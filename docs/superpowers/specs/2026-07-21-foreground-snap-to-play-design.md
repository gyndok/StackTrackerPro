# Foreground Snap-to-Play — Design

**Approved:** 2026-07-21 with user (option 2 of two presented). Problem: iOS restores the app to whatever tab was last visible when it was kept in memory, so mid-session returns sometimes land on Results/Settings. Verified NOT an app bug — the only programmatic tab write is the DEBUG-only demo hook.

## Behavior (binding)

- When the app **returns to the foreground** (`scenePhase` `.background` → `.active`) AND a tournament session is in progress (`tournamentManager.activeTournament != nil`) AND the app was backgrounded for **≥ 5 minutes**, select the **Play tab** (`selectedTab = 0`).
- Shorter absences change nothing — quick flips to Messages and back return wherever the user was (intentional Results reading survives brief interruptions).
- No active tournament → never snaps (browsing Results between sessions is undisturbed).
- `.inactive` (app switcher peek, notification shade) does NOT arm the timer — only a real `.background` transition does.
- Threshold is a constant (300 s), no setting. Snapping does not pop navigation stacks or dismiss sheets — it only changes the tab selection.

## Implementation shape

- `ContentView`: `@Environment(\.scenePhase)`, `@State private var backgroundedAt: Date?`; `.onChange(of: scenePhase)` — `.background` stamps `backgroundedAt = .now`; `.active` consults the decision rule then clears the stamp.
- Pure, unit-tested decision seam:
  `ForegroundSnap.shouldSnapToPlay(backgroundedAt: Date?, now: Date, hasActiveTournament: Bool, threshold: TimeInterval = 300) -> Bool`
  (small enum in ContentView.swift — true iff stamp non-nil, elapsed ≥ threshold, and an active tournament exists).
- DEBUG demo routes unaffected (snap requires a real backgrounding; demo screenshots never background).

## Constraints

- No schema changes; no engine changes; Release gate + suite green (181 + new tests).

## Testing

- Decision-rule truth table: nil stamp → false; elapsed < threshold → false; elapsed ≥ threshold without tournament → false; elapsed ≥ threshold with tournament → true; exact-threshold boundary → true.
- Manual: background > 5 min with an active session → returns to Play; < 5 min → returns to prior tab.

> **STATUS: EXECUTED 2026-07-21** (commit c3c5c99; suite 182/182, Release clean, review approved first pass).
