import Combine
import SwiftData
import SwiftOpenMLS
import SwiftUI

struct ConversationListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.lastMessageTime, order: .reverse) private
        var conversations: [Conversation]
    @Bindable var mqttService: MQTTService
    @Bindable var mlsService: MLSService

    @State private var showingNewChat = false

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "message",
                        description: Text("Start a new chat to begin messaging")
                    )
                } else {
                    List {
                        ForEach(conversations) { conversation in
                            NavigationLink(value: conversation) {
                                ConversationRow(conversation: conversation)
                            }
                        }
                        .onDelete(perform: deleteConversations)
                    }
                }
            }
            .navigationTitle("Messages")
            .navigationDestination(for: Conversation.self) { conversation in
                if conversation.isEncrypted {
                    RelayEncryptedChatView(
                        conversation: conversation,
                        mqttService: mqttService,
                        mlsService: mlsService
                    )
                } else {
                    PlainMQTTChatView(
                        conversation: conversation,
                        mqttService: mqttService
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectionStatusView(state: mqttService.connectionState)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showingNewChat) {
                NewChatSheet(mqttService: mqttService, mlsService: mlsService)
            }
        }
    }

    private func deleteConversations(at offsets: IndexSet) {
        for index in offsets {
            let conversation = conversations[index]
            // Unsubscribe from all topics
            for topic in conversation.subscribeTopics {
                Task {
                    try? await mqttService.unsubscribe(from: topic)
                }
            }
            modelContext.delete(conversation)
        }
    }
}

struct NewChatSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var mqttService: MQTTService
    @Bindable var mlsService: MLSService

    @AppStorage("appMode") private var appMode = "relay"

    // For Relay mode
    @State private var contactId = ""

    // For MQTT mode
    @State private var subscribeTopics: [String] = [""]
    @State private var publishTopic = ""
    @State private var displayName = ""

    private var canCreate: Bool {
        if appMode == "relay" {
            return !contactId.isEmpty
        } else {
            return subscribeTopics.contains { !$0.isEmpty }
        }
    }

    private var firstNonEmptyTopic: String? {
        subscribeTopics.first { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                if appMode == "relay" {
                    // Relay mode: Contact-based
                    Section {
                        TextField("Contact ID", text: $contactId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    } header: {
                        Text("Contact")
                    } footer: {
                        Text(
                            "Enter the Client ID of the person you want to chat with"
                        )
                    }

                    Section {
                        TextField("Display name", text: $displayName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Display Name (Optional)")
                    } footer: {
                        Text("Leave empty to use Contact ID")
                    }
                } else {
                    // MQTT mode: Topic-based
                    Section {
                        ForEach(subscribeTopics.indices, id: \.self) { index in
                            HStack {
                                TextField(
                                    "Topic",
                                    text: $subscribeTopics[index]
                                )
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                                if subscribeTopics.count > 1 {
                                    Button {
                                        subscribeTopics.remove(at: index)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                        }

                        Button {
                            subscribeTopics.append("")
                        } label: {
                            Label("Add topic", systemImage: "plus.circle")
                        }
                    } header: {
                        Text("Subscribe Topics")
                    } footer: {
                        Text(
                            "Topics to receive messages from. Supports wildcards: + (single level) and # (multi-level)"
                        )
                    }

                    Section {
                        TextField("Publish topic", text: $publishTopic)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Publish Topic")
                    } footer: {
                        Text(
                            "Topic to send messages to. Leave empty to use first subscribe topic."
                        )
                    }

                    Section {
                        TextField("Display name", text: $displayName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Display Name")
                    } footer: {
                        Text("Leave empty to use first subscribe topic")
                    }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createConversation()
                    }
                    .disabled(!canCreate)
                }
            }
        }
    }

    private func createConversation() {
        if appMode == "relay" {
            // Relay mode: Create encrypted conversation following Relay protocol
            guard !contactId.isEmpty else { return }

            Task {
                await createRelayConversation()
            }
        } else {
            // MQTT mode: Create plain conversation with manual topics
            let validTopics = subscribeTopics.filter { !$0.isEmpty }
            guard !validTopics.isEmpty else { return }

            let effectiveDisplayName =
                displayName.isEmpty ? validTopics[0] : displayName
            let effectivePublishTopic =
                publishTopic.isEmpty ? nil : publishTopic

            let conversation = Conversation(
                subscribeTopics: validTopics,
                publishTopic: effectivePublishTopic,
                displayName: effectiveDisplayName,
                isEncrypted: false
            )

            modelContext.insert(conversation)

            // Subscribe to all topics
            Task {
                for topic in validTopics {
                    try? await mqttService.subscribe(to: topic)
                }
            }
        }

        dismiss()
    }

    /// Create a Relay encrypted conversation following the Relay protocol:
    /// 1. Fetch KeyPackage from relay/k/{contactId}
    /// 2. Create MLS group with random group_id
    /// 3. Add contact using their KeyPackage
    /// 4. Send Welcome to relay/w/{contactId}
    /// 5. Subscribe to relay/g/{group_id}/m
    @MainActor
    private func createRelayConversation() async {
        let keyPackageTopic = "relay/k/\(contactId)"

        do {
            // 1. Subscribe to contact's KeyPackage topic to get their KeyPackage (retained)
            print("Fetching KeyPackage from: \(keyPackageTopic)")
            try await mqttService.subscribe(to: keyPackageTopic)

            // Wait for the KeyPackage message with a timeout
            let keyPackageData = await waitForMessage(
                on: keyPackageTopic,
                timeout: 5.0
            )

            // Unsubscribe from KeyPackage topic (we only needed it once)
            try? await mqttService.unsubscribe(from: keyPackageTopic)

            guard let keyPackageData = keyPackageData else {
                print("No KeyPackage found for contact: \(contactId)")
                return
            }

            print("Received KeyPackage (\(keyPackageData.count) bytes)")

            // 2. Create MLS group with random group_id
            let groupId = try mlsService.createGroup()
            let groupTopic = "relay/g/\(groupId)/m"
            print("Created MLS group: \(groupId)")

            // 3. Add contact using their KeyPackage
            let addResult = try mlsService.addMember(
                to: groupId,
                keyPackageData: keyPackageData
            )
            print(
                "Added contact to group, Welcome size: \(addResult.welcomeBytes.count) bytes"
            )

            // 4. Send Welcome to relay/w/{contactId}
            let welcomeTopic = "relay/w/\(contactId)"
            try await mqttService.publish(
                to: welcomeTopic,
                payload: Data(addResult.welcomeBytes),
                retain: false
            )
            print("Sent Welcome to: \(welcomeTopic)")

            // 5. Subscribe to group messages
            try? await mqttService.subscribe(to: groupTopic)
            print("Subscribed to group messages at: \(groupTopic)")

            // 6. Create conversation in SwiftData
            let effectiveDisplayName =
                displayName.isEmpty ? contactId : displayName

            let conversation = Conversation(
                peerClientId: contactId,
                groupId: groupId,
                subscribeTopics: [groupTopic],
                publishTopic: groupTopic,
                displayName: effectiveDisplayName,
                isEncrypted: true
            )

            modelContext.insert(conversation)
            try? modelContext.save()

            print("Created Relay conversation with \(contactId)")

        } catch {
            print("Failed to create Relay conversation: \(error)")
        }
    }

    /// Wait for a message on a specific topic with timeout
    @MainActor
    private func waitForMessage(on topic: String, timeout: TimeInterval) async
        -> Data?
    {
        await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            var didResume = false

            // Set up timeout
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                if !didResume {
                    didResume = true
                    cancellable?.cancel()
                    continuation.resume(returning: nil)
                }
            }

            // Subscribe to messages
            cancellable = mqttService.receivedMessages
                .filter { $0.topic == topic }
                .first()
                .sink { message in
                    if !didResume {
                        didResume = true
                        timeoutTask.cancel()
                        continuation.resume(returning: message.payload)
                    }
                }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            // Avatar placeholder
            Circle()
                .fill(Color.blue.opacity(0.2))
                .frame(width: 50, height: 50)
                .overlay {
                    Image(
                        systemName: conversation.isEncrypted
                            ? "lock.fill" : "number"
                    )
                    .foregroundStyle(.blue)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    if let time = conversation.lastMessageTime {
                        Text(time, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text(conversation.lastMessage ?? "No messages yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ConnectionStatusView: View {
    let state: MQTTConnectionState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch state {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }

    private var statusText: String {
        switch state {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Disconnected"
        case .error:
            return "Error"
        }
    }
}

#Preview {
    let mqttService = MQTTService()
    let mlsService = MLSService(clientId: mqttService.clientId)

    ConversationListView(mqttService: mqttService, mlsService: mlsService)
        .modelContainer(for: Conversation.self, inMemory: true)
}
