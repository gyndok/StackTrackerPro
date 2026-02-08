import Foundation

@MainActor
final class MilestoneTracker {
    static let shared = MilestoneTracker()

    private let shownKey = "MilestoneTracker.shownMilestones"

    private init() {}

    /// Checks if the completed tournament triggers any new milestones.
    func checkForNewMilestones(completed: Tournament, allTournaments: [Tournament]) -> [MilestoneType] {
        let shown = shownMilestones()
        var newMilestones: [MilestoneType] = []

        // First Cash: first tournament with payout > 0
        if !shown.contains(MilestoneType.firstCash.rawValue) {
            if let payout = completed.payout, payout > 0 {
                let previousCashes = allTournaments.filter {
                    $0.persistentModelID != completed.persistentModelID &&
                    $0.status == .completed &&
                    ($0.payout ?? 0) > 0
                }
                if previousCashes.isEmpty {
                    newMilestones.append(.firstCash)
                }
            }
        }

        // First Place: position == 1
        if !shown.contains(MilestoneType.firstPlace.rawValue) {
            if completed.finishPosition == 1 {
                let previousWins = allTournaments.filter {
                    $0.persistentModelID != completed.persistentModelID &&
                    $0.status == .completed &&
                    $0.finishPosition == 1
                }
                if previousWins.isEmpty {
                    newMilestones.append(.firstPlace)
                }
            }
        }

        // New PB Cash: payout > all previous
        if !shown.contains(MilestoneType.newPBCash.rawValue) {
            if let payout = completed.payout, payout > 0 {
                let previousMax = allTournaments
                    .filter {
                        $0.persistentModelID != completed.persistentModelID &&
                        $0.status == .completed
                    }
                    .compactMap(\.payout)
                    .max() ?? 0
                if payout > previousMax && previousMax > 0 {
                    newMilestones.append(.newPBCash)
                }
            }
        }

        // Final Table: position <= 9 && fieldSize >= 20
        if !shown.contains(MilestoneType.finalTable.rawValue) {
            if let pos = completed.finishPosition, pos <= 9, completed.fieldSize >= 20 {
                let previousFTs = allTournaments.filter {
                    $0.persistentModelID != completed.persistentModelID &&
                    $0.status == .completed &&
                    ($0.finishPosition ?? 999) <= 9 &&
                    $0.fieldSize >= 20
                }
                if previousFTs.isEmpty {
                    newMilestones.append(.finalTable)
                }
            }
        }

        return newMilestones
    }

    func markShown(_ milestones: [MilestoneType]) {
        var shown = shownMilestones()
        for m in milestones {
            shown.insert(m.rawValue)
        }
        UserDefaults.standard.set(Array(shown), forKey: shownKey)
    }

    private func shownMilestones() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: shownKey) ?? []
        return Set(array)
    }
}
