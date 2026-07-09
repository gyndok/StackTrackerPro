import Foundation

struct DebriefGap: Equatable {
    let start: Date
    let end: Date
    let delta: Int
}

/// Finds stack intervals with a swing-sized delta that have no stub or logged
/// hand near them — the "unexplained" gaps a break debrief should ask about.
enum BreakDebriefEngine {
    /// Timestamp slop when matching stubs/hands to an interval.
    static let explainPadding: TimeInterval = 10 * 60

    static func unexplainedGaps(for tournament: Tournament, since: Date?,
                                sensitivityPercent: Int, maxCount: Int = 3) -> [DebriefGap] {
        // Exclude the synthetic baseline entry `startTournament` seeds with
        // the nominal starting stack — it's bookkeeping, not a reported
        // in-session update, so the jump from it to the first real update
        // isn't a "mystery" swing worth asking about.
        let entries = tournament.sortedStackEntries.filter { $0.source != .initial }
        guard entries.count >= 2 else { return [] }

        let explainers: [Date] =
            (tournament.handStubs ?? []).filter { $0.status != .dismissed }.map(\.createdAt) +
            tournament.sortedHands.map(\.timestamp)

        var gaps: [DebriefGap] = []
        for (prev, next) in zip(entries, entries.dropFirst()) {
            if let since, next.timestamp <= since { continue }
            let delta = next.chipCount - prev.chipCount
            guard SwingDetector.isSwing(previous: prev.chipCount, new: next.chipCount,
                                        currentBB: next.currentBB,
                                        sensitivityPercent: sensitivityPercent) else { continue }
            let lo = prev.timestamp.addingTimeInterval(-explainPadding)
            let hi = next.timestamp.addingTimeInterval(explainPadding)
            let explained = explainers.contains { $0 >= lo && $0 <= hi }
            if !explained {
                gaps.append(DebriefGap(start: prev.timestamp, end: next.timestamp, delta: delta))
            }
        }
        return Array(gaps.sorted { abs($0.delta) > abs($1.delta) }.prefix(maxCount))
    }
}
