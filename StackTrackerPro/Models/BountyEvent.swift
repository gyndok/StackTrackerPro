import Foundation
import SwiftData

@Model
final class BountyEvent {
    var timestamp: Date = Date.now
    var amount: Int = 0
    var tournament: Tournament?

    init(timestamp: Date = .now, amount: Int) {
        self.timestamp = timestamp
        self.amount = amount
    }
}
