import Foundation

/// Parses user-typed / spoken-ish hole card entry into a canonical storage
/// string. Two storage forms:
///   exact       — "Ah Kd" (PlayingCard raws, space-joined)
///   suit-agnostic — "KQs" | "AKo" | "KQ" | "99"  (ranks high-first, optional s/o)
enum HoleCardShorthand {
    private static let rankWords: [String: Character] = [
        "ace": "a", "aces": "a", "king": "k", "kings": "k",
        "queen": "q", "queens": "q", "jack": "j", "jacks": "j",
        "ten": "t", "tens": "t", "nine": "9", "nines": "9",
        "eight": "8", "eights": "8", "seven": "7", "sevens": "7",
        "six": "6", "sixes": "6", "five": "5", "fives": "5",
        "four": "4", "fours": "4", "three": "3", "threes": "3",
        "deuce": "2", "deuces": "2", "two": "2", "twos": "2",
    ]

    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= 40 else { return nil }

        // Spoken-ish: translate rank words and suited/offsuit/pocket markers.
        var modifier: Character? = nil
        if text.contains("suited") { modifier = "s" }
        if text.contains("offsuit") || text.contains("off suit") { modifier = "o" }
        let isPocket = text.contains("pocket")
        let isSpoken = isPocket || modifier != nil
            || rankWords.keys.contains(where: { text.contains($0) })
        if isSpoken {
            for (word, rank) in rankWords.sorted(by: { $0.key.count > $1.key.count }) {
                text = text.replacingOccurrences(of: word, with: String(rank))
            }
            for junk in ["pocket", "suited", "offsuit", "off suit", "of", "and"] {
                text = text.replacingOccurrences(of: junk, with: " ")
            }
            // If pocket, duplicate the rank (pocket pair)
            if isPocket {
                let compactRank = text.filter { !$0.isWhitespace }
                if compactRank.count == 1 {
                    text = "\(compactRank)\(compactRank)"
                }
            }
        }

        let compact = text.filter { !$0.isWhitespace }
        let ranks = Set("akqjt98765432")
        let suits = Set("shdc")

        // Exact form: rank+suit rank+suit  (4 meaningful chars)
        if compact.count == 4 {
            let chars = Array(compact)
            if ranks.contains(chars[0]), suits.contains(chars[1]),
               ranks.contains(chars[2]), suits.contains(chars[3]) {
                let c1 = "\(Character(chars[0].uppercased()))\(chars[1])"
                let c2 = "\(Character(chars[2].uppercased()))\(chars[3])"
                guard c1 != c2, PlayingCard(c1) != nil, PlayingCard(c2) != nil else { return nil }
                return "\(c1) \(c2)"
            }
        }

        // Suit-agnostic: two ranks + optional s/o modifier
        var body = compact
        var suffix: Character? = modifier
        if body.count == 3, let last = body.last, last == "s" || last == "o" {
            suffix = last
            body = String(body.dropLast())
        }
        guard body.count == 2,
              let r1 = body.first, let r2 = body.last,
              ranks.contains(r1), ranks.contains(r2) else { return nil }
        // Pairs can't be suited; single pair like "99" keeps no suffix.
        if r1 == r2 && suffix == "s" { return nil }
        let order = Array("akqjt98765432")
        let hi = order.firstIndex(of: r1)! <= order.firstIndex(of: r2)! ? r1 : r2
        let lo = hi == r1 ? r2 : r1
        var out = "\(Character(hi.uppercased()))\(Character(lo.uppercased()))"
        if r1 != r2, let suffix { out.append(suffix) }
        return out
    }

    static func isExact(_ stored: String) -> Bool {
        exactCards(stored).count == 2
    }

    static func exactCards(_ stored: String) -> [PlayingCard] {
        let cards = PlayingCard.parseList(stored)
        return cards.count == 2 ? cards : []
    }

    static func display(_ stored: String) -> String {
        let cards = exactCards(stored)
        guard cards.count == 2 else { return stored }
        return cards.map(\.display).joined(separator: " ")
    }
}
