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
