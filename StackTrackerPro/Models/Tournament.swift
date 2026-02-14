import Foundation
import SwiftData

@Model
final class Tournament {
    // Basic info
    var name: String = ""
    var gameTypeRaw: String = "NLH"
    var buyIn: Int = 0
    var entryFee: Int = 0
    var deductions: Int = 0
    var bountyAmount: Int = 0
    var guarantee: Int = 0
    var startDate: Date = Date.now
    var regCloseTime: Date?
    var startingChips: Int = 20000

    // Re-entry
    var reentryPolicy: String = "None"
    var rebuysUsed: Int = 0

    // Status
    var statusRaw: String = "setup"
    var finishPosition: Int?
    var payout: Int?
    var bountiesCollected: Int = 0

    // Current state
    var currentBlindLevelNumber: Int = 1
    var fieldSize: Int = 0
    var playersRemaining: Int = 0
    var payoutPercent: Double = 15.0

    // Venue (soft reference)
    var venueID: UUID?
    var venueName: String?

    // Relationships (optional for CloudKit compatibility)
    @Relationship(deleteRule: .cascade, inverse: \BlindLevel.tournament)
    var blindLevels: [BlindLevel]? = []

    @Relationship(deleteRule: .cascade, inverse: \StackEntry.tournament)
    var stackEntries: [StackEntry]? = []

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.tournament)
    var chatMessages: [ChatMessage]? = []

    @Relationship(deleteRule: .cascade, inverse: \HandNote.tournament)
    var handNotes: [HandNote]? = []

    @Relationship(deleteRule: .cascade, inverse: \BreakEntry.tournament)
    var breakEntries: [BreakEntry]? = []

    @Relationship(deleteRule: .cascade, inverse: \BountyEvent.tournament)
    var bountyEvents: [BountyEvent]? = []

    @Relationship(deleteRule: .cascade, inverse: \FieldSnapshot.tournament)
    var fieldSnapshots: [FieldSnapshot]? = []

    @Relationship(deleteRule: .cascade, inverse: \ChipStackPhoto.tournament)
    var chipStackPhotos: [ChipStackPhoto]? = []

    // End of session
    var endDate: Date?

    // Receipt
    @Attribute(.externalStorage) var receiptImageData: Data?

    init(
        name: String,
        gameType: GameType = .nlh,
        buyIn: Int = 0,
        entryFee: Int = 0,
        deductions: Int = 0,
        bountyAmount: Int = 0,
        guarantee: Int = 0,
        startDate: Date = .now,
        startingChips: Int = 20000,
        reentryPolicy: String = "None"
    ) {
        self.name = name
        self.gameTypeRaw = gameType.rawValue
        self.buyIn = buyIn
        self.entryFee = entryFee
        self.deductions = deductions
        self.bountyAmount = bountyAmount
        self.guarantee = guarantee
        self.startDate = startDate
        self.regCloseTime = nil
        self.startingChips = startingChips
        self.reentryPolicy = reentryPolicy
        self.rebuysUsed = 0
        self.statusRaw = TournamentStatus.setup.rawValue
        self.finishPosition = nil
        self.payout = nil
        self.bountiesCollected = 0
        self.currentBlindLevelNumber = 1
        self.fieldSize = 0
        self.playersRemaining = 0
        self.payoutPercent = 15.0
        self.venueID = nil
        self.venueName = nil
        self.endDate = nil
        self.receiptImageData = nil
    }

    // MARK: - Computed Properties

    var gameType: GameType {
        get { GameType(rawValue: gameTypeRaw) ?? .nlh }
        set { gameTypeRaw = newValue.rawValue }
    }

    var gameTypeLabel: String {
        GameType.label(for: gameTypeRaw)
    }

    var status: TournamentStatus {
        get { TournamentStatus(rawValue: statusRaw) ?? .setup }
        set { statusRaw = newValue.rawValue }
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

    var sortedBreakEntries: [BreakEntry] {
        (breakEntries ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    var sortedBlindLevels: [BlindLevel] {
        (blindLevels ?? []).sorted { $0.levelNumber < $1.levelNumber }
    }

    /// Maps internal levelNumber → display number (1-based, skipping breaks).
    var displayLevelNumbers: [Int: Int] {
        var map: [Int: Int] = [:]
        var displayNum = 1
        for level in sortedBlindLevels where !level.isBreak {
            map[level.levelNumber] = displayNum
            displayNum += 1
        }
        return map
    }

    /// Reverse map: display level number → internal level number.
    var internalLevelNumbers: [Int: Int] {
        var map: [Int: Int] = [:]
        for (internal_, display) in displayLevelNumbers {
            map[display] = internal_
        }
        return map
    }

    /// Display level number for the current blind level.
    var currentDisplayLevel: Int? {
        displayLevelNumbers[currentBlindLevelNumber]
    }

    var latestStack: StackEntry? {
        sortedStackEntries.last
    }

    var currentBlinds: BlindLevel? {
        (blindLevels ?? []).first { $0.levelNumber == currentBlindLevelNumber }
    }

    var currentMRatio: Double {
        latestStack?.mRatio ?? 0
    }

    var currentBBCount: Double {
        latestStack?.bbCount ?? 0
    }

    var averageStack: Int {
        guard playersRemaining > 0, fieldSize > 0 else { return 0 }
        let totalChips = fieldSize * startingChips
        return totalChips / playersRemaining
    }

    var totalInvestment: Int {
        (buyIn + entryFee) * (1 + rebuysUsed)
    }

    var profit: Int? {
        guard let payout else { return nil }
        return payout + (bountiesCollected * bountyAmount) - totalInvestment
    }

    var duration: TimeInterval? {
        guard let end = endDate else { return nil }
        return end.timeIntervalSince(startDate)
    }

    var durationFormatted: String {
        let elapsed = duration ?? Date.now.timeIntervalSince(startDate)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var hourlyRate: Double? {
        guard let profit = profit, let dur = duration, dur > 0 else { return nil }
        let hours = dur / 3600
        return Double(profit) / hours
    }

    // MARK: - Tournament Metrics

    var prizePool: Int {
        buyIn * fieldSize
    }

    var houseRake: Int {
        entryFee * fieldSize
    }

    var overlay: Int {
        guard guarantee > 0 else { return 0 }
        return max(0, guarantee - prizePool)
    }

    var playersNeededForGuarantee: Int {
        guard guarantee > 0, buyIn > 0 else { return 0 }
        let needed = Int(ceil(Double(guarantee) / Double(buyIn))) - fieldSize
        return max(0, needed)
    }

    var totalChipsInPlay: Int {
        fieldSize * startingChips
    }

    var estimatedBubbleDistance: Int {
        guard fieldSize > 0, payoutPercent > 0 else { return 0 }
        let itm = Int(ceil(Double(fieldSize) * payoutPercent / 100.0))
        return playersRemaining - itm
    }

    var averageStackInBB: Double {
        guard let blinds = currentBlinds, blinds.bigBlind > 0 else { return 0 }
        return Double(averageStack) / Double(blinds.bigBlind)
    }
}
