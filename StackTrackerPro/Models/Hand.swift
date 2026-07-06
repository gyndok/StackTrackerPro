import Foundation
import SwiftData

// MARK: - Card

struct PlayingCard: Equatable, Hashable {
    static let ranks: [Character] = ["A","K","Q","J","T","9","8","7","6","5","4","3","2"]
    static let suits: [Character] = ["s","h","d","c"]

    let rank: Character
    let suit: Character

    init?(rank: Character, suit: Character) {
        guard Self.ranks.contains(rank), Self.suits.contains(suit) else { return nil }
        self.rank = rank
        self.suit = suit
    }

    init?(_ string: String) {
        guard string.count == 2,
              let r = string.first, let s = string.last,
              let card = PlayingCard(rank: r, suit: s) else { return nil }
        self = card
    }

    var raw: String { "\(rank)\(suit)" }

    var suitSymbol: String {
        switch suit {
        case "s": return "♠"
        case "h": return "♥"
        case "d": return "♦"
        default: return "♣"
        }
    }

    var display: String { "\(rank)\(suitSymbol)" }

    /// True for hearts/diamonds (red suits) — used for display tinting.
    var isRed: Bool { suit == "h" || suit == "d" }

    static func parseList(_ raw: String) -> [PlayingCard] {
        raw.split(separator: " ").compactMap { PlayingCard(String($0)) }
    }

    static func joinList(_ cards: [PlayingCard]) -> String {
        cards.map(\.raw).joined(separator: " ")
    }
}

// MARK: - Enums

enum HandStreet: String, CaseIterable {
    case preflop, flop, turn, river

    var label: String { rawValue.capitalized }
}

enum HeroPosition: String, CaseIterable {
    case utg = "UTG", utg1 = "UTG+1", mp = "MP", lj = "LJ", hj = "HJ"
    case co = "CO", btn = "BTN", sb = "SB", bb = "BB"
}

enum HandActionType: String, CaseIterable {
    case fold = "Fold", check = "Check", call = "Call"
    case bet = "Bet", raise = "Raise", allIn = "All-In"

    /// Actions where the hero voluntarily put chips in preflop (VPIP).
    var isVoluntaryChips: Bool {
        switch self {
        case .call, .bet, .raise, .allIn: return true
        case .fold, .check: return false
        }
    }
}

enum HandResult: String, CaseIterable {
    case won = "Won", lost = "Lost", chop = "Chop", folded = "Folded"
}

// MARK: - Models

@Model
final class Hand {
    var timestamp: Date = Date.now
    var heroPositionRaw: String = HeroPosition.btn.rawValue
    var heroCardsRaw: String = ""      // "As Kh"
    var boardRaw: String = ""          // "Ah 7d 2c Ts 3h"
    var resultRaw: String = HandResult.folded.rawValue
    var potSize: Int = 0               // 0 = not recorded
    var amountWon: Int = 0             // net; negative = loss
    var villainCardsRaw: String = ""
    var notes: String = ""
    var tagsRaw: String = ""           // comma-joined

    // Context snapshot (all zero when unknown / cash game)
    var levelNumber: Int = 0
    var smallBlind: Int = 0
    var bigBlind: Int = 0
    var ante: Int = 0
    var heroStackChips: Int = 0
    var playersRemaining: Int = 0
    var tableSize: Int = 9
    var stakes: String = ""            // cash stakes string, e.g. "1/3"

    @Relationship(deleteRule: .cascade, inverse: \HandAction.hand)
    var actions: [HandAction]? = []

    var tournament: Tournament?
    var cashSession: CashSession?

    init(
        heroPosition: HeroPosition = .btn,
        heroCardsRaw: String = "",
        levelNumber: Int = 0, smallBlind: Int = 0, bigBlind: Int = 0, ante: Int = 0,
        heroStackChips: Int = 0, playersRemaining: Int = 0, tableSize: Int = 9,
        stakes: String = ""
    ) {
        self.heroPositionRaw = heroPosition.rawValue
        self.heroCardsRaw = heroCardsRaw
        self.levelNumber = levelNumber
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
        self.ante = ante
        self.heroStackChips = heroStackChips
        self.playersRemaining = playersRemaining
        self.tableSize = tableSize
        self.stakes = stakes
    }

    var heroPosition: HeroPosition { HeroPosition(rawValue: heroPositionRaw) ?? .btn }
    var result: HandResult { HandResult(rawValue: resultRaw) ?? .folded }
    var heroCards: [PlayingCard] { PlayingCard.parseList(heroCardsRaw) }
    var board: [PlayingCard] { PlayingCard.parseList(boardRaw) }
    var villainCards: [PlayingCard] { PlayingCard.parseList(villainCardsRaw) }
    var tags: [String] {
        tagsRaw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    var netResult: Int { amountWon }

    var sortedActions: [HandAction] {
        (actions ?? []).sorted { $0.orderIndex < $1.orderIndex }
    }

    /// Hero's preflop actions, for VPIP/PFR.
    var heroPreflopActions: [HandAction] {
        sortedActions.filter { $0.isHero && $0.street == .preflop }
    }

    var blindsDisplay: String {
        if !stakes.isEmpty { return stakes }
        guard bigBlind > 0 else { return "" }
        var s = "\(smallBlind.formatted())/\(bigBlind.formatted())"
        if ante > 0 { s += " ante \(ante.formatted())" }
        return s
    }
}

@Model
final class HandAction {
    var orderIndex: Int = 0
    var streetRaw: String = HandStreet.preflop.rawValue
    var positionRaw: String = HeroPosition.btn.rawValue
    var actionTypeRaw: String = HandActionType.check.rawValue
    var amount: Int = 0
    var isHero: Bool = false
    var hand: Hand?

    init(orderIndex: Int, street: HandStreet, position: HeroPosition, actionType: HandActionType, amount: Int = 0, isHero: Bool = false) {
        self.orderIndex = orderIndex
        self.streetRaw = street.rawValue
        self.positionRaw = position.rawValue
        self.actionTypeRaw = actionType.rawValue
        self.amount = amount
        self.isHero = isHero
    }

    var street: HandStreet { HandStreet(rawValue: streetRaw) ?? .preflop }
    var position: HeroPosition { HeroPosition(rawValue: positionRaw) ?? .btn }
    var actionType: HandActionType { HandActionType(rawValue: actionTypeRaw) ?? .check }

    var timelineDescription: String {
        let amountPart = amount > 0 ? " \(amount.formatted())" : ""
        return "\(positionRaw) \(actionTypeRaw.lowercased())\(amountPart)"
    }
}
