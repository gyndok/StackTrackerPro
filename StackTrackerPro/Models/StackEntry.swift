import Foundation
import SwiftData

@Model
final class StackEntry {
    var timestamp: Date
    var chipCount: Int
    var blindLevelNumber: Int
    var currentSB: Int
    var currentBB: Int
    var currentAnte: Int
    var sourceRaw: String
    var tournament: Tournament?

    init(
        timestamp: Date = .now,
        chipCount: Int,
        blindLevelNumber: Int = 1,
        currentSB: Int = 0,
        currentBB: Int = 0,
        currentAnte: Int = 0,
        source: StackEntrySource = .chat
    ) {
        self.timestamp = timestamp
        self.chipCount = chipCount
        self.blindLevelNumber = blindLevelNumber
        self.currentSB = currentSB
        self.currentBB = currentBB
        self.currentAnte = currentAnte
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
        let orbit = currentSB + currentBB + (9 * currentAnte)
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
