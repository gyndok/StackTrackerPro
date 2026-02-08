import Foundation
import SwiftData

@Model
final class ChipStackPhoto {
    var timestamp: Date
    var imageData: Data
    var blindLevel: Int
    var stackAtTime: Int?
    var tournament: Tournament?

    init(
        timestamp: Date = .now,
        imageData: Data,
        blindLevel: Int = 1,
        stackAtTime: Int? = nil
    ) {
        self.timestamp = timestamp
        self.imageData = imageData
        self.blindLevel = blindLevel
        self.stackAtTime = stackAtTime
    }
}
