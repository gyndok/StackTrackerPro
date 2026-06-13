import Foundation

struct TweetComposer {

    enum TweetContext {
        case activeLive
        case completed
    }

    // MARK: - Compose Tweet

    static func composeTweet(for tournament: Tournament, context: TweetContext) -> String {
        let body: String
        switch context {
        case .activeLive:
            body = liveBody(for: tournament)
        case .completed:
            body = completedBody(for: tournament)
        }

        let tags = hashtags(for: tournament)
        return "\(body)\n\n\(tags)"
    }

    // MARK: - Live Body

    private static func liveBody(for tournament: Tournament) -> String {
        var parts: [String] = []

        if let displayLevel = tournament.currentDisplayLevel {
            parts.append("Level \(displayLevel)")
        }

        if let latest = tournament.latestStack {
            parts.append("Stack: \(latest.formattedChipCount) (\(Int(latest.bbCount)) BBs)")
        }

        if tournament.playersRemaining > 0, tournament.fieldSize > 0 {
            parts.append("\(tournament.playersRemaining)/\(tournament.fieldSize) remaining")
        }

        return parts.joined(separator: " | ")
    }

    // MARK: - Completed Body

    private static func completedBody(for tournament: Tournament) -> String {
        var parts: [String] = []

        if let finish = tournament.finishPosition {
            let suffix = ordinalSuffix(finish)
            var text = "Finished \(finish)\(suffix)"
            if tournament.fieldSize > 0 {
                text += " of \(tournament.fieldSize)"
            }
            parts.append(text)
        }

        if let profit = tournament.profit {
            let sign = profit >= 0 ? "+" : ""
            parts.append("Profit: \(sign)$\(profit)")
        }

        parts.append("Duration: \(tournament.durationFormatted)")

        return parts.joined(separator: " | ")
    }

    // MARK: - Hashtags

    static func hashtags(for tournament: Tournament) -> String {
        var tags: [String] = ["#poker", "#tournament"]

        let eventTag = sanitizeHashtag(tournament.name)
        if !eventTag.isEmpty {
            tags.append("#\(eventTag)")
        }

        if let venue = tournament.venueName, !venue.isEmpty {
            let venueTag = sanitizeHashtag(venue)
            if !venueTag.isEmpty {
                tags.append("#\(venueTag)")
            }
        }

        let gameTag = tournament.gameType.rawValue
        if !gameTag.isEmpty {
            tags.append("#\(gameTag)")
        }

        tags.append("#StackTrackerPro")
        return tags.joined(separator: " ")
    }

    // MARK: - Character Counting

    static func remainingCharacters(for text: String) -> Int {
        280 - weightedTweetLength(of: text)
    }

    /// X does not count Swift Characters — it counts weighted code points:
    /// every URL is wrapped in t.co and costs a fixed 23, CJK and emoji
    /// count as 2, and most other code points count as 1.
    static func weightedTweetLength(of text: String) -> Int {
        var weighted = 0

        // URLs: fixed weight of 23 each, regardless of actual length.
        var urlRanges: [Range<String.Index>] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let fullRange = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: fullRange) {
                if let range = Range(match.range, in: text) {
                    urlRanges.append(range)
                    weighted += 23
                }
            }
        }

        var index = text.startIndex
        while index < text.endIndex {
            if let url = urlRanges.first(where: { $0.contains(index) }) {
                index = url.upperBound
                continue
            }
            weighted += weight(of: text[index])
            index = text.index(after: index)
        }
        return weighted
    }

    /// Weight of a single grapheme cluster outside a URL.
    private static func weight(of char: Character) -> Int {
        // Emoji count as 2 no matter how many scalars compose them
        // (skin tones, ZWJ sequences, flags, etc.).
        let isEmoji = char.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C)
        }
        if isEmoji { return 2 }

        return char.unicodeScalars.reduce(0) { $0 + scalarWeight($1) }
    }

    /// X's weighted ranges: CJK and other wide scripts are 2, the rest 1.
    private static func scalarWeight(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x1100...0x11FF,    // Hangul Jamo
             0x2E80...0x303E,    // CJK radicals, Kangxi, CJK symbols & punctuation
             0x3041...0x33FF,    // Hiragana, Katakana, CJK compatibility
             0x3400...0x4DBF,    // CJK extension A
             0x4E00...0x9FFF,    // CJK unified ideographs
             0xA960...0xA97F,    // Hangul Jamo extended A
             0xAC00...0xD7FF,    // Hangul syllables & Jamo extended B
             0xF900...0xFAFF,    // CJK compatibility ideographs
             0xFE30...0xFE4F,    // CJK compatibility forms
             0xFF00...0xFFEF,    // Full-width / half-width forms
             0x20000...0x2FFFD,  // CJK extensions B-F
             0x30000...0x3FFFD:  // CJK extension G
            return 2
        default:
            return 1
        }
    }

    // MARK: - Helpers

    static func sanitizeHashtag(_ input: String) -> String {
        let words = input.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }

        if words.count == 1 {
            return words[0].filter { $0.isLetter || $0.isNumber }
        }

        // camelCase multi-word strings
        var result = ""
        for (index, word) in words.enumerated() {
            let cleaned = word.filter { $0.isLetter || $0.isNumber }
            guard !cleaned.isEmpty else { continue }
            if index == 0 {
                result += cleaned.lowercased()
            } else {
                result += cleaned.prefix(1).uppercased() + cleaned.dropFirst().lowercased()
            }
        }
        return result
    }

    private static func ordinalSuffix(_ n: Int) -> String {
        let tens = (n / 10) % 10
        if tens == 1 { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }
}
