import Foundation

struct ParsedEntities {
    var chipCount: Int?
    var smallBlind: Int?
    var bigBlind: Int?
    var ante: Int?
    var levelNumber: Int?
    var totalEntries: Int?
    var playersRemaining: Int?
    var finishPosition: Int?
    var payoutAmount: Int?
    var bountyCollected: Bool = false
    var tookRebuy: Bool = false
    var isEliminated: Bool = false
    var handNote: String?

    var hasAnyData: Bool {
        chipCount != nil || smallBlind != nil || bigBlind != nil ||
        ante != nil || levelNumber != nil || totalEntries != nil ||
        playersRemaining != nil || finishPosition != nil ||
        payoutAmount != nil || bountyCollected || tookRebuy ||
        isEliminated || handNote != nil
    }
}

final class RegexPokerParser: @unchecked Sendable {
    static let shared = RegexPokerParser()

    private init() {}

    func parse(_ text: String) -> ParsedEntities {
        let input = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var entities = ParsedEntities()

        // Level number: "level 7", "lvl 7", "lv 7"
        if let match = input.firstMatch(of: /(?:level|lvl|lv)\s*(\d+)/) {
            entities.levelNumber = Int(match.1)
        }

        // Blinds: "500/1000", "1k/2k", "500/1000/100" (with ante)
        if let match = input.firstMatch(of: /(\d+[kK]?)\s*\/\s*(\d+[kK]?)(?:\s*\/\s*(\d+[kK]?))?/) {
            entities.smallBlind = parseChipValue(String(match.1))
            entities.bigBlind = parseChipValue(String(match.2))
            if let anteStr = match.3 {
                entities.ante = parseChipValue(String(anteStr))
            }
        }

        // Bounty: "got a bounty", "bounty", "collected a bounty", "knocked someone out"
        if input.contains("bounty") || input.contains("knocked") || input.contains("knock out") {
            entities.bountyCollected = true
        }

        // Rebuy: "rebought", "rebuy", "re-entry", "reentry", "I rebought"
        if input.contains("rebuy") || input.contains("rebought") || input.contains("re-entry") || input.contains("reentry") || input.contains("re-buy") {
            entities.tookRebuy = true
        }

        // Elimination: "busted", "eliminated", "out"
        if let match = input.firstMatch(of: /(?:busted|eliminated|finished|came in)\s*(?:in\s+)?(\d+)(?:st|nd|rd|th)?/) {
            entities.finishPosition = Int(match.1)
            entities.isEliminated = true
        } else if input.contains("busted") || input.contains("eliminated") || input == "out" || input.contains("i'm out") {
            entities.isEliminated = true
        }

        // Payout: "cashed for $680", "won $1200", "payout $500", "got $680"
        if let match = input.firstMatch(of: /(?:cashed|won|payout|got|paid|collected)\s*(?:for\s+)?\$?([\d,]+[kK]?)/) {
            let value = parseChipValue(String(match.1).replacingOccurrences(of: ",", with: ""))
            if !entities.bountyCollected || value > 200 {
                entities.payoutAmount = value
            }
        }

        // Total entries: "375 entries", "375 runners"
        if let match = input.firstMatch(of: /(\d+)\s*(?:entries|runners|entrants|registered)/) {
            entities.totalEntries = Int(match.1)
        }

        // Players remaining: "310 left", "310 remaining", "down to 310"
        if let match = input.firstMatch(of: /(\d+)\s*(?:left|remaining|players left|remain)/) {
            entities.playersRemaining = Int(match.1)
        } else if let match = input.firstMatch(of: /(?:down to|field|field is)\s*(\d+)/) {
            entities.playersRemaining = Int(match.1)
        }

        // Hand note: "hand note: ...", "noted: ...", "HN: ...", "note: ..."
        if let match = input.firstMatch(of: /(?:hand\s*note|noted|hn|note)\s*:\s*(.+)/) {
            entities.handNote = String(match.1).trimmingCharacters(in: .whitespaces)
        }

        // Stack/chip count: "18k", "45,000", "I have 32k", "stack is 45000"
        // Must be parsed AFTER blinds to avoid conflicts
        // Skip if message is a hand note to prevent false stack updates
        if entities.handNote == nil {
            entities.chipCount = extractStackValue(from: input, entities: entities)
        }

        return entities
    }

    private func extractStackValue(from input: String, entities: ParsedEntities) -> Int? {
        // Explicit stack mentions: "I have 32k", "stack is 45k", "sitting on 32k", "at 32k"
        let stackPatterns: [Regex<(Substring, Substring)>] = [
            /(?:i have|stack is|stack at|sitting on|sitting at|at|chips?)\s+(\d+[kKmM]?(?:,\d{3})*)/,
            /(\d+[kKmM](?:,\d{3})*)\s+(?:chips?|stack)/,
        ]

        for pattern in stackPatterns {
            if let match = input.firstMatch(of: pattern) {
                let val = parseChipValue(String(match.1).replacingOccurrences(of: ",", with: ""))
                if val > 0 { return val }
            }
        }

        // Bare number that looks like a stack (>= 1000 or has k/m suffix)
        // Avoid matching numbers already captured as blinds, entries, level, etc.
        let tokens = input.components(separatedBy: .whitespacesAndNewlines)
        for token in tokens {
            let cleaned = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard !cleaned.isEmpty else { continue }

            // Skip if this token is part of a blinds pattern (contains /)
            if token.contains("/") { continue }

            // Skip if this matches level, entries, remaining, etc.
            if cleaned.allSatisfy({ $0.isNumber }) {
                let val = Int(cleaned) ?? 0
                // Bare numbers >= 1000 could be stacks
                if val >= 1000, entities.smallBlind == nil || val != entities.smallBlind,
                   entities.bigBlind == nil || val != entities.bigBlind,
                   entities.levelNumber == nil || val != entities.levelNumber,
                   entities.totalEntries == nil || val != entities.totalEntries,
                   entities.playersRemaining == nil || val != entities.playersRemaining,
                   entities.finishPosition == nil || val != entities.finishPosition {
                    return val
                }
            } else if cleaned.hasSuffix("k") || cleaned.hasSuffix("K") || cleaned.hasSuffix("m") || cleaned.hasSuffix("M") {
                let val = parseChipValue(cleaned)
                if val > 0, entities.smallBlind == nil || val != entities.smallBlind,
                   entities.bigBlind == nil || val != entities.bigBlind {
                    return val
                }
            }
        }

        return nil
    }

    func parseChipValue(_ str: String) -> Int {
        let cleaned = str.lowercased().trimmingCharacters(in: .whitespaces)
        if cleaned.hasSuffix("m") {
            if let num = Double(cleaned.dropLast()) {
                return Int(num * 1_000_000)
            }
        } else if cleaned.hasSuffix("k") {
            if let num = Double(cleaned.dropLast()) {
                return Int(num * 1000)
            }
        } else if let num = Int(cleaned) {
            return num
        }
        return 0
    }
}
