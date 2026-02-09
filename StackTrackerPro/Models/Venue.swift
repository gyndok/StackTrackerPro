import Foundation
import SwiftData

@Model
final class Venue {
    var id: UUID = UUID()
    var name: String = ""
    var city: String?
    var state: String?

    init(name: String, city: String? = nil, state: String? = nil) {
        self.id = UUID()
        self.name = name
        self.city = city
        self.state = state
    }

    var displayName: String {
        if let city, let state {
            return "\(name) — \(city), \(state)"
        } else if let city {
            return "\(name) — \(city)"
        }
        return name
    }
}
