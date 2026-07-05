import Foundation

// Platform-neutral blind-structure parsing, shared between the app's OCR
// scanner (PokerAtlasScanner) and the command-line seeding pipeline in
// tools/seeder. Foundation-only on purpose: no UIKit/SwiftUI/Vision imports,
// so the same file compiles into the macOS CLI. Keep it that way.

struct ScannedBlindLevel {
    var levelNumber: Int
    var smallBlind: Int
    var bigBlind: Int
    var ante: Int
    var durationMinutes: Int
    var isBreak: Bool
    var breakLabel: String?
}

/// Parses OCR'd (or otherwise extracted) text lines into blind levels.
/// Understands two table formats:
/// - Poker Atlas: `Level | Duration | SB | BB | Ante` behind a Name/Length header
/// - WSOP sheets: `LEVEL | [BB] ANTE | BLINDS` with dash blinds ("500-1,000")
enum BlindStructureParser {

    // MARK: - Regex

    private static func regex(_ pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("BlindStructureParser: invalid regex pattern: \(pattern)")
        }
        return regex
    }

    private static let numberPattern = regex(#"\d[\d,]*"#)
    private static let statusBarTimePattern = regex(#"^\d{1,2}:\d{2}\b"#)

    // MARK: - Entry Point

    static func parseBlindLevels(from lines: [String]) -> [ScannedBlindLevel] {
        // WSOP-style structure sheets use a different table format than
        // Poker Atlas — try that interpretation first.
        if let wsopLevels = parseWSOPStructure(from: lines) {
            return wsopLevels
        }

        var levels: [ScannedBlindLevel] = []
        var isPokerAtlasFormat = false
        var levelCounter = 1
        var pastHeader = false

        // Detect Poker Atlas blind structure format by looking for header row
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("name") && lower.contains("length") &&
                (lower.contains("sb") || lower.contains("small")) &&
                (lower.contains("bb") || lower.contains("big")) {
                isPokerAtlasFormat = true
                break
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()

            // Skip header row
            if lower.contains("name") && (lower.contains("sb") || lower.contains("small")) &&
                (lower.contains("bb") || lower.contains("big")) {
                pastHeader = true
                continue
            }

            // Skip chrome and section headers
            if isChromeText(trimmed) { continue }
            if isSectionHeader(trimmed) { continue }

            // Check for break rows
            if lower.hasPrefix("break") || lower.contains("break") && extractNumbers(from: trimmed).count <= 2 {
                if lower.hasPrefix("break") || lower.contains("break") {
                    let breakLabel = extractBreakLabel(from: trimmed)
                    let duration = extractDuration(from: trimmed) ?? 15
                    levels.append(ScannedBlindLevel(
                        levelNumber: levelCounter,
                        smallBlind: 0,
                        bigBlind: 0,
                        ante: 0,
                        durationMinutes: duration,
                        isBreak: true,
                        breakLabel: breakLabel
                    ))
                    levelCounter += 1
                    continue
                }
            }

            // Check for "Level N" rows
            if lower.hasPrefix("level") {
                let numbers = extractNumbers(from: trimmed)
                guard numbers.count >= 3 else { continue }

                // Poker Atlas order: Level#, Duration, SB, BB, [Ante]
                let parsed = interpretPokerAtlasRow(numbers: numbers, expectedLevel: levelCounter)
                if let parsed {
                    levels.append(parsed)
                    levelCounter += 1
                }
                continue
            }

            // Generic row: 3-5 numbers that could be blind levels (only after header)
            if pastHeader || isPokerAtlasFormat {
                let numbers = extractNumbers(from: trimmed)
                if numbers.count >= 3 {
                    let parsed = isPokerAtlasFormat
                        ? interpretPokerAtlasRow(numbers: numbers, expectedLevel: levelCounter)
                        : interpretGenericRow(numbers: numbers, expectedLevel: levelCounter)
                    if let parsed {
                        levels.append(parsed)
                        levelCounter += 1
                    }
                }
            }
        }

        return levels
    }

    // MARK: - WSOP Structure Sheets

    /// Detects and parses WSOP-style structure tables:
    /// `LEVEL | [BB] ANTE | BLINDS` with blinds written as "SB-BB"
    /// (e.g. "500-1,000"). Returns nil when the lines don't look like a
    /// WSOP sheet, so Poker Atlas screenshots never route through here.
    ///
    /// WSOP sheets are two-column posters, so OCR rows frequently merge
    /// schedule text with structure rows ("Day 1B — July 3 (Friday): 2 300
    /// 200-300"); all matching is therefore anchored to the END of the line.
    /// The level duration is stated once per sheet ("Level Duration: 120
    /// minutes"); rows on pages without that line get duration 0, which
    /// `normalizeDurations` resolves after the multi-page merge.
    static func parseWSOPStructure(from lines: [String]) -> [ScannedBlindLevel]? {
        let lowered = lines.map { $0.lowercased() }

        let hasHeader = lowered.contains {
            $0.contains("level") && $0.contains("ante") && $0.contains("blinds")
        }

        // Sheet-wide level duration.
        var sheetDuration = 0
        for line in lowered {
            if let match = line.firstMatch(of: /level\s*duration:?\s*(\d{1,3})\s*min/) {
                sheetDuration = Int(match.1) ?? 0
                break
            }
        }

        // Row patterns, all end-anchored (text to the left is page chrome).
        let fullRow = /(?:^|\s)(\d{1,2})\s+([\d,]{3,})\s+([\d,]{3,})\s*-\s*([\d,]{3,})\s*$/
        let numberlessRow = /(?:^|\s)([\d,]{3,})\s+([\d,]{3,})\s*-\s*([\d,]{3,})\s*$/
        let anteOnlyRow = /(?:^|\s)(\d{1,2})\s+((?:\d{1,3},)+\d{3})\s*$/

        func chips(_ s: Substring) -> Int {
            Int(s.replacingOccurrences(of: ",", with: "")) ?? 0
        }

        var levels: [ScannedBlindLevel] = []
        var lastLevel = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Chip race-off rows ("Remove 500 Chips") are not levels.
            if trimmed.lowercased().contains("remove") { continue }

            if let match = trimmed.firstMatch(of: fullRow) {
                let level = Int(match.1) ?? 0
                let ante = chips(match.2)
                let sb = chips(match.3)
                let bb = chips(match.4)
                guard level > 0, level <= 60, sb > 0, bb >= sb else { continue }
                levels.append(ScannedBlindLevel(
                    levelNumber: level, smallBlind: sb, bigBlind: bb, ante: ante,
                    durationMinutes: sheetDuration, isBreak: false, breakLabel: nil
                ))
                lastLevel = level
            } else if let match = trimmed.firstMatch(of: numberlessRow) {
                // OCR dropped the level number; infer from the previous row.
                guard lastLevel > 0 else { continue }
                let ante = chips(match.1)
                let sb = chips(match.2)
                let bb = chips(match.3)
                guard sb > 0, bb >= sb else { continue }
                lastLevel += 1
                levels.append(ScannedBlindLevel(
                    levelNumber: lastLevel, smallBlind: sb, bigBlind: bb, ante: ante,
                    durationMinutes: sheetDuration, isBreak: false, breakLabel: nil
                ))
            } else if let match = trimmed.firstMatch(of: anteOnlyRow) {
                // OCR lost the blinds column. On WSOP big-blind-ante sheets
                // the ante always equals the big blind; the small blind is
                // approximated as half and can be corrected in the editor.
                let level = Int(match.1) ?? 0
                let ante = chips(match.2)
                guard level > 0, level <= 60, ante > 0 else { continue }
                levels.append(ScannedBlindLevel(
                    levelNumber: level, smallBlind: ante / 2, bigBlind: ante, ante: ante,
                    durationMinutes: sheetDuration, isBreak: false, breakLabel: nil
                ))
                lastLevel = level
            }
        }

        // Require the WSOP header or a convincing number of dash-format rows
        // so this never hijacks a Poker Atlas structure.
        guard hasHeader || levels.count >= 3, !levels.isEmpty else { return nil }
        return levels.sorted { $0.levelNumber < $1.levelNumber }
    }

    /// Replaces the duration-0 sentinel (WSOP pages without a "Level
    /// Duration" line) with the duration found elsewhere on the sheet,
    /// falling back to 30 minutes.
    static func normalizeDurations(_ levels: [ScannedBlindLevel]) -> [ScannedBlindLevel] {
        guard levels.contains(where: { $0.durationMinutes <= 0 }) else { return levels }
        let known = levels.first(where: { !$0.isBreak && $0.durationMinutes > 0 })?.durationMinutes ?? 30
        return levels.map { level in
            var normalized = level
            if normalized.durationMinutes <= 0 { normalized.durationMinutes = known }
            return normalized
        }
    }

    // MARK: - Row Interpretation

    /// Poker Atlas column order: [LevelNumber, Duration, SB, BB, Ante]
    private static func interpretPokerAtlasRow(numbers: [Int], expectedLevel: Int) -> ScannedBlindLevel? {
        guard numbers.count >= 3 else { return nil }

        var idx = 0
        var levelNum = expectedLevel

        // First number is level number if it's small and reasonable
        if numbers[0] <= 50 && (numbers[0] == expectedLevel || numbers[0] <= 30) {
            levelNum = numbers[0]
            idx = 1
        }

        let remaining = Array(numbers[idx...])
        // Poker Atlas: [Duration, SB, BB, Ante?]
        guard remaining.count >= 3 else { return nil }

        let duration = remaining[0]
        let sb = remaining[1]
        let bb = remaining[2]
        let ante = remaining.count >= 4 ? remaining[3] : 0

        // Sanity: SB and BB should be positive, BB >= SB, duration 1-120
        guard sb > 0, bb >= sb, duration >= 1, duration <= 120 else { return nil }

        return ScannedBlindLevel(
            levelNumber: levelNum,
            smallBlind: sb,
            bigBlind: bb,
            ante: ante,
            durationMinutes: duration,
            isBreak: false
        )
    }

    private static func interpretGenericRow(numbers: [Int], expectedLevel: Int) -> ScannedBlindLevel? {
        var idx = 0
        var levelNum = expectedLevel

        if numbers.count >= 4, numbers[0] <= 50, numbers[0] == expectedLevel {
            levelNum = numbers[0]
            idx = 1
        } else if numbers.count >= 3, numbers[0] == expectedLevel, numbers[0] <= 50 {
            levelNum = numbers[0]
            idx = 1
        }

        let remaining = Array(numbers[idx...])
        guard remaining.count >= 2 else { return nil }

        let sb = remaining[0]
        let bb = remaining[1]
        guard sb > 0, bb >= sb else { return nil }

        var ante = 0
        var duration = 30

        if remaining.count == 4 {
            ante = remaining[2]
            duration = remaining[3]
        } else if remaining.count == 3 {
            let third = remaining[2]
            if third >= 5 && third <= 60 && third < sb {
                duration = third
            } else {
                ante = third
            }
        }

        if duration < 1 || duration > 120 { duration = 30 }

        return ScannedBlindLevel(
            levelNumber: levelNum,
            smallBlind: sb,
            bigBlind: bb,
            ante: ante,
            durationMinutes: duration,
            isBreak: false
        )
    }

    // MARK: - Text Helpers

    static func extractNumbers(from text: String) -> [Int] {
        let range = NSRange(text.startIndex..., in: text)
        let matches = numberPattern.matches(in: text, range: range)
        return matches.compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            return Int(String(text[r]).replacingOccurrences(of: ",", with: ""))
        }
    }

    private static func extractDuration(from text: String) -> Int? {
        let numbers = extractNumbers(from: text)
        if let dur = numbers.last, dur >= 1, dur <= 60 {
            return dur
        }
        return nil
    }

    private static func extractBreakLabel(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove trailing numbers (duration)
        let withoutNumbers = trimmed.replacingOccurrences(
            of: #"\s*\d+\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        return withoutNumbers.isEmpty ? "Break" : withoutNumbers
    }

    static func isChromeText(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)

        // Very short strings
        if lower.count <= 3 { return true }

        // Status bar time patterns: "3:30", "3:30 4", "12:45 PM"
        if statusBarTimePattern.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
            return true
        }

        // Date patterns: "Today - Thursday, ..." or just a date
        if lower.hasPrefix("today") { return true }

        // Known chrome / UI elements
        let chrome = [
            "back", "home", "search", "menu", "share", "settings",
            "notifications", "poker atlas", "pokeratlas", "http", "www",
            "cancel", "close", "done", "register", "note from"
        ]

        for keyword in chrome {
            if lower == keyword || lower.hasPrefix(keyword + " ") {
                return true
            }
        }

        return false
    }

    /// Detects Poker Atlas section headers that should be skipped
    static func isSectionHeader(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let headers = [
            "tournament info", "buy-in details", "format", "size",
            "structure", "registration"
        ]
        return headers.contains(lower)
    }
}
