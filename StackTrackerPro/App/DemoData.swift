import Foundation
import SwiftData

#if DEBUG
/// DEBUG-only demo world for App Store screenshots.
///
/// Activated by the `-DemoData` launch argument (with an optional
/// `-DemoRoute <name>` argument selecting which screen to pose), this seeds a
/// single, fully-populated active tournament into an in-memory `ModelContext`
/// so a capture script can drive the app to any of several screens without a
/// real CloudKit-backed store. See `StackTrackerProApp` for the container
/// swap that activates this, and
/// `docs/superpowers/plans/2026-07-11-screenshot-demo-mode.md` for the full
/// plan (Task 2 adds routing hooks; Task 3 adds the capture script).
///
/// All dates are computed relative to `Date.now` at seed time — never a
/// hardcoded absolute date — so a demo run always looks fresh.
@MainActor
enum DemoData {

    // MARK: - Launch arguments

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-DemoData")
    }

    /// The value of the argument immediately following `-DemoRoute`, if any.
    static var route: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-DemoRoute"), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    // MARK: - Seeded handles (Task 2/3 read these after `seed(into:)`)

    /// The single active tournament `seed(into:)` builds. `nil` until seeded;
    /// also doubles as the idempotency guard.
    static var activeTournament: Tournament?

    /// The "big win" saved hand (Level 11, hero BTN `Ks Kd`), exposed for the
    /// share-preview screenshot route.
    static var bigWinHand: Hand?

    /// The verbatim dictation transcript shared by hand 4's `notes` and the
    /// dictation-preview screenshot pose (Task 2).
    static let dictationPreviewTranscript = "I had ace queen of diamonds in the middle position, raised to seventy five hundred, big blind called. Flop came queen ten four with two clubs, he check called fifteen thousand. Turn was a king, we both checked. River blanked and he folded to my thirty thousand."

    // MARK: - Seed

    /// Populates `context` with a full demo world: one active tournament with
    /// a 16-level blind structure, 13 stack updates, field snapshots, a chat
    /// history, one pending stub, five saved hands, a fade note, plus
    /// completed tournament/cash-session history. Idempotent — a second call
    /// is a no-op (guarded by `activeTournament`), so re-entrant `.onAppear`
    /// seeding never duplicates data.
    static func seed(into context: ModelContext) {
        guard activeTournament == nil else { return }

        let now = Date.now
        let start = now.addingTimeInterval(-4.5 * 3600) // actualStartDate

        let t = Tournament(
            name: "$600 Ultra Stack",
            buyIn: 500,
            entryFee: 100,
            guarantee: 500_000,
            startDate: start,
            startingChips: 50_000
        )
        t.venueName = "Horseshoe Las Vegas"
        t.statusRaw = TournamentStatus.active.rawValue
        t.actualStartDate = start
        t.fieldSize = 2_481
        t.playersRemaining = 612
        context.insert(t)

        let displayToInternalLevel = seedBlindLevels(into: context, tournament: t)
        // Internal (sequential, breaks-counted) number for display "Level 12"
        // (1,500/3,000/3,000) — see task-1-report.md for why this differs
        // from the display number itself.
        t.currentBlindLevelNumber = displayToInternalLevel[12] ?? 12

        seedStackEntries(into: context, tournament: t, start: start, displayToInternalLevel: displayToInternalLevel)
        seedFieldSnapshots(into: context, tournament: t, now: now)
        seedChat(into: context, tournament: t, start: start, now: now)
        seedPendingStub(into: context, tournament: t)
        seedHands(into: context, tournament: t, start: start)
        seedFadeNote(into: context, tournament: t, now: now)
        seedHistory(into: context, now: now)

        activeTournament = t
    }

    // MARK: - Blind structure

    /// Builds 16 real levels (doubling roughly, L1 100/200/200 …
    /// L12 1,500/3,000/3,000 … L16 5,000/10,000/10,000) with 15-minute
    /// breaks after L4/L8/L12, numbered sequentially the way
    /// `BlindStructureParsing` numbers a scanned structure (the break itself
    /// consumes the next sequential `levelNumber`, same as a real level).
    /// Returns the display (1...16) → internal `levelNumber` map so callers
    /// can target a specific display level (e.g. for `currentBlindLevelNumber`
    /// or a `StackEntry.blindLevelNumber`, both of which are internal-numbered
    /// per the rest of the codebase).
    @discardableResult
    private static func seedBlindLevels(into context: ModelContext, tournament t: Tournament) -> [Int: Int] {
        struct Real { let sb: Int; let bb: Int; let ante: Int }
        let reals: [Real] = [
            Real(sb: 100, bb: 200, ante: 200),       // L1
            Real(sb: 150, bb: 300, ante: 300),       // L2
            Real(sb: 200, bb: 400, ante: 400),       // L3
            Real(sb: 300, bb: 500, ante: 500),       // L4
            Real(sb: 300, bb: 600, ante: 600),       // L5
            Real(sb: 400, bb: 800, ante: 800),       // L6
            Real(sb: 500, bb: 1_000, ante: 1_000),   // L7
            Real(sb: 600, bb: 1_200, ante: 1_200),   // L8
            Real(sb: 800, bb: 1_600, ante: 1_600),   // L9
            Real(sb: 1_000, bb: 2_000, ante: 2_000), // L10
            Real(sb: 1_200, bb: 2_500, ante: 2_500), // L11
            Real(sb: 1_500, bb: 3_000, ante: 3_000), // L12
            Real(sb: 2_000, bb: 4_000, ante: 4_000), // L13
            Real(sb: 2_500, bb: 5_000, ante: 5_000), // L14
            Real(sb: 3_000, bb: 6_000, ante: 6_000), // L15
            Real(sb: 5_000, bb: 10_000, ante: 10_000) // L16
        ]

        var internalNumber = 1
        var displayToInternal: [Int: Int] = [:]

        for (index, real) in reals.enumerated() {
            let displayNumber = index + 1
            let level = BlindLevel(levelNumber: internalNumber, smallBlind: real.sb,
                                    bigBlind: real.bb, ante: real.ante, durationMinutes: 30,
                                    isBreak: false)
            level.tournament = t
            context.insert(level)
            displayToInternal[displayNumber] = internalNumber
            internalNumber += 1

            if displayNumber == 4 || displayNumber == 8 || displayNumber == 12 {
                let brk = BlindLevel(levelNumber: internalNumber, smallBlind: 0, bigBlind: 0,
                                      ante: 0, durationMinutes: 15, isBreak: true, breakLabel: "Break")
                brk.tournament = t
                context.insert(brk)
                internalNumber += 1
            }
        }

        return displayToInternal
    }

    // MARK: - Stack entries

    private static func seedStackEntries(into context: ModelContext, tournament t: Tournament,
                                          start: Date, displayToInternalLevel: [Int: Int]) {
        struct Entry {
            let offsetMinutes: Double
            let chips: Int
            let displayLevel: Int
            let sb: Int
            let bb: Int
            let ante: Int
            let source: StackEntrySource
        }
        let entries: [Entry] = [
            Entry(offsetMinutes: 5, chips: 50_000, displayLevel: 1, sb: 100, bb: 200, ante: 200, source: .initial),
            Entry(offsetMinutes: 25, chips: 62_000, displayLevel: 2, sb: 150, bb: 300, ante: 300, source: .chat),
            Entry(offsetMinutes: 45, chips: 58_500, displayLevel: 3, sb: 200, bb: 400, ante: 400, source: .chat),
            Entry(offsetMinutes: 65, chips: 71_000, displayLevel: 4, sb: 300, bb: 500, ante: 500, source: .chat),
            Entry(offsetMinutes: 85, chips: 94_000, displayLevel: 5, sb: 300, bb: 600, ante: 600, source: .chat),
            Entry(offsetMinutes: 105, chips: 88_000, displayLevel: 6, sb: 400, bb: 800, ante: 800, source: .chat),
            Entry(offsetMinutes: 125, chips: 61_000, displayLevel: 7, sb: 500, bb: 1_000, ante: 1_000, source: .chat),
            Entry(offsetMinutes: 145, chips: 31_500, displayLevel: 8, sb: 600, bb: 1_200, ante: 1_200, source: .chat),
            Entry(offsetMinutes: 165, chips: 47_000, displayLevel: 9, sb: 800, bb: 1_600, ante: 1_600, source: .chat),
            Entry(offsetMinutes: 185, chips: 78_000, displayLevel: 10, sb: 1_000, bb: 2_000, ante: 2_000, source: .chat),
            Entry(offsetMinutes: 205, chips: 104_500, displayLevel: 11, sb: 1_200, bb: 2_500, ante: 2_500, source: .chat),
            Entry(offsetMinutes: 230, chips: 142_000, displayLevel: 12, sb: 1_500, bb: 3_000, ante: 3_000, source: .chat),
            Entry(offsetMinutes: 265, chips: 168_500, displayLevel: 12, sb: 1_500, bb: 3_000, ante: 3_000, source: .chat)
        ]

        for e in entries {
            let internalLevel = displayToInternalLevel[e.displayLevel] ?? e.displayLevel
            let stackEntry = StackEntry(
                timestamp: start.addingTimeInterval(e.offsetMinutes * 60),
                chipCount: e.chips,
                blindLevelNumber: internalLevel,
                currentSB: e.sb,
                currentBB: e.bb,
                currentAnte: e.ante,
                source: e.source
            )
            stackEntry.tournament = t
            context.insert(stackEntry)
        }
    }

    // MARK: - Field snapshots

    private static func seedFieldSnapshots(into context: ModelContext, tournament t: Tournament, now: Date) {
        let snapshots: [(offsetSeconds: TimeInterval, remaining: Int)] = [
            (-3 * 3600, 1_950),
            (-90 * 60, 1_240),
            (-10 * 60, 612)
        ]
        for s in snapshots {
            let snapshot = FieldSnapshot(timestamp: now.addingTimeInterval(s.offsetSeconds),
                                          totalEntries: 2_481, playersRemaining: s.remaining)
            snapshot.tournament = t
            context.insert(snapshot)
        }
    }

    // MARK: - Chat

    private static func seedChat(into context: ModelContext, tournament t: Tournament, start: Date, now: Date) {
        func add(_ text: String, sender: MessageSender, at date: Date, proactive: Bool = false) {
            let message = ChatMessage(timestamp: date, sender: sender, text: text, isProactive: proactive)
            message.tournament = t
            context.insert(message)
        }

        add("62k now", sender: .user, at: start.addingTimeInterval(25 * 60))
        add("✅ Stack updated to 62,000. M-ratio: 82.7 — Green Zone.", sender: .ai,
            at: start.addingTimeInterval(25 * 60 + 20))

        add("94k now", sender: .user, at: start.addingTimeInterval(85 * 60))
        add("✅ Stack updated to 94,000. M-ratio: 65.3 — Green Zone.", sender: .ai,
            at: start.addingTimeInterval(85 * 60 + 20))

        add("bounty collected", sender: .user, at: start.addingTimeInterval(150 * 60))
        add("🎯 Bounty secured! Nice work knocking someone out.", sender: .ai,
            at: start.addingTimeInterval(150 * 60 + 20))

        add("612 left", sender: .user, at: now.addingTimeInterval(-10 * 60))
        add("Field's down to 612 — you're well into the money zone. Keep grinding!", sender: .ai,
            at: now.addingTimeInterval(-10 * 60 + 20))

        add("I have 168k", sender: .user, at: start.addingTimeInterval(265 * 60))
        add("✅ Stack updated to 168,500. M-ratio: 22.4 — Green Zone.\n\nBig pot — +64,000 at Level 11. Log it? Just tell me your cards.",
            sender: .ai, at: start.addingTimeInterval(265 * 60 + 20), proactive: true)
    }

    // MARK: - Pending stub

    private static func seedPendingStub(into context: ModelContext, tournament t: Tournament) {
        let stub = HandStub(levelNumber: 12, smallBlind: 1_500, bigBlind: 3_000, ante: 3_000,
                             heroStackBefore: 168_500, playersRemaining: 612, holeCards: "As Ks",
                             origin: .manual)
        stub.tournament = t
        context.insert(stub)
    }

    // MARK: - Saved hands

    private static func seedHands(into context: ModelContext, tournament t: Tournament, start: Date) {
        seedBigWinHand(into: context, tournament: t, start: start)
        seedLossHand(into: context, tournament: t, start: start)
        seedPreflopFoldHand(into: context, tournament: t, start: start)
        seedDictatedOnlyHand(into: context, tournament: t, start: start)
        seedStructuredWithNotesHand(into: context, tournament: t, start: start)
    }

    private static func seedBigWinHand(into context: ModelContext, tournament t: Tournament, start: Date) {
        let hand = Hand(heroPosition: .btn, heroCardsRaw: "Ks Kd",
                         levelNumber: 11, smallBlind: 1_000, bigBlind: 2_000, ante: 2_000,
                         heroStackChips: 104_500, playersRemaining: 950, tableSize: 9)
        hand.timestamp = start.addingTimeInterval(205 * 60)
        hand.boardRaw = "Jh 8h 4d 2c 3s"
        hand.resultRaw = HandResult.won.rawValue
        hand.potSize = 142_000
        hand.amountWon = 64_000
        hand.tournament = t
        context.insert(hand)

        let actions: [(street: HandStreet, position: HeroPosition, type: HandActionType, amount: Int, isHero: Bool)] = [
            (.preflop, .utg, .raise, 7_000, false),
            (.preflop, .btn, .raise, 21_000, true),
            (.preflop, .utg, .call, 21_000, false),
            (.flop, .utg, .check, 0, false),
            (.flop, .btn, .bet, 24_000, true),
            (.flop, .utg, .call, 24_000, false),
            (.turn, .utg, .check, 0, false),
            (.turn, .btn, .check, 0, true),
            (.river, .utg, .bet, 46_000, false),
            (.river, .btn, .call, 46_000, true)
        ]
        for (i, a) in actions.enumerated() {
            let action = HandAction(orderIndex: i, street: a.street, position: a.position,
                                     actionType: a.type, amount: a.amount, isHero: a.isHero)
            action.hand = hand
            context.insert(action)
        }

        let villain = HandVillain(orderIndex: 0, position: .utg, relativeStack: .coversHero, approxStack: 210_000)
        villain.shownHolding = "9h Th"
        villain.hand = hand
        context.insert(villain)

        bigWinHand = hand
    }

    private static func seedLossHand(into context: ModelContext, tournament t: Tournament, start: Date) {
        let hand = Hand(heroPosition: .co, heroCardsRaw: "Ah Qh",
                         levelNumber: 9, smallBlind: 800, bigBlind: 1_600, ante: 1_600,
                         heroStackChips: 47_000, playersRemaining: 1_450, tableSize: 9)
        hand.timestamp = start.addingTimeInterval(165 * 60)
        hand.boardRaw = "Kd 9c 4h"
        hand.resultRaw = HandResult.lost.rawValue
        hand.potSize = 61_000
        hand.amountWon = -28_000
        hand.tournament = t
        context.insert(hand)

        let actions: [(street: HandStreet, position: HeroPosition, type: HandActionType, amount: Int, isHero: Bool)] = [
            (.preflop, .utg, .raise, 3_600, false),
            (.preflop, .co, .call, 3_600, true),
            (.flop, .utg, .bet, 5_000, false),
            (.flop, .co, .call, 5_000, true)
        ]
        for (i, a) in actions.enumerated() {
            let action = HandAction(orderIndex: i, street: a.street, position: a.position,
                                     actionType: a.type, amount: a.amount, isHero: a.isHero)
            action.hand = hand
            context.insert(action)
        }
    }

    private static func seedPreflopFoldHand(into context: ModelContext, tournament t: Tournament, start: Date) {
        let hand = Hand(heroPosition: .utg, heroCardsRaw: "7c 2d",
                         levelNumber: 10, smallBlind: 1_000, bigBlind: 2_000, ante: 2_000,
                         heroStackChips: 78_000, playersRemaining: 1_240, tableSize: 9)
        hand.timestamp = start.addingTimeInterval(185 * 60)
        hand.resultRaw = HandResult.folded.rawValue
        hand.tournament = t
        context.insert(hand)

        let fold = HandAction(orderIndex: 0, street: .preflop, position: .utg,
                               actionType: .fold, amount: 0, isHero: true)
        fold.hand = hand
        context.insert(fold)
    }

    private static func seedDictatedOnlyHand(into context: ModelContext, tournament t: Tournament, start: Date) {
        let hand = Hand(heroPosition: .mp, heroCardsRaw: "Ad Qd",
                         levelNumber: 12, smallBlind: 1_500, bigBlind: 3_000, ante: 3_000,
                         heroStackChips: 142_000, playersRemaining: 700, tableSize: 9)
        hand.timestamp = start.addingTimeInterval(230 * 60)
        hand.notes = dictationPreviewTranscript
        // resultRaw stays at its model default (Hand.resultRaw = .folded raw
        // value) — no result was ever booked for a dictated-only hand.
        hand.tournament = t
        context.insert(hand)
    }

    private static func seedStructuredWithNotesHand(into context: ModelContext, tournament t: Tournament, start: Date) {
        let hand = Hand(heroPosition: .sb, heroCardsRaw: "9s 9c",
                         levelNumber: 8, smallBlind: 600, bigBlind: 1_200, ante: 1_200,
                         heroStackChips: 31_500, playersRemaining: 1_650, tableSize: 9)
        hand.timestamp = start.addingTimeInterval(145 * 60)
        hand.boardRaw = "8h 4c 2s"
        hand.resultRaw = HandResult.won.rawValue
        hand.potSize = 24_000
        hand.amountWon = 22_000
        hand.notes = "Villain was steaming after losing the last pot."
        hand.tournament = t
        context.insert(hand)

        let actions: [(street: HandStreet, position: HeroPosition, type: HandActionType, amount: Int, isHero: Bool)] = [
            (.preflop, .bb, .raise, 2_400, false),
            (.preflop, .sb, .call, 2_400, true),
            (.flop, .bb, .check, 0, false),
            (.flop, .sb, .bet, 3_000, true),
            (.flop, .bb, .fold, 0, false)
        ]
        for (i, a) in actions.enumerated() {
            let action = HandAction(orderIndex: i, street: a.street, position: a.position,
                                     actionType: a.type, amount: a.amount, isHero: a.isHero)
            action.hand = hand
            context.insert(action)
        }
    }

    // MARK: - Fade note

    private static func seedFadeNote(into context: ModelContext, tournament t: Tournament, now: Date) {
        let fade = FadeNote(intervalStart: now.addingTimeInterval(-70 * 60),
                             intervalEnd: now.addingTimeInterval(-55 * 60),
                             chipDelta: -27_000,
                             userExplanation: "Lost a flip with AK against tens, then paid off a river bet.")
        fade.tournament = t
        context.insert(fade)
    }

    // MARK: - History

    private static func seedHistory(into context: ModelContext, now: Date) {
        // Brief split: FIVE cashes (finishPosition + payout > 0, including the
        // 1st-place $8,400 on the $600 buy-in) and THREE busts (payout 0, no
        // finishPosition). Net across everything stays clearly positive.
        struct Historical {
            let name: String
            let venue: String
            let daysAgo: Double
            let buyIn: Int
            let finishPosition: Int?
            let payout: Int
        }
        let historicalTournaments: [Historical] = [
            Historical(name: "Deepstack Daily", venue: "Horseshoe Las Vegas", daysAgo: 90, buyIn: 250, finishPosition: nil, payout: 0),
            Historical(name: "Wynn Summer Classic", venue: "Wynn Las Vegas", daysAgo: 75, buyIn: 300, finishPosition: 12, payout: 950),
            Historical(name: "Texas Hold'em Open", venue: "Champions Club Texas", daysAgo: 60, buyIn: 400, finishPosition: nil, payout: 0),
            Historical(name: "$600 Championship", venue: "Horseshoe Las Vegas", daysAgo: 50, buyIn: 600, finishPosition: 1, payout: 8_400),
            Historical(name: "Sunday Special", venue: "Wynn Las Vegas", daysAgo: 40, buyIn: 250, finishPosition: nil, payout: 0),
            Historical(name: "High Roller", venue: "Champions Club Texas", daysAgo: 30, buyIn: 1_700, finishPosition: 25, payout: 3_200),
            Historical(name: "Mid-Week Grind", venue: "Horseshoe Las Vegas", daysAgo: 18, buyIn: 500, finishPosition: 8, payout: 1_450),
            Historical(name: "Weekend Warm-Up", venue: "Wynn Las Vegas", daysAgo: 7, buyIn: 350, finishPosition: 18, payout: 600)
        ]

        for h in historicalTournaments {
            let startDate = now.addingTimeInterval(-h.daysAgo * 24 * 3600)
            let tournament = Tournament(name: h.name, buyIn: h.buyIn, startDate: startDate, startingChips: 25_000)
            tournament.venueName = h.venue
            tournament.statusRaw = TournamentStatus.completed.rawValue
            tournament.actualStartDate = startDate
            tournament.fieldSize = 200
            tournament.playersRemaining = 0
            tournament.finishPosition = h.finishPosition
            tournament.payout = h.payout
            tournament.endDate = startDate.addingTimeInterval(6 * 3600)
            context.insert(tournament)
        }

        struct HistoricalCash {
            let daysAgo: Double
            let cashOut: Int
        }
        let historicalCashSessions: [HistoricalCash] = [
            HistoricalCash(daysAgo: 45, cashOut: 1_850),
            HistoricalCash(daysAgo: 20, cashOut: 720),
            HistoricalCash(daysAgo: 10, cashOut: 2_400)
        ]

        for c in historicalCashSessions {
            let date = now.addingTimeInterval(-c.daysAgo * 24 * 3600)
            let session = CashSession(stakes: "2/5", buyInTotal: 1_000, venueName: "Horseshoe Las Vegas", date: date)
            session.statusRaw = SessionStatus.completed.rawValue
            session.cashOut = c.cashOut
            session.endTime = date.addingTimeInterval(4 * 3600)
            context.insert(session)
        }
    }

    // MARK: - Mid-hand pose (Task 2's HandCaptureView.onAppear hook)

    /// Poses `model` mid-hand: hero BTN `Ks Kd` at Level 12, three streets in,
    /// awaiting hero's response to a live flop bet. Uses only
    /// `HandCaptureModel`'s existing public mutation surface (no engine
    /// changes). Turn order is verified against `HandCaptureModel`'s
    /// `streetOrder`: `tableOrder` places `.utg` before `.btn` both preflop
    /// (sorted by seat index) and postflop (sorted by distance from the SB
    /// seat), so UTG acts first on every street below and the pose correctly
    /// ends with the flop bet pending on hero.
    static func poseMidHand(_ model: HandCaptureModel) {
        model.setLevel(number: 12, smallBlind: 1_500, bigBlind: 3_000, ante: 3_000)
        model.heroStackBefore = 168_500
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Ks Kd") { _ = model.addCard(c) }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 210_000)
        model.add(action: .raise, toAmount: 7_000)      // UTG (villain acts first preflop)
        model.add(action: .call, toAmount: 0)           // hero BTN closes preflop
        for c in PlayingCard.parseList("Jh 8h 4d") { _ = model.addBoardCard(c) }
        model.add(action: .bet, toAmount: 12_000)       // UTG leads flop → hero's decision is live
    }
}
#endif
