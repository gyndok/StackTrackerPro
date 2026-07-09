import Foundation

/// Builds a single self-contained Markdown file for a completed tournament:
/// a ready-made prompt for a frontier AI model, the tournament's summary and
/// structure, a chronological merged timeline, the raw stack series as CSV,
/// hand notes, and the chat transcript. The user shares the file straight
/// into an AI app to get a polished PDF recap.
enum TournamentRecapExporter {

    // MARK: - Entry Points

    /// Full markdown document for the tournament.
    static func markdown(for tournament: Tournament) -> String {
        var sections: [String] = []
        sections.append(promptHeader(for: tournament))
        sections.append(summarySection(for: tournament))
        sections.append(structureSection(for: tournament))
        sections.append(timelineSection(for: tournament))
        sections.append(stackSeriesSection(for: tournament))
        sections.append(handNotesSection(for: tournament))
        sections.append(structuredHandsSection(for: tournament))
        sections.append(pendingStubsSection(for: tournament))
        sections.append(chatTranscriptSection(for: tournament))
        return sections.joined(separator: "\n\n")
    }

    /// Writes the recap to a temp file and returns its URL for sharing.
    static func writeRecapFile(for tournament: Tournament) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Recaps", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = tournament.name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = "\(safeName.isEmpty ? "tournament" : safeName)-recap.md"
        let url = directory.appendingPathComponent(fileName)

        try markdown(for: tournament).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Formatters

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let csvTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static func stamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private static func money(_ value: Int) -> String {
        "$\(value.formatted())"
    }

    // MARK: - Sections

    private static func promptHeader(for tournament: Tournament) -> String {
        """
        # Tournament Recap Data — \(tournament.name)

        > **Prompt for the AI assistant reading this file:**
        > Produce a polished, single-document PDF recap of this poker tournament.
        > Include: (1) a headline summary of the result and profit/loss; (2) a
        > stack-over-time line chart built from the Stack Series CSV below, with
        > the blind level on the x-axis context; (3) an entrants vs. players-
        > remaining progression chart from the timeline data; (4) a financial
        > breakdown (buy-in, fees, add-ons, bounties, payout, net); (5) a
        > narrative of the session's key moments using the timeline, hand
        > notes, and the street-by-street Structured Hands, and FadeNotes
        > (player-confirmed gradual losses — treat them as authoritative, not
        > unknowns) — call out swings, the bubble, and any notable hands; (6) the
        > blind structure as an appendix table. Keep the tone knowledgeable and
        > concise, like a poker coach's session debrief. All timestamps are
        > local to the player.
        """
    }

    private static func summarySection(for tournament: Tournament) -> String {
        var lines: [String] = ["## Summary", ""]
        lines.append("| Field | Value |")
        lines.append("|---|---|")
        lines.append("| Tournament | \(tournament.name) |")
        if let venue = tournament.venueName, !venue.isEmpty {
            lines.append("| Venue | \(venue) |")
        }
        lines.append("| Game | \(tournament.gameTypeRaw) |")
        lines.append("| Date | \(stamp(tournament.actualStartDate ?? tournament.startDate)) |")
        lines.append("| Buy-in (total) | \(money(tournament.buyIn)) |")
        if tournament.entryFee > 0 { lines.append("| Entry fee (rake) | \(money(tournament.entryFee)) |") }
        if tournament.bountyAmount > 0 { lines.append("| Bounty | \(money(tournament.bountyAmount)) |") }
        if tournament.rebuysUsed > 0 { lines.append("| Rebuys taken | \(tournament.rebuysUsed) |") }
        if tournament.addOnAvailable {
            lines.append("| Add-on | \(money(tournament.addOnCost)) for \(tournament.addOnChips.formatted()) chips (\(money(tournament.addOnRake)) rake) |")
            lines.append("| Add-ons (field / mine) | \(tournament.addOnsCount) / \(tournament.playerAddOnsUsed) |")
        }
        lines.append("| Starting chips | \(tournament.startingChips.formatted()) |")
        if tournament.fieldSize > 0 { lines.append("| Entries | \(tournament.fieldSize) |") }
        if tournament.guarantee > 0 { lines.append("| Guarantee | \(money(tournament.guarantee)) |") }
        if tournament.prizePool > 0 { lines.append("| Prize pool (est.) | \(money(tournament.prizePool)) |") }
        if let position = tournament.finishPosition {
            lines.append("| Finish | \(position)\(tournament.fieldSize > 0 ? " of \(tournament.fieldSize)" : "") |")
        }
        if let payout = tournament.payout { lines.append("| Payout | \(money(payout)) |") }
        if tournament.bountyWinnings > 0 { lines.append("| Bounty winnings | \(money(tournament.bountyWinnings)) |") }
        lines.append("| Total invested | \(money(tournament.totalInvestment)) |")
        if let profit = tournament.profit {
            lines.append("| Net result | \(profit >= 0 ? "+" : "−")\(money(abs(profit))) |")
        }
        lines.append("| Duration (active play) | \(tournament.durationFormatted) |")
        if tournament.accumulatedPauseSeconds > 0 {
            lines.append("| Time paused | \(tournament.accumulatedPauseSeconds / 60)m |")
        }
        return lines.joined(separator: "\n")
    }

    private static func structureSection(for tournament: Tournament) -> String {
        var lines: [String] = ["## Blind Structure", ""]
        let levels = tournament.sortedBlindLevels
        guard !levels.isEmpty else {
            lines.append("_No blind structure recorded._")
            return lines.joined(separator: "\n")
        }
        lines.append("| Level | SB | BB | Ante | Minutes |")
        lines.append("|---|---|---|---|---|")
        for level in levels {
            if level.isBreak {
                lines.append("| \(level.breakLabel ?? "Break") | — | — | — | \(level.durationMinutes) |")
            } else {
                lines.append("| \(level.levelNumber) | \(level.smallBlind.formatted()) | \(level.bigBlind.formatted()) | \(level.ante.formatted()) | \(level.durationMinutes) |")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Every timestamped happening, merged and sorted chronologically.
    private static func timelineSection(for tournament: Tournament) -> String {
        var rows: [(Date, String)] = []

        if let start = tournament.actualStartDate {
            rows.append((start, "Tournament started"))
        }
        for entry in tournament.sortedStackEntries {
            var line = "Stack: \(entry.chipCount.formatted())"
            if entry.currentBB > 0 {
                line += " (\(String(format: "%.1f", entry.bbCount)) BB at \(entry.currentSB.formatted())/\(entry.currentBB.formatted()))"
            }
            rows.append((entry.timestamp, line))
        }
        for snapshot in (tournament.fieldSnapshots ?? []).sorted(by: { $0.timestamp < $1.timestamp }) {
            var line = "Field: \(snapshot.totalEntries) entries, \(snapshot.playersRemaining) remaining"
            if let avg = snapshot.avgStack { line += ", avg stack \(avg.formatted())" }
            rows.append((snapshot.timestamp, line))
        }
        for event in tournament.sortedEvents {
            rows.append((event.timestamp, event.timelineDescription))
        }
        for bounty in (tournament.bountyEvents ?? []).sorted(by: { $0.timestamp < $1.timestamp }) {
            rows.append((bounty.timestamp, "Bounty collected\(bounty.amount > 0 ? " (\(money(bounty.amount)))" : "")"))
        }
        for breakEntry in tournament.sortedBreakEntries {
            rows.append((breakEntry.timestamp, "Break started (\(breakEntry.breakDurationSeconds / 60)m) at \(breakEntry.blindsDisplay), stack \(breakEntry.chipCount.formatted())"))
        }
        for note in tournament.sortedHandNotes {
            rows.append((note.timestamp, "Hand note: \(note.descriptionText)"))
        }
        for fade in tournament.sortedFadeNotes {
            let sign = fade.chipDelta >= 0 ? "+" : "−"
            rows.append((fade.intervalEnd,
                "Fade: \(sign)\(abs(fade.chipDelta).formatted()) — \(fade.userExplanation)"))
        }
        if let end = tournament.endDate {
            rows.append((end, "Tournament ended"))
        }

        rows.sort { $0.0 < $1.0 }

        var lines: [String] = ["## Timeline", ""]
        guard !rows.isEmpty else {
            lines.append("_No timeline data recorded._")
            return lines.joined(separator: "\n")
        }
        lines.append("| Time | Event |")
        lines.append("|---|---|")
        for (date, text) in rows {
            lines.append("| \(stamp(date)) | \(text.replacingOccurrences(of: "|", with: "/")) |")
        }
        return lines.joined(separator: "\n")
    }

    /// Precise stack data for charting, as a CSV code block.
    private static func stackSeriesSection(for tournament: Tournament) -> String {
        var lines: [String] = ["## Stack Series (CSV)", "", "```csv"]
        lines.append("timestamp,chips,level,small_blind,big_blind,ante,bb_count")
        for entry in tournament.sortedStackEntries {
            let bb = entry.currentBB > 0 ? String(format: "%.1f", entry.bbCount) : ""
            lines.append("\(csvTimestampFormatter.string(from: entry.timestamp)),\(entry.chipCount),\(entry.blindLevelNumber),\(entry.currentSB),\(entry.currentBB),\(entry.currentAnte),\(bb)")
        }
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    private static func handNotesSection(for tournament: Tournament) -> String {
        var lines: [String] = ["## Hand Notes", ""]
        let notes = tournament.sortedHandNotes
        guard !notes.isEmpty else {
            lines.append("_No hand notes recorded._")
            return lines.joined(separator: "\n")
        }
        for note in notes {
            var context = stamp(note.timestamp)
            if !note.blindsDisplay.isEmpty { context += " · blinds \(note.blindsDisplay)" }
            if let stack = note.stackBefore { context += " · stack \(stack.formatted())" }
            lines.append("- **\(context)** — \(note.descriptionText)")
        }
        return lines.joined(separator: "\n")
    }

    /// Street-by-street structured hands from the hand logger.
    private static func structuredHandsSection(for tournament: Tournament) -> String {
        var lines: [String] = ["## Structured Hands", ""]
        let hands = tournament.sortedHands
        guard !hands.isEmpty else {
            lines.append("_No structured hands logged._")
            return lines.joined(separator: "\n")
        }
        for (index, hand) in hands.enumerated() {
            var header = "### Hand \(index + 1) — \(stamp(hand.timestamp)) — \(hand.heroPosition.rawValue)"
            header += " — \(hand.heroCards.map(\.display).joined(separator: " "))"
            lines.append(header)
            var context = "Blinds \(hand.blindsDisplay)"
            if hand.levelNumber > 0 { context = "Level \(hand.levelNumber), " + context }
            if hand.heroStackChips > 0 { context += ", stack \(hand.heroStackChips.formatted())" }
            if hand.playersRemaining > 0 { context += ", \(hand.playersRemaining) left" }
            lines.append(context)
            if !hand.board.isEmpty {
                lines.append("Board: \(hand.board.map(\.display).joined(separator: " "))")
            }
            for street in HandStreet.allCases {
                let actions = hand.sortedActions.filter { $0.street == street }
                if !actions.isEmpty {
                    lines.append("- \(street.label): " + actions.map(\.timelineDescription).joined(separator: " › "))
                }
            }
            var result = "Result: \(hand.result.rawValue)"
            if hand.potSize > 0 { result += ", pot \(hand.potSize.formatted())" }
            if hand.amountWon != 0 { result += ", net \(hand.amountWon.formatted())" }
            lines.append(result)
            if !hand.villainCards.isEmpty { lines.append("Villain: \(hand.villainCards.map(\.display).joined(separator: " "))") }
            if !hand.tags.isEmpty { lines.append("Tags: \(hand.tags.joined(separator: ", "))") }
            if !hand.notes.isEmpty { lines.append("Note: \(hand.notes)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func pendingStubsSection(for tournament: Tournament) -> String {
        var lines: [String] = ["## Pending Hands (stubs awaiting enrichment)", ""]
        let stubs = tournament.pendingStubs
        guard !stubs.isEmpty else {
            lines.append("_None — every captured hand was enriched._")
            return lines.joined(separator: "\n")
        }
        for stub in stubs {
            lines.append("- \(stamp(stub.createdAt)) — \(stub.exportLine)")
        }
        return lines.joined(separator: "\n")
    }

    private static func chatTranscriptSection(for tournament: Tournament) -> String {
        var lines: [String] = ["## Chat Transcript", ""]
        let messages = tournament.sortedChatMessages
        guard !messages.isEmpty else {
            lines.append("_No chat messages recorded._")
            return lines.joined(separator: "\n")
        }
        for message in messages {
            let speaker = message.isUser ? "Player" : "Tracker"
            lines.append("- `\(stamp(message.timestamp))` **\(speaker):** \(message.text)")
        }
        return lines.joined(separator: "\n")
    }
}
