# Verbatim Dictation (Parser Removal) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dictation delivers a verbatim transcript to the Capture Screen as a visible reference card and into `Hand.notes` on save — the on-device parsing pipeline is removed entirely (user decision after device field-testing).

**Architecture:** Delete `HandTranscriptParser` + `VoiceHandMapper` (+types, +tests, +chips UI); `DictationSheet` returns the plain transcript; `HandCaptureModel` gains a `transcript` property that persists to `Hand.notes`; "Dictated" rendering rules replace result badges for structure-free hands. `DictationEngine` and all three mic entry points unchanged. Spec: `docs/superpowers/specs/2026-07-09-verbatim-dictation-design.md`.

**Tech Stack:** SwiftUI, XCTest. Zero schema impact (`Hand.notes` already exists and is unused by v2 saves — verify before relying on it; if any v2 path writes notes, STOP and report).

## Global Constraints

- No CloudKit schema changes; `HandCaptureModel` engine (replay/result semantics) untouched except the additive `transcript` property and save-path notes write.
- `DictationEngine` untouched (its locale + closure-isolation fixes are device-validated).
- Removal completeness gate: `grep -rn "HandTranscriptParser\|VoiceHandMapper\|ParsedHandDraft\|SpokenVillain\|SpokenAction\|MappingIssue\|HandContext" StackTrackerPro StackTrackerProTests` → zero hits after Task 1 (plan docs excluded).
- Build gates: Debug AND `-configuration Release -destination 'generic/platform=iOS Simulator'` clean.
- Test command: `xcodebuild test -project StackTrackerPro.xcodeproj -scheme StackTrackerPro -destination 'platform=iOS Simulator,name=iPhone Air,OS=26.5'`. Suite is 177 green pre-plan (expect ~145 after test deletions, then +new).
- pbxproj: REMOVE IDs 012B/012C (HandTranscriptParser) and 012D/012E (VoiceHandMapper) from all four sections each. No new files → no new IDs.
- Test hygiene conventions; commits direct to `main`, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Sequencing:** do not start until the F18/F19 fix round has committed (it edits HandCaptureView/TournamentRecapExporter/tests).

---

### Task 1: Removal sweep + DictationSheet simplification

**Files:**
- Delete: `StackTrackerPro/Managers/HandTranscriptParser.swift`, `StackTrackerPro/Managers/VoiceHandMapper.swift`
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (remove 012B–012E, four sections each)
- Modify: `StackTrackerPro/Views/Session/DictationSheet.swift` — remove the parse phase entirely (parser-availability state, spinner, parse-error/retry); `onResult` becomes `(String) -> Void` receiving the raw transcript; primary button retitled **"Use Transcript"**; empty-transcript hint/resume behavior unchanged; Cancel/swipe-dismiss teardown unchanged (the `cancelled` flag now guards transcript delivery instead of draft delivery).
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift` — delete `mappingIssues` state, the chips row, and `applyDraft`; the dictation sheet's `onResult` now stores the transcript (Task 2 adds the model property — in THIS task, wire to a local `@State pendingTranscript: String?` TODO-free by implementing against the Task 2 interface `model.transcript = text` directly IF you do Tasks 1+2 in one branch sitting; otherwise stage with the model property added here as a bare `var transcript: String = ""` on HandCaptureModel so nothing dangles).
- Tests: delete `HandTranscriptParserTests` (whole class incl. the mapper tests inside it) and any `ParsedHandDraft`/`emptyDraft` fixtures.

Steps: delete → pbxproj → grep gate (zero hits) → full suite (expect ~145, all green) → both builds clean → commit `refactor: remove dictation parsing pipeline (verbatim transcript design)`.

### Task 2: Transcript card, persistence, and Dictated rendering

**Files:**
- Modify: `StackTrackerPro/Managers/HandCaptureModel.swift` — `var transcript: String = ""` (plain stored; NOT an input; survives rebuild — verify rebuild doesn't touch it); `init(editing:)` restores it from `hand.notes`; `save()` writes `hand.notes = transcript` (and continues to work when empty). Save gating: `var canSave: Bool { isResolvable || !transcript.isEmpty }` — new computed, view switches from isResolvable to canSave; `shouldPushStackUpdate` must additionally require `isResolvable` (a transcript-only save NEVER pushes — add the clause + test).
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift` — collapsible "Transcript" card under the narration bar when `!model.transcript.isEmpty` (monospaced footnote, max height ~160 with internal scroll, chevron collapse, default expanded); dictation `onResult` sets `model.transcript` with a replace-confirm when one already exists; Save button gates on `canSave`.
- Modify: `StackTrackerPro/Views/Session/HandsPane.swift` — row: when `hand.sortedActions.isEmpty && !hand.notes.isEmpty` show secondary-styled "Dictated" instead of the result badge and omit the net amount; HandDetailView: add "Transcript" section (monospaced) when notes non-empty; hide the Result section for the dictated-only case.
- Modify: `StackTrackerPro/Managers/HandHistoryFormatter.swift` — when `hand.sortedActions.isEmpty && !hand.notes.isEmpty`: omit the result line; always (any hand with non-empty notes): append a final block `— Transcript —` newline + notes verbatim.
- Recap: `TournamentRecapExporter.structuredHandsSection` — confirm it already routes through per-hand content that will include the transcript via the formatter OR add the transcript line explicitly (read the current section builder; match its style).

**Tests (all deterministic):**
```swift
// Formatter
func testFormatterDictatedOnlyHandOmitsResultAndAppendsTranscript()
func testFormatterStructuredHandWithNotesAppendsTranscriptAfterResult()
// Save path
@MainActor func testTranscriptOnlySavePersistsNotesAndSkipsStackPush()
@MainActor func testCanSaveWithTranscriptOnly()
// Edit round-trip
@MainActor func testEditRoundTripCarriesTranscript()
```
Each asserts concrete strings/flags (`hand.notes == transcript`, `shouldPushStackUpdate == false`, formatter output contains `— Transcript —` and not `Hero folds`, etc.).

Steps: TDD where logic-level → implement → full suite green → both builds → commit `feat: verbatim dictation transcript card and Dictated rendering`.

### Task 3: Verification + closeout

- Full suite + both configs at HEAD; grep gate re-run.
- Simulator smoke: launch; open capture; mic (graceful sim behavior); confirm no chips UI remains.
- Device checklist addendum appended to this plan's footer: dictate → transcript card appears → save without structure → "Dictated" row → detail shows transcript → share text carries `— Transcript —` block → recap includes it.
- Mark spec + this plan executed; ledger; commit docs.

## Self-Review

- Spec coverage: removals ✓ (T1), new flow items 1–6 ✓ (T2 maps one-to-one), privacy note is doc-only ✓, out-of-scope respected ✓, testing list ✓ (T2 tests + T1 grep gate).
- Placeholder scan: T1's staging note gives a concrete either/or, not a TBD.
- Type consistency: `model.transcript`, `canSave`, `onResult: (String) -> Void` used consistently across tasks.
