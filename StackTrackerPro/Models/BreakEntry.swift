import Foundation
import SwiftData

@Model
final class BreakEntry {
    var timestamp: Date = Date.now
    var tableNumber: String = ""
    var seatNumber: String = ""
    var chipCount: Int = 0
    var breakDurationSeconds: Int = 600
    var blindLevelNumber: Int = 0
    var blindsDisplay: String = ""
    @Attribute(.externalStorage) var chipPhotoData: Data?
    var tournament: Tournament?

    init(
        tableNumber: String,
        seatNumber: String,
        chipCount: Int,
        breakDurationSeconds: Int,
        blindLevelNumber: Int = 0,
        blindsDisplay: String = "",
        chipPhotoData: Data? = nil
    ) {
        self.timestamp = .now
        self.tableNumber = tableNumber
        self.seatNumber = seatNumber
        self.chipCount = chipCount
        self.breakDurationSeconds = breakDurationSeconds
        self.blindLevelNumber = blindLevelNumber
        self.blindsDisplay = blindsDisplay
        self.chipPhotoData = chipPhotoData
    }
}
