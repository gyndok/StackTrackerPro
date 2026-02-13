import Foundation
import SwiftData

struct CSVImportResult {
    var cashSessionsCreated: Int = 0
    var tournamentsCreated: Int = 0
    var rowsSkipped: Int = 0
    var warnings: [String] = []
}

struct CSVImporter {
    static func importCSV(from url: URL, into context: ModelContext) -> CSVImportResult {
        var result = CSVImportResult()

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            result.warnings.append("Could not read file")
            return result
        }

        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else {
            result.warnings.append("File is empty or has no data rows")
            return result
        }

        for (lineIndex, line) in lines.dropFirst().enumerated() {
            let rowNum = lineIndex + 2
            let columns = parseCSVLine(line)

            guard columns.count >= 9 else {
                result.warnings.append("Row \(rowNum): not enough columns (\(columns.count)), skipping")
                result.rowsSkipped += 1
                continue
            }

            guard let date = parseDate(columns[0]) else {
                result.warnings.append("Row \(rowNum): could not parse date '\(columns[0])', skipping")
                result.rowsSkipped += 1
                continue
            }

            let format = columns[1].trimmingCharacters(in: .whitespaces).lowercased()
            let variant = columns[2].trimmingCharacters(in: .whitespaces)
            let stakes = columns[3].trimmingCharacters(in: .whitespaces)
            let location = columns[4].trimmingCharacters(in: .whitespaces)
            let buyIn = parseCurrency(columns[5])
            let cashOut = parseCurrency(columns[6])
            let durationHours = Double(columns[8].trimmingCharacters(in: .whitespaces))
            let notes = columns.count > 10 ? columns[10].trimmingCharacters(in: .whitespaces) : nil

            guard let buyIn, buyIn > 0 else {
                result.warnings.append("Row \(rowNum): invalid buy-in '\(columns[5])', skipping")
                result.rowsSkipped += 1
                continue
            }

            let gameType = mapVariantToGameType(variant)
            let endTime = durationHours.map { date.addingTimeInterval($0 * 3600) }

            if format.contains("cash") {
                let session = CashSession(
                    stakes: stakes,
                    gameType: gameType,
                    buyInTotal: buyIn,
                    venueName: location.isEmpty ? nil : location,
                    date: date
                )
                session.cashOut = cashOut
                session.endTime = endTime
                session.statusRaw = SessionStatus.completed.rawValue
                session.isImported = true
                session.notes = (notes?.isEmpty ?? true) ? nil : notes
                context.insert(session)
                result.cashSessionsCreated += 1
            } else {
                let tournament = Tournament(
                    name: "\(stakes) \(gameType.label)".trimmingCharacters(in: .whitespaces),
                    gameType: gameType,
                    buyIn: buyIn
                )
                tournament.payout = cashOut
                tournament.endDate = endTime
                tournament.statusRaw = TournamentStatus.completed.rawValue
                tournament.venueName = location.isEmpty ? nil : location
                tournament.startDate = date
                context.insert(tournament)
                result.tournamentsCreated += 1
            }
        }

        try? context.save()
        return result
    }

    // MARK: - Parsing Helpers

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }

    private static func parseDate(_ string: String) -> Date? {
        let cleaned = string.trimmingCharacters(in: .whitespaces)
        let formats = ["MM/dd/yyyy", "yyyy-MM-dd", "M/d/yy", "M/d/yyyy", "MM-dd-yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) {
                return date
            }
        }
        return nil
    }

    private static func parseCurrency(_ string: String) -> Int? {
        let cleaned = string
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "(", with: "-")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespaces)

        if let intVal = Int(cleaned) { return intVal }
        if let doubleVal = Double(cleaned) { return Int(doubleVal) }
        return nil
    }

    private static func mapVariantToGameType(_ variant: String) -> GameType {
        let upper = variant.uppercased()
        if upper.contains("PLO") || upper.contains("OMAHA") { return .plo }
        if upper.contains("MIXED") { return .mixed }
        return .nlh
    }
}
