# Transcript Editing + Buy-In Editor + Players Stepper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three live-play fixes — editable dictation transcripts (at capture and on saved hands), a Total/Prize/Fee buy-in editor that repairs today's investment-metric bug, and a one-tap players-remaining stepper in the always-visible status bar — plus the buy-in convention repair at its seeder/manual sources.

**Architecture:** One new shared view (`TranscriptEditorSheet`); a pure `BuyInSplit` rebalance struct + sheet in the Metrics pane; a `TournamentManager.stepPlayersRemaining` API with a debounced FieldSnapshot; seeder mapping + docs fixed to the model's buyIn-is-total convention. Spec: `docs/superpowers/specs/2026-07-18-transcript-edit-buyin-stepper-design.md` (binding).

**Tech Stack:** SwiftUI, SwiftData, XCTest; seeder Swift + test.sh.

## Global Constraints

- No schema/CloudKit changes anywhere (Hand.notes, Tournament.buyIn/entryFee/playersRemaining, FieldSnapshot all exist).
- `HandCaptureModel` engine untouched (transcript is already a stored property; no replay interaction).
- Release gate: `xcodebuild build -configuration Release -destination 'generic/platform=iOS Simulator'`. Test command: `xcodebuild test -project StackTrackerPro.xcodeproj -scheme StackTrackerPro -destination 'platform=iOS Simulator,name=iPhone Air,OS=26.5'` — suite is 167 green at HEAD; keep green plus new tests.
- Seeder harness `tools/seeder/test.sh` must stay green (Task 4 changes mappings + goldens).
- pbxproj hand-wiring for the one new file: TranscriptEditorSheet.swift fileRef `7E5700000000000000000137` / buildFile `...0138`, Views/Components group, four sections.
- DemoData/screenshot routes must still build and pose (TranscriptCard/DictationSheet changes are additive; `previewTranscript` behavior unchanged).
- Editing a transcript never changes structured data or results.
- Commits direct to `main`, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Verified Interfaces (at HEAD cf5751f+spec; re-read while coding)

- `DictationSheet` (Views/Session/DictationSheet.swift): `previewTranscript: String?` DEBUG pose param, `onResult: (String) -> Void`, `@State engine = DictationEngine()`, `cancelled` flag, body = recordingStatus / transcriptArea / actionButtons, `.task` starts engine, `.onDisappear` full-stop teardown. Engine states: `.idle/.requestingPermission/.preparingModel/.listening/.stopping/.error`; transcript text comes from the engine's published property (read the file for its exact name — `engine.transcript`-shaped).
- `HandCaptureModel.transcript: String` (plain stored, rebuild-safe); `canSave { isResolvable || !transcript.isEmpty }`.
- `HandsPane.swift`: HandDetailView Transcript section (renders `hand.notes` monospaced when non-empty); dictated-only rule `sortedActions.isEmpty && !notes.isEmpty`.
- `HandCaptureView.swift`: `TranscriptCard` (collapsible, under NarrationBar, renders `model.transcript`).
- `Tournament` (Models/Tournament.swift): `buyIn`/`entryFee`/`deductions`/`bountyAmount: Int` stored; `totalInvestment = buyIn*(1+rebuysUsed) + addOns` (:249); `prizePoolContributionPerPlayer = max(0, buyIn − entryFee − bountyAmount − deductions)` (:315); `profit = payout + bountyWinnings − totalInvestment`.
- `TournamentMetricsView.swift`: Investment stat at :213 (`StatBlockView(label:… value: formatCurrency(tournament.totalInvestment))` — currently NOT editable); existing editable-stat pattern at :110-116 (`isEditable: true, onTap: { … showPlayersEditor = true }`) with sheet + text fields — copy this pattern for the buy-in sheet.
- `StatusBarView.swift` (77 lines, read fully above): HStack = name/game · Spacer · break-timer-or-level · BBBadge · MRatioBadge. **No players display exists today** — the stepper element is net-new, placed between the Spacer and the level block.
- `FieldSnapshot(timestamp:totalEntries:playersRemaining:avgStack:)`; TournamentManager is `@MainActor @Observable`, holds `modelContext`, pattern for inserts visible in its stub/tournament APIs.
- Seeder mapping to change (tools/seeder/import-scrape.swift, `mappedBuyInAndFee`): currently `buyIn = round(buy_in) − round(rake)`, `entryFee = round(rake)`.
- Manual wording to fix: docs/manual.html fields table row `Buy-in / Entry Fee` ("Buy-in is your prize pool contribution; entry fee goes to the house").

---

### Task 1: TranscriptEditorSheet + three entry points

**Files:**
- Create: `StackTrackerPro/Views/Components/TranscriptEditorSheet.swift`
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (IDs 0137/0138, Views/Components group, four sections)
- Modify: `StackTrackerPro/Views/Session/DictationSheet.swift`
- Modify: `StackTrackerPro/Views/Session/HandsPane.swift` (HandDetailView)
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift` (TranscriptCard)
- Test: `StackTrackerProTests/StackTrackerProTests.swift` (new class `TranscriptEditingTests`)

**Interfaces (Produces):**
```swift
/// Shared transcript editor. `warnIfEmptiedWithoutStructure` drives the
/// dictated-only warning copy; onSave receives the trimmed final text.
struct TranscriptEditorSheet: View {
    let initialText: String
    let warnIfEmptiedWithoutStructure: Bool
    let onSave: (String) -> Void
}
/// Pure merge rule for resume-after-edit (unit-tested):
enum TranscriptMerge {
    static func joined(base: String, newSpeech: String) -> String
    // trimmed base + single space + trimmed newSpeech; either side empty → the other, trimmed.
}
```

- [ ] **Step 1: Failing tests**

```swift
final class TranscriptEditingTests: XCTestCase {
    func testTranscriptMergeJoinsWithSingleSpace() {
        XCTAssertEqual(TranscriptMerge.joined(base: "I had aces ", newSpeech: " he called"),
                       "I had aces he called")
        XCTAssertEqual(TranscriptMerge.joined(base: "", newSpeech: "he called"), "he called")
        XCTAssertEqual(TranscriptMerge.joined(base: "I had aces", newSpeech: ""), "I had aces")
    }

    @MainActor func testEditedTranscriptPersistsThroughModel() {
        let model = HandCaptureModel(/* real init — copy engine-test construction */)
        model.transcript = "original"
        model.transcript = "corrected text"
        XCTAssertTrue(model.canSave)          // transcript-only save stays enabled
        XCTAssertEqual(model.transcript, "corrected text")
    }

    @MainActor func testClearedTranscriptOnDictatedOnlyDisablesSave() {
        let model = HandCaptureModel(/* real init */)
        model.transcript = "spoken words"
        XCTAssertTrue(model.canSave)
        model.transcript = ""
        XCTAssertFalse(model.canSave)         // no structure + no transcript
    }
}
```

- [ ] **Step 2: Run — FAIL** (`TranscriptMerge` undefined; other two pass already — keep them as regression locks and note that in the commit).
- [ ] **Step 3: `TranscriptEditorSheet`.** NavigationStack; `TextEditor` (monospaced footnote, min height 200) seeded `initialText`; Cancel dismisses; Save trims, and when `warnIfEmptiedWithoutStructure && trimmed.isEmpty` shows a confirmation alert ("This hand has no logged actions; clearing the transcript leaves it empty." Clear / Keep Editing) before calling `onSave(trimmed)`. `TranscriptMerge` lives in this file (it's the transcript-text domain helper). pbxproj wiring.
- [ ] **Step 4: DictationSheet post-stop editing.** Add `@State private var editedText: String? = nil` and `@State private var resumeConfirm = false`. When the engine leaves `.listening` via Done/stop (the existing "Use Transcript" phase), `transcriptArea` switches from the live read-only text to a `TextEditor` bound to `editedText` (seeded once from the engine transcript when the stop completes). "Use Transcript" sends `editedText ?? engineText`. A "Resume" button (already exists for the empty-resume path — read the current actionButtons and extend the same control) with a prior manual edit sets `resumeConfirm = true` → alert "Resume dictation? New speech will be appended to your edited text." → on confirm: stash `base = editedText`, restart engine, and the display/text on next stop = `TranscriptMerge.joined(base: base, newSpeech: engineNewText)` (engine restart gives a fresh buffer — verify by reading DictationEngine.start(); if it accumulates instead, capture the pre-resume length and merge only the suffix). `previewTranscript` pose path untouched.
- [ ] **Step 5: Saved-hand entry points.** HandDetailView Transcript section: toolbar-style **Edit** button → `TranscriptEditorSheet(initialText: hand.notes, warnIfEmptiedWithoutStructure: hand.sortedActions.isEmpty) { hand.notes = $0 }`. TranscriptCard: pencil icon in its header row → same sheet bound to `model.transcript` (`warnIfEmptiedWithoutStructure: !model.isResolvable`). Dictated-only rendering rule is unaffected by edits that keep text non-empty; an emptied transcript on a structured hand simply drops the transcript block (existing formatter rules handle it).
- [ ] **Step 6:** Full suite + both configs. Manual smoke on simulator: dictate (sim graceful) → stop → edit → Use Transcript; open a saved dictated hand → Edit → change → reopen shows the change.
- [ ] **Step 7: Commit** `feat: editable dictation transcripts (capture + saved hands)`.

### Task 2: BuyInSplit + buy-in editor sheet

**Files:**
- Modify: `StackTrackerPro/Views/Session/TournamentMetricsView.swift` (investment row + `BuyInEditSheet` private view + `BuyInSplit` struct — file already hosts sibling editors)
- Modify: `StackTrackerPro/Models/Tournament.swift` (doc comments ONLY on buyIn/entryFee/totalInvestment/prizePoolContributionPerPlayer clarifying the convention)
- Test: `StackTrackerProTests/StackTrackerProTests.swift` (new class `BuyInSplitTests`)

**Interfaces (Produces):**
```swift
/// Total = prizePool + fee, maintained live. All Ints, never negative.
struct BuyInSplit: Equatable {
    var total: Int
    var fee: Int
    var prizePool: Int { max(0, total - fee) }
    mutating func setTotal(_ v: Int)      // keeps fee (clamped to ≤ total), prize rebalances
    mutating func setPrizePool(_ v: Int)  // keeps fee, total = v + fee
    mutating func setFee(_ v: Int)        // keeps prizePool, total = prizePool + v
}
```

- [ ] **Step 1: Failing tests**

```swift
final class BuyInSplitTests: XCTestCase {
    func testTodaysBugScenario() {          // $330 imported, user corrects total to $400
        var s = BuyInSplit(total: 330, fee: 0)
        s.setFee(70)                        // prize stays 330, total becomes 400
        XCTAssertEqual(s.total, 400); XCTAssertEqual(s.prizePool, 330); XCTAssertEqual(s.fee, 70)
    }
    func testTotalDrivenRebalance() {
        var s = BuyInSplit(total: 400, fee: 70)
        s.setTotal(600)                     // fee kept, prize 530
        XCTAssertEqual(s.prizePool, 530); XCTAssertEqual(s.fee, 70)
        s.setTotal(50)                      // fee clamps to ≤ total
        XCTAssertEqual(s.fee, 50); XCTAssertEqual(s.prizePool, 0)
    }
    func testPrizeDriven() {
        var s = BuyInSplit(total: 400, fee: 70)
        s.setPrizePool(500)
        XCTAssertEqual(s.total, 570); XCTAssertEqual(s.fee, 70)
    }
    @MainActor func testMetricsRecomputeAfterEdit() {
        let t = Tournament(name: "T", buyIn: 330, entryFee: 0, startingChips: 50_000)
        t.payout = 1_000
        XCTAssertEqual(t.totalInvestment, 330)
        t.buyIn = 400; t.entryFee = 70      // what BuyInEditSheet.save writes
        XCTAssertEqual(t.totalInvestment, 400)
        XCTAssertEqual(t.profit, 600)
        XCTAssertEqual(t.prizePoolContributionPerPlayer, 330)
    }
}
```

- [ ] **Step 2: Run — FAIL** (`BuyInSplit` undefined; metrics test passes — regression lock, note in commit).
- [ ] **Step 3: Implement `BuyInSplit`** exactly per the interface (pure, no Foundation beyond Swift stdlib).
- [ ] **Step 4: `BuyInEditSheet`.** Copy the players-editor sheet pattern (:110-116 + its sheet body): three labeled currency fields — **Total buy-in** ("what one entry costs you"), **To prize pool**, **House fee** — bound through a `@State var split: BuyInSplit` with `onChange` per field routing to the corresponding `set…` (focused-field guard so programmatic rebalances don't loop: only apply `set…` for the field the user is editing — track via `@FocusState`). Footnote when `tournament.bountyAmount > 0 || tournament.deductions > 0`: "Prize-pool math also subtracts your bounty (\(…)) and deductions (\(…))." Save writes `tournament.buyIn = split.total; tournament.entryFee = split.fee`. Sheet opens from the Investment StatBlockView with `isEditable: true` + onTap seeding `split = BuyInSplit(total: tournament.buyIn, fee: tournament.entryFee)`. Works for completed tournaments too — the Metrics pane renders read-only for completed sessions today? READ the surrounding code: if `isReadOnly`-style gating exists for other editable stats, follow the same gating EXCEPT allow investment editing on completed tournaments per spec (completed recap correction is the point) — if that requires a second entry point (recap screen), do NOT add one; the spec binds only the Metrics-pane entry, which remains reachable for completed tournaments via the history detail view.
- [ ] **Step 5: Tournament doc comments** on the four members stating the convention ("buyIn is the TOTAL per-entry price; entryFee is the house-kept portion of it").
- [ ] **Step 6:** Full suite + both configs. Commit `feat: buy-in editor (total / prize pool / house fee) with live rebalance`.

### Task 3: Players-remaining stepper in the status bar

**Files:**
- Modify: `StackTrackerPro/Views/Session/StatusBarView.swift`
- Modify: `StackTrackerPro/Managers/TournamentManager.swift`
- Test: `StackTrackerProTests/StackTrackerProTests.swift` (new class `PlayersStepperTests`)

**Interfaces (Produces):**
```swift
// TournamentManager:
func stepPlayersRemaining(_ delta: Int)         // clamps [1, fieldSize>0 ? fieldSize : Int.max]; no-op without active tournament or when playersRemaining == 0
func settlePlayersSnapshotNow()                  // test seam: cancels the debounce and records the snapshot immediately
// Debounce: each step (re)schedules a 10s Task; on fire, insert one
// FieldSnapshot(totalEntries: fieldSize, playersRemaining: current) via modelContext.
```

- [ ] **Step 1: Failing tests**

```swift
final class PlayersStepperTests: XCTestCase {
    @MainActor func testStepClampsAndSettlesOneSnapshot() throws {
        let (manager, tournament, ctx) = makeActiveTournament(fieldSize: 100, remaining: 3) // helper on existing fixture patterns
        manager.stepPlayersRemaining(-1)
        manager.stepPlayersRemaining(-1)
        XCTAssertEqual(tournament.playersRemaining, 1)
        manager.stepPlayersRemaining(-1)                  // floor 1
        XCTAssertEqual(tournament.playersRemaining, 1)
        manager.stepPlayersRemaining(+1)
        XCTAssertEqual(tournament.playersRemaining, 2)
        let before = try ctx.fetch(FetchDescriptor<FieldSnapshot>()).count
        manager.settlePlayersSnapshotNow()
        let after = try ctx.fetch(FetchDescriptor<FieldSnapshot>()).count
        XCTAssertEqual(after, before + 1)                 // burst → ONE snapshot
        XCTAssertEqual(try XCTUnwrap(ctx.fetch(FetchDescriptor<FieldSnapshot>()).max(by: { $0.timestamp < $1.timestamp })).playersRemaining, 2)
    }

    @MainActor func testStepCeilingAtFieldSize() {
        let (manager, tournament, _) = makeActiveTournament(fieldSize: 100, remaining: 100)
        manager.stepPlayersRemaining(+1)
        XCTAssertEqual(tournament.playersRemaining, 100)
    }

    @MainActor func testStepNoOpWhenNeverSeeded() {
        let (manager, tournament, _) = makeActiveTournament(fieldSize: 100, remaining: 0)
        manager.stepPlayersRemaining(-1)
        XCTAssertEqual(tournament.playersRemaining, 0)    // nothing to step from
    }
}
```

(FieldSnapshot association: read how snapshots relate to the tournament — relationship append vs context insert — and assert through whichever the codebase uses.)
- [ ] **Step 2: Run — FAIL** (methods undefined).
- [ ] **Step 3: Implement** in TournamentManager: mutation + clamps per interface; debounce as a stored `Task<Void, Never>?` cancelled/rescheduled per step (`try? await Task.sleep(for: .seconds(10))` then snapshot on MainActor); `settlePlayersSnapshotNow()` cancels the task and snapshots synchronously. Haptic via the existing `HapticFeedback` helper at the VIEW layer, not in the manager.
- [ ] **Step 4: StatusBarView element.** Between the Spacer and the break/level block, when `tournament.status == .active && tournament.playersRemaining > 0`:

```swift
HStack(spacing: 6) {
    stepButton("minus.circle.fill") { tournamentManager.stepPlayersRemaining(-1) }
    VStack(spacing: 0) {
        Text("\(tournament.playersRemaining)").font(PokerTypography.statValue).monospacedDigit().foregroundColor(.textPrimary)
        Text("left").font(PokerTypography.chatCaption).foregroundColor(.textSecondary)
    }
    stepButton("plus.circle.fill") { tournamentManager.stepPlayersRemaining(+1) }
}
```

with `stepButton` = 44×44 tappable `Button` showing a 20pt SF symbol tinted `.textSecondary`, `HapticFeedback.impact(.light)` in the action, accessibility labels "Decrement players remaining"/"Increment players remaining". Read-only/completed sessions render nothing (condition above). Name truncation already handled by `lineLimit(1)`; verify visually the bar fits on the iPhone Air sim width with break timer active (screenshot).
- [ ] **Step 5:** Full suite + both configs + visual check (screenshot of the bar with stepper). Commit `feat: players-remaining stepper in session status bar`.

### Task 4: Convention repair (seeder + manual) + closeout

**Files:**
- Modify: `tools/seeder/import-scrape.swift` (`mappedBuyInAndFee`), `tools/seeder/tests/golden/*` (regenerate BY HAND per new rule), `tools/seeder/README.md` (mapping wording)
- Modify: `docs/manual.html` (Buy-in / Entry Fee row)
- Docs: STATUS EXECUTED on spec + plan; memory update note for coordinator.

- [ ] **Step 1: Seeder mapping.** `buyIn = round(buy_in_usd)` (TOTAL), `entryFee = round(rake_usd ?? 0)`. Update every golden's buyIn/entryFee by hand from its fixture (e.g. 600/95 event → buyIn 600, entryFee 95; null-rake → buyIn unchanged, entryFee 0 — those goldens don't change). Update the README mapping table + the tx-venues dedup comment (dedup keys now carry TOTAL — matches PokerAtlas fetched events; note that pre-2026-07-18 manually-seeded records used the old prize-portion values and simply occupy different keys).
- [ ] **Step 2:** `cd tools/seeder && ./build.sh && ./test.sh` → PASS (goldens updated first, watch the diff fail then pass — the harness is the TDD loop here).
- [ ] **Step 3: Manual.** docs/manual.html fields row becomes: `<td><strong>Buy-in / Entry Fee</strong></td><td>Buy-in is the total cost of one entry; the entry fee is the portion the house keeps (the rest funds the prize pool)</td>` (match surrounding markup exactly).
- [ ] **Step 4:** App suite + both configs one final time (no app-code changes in this task — confirm nothing drifted). STATUS: EXECUTED lines on spec + this plan with commit range. Commit `fix: buy-in convention repair (seeder mapping + manual) + closeout`.

## Self-Review

- Spec coverage: F1→T1 (three entry points, merge rule, empty-warning), F2→T2 (sheet, rebalance, doc comments) + T4 (sources), F3→T3 (stepper, clamps, debounce, gating); root-cause section→T2/T4; constraints mirrored above. Testing list maps to the three new test classes + seeder harness.
- Placeholders: none — every step carries code or exact edits; the two read-first checks (engine buffer accumulation, snapshot association) state what to look for and both outcomes.
- Type consistency: `TranscriptMerge.joined(base:newSpeech:)`, `BuyInSplit.setTotal/setPrizePool/setFee`, `stepPlayersRemaining(_:)`/`settlePlayersSnapshotNow()` used identically in interface blocks and steps.
