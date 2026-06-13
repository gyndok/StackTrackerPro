import Foundation
import SwiftData
import os

struct CSVExportResult {
    let csvString: String
    let totalRows: Int
    let cashCount: Int
    let tournamentCount: Int
}

struct CSVExporter {

    private static let logger = Logger(subsystem: "com.gyndok.stacktrackerpro", category: "CSVExporter")

    /// Exports all completed sessions to CSV matching the import format:
    /// Date, Format, Variant, Stakes, Location, Buy-in ($), Cash-out ($), Profit/Loss ($),
    /// Duration (hours), Hourly Rate ($/hr), Notes, Tournament Name, Finish Position,
    /// Field Size, Rebuys, Bounties Collected, Bounty Amount
    ///
    /// Note: fetch failures are logged (the export will then be missing that
    /// record type) — the signature stays non-throwing because SettingsView
    /// owns the call site and expects a value.
    static func exportCSV(from context: ModelContext) -> CSVExportResult {
        let header = "Date,Format,Variant,Stakes,Location,Buy-in ($),Cash-out ($),Profit/Loss ($),Duration (hours),Hourly Rate ($/hr),Notes,Tournament Name,Finish Position,Field Size,Rebuys,Bounties Collected,Bounty Amount"

        var rows: [(date: Date, line: String)] = []
        var cashCount = 0
        var tournamentCount = 0

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM/dd/yyyy"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        // Fetch completed cash sessions
        do {
            var descriptor = FetchDescriptor<CashSession>(
                predicate: #Predicate { $0.statusRaw == "completed" },
                sortBy: [SortDescriptor(\.startTime)]
            )
            descriptor.fetchLimit = nil
            let cashSessions = try context.fetch(descriptor)

            for session in cashSessions {
                let date = session.endTime ?? session.startTime
                let dateStr = dateFormatter.string(from: date)
                let variant = escapeCSV(session.gameTypeRaw)
                let stakes = escapeCSV(session.stakes)
                let location = escapeCSV(session.venueName ?? "")
                let buyIn = session.buyInTotal
                // Blank cash-out means "no recorded result" — preserved on import
                let cashOutStr = session.cashOut.map(String.init) ?? ""
                let profitStr = session.cashOut.map { String($0 - session.buyInTotal) } ?? ""
                let durationHours = session.duration.map { $0 / 3600 }
                let hourlyRate = session.hourlyRate

                let durationStr = durationHours.map { String(format: "%.2f", $0) } ?? ""
                let hourlyStr = hourlyRate.map { String(format: "%.2f", $0) } ?? ""
                let notes = escapeCSV(session.notes ?? "")

                let line = "\(dateStr),Cash,\(variant),\(stakes),\(location),\(buyIn),\(cashOutStr),\(profitStr),\(durationStr),\(hourlyStr),\(notes),,,,,,"
                rows.append((date: date, line: line))
                cashCount += 1
            }
        } catch {
            logger.error("CSV export: failed to fetch cash sessions: \(error.localizedDescription, privacy: .public)")
        }

        // Fetch completed tournaments
        do {
            var descriptor = FetchDescriptor<Tournament>(
                predicate: #Predicate { $0.statusRaw == "completed" },
                sortBy: [SortDescriptor(\.startDate)]
            )
            descriptor.fetchLimit = nil
            let tournaments = try context.fetch(descriptor)

            for t in tournaments {
                let date = t.endDate ?? t.startDate
                let dateStr = dateFormatter.string(from: date)
                let variant = escapeCSV(t.gameTypeRaw)
                let stakes = ""
                let location = escapeCSV(t.venueName ?? "")
                let buyIn = t.totalInvestment
                // Blank cash-out means "no recorded result" — preserved on import
                let cashOutStr = t.payout.map(String.init) ?? ""
                let profitStr = t.profit.map(String.init) ?? ""
                let durationHours = t.duration.map { $0 / 3600 }
                let hourlyRate: Double? = if let p = t.profit, let d = t.duration, d > 0 {
                    Double(p) / (d / 3600)
                } else {
                    nil
                }

                let durationStr = durationHours.map { String(format: "%.2f", $0) } ?? ""
                let hourlyStr = hourlyRate.map { String(format: "%.2f", $0) } ?? ""
                let tournamentName = escapeCSV(t.name)
                let finishStr = t.finishPosition.map(String.init) ?? ""
                let fieldStr = t.fieldSize > 0 ? String(t.fieldSize) : ""
                let rebuysStr = String(t.rebuysUsed)
                let bountiesStr = String(t.bountiesCollected)
                let bountyAmountStr = String(t.bountyAmount)

                let line = "\(dateStr),Tournament,\(variant),\(stakes),\(location),\(buyIn),\(cashOutStr),\(profitStr),\(durationStr),\(hourlyStr),,\(tournamentName),\(finishStr),\(fieldStr),\(rebuysStr),\(bountiesStr),\(bountyAmountStr)"
                rows.append((date: date, line: line))
                tournamentCount += 1
            }
        } catch {
            logger.error("CSV export: failed to fetch tournaments: \(error.localizedDescription, privacy: .public)")
        }

        // Sort all rows by date
        rows.sort { $0.date < $1.date }

        let csvLines = [header] + rows.map(\.line)
        let csvString = csvLines.joined(separator: "\n")

        return CSVExportResult(
            csvString: csvString,
            totalRows: rows.count,
            cashCount: cashCount,
            tournamentCount: tournamentCount
        )
    }

    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}
