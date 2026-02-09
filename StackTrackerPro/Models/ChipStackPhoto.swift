import Foundation
import SwiftData

@Model
final class ChipStackPhoto {
    var timestamp: Date = Date.now
    @Attribute(.externalStorage) var imageData: Data = Data()
    var blindLevel: Int = 1
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
