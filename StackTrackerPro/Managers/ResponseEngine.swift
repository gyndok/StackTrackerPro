import Foundation

final class ResponseEngine: @unchecked Sendable {
    static let shared = ResponseEngine()

    private init() {}

    // MARK: - Main Response Generator

    func generateResponse(
        entities: ParsedEntities,
        tournament: Tournament
    ) -> String {
        var sections: [String] = []

        // Stack update section
        if entities.chipCount != nil, let latest = tournament.latestStack {
            sections.append(stackUpdateResponse(entry: latest, tournament: tournament))
        }

        // Level change
        if entities.levelNumber != nil || entities.smallBlind != nil {
            if let blinds = tournament.currentBlinds {
                sections.append(levelChangeResponse(blinds: blinds, tournament: tournament))
            }
        }

        // Field update
        if entities.totalEntries != nil || entities.playersRemaining != nil {
            sections.append(fieldUpdateResponse(tournament: tournament))
        }

        // Bounty
        if entities.bountyCollected {
            sections.append(bountyResponse(tournament: tournament))
        }

        // Rebuy
        if entities.tookRebuy {
            sections.append(rebuyResponse(tournament: tournament))
        }

        // Elimination
        if entities.isEliminated {
            if let position = entities.finishPosition, let payout = entities.payoutAmount {
                sections.append(tournamentCompleteResponse(
                    position: position,
                    payout: payout,
                    tournament: tournament
                ))
            } else if let position = entities.finishPosition {
                sections.append(eliminationResponse(position: position, tournament: tournament))
            } else {
                sections.append(eliminationResponse(position: nil, tournament: tournament))
            }
        }

        // Hand note
        if let noteText = entities.handNote {
            sections.append(handNoteResponse(noteText: noteText, tournament: tournament))
        }

        if sections.isEmpty {
            return fallbackResponse(entities: entities)
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Stack Update

    func stackUpdateResponse(entry: StackEntry, tournament: Tournament) -> String {
        let bbCount = entry.bbCount
        let mRatio = entry.mRatio
        let zone = entry.mZone
        let chipStr = entry.formattedChipCount

        var lines: [String] = []
        lines.append("Stack: \(chipStr)")

        if entry.currentBB > 0 {
            lines.append(String(format: "%.0f BB  |  M-ratio: %.1f (%@)", bbCount, mRatio, zone.rawValue))
        }

        // Average stack comparison
        let avg = tournament.averageStack
        if avg > 0 {
            let pctOfAvg = Double(entry.chipCount) / Double(avg) * 100
            lines.append(String(format: "Avg stack: %@  |  You're at %.0f%% of average",
                                formatChips(avg), pctOfAvg))
        }

        // Coaching tip based on zone
        if entry.currentBB > 0 {
            lines.append(zone.coachingTip)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Field Update

    func fieldUpdateResponse(tournament: Tournament) -> String {
        var lines: [String] = []

        if tournament.fieldSize > 0 {
            lines.append("Field: \(tournament.fieldSize) entries")
        }
        if tournament.playersRemaining > 0 {
            lines.append("\(tournament.playersRemaining) players remaining")
            if tournament.fieldSize > 0 {
                let pctRemaining = Double(tournament.playersRemaining) / Double(tournament.fieldSize) * 100
                lines.append(String(format: "%.0f%% of field eliminated", 100 - pctRemaining))
            }
        }

        let avg = tournament.averageStack
        if avg > 0 {
            lines.append("Average stack: \(formatChips(avg))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Level Change

    func levelChangeResponse(blinds: BlindLevel, tournament: Tournament) -> String {
        if blinds.isBreak {
            return "Break time! Good time to stretch and reset."
        }

        let displayLevel = tournament.displayLevelNumbers[blinds.levelNumber] ?? blinds.levelNumber
        var lines: [String] = []
        lines.append("Level \(displayLevel): \(blinds.blindsDisplay)")
        lines.append("Orbit cost: \(formatChips(blinds.orbitCost))")
        return lines.joined(separator: "\n")
    }

    // MARK: - Bounty

    func bountyResponse(tournament: Tournament) -> String {
        let total = tournament.bountiesCollected
        var text = "Bounty collected! (\(total) total)"
        if tournament.bountyAmount > 0 {
            let totalValue = total * tournament.bountyAmount
            text += "\nBounty earnings: $\(totalValue)"
        }
        return text
    }

    // MARK: - Rebuy

    func rebuyResponse(tournament: Tournament) -> String {
        let total = tournament.rebuysUsed
        let investment = tournament.totalInvestment
        return "Rebuy recorded (\(total) total)\nTotal investment: $\(investment)"
    }

    // MARK: - Elimination

    func eliminationResponse(position: Int?, tournament: Tournament) -> String {
        var lines: [String] = []
        if let position {
            lines.append("Finished in \(ordinal(position)) place")
        } else {
            lines.append("Tournament complete")
        }

        if tournament.fieldSize > 0 {
            if let pos = position {
                let pct = Double(pos) / Double(tournament.fieldSize) * 100
                lines.append(String(format: "Top %.0f%% of %d entries", pct, tournament.fieldSize))
            }
        }

        lines.append("Total invested: $\(tournament.totalInvestment)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Tournament Complete (with payout)

    func tournamentCompleteResponse(position: Int, payout: Int, tournament: Tournament) -> String {
        var lines: [String] = []
        lines.append("Finished \(ordinal(position)) — Cashed for $\(payout)!")

        if tournament.fieldSize > 0 {
            let pct = Double(position) / Double(tournament.fieldSize) * 100
            lines.append(String(format: "Top %.1f%% of %d entries", pct, tournament.fieldSize))
        }

        let investment = tournament.totalInvestment
        let bountyEarnings = tournament.bountiesCollected * tournament.bountyAmount
        let totalReturn = payout + bountyEarnings
        let profit = totalReturn - investment

        lines.append("Investment: $\(investment)")
        if bountyEarnings > 0 {
            lines.append("Bounties: $\(bountyEarnings)")
        }
        lines.append("Total return: $\(totalReturn)")
        lines.append(profit >= 0 ? "Profit: +$\(profit)" : "Loss: -$\(abs(profit))")

        return lines.joined(separator: "\n")
    }

    // MARK: - Hand Note

    func handNoteResponse(noteText: String, tournament: Tournament) -> String {
        let preview = noteText.count > 60 ? String(noteText.prefix(60)) + "..." : noteText
        var lines: [String] = []
        lines.append("Hand noted: \"\(preview)\"")

        var context: [String] = []
        if let displayLevel = tournament.currentDisplayLevel {
            context.append("Level \(displayLevel)")
        }
        if let stack = tournament.latestStack {
            context.append("Stack: \(stack.formattedChipCount)")
        }
        if !context.isEmpty {
            lines.append(context.joined(separator: " | "))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Session Summary

    func sessionSummaryResponse(tournament: Tournament) -> String {
        let entries = tournament.sortedStackEntries
        guard let first = entries.first, let last = entries.last else {
            return "No stack data recorded."
        }

        var lines: [String] = []
        lines.append("Session Summary")
        lines.append("Starting stack: \(formatChips(first.chipCount))")
        lines.append("Final stack: \(formatChips(last.chipCount))")

        let change = last.chipCount - first.chipCount
        if change >= 0 {
            lines.append("Change: +\(formatChips(change))")
        } else {
            lines.append("Change: -\(formatChips(abs(change)))")
        }

        if entries.count > 1 {
            let peak = entries.max(by: { $0.chipCount < $1.chipCount })!.chipCount
            let valley = entries.min(by: { $0.chipCount < $1.chipCount })!.chipCount
            lines.append("Peak: \(formatChips(peak))  |  Valley: \(formatChips(valley))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Fallback

    private func fallbackResponse(entities: ParsedEntities) -> String {
        "Got it. Try messages like \"18k\", \"level 7\", \"310 left\", or \"got a bounty\"."
    }

    // MARK: - Helpers

    private func formatChips(_ value: Int) -> String {
        if value >= 1_000_000 {
            let m = Double(value) / 1_000_000.0
            return String(format: "%.1fM", m)
        } else if value >= 1000 {
            let k = Double(value) / 1000.0
            if k == Double(Int(k)) {
                return "\(Int(k))k"
            }
            return String(format: "%.1fk", k)
        }
        return "\(value)"
    }

    private func ordinal(_ n: Int) -> String {
        let suffix: String
        let ones = n % 10
        let tens = (n / 10) % 10

        if tens == 1 {
            suffix = "th"
        } else {
            switch ones {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }
}
