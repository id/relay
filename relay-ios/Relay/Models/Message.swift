import Foundation
import SwiftData

enum MessageStatus: String, Codable {
    case sending
    case sent
    case delivered
    case failed
}

@Model
final class Message {
    var id: UUID
    var content: String
    var timestamp: Date
    var isFromMe: Bool
    var status: MessageStatus

    var conversation: Conversation?

    init(
        id: UUID = UUID(),
        content: String,
        isFromMe: Bool,
        status: MessageStatus = .sending,
        conversation: Conversation? = nil
    ) {
        self.id = id
        self.content = content
        self.timestamp = Date()
        self.isFromMe = isFromMe
        self.status = status
        self.conversation = conversation
    }
}
