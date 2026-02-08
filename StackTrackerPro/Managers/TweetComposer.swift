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
        280 - text.count
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
