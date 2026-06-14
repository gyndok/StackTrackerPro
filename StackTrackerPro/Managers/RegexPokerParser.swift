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

    /// Returns a copy with implausible or internally inconsistent values
    /// dropped. Defense in depth: a single bad parse — especially a
    /// hallucinated value from the on-device AI model — must never write
    /// garbage into the live session. Applied at the parse boundary so both
    /// the AI and regex paths (and the generated response) use clean values.
    func sanitized() -> ParsedEntities {
        var e = self

        // A single poker stack never approaches a billion chips; blinds share
        // the same ceiling. Fields/positions use a separate, smaller ceiling.
        let chipCeiling = 1_000_000_000
        let fieldCeiling = 1_000_000

        // Stack: strictly positive and within a sane ceiling.
        if let c = e.chipCount, c <= 0 || c > chipCeiling { e.chipCount = nil }

        // Blinds: strictly positive; a big blind below the small blind is a
        // misparse, so drop both. Ante is non-negative.
        if let sb = e.smallBlind, sb <= 0 || sb > chipCeiling { e.smallBlind = nil }
        if let bb = e.bigBlind, bb <= 0 || bb > chipCeiling { e.bigBlind = nil }
        if let sb = e.smallBlind, let bb = e.bigBlind, bb < sb {
            e.smallBlind = nil
            e.bigBlind = nil
        }
        if let a = e.ante, a < 0 || a > chipCeiling { e.ante = nil }

        // Field counts: strictly positive and sane; players remaining can't
        // exceed total entries when both arrive in the same message.
        if let t = e.totalEntries, t <= 0 || t > fieldCeiling { e.totalEntries = nil }
        if let r = e.playersRemaining, r <= 0 || r > fieldCeiling { e.playersRemaining = nil }
        if let t = e.totalEntries, let r = e.playersRemaining, r > t {
            e.playersRemaining = nil
        }

        // Level / finish position / payout.
        if let l = e.levelNumber, l <= 0 || l > 1000 { e.levelNumber = nil }
        if let f = e.finishPosition, f <= 0 || f > fieldCeiling { e.finishPosition = nil }
        if let p = e.payoutAmount, p < 0 || p > chipCeiling { e.payoutAmount = nil }

        return e
    }
}

final class RegexPokerParser: @unchecked Sendable {
    static let shared = RegexPokerParser()

    private init() {}

    func parse(_ text: String) -> ParsedEntities {
        let input = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var entities = ParsedEntities()

        // Hand note: "hand note: ...", "noted: ...", "HN: ...", "note: ..."
        // A hand note is the entire entity — suppress ALL other extraction so
        // phrases like "note: villain busted my aces" can't trigger
        // eliminations, bounties, rebuys, payouts, blinds, or stack updates.
        if let match = input.firstMatch(of: /(?:hand\s*note|noted|hn|note)\s*:\s*(.+)/) {
            entities.handNote = String(match.1).trimmingCharacters(in: .whitespaces)
            return entities
        }

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
            // Constraint: ParsedEntities has no per-bounty amount field (the
            // bounty value is fixed per tournament), so an amount that clearly
            // describes the bounty itself ("got a $100 bounty") is dropped
            // rather than misrecorded as prize money. All other amounts are
            // recorded as payouts — no minimum threshold.
            let amountBelongsToBounty = input.firstMatch(of: /\$?[\d,]+[kK]?\s*(?:bounty|bounties|knockout|ko)\b/) != nil
            if !amountBelongsToBounty {
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

        // Stack/chip count: "18k", "45,000", "I have 32k", "stack is 45000"
        // Must be parsed AFTER blinds to avoid conflicts
        entities.chipCount = extractStackValue(from: input, entities: entities)

        return entities
    }

    private func extractStackValue(from input: String, entities: ParsedEntities) -> Int? {
        // Explicit stack mentions: "I have 32k", "stack is 45k", "sitting on 32k", "at 32k"
        // The trailing (?![\d,]*\/) guard rejects numbers that are part of
        // blinds notation ("now at 500/1000" must not record stack=500).
        let stackPatterns: [Regex<(Substring, Substring)>] = [
            /(?:i have|stack is|stack at|sitting on|sitting at|at|chips?)\s+(\d+[kKmM]?(?:,\d{3})*)(?![\d,]*\/)/,
            /(\d+[kKmM](?:,\d{3})*)(?![\d,]*\/)\s+(?:chips?|stack)/,
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
