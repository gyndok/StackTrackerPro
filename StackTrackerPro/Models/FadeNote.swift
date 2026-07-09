import Foundation
import SwiftData

/// A break-debrief explanation for a stack delta that was NOT a single hand
/// ("card dead, paid blinds, lost two small pots"). Lets the recap narrative
/// state fades authoritatively without inventing hands.
@Model
final class FadeNote {
    var createdAt: Date = Date.now
    var intervalStart: Date = Date.now
    var intervalEnd: Date = Date.now
    var chipDelta: Int = 0
    var userExplanation: String = ""
    var tournament: Tournament?

    init(intervalStart: Date = .now, intervalEnd: Date = .now,
         chipDelta: Int = 0, userExplanation: String = "") {
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.chipDelta = chipDelta
        self.userExplanation = userExplanation
    }
}
