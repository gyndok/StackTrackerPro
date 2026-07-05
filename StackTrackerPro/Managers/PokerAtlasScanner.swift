import UIKit
import Vision

// MARK: - Scan Result

struct PokerAtlasScanResult {
    var tournamentName: String?
    var venueName: String?
    var gameType: GameType?
    /// Total cost to the player.
    var buyIn: Int?
    /// House fee/rake portion of the buy-in, excluding `deductions`.
    var entryFee: Int?
    /// Prize-pool deductions (staff bonus, etc.) listed separately by
    /// Poker Atlas. Never folded into `entryFee` to avoid double-counting.
    var deductions: Int?
    var bountyAmount: Int?
    var guarantee: Int?
    var startingChips: Int?
    var reentryPolicy: String?
    var startingSB: Int?
    var startingBB: Int?
    var blindLevels: [ScannedBlindLevel] = []
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

    // MARK: - Regex Patterns

    /// Builds a regex from a compile-time pattern. The patterns below are
    /// constants; an invalid one is a programmer error, surfaced with a
    /// clear message instead of a bare `try!` crash.
    private static func regex(_ pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("PokerAtlasScanner: invalid regex pattern: \(pattern)")
        }
        return regex
    }

    private static let cityStatePattern = regex(#"^[A-Z][a-zA-Z\s]+,\s*[A-Z]{2}$"#)
    private static let blindsPairPattern = regex(#"(\d[\d,]*)\s*/\s*(\d[\d,]*)"#)
    private static let dollarPlusPattern = regex(#"\$\s*(\d[\d,]*)\s*\+\s*\$\s*(\d[\d,]*)"#)
    private static let buyInPattern = regex(#"(?i)buy[\s-]?in[:\s]*\$?\s*(\d[\d,]*)"#)
    private static let startingChipsPattern = regex(#"(?i)(?:starting\s+(?:chips|stack))[:\s]*(\d[\d,]*)"#)
    private static let guaranteePrefixPattern = regex(#"(?i)\$\s*(\d[\d,]*[kK]?)\s*(?:gtd|guaranteed|guarantee)"#)
    private static let guaranteeSuffixPattern = regex(#"(?i)(?:gtd|guarantee|guaranteed)[:\s]*\$?\s*(\d[\d,]*[kK]?)"#)
    private static let bountyPattern = regex(#"(?i)bounty(?:\s+amount)?[:\s]*\$?\s*(\d[\d,]*)"#)
    private static let dollarTokenPattern = regex(#"(\d[\d,]*)"#)

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

        var merged = merge(allResults)
        // WSOP sheets state the level duration once (often not on every
        // page) — propagate it across all pages after the merge.
        merged.blindLevels = normalizeDurations(merged.blindLevels)
        return merged
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
            if merged.deductions == nil { merged.deductions = r.deductions }
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
                // Compute the prefix range on the ORIGINAL string with a
                // case-insensitive anchored search: lowercasing can change
                // string length (e.g. İ), so an offset measured on the
                // lowercased copy could misalign.
                guard lowerLine.hasPrefix(label) else { continue }
                if let labelRange = normalized.range(of: label, options: [.caseInsensitive, .anchored]) {
                    let value = String(normalized[labelRange.upperBound...])
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
                    if !value.isEmpty {
                        dict[label] = value
                    }
                }
                break
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
            if trimmed.count >= 5, !BlindStructureParser.isChromeText(trimmed) {
                result.tournamentName = trimmed
                return
            }
        }
    }

    // MARK: - Venue

    private func parseVenue(from lines: [String], keyValues: [String: String], result: inout PokerAtlasScanResult) {
        // Look for "City, ST" pattern — venue name is typically the line above it

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if i + 1 < lines.count {
                let nextLine = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                let range = NSRange(nextLine.startIndex..., in: nextLine)
                if Self.cityStatePattern.firstMatch(in: nextLine, range: range) != nil {
                    if trimmed.count >= 3, trimmed.count <= 60, !BlindStructureParser.isChromeText(trimmed) {
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
            // buyIn keeps total-cost-to-player semantics.
            result.buyIn = total
            if let ded = deductions, ded > 0, ded < total {
                // Expose deductions separately (Tournament.deductions feeds
                // prize-pool math); entryFee must NOT double-count them.
                result.deductions = ded
                if let entry = entryFee, entry > 0, entry < total {
                    // Poker Atlas "Entry Fee" = prize pool portion, so any
                    // remaining house fee = total - prize pool - deductions.
                    let fee = total - entry - ded
                    result.entryFee = fee > 0 ? fee : nil
                }
            } else if let entry = entryFee, entry > 0, entry < total {
                // Poker Atlas "Entry Fee" = prize pool portion; rake = total - entry
                result.entryFee = total - entry
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
        let range = NSRange(blindsStr.startIndex..., in: blindsStr)
        if let match = Self.blindsPairPattern.firstMatch(in: blindsStr, range: range),
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
        let range = NSRange(text.startIndex..., in: text)

        if let match = Self.dollarPlusPattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text),
               let r2 = Range(match.range(at: 2), in: text) {
                let prizePool = parseNumberFromString(String(text[r1]))
                let fee = parseNumberFromString(String(text[r2]))
                // "$330 + $70" → buyIn = total ($400), entryFee = fee ($70)
                if let pp = prizePool, let f = fee {
                    result.buyIn = pp + f
                    result.entryFee = f
                }
                return
            }
        }

        if let match = Self.buyInPattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.buyIn = parseNumberFromString(String(text[r1]))
            }
        }
    }

    private func parseStartingChipsFromText(from text: String, result: inout PokerAtlasScanResult) {
        let range = NSRange(text.startIndex..., in: text)

        if let match = Self.startingChipsPattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.startingChips = parseNumberFromString(String(text[r1]))
            }
        }
    }

    private func parseGuaranteeFromText(from text: String, result: inout PokerAtlasScanResult) {
        let range = NSRange(text.startIndex..., in: text)

        if let match = Self.guaranteePrefixPattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.guarantee = parseChipValue(String(text[r1]))
                return
            }
        }

        if let match = Self.guaranteeSuffixPattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.guarantee = parseChipValue(String(text[r1]))
            }
        }
    }

    private func parseBountyFromText(from text: String, result: inout PokerAtlasScanResult) {
        let range = NSRange(text.startIndex..., in: text)

        if let match = Self.bountyPattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.bountyAmount = parseNumberFromString(String(text[r1]))
            }
        }
    }

    // MARK: - Blind Level Parser

    /// Blind-structure parsing lives in BlindStructureParser
    /// (BlindStructureParsing.swift), shared with the tools/seeder CLI.
    /// These wrappers keep the scanner's public surface (and tests) stable.
    func parseBlindLevels(from lines: [String]) -> [ScannedBlindLevel] {
        BlindStructureParser.parseBlindLevels(from: lines)
    }

    func parseWSOPStructure(from lines: [String]) -> [ScannedBlindLevel]? {
        BlindStructureParser.parseWSOPStructure(from: lines)
    }

    func normalizeDurations(_ levels: [ScannedBlindLevel]) -> [ScannedBlindLevel] {
        BlindStructureParser.normalizeDurations(levels)
    }

    // MARK: - Helpers

    private func parseNumberFromString(_ str: String) -> Int? {
        Int(str.replacingOccurrences(of: ",", with: ""))
    }

    private func parseDollarValue(_ str: String?) -> Int? {
        guard let str else { return nil }
        let cleaned = str.replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        // Take first number-like token
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        if let match = Self.dollarTokenPattern.firstMatch(in: cleaned, range: range),
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

}
