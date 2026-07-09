import Foundation

/// A disambiguation anomaly surfaced by `VoiceHandMapper`. Each case renders to
/// a user-facing chip (`label`) that nudges the user to fix one thing by tap.
/// The mapper never throws: everything it can't apply deterministically becomes
/// one of these.
enum MappingIssue: Equatable, Identifiable {
    /// Hero cards were nil, unparseable, or only suit-agnostic (payload is the
    /// best canonical string we have, e.g. `"KQs"`).
    case unknownHeroCards(String)
    /// A position string (hero's or a villain's) didn't resolve to a seat.
    case unknownPosition(String)
    /// A villain seat was already taken (by the hero or an earlier villain).
    case duplicateVillainSeat(String)
    /// An action couldn't be placed in the engine's turn order (wrong actor,
    /// unresolvable actor, illegal action, or the hand was already over).
    case outOfTurnAction(actor: String, street: String)
    /// A bet/raise/all-in that needed a chip amount didn't carry one.
    case missingAmount(actor: String, street: String)
    /// A single board card couldn't be dealt (unparseable or a duplicate).
    case invalidCard(text: String, place: String)
    /// A street's board string had the wrong count or was unparseable.
    case boardMismatch(String)
    /// A villain's shown holding didn't resolve to two fresh cards.
    case unknownShownCards(actor: String, text: String)

    var id: String {
        switch self {
        case .unknownHeroCards(let s): return "unknownHeroCards:\(s)"
        case .unknownPosition(let s): return "unknownPosition:\(s)"
        case .duplicateVillainSeat(let s): return "duplicateVillainSeat:\(s)"
        case .outOfTurnAction(let actor, let street): return "outOfTurnAction:\(actor):\(street)"
        case .missingAmount(let actor, let street): return "missingAmount:\(actor):\(street)"
        case .invalidCard(let text, let place): return "invalidCard:\(text):\(place)"
        case .boardMismatch(let s): return "boardMismatch:\(s)"
        case .unknownShownCards(let actor, let text): return "unknownShownCards:\(actor):\(text)"
        }
    }

    /// Human chip text shown in the review UI.
    var label: String {
        switch self {
        case .unknownHeroCards(let s):
            return s.isEmpty
                ? "Couldn't read your hole cards — tap to pick them"
                : "Pick suits for your \(s) — tap to set"
        case .unknownPosition(let s):
            return "Couldn't place the seat \"\(s)\" — tap to set"
        case .duplicateVillainSeat(let s):
            return "Two players in \(s) — tap to fix the seat"
        case .outOfTurnAction(let actor, let street):
            return "Couldn't place \(actor)'s \(street) action — add it by tap"
        case .missingAmount(let actor, let street):
            return "\(actor)'s \(street) bet needs an amount — tap to set"
        case .invalidCard(let text, let place):
            return "Couldn't add \(text) to the \(place) — tap to fix"
        case .boardMismatch(let s):
            return "The \(s) didn't read cleanly — tap to fix the board"
        case .unknownShownCards(let actor, let text):
            return "Couldn't read \(actor)'s shown cards \"\(text)\" — tap to set"
        }
    }
}

/// The deterministic core of Voice Hand Entry: folds a parsed hand draft into a
/// `HandCaptureModel` using only the engine's own mutation surface, and reports
/// everything it couldn't place as a `MappingIssue`.
///
/// It never forces the engine out of turn order — the engine's turn computation
/// is authoritative. An action is applied only when its actor is exactly the
/// engine's `participantToAct` *and* the mapped action is in `legalActions`;
/// otherwise it is flagged and skipped (see `outOfTurnAction`).
///
/// Board cards are interleaved with actions: whenever the engine asks for board
/// cards (`boardCardsNeeded > 0`) the next pending street is fed before the next
/// action, and any remaining board (all-in run-outs) is fed after the last
/// action. Shown holdings are applied last.
@MainActor
enum VoiceHandMapper {

    static func apply(_ draft: ParsedHandDraft, to model: HandCaptureModel) -> [MappingIssue] {
        var issues: [MappingIssue] = []

        // Rule 1: hero position (set BEFORE villains/actions — didSet rebuilds).
        if let position = parsePosition(draft.heroPosition) {
            model.heroPosition = position
        } else {
            issues.append(.unknownPosition(draft.heroPosition ?? ""))
        }

        // Rule 2: hero cards.
        applyHeroCards(draft, to: model, issues: &issues)

        // Rule 3: villains. Track the added (spoken → id) pairs for showdown.
        var addedVillains: [(spoken: SpokenVillain, id: UUID)] = []
        var usedSeats: Set<HeroPosition> = []
        if let hero = model.heroPosition { usedSeats.insert(hero) }
        for spoken in draft.villains {
            guard let seat = parsePosition(spoken.position) else {
                issues.append(.unknownPosition(spoken.position ?? ""))
                continue
            }
            guard !usedSeats.contains(seat) else {
                issues.append(.duplicateVillainSeat(seat.rawValue))
                continue
            }
            usedSeats.insert(seat)
            model.addVillain(position: seat,
                             relative: relativeStack(spoken.relativeStack),
                             approxStack: spoken.approxStack ?? 0)
            if let id = model.villains.last?.id {
                addedVillains.append((spoken, id))
            }
        }

        // Rules 4 + 5: actions interleaved with board.
        for action in draft.actions {
            feedPendingBoard(draft, to: model, issues: &issues)
            applyAction(action, to: model, issues: &issues)
        }
        // Any board the engine still owes (e.g. all-in run-out) after the last
        // action.
        feedPendingBoard(draft, to: model, issues: &issues)

        // Rule 6: showdown holdings.
        for (spoken, id) in addedVillains {
            guard let shown = spoken.shownCards,
                  !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let cards = PlayingCard.parseList(shown)
            let dealt = model.dealtCards
            if cards.count == 2, cards.allSatisfy({ !dealt.contains($0) }) {
                model.setShownHolding(cards, for: id)
            } else {
                issues.append(.unknownShownCards(actor: spoken.position ?? "villain", text: shown))
            }
        }

        return issues
    }

    // MARK: - Hero cards

    private static func applyHeroCards(_ draft: ParsedHandDraft, to model: HandCaptureModel,
                                       issues: inout [MappingIssue]) {
        let raw = draft.heroCards ?? ""
        guard let normalized = HoleCardShorthand.normalize(raw) else {
            issues.append(.unknownHeroCards(raw))
            return
        }
        let exact = HoleCardShorthand.exactCards(normalized)
        if exact.count == 2 {
            for card in exact { model.addCard(card) }   // respects heroCardCount + dealt
        } else {
            // Suit-agnostic (e.g. "KQs", "99"): leave cards empty, chip picks suits.
            issues.append(.unknownHeroCards(normalized))
        }
    }

    // MARK: - Actions

    private static func applyAction(_ action: SpokenAction, to model: HandCaptureModel,
                                    issues: inout [MappingIssue]) {
        let actorLabel = action.actor ?? "?"
        let streetLabel = action.street ?? "?"

        // Resolve actor and demand it exactly matches whose turn the engine says
        // it is — never force the engine out of order.
        guard let target = resolveActor(action.actor, in: model),
              let toAct = model.participantToAct,
              target == toAct else {
            issues.append(.outOfTurnAction(actor: actorLabel, street: streetLabel))
            return
        }

        let isAllIn = action.isAllIn == true
        let isHero = (target == .hero)

        // Determine the engine action type.
        let type: HandActionType
        if isAllIn {
            type = .allIn
        } else if let parsed = parseActionType(action.action) {
            type = parsed
        } else {
            // Unrecognised verb that isn't an all-in — can't map it.
            issues.append(.outOfTurnAction(actor: actorLabel, street: streetLabel))
            return
        }

        // Legality: trust the draft only when the engine currently offers it.
        guard model.legalActions.contains(type) else {
            issues.append(.outOfTurnAction(actor: actorLabel, street: streetLabel))
            return
        }

        // Resolve the amount.
        let toAmount: Int
        switch type {
        case .fold, .check, .call:
            toAmount = 0
        case .allIn:
            if let amount = action.amount {
                toAmount = amount
            } else if isHero {
                toAmount = model.heroStackBefore   // hero jam with no stated amount
            } else {
                issues.append(.missingAmount(actor: actorLabel, street: streetLabel))
                return
            }
        case .bet, .raise:
            guard let amount = action.amount else {
                issues.append(.missingAmount(actor: actorLabel, street: streetLabel))
                return
            }
            toAmount = amount
        }

        model.add(action: type, toAmount: toAmount)
    }

    /// "hero" or the hero's own seat name → `.hero`; a villain's seat → that
    /// villain. `nil` when the actor can't be tied to a current participant.
    private static func resolveActor(_ actor: String?, in model: HandCaptureModel) -> HandCaptureModel.Participant? {
        guard let actor = actor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !actor.isEmpty else { return nil }
        if actor.lowercased() == "hero" { return .hero }
        guard let seat = parsePosition(actor) else { return nil }
        if seat == model.heroPosition { return .hero }
        if let villain = model.villains.first(where: { $0.position == seat }) {
            return .villain(villain.id)
        }
        return nil
    }

    // MARK: - Board

    /// Feeds pending board cards for as long as the engine asks for them. The
    /// pending street is determined by how many board cards are already dealt
    /// (0→flop, 3→turn, 4→river), so all-in run-outs feed multiple streets in a
    /// single call while live betting stops after one street (the engine then
    /// hands the turn back to a player and `boardCardsNeeded` drops to 0).
    private static func feedPendingBoard(_ draft: ParsedHandDraft, to model: HandCaptureModel,
                                         issues: inout [MappingIssue]) {
        while model.boardCardsNeeded > 0 {
            let dealtOnBoard = model.board.count
            let street: HandStreet
            let source: String?
            if dealtOnBoard < 3 { street = .flop; source = draft.flop }
            else if dealtOnBoard < 4 { street = .turn; source = draft.turn }
            else { street = .river; source = draft.river }

            let cards = PlayingCard.parseList(source ?? "")
            guard cards.count == model.boardCardsNeeded else {
                issues.append(.boardMismatch(street.label))
                break
            }
            var stalled = false
            for card in cards {
                if !model.addBoardCard(card) {
                    issues.append(.invalidCard(text: card.raw, place: street.label))
                    stalled = true
                    break
                }
            }
            if stalled { break }
        }
    }

    // MARK: - Parsing helpers

    /// Case-insensitive seat parsing: raw-value match plus common aliases.
    static func parsePosition(_ raw: String?) -> HeroPosition? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        if let match = HeroPosition.allCases.first(where: { $0.rawValue.uppercased() == upper }) {
            return match
        }
        switch upper {
        case "UTG1", "UTG +1", "UTG + 1": return .utg1
        case "BUTTON", "DEALER", "BUT", "BU": return .btn
        case "SMALL BLIND", "SMALLBLIND", "SMALL": return .sb
        case "BIG BLIND", "BIGBLIND", "BIG": return .bb
        case "CUTOFF", "CUT OFF": return .co
        case "HIJACK", "HI JACK": return .hj
        case "LOJACK", "LO JACK": return .lj
        case "MIDDLE", "MIDDLE POSITION", "MIDDLEPOSITION": return .mp
        default: return nil
        }
    }

    private static func parseActionType(_ raw: String?) -> HandActionType? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        switch value {
        case "fold", "folds": return .fold
        case "check", "checks": return .check
        case "call", "calls": return .call
        case "bet", "bets": return .bet
        case "raise", "raises", "reraise", "re-raise", "3bet", "3-bet": return .raise
        case "all-in", "allin", "all in", "jam", "shove", "ship": return .allIn
        default: return nil
        }
    }

    private static func relativeStack(_ raw: String?) -> RelativeStack {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return .coversHero }
        if value.hasPrefix("cover") { return .coversHero }
        if value.hasPrefix("same") || value.hasPrefix("similar") || value.hasPrefix("equal") { return .similar }
        if value.hasPrefix("short") { return .shorter }
        return .coversHero
    }
}
