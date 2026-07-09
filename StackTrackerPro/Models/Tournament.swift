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

    // Add-on (all gated on addOnAvailable; CloudKit-safe defaults)
    var addOnAvailable: Bool = false
    var addOnCost: Int = 0          // total price (e.g. 100)
    var addOnRake: Int = 0          // house cut (e.g. 10)
    var addOnChips: Int = 0         // chips granted per add-on (e.g. 30,000)
    var addOnsCount: Int = 0        // field-wide add-ons taken; observed/editable
    var playerAddOnsUsed: Int = 0   // add-ons the player took; feeds investment

    // Status
    var statusRaw: String = "setup"
    var finishPosition: Int?
    var payout: Int?
    var bountiesCollected: Int = 0

    // Timing (CloudKit-safe defaults)
    var actualStartDate: Date?
    var accumulatedPauseSeconds: Int = 0
    var pausedAt: Date?

    // Ante format (big-blind ante by default; see AnteFormat)
    var anteFormatRaw: String = AnteFormat.bigBlind.rawValue

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

    @Relationship(deleteRule: .cascade, inverse: \TournamentEvent.tournament)
    var events: [TournamentEvent]? = []

    @Relationship(deleteRule: .cascade, inverse: \Hand.tournament)
    var hands: [Hand]? = []

    @Relationship(deleteRule: .cascade, inverse: \HandStub.tournament)
    var handStubs: [HandStub]? = []

    @Relationship(deleteRule: .cascade, inverse: \FadeNote.tournament)
    var fadeNotes: [FadeNote]? = []

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
        self.actualStartDate = nil
        self.accumulatedPauseSeconds = 0
        self.pausedAt = nil
        self.anteFormatRaw = AnteFormat.bigBlind.rawValue
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

    var anteFormat: AnteFormat {
        get { AnteFormat(rawValue: anteFormatRaw) ?? .bigBlind }
        set { anteFormatRaw = newValue.rawValue }
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

    var sortedEvents: [TournamentEvent] {
        (events ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    var sortedHands: [Hand] {
        (hands ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    var pendingStubs: [HandStub] {
        (handStubs ?? [])
            .filter { $0.status == .pending }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var sortedFadeNotes: [FadeNote] {
        (fadeNotes ?? []).sorted { $0.intervalStart < $1.intervalStart }
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
        // Use the single source of truth so add-on chips are included.
        return totalChipsInPlay / playersRemaining
    }

    var totalInvestment: Int {
        buyIn * (1 + rebuysUsed) + (addOnAvailable ? playerAddOnsUsed * addOnCost : 0)
    }

    /// Per-add-on amount that goes to the prize pool (price minus house cut).
    var addOnToPrizePool: Int {
        max(0, addOnCost - addOnRake)
    }

    /// Total prize-pool money contributed by add-ons across the field.
    private var addOnPrizePoolTotal: Int {
        addOnAvailable ? addOnsCount * addOnToPrizePool : 0
    }

    /// Total bounty winnings. Prefers persisted per-event amounts (supports
    /// variable/PKO bounties); falls back to count × flat amount for legacy data.
    var bountyWinnings: Int {
        if let events = bountyEvents, !events.isEmpty {
            return events.reduce(0) { $0 + $1.amount }
        }
        return bountiesCollected * bountyAmount
    }

    var profit: Int? {
        guard let payout else { return nil }
        return payout + bountyWinnings - totalInvestment
    }

    /// Seconds of active play between the effective start and `reference`,
    /// excluding accumulated (and any in-flight) pause time. Never negative.
    private func activeSeconds(until reference: Date) -> TimeInterval {
        let start = actualStartDate ?? startDate
        var elapsed = reference.timeIntervalSince(start)
        elapsed -= TimeInterval(accumulatedPauseSeconds)
        if let pausedAt, status == .paused {
            elapsed -= reference.timeIntervalSince(pausedAt)
        }
        return max(0, elapsed)
    }

    var duration: TimeInterval? {
        guard let end = endDate else { return nil }
        return activeSeconds(until: end)
    }

    var durationFormatted: String {
        let elapsed = duration ?? activeSeconds(until: .now)
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

    /// Per-player contribution to the prize pool (total buy-in minus rake,
    /// bounty, and other deductions). Never negative.
    var prizePoolContributionPerPlayer: Int {
        max(0, buyIn - entryFee - bountyAmount - deductions)
    }

    var prizePool: Int {
        prizePoolContributionPerPlayer * fieldSize + addOnPrizePoolTotal
    }

    var houseRake: Int {
        entryFee * fieldSize + (addOnAvailable ? addOnsCount * addOnRake : 0)
    }

    var overlay: Int {
        guard guarantee > 0 else { return 0 }
        return max(0, guarantee - prizePool)
    }

    var playersNeededForGuarantee: Int {
        let prizePoolPerPlayer = prizePoolContributionPerPlayer
        guard guarantee > 0, prizePoolPerPlayer > 0 else { return 0 }
        // Add-on money already in the pool reduces the buy-ins still needed.
        let remaining = max(0, guarantee - addOnPrizePoolTotal)
        let needed = Int(ceil(Double(remaining) / Double(prizePoolPerPlayer))) - fieldSize
        return max(0, needed)
    }

    var totalChipsInPlay: Int {
        fieldSize * startingChips + (addOnAvailable ? addOnsCount * addOnChips : 0)
    }

    /// Number of paid finishing positions, derived from the payout
    /// percentage. 0 until both field size and payout % are known.
    var paidSpots: Int {
        guard fieldSize > 0, payoutPercent > 0 else { return 0 }
        return Int(ceil(Double(fieldSize) * payoutPercent / 100.0))
    }

    /// Players left until the money bubble. 0 once in the money.
    var estimatedBubbleDistance: Int {
        let itm = paidSpots
        guard itm > 0 else { return 0 }
        return max(0, playersRemaining - itm)
    }

    /// Projected average stack at the moment the money bubble bursts. Chips
    /// never leave a tournament, so when the field is reduced to exactly the
    /// paid spots, the average stack is all chips in play spread across those
    /// seats. A useful target: a stack near or above this number coasts into
    /// the money. 0 until field size and payout % are known.
    ///
    /// Assumes `fieldSize` reflects total entries; in re-entry events the
    /// extra chips beyond the tracked field size aren't counted.
    var averageStackAtBubble: Int {
        let spots = paidSpots
        guard spots > 0 else { return 0 }
        return totalChipsInPlay / spots
    }

    /// Seats at a standard full-ring final table.
    static let finalTableSeats = 9

    /// Projected average stack at a 9-handed final table: all chips in play
    /// spread across the final 9 seats. 0 until field size is known, or when
    /// the field is smaller than a full final table.
    ///
    /// Same assumption as `averageStackAtBubble`: `fieldSize` is treated as
    /// total entries.
    var averageStackAtFinalTable: Int {
        guard fieldSize >= Self.finalTableSeats else { return 0 }
        return totalChipsInPlay / Self.finalTableSeats
    }

    var averageStackInBB: Double {
        guard let blinds = currentBlinds, blinds.bigBlind > 0 else { return 0 }
        return Double(averageStack) / Double(blinds.bigBlind)
    }
}
