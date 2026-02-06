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

                // Sort top-to-bottom (Vision y-origin is bottom-left, so descending y = top first)
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

        // Tournament name — first substantial line that isn't chrome/navigation
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 5, !isChromeText(trimmed) {
                result.tournamentName = trimmed
                break
            }
        }

        // Venue name — look for "at <Venue>" or "venue: <Name>"
        parseVenue(from: joined, result: &result)

        // Game type
        if lower.contains("nlh") || lower.contains("no limit hold") || lower.contains("no-limit hold") {
            result.gameType = .nlh
        } else if lower.contains("plo") || lower.contains("pot limit omaha") || lower.contains("pot-limit omaha") {
            result.gameType = .plo
        } else if lower.contains("mixed") {
            result.gameType = .mixed
        }

        // Financials
        parseBuyIn(from: joined, result: &result)
        parseStartingChips(from: joined, result: &result)
        parseGuarantee(from: joined, result: &result)
        parseBounty(from: joined, result: &result)

        // Blind levels
        result.blindLevels = parseBlindLevels(from: lines)

        return result
    }

    // MARK: - Venue Parser

    private func parseVenue(from text: String, result: inout PokerAtlasScanResult) {
        // "at <Venue Name>" pattern
        let lines = text.components(separatedBy: "\n")
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
            if lower.hasPrefix("venue") {
                let stripped = line.replacingOccurrences(of: "venue", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":- ")))
                if stripped.count >= 3 {
                    result.venueName = stripped
                    return
                }
            }
        }
    }

    // MARK: - Financial Parsers

    private func parseBuyIn(from text: String, result: inout PokerAtlasScanResult) {
        // Look for "$150 + $30" or "$150+$30" pattern
        let dollarPlusPattern = try! NSRegularExpression(pattern: #"\$\s*(\d[\d,]*)\s*\+\s*\$\s*(\d[\d,]*)"#)
        let range = NSRange(text.startIndex..., in: text)

        if let match = dollarPlusPattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text),
               let r2 = Range(match.range(at: 2), in: text) {
                result.buyIn = parseNumber(String(text[r1]))
                result.entryFee = parseNumber(String(text[r2]))
                return
            }
        }

        // "Buy-in: $150" or "Buy in $150"
        let buyInPattern = try! NSRegularExpression(pattern: #"(?i)buy[\s-]?in[:\s]*\$?\s*(\d[\d,]*)"#)
        if let match = buyInPattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.buyIn = parseNumber(String(text[r1]))
            }
        }
    }

    private func parseStartingChips(from text: String, result: inout PokerAtlasScanResult) {
        // "Starting Chips: 20,000" or "Starting Stack: 20000"
        let chipsPattern = try! NSRegularExpression(pattern: #"(?i)(?:starting\s+(?:chips|stack)|chips)[:\s]*(\d[\d,]*)"#)
        let range = NSRange(text.startIndex..., in: text)

        if let match = chipsPattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.startingChips = parseNumber(String(text[r1]))
                return
            }
        }

        // "20,000 chips" or "20000 starting chips"
        let reversePattern = try! NSRegularExpression(pattern: #"(\d[\d,]+)\s*(?:starting\s+)?chips"#, options: .caseInsensitive)
        if let match = reversePattern.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                let val = parseNumber(String(text[r1]))
                if let val, val >= 1000 {
                    result.startingChips = val
                }
            }
        }
    }

    private func parseGuarantee(from text: String, result: inout PokerAtlasScanResult) {
        let range = NSRange(text.startIndex..., in: text)

        // "$50,000 GTD" or "$50K Guaranteed"
        let gtdPattern1 = try! NSRegularExpression(pattern: #"(?i)\$\s*(\d[\d,]*[kK]?)\s*(?:gtd|guaranteed|guarantee)"#)
        if let match = gtdPattern1.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.guarantee = parseChipValue(String(text[r1]))
                return
            }
        }

        // "GTD: $50,000" or "Guarantee: $50K"
        let gtdPattern2 = try! NSRegularExpression(pattern: #"(?i)(?:gtd|guarantee|guaranteed)[:\s]*\$?\s*(\d[\d,]*[kK]?)"#)
        if let match = gtdPattern2.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.guarantee = parseChipValue(String(text[r1]))
            }
        }
    }

    private func parseBounty(from text: String, result: inout PokerAtlasScanResult) {
        let range = NSRange(text.startIndex..., in: text)

        // "Bounty: $50"
        let bountyPattern1 = try! NSRegularExpression(pattern: #"(?i)bounty[:\s]*\$?\s*(\d[\d,]*)"#)
        if let match = bountyPattern1.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.bountyAmount = parseNumber(String(text[r1]))
                return
            }
        }

        // "$50 Bounty"
        let bountyPattern2 = try! NSRegularExpression(pattern: #"(?i)\$(\d[\d,]*)\s*bounty"#)
        if let match = bountyPattern2.firstMatch(in: text, range: range) {
            if let r1 = Range(match.range(at: 1), in: text) {
                result.bountyAmount = parseNumber(String(text[r1]))
            }
        }
    }

    // MARK: - Blind Level Parser

    private func parseBlindLevels(from lines: [String]) -> [ScannedBlindLevel] {
        var levels: [ScannedBlindLevel] = []
        var levelCounter = 1

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Check for break rows
            if trimmed.lowercased().contains("break") {
                let duration = extractDuration(from: trimmed) ?? 15
                levels.append(ScannedBlindLevel(
                    levelNumber: levelCounter,
                    smallBlind: 0,
                    bigBlind: 0,
                    ante: 0,
                    durationMinutes: duration,
                    isBreak: true,
                    breakLabel: "Break"
                ))
                levelCounter += 1
                continue
            }

            // Look for rows with 2-5 numbers that look like blind levels
            let numbers = extractNumbers(from: trimmed)

            if numbers.count >= 3 {
                let parsed = interpretBlindRow(numbers: numbers, expectedLevel: levelCounter)
                if let parsed {
                    levels.append(parsed)
                    levelCounter += 1
                }
            } else if numbers.count == 2 {
                let sb = numbers[0]
                let bb = numbers[1]
                if bb >= sb, sb > 0 {
                    levels.append(ScannedBlindLevel(
                        levelNumber: levelCounter,
                        smallBlind: sb,
                        bigBlind: bb,
                        ante: 0,
                        durationMinutes: 30,
                        isBreak: false
                    ))
                    levelCounter += 1
                }
            }
        }

        return levels
    }

    private func interpretBlindRow(numbers: [Int], expectedLevel: Int) -> ScannedBlindLevel? {
        var idx = 0
        var levelNum = expectedLevel

        // If first number matches expected level or is small (1-50), treat as level number
        if numbers.count >= 4, numbers[0] <= 50, numbers[0] == expectedLevel || numbers[0] <= numbers.count {
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

        // Sanity check: BB should be >= SB and both should be positive
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

        if duration < 1 || duration > 120 {
            duration = 30
        }

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
            return parseNumber(String(text[r]))
        }
    }

    private func extractDuration(from text: String) -> Int? {
        let pattern = try! NSRegularExpression(pattern: #"(\d+)\s*(?:min|minutes|mins)"#, options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        if let match = pattern.firstMatch(in: text, range: range),
           let r = Range(match.range(at: 1), in: text) {
            return Int(text[r])
        }
        let numbers = extractNumbers(from: text)
        if let dur = numbers.last, dur >= 5, dur <= 60 {
            return dur
        }
        return nil
    }

    private func parseNumber(_ str: String) -> Int? {
        Int(str.replacingOccurrences(of: ",", with: ""))
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
                      "am", "pm", "cancel", "close", "done"]
        let lower = text.lowercased()
        return chrome.contains(where: { lower == $0 }) || lower.count <= 3
    }
}
