import Foundation
import SwiftData

@Model
final class HandNote {
    var timestamp: Date = Date.now
    var descriptionText: String = ""
    var stackBefore: Int?
    var stackAfter: Int?
    var blindLevelNumber: Int = 0
    var blindsDisplay: String = ""
    var tournament: Tournament?

    init(
        timestamp: Date = .now,
        descriptionText: String,
        stackBefore: Int? = nil,
        stackAfter: Int? = nil,
        blindLevelNumber: Int = 0,
        blindsDisplay: String = ""
    ) {
        self.timestamp = timestamp
        self.descriptionText = descriptionText
        self.stackBefore = stackBefore
        self.stackAfter = stackAfter
        self.blindLevelNumber = blindLevelNumber
        self.blindsDisplay = blindsDisplay
    }
}
