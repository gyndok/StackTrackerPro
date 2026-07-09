import Foundation

/// Pure swing-detection math (spec F2):
///   threshold = max(sensitivity% × previousStack, 8 × currentBB)
/// Suppressions: previous update older than 45 min (multi-pot drift → break
/// debrief handles it), or an existing pending stub within the last 90 s.
struct SwingDetector {
    static let staleUpdateMinutes: Double = 45
    static let duplicateWindowSeconds: Double = 90

    static func isSwing(previous: Int, new: Int, currentBB: Int, sensitivityPercent: Int) -> Bool {
        guard sensitivityPercent > 0, previous > 0 else { return false }
        let delta = abs(new - previous)
        let pctThreshold = Int((Double(previous) * Double(sensitivityPercent) / 100.0).rounded())
        let threshold = max(pctThreshold, 8 * max(currentBB, 0))
        guard threshold > 0 else { return false }
        return delta >= threshold
    }

    static func shouldSuppress(previousEntryDate: Date, now: Date,
                               latestPendingStubDate: Date?) -> Bool {
        if now.timeIntervalSince(previousEntryDate) > staleUpdateMinutes * 60 { return true }
        if let stubDate = latestPendingStubDate,
           now.timeIntervalSince(stubDate) < duplicateWindowSeconds { return true }
        return false
    }
}
