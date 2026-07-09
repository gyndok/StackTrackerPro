import Foundation

/// Minimal 5–7 card hold'em hand evaluator. Categories:
/// 8 straight flush, 7 quads, 6 full house, 5 flush, 4 straight,
/// 3 trips, 2 two pair, 1 pair, 0 high card.
struct PokerHandEvaluator {
    struct Score: Comparable, Equatable {
        let category: Int
        let ranks: [Int]   // tiebreakers, high first

        static func < (lhs: Score, rhs: Score) -> Bool {
            if lhs.category != rhs.category { return lhs.category < rhs.category }
            for (l, r) in zip(lhs.ranks, rhs.ranks) where l != r { return l < r }
            return false
        }
    }

    private static let rankValue: [Character: Int] = [
        "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8,
        "9": 9, "T": 10, "J": 11, "Q": 12, "K": 13, "A": 14,
    ]

    static func bestScore(_ cards: [PlayingCard]) -> Score? {
        guard cards.count >= 5, cards.count <= 7 else { return nil }
        guard Set(cards).count == cards.count else { return nil }
        var best: Score?
        for combo in combinations(cards, choose: 5) {
            let s = scoreFive(combo)
            if best == nil || s > best! { best = s }
        }
        return best
    }

    static func holdemWinners(board: [PlayingCard],
                              holdings: [(id: UUID, cards: [PlayingCard])]) -> [UUID] {
        guard board.count == 5 else { return [] }
        var scored: [(UUID, Score)] = []
        for (id, cards) in holdings {
            guard cards.count == 2, let s = bestScore(board + cards) else { continue }
            scored.append((id, s))
        }
        guard let top = scored.map(\.1).max() else { return [] }
        return scored.filter { $0.1 == top }.map(\.0)
    }

    // MARK: - Internals

    private static func scoreFive(_ cards: [PlayingCard]) -> Score {
        let values = cards.map { rankValue[$0.rank]! }.sorted(by: >)
        let isFlush = Set(cards.map(\.suit)).count == 1
        let straightHigh = straightHighCard(values)

        var counts: [Int: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        // Sort rank groups by (count desc, rank desc) — canonical tiebreak order.
        let groups = counts.sorted { ($0.value, $0.key) > ($1.value, $1.key) }
        let shape = groups.map(\.value)
        let ordered = groups.map(\.key)

        if isFlush, let high = straightHigh { return Score(category: 8, ranks: [high]) }
        if shape == [4, 1] { return Score(category: 7, ranks: ordered) }
        if shape == [3, 2] { return Score(category: 6, ranks: ordered) }
        if isFlush { return Score(category: 5, ranks: values) }
        if let high = straightHigh { return Score(category: 4, ranks: [high]) }
        if shape == [3, 1, 1] { return Score(category: 3, ranks: ordered) }
        if shape == [2, 2, 1] { return Score(category: 2, ranks: ordered) }
        if shape == [2, 1, 1, 1] { return Score(category: 1, ranks: ordered) }
        return Score(category: 0, ranks: values)
    }

    private static func straightHighCard(_ sortedDesc: [Int]) -> Int? {
        let distinct = Array(Set(sortedDesc)).sorted(by: >)
        guard distinct.count == 5 else { return nil }
        if distinct.first! - distinct.last! == 4 { return distinct.first! }
        if distinct == [14, 5, 4, 3, 2] { return 5 }   // wheel
        return nil
    }

    private static func combinations(_ cards: [PlayingCard], choose k: Int) -> [[PlayingCard]] {
        guard cards.count > k else { return [cards] }
        var result: [[PlayingCard]] = []
        var combo: [PlayingCard] = []
        func recurse(_ start: Int) {
            if combo.count == k { result.append(combo); return }
            for i in start..<cards.count {
                combo.append(cards[i])
                recurse(i + 1)
                combo.removeLast()
            }
        }
        recurse(0)
        return result
    }
}
