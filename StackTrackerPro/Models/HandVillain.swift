import Foundation
import SwiftData

enum RelativeStack: String, CaseIterable {
    case coversHero = "Covers me", similar = "~Same", shorter = "Shorter"
}

/// A specific opponent in a structured hand. No fixed count — multiway is
/// not a special case (spec 5.2).
@Model
final class HandVillain {
    var orderIndex: Int = 0
    var positionRaw: String = HeroPosition.utg.rawValue
    var relativeStackRaw: String = RelativeStack.coversHero.rawValue
    var approxStack: Int = 0          // 0 = not given
    var shownHolding: String = ""     // "9h Th"; "" = mucked/unknown
    var hand: Hand?

    init(orderIndex: Int = 0, position: HeroPosition = .utg,
         relativeStack: RelativeStack = .coversHero, approxStack: Int = 0) {
        self.orderIndex = orderIndex
        self.positionRaw = position.rawValue
        self.relativeStackRaw = relativeStack.rawValue
        self.approxStack = approxStack
    }

    var position: HeroPosition { HeroPosition(rawValue: positionRaw) ?? .utg }
    var relativeStack: RelativeStack { RelativeStack(rawValue: relativeStackRaw) ?? .coversHero }
    var shownCards: [PlayingCard] { PlayingCard.parseList(shownHolding) }

    var chipLabel: String {
        var label = "\(positionRaw) · \(relativeStackRaw)"
        if approxStack > 0 { label += " ≈\(approxStack.formatted())" }
        return label
    }
}
