import Foundation
import SwiftData

@Model
final class BountyEvent {
    var timestamp: Date
    var amount: Int
    var tournament: Tournament?

    init(timestamp: Date = .now, amount: Int) {
        self.timestamp = timestamp
        self.amount = amount
    }
}
