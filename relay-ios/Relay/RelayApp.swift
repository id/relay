//
//  RelayApp.swift
//  Relay
//
//  Created by Ivan Dyachkov on 2025-12-27.
//

import SwiftData
import SwiftOpenMLS
import SwiftUI

@main
struct RelayApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding =
        false

    @State private var mqttService = MQTTService()
    @State private var mlsService: MLSService

    init() {
        // Initialize MLSService with the MQTT client ID
        let mqttSvc = MQTTService()
        self._mqttService = State(initialValue: mqttSvc)
        self._mlsService = State(
            initialValue: MLSService(clientId: mqttSvc.clientId)
        )
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            BrokerConfig.self,
            Conversation.self,
            Message.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
        } catch {
            // Schema changed - delete old database and retry
            // This is acceptable during development; production apps should use proper migrations
            print(
                "ModelContainer error: \(error). Attempting to delete old database..."
            )

            let url = URL.applicationSupportDirectory.appending(
                path: "default.store"
            )
            let deleteFiles = [
                url, url.appendingPathExtension("shm"),
                url.appendingPathExtension("wal"),
            ]
            for file in deleteFiles {
                try? FileManager.default.removeItem(at: file)
            }

            do {
                return try ModelContainer(
                    for: schema,
                    configurations: [modelConfiguration]
                )
            } catch {
                fatalError(
                    "Could not create ModelContainer after reset: \(error)"
                )
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                MainTabView(mqttService: mqttService, mlsService: mlsService)
                    .task {
                        await initializeApp()
                    }
            } else {
                OnboardingView()
            }
        }
        .modelContainer(sharedModelContainer)
    }

    private func initializeApp() async {
        // Initialize MLS service
        try? mlsService.initialize()

        // Ensure default broker exists
        let context = sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<BrokerConfig>()

        do {
            let configs = try context.fetch(descriptor)
            if configs.isEmpty {
                let defaultBroker = BrokerConfig.defaultConfig
                context.insert(defaultBroker)
                try context.save()

                // Auto-connect to default broker
                try? await mqttService.connect(config: defaultBroker)
            } else if let defaultBroker = configs.first(where: { $0.isDefault })
                ?? configs.first
            {
                // Auto-connect to existing broker
                try? await mqttService.connect(config: defaultBroker)
            }

            // Subscribe to Relay protocol topics
            await subscribeRelayTopics()
        } catch {
            print("Failed to initialize app: \(error)")
        }
    }

    private func subscribeRelayTopics() async {
        let clientId = mqttService.clientId
        print("[RelayApp] Client ID: \(clientId)")

        // Subscribe to Welcome messages for this client
        let welcomeTopic = "relay/w/\(clientId)"
        try? await mqttService.subscribe(to: welcomeTopic)
        print("[RelayApp] Subscribed to Welcome messages at: \(welcomeTopic)")

        // Publish our KeyPackage to relay/k/{clientId} (retained)
        await publishKeyPackage()

        // Set up Welcome message handler
        setupWelcomeHandler()
    }

    /// Publish our KeyPackage so others can invite us to groups
    private func publishKeyPackage() async {
        let clientId = mqttService.clientId
        let keyPackageTopic = "relay/k/\(clientId)"

        do {
            let keyPackageData = try mlsService.createKeyPackage()
            try await mqttService.publish(
                to: keyPackageTopic,
                payload: keyPackageData,
                retain: true  // KeyPackages should be retained
            )
            print(
                "[RelayApp] Published KeyPackage to: \(keyPackageTopic) (\(keyPackageData.count) bytes)"
            )
        } catch {
            print("[RelayApp] Failed to publish KeyPackage: \(error)")
        }
    }

    /// Set up handler for incoming Welcome messages
    private func setupWelcomeHandler() {
        let welcomeTopic = "relay/w/\(mqttService.clientId)"

        mqttService.setMessageHandler { [self] topic, payload in
            print("[RelayApp] Handler received: \(topic)")

            if topic == welcomeTopic {
                print("[RelayApp] -> Routing to Welcome handler")
                Task { @MainActor in
                    await handleWelcomeMessage(payload: payload)
                }
            } else if topic.hasPrefix("relay/g/") && topic.hasSuffix("/m") {
                print("[RelayApp] -> Routing to Group message handler")
                Task { @MainActor in
                    await handleGroupMessage(topic: topic, payload: payload)
                }
            } else {
                print("[RelayApp] -> No handler for this topic")
            }
        }
    }

    /// Handle an incoming group message - decrypt and store
    @MainActor
    private func handleGroupMessage(topic: String, payload: Data) async {
        print("[RelayApp] handleGroupMessage called for topic: \(topic)")

        // Extract group_id from topic: relay/g/{group_id}/m
        let parts = topic.split(separator: "/")
        guard parts.count == 4,
            parts[0] == "relay",
            parts[1] == "g",
            parts[3] == "m"
        else {
            print("[RelayApp] Invalid group message topic: \(topic)")
            return
        }
        let groupId = String(parts[2])
        print("[RelayApp] Extracted groupId: \(groupId)")

        // Find the conversation for this group
        let context = sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { conv in
                conv.groupId == groupId
            }
        )

        guard let conversations = try? context.fetch(descriptor),
            let conversation = conversations.first
        else {
            print("No conversation found for group: \(groupId)")
            return
        }

        // Decrypt the message
        do {
            let content = try mlsService.decrypt(
                ciphertext: payload,
                for: groupId
            )

            print(
                "[RelayApp] Decrypted message in group \(groupId.prefix(8)): \(content)"
            )

            // Create and store the message
            let message = Message(
                content: content,
                isFromMe: false,
                status: .delivered,
                conversation: conversation
            )

            context.insert(message)
            conversation.updateLastMessage(content)
            try? context.save()

        } catch {
            // Check for CannotDecryptOwnMessage
            let errorMessage = "\(error)"
            if errorMessage.contains("CannotDecryptOwnMessage") {
                print(
                    "[RelayApp] Ignoring our own message (CannotDecryptOwnMessage)"
                )
                return
            }
            print("[RelayApp] Failed to decrypt group message: \(error)")
        }
    }

    /// Handle an incoming Welcome message - join the group and create conversation
    @MainActor
    private func handleWelcomeMessage(payload: Data) async {
        print("[RelayApp] handleWelcomeMessage called (\(payload.count) bytes)")

        do {
            // Join the group from the Welcome message
            let result = try mlsService.joinFromWelcome(welcomeData: payload)
            let groupId = result.groupId
            print("[RelayApp] Joined MLS group: \(groupId)")

            // Subscribe to group messages
            let groupTopic = "relay/g/\(groupId)/m"
            try? await mqttService.subscribe(to: groupTopic)
            print("[RelayApp] Subscribed to group topic: \(groupTopic)")

            // Create conversation in SwiftData
            let context = sharedModelContainer.mainContext

            // Check if conversation already exists
            let descriptor = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { conv in
                    conv.groupId == groupId
                }
            )

            let existing = try? context.fetch(descriptor)
            if existing?.isEmpty ?? true {
                // Create new conversation
                let conversation = Conversation(
                    name: "Group \(groupId.prefix(8))",
                    topic: groupTopic,
                    isEncrypted: true
                )
                conversation.groupId = groupId
                context.insert(conversation)
                try? context.save()
                print("[RelayApp] Created conversation for group: \(groupId)")
                print(
                    "[RelayApp] Conversation subscribeTopics: \(conversation.subscribeTopics)"
                )
                print(
                    "[RelayApp] Conversation publishTopic: \(conversation.publishTopic ?? "nil")"
                )
            } else {
                print(
                    "[RelayApp] Conversation already exists for group: \(groupId)"
                )
            }

            // Publish a fresh KeyPackage (the old one was consumed by joining)
            await publishKeyPackage()

        } catch {
            print("[RelayApp] Failed to join group from Welcome: \(error)")
        }
    }
}

struct MainTabView: View {
    @Bindable var mqttService: MQTTService
    @Bindable var mlsService: MLSService

    var body: some View {
        TabView {
            ConversationListView(
                mqttService: mqttService,
                mlsService: mlsService
            )
            .tabItem {
                Label("Messages", systemImage: "message")
            }

            SettingsView(mqttService: mqttService)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}

#Preview {
    let mqttService = MQTTService()
    let mlsService = MLSService(clientId: mqttService.clientId)

    MainTabView(mqttService: mqttService, mlsService: mlsService)
        .modelContainer(
            for: [BrokerConfig.self, Conversation.self, Message.self],
            inMemory: true
        )
}
