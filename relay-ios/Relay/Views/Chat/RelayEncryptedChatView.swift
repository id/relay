import SwiftData
import SwiftUI

struct RelayEncryptedChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var conversation: Conversation
    @Bindable var mqttService: MQTTService
    @Bindable var mlsService: MLSService

    @State private var messageText = ""
    @State private var publishTopicText = ""
    @State private var showingPublishTopicEditor = false
    @State private var showingTopicsSheet = false

    var sortedMessages: [Message] {
        conversation.messages.sorted { $0.timestamp < $1.timestamp }
    }

    /// The current publish topic (from state or conversation)
    private var currentPublishTopic: String {
        if !publishTopicText.isEmpty {
            return publishTopicText
        }
        return conversation.effectivePublishTopic ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sortedMessages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: conversation.messages.count) { _, _ in
                    if let lastMessage = sortedMessages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input area
            VStack(spacing: 8) {
                // Publish topic row
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.to.line")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if showingPublishTopicEditor {
                        TextField("Publish topic", text: $publishTopicText)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit {
                                savePublishTopic()
                            }

                        Button {
                            savePublishTopic()
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }

                        Button {
                            cancelPublishTopicEdit()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(
                            currentPublishTopic.isEmpty
                                ? "No publish topic" : currentPublishTopic
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                        Spacer()

                        Button {
                            startPublishTopicEdit()
                        } label: {
                            Image(systemName: "pencil.circle")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Message input row
                HStack(spacing: 12) {
                    TextField("Message", text: $messageText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .lineLimit(1...5)

                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(canSend ? .blue : .gray)
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle(conversation.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingTopicsSheet = true
                } label: {
                    Image(systemName: "info.circle")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.green)
            }
        }
        .sheet(isPresented: $showingTopicsSheet) {
            TopicsSheet(conversation: conversation, mqttService: mqttService)
        }
        .onAppear {
            publishTopicText = conversation.publishTopic ?? ""
            // Subscriptions are handled by RelayApp (when joining) and ConversationListView (when creating)
            // Message decryption is handled globally by RelayApp
        }
        .onDisappear {
            // No cleanup needed - message handling is done globally by RelayApp
        }
    }

    private var canSend: Bool {
        !messageText.isEmpty && !currentPublishTopic.isEmpty
    }

    private func startPublishTopicEdit() {
        publishTopicText = conversation.publishTopic ?? conversation.topic ?? ""
        showingPublishTopicEditor = true
    }

    private func savePublishTopic() {
        conversation.publishTopic =
            publishTopicText.isEmpty ? nil : publishTopicText
        showingPublishTopicEditor = false
    }

    private func cancelPublishTopicEdit() {
        publishTopicText = conversation.publishTopic ?? ""
        showingPublishTopicEditor = false
    }

    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        guard !currentPublishTopic.isEmpty else { return }
        guard let groupId = conversation.groupId else {
            print("No groupId for encrypted conversation")
            return
        }

        let content = messageText
        let topic = currentPublishTopic
        messageText = ""

        // Create message
        let message = Message(
            content: content,
            isFromMe: true,
            status: .sending,
            conversation: conversation
        )

        modelContext.insert(message)
        conversation.updateLastMessage(content)

        // Encrypt and publish to topic
        Task {
            do {
                // Encrypt message using MLS with the groupId
                let encryptedData = try mlsService.encrypt(
                    message: content,
                    for: groupId
                )
                try await mqttService.publish(to: topic, payload: encryptedData)

                await MainActor.run {
                    message.status = .sent
                }
            } catch {
                await MainActor.run {
                    message.status = .failed
                }
                print("Failed to send encrypted message: \(error)")
            }
        }
    }
}

#Preview {
    let mqttService = MQTTService()
    let mlsService = MLSService(clientId: mqttService.clientId)

    NavigationStack {
        RelayEncryptedChatView(
            conversation: Conversation(
                groupId: "preview-group-id",
                subscribeTopics: ["relay/g/preview-group-id/m"],
                publishTopic: "relay/g/preview-group-id/m",
                displayName: "Preview Chat",
                isEncrypted: true
            ),
            mqttService: mqttService,
            mlsService: mlsService
        )
    }
    .modelContainer(for: [Conversation.self, Message.self], inMemory: true)
}
