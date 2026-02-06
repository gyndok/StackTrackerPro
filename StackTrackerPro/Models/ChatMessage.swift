import Foundation
import SwiftData

@Model
final class ChatMessage {
    var timestamp: Date
    var senderRaw: String
    var text: String
    var isProactive: Bool
    var parsedEntitiesData: Data?
    var tournament: Tournament?

    init(
        timestamp: Date = .now,
        sender: MessageSender,
        text: String,
        isProactive: Bool = false
    ) {
        self.timestamp = timestamp
        self.senderRaw = sender.rawValue
        self.text = text
        self.isProactive = isProactive
    }

    var sender: MessageSender {
        MessageSender(rawValue: senderRaw) ?? .system
    }

    var isUser: Bool {
        sender == .user
    }

    var isAI: Bool {
        sender == .ai
    }
}
