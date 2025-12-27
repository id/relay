import SwiftData
import SwiftUI

struct ConversationListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.lastMessageTime, order: .reverse) private
        var conversations: [Conversation]
    @Bindable var mqttService: MQTTService

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
                ChatView(conversation: conversation, mqttService: mqttService)
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
                NewChatSheet(mqttService: mqttService)
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

    @State private var subscribeTopics: [String] = [""]
    @State private var publishTopic = ""
    @State private var displayName = ""

    private var canCreate: Bool {
        subscribeTopics.contains { !$0.isEmpty }
    }

    private var firstNonEmptyTopic: String? {
        subscribeTopics.first { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(subscribeTopics.indices, id: \.self) { index in
                        HStack {
                            TextField("Topic", text: $subscribeTopics[index])
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
        let validTopics = subscribeTopics.filter { !$0.isEmpty }
        guard !validTopics.isEmpty else { return }

        let effectiveDisplayName =
            displayName.isEmpty ? validTopics[0] : displayName
        let effectivePublishTopic = publishTopic.isEmpty ? nil : publishTopic

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

        dismiss()
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
    ConversationListView(mqttService: MQTTService())
        .modelContainer(for: Conversation.self, inMemory: true)
}
