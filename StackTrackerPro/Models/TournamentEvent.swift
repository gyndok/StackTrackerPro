import Foundation
import SwiftData

/// Kinds of tournament happenings that previously mutated state in place
/// with no history. Everything else in the timeline (stacks, field, notes,
/// chat, bounties, breaks, photos) already has its own timestamped model.
enum TournamentEventType: String {
    case rebuy
    case levelChange
    case addOnField      // observed field-wide add-on count changed
    case addOnPlayer     // player's own add-on count changed
    case pause
    case resume
    case completed
    case startingChipsCorrected
}

/// A timestamped tournament event, appended by TournamentManager whenever
/// state changes that has no timestamped record of its own. Powers the
/// chronological timeline in the recap export.
@Model
final class TournamentEvent {
    var timestamp: Date = Date.now
    var typeRaw: String = ""
    /// Type-dependent payload: new level number for levelChange, running
    /// counts for rebuy/add-on events, finish position for completed.
    var intValue: Int = 0
    var tournament: Tournament?

    init(type: TournamentEventType, intValue: Int = 0, timestamp: Date = .now) {
        self.typeRaw = type.rawValue
        self.intValue = intValue
        self.timestamp = timestamp
    }

    var type: TournamentEventType? {
        TournamentEventType(rawValue: typeRaw)
    }

    /// Human-readable line for the recap timeline.
    var timelineDescription: String {
        switch type {
        case .rebuy: return "Rebuy / re-entry taken (total \(intValue))"
        case .levelChange: return "Moved to level \(intValue)"
        case .addOnField: return "Field add-on count updated to \(intValue)"
        case .addOnPlayer: return "Player add-ons updated to \(intValue)"
        case .pause: return "Session paused"
        case .resume: return "Session resumed"
        case .completed: return intValue > 0 ? "Eliminated in position \(intValue)" : "Tournament completed"
        case .startingChipsCorrected: return "Starting stack corrected to \(intValue.formatted())"
        case nil: return "Event"
        }
    }
}
