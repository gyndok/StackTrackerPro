import Foundation

/// Formats a persisted Hand as a shareable plain-text hand history with
/// Unicode suit glyphs. Pure and deterministic: numbers are en_US-grouped
/// regardless of device locale.
enum HandHistoryFormatter {

    private static let numberStyle = IntegerFormatStyle<Int>.number
        .locale(Locale(identifier: "en_US"))

    static func text(for hand: Hand) -> String {
        var lines: [String] = []
        if let header = headerLine(for: hand) { lines.append(header) }
        lines.append(contentsOf: streetLines(for: hand))
        lines.append(resultLine(for: hand))
        return lines.joined(separator: "\n")
    }

    // MARK: - Header

    private static func headerLine(for hand: Hand) -> String? {
        var contextPart: String?
        if !hand.stakes.isEmpty {
            contextPart = hand.stakes
        } else if hand.bigBlind > 0 {
            var blinds = "\(fmt(hand.smallBlind))/\(fmt(hand.bigBlind))"
            if hand.ante > 0 { blinds += " (\(fmt(hand.ante)))" }
            contextPart = hand.levelNumber > 0 ? "Level \(hand.levelNumber) — \(blinds)" : blinds
        }

        var heroPart = "Hero \(hand.heroPositionRaw)"
        let cards = glyphs(hand.heroCards)
        if !cards.isEmpty { heroPart += " \(cards)" }
        if hand.heroStackChips > 0 { heroPart += " (\(fmt(hand.heroStackChips)))" }

        if let contextPart { return "\(contextPart) · \(heroPart)" }
        // No blinds/stakes context and no cards/stack → header adds nothing.
        return hand.heroCards.isEmpty && hand.heroStackChips == 0 ? nil : heroPart
    }

    // MARK: - Streets

    private static func streetLines(for hand: Hand) -> [String] {
        let board = hand.board
        var lines: [String] = []
        for street in HandStreet.allCases {
            let actions = hand.sortedActions.filter { $0.street == street }
            let boardPart = boardGlyphs(for: street, board: board)
            guard !actions.isEmpty || boardPart != nil else { continue }

            var prefix: String
            switch street {
            case .preflop: prefix = "PRE"
            case .flop: prefix = "FLOP"
            case .turn: prefix = "TURN"
            case .river: prefix = "RIVER"
            }
            if let boardPart { prefix += " \(boardPart)" }

            if actions.isEmpty {
                lines.append(prefix)
            } else {
                let joined = actions.map(describe).joined(separator: " · ")
                lines.append("\(prefix): \(joined)")
            }
        }
        return lines
    }

    private static func boardGlyphs(for street: HandStreet, board: [PlayingCard]) -> String? {
        switch street {
        case .preflop: return nil
        case .flop: return board.count >= 3 ? glyphs(Array(board[0..<3])) : nil
        case .turn: return board.count >= 4 ? board[3].display : nil
        case .river: return board.count >= 5 ? board[4].display : nil
        }
    }

    private static func describe(_ action: HandAction) -> String {
        let actor = action.isHero ? "Hero" : action.positionRaw
        let amount = action.amount > 0 ? " \(fmt(action.amount))" : ""
        switch action.actionType {
        case .fold: return "\(actor) folds"
        case .check: return "\(actor) checks"
        case .call: return "\(actor) calls"
        case .bet: return "\(actor) bets\(amount)"
        case .raise: return action.amount > 0 ? "\(actor) raises to\(amount)" : "\(actor) raises"
        case .allIn: return "\(actor) all-in\(amount)"
        }
    }

    // MARK: - Result

    private static func resultLine(for hand: Hand) -> String {
        let shows = hand.sortedVillains
            .filter { !$0.shownHolding.isEmpty }
            .map { "\($0.positionRaw) shows \(glyphs($0.shownCards))" }
            .joined(separator: ", ")

        // Negative amounts carry their own minus; only prefix "+" for gains
        // (same conditional-sign pattern as HandsPane's net display).
        let sign = hand.amountWon > 0 ? "+" : ""
        let outcome: String
        switch hand.result {
        case .won:
            var s = "Hero wins"
            if hand.potSize > 0 { s += " \(fmt(hand.potSize))" }
            if hand.amountWon != 0 { s += " (\(sign)\(fmt(hand.amountWon)))" }
            outcome = s
        case .lost:
            outcome = hand.amountWon != 0 ? "Hero loses (\(fmt(hand.amountWon)))" : "Hero loses"
        case .chop:
            outcome = hand.amountWon != 0 ? "Chop (\(sign)\(fmt(hand.amountWon)))" : "Chop"
        case .folded:
            outcome = "Hero folds"
        }
        return shows.isEmpty ? outcome : "\(shows) — \(outcome)"
    }

    // MARK: - Helpers

    private static func fmt(_ n: Int) -> String { n.formatted(numberStyle) }
    private static func glyphs(_ cards: [PlayingCard]) -> String {
        cards.map(\.display).joined()
    }
}
