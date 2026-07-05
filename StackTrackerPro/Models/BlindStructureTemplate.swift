import Foundation
import SwiftData

/// A reusable, named blind structure saved to the user's library.
/// Levels are stored as JSON-encoded `[BlindLevelCodable]` rather than a
/// relationship: templates are read-only snapshots, and a single blob keeps
/// the CloudKit record count low.
@Model
final class BlindStructureTemplate {
    var name: String = ""
    var venueName: String?
    var startingChips: Int = 0
    var createdDate: Date = Date.now
    /// JSON-encoded [BlindLevelCodable]
    var levelsData: Data?

    init(
        name: String,
        venueName: String? = nil,
        startingChips: Int = 0,
        levels: [BlindLevelCodable] = []
    ) {
        self.name = name
        self.venueName = venueName
        self.startingChips = startingChips
        self.createdDate = .now
        self.levelsData = try? JSONEncoder().encode(levels)
    }

    var levels: [BlindLevelCodable] {
        get {
            guard let levelsData,
                  let decoded = try? JSONDecoder().decode([BlindLevelCodable].self, from: levelsData) else {
                return []
            }
            return decoded
        }
        set {
            levelsData = try? JSONEncoder().encode(newValue)
        }
    }

    /// Playing levels only (breaks excluded), for display.
    var playingLevelCount: Int {
        levels.filter { !$0.isBreak }.count
    }
}

extension BlindLevelCodable {
    /// Snapshot of a persisted BlindLevel, for saving into a template.
    init(from level: BlindLevel) {
        self.levelNumber = level.levelNumber
        self.smallBlind = level.smallBlind
        self.bigBlind = level.bigBlind
        self.ante = level.ante
        self.durationMinutes = level.durationMinutes
        self.isBreak = level.isBreak
        self.breakLabel = level.breakLabel
    }
}
