import Foundation
import SwiftData

@Model
final class BlindLevel {
    var levelNumber: Int = 0
    var smallBlind: Int = 0
    var bigBlind: Int = 0
    var ante: Int = 0
    var durationMinutes: Int = 30
    var isBreak: Bool = false
    var breakLabel: String?
    var tournament: Tournament?

    init(
        levelNumber: Int,
        smallBlind: Int,
        bigBlind: Int,
        ante: Int = 0,
        durationMinutes: Int = 30,
        isBreak: Bool = false,
        breakLabel: String? = nil
    ) {
        self.levelNumber = levelNumber
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
        self.ante = ante
        self.durationMinutes = durationMinutes
        self.isBreak = isBreak
        self.breakLabel = breakLabel
    }

    /// Cost of one full orbit (seats-per-table × ante + SB + BB)
    var orbitCost: Int {
        let seats = UserDefaults.standard.object(forKey: SettingsKeys.defaultSeatsPerTable) as? Int ?? 9
        return smallBlind + bigBlind + (seats * ante)
    }

    var blindsDisplay: String {
        if isBreak {
            return breakLabel ?? "Break"
        }
        if ante > 0 {
            return "\(formatted(smallBlind))/\(formatted(bigBlind)) ante \(formatted(ante))"
        }
        return "\(formatted(smallBlind))/\(formatted(bigBlind))"
    }

    private func formatted(_ value: Int) -> String {
        if value >= 1000 {
            let k = Double(value) / 1000.0
            if k == Double(Int(k)) {
                return "\(Int(k))k"
            }
            return String(format: "%.1fk", k)
        }
        return "\(value)"
    }
}
