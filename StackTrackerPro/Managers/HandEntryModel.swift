import Foundation
import SwiftData
import Observation

/// Pure state machine behind the hand-entry surface. Owns the staged flow
/// (position → hole cards → per-street actions/boards → result), dealt-card
/// tracking, undo, and the final save with live-session context snapshot.
/// UI-free so the whole flow is unit-testable.
@MainActor @Observable
final class HandEntryModel {

    enum Stage: Equatable {
        case position
        case holeCards
        case action(HandStreet)
        case boardCards(HandStreet)
        case result
    }

    struct DraftAction {
        let street: HandStreet
        let position: HeroPosition
        let type: HandActionType
        let amount: Int
        let isHero: Bool
    }

    static let presetTags = ["bluff", "value bet", "set mining", "squeeze",
                             "overbet", "hero call", "bad beat", "cooler"]

    private(set) var stage: Stage = .position
    private(set) var heroPosition: HeroPosition?
    private(set) var heroCards: [PlayingCard] = []
    private(set) var board: [PlayingCard] = []
    private(set) var draftActions: [DraftAction] = []

    /// Position the next action applies to; defaults to hero, user may retarget.
    var actingPosition: HeroPosition = .btn

    // Result-stage fields
    var result: HandResult?
    var potSize: Int = 0
    var amountWon: Int = 0
    var villainCards: [PlayingCard] = []
    var notes: String = ""
    var selectedTags: Set<String> = []

    /// Every input in order, for undo.
    private enum Input {
        case position
        case heroCard
        case boardCard(HandStreet)
        case action
        case streetAdvance(from: Stage)
        case finish(from: Stage)
    }
    private var inputLog: [Input] = []

    private var dealt: Set<PlayingCard> { Set(heroCards + board + villainCards) }

    // MARK: - Inputs

    func selectPosition(_ position: HeroPosition) {
        heroPosition = position
        actingPosition = position
        stage = .holeCards
        inputLog.append(.position)
    }

    func isCardDealt(_ card: PlayingCard) -> Bool { dealt.contains(card) }

    /// Adds a card to whichever collection the current stage needs.
    /// Returns false (no-op) for already-dealt cards or non-card stages.
    @discardableResult
    func addCard(_ card: PlayingCard) -> Bool {
        guard !isCardDealt(card) else { return false }
        switch stage {
        case .holeCards:
            heroCards.append(card)
            inputLog.append(.heroCard)
            if heroCards.count == 2 { stage = .action(.preflop) }
            return true
        case .boardCards(let street):
            board.append(card)
            inputLog.append(.boardCard(street))
            let needed = street == .flop ? 3 : (street == .turn ? 4 : 5)
            if board.count == needed { stage = .action(street) }
            return true
        default:
            return false
        }
    }

    func addAction(_ type: HandActionType, amount: Int = 0) {
        guard case .action(let street) = stage else { return }
        draftActions.append(DraftAction(
            street: street,
            position: actingPosition,
            type: type,
            amount: amount,
            isHero: actingPosition == heroPosition
        ))
        inputLog.append(.action)
    }

    /// From an action stage, moves to the next street's board entry.
    func advanceStreet() {
        guard case .action(let street) = stage else { return }
        let next: HandStreet? = switch street {
        case .preflop: .flop
        case .flop: .turn
        case .turn: .river
        case .river: nil
        }
        let previous = stage
        if let next {
            stage = .boardCards(next)
            inputLog.append(.streetAdvance(from: previous))
        } else {
            finishHand()
        }
    }

    /// Jumps to the result stage from anywhere past hole cards.
    func finishHand() {
        guard stage != .position, stage != .result, heroCards.count == 2 else { return }
        let previous = stage
        stage = .result
        inputLog.append(.finish(from: previous))
        // Hero folding is the most common ending — pre-select it.
        if result == nil,
           let lastHero = draftActions.last(where: { $0.isHero }),
           lastHero.type == .fold {
            result = .folded
        }
    }

    func undo() {
        guard let last = inputLog.popLast() else { return }
        switch last {
        case .position:
            heroPosition = nil
            stage = .position
        case .heroCard:
            _ = heroCards.popLast()
            stage = .holeCards
        case .boardCard(let street):
            _ = board.popLast()
            stage = .boardCards(street)
        case .action:
            _ = draftActions.popLast()
            // stage unchanged (still the same action stage)
        case .streetAdvance(let from), .finish(let from):
            stage = from
            result = nil
        }
    }

    // MARK: - Derived

    /// Rough pot: blinds + one big-blind ante + every recorded amount.
    /// An estimate by design — the result screen lets the user correct it.
    func potEstimate(sb: Int, bb: Int, ante: Int) -> Int {
        sb + bb + ante + draftActions.reduce(0) { $0 + $1.amount }
    }

    var timeline: String {
        draftActions.map { "\($0.position.rawValue) \($0.type.rawValue.lowercased())\($0.amount > 0 ? " \($0.amount.formatted())" : "")" }
            .joined(separator: " › ")
    }

    // MARK: - Save

    /// Persists the draft as a Hand, snapshotting live context from the
    /// session it belongs to. Exactly one of tournament/cashSession is set.
    func save(into context: ModelContext, tournament: Tournament?, cashSession: CashSession?, seatsDefault: Int) -> Hand {
        let hand = Hand(
            heroPosition: heroPosition ?? .btn,
            heroCardsRaw: PlayingCard.joinList(heroCards),
            levelNumber: tournament?.currentBlindLevelNumber ?? 0,
            smallBlind: tournament?.currentBlinds?.smallBlind ?? 0,
            bigBlind: tournament?.currentBlinds?.bigBlind ?? 0,
            ante: tournament?.currentBlinds?.ante ?? 0,
            heroStackChips: tournament?.latestStack?.chipCount ?? 0,
            playersRemaining: tournament?.playersRemaining ?? 0,
            tableSize: seatsDefault,
            stakes: cashSession?.stakes ?? ""
        )
        hand.boardRaw = PlayingCard.joinList(board)
        hand.resultRaw = (result ?? .folded).rawValue
        hand.potSize = potSize
        hand.amountWon = amountWon
        hand.villainCardsRaw = PlayingCard.joinList(villainCards)
        hand.notes = notes
        hand.tagsRaw = selectedTags.sorted().joined(separator: ",")
        hand.tournament = tournament
        hand.cashSession = cashSession
        context.insert(hand)

        for (index, draft) in draftActions.enumerated() {
            let action = HandAction(
                orderIndex: index, street: draft.street, position: draft.position,
                actionType: draft.type, amount: draft.amount, isHero: draft.isHero
            )
            action.hand = hand
            context.insert(action)
        }
        return hand
    }
}
