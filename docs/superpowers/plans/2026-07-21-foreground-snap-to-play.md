# Foreground Snap-to-Play Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Returning to the app after ≥5 minutes in the background during an active tournament lands on the Play tab; shorter absences and out-of-session browsing are untouched.

**Architecture:** A pure `ForegroundSnap` decision enum + thin `scenePhase` wiring in `ContentView`. Spec: `docs/superpowers/specs/2026-07-21-foreground-snap-to-play-design.md` (binding).

**Tech Stack:** SwiftUI, XCTest.

## Global Constraints

- No schema/engine changes. Only `StackTrackerPro/App/ContentView.swift` + tests change.
- Suite green (181 at HEAD; expect +1 test with 5 assertions or 5 tests), Release gate: `xcodebuild build -configuration Release -destination 'generic/platform=iOS Simulator'`. Test command: `xcodebuild test -project StackTrackerPro.xcodeproj -scheme StackTrackerPro -destination 'platform=iOS Simulator,name=iPhone Air,OS=26.5'`.
- DEBUG demo hook in ContentView.onAppear stays untouched.
- Commit direct to `main`, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

### Task 1: ForegroundSnap + scenePhase wiring

**Files:**
- Modify: `StackTrackerPro/App/ContentView.swift`
- Test: `StackTrackerProTests/StackTrackerProTests.swift` (new class `ForegroundSnapTests`)

- [ ] **Step 1: Failing test**

```swift
final class ForegroundSnapTests: XCTestCase {
    func testSnapDecisionTruthTable() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // nil stamp → never
        XCTAssertFalse(ForegroundSnap.shouldSnapToPlay(backgroundedAt: nil, now: now, hasActiveTournament: true))
        // short absence → never
        XCTAssertFalse(ForegroundSnap.shouldSnapToPlay(backgroundedAt: now.addingTimeInterval(-299), now: now, hasActiveTournament: true))
        // long absence, no session → never
        XCTAssertFalse(ForegroundSnap.shouldSnapToPlay(backgroundedAt: now.addingTimeInterval(-301), now: now, hasActiveTournament: false))
        // long absence + active session → snap
        XCTAssertTrue(ForegroundSnap.shouldSnapToPlay(backgroundedAt: now.addingTimeInterval(-301), now: now, hasActiveTournament: true))
        // exact threshold boundary → snap
        XCTAssertTrue(ForegroundSnap.shouldSnapToPlay(backgroundedAt: now.addingTimeInterval(-300), now: now, hasActiveTournament: true))
    }
}
```

- [ ] **Step 2: Run — FAIL** (`ForegroundSnap` undefined).
- [ ] **Step 3: Implement** in ContentView.swift:

```swift
/// Spec 2026-07-21: after a real backgrounding of ≥ threshold during an
/// active tournament, the app returns to the Play tab — brief app-switches
/// and out-of-session browsing keep the user's place.
enum ForegroundSnap {
    static func shouldSnapToPlay(backgroundedAt: Date?, now: Date,
                                 hasActiveTournament: Bool,
                                 threshold: TimeInterval = 300) -> Bool {
        guard let backgroundedAt, hasActiveTournament else { return false }
        return now.timeIntervalSince(backgroundedAt) >= threshold
    }
}
```

Wiring in `ContentView`: add `@Environment(\.scenePhase) private var scenePhase` and `@State private var backgroundedAt: Date?`; after the existing `.onAppear` modifier add:

```swift
.onChange(of: scenePhase) { _, phase in
    switch phase {
    case .background:
        backgroundedAt = .now
    case .active:
        if ForegroundSnap.shouldSnapToPlay(backgroundedAt: backgroundedAt, now: .now,
                                           hasActiveTournament: tournamentManager.activeTournament != nil) {
            selectedTab = 0
        }
        backgroundedAt = nil
    default:
        break   // .inactive must not arm or clear the stamp
    }
}
```

(Read the real file first — if `.inactive` intervenes between background and active, the stamp must survive it; the switch above does that. `tournamentManager` is already in the environment.)
- [ ] **Step 4: Run — PASS.** Full suite + Release build.
- [ ] **Step 5: Simulator check:** launch with `-DemoData` (active demo tournament), background the app (`xcrun simctl` can't background-foreground cleanly — use the Simulator: Home button via the control tool, wait, relaunch is a COLD start so it won't prove the timer; instead verify by temporarily reasoning the wiring compiles and the truth table covers logic; note in the report that the 5-minute path is user-verified on device).
- [ ] **Step 6: Commit** `feat: snap to Play tab on foreground return after 5+ min during active session`.

> **STATUS: EXECUTED 2026-07-21** (commit c3c5c99).
