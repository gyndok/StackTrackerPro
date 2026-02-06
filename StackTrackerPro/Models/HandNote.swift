import Foundation
import SwiftData

@Model
final class HandNote {
    var timestamp: Date
    var descriptionText: String
    var stackBefore: Int?
    var stackAfter: Int?
    var tournament: Tournament?

    init(
        timestamp: Date = .now,
        descriptionText: String,
        stackBefore: Int? = nil,
        stackAfter: Int? = nil
    ) {
        self.timestamp = timestamp
        self.descriptionText = descriptionText
        self.stackBefore = stackBefore
        self.stackAfter = stackAfter
    }
}
