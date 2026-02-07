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
    var startingSB: Int?
    var startingBB: Int?
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

// MARK: - Text Observation (internal)

private struct TextObservation {
    let text: String
    let boundingBox: CGRect // Vision coords: origin bottom-left, y goes up, normalized 0-1
}

// MARK: - Scanner

final class PokerAtlasScanner: @unchecked Sendable {
    static let shared = PokerAtlasScanner()

    private init() {}

    func scan(image: UIImage) async throws -> PokerAtlasScanResult {
        guard let cgImage = image.cgImage else {
            throw ScannerError.invalidImage
        }

        let observations = try await recognizeText(in: cgImage)
        guard !observations.isEmpty else {
            throw ScannerError.noTextFound
        }

        // Group observations into rows using bounding box positions
        let rows = groupIntoRows(observations)
        let lines = rows.map { row in
            row.map { $0.text }.joined(separator: " ")
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
            if merged.startingSB == nil { merged.startingSB = r.startingSB }
            if merged.startingBB == nil { merged.startingBB = r.startingBB }
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

        unique.sort { $0.levelNumber < $1.levelNumber }

        return unique.enumerated().map { index, level in
            var renumbered = level
            renumbered.levelNumber = index + 1
            return renumbered
        }
    }

    // MARK: - OCR

    private func recognizeText(in cgImage: CGImage) async throws -> [TextObservation] {
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

                let textObs = observations.compactMap { obs -> TextObservation? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return TextObservation(text: candidate.string, boundingBox: obs.boundingBox)
                }

                continuation.resume(returning: textObs)
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

    // MARK: - Row Grouping

    /// Groups text observations into rows by y-coordinate proximity,
    /// then sorts each row left-to-right by x-coordinate.
    /// This reconstructs table rows from individual cell observations.
    private func groupIntoRows(_ observations: [TextObservation]) -> [[TextObservation]] {
        guard !observations.isEmpty else { return [] }

        // Sort by midY descending (top of image = highest y in Vision coords)
        let sorted = observations.sorted {
            ($0.boundingBox.midY) > ($1.boundingBox.midY)
        }

        var rows: [[TextObservation]] = []
        var currentRow: [TextObservation] = []
        var currentMidY: CGFloat = -1
        let threshold: CGFloat = 0.01 // ~1% of image height

        for obs in sorted {
            let midY = obs.boundingBox.midY
            if currentRow.isEmpty {
                currentRow.append(obs)
                currentMidY = midY
            } else if abs(midY - currentMidY) < threshold {
                currentRow.append(obs)
                // Update running average midY
                let sum = currentRow.reduce(CGFloat(0)) { $0 + $1.boundingBox.midY }
                currentMidY = sum / CGFloat(currentRow.count)
            } else {
                // Finalize current row: sort left to right
                currentRow.sort { $0.boundingBox.origin.x < $1.boundingBox.origin.x }
                rows.append(currentRow)
                currentRow = [obs]
                currentMidY = midY
            }
        }
        if !currentRow.isEmpty {
            currentRow.sort { $0.boundingBox.origin.x < $1.boundingBox.origin.x }
            rows.append(currentRow)
        }

        return rows
    }

    // MARK: - Parser

    private func parse(lines: [String]) -> PokerAtlasScanResult {
        var result = PokerAtlasScanResult()
        let joined = lines.joined(separator: "\n")
        let lower = joined.lowercased()

        // Build key-value pairs from reconstructed lines
        let keyValues = buildKeyValues(from: lines)

        // Tournament name
        parseTournamentName(from: lines, keyValues: keyValues, result: &result)

        // Venue
        parseVenue(from: lines, keyValues: keyValues, result: &result)

        // Game type
        parseGameType(from: lower, keyValues: keyValues, result: &result)

        // Financials
        parseFinancials(from: joined, keyValues: keyValues, result: &result)

        // Starting Blinds (from explicit "Starting Blinds 100/200" field)
        parseStartingBlinds(from: keyValues, result: &result)

        // Re-entry (normalized to picker values)
        parseReentryPolicy(from: keyValues, result: &result)

        // Blind levels
        result.blindLevels = parseBlindLevels(from: lines)

        return result
    }

    // MARK: - Key-Value Builder

    /// Known Poker Atlas labels for key-value extraction
    private static let knownLabels = [
        "total buy-in", "entry fee", "deductions", "starting chips",
        "starting blinds", "re-entry", "rebuys", "addons", "bounties",
        "bounty amount", "guarantee", "level time", "game type",
        "event name", "event type", "event number", "start time",
        "event start date", "length of event", "registration opens",
        "registration closes"
    ]

    /// Parses reconstructed lines into key-value pairs.
    /// With bounding-box row reconstruction, a table row like
    /// "Total Buy-In $400" is already a single line.
    private func buildKeyValues(from lines: [String]) -> [String: String] {
        var dict: [String: String] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Normalize dashes (en-dash, em-dash → hyphen)
            let normalized = trimmed
                .replacingOccurrences(of: "\u{2013}", with: "-") // en-dash
                .replacingOccurrences(of: "\u{2014}", with: "-") // em-dash
            let lowerLine = normalized.lowercased()

            for label in Self.knownLabels {
                if lowerLine.hasPrefix(label) {
                    let valueStart = normalized.index(normalized.startIndex, offsetBy: label.count)
                    let value = String(normalized[valueStart...])
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
                    if !value.isEmpty {
                        dict[label] = value
                    }
                    break
                }
            }
        }

        // Also try pairing consecutive lines where first is a standalone label
        for i in 0..<lines.count - 1 {
            let possibleLabel = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{2013}", with: "-")
                .replacingOccurrences(of: "\u{2014}", with: "-")
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            let possibleValue = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)

            for label in Self.knownLabels {
                if possibleLabel == label {
                    if dict[label] == nil && !possibleValue.isEmpty {
                        // Don't pair if the "value" is itself a known label
                        let valueLower = possibleValue.lowercased()
                        let isLabel = Self.knownLabels.contains { valueLower == $0 || valueLower.hasPrefix($0) }
                        if !isLabel {
                            dict[label] = possibleValue
                        }
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
        // Look for "City, ST" pattern — venue name is typically the line above it
        let cityStatePattern = try! NSRegularExpression(pattern: #"^[A-Z][a-zA-Z\s]+,\s*[A-Z]{2}$"#)

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if i + 1 < lines.count {
                let nextLine = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
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
        let gameTypeText = (keyValues["game type"] ?? "").lowercased()
        let searchText = gameTypeText.isEmpty ? lower : gameTypeText

        if searchText.contains("pl omaha") || searchText.contains("plo") ||
            searchText.contains("pot limit omaha") || searchText.contains("pot-limit omaha") {
            result.gameType = .plo
        } else if searchText.contains("nlh") || searchText.contains("no limit hold") ||
                    searchText.contains("no-limit hold") || searchText.contains("nl hold") ||
                    searchText.contains("nl texas") {
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

        // Bounty Amount
        if let bounty = keyValues["bounty amount"] {
            result.bountyAmount = parseDollarValue(bounty)
        }
        if result.bountyAmount == nil {
            parseBountyFromText(from: text, result: &result)
        }
    }

    // MARK: - Starting Blinds

    private func parseStartingBlinds(from keyValues: [String: String], result: inout PokerAtlasScanResult) {
        guard let blindsStr = keyValues["starting blinds"] else { return }

        // Parse "100/200" format
        let pattern = try! NSRegularExpression(pattern: #"(\d[\d,]*)\s*/\s*(\d[\d,]*)"#)
        let range = NSRange(blindsStr.startIndex..., in: blindsStr)
        if let match = pattern.firstMatch(in: blindsStr, range: range),
           let r1 = Range(match.range(at: 1), in: blindsStr),
           let r2 = Range(match.range(at: 2), in: blindsStr) {
            result.startingSB = parseNumberFromString(String(blindsStr[r1]))
            result.startingBB = parseNumberFromString(String(blindsStr[r2]))
        }
    }

    // MARK: - Re-entry Policy

    private func parseReentryPolicy(from keyValues: [String: String], result: inout PokerAtlasScanResult) {
        guard let reentry = keyValues["re-entry"] else { return }
        let lower = reentry.lowercased().trimmingCharacters(in: .whitespaces)

        // Normalize to match the app's picker values
        if lower.contains("unlimited") || lower.contains("unlim") {
            result.reentryPolicy = "Unlimited"
        } else if lower.contains("none") || lower == "0" || lower == "no" {
            result.reentryPolicy = "None"
        } else if lower.contains("2") {
            result.reentryPolicy = "2 Re-entries"
        } else if lower.contains("1") {
            result.reentryPolicy = "1 Re-entry"
        } else {
            result.reentryPolicy = reentry
        }
    }

    // MARK: - Text Fallback Parsers

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

        let bountyPattern = try! NSRegularExpression(pattern: #"(?i)bounty(?:\s+amount)?[:\s]*\$?\s*(\d[\d,]*)"#)
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

    /// Poker Atlas column order: [LevelNumber, Duration, SB, BB, Ante]
    private func interpretPokerAtlasRow(numbers: [Int], expectedLevel: Int) -> ScannedBlindLevel? {
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
        if let dur = numbers.last, dur >= 1, dur <= 60 {
            return dur
        }
        return nil
    }

    private func extractBreakLabel(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)

        // Very short strings
        if lower.count <= 3 { return true }

        // Status bar time patterns: "3:30", "3:30 4", "12:45 PM"
        let timePattern = try! NSRegularExpression(pattern: #"^\d{1,2}:\d{2}\b"#)
        if timePattern.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
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
    private func isSectionHeader(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let headers = [
            "tournament info", "buy-in details", "format", "size",
            "structure", "registration"
        ]
        return headers.contains(lower)
    }
}
