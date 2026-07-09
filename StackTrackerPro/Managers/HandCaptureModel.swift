import Foundation
import Observation

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

    // MARK: - Setup state

    var heroPosition: HeroPosition? { didSet { rebuild() } }
    var heroCards: [PlayingCard] = []
    private(set) var villains: [VillainDraft] = []

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
         heroCardCount: Int, heroStackBefore: Int) {
        self.levelNumber = levelNumber
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
        self.ante = ante
        self.heroCardCount = heroCardCount
        self.heroStackBefore = heroStackBefore
        rebuild()
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
