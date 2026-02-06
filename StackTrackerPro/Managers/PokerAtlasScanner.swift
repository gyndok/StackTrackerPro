import UIKit
import Vision

// MARK: - Scan Result

struct PokerAtlasScanResult {
    var tournamentName: String?
    var venueName: String?
    var gameType: GameType?
    var buyIn: Int?
    var entryFee: Int?
    var bountyAmount: Int?
    var guarantee: Int?
    var startingChips: Int?
    var reentryPolicy: String?
    var blindLevels: [ScannedBlindLevel] = []
}

struct ScannedBlindLevel {
    var levelNumber: Int
    var smallBlind: Int
    var bigBlind: Int
    var ante: Int
    var durationMinutes: Int
    var isBreak: Bool
    var breakLabel: String?
}

// MARK: - Error

enum ScannerError: LocalizedError {
    case invalidImage
    case ocrFailed(Error)
    case noTextFound
    case parsingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Could not process the image."
        case .ocrFailed(let err): return "OCR failed: \(err.localizedDescription)"
        case .noTextFound: return "No text found in the image."
        case .parsingFailed: return "Could not parse poker tournament data from this image."
        }
    }
}

// MARK: - Scanner

final class PokerAtlasScanner: @unchecked Sendable {
    static let shared = PokerAtlasScanner()

    private init() {}

    func scan(image: UIImage) async throws -> PokerAtlasScanResult {
        guard let cgImage = image.cgImage else {
            throw ScannerError.invalidImage
        }

        let lines = try await recognizeText(in: cgImage)
        guard !lines.isEmpty else {
            throw ScannerError.noTextFound
        }

        return parse(lines: lines)
    }

    func scan(images: [UIImage]) async throws -> PokerAtlasScanResult {
        guard !images.isEmpty else { throw ScannerError.invalidImage }

        var allResults: [PokerAtlasScanResult] = []
        for image in images {
            let result = try await scan(image: image)
            allResults.append(result)
        }

        return merge(allResults)
    }

    // MARK: - Merge

    private func merge(_ results: [PokerAtlasScanResult]) -> PokerAtlasScanResult {
        guard !results.isEmpty else { return PokerAtlasScanResult() }
        if results.count == 1 { return results[0] }

        var merged = PokerAtlasScanResult()

        for r in results {
            if merged.tournamentName == nil { merged.tournamentName = r.tournamentName }
            if merged.venueName == nil { merged.venueName = r.venueName }
            if merged.gameType == nil { merged.gameType = r.gameType }
            if merged.buyIn == nil { merged.buyIn = r.buyIn }
            if merged.entryFee == nil { merged.entryFee = r.entryFee }
            if merged.bountyAmount == nil { merged.bountyAmount = r.bountyAmount }
            if merged.guarantee == nil { merged.guarantee = r.guarantee }
            if merged.startingChips == nil { merged.startingChips = r.startingChips }
            if merged.reentryPolicy == nil { merged.reentryPolicy = r.reentryPolicy }
        }

        var allLevels: [ScannedBlindLevel] = []
        for r in results {
            allLevels.append(contentsOf: r.blindLevels)
        }
        merged.blindLevels = deduplicateAndRenumber(allLevels)

        return merged
    }

    private func deduplicateAndRenumber(_ levels: [ScannedBlindLevel]) -> [ScannedBlindLevel] {
        guard !levels.isEmpty else { return [] }

        var unique: [ScannedBlindLevel] = []
        for level in levels {
            let isDuplicate = unique.contains { existing in
                if level.isBreak && existing.isBreak {
                    return existing.breakLabel == level.breakLabel &&
                           existing.durationMinutes == level.durationMinutes
                }
                return !level.isBreak && !existing.isBreak &&
                    existing.smallBlind == level.smallBlind &&
                    existing.bigBlind == level.bigBlind &&
                    existing.ante == level.ante
            }
            if !isDuplicate {
                unique.append(level)
            }
        }

        // Sort: non-break levels by blind size, breaks keep relative position
        // Use the original level number for ordering since it reflects position in structure
        unique.sort { a, b in
            a.levelNumber < b.levelNumber
        }

        return unique.enumerated().map { index, level in
            var renumbered = level
            renumbered.levelNumber = index + 1
            return renumbered
        }
    }

    // MARK: - OCR

    private func recognizeText(in cgImage: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: ScannerError.ocrFailed(error))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let sorted = observations.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }

                let lines = sorted.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }

                continuation.resume(returning: lines)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: ScannerError.ocrFailed(error))
            }
        }
    }

    // MARK: - Parser

    private func parse(lines: [String]) -> PokerAtlasScanResult {
        var result = PokerAtlasScanResult()
        let joined = lines.joined(separator: "\n")
        let lower = joined.lowercased()

        // Build key-value pairs from labeled lines (e.g. "Total Buy-In $400")
        let keyValues = buildKeyValues(from: lines)

        // Tournament name
        parseTournamentName(from: lines, keyValues: keyValues, result: &result)

        // Venue
        parseVenue(from: lines, keyValues: keyValues, result: &result)

        // Game type — check key-values first, then full text
        parseGameType(from: lower, keyValues: keyValues, result: &result)

        // Financials from key-value pairs
        parseFinancials(from: joined, keyValues: keyValues, result: &result)

        // Re-entry
        if let reentry = keyValues["re-entry"] {
            result.reentryPolicy = reentry
        }

        // Blind levels
        result.blindLevels = parseBlindLevels(from: lines)

        return result
    }

    // MARK: - Key-Value Builder

    /// Parses lines like "Total Buy-In $400" or "Starting Chips 30,000" into a dictionary
    private func buildKeyValues(from lines: [String]) -> [String: String] {
        var dict: [String: String] = [:]

        // Known Poker Atlas labels
        let labels = [
            "total buy-in", "entry fee", "deductions", "starting chips",
            "starting blinds", "re-entry", "rebuys", "addons", "bounties",
            "bounty amount", "guarantee", "level time", "game type",
            "event name", "event type", "event number", "start time",
            "event start date", "length of event", "registration opens",
            "registration closes"
        ]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerLine = trimmed.lowercased()

            for label in labels {
                if lowerLine.hasPrefix(label) {
                    let valueStart = trimmed.index(trimmed.startIndex, offsetBy: label.count)
                    let value = String(trimmed[valueStart...])
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
                    if !value.isEmpty {
                        dict[label] = value
                    }
                    break
                }
            }
        }

        // Also try pairing consecutive lines where first is a label and second is a value
        for i in 0..<lines.count - 1 {
            let possibleLabel = lines[i].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let possibleValue = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)

            for label in labels {
                if possibleLabel == label || possibleLabel == label + ":" {
                    if dict[label] == nil && !possibleValue.isEmpty {
                        dict[label] = possibleValue
                    }
                    break
                }
            }
        }

        return dict
    }

    // MARK: - Tournament Name

    private func parseTournamentName(from lines: [String], keyValues: [String: String], result: inout PokerAtlasScanResult) {
        // Prefer "Event Name" key-value
        if let eventName = keyValues["event name"], eventName.count >= 5 {
            result.tournamentName = eventName
            return
        }

        // Fall back to first substantial non-chrome line
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 5, !isChromeText(trimmed) {
                result.tournamentName = trimmed
                return
            }
        }
    }

    // MARK: - Venue

    private func parseVenue(from lines: [String], keyValues: [String: String], result: inout PokerAtlasScanResult) {
        // Look for known venue patterns in Poker Atlas — venue name often appears
        // as a standalone line near location (city, state)
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Check if next line looks like "City, ST" pattern
            if i + 1 < lines.count {
                let nextLine = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                let cityStatePattern = try! NSRegularExpression(pattern: #"^[A-Z][a-zA-Z\s]+,\s*[A-Z]{2}$"#)
                let range = NSRange(nextLine.startIndex..., in: nextLine)
                if cityStatePattern.firstMatch(in: nextLine, range: range) != nil {
                    if trimmed.count >= 3, trimmed.count <= 60, !isChromeText(trimmed) {
                        result.venueName = trimmed
                        return
                    }
                }
            }
        }

        // "at <Venue>" pattern
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("at ") || lower.contains(" at ") {
                if let range = line.range(of: "at ", options: .caseInsensitive) {
                    let venue = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if venue.count >= 3, venue.count <= 50 {
                        result.venueName = venue
                        return
                    }
                }
            }
        }
    }

    // MARK: - Game Type

    private func parseGameType(from lower: String, keyValues: [String: String], result: inout PokerAtlasScanResult) {
        // Check key-value "Game Type" first
        let gameTypeText = (keyValues["game type"] ?? "").lowercased()
        let searchText = gameTypeText.isEmpty ? lower : gameTypeText

        if searchText.contains("pl omaha") || searchText.contains("plo") || searchText.contains("pot limit omaha") || searchText.contains("pot-limit omaha") {
            result.gameType = .plo
        } else if searchText.contains("nlh") || searchText.contains("no limit hold") || searchText.contains("no-limit hold") || searchText.contains("nl hold") || searchText.contains("nl texas") {
            result.gameType = .nlh
        } else if searchText.contains("mixed") {
            result.gameType = .mixed
        }

        // If not found from key-value, try full text
        if result.gameType == nil && !gameTypeText.isEmpty {
            if lower.contains("plo") || lower.contains("pl omaha") || lower.contains("omaha") {
                result.gameType = .plo
            } else if lower.contains("nlh") || lower.contains("hold") {
                result.gameType = .nlh
            }
        }
    }

    // MARK: - Financial Parsers

    private func parseFinancials(from text: String, keyValues: [String: String], result: inout PokerAtlasScanResult) {
        // Poker Atlas key-value format
        let totalBuyIn = parseDollarValue(keyValues["total buy-in"])
        let entryFee = parseDollarValue(keyValues["entry fee"])
        let deductions = parseDollarValue(keyValues["deductions"])

        if let total = totalBuyIn {
            if let ded = deductions, ded > 0, ded < total {
                // buyIn = prize pool portion, entryFee = rake
                result.buyIn = total - ded
                result.entryFee = ded
            } else if let entry = entryFee, entry > 0, entry < total {
                result.buyIn = entry
                result.entryFee = total - entry
            } else {
                result.buyIn = total
            }
        }

        // Fallback: "$X + $Y" format in text
        if result.buyIn == nil {
            parseBuyInFromText(from: text, result: &result)
        }

        // Starting Chips
        if let chips = keyValues["starting chips"] {
            result.startingChips = parseNumberFromString(chips)
        }
        if result.startingChips == nil {
            parseStartingChipsFromText(from: text, result: &result)
        }

        // Guarantee
        if let gtd = keyValues["guarantee"] {
            result.guarantee = parseDollarValue(gtd)
        }
        if result.guarantee == nil {
            parseGuaranteeFromText(from: text, result: &result)
        }

        // Bounty
        if let bounty = keyValues["bounty amount"] {
            result.bountyAmount = parseDollarValue(bounty)
        }
        if result.bountyAmount == nil {
            parseBountyFromText(from: text, result: &result)
        }
    }

    private func parseBuyInFromText(from text: String, result: inout PokerAtlasScanResult) {
        let dollarPlusPattern = try! NSRegularExpression(pattern: #"\$\s*(\d[\d,]*)\s*\+\s*\$\s*(\d[\d,]*)"#)
        let range = NSRange(text.startIndex..., in: text)

        if let match = dollarPlusPattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text),
               let r2 = Range(match.range(at: 2), in: text) {
                result.buyIn = parseNumberFromString(String(text[r1]))
                result.entryFee = parseNumberFromString(String(text[r2]))
                return
            }
        }

        let buyInPattern = try! NSRegularExpression(pattern: #"(?i)buy[\s-]?in[:\s]*\$?\s*(\d[\d,]*)"#)
        if let match = buyInPattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.buyIn = parseNumberFromString(String(text[r1]))
            }
        }
    }

    private func parseStartingChipsFromText(from text: String, result: inout PokerAtlasScanResult) {
        let chipsPattern = try! NSRegularExpression(pattern: #"(?i)(?:starting\s+(?:chips|stack))[:\s]*(\d[\d,]*)"#)
        let range = NSRange(text.startIndex..., in: text)

        if let match = chipsPattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.startingChips = parseNumberFromString(String(text[r1]))
            }
        }
    }

    private func parseGuaranteeFromText(from text: String, result: inout PokerAtlasScanResult) {
        let range = NSRange(text.startIndex..., in: text)

        let gtdPattern1 = try! NSRegularExpression(pattern: #"(?i)\$\s*(\d[\d,]*[kK]?)\s*(?:gtd|guaranteed|guarantee)"#)
        if let match = gtdPattern1.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.guarantee = parseChipValue(String(text[r1]))
                return
            }
        }

        let gtdPattern2 = try! NSRegularExpression(pattern: #"(?i)(?:gtd|guarantee|guaranteed)[:\s]*\$?\s*(\d[\d,]*[kK]?)"#)
        if let match = gtdPattern2.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.guarantee = parseChipValue(String(text[r1]))
            }
        }
    }

    private func parseBountyFromText(from text: String, result: inout PokerAtlasScanResult) {
        let range = NSRange(text.startIndex..., in: text)

        let bountyPattern = try! NSRegularExpression(pattern: #"(?i)bounty[:\s]*\$?\s*(\d[\d,]*)"#)
        if let match = bountyPattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.bountyAmount = parseNumberFromString(String(text[r1]))
            }
        }
    }

    // MARK: - Blind Level Parser

    private func parseBlindLevels(from lines: [String]) -> [ScannedBlindLevel] {
        var levels: [ScannedBlindLevel] = []
        var isPokerAtlasFormat = false
        var levelCounter = 1

        // Detect Poker Atlas blind structure format by looking for header row
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("name") && lower.contains("length") && lower.contains("sb") && lower.contains("bb") {
                isPokerAtlasFormat = true
                break
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()

            // Skip header rows and chrome
            if lower.contains("name") && lower.contains("sb") && lower.contains("bb") { continue }
            if isChromeText(trimmed) { continue }

            // Check for break rows: "Break", "Break 15", "Break - End of Reg... 15"
            if lower.hasPrefix("break") {
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

            // Check for "Level N" rows
            if lower.hasPrefix("level") {
                let numbers = extractNumbers(from: trimmed)
                guard numbers.count >= 3 else { continue }

                if isPokerAtlasFormat || lower.hasPrefix("level ") {
                    // Poker Atlas order: Level#, Duration, SB, BB, [Ante]
                    let parsed = interpretPokerAtlasRow(numbers: numbers, expectedLevel: levelCounter)
                    if let parsed {
                        levels.append(parsed)
                        levelCounter += 1
                    }
                }
                continue
            }

            // Generic row: look for 3-5 numbers that could be blind levels
            let numbers = extractNumbers(from: trimmed)
            if numbers.count >= 3 {
                let parsed: ScannedBlindLevel?
                if isPokerAtlasFormat {
                    parsed = interpretPokerAtlasRow(numbers: numbers, expectedLevel: levelCounter)
                } else {
                    parsed = interpretGenericRow(numbers: numbers, expectedLevel: levelCounter)
                }
                if let parsed {
                    levels.append(parsed)
                    levelCounter += 1
                }
            }
        }

        return levels
    }

    /// Poker Atlas column order: [LevelNumber, Duration, SB, BB, Ante]
    private func interpretPokerAtlasRow(numbers: [Int], expectedLevel: Int) -> ScannedBlindLevel? {
        guard numbers.count >= 3 else { return nil }

        var idx = 0
        var levelNum = expectedLevel

        // First number is level number if it's small and matches expected
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

    /// Generic blind row: [LevelNumber?, SB, BB, Ante?, Duration?]
    private func interpretGenericRow(numbers: [Int], expectedLevel: Int) -> ScannedBlindLevel? {
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

    // MARK: - Helpers

    private func extractNumbers(from text: String) -> [Int] {
        let pattern = try! NSRegularExpression(pattern: #"\d[\d,]*"#)
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        return matches.compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            return parseNumberFromString(String(text[r]))
        }
    }

    private func extractDuration(from text: String) -> Int? {
        let numbers = extractNumbers(from: text)
        // For break lines, the number is typically the duration
        if let dur = numbers.last, dur >= 1, dur <= 60 {
            return dur
        }
        return nil
    }

    private func extractBreakLabel(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Break - End of Reg..." → "Break - End of Reg..."
        // "Break" → "Break"
        // Remove trailing numbers (duration)
        let withoutNumbers = trimmed.replacingOccurrences(
            of: #"\s*\d+\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        return withoutNumbers.isEmpty ? "Break" : withoutNumbers
    }

    private func parseNumberFromString(_ str: String) -> Int? {
        Int(str.replacingOccurrences(of: ",", with: ""))
    }

    private func parseDollarValue(_ str: String?) -> Int? {
        guard let str else { return nil }
        // Extract first number after optional $
        let cleaned = str.replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        // Take first number-like token
        let pattern = try! NSRegularExpression(pattern: #"(\d[\d,]*)"#)
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        if let match = pattern.firstMatch(in: cleaned, range: range),
           let r = Range(match.range(at: 1), in: cleaned) {
            return parseNumberFromString(String(cleaned[r]))
        }
        return nil
    }

    private func parseChipValue(_ str: String) -> Int? {
        let cleaned = str.lowercased().replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if cleaned.hasSuffix("k") {
            if let num = Double(cleaned.dropLast()) {
                return Int(num * 1000)
            }
        }
        return Int(cleaned)
    }

    private func isChromeText(_ text: String) -> Bool {
        let chrome = ["back", "home", "search", "menu", "share", "settings",
                      "notifications", "poker atlas", "pokeratlas", "http", "www",
                      "cancel", "close", "done", "register", "registration",
                      "tournament info", "buy-in details", "format", "size",
                      "structure", "note from"]
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        return chrome.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) || lower.count <= 3
    }
}
