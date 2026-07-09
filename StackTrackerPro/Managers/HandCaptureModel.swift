import Foundation
import Observation
import SwiftData

/// Core engine behind the Hand Capture screen (Hand Logging v2, Phase B).
///
/// Models a single hand as an ordered log of *inputs* (participant actions and
/// board cards). Every piece of derived state — turn order, the betting ledger,
/// the pot, street progression, whose turn it is — is recomputed from scratch by
/// a single private `rebuild()` that replays the log. There is no incremental
/// mutation, so `undoLast()` / `truncate(toLedgerIndex:)` are trivially correct:
/// they drop inputs and replay.
///
/// Only the hero plus explicitly-added villains are participants. Every other
/// seat is treated as already folded ("folds to us" costs zero taps); their
/// blinds, when no participant occupies the seat, are counted as dead money in
/// the pot.
@MainActor @Observable
final class HandCaptureModel {

    // MARK: - Public types

    struct VillainDraft: Identifiable, Equatable {
        let id: UUID
        var position: HeroPosition
        var relative: RelativeStack
        var approxStack: Int              // 0 = unset
        var shownHolding: [PlayingCard]
        var mucked: Bool
    }

    enum Participant: Equatable, Hashable { case hero, villain(UUID) }

    struct LedgerEntry: Identifiable, Equatable {
        let id: UUID
        let street: HandStreet
        let participant: Participant
        let action: HandActionType
        let toAmount: Int                 // committed total on that street after this action
    }

    // MARK: - Context (immutable after init)

    let levelNumber: Int
    let smallBlind: Int
    let bigBlind: Int
    let ante: Int
    let heroCardCount: Int                // 2 (NLHE) or 4 (PLO)
    var heroStackBefore: Int              // editable, prefilled

    /// True when this capture is enriching an existing `HandStub` (vs a fresh
    /// Log Hand capture). Drives `shouldPushStackUpdate`.
    let isStubEnrichment: Bool
    /// The tracker's `latestStack` chip count when this capture opened. `nil`
    /// for a fresh capture (no stub to compare against). Drives
    /// `shouldPushStackUpdate`.
    let trackerStackAtOpen: Int?

    // MARK: - Setup state

    var heroPosition: HeroPosition? { didSet { rebuild() } }
    var heroCards: [PlayingCard] = []
    private(set) var villains: [VillainDraft] = []

    // MARK: - Result flow state

    /// Manual ruling that supersedes `computedWinners` everywhere (chops, odd
    /// rulings, dealer corrections). `nil` = trust the computed result.
    var winnerOverride: Set<Participant>?

    /// Free-form review tags: "Cooler", "Bluff", "Value", "Hero call", "Punt?".
    var selectedTags: Set<String> = []

    /// Stable id used to represent the hero inside `PokerHandEvaluator.holdemWinners`
    /// (which is keyed by UUID). Distinct from every villain's id.
    private let heroSentinel = UUID()

    // MARK: - Derived state (recomputed by rebuild())

    private(set) var ledger: [LedgerEntry] = []
    private(set) var board: [PlayingCard] = []
    private(set) var currentStreet: HandStreet = .preflop
    private(set) var boardCardsNeeded = 0
    private(set) var participantToAct: Participant?
    private(set) var currentBet = 0
    private(set) var isHandOver = false
    private(set) var foldedParticipants: Set<Participant> = []
    private(set) var allInParticipants: Set<Participant> = []
    private(set) var committedByStreet: [HandStreet: [Participant: Int]] = [:]
    var potOverride: Int?

    // MARK: - Input log

    private enum Input {
        case action(id: UUID, Participant, HandActionType, Int)
        case boardCard(PlayingCard)
    }
    private var inputs: [Input] = []

    /// Table seat order, used to derive turn order on every street.
    static let tableOrder: [HeroPosition] = [.utg, .utg1, .mp, .lj, .hj, .co, .btn, .sb, .bb]

    // MARK: - Init

    init(levelNumber: Int, smallBlind: Int, bigBlind: Int, ante: Int,
         heroCardCount: Int, heroStackBefore: Int,
         isStubEnrichment: Bool = false, trackerStackAtOpen: Int? = nil) {
        self.levelNumber = levelNumber
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
        self.ante = ante
        self.heroCardCount = heroCardCount
        self.heroStackBefore = heroStackBefore
        self.isStubEnrichment = isStubEnrichment
        self.trackerStackAtOpen = trackerStackAtOpen
        rebuild()
    }

    /// Seeds a capture from a `HandStub`: copies the level/blinds/ante/stack
    /// snapshot and prefills the hero's hole cards only when the stub stored
    /// exact cards (`"Ah Kd"`). Suit-agnostic stubs (`"KQs"`, `"99"`) leave the
    /// cards empty; the view surfaces the token as a hint instead.
    convenience init(stub: HandStub, heroCardCount: Int, trackerStackAtOpen: Int? = nil) {
        self.init(levelNumber: stub.levelNumber, smallBlind: stub.smallBlind,
                  bigBlind: stub.bigBlind, ante: stub.ante,
                  heroCardCount: heroCardCount, heroStackBefore: stub.heroStackBefore,
                  isStubEnrichment: true, trackerStackAtOpen: trackerStackAtOpen)
        let exact = HoleCardShorthand.exactCards(stub.holeCards)
        if exact.count == 2 { heroCards = exact }
    }

    // MARK: - Participants

    /// Ordered participants: hero (once a position is chosen) plus every villain.
    private var participants: [Participant] {
        var result: [Participant] = []
        if heroPosition != nil { result.append(.hero) }
        result.append(contentsOf: villains.map { .villain($0.id) })
        return result
    }

    private func position(of participant: Participant) -> HeroPosition? {
        switch participant {
        case .hero: return heroPosition
        case .villain(let id): return villains.first { $0.id == id }?.position
        }
    }

    /// The participant occupying `seat`, if any.
    private func participant(at seat: HeroPosition) -> Participant? {
        participants.first { position(of: $0) == seat }
    }

    private func tableIndex(_ participant: Participant) -> Int {
        guard let pos = position(of: participant),
              let idx = Self.tableOrder.firstIndex(of: pos) else { return .max }
        return idx
    }

    /// Participants in the order they act on `street`. Preflop starts with the
    /// first seat after the big blind (i.e. UTG, wrapping); postflop starts at
    /// the small blind and proceeds clockwise.
    private func streetOrder(_ street: HandStreet) -> [Participant] {
        let parts = participants
        if street == .preflop {
            return parts.sorted { tableIndex($0) < tableIndex($1) }
        }
        let sbIndex = Self.tableOrder.firstIndex(of: .sb) ?? 7
        func key(_ p: Participant) -> Int { (tableIndex(p) - sbIndex + Self.tableOrder.count) % Self.tableOrder.count }
        return parts.sorted { key($0) < key($1) }
    }

    // MARK: - Setup mutations

    func addVillain(position: HeroPosition, relative: RelativeStack, approxStack: Int) {
        villains.append(VillainDraft(id: UUID(), position: position, relative: relative,
                                     approxStack: approxStack, shownHolding: [], mucked: false))
        rebuild()
    }

    /// Removes a villain. If the villain had recorded actions, those inputs are
    /// dropped too — replay then recomputes the pot, ledger, and turn order as if
    /// the villain had never been in the hand. Safe because nothing is mutated
    /// incrementally; the log is simply shorter.
    func removeVillain(id: UUID) {
        villains.removeAll { $0.id == id }
        inputs.removeAll { input in
            if case .action(_, .villain(let vid), _, _) = input { return vid == id }
            return false
        }
        rebuild()
    }

    /// Adds a hero hole card. Rejects already-dealt cards and respects the
    /// `heroCardCount` cap. Hero cards are setup state, not part of the input log.
    @discardableResult
    func addCard(_ card: PlayingCard) -> Bool {
        guard heroCards.count < heroCardCount, !dealtCards.contains(card) else { return false }
        heroCards.append(card)
        return true
    }

    // MARK: - Live mutations

    /// Records `action` for whoever is currently to act. `toAmount` is ignored
    /// for fold/check. No-op when it is nobody's turn (hand over / awaiting board).
    func add(action: HandActionType, toAmount: Int) {
        guard let actor = participantToAct else { return }
        inputs.append(.action(id: UUID(), actor, action, toAmount))
        rebuild()
    }

    /// Adds a board card. Rejects duplicates and cards added when none are needed.
    @discardableResult
    func addBoardCard(_ card: PlayingCard) -> Bool {
        guard boardCardsNeeded > 0, !dealtCards.contains(card) else { return false }
        inputs.append(.boardCard(card))
        rebuild()
        return true
    }

    func undoLast() {
        guard !inputs.isEmpty else { return }
        inputs.removeLast()
        rebuild()
    }

    /// Drops the ledger entry at `index` and every input after it (later actions
    /// and board cards), then replays.
    func truncate(toLedgerIndex index: Int) {
        guard index >= 0, index < ledger.count else { return }
        var actionCount = 0
        var cut = inputs.count
        for (j, input) in inputs.enumerated() {
            if case .action = input {
                if actionCount == index { cut = j; break }
                actionCount += 1
            }
        }
        inputs.removeSubrange(cut...)
        rebuild()
    }

    // MARK: - Derived reads

    /// Live pot: the ante, plus any blinds whose seat has no participant (dead
    /// money), plus every participant's committed total across all streets. When
    /// a blind seat *is* a participant, its posted blind is already inside their
    /// preflop committed total, so it is not double-counted. `potOverride` wins.
    var pot: Int {
        if let potOverride { return potOverride }
        var total = ante
        if participant(at: .sb) == nil { total += smallBlind }
        if participant(at: .bb) == nil { total += bigBlind }
        for (_, streetMap) in committedByStreet {
            for (_, amount) in streetMap { total += amount }
        }
        return total
    }

    /// Actions offered to the participant to act. Empty when it is nobody's turn.
    var legalActions: [HandActionType] {
        guard let actor = participantToAct else { return [] }
        let committed = committedByStreet[currentStreet]?[actor] ?? 0
        var actions: [HandActionType] = [.fold]
        if committed == currentBet {
            actions.append(.check)
        } else {
            actions.append(.call)
        }
        if currentBet == 0 {
            actions.append(.bet)
        } else {
            // Something to match already exists (a bet, or the big blind
            // preflop): the aggressive option is a raise.
            actions.append(.raise)
        }
        actions.append(.allIn)
        return actions
    }

    /// All cards known to be in play: hero, board, and any shown villain holdings.
    var dealtCards: Set<PlayingCard> {
        var set = Set(heroCards)
        set.formUnion(board)
        for villain in villains { set.formUnion(villain.shownHolding) }
        return set
    }

    func label(for participant: Participant) -> String {
        switch participant {
        case .hero:
            return "Hero (\(heroPosition?.rawValue ?? "?"))"
        case .villain(let id):
            guard let villain = villains.first(where: { $0.id == id }) else { return "?" }
            let relative: String
            switch villain.relative {
            case .coversHero: relative = "covers"
            case .similar: relative = "~same"
            case .shorter: relative = "short"
            }
            return "\(villain.position.rawValue) (\(relative))"
        }
    }

    /// Compact "what's happened so far" recap for the narration bar: level and
    /// blinds, hero's seat/cards/stack, then one segment per street with its
    /// board cards (once dealt) and the actions taken on it. Pure string
    /// composition over already-computed state; no new derivation happens
    /// here. The pot is intentionally omitted — it has its own chip in the UI.
    var narration: String {
        var parts: [String] = []

        let game = heroCardCount == 4 ? "PLO" : "NLHE"
        var header = "\(game) L\(levelNumber) \(smallBlind.formatted())/\(bigBlind.formatted())"
        if ante > 0 { header += "(\(ante.formatted()))" }
        parts.append(header)

        if let heroPosition {
            var heroPart = "Hero \(heroPosition.rawValue)"
            if !heroCards.isEmpty {
                heroPart += " " + heroCards.map(\.display).joined()
            }
            heroPart += " (\(heroStackBefore.formatted()))"
            parts.append(heroPart)
        }

        for street in HandStreet.allCases {
            let entries = ledger.filter { $0.street == street }
            let streetBoard = boardCards(for: street)
            guard !entries.isEmpty || !streetBoard.isEmpty else { continue }

            var streetPart = street.label.uppercased()
            if !streetBoard.isEmpty {
                streetPart += " " + streetBoard.map(\.display).joined()
            }
            if !entries.isEmpty {
                let separator = streetBoard.isEmpty ? " " : " — "
                streetPart += separator + entries.map(describe).joined(separator: ", ")
            }
            parts.append(streetPart)
        }

        return parts.joined(separator: " · ")
    }

    /// The board cards revealed as of `street` (flop = first three, turn/river
    /// = the single card added on that street). Empty until enough cards have
    /// actually been dealt.
    private func boardCards(for street: HandStreet) -> [PlayingCard] {
        switch street {
        case .preflop: return []
        case .flop: return board.count >= 3 ? Array(board[0..<3]) : []
        case .turn: return board.count >= 4 ? [board[3]] : []
        case .river: return board.count >= 5 ? [board[4]] : []
        }
    }

    /// Short actor label for narration lines: bare "Hero" (the fuller
    /// "Hero (BTN)" form from `label(for:)` would duplicate the hero segment).
    private func actorLabel(_ participant: Participant) -> String {
        switch participant {
        case .hero: return "Hero"
        case .villain: return label(for: participant)
        }
    }

    private func describe(_ entry: LedgerEntry) -> String {
        let actor = actorLabel(entry.participant)
        switch entry.action {
        case .fold: return "\(actor) folds"
        case .check: return "\(actor) checks"
        case .call: return "\(actor) calls \(entry.toAmount.formatted())"
        case .bet: return "\(actor) bets \(entry.toAmount.formatted())"
        case .raise: return "\(actor) raises to \(entry.toAmount.formatted())"
        case .allIn: return "\(actor) is all-in for \(entry.toAmount.formatted())"
        }
    }

    // MARK: - Showdown / result flow

    /// Sets a villain's shown holding (exactly two cards for a hold'em read).
    /// A shown holding is *not* a betting action, so it never enters the input
    /// log — it only annotates the draft and feeds `computedWinners`/`dealtCards`.
    func setShownHolding(_ cards: [PlayingCard], for id: UUID) {
        guard let idx = villains.firstIndex(where: { $0.id == id }) else { return }
        villains[idx].shownHolding = cards
        villains[idx].mucked = false
    }

    /// Marks a villain as having mucked: they showed nothing, so they cannot win
    /// a showdown. Clears any previously entered holding.
    func setMucked(_ id: UUID) {
        guard let idx = villains.firstIndex(where: { $0.id == id }) else { return }
        villains[idx].shownHolding = []
        villains[idx].mucked = true
    }

    /// Participants who have not folded (the hero plus every villain still live).
    private var nonFoldedParticipants: [Participant] {
        participants.filter { !foldedParticipants.contains($0) }
    }

    /// True when the hand is over with two or more players still live — a real
    /// showdown that needs shown cards (or a manual ruling) to decide.
    var needsShowdown: Bool {
        isHandOver && nonFoldedParticipants.count >= 2
    }

    /// The live participants at a showdown; empty when no showdown is required.
    var showdownParticipants: [Participant] {
        needsShowdown ? nonFoldedParticipants : []
    }

    /// The last participant to bet/raise/all-in, i.e. the aggressor who closed a
    /// no-showdown pot when everyone else folded.
    private var lastAggressor: Participant? {
        for entry in ledger.reversed() {
            switch entry.action {
            case .bet, .raise, .allIn: return entry.participant
            default: continue
            }
        }
        return nil
    }

    /// Winners derived purely from the recorded hand:
    /// - not over → empty;
    /// - no showdown → the last aggressor, else the lone survivor;
    /// - showdown → `holdemWinners` over the hero plus every villain who showed
    ///   exactly two cards (mucked/unknown villains are excluded — a villain who
    ///   didn't show loses; if *all* villains muck the hero wins).
    ///
    /// Empty when unevaluable (board not yet five cards, PLO four-card holdings,
    /// or hero cards missing) — the UI then requires a manual `winnerOverride`.
    var computedWinners: [Participant] {
        guard isHandOver else { return [] }

        if !needsShowdown {
            if let aggressor = lastAggressor { return [aggressor] }
            let survivors = nonFoldedParticipants
            return survivors.count == 1 ? survivors : []
        }

        // Hold'em showdown only; PLO or missing/incomplete cards are unevaluable.
        guard heroCardCount == 2, heroCards.count == 2, board.count == 5 else { return [] }
        var holdings: [(id: UUID, cards: [PlayingCard])] = [(heroSentinel, heroCards)]
        for villain in villains
        where !foldedParticipants.contains(.villain(villain.id)) && villain.shownHolding.count == 2 {
            holdings.append((villain.id, villain.shownHolding))
        }
        let winnerIDs = PokerHandEvaluator.holdemWinners(board: board, holdings: holdings)
        return winnerIDs.map { $0 == heroSentinel ? .hero : .villain($0) }
    }

    /// The winners that actually decide the pot: the manual override when set,
    /// otherwise `computedWinners`.
    var effectiveWinners: Set<Participant> {
        if let winnerOverride { return winnerOverride }
        return Set(computedWinners)
    }

    /// True when the hand can be saved without booking a silently-wrong
    /// result. Gates the Save button:
    /// - the hand must be over;
    /// - no showdown → always resolvable (the fold-out winner is unambiguous);
    /// - showdown → a manual `winnerOverride` settles anything; otherwise
    ///   every still-live villain must be resolved (a two-card shown holding
    ///   or an explicit muck) AND `computedWinners` must actually evaluate to
    ///   something. The second clause matters for unevaluable showdowns (PLO,
    ///   missing hero cards): without it, `heroNet` would book an automatic
    ///   hero loss even though no winner was ever determined.
    var isResolvable: Bool {
        guard isHandOver else { return false }
        if !needsShowdown { return true }
        if winnerOverride != nil { return true }
        let villainsResolved = villains.allSatisfy { villain in
            foldedParticipants.contains(.villain(villain.id))
                || villain.mucked || villain.shownHolding.count == 2
        }
        return villainsResolved && !computedWinners.isEmpty
    }

    /// True when `participant` has at least one recorded betting action.
    /// The UI uses this to lock a villain's seat/stack editing (edit is
    /// remove-and-re-add, which would silently drop their ledger entries)
    /// and to warn before removal.
    func hasActed(_ participant: Participant) -> Bool {
        ledger.contains { $0.participant == participant }
    }

    /// Total chips the hero put in the pot: everything committed across streets,
    /// plus the ante when the hero sits in the big blind (the BB-ante model
    /// posts the single table ante from the BB seat).
    private var heroContribution: Int {
        var total = 0
        for (_, streetMap) in committedByStreet { total += streetMap[.hero] ?? 0 }
        if heroPosition == .bb { total += ante }
        return total
    }

    /// Hero's net for the hand: pot share if the hero is among the effective
    /// winners (winners split equally by integer division; any remainder goes to
    /// the hero when the hero wins), minus the hero's total contribution.
    var heroNet: Int {
        let winners = effectiveWinners
        let contribution = heroContribution
        guard !winners.isEmpty else { return -contribution }
        let share = pot / winners.count
        let remainder = pot % winners.count
        let heroShare = winners.contains(.hero) ? share + remainder : 0
        return heroShare - contribution
    }

    /// Hero's stack once the hand is booked.
    var heroStackAfter: Int { heroStackBefore + heroNet }

    /// Whether saving this hand should push a tracker `updateStack`.
    ///
    /// Rule: push only when the hand is *current* —
    ///   `stub == nil || tournament.latestStack == model.heroStackBefore`
    /// A fresh Log Hand capture always pushes. A stub enrichment pushes only
    /// when the tracker stack still equals the stub's pre-hand snapshot, i.e.
    /// the hand just happened and no stack update has landed since. A stale
    /// enrichment (an old stub opened later, e.g. at break) must NOT push: the
    /// chat update that originally recorded the result already moved
    /// `latestStack` on, so re-pushing `heroStackAfter` would regress it — a
    /// phantom cliff that re-triggers swing detection. (With the swing-stub fix,
    /// a swing stub's `latestStack` equals its `heroStackAfter`, not its
    /// `heroStackBefore`, so swing enrichments correctly land here as false.)
    var shouldPushStackUpdate: Bool {
        !isStubEnrichment || trackerStackAtOpen == heroStackBefore
    }

    // MARK: - Persistence

    /// Builds and inserts a `Hand` (with ordered `HandAction`s and `HandVillain`s)
    /// from the current draft, links it to the given context objects, and — when
    /// a `sourceStub` is supplied — marks that stub enriched. Does **not** push
    /// the tracker stack update; the view does that after saving to keep the
    /// engine ModelContext-pure.
    @discardableResult
    func save(into context: ModelContext, tournament: Tournament?, cashSession: CashSession?,
              sourceStub: HandStub?, tableSize: Int) -> Hand {
        let net = heroNet
        let winners = effectiveWinners

        let result: HandResult
        if foldedParticipants.contains(.hero) {
            result = .folded
        } else if winners.contains(.hero) {
            result = winners.count == 1 ? .won : .chop
        } else {
            result = .lost
        }

        let hand = Hand(
            heroPosition: heroPosition ?? .btn,
            heroCardsRaw: PlayingCard.joinList(heroCards),
            levelNumber: levelNumber, smallBlind: smallBlind, bigBlind: bigBlind, ante: ante,
            heroStackChips: heroStackBefore, playersRemaining: 0, tableSize: tableSize)
        hand.boardRaw = PlayingCard.joinList(board)
        hand.potSize = pot
        hand.amountWon = net
        hand.heroStackAfter = heroStackAfter
        hand.resultRaw = result.rawValue
        hand.tagsRaw = selectedTags.sorted().joined(separator: ", ")
        hand.wasAutoDetected = (sourceStub?.origin == .swingDetected)
        if let winnerOverride {
            hand.winnerOverride = winnerOverride.map { label(for: $0) }.sorted().joined(separator: ", ")
        }
        hand.tournament = tournament
        hand.cashSession = cashSession
        hand.sourceStub = sourceStub

        // Ordered actions replayed from the ledger.
        for (i, entry) in ledger.enumerated() {
            let action = HandAction(orderIndex: i, street: entry.street,
                                    position: position(of: entry.participant) ?? .btn,
                                    actionType: entry.action, amount: entry.toAmount,
                                    isHero: entry.participant == .hero)
            action.hand = hand
            context.insert(action)
        }

        // Villains, preserving add order and any shown holdings.
        for (i, villain) in villains.enumerated() {
            let hv = HandVillain(orderIndex: i, position: villain.position,
                                 relativeStack: villain.relative, approxStack: villain.approxStack)
            hv.shownHolding = PlayingCard.joinList(villain.shownHolding)
            hv.hand = hand
            context.insert(hv)
        }

        context.insert(hand)

        if let stub = sourceStub {
            stub.setStatus(.enriched)
            stub.enrichedHand = hand
            stub.heroStackAfter = heroStackAfter
        }

        return hand
    }

    // MARK: - Replay

    // Cards the next street needs before betting resumes (flop 3, otherwise 1).
    private func cardsForNextStreet(after street: HandStreet) -> Int {
        street == .preflop ? 3 : 1
    }

    private func nextStreet(after street: HandStreet) -> HandStreet? {
        switch street {
        case .preflop: return .flop
        case .flop: return .turn
        case .turn: return .river
        case .river: return nil
        }
    }

    /// Rebuilds every derived property by replaying `inputs` from scratch.
    private func rebuild() {
        // Replay-local state.
        var street: HandStreet = .preflop
        var committed: [HandStreet: [Participant: Int]] = [:]
        var folded: Set<Participant> = []
        var allIn: Set<Participant> = []
        var acted: Set<Participant> = []            // acted on the current street
        var curBet = 0
        var lastActor: Participant?
        var boardArr: [PlayingCard] = []
        var ledgerArr: [LedgerEntry] = []
        var handOver = false
        var needed = 0

        let parts = participants

        // Seed preflop: blind seats that are participants post their blinds; the
        // amount to match preflop is the big blind whether or not a BB sits.
        committed[.preflop] = [:]
        if let sbP = participant(at: .sb) { committed[.preflop]?[sbP] = smallBlind }
        if let bbP = participant(at: .bb) { committed[.preflop]?[bbP] = bigBlind }
        curBet = bigBlind

        func committedOf(_ p: Participant) -> Int { committed[street]?[p] ?? 0 }
        func nonFolded() -> [Participant] { parts.filter { !folded.contains($0) } }
        func ableToAct() -> [Participant] { nonFolded().filter { !allIn.contains($0) } }

        func needsToAct(_ p: Participant) -> Bool {
            guard !folded.contains(p), !allIn.contains(p) else { return false }
            return !acted.contains(p) || committedOf(p) < curBet
        }

        // Betting round is complete when no non-folded, non-all-in player still
        // owes action (everyone has acted and matched, or is all-in).
        func streetClosed() -> Bool {
            nonFolded().allSatisfy { p in
                allIn.contains(p) || (acted.contains(p) && committedOf(p) == curBet)
            }
        }

        func startNextStreet() {
            guard let next = nextStreet(after: street) else { handOver = true; return }
            street = next
            committed[street] = [:]
            curBet = 0
            acted = []
            lastActor = nil
            // If at most one player can still act (the rest all-in or folded),
            // there is no betting: run the remaining board out street by street.
            if nonFolded().count <= 1 {
                handOver = true
            } else if ableToAct().count <= 1 {
                if street == .river { handOver = true }
                else { needed = cardsForNextStreet(after: street) }
            }
        }

        // Called after each action to resolve hand-end / street-close.
        func resolveAfterAction() {
            if nonFolded().count <= 1 { handOver = true; needed = 0; return }
            guard streetClosed() else { return }
            if street == .river { handOver = true; needed = 0 }
            else { needed = cardsForNextStreet(after: street) }
        }

        for input in inputs {
            if handOver { break }
            switch input {
            case .action(let id, let actor, let type, let amount):
                switch type {
                case .fold:
                    folded.insert(actor)
                    acted.insert(actor)
                case .check:
                    acted.insert(actor)
                case .call:
                    committed[street, default: [:]][actor] = curBet
                    acted.insert(actor)
                case .bet, .raise:
                    committed[street, default: [:]][actor] = amount
                    curBet = max(curBet, amount)
                    acted.insert(actor)
                case .allIn:
                    committed[street, default: [:]][actor] = amount
                    curBet = max(curBet, amount)
                    allIn.insert(actor)
                    acted.insert(actor)
                }
                lastActor = actor
                ledgerArr.append(LedgerEntry(id: id, street: street, participant: actor,
                                             action: type, toAmount: committedOf(actor)))
                resolveAfterAction()

            case .boardCard(let card):
                // A board card only ever appears in the log while one is owed;
                // guarding keeps replay correct even after odd truncations.
                guard needed > 0 else { break }
                boardArr.append(card)
                needed -= 1
                if needed == 0 { startNextStreet() }
            }
        }

        // Compute whose turn it is: nobody while the hand is over or a board is
        // pending; otherwise the next owed participant after the last actor.
        var toAct: Participant?
        if !handOver && needed == 0 {
            let order = streetOrder(street)
            if !order.isEmpty {
                var start = 0
                if let la = lastActor, let i = order.firstIndex(of: la) { start = i + 1 }
                for k in 0..<order.count {
                    let p = order[(start + k) % order.count]
                    if needsToAct(p) { toAct = p; break }
                }
            }
        }

        // Publish.
        ledger = ledgerArr
        board = boardArr
        currentStreet = street
        boardCardsNeeded = needed
        participantToAct = toAct
        currentBet = curBet
        isHandOver = handOver
        foldedParticipants = folded
        allInParticipants = allIn
        committedByStreet = committed
    }
}
