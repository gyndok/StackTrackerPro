import Foundation

// MARK: - Chip input parsing

/// Parses free-form chip amounts: "390k"/"42.5k" for thousands, "1.2m" for
/// millions, otherwise a literal bare integer. Used by the pot/stack pads and
/// the villain approx-stack field. (The bet-sizing pad has its own parser,
/// `SizingInput`, which adds the explicit "bb" suffix — the implicit
/// short-number-means-BB-multiple heuristic that used to live here made
/// typed amounts unpredictable and is gone.)
enum ChipInput {
    static func parse(_ raw: String) -> Int? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }
        if cleaned.hasSuffix("k") {
            guard let num = Double(cleaned.dropLast()), num > 0 else { return nil }
            return Int((num * 1000).rounded())
        }
        if cleaned.hasSuffix("m") {
            guard let num = Double(cleaned.dropLast()), num > 0 else { return nil }
            return Int((num * 1_000_000).rounded())
        }
        guard let value = Int(cleaned), value >= 0 else { return nil }
        return value
    }
}

/// Pure parser for the bet-sizing "#" pad. Semantics are LITERAL — what you
/// type is the raise-to/bet total in chips (device finding 13; the old pad
/// both multiplied short numbers by the big blind and added `currentBet` on
/// top, so "2300" committed as 2300 + BB):
/// - bare number ("2300") -> exactly 2300 chips;
/// - "bb" suffix ("4bb", "2.5bb", "4 bb", case-insensitive) -> value x bigBlind,
///   rounded to the nearest chip;
/// - "k"/"m" shorthand ("42.5k", "1.2m") -> thousands/millions;
/// - zero, empty, or unparseable -> nil.
enum SizingInput {
    static func parse(_ raw: String, bigBlind: Int) -> Int? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }
        if cleaned.hasSuffix("bb") {
            let numText = cleaned.dropLast(2).trimmingCharacters(in: .whitespaces)
            guard bigBlind > 0, let num = Double(numText), num > 0 else { return nil }
            return Int((num * Double(bigBlind)).rounded())
        }
        if cleaned.hasSuffix("k") {
            guard let num = Double(cleaned.dropLast()), num > 0 else { return nil }
            return Int((num * 1000).rounded())
        }
        if cleaned.hasSuffix("m") {
            guard let num = Double(cleaned.dropLast()), num > 0 else { return nil }
            return Int((num * 1_000_000).rounded())
        }
        guard let value = Int(cleaned), value > 0 else { return nil }
        return value
    }
}

// MARK: - Bar state

/// Which mode the pinned capture bar is in (spec §1). Derived from engine
/// state on every render — never stored. First matching row wins.
enum CaptureBarState: Equatable {
    case done
    case dealingBoard(street: HandStreet, needed: Int)
    case sizing(HandActionType)
    case dealingHero
    case needsVillain
    case acting

    static func derive(isHandOver: Bool, boardCardsNeeded: Int, streetBeingDealt: HandStreet,
                       pendingAction: HandActionType?, heroCardsMissing: Bool,
                       heroCardsDeferred: Bool, ledgerIsEmpty: Bool,
                       villainsIsEmpty: Bool) -> CaptureBarState {
        if isHandOver { return .done }
        if boardCardsNeeded > 0 { return .dealingBoard(street: streetBeingDealt, needed: boardCardsNeeded) }
        if let pendingAction { return .sizing(pendingAction) }
        // Fresh hand only: once actions exist (or the user tapped "Later") the
        // hero-cards editor lives inline in the Hero section instead.
        if heroCardsMissing && ledgerIsEmpty && !heroCardsDeferred { return .dealingHero }
        if villainsIsEmpty && ledgerIsEmpty { return .needsVillain }
        return .acting
    }
}

// MARK: - Collapsed setup chips

/// Text for the collapsed Hero chip row (spec §5). Pure so the wording is
/// unit-tested without rendering.
enum CaptureChips {
    struct Hero: Equatable {
        let seat: String
        let cards: String
        let stack: String
    }

    static func hero(position: HeroPosition?, cards: [PlayingCard], cardCount: Int, stack: Int) -> Hero {
        let seat = position?.rawValue ?? "Seat?"
        let cardText: String
        if cards.isEmpty {
            cardText = "Cards?"
        } else if cards.count < cardCount {
            cardText = cards.map(\.display).joined(separator: " ") + " +\(cardCount - cards.count)"
        } else {
            cardText = cards.map(\.display).joined(separator: " ")
        }
        return Hero(seat: seat, cards: cardText, stack: stack.formatted())
    }
}

// MARK: - Sizing presets

/// Spot-aware preset chips for the bar's sizing row (spec §3). Pure: the
/// caller passes engine values in and gets labelled raise-to/bet totals
/// back, already rounded and with the disable rules applied.
enum SizingPresets {
    struct Chip: Equatable {
        let label: String
        let toAmount: Int
        let isEnabled: Bool
    }

    /// Chip denomination to round presets to. Spec: 100 below a 1K big
    /// blind, 500 below 10K, else 1,000 — extended downward for cash blinds
    /// (1 below 20, 5 below 100) so $1/$2 games don't round 6 up to 100.
    static func roundingUnit(bigBlind: Int) -> Int {
        switch bigBlind {
        case ..<20: return 1
        case ..<100: return 5
        case ..<1_000: return 100
        case ..<10_000: return 500
        default: return 1_000
        }
    }

    /// Nearest multiple of the unit, never below one unit.
    static func rounded(_ raw: Double, bigBlind: Int) -> Int {
        let unit = roundingUnit(bigBlind: bigBlind)
        guard raw > 0 else { return unit }
        return max(unit, Int((raw / Double(unit)).rounded()) * unit)
    }

    static func chips(street: HandStreet, currentBet: Int, minRaiseTotal: Int?,
                      pot: Int, bigBlind: Int, jamTotal: Int?) -> [Chip] {
        let facing = street == .preflop ? currentBet > bigBlind : currentBet > 0
        var raw: [(String, Int)] = []
        if facing {
            if let minRaiseTotal { raw.append(("Min", minRaiseTotal)) }
            raw.append(("2.5×", rounded(Double(currentBet) * 2.5, bigBlind: bigBlind)))
            raw.append(("3×", rounded(Double(currentBet) * 3, bigBlind: bigBlind)))
            raw.append(("4×", rounded(Double(currentBet) * 4, bigBlind: bigBlind)))
            raw.append(("Pot", currentBet + rounded(Double(pot), bigBlind: bigBlind)))
        } else if street == .preflop {
            for label in ["2bb", "2.5bb", "3bb"] {
                raw.append((label, SizingInput.parse(label, bigBlind: bigBlind) ?? 0))
            }
            raw.append(("Pot", currentBet + rounded(Double(pot), bigBlind: bigBlind)))
        } else {
            let fractions: [(String, Double)] = [("⅓", 1.0 / 3), ("½", 0.5), ("⅔", 2.0 / 3), ("Pot", 1.0), ("1.5×", 1.5)]
            for (label, fraction) in fractions {
                raw.append((label, rounded(Double(pot) * fraction, bigBlind: bigBlind)))
            }
        }
        return raw.map { label, total in
            var isEnabled = total > currentBet
            if let jamTotal, total >= jamTotal { isEnabled = false }
            return Chip(label: label, toAmount: total, isEnabled: isEnabled)
        }
    }
}
