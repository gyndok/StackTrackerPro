import Foundation
import SwiftData

@Model
final class CashSession {
    var date: Date = Date.now
    var startTime: Date = Date.now
    var endTime: Date?
    var stakes: String = ""
    var gameTypeRaw: String = "NLH"
    var buyInTotal: Int = 0
    var cashOut: Int?
    var venueName: String?
    var venueID: UUID?
    var statusRaw: String = "setup"
    var notes: String?
    var isImported: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \StackEntry.cashSession)
    var stackEntries: [StackEntry]? = []

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.cashSession)
    var chatMessages: [ChatMessage]? = []

    @Relationship(deleteRule: .cascade, inverse: \HandNote.cashSession)
    var handNotes: [HandNote]? = []

    init(
        stakes: String = "",
        gameType: GameType = .nlh,
        buyInTotal: Int = 0,
        venueName: String? = nil,
        date: Date = .now
    ) {
        self.date = date
        self.startTime = date
        self.endTime = nil
        self.stakes = stakes
        self.gameTypeRaw = gameType.rawValue
        self.buyInTotal = buyInTotal
        self.cashOut = nil
        self.venueName = venueName
        self.venueID = nil
        self.statusRaw = SessionStatus.setup.rawValue
        self.notes = nil
        self.isImported = false
    }

    var gameType: GameType {
        get { GameType(rawValue: gameTypeRaw) ?? .nlh }
        set { gameTypeRaw = newValue.rawValue }
    }

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .setup }
        set { statusRaw = newValue.rawValue }
    }

    var profit: Int? {
        guard let cashOut else { return nil }
        return cashOut - buyInTotal
    }

    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    var durationFormatted: String {
        let elapsed = duration ?? Date.now.timeIntervalSince(startTime)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var hourlyRate: Double? {
        guard let profit, let dur = duration, dur > 0 else { return nil }
        return Double(profit) / (dur / 3600)
    }

    var sortedStackEntries: [StackEntry] {
        (stackEntries ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    var sortedChatMessages: [ChatMessage] {
        (chatMessages ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    var sortedHandNotes: [HandNote] {
        (handNotes ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    var latestStack: StackEntry? {
        sortedStackEntries.last
    }

    var displayName: String {
        "\(stakes) \(gameType.label)"
    }
}
