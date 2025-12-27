//
//  RelayApp.swift
//  Relay
//
//  Created by Ivan Dyachkov on 2025-12-27.
//

import SwiftData
import SwiftUI

@main
struct RelayApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding =
        false

    @State private var mqttService = MQTTService()

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
                MainTabView(mqttService: mqttService)
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
        } catch {
            print("Failed to initialize app: \(error)")
        }
    }
}

struct MainTabView: View {
    @Bindable var mqttService: MQTTService

    var body: some View {
        TabView {
            ConversationListView(mqttService: mqttService)
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
    MainTabView(mqttService: MQTTService())
        .modelContainer(
            for: [BrokerConfig.self, Conversation.self, Message.self],
            inMemory: true
        )
}
