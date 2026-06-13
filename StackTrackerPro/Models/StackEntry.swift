import Foundation
import SwiftData

@Model
final class StackEntry {
    var timestamp: Date = Date.now
    var chipCount: Int = 0
    var blindLevelNumber: Int = 1
    var currentSB: Int = 0
    var currentBB: Int = 0
    var currentAnte: Int = 0
    /// Seats per table snapshotted at record time, so changing the setting
    /// later doesn't rewrite historical M-ratios. Nil for legacy rows.
    var seatsAtTable: Int?
    var sourceRaw: String = "chat"
    var tournament: Tournament?
    var cashSession: CashSession?

    init(
        timestamp: Date = .now,
        chipCount: Int,
        blindLevelNumber: Int = 1,
        currentSB: Int = 0,
        currentBB: Int = 0,
        currentAnte: Int = 0,
        seatsAtTable: Int? = nil,
        source: StackEntrySource = .chat
    ) {
        self.timestamp = timestamp
        self.chipCount = chipCount
        self.blindLevelNumber = blindLevelNumber
        self.currentSB = currentSB
        self.currentBB = currentBB
        self.currentAnte = currentAnte
        self.seatsAtTable = seatsAtTable
        self.sourceRaw = source.rawValue
    }

    var source: StackEntrySource {
        StackEntrySource(rawValue: sourceRaw) ?? .chat
    }

    var bbCount: Double {
        guard currentBB > 0 else { return 0 }
        return Double(chipCount) / Double(currentBB)
    }

    var mRatio: Double {
        let anteTotal: Int
        switch tournament?.anteFormat ?? .bigBlind {
        case .bigBlind:
            anteTotal = currentAnte
        case .perPlayer:
            // Prefer the snapshotted seat count; only legacy rows fall back
            // to the live setting (read once into a local).
            let seats = seatsAtTable
                ?? (UserDefaults.standard.object(forKey: SettingsKeys.defaultSeatsPerTable) as? Int ?? 9)
            anteTotal = seats * currentAnte
        }
        let orbit = currentSB + currentBB + anteTotal
        guard orbit > 0 else { return 0 }
        return Double(chipCount) / Double(orbit)
    }

    var mZone: MZone {
        MZone.from(mRatio: mRatio)
    }

    var formattedChipCount: String {
        if chipCount >= 1_000_000 {
            let m = Double(chipCount) / 1_000_000.0
            return String(format: "%.1fM", m)
        } else if chipCount >= 1000 {
            let k = Double(chipCount) / 1000.0
            if k == Double(Int(k)) {
                return "\(Int(k))k"
            }
            return String(format: "%.1fk", k)
        }
        return "\(chipCount)"
    }
}
