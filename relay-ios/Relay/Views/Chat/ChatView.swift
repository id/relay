import Combine
import SwiftData
import SwiftUI

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var conversation: Conversation
    @Bindable var mqttService: MQTTService

    @State private var messageText = ""
    @State private var publishTopicText = ""
    @State private var showingPublishTopicEditor = false
    @State private var showingTopicsSheet = false
    @State private var cancellables = Set<AnyCancellable>()

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

            if conversation.isEncrypted {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .sheet(isPresented: $showingTopicsSheet) {
            TopicsSheet(conversation: conversation, mqttService: mqttService)
        }
        .onAppear {
            subscribeToMessages()
            publishTopicText = conversation.publishTopic ?? ""
        }
        .onDisappear {
            cancellables.removeAll()
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

        // Publish to topic
        Task {
            do {
                try await mqttService.publish(to: topic, message: content)
                await MainActor.run {
                    message.status = .sent
                }
            } catch {
                await MainActor.run {
                    message.status = .failed
                }
            }
        }
    }

    private func subscribeToMessages() {
        // Subscribe to all topics
        Task {
            for topic in conversation.subscribeTopics {
                try? await mqttService.subscribe(to: topic)
            }
        }

        // Listen for incoming messages matching any subscribe topic
        mqttService.receivedMessages
            .filter { incoming in
                conversation.subscribeTopics.contains { filter in
                    topicMatchesFilter(incoming.topic, filter: filter)
                }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak modelContext] incoming in
                guard
                    let content = String(
                        data: incoming.payload,
                        encoding: .utf8
                    ),
                    let modelContext = modelContext
                else { return }

                // Don't add our own messages (they're already added when sent)
                // In a real app, you'd have message IDs to deduplicate
                let message = Message(
                    content: content,
                    isFromMe: false,
                    status: .delivered,
                    conversation: conversation
                )

                modelContext.insert(message)
                conversation.updateLastMessage(content)
            }
            .store(in: &cancellables)
    }

    /// Check if a topic matches an MQTT filter pattern (supports + and # wildcards)
    private func topicMatchesFilter(_ topic: String, filter: String) -> Bool {
        let topicParts = topic.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        let filterParts = filter.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)

        var ti = 0
        var fi = 0

        while fi < filterParts.count {
            let filterPart = filterParts[fi]

            if filterPart == "#" {
                // # matches everything from here on
                return true
            } else if filterPart == "+" {
                // + matches exactly one level
                if ti >= topicParts.count {
                    return false
                }
                ti += 1
                fi += 1
            } else {
                // Exact match required
                if ti >= topicParts.count || topicParts[ti] != filterPart {
                    return false
                }
                ti += 1
                fi += 1
            }
        }

        // All parts must be consumed
        return ti == topicParts.count
    }
}

// MARK: - Topics Sheet

struct TopicsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var conversation: Conversation
    @Bindable var mqttService: MQTTService

    @State private var newTopic = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(conversation.subscribeTopics, id: \.self) { topic in
                        HStack {
                            Text(topic)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                        }
                    }
                    .onDelete(perform: deleteTopics)

                    HStack {
                        TextField("Add topic", text: $newTopic)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))

                        Button {
                            addTopic()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.blue)
                        }
                        .disabled(newTopic.isEmpty)
                    }
                } header: {
                    Text("Subscribe Topics")
                } footer: {
                    Text(
                        "Supports wildcards: + (single level) and # (multi-level)"
                    )
                }

                Section {
                    HStack {
                        Text(conversation.effectivePublishTopic ?? "Not set")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(
                                conversation.publishTopic == nil
                                    ? .secondary : .primary
                            )
                        Spacer()
                    }
                } header: {
                    Text("Publish Topic")
                } footer: {
                    if conversation.publishTopic == nil {
                        Text("Using first subscribe topic")
                    }
                }
            }
            .navigationTitle("Topics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func addTopic() {
        guard !newTopic.isEmpty else { return }

        conversation.addSubscribeTopic(newTopic)

        // Subscribe to the new topic
        Task {
            try? await mqttService.subscribe(to: newTopic)
        }

        newTopic = ""
    }

    private func deleteTopics(at offsets: IndexSet) {
        for index in offsets {
            let topic = conversation.subscribeTopics[index]

            // Unsubscribe from the topic
            Task {
                try? await mqttService.unsubscribe(from: topic)
            }

            conversation.removeSubscribeTopic(topic)
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isFromMe {
                Spacer(minLength: 60)
            }

            VStack(
                alignment: message.isFromMe ? .trailing : .leading,
                spacing: 2
            ) {
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.isFromMe ? Color.blue : Color.gray.opacity(0.2)
                    )
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if message.isFromMe {
                        statusIcon
                    }
                }
            }

            if !message.isFromMe {
                Spacer(minLength: 60)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .sending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .sent:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .delivered:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(
            conversation: Conversation(
                subscribeTopics: ["test/+/messages"],
                publishTopic: "test/device1/messages",
                displayName: "Test Chat"
            ),
            mqttService: MQTTService()
        )
    }
    .modelContainer(for: [Conversation.self, Message.self], inMemory: true)
}
