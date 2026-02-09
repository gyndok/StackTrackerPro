import Foundation
import SwiftData

@Model
final class FieldSnapshot {
    var timestamp: Date = Date.now
    var totalEntries: Int = 0
    var playersRemaining: Int = 0
    var avgStack: Int?
    var tournament: Tournament?

    init(
        timestamp: Date = .now,
        totalEntries: Int,
        playersRemaining: Int,
        avgStack: Int? = nil
    ) {
        self.timestamp = timestamp
        self.totalEntries = totalEntries
        self.playersRemaining = playersRemaining
        self.avgStack = avgStack
    }
}
