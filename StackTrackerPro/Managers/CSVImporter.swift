import Foundation
import SwiftData
import os

struct CSVImportResult {
    var cashSessionsCreated: Int = 0
    var tournamentsCreated: Int = 0
    var rowsSkipped: Int = 0
    var duplicatesSkipped: Int = 0
    var warnings: [String] = []
}

struct CSVImporter {

    private static let logger = Logger(subsystem: "com.gyndok.stacktrackerpro", category: "CSVImporter")

    static func importCSV(from url: URL, into context: ModelContext) -> CSVImportResult {
        var result = CSVImportResult()

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            result.warnings.append("Could not read file")
            return result
        }

        // RFC 4180-aware parse: quoted fields may contain commas, escaped
        // quotes ("") and embedded newlines (e.g. multi-line notes).
        let allRows = parseCSV(content).filter { row in
            row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        guard allRows.count > 1 else {
            result.warnings.append("File is empty or has no data rows")
            return result
        }

        // Header-driven column lookup with positional fallback, so both the
        // current schema and old exports (without the tournament columns)
        // import correctly.
        let columns = ColumnMap(header: allRows[0])

        // Existing-record keys for idempotent re-import (date + location +
        // buy-in + cash-out/payout).
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        var existingKeys = existingRecordKeys(in: context, dayFormatter: dayFormatter)

        for (rowIndex, row) in allRows.dropFirst().enumerated() {
            let rowNum = rowIndex + 2

            func field(_ index: Int?) -> String? {
                guard let index, index >= 0, index < row.count else { return nil }
                let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }

            guard let dateStr = field(columns.date), let date = parseDate(dateStr) else {
                result.warnings.append("Row \(rowNum): could not parse date '\(field(columns.date) ?? "")', skipping")
                result.rowsSkipped += 1
                continue
            }

            let format = (field(columns.format) ?? "").lowercased()
            let variant = field(columns.variant) ?? ""
            let stakes = field(columns.stakes) ?? ""
            let location = field(columns.location) ?? ""
            let buyIn = field(columns.buyIn).flatMap(parseCurrency)
            // Blank cash-out = "no result"; keep it nil, not a $0 full loss.
            let cashOut = field(columns.cashOut).flatMap(parseCurrency)
            let durationHours = field(columns.duration).flatMap(Double.init)
            let notes = field(columns.notes)

            // Allow 0 (freerolls); reject only negative/unparseable buy-ins.
            guard let buyIn, buyIn >= 0 else {
                result.warnings.append("Row \(rowNum): invalid buy-in '\(field(columns.buyIn) ?? "")', skipping")
                result.rowsSkipped += 1
                continue
            }

            let gameType = mapVariantToGameType(variant)
            let endTime = durationHours.map { date.addingTimeInterval($0 * 3600) }
            let isCash = format.contains("cash")

            // Dedup: skip rows matching an existing record (or an earlier row
            // in this same file) so re-importing is idempotent.
            let key = dedupKey(
                isCash: isCash,
                date: date,
                location: location,
                buyIn: buyIn,
                cashOut: cashOut,
                dayFormatter: dayFormatter
            )
            guard !existingKeys.contains(key) else {
                result.duplicatesSkipped += 1
                continue
            }
            existingKeys.insert(key)

            if isCash {
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
                session.notes = notes
                context.insert(session)
                result.cashSessionsCreated += 1
            } else {
                // Prefer the explicit Tournament Name column; old exports put
                // the name in Notes (with empty Stakes), so fall back there.
                let name = field(columns.tournamentName)
                    ?? notes
                    ?? "\(stakes) \(gameType.label)".trimmingCharacters(in: .whitespaces)

                // The exporter writes total investment (buyIn × (1 + rebuys))
                // into the Buy-in column; derive the base buy-in back so
                // rebuys aren't double-counted on round-trip.
                let rebuys = field(columns.rebuys).flatMap { Int($0) } ?? 0
                let baseBuyIn = rebuys > 0 ? buyIn / (1 + rebuys) : buyIn

                let tournament = Tournament(
                    name: name,
                    gameType: gameType,
                    buyIn: baseBuyIn
                )
                tournament.payout = cashOut
                tournament.endDate = endTime
                tournament.statusRaw = TournamentStatus.completed.rawValue
                tournament.venueName = location.isEmpty ? nil : location
                tournament.startDate = date
                if let finish = field(columns.finishPosition).flatMap({ Int($0) }) {
                    tournament.finishPosition = finish
                }
                if let size = field(columns.fieldSize).flatMap({ Int($0) }) {
                    tournament.fieldSize = size
                }
                tournament.rebuysUsed = rebuys
                if let bounties = field(columns.bountiesCollected).flatMap({ Int($0) }) {
                    tournament.bountiesCollected = bounties
                }
                if let bountyAmount = field(columns.bountyAmount).flatMap(parseCurrency) {
                    tournament.bountyAmount = bountyAmount
                }
                context.insert(tournament)
                result.tournamentsCreated += 1
            }
        }

        do {
            try context.save()
        } catch {
            logger.error("CSV import: failed to save: \(error.localizedDescription, privacy: .public)")
            result.warnings.append("Failed to save imported sessions: \(error.localizedDescription)")
        }
        return result
    }

    // MARK: - Column Mapping

    /// Resolves column indices from the header row. Old exports without the
    /// tournament columns still resolve the legacy positions; missing
    /// optional columns are tolerated (nil).
    private struct ColumnMap {
        let date: Int
        let format: Int
        let variant: Int
        let stakes: Int
        let location: Int
        let buyIn: Int
        let cashOut: Int
        let duration: Int
        let notes: Int
        // Newer columns (absent in old exports)
        let tournamentName: Int?
        let finishPosition: Int?
        let fieldSize: Int?
        let rebuys: Int?
        let bountiesCollected: Int?
        let bountyAmount: Int?

        init(header: [String]) {
            let normalized = header.map { Self.normalize($0) }
            func index(of key: String) -> Int? {
                normalized.firstIndex { $0 == key || $0.hasPrefix(key) }
            }
            date = index(of: "date") ?? 0
            format = index(of: "format") ?? 1
            variant = index(of: "variant") ?? 2
            stakes = index(of: "stakes") ?? 3
            location = index(of: "location") ?? 4
            buyIn = index(of: "buyin") ?? 5
            cashOut = index(of: "cashout") ?? 6
            duration = index(of: "duration") ?? 8
            notes = index(of: "notes") ?? 10
            tournamentName = index(of: "tournamentname")
            finishPosition = index(of: "finishposition")
            fieldSize = index(of: "fieldsize")
            rebuys = index(of: "rebuys")
            bountiesCollected = index(of: "bountiescollected")
            bountyAmount = index(of: "bountyamount")
        }

        static func normalize(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }
    }

    // MARK: - Deduplication

    private static func dedupKey(
        isCash: Bool,
        date: Date,
        location: String?,
        buyIn: Int,
        cashOut: Int?,
        dayFormatter: DateFormatter
    ) -> String {
        let kind = isCash ? "cash" : "tournament"
        let day = dayFormatter.string(from: date)
        let loc = (location ?? "").lowercased()
        let out = cashOut.map(String.init) ?? "nil"
        return "\(kind)|\(day)|\(loc)|\(buyIn)|\(out)"
    }

    private static func existingRecordKeys(in context: ModelContext, dayFormatter: DateFormatter) -> Set<String> {
        var keys: Set<String> = []

        let cashSessions = (try? context.fetch(FetchDescriptor<CashSession>())) ?? []
        for session in cashSessions {
            keys.insert(dedupKey(
                isCash: true,
                date: session.date,
                location: session.venueName,
                buyIn: session.buyInTotal,
                cashOut: session.cashOut,
                dayFormatter: dayFormatter
            ))
        }

        let tournaments = (try? context.fetch(FetchDescriptor<Tournament>())) ?? []
        for tournament in tournaments {
            // Exported rows carry totalInvestment in the Buy-in column, so
            // key existing tournaments under both forms.
            for amount in Set([tournament.buyIn, tournament.totalInvestment]) {
                keys.insert(dedupKey(
                    isCash: false,
                    date: tournament.startDate,
                    location: tournament.venueName,
                    buyIn: amount,
                    cashOut: tournament.payout,
                    dayFormatter: dayFormatter
                ))
            }
        }

        return keys
    }

    // MARK: - CSV Parsing (RFC 4180)

    /// Splits CSV content into rows of fields, honoring quoted fields that
    /// contain commas, escaped quotes ("") and embedded newlines.
    static func parseCSV(_ content: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var fieldValue = ""
        var inQuotes = false

        var i = content.startIndex
        while i < content.endIndex {
            let char = content[i]
            if inQuotes {
                if char == "\"" {
                    let next = content.index(after: i)
                    if next < content.endIndex && content[next] == "\"" {
                        // Escaped quote: "" → literal "
                        fieldValue.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    fieldValue.append(char)
                }
            } else {
                switch char {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(fieldValue)
                    fieldValue = ""
                // Swift groups "\r\n" into one Character, so CRLF needs its
                // own case; bare CR (classic Mac endings) also ends a row.
                case "\n", "\r\n", "\r":
                    row.append(fieldValue)
                    fieldValue = ""
                    rows.append(row)
                    row = []
                default:
                    fieldValue.append(char)
                }
            }
            i = content.index(after: i)
        }

        if !fieldValue.isEmpty || !row.isEmpty {
            row.append(fieldValue)
            rows.append(row)
        }

        return rows
    }

    // MARK: - Parsing Helpers

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
