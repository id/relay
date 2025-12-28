import Foundation
import SwiftData

@Model
final class Conversation {
    var id: UUID
    var peerClientId: String?
    var groupId: String?  // MLS group ID (hex-encoded) for encrypted conversations
    var subscribeTopics: [String]  // Subscribe topics (can include wildcards like +, #)
    var publishTopic: String?  // Topic to publish to (no wildcards)
    var displayName: String
    var lastMessage: String?
    var lastMessageTime: Date?
    var unreadCount: Int
    var isEncrypted: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []

    /// The topic to use for publishing (falls back to first subscribe topic if not set)
    var effectivePublishTopic: String? {
        publishTopic ?? subscribeTopics.first
    }

    /// Legacy accessor for single topic (returns first subscribe topic)
    var topic: String? {
        subscribeTopics.first
    }

    init(
        id: UUID = UUID(),
        peerClientId: String? = nil,
        groupId: String? = nil,
        subscribeTopics: [String] = [],
        publishTopic: String? = nil,
        displayName: String,
        isEncrypted: Bool = false
    ) {
        self.id = id
        self.peerClientId = peerClientId
        self.groupId = groupId
        self.subscribeTopics = subscribeTopics
        self.publishTopic = publishTopic
        self.displayName = displayName
        self.lastMessage = nil
        self.lastMessageTime = nil
        self.unreadCount = 0
        self.isEncrypted = isEncrypted
        self.createdAt = Date()
    }

    /// Convenience initializer for Relay encrypted conversations
    convenience init(name: String, topic: String, isEncrypted: Bool) {
        self.init(
            subscribeTopics: [topic],
            publishTopic: topic,
            displayName: name,
            isEncrypted: isEncrypted
        )
    }

    func updateLastMessage(_ content: String) {
        self.lastMessage = content
        self.lastMessageTime = Date()
    }

    func addSubscribeTopic(_ topic: String) {
        if !subscribeTopics.contains(topic) {
            subscribeTopics.append(topic)
        }
    }

    func removeSubscribeTopic(_ topic: String) {
        subscribeTopics.removeAll { $0 == topic }
    }
}
