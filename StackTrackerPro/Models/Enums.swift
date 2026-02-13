import SwiftUI

// MARK: - Tournament Status

enum TournamentStatus: String, Codable, CaseIterable {
    case setup = "setup"
    case active = "active"
    case paused = "paused"
    case completed = "completed"

    var label: String {
        switch self {
        case .setup: return "Setup"
        case .active: return "Active"
        case .paused: return "Paused"
        case .completed: return "Completed"
        }
    }

    var icon: String {
        switch self {
        case .setup: return "gear"
        case .active: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .setup: return .textSecondary
        case .active: return .mZoneGreen
        case .paused: return .mZoneYellow
        case .completed: return .goldAccent
        }
    }
}

// MARK: - Session Status (shared by cash games)

enum SessionStatus: String, Codable, CaseIterable {
    case setup = "setup"
    case active = "active"
    case paused = "paused"
    case completed = "completed"

    var label: String {
        switch self {
        case .setup: return "Setup"
        case .active: return "Active"
        case .paused: return "Paused"
        case .completed: return "Completed"
        }
    }

    var icon: String {
        switch self {
        case .setup: return "gear"
        case .active: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .setup: return .textSecondary
        case .active: return .mZoneGreen
        case .paused: return .mZoneYellow
        case .completed: return .goldAccent
        }
    }
}

// MARK: - Message Sender

enum MessageSender: String, Codable {
    case user = "user"
    case ai = "ai"
    case system = "system"
}

// MARK: - M-Zone

enum MZone: String {
    case green = "Green Zone"
    case yellow = "Yellow Zone"
    case orange = "Orange Zone"
    case red = "Red Zone"

    var color: Color {
        switch self {
        case .green: return .mZoneGreen
        case .yellow: return .mZoneYellow
        case .orange: return .mZoneOrange
        case .red: return .mZoneRed
        }
    }

    var coachingTip: String {
        switch self {
        case .green:
            return "Comfortable stack. Play your A-game and look for spots to accumulate."
        case .yellow:
            return "Getting shorter. Start widening your opening range and look for re-steal spots."
        case .orange:
            return "Push/fold territory approaching. Look to shove light from late position."
        case .red:
            return "Critical! Push or fold only. Any ace, pair, or two broadways is a shove."
        }
    }

    static func from(mRatio: Double) -> MZone {
        switch mRatio {
        case 20...: return .green
        case 10..<20: return .yellow
        case 5..<10: return .orange
        default: return .red
        }
    }
}

// MARK: - Game Type

enum GameType: String, Codable, CaseIterable {
    case nlh = "NLH"
    case plo = "PLO"
    case mixed = "Mixed"

    var label: String {
        switch self {
        case .nlh: return "No Limit Hold'em"
        case .plo: return "Pot Limit Omaha"
        case .mixed: return "Mixed Game"
        }
    }

    /// Returns a display label for any gameTypeRaw string (built-in or custom).
    static func label(for rawValue: String) -> String {
        if let builtIn = GameType(rawValue: rawValue) {
            return builtIn.label
        }
        return GameTypeStore.shared.label(for: rawValue) ?? rawValue
    }
}

// MARK: - Custom Game Type Storage

final class GameTypeStore: @unchecked Sendable {
    static let shared = GameTypeStore()
    private let key = "settings.customGameTypes"

    struct CustomType: Codable, Identifiable, Equatable {
        var id: String { rawValue }
        let rawValue: String
        let label: String
    }

    var customTypes: [CustomType] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let types = try? JSONDecoder().decode([CustomType].self, from: data) else {
                return []
            }
            return types
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    /// All available game types: built-in + custom
    var allOptions: [(rawValue: String, label: String)] {
        var options: [(rawValue: String, label: String)] = GameType.allCases.map { ($0.rawValue, $0.label) }
        options.append(contentsOf: customTypes.map { ($0.rawValue, $0.label) })
        return options
    }

    func label(for rawValue: String) -> String? {
        customTypes.first(where: { $0.rawValue == rawValue })?.label
    }

    func add(rawValue: String, label: String) {
        var types = customTypes
        guard !types.contains(where: { $0.rawValue == rawValue }) else { return }
        // Don't add if it conflicts with a built-in type
        guard GameType(rawValue: rawValue) == nil else { return }
        types.append(CustomType(rawValue: rawValue, label: label))
        customTypes = types
    }

    func remove(rawValue: String) {
        var types = customTypes
        types.removeAll { $0.rawValue == rawValue }
        customTypes = types
    }
}

// MARK: - BB Zone

enum BBZone: String {
    case green = "Green Zone"
    case yellow = "Yellow Zone"
    case orange = "Orange Zone"
    case red = "Red Zone"

    var color: Color {
        switch self {
        case .green: return .mZoneGreen
        case .yellow: return .mZoneYellow
        case .orange: return .mZoneOrange
        case .red: return .mZoneRed
        }
    }

    private var severity: Int {
        switch self {
        case .green: return 0
        case .yellow: return 1
        case .orange: return 2
        case .red: return 3
        }
    }

    func isWorseThan(_ other: BBZone) -> Bool {
        severity > other.severity
    }

    static func from(bbCount: Double) -> BBZone {
        switch bbCount {
        case 30...: return .green
        case 15..<30: return .yellow
        case 8..<15: return .orange
        default: return .red
        }
    }
}

// MARK: - Stack Entry Source

enum StackEntrySource: String, Codable {
    case chat = "chat"
    case manual = "manual"
    case initial = "initial"
}

// MARK: - Milestone Type

enum MilestoneType: String, CaseIterable {
    case firstCash = "first_cash"
    case firstPlace = "first_place"
    case newPBCash = "new_pb_cash"
    case finalTable = "final_table"

    var title: String {
        switch self {
        case .firstCash: return "FIRST CASH!"
        case .firstPlace: return "FIRST PLACE!"
        case .newPBCash: return "NEW PERSONAL BEST!"
        case .finalTable: return "FINAL TABLE!"
        }
    }

    var subtitle: String {
        switch self {
        case .firstCash: return "You cashed in a tournament for the first time"
        case .firstPlace: return "You took down the whole thing"
        case .newPBCash: return "Your biggest cash ever"
        case .finalTable: return "You made the final table"
        }
    }

    var icon: String {
        switch self {
        case .firstCash: return "dollarsign.circle.fill"
        case .firstPlace: return "trophy.fill"
        case .newPBCash: return "star.fill"
        case .finalTable: return "crown.fill"
        }
    }
}
