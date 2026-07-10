# Verbatim Dictation (Parser Removal) — Design

**Approved:** 2026-07-09 with user (device field-testing verdict: structured parsing of dictation is too unreliable to be load-bearing; transcript-as-reference is the product). Option B chosen: no result UI for transcript-only hands.

## Purpose

Dictation becomes a **verbatim voice note attached to a hand**: the user dictates what they recall, sees the transcript on the Capture Screen as a visual reference, and enters structure by tap **if they want to**. The transcript always survives to the hands list and the recap — where the user's frontier-AI recap step can interpret the prose far better than the on-device model could.

## Removals (the bulk of the work)

- `StackTrackerPro/Managers/HandTranscriptParser.swift` — deleted (FoundationModels hand parsing; pbxproj IDs 012B/012C removed).
- `StackTrackerPro/Managers/VoiceHandMapper.swift` — deleted (draft→engine mapping + MappingIssue; pbxproj IDs 012D/012E removed).
- HandCaptureView: `mappingIssues` state + the orange chips row — deleted.
- DictationSheet: the parse phase (spinner, parser-unavailable state, parse-error/retry) — deleted.
- All parser/mapper tests (`HandTranscriptParserTests`, mapper tests inside it, `ParsedHandDraft` fixtures) — deleted. Expect the suite to shrink by roughly 30–35 tests; every remaining test must stay green.
- `ParsedHandDraft`/`SpokenVillain`/`SpokenAction`/`HandContext` types — deleted with the parser (no remaining consumers after the mapper goes).

**Kept:** `DictationEngine` (mic → on-device transcript) unchanged, including the locale-reservation and closure-isolation fixes; all three mic entry points (Capture toolbar, stub-sheet "Talk instead", pending-row mic).

## New flow

1. **DictationSheet** — record → live transcript → primary button retitled **"Use Transcript"** → `onResult(transcript: String)` (plain string; no parsing, no spinner) → dismiss. Empty-transcript handling unchanged (hint + resume).
2. **Capture Screen transcript card** — a collapsible card (header "Transcript", chevron toggle, default expanded) rendered directly under the narration bar when a transcript exists: monospaced footnote text, scrollable when long (fixed max height), theme-consistent. Dictating again REPLACES the transcript (confirm when a previous one exists). The card is the visual guide for tap-entry.
3. **Persistence** — on Save, the transcript is written verbatim to `Hand.notes` (existing schema field, unused by v2 saves — **zero CloudKit impact**). When the user launched from a stub, stub linkage behaves as today.
4. **Save gating** — `Save` enables when `model.isResolvable` **OR** a transcript exists. Transcript-only saves (empty ledger): persist hero cards/position/level context as-is, `resultRaw` stays the model default internally but is **suppressed in every user-facing surface** (no result badge).
5. **Result-free rendering rule** (the "Dictated" treatment): a hand with `sortedActions.isEmpty && !notes.isEmpty` renders:
   - Hands-list row: secondary "Dictated" label where the Won/Lost badge would be; net amount omitted.
   - HandDetailView: a "Transcript" section showing notes; Result section hidden.
   - `HandHistoryFormatter`: result line omitted; transcript appended as a final block (`— Transcript —` then the text). For structured hands that ALSO carry notes, the transcript block appends after the normal result line.
   - Recap exporter: structured-hands section includes the transcript block per hand when notes exist (the AI-prompt preamble already tells the model to use the hands section).
6. **No stack push** for transcript-only saves (`shouldPushStackUpdate` requires resolvable structure — verify and enforce).

## Privacy note (supersedes the voice plan's constraint)

The original voice plan forbade transcript persistence because transcripts were pipeline intermediates. Under this design the transcript IS the user's chosen content — persisting it to their private CloudKit database via `Hand.notes` is the feature, not a leak. Audio still never leaves the device; nothing is sent anywhere.

## Out of scope

- Any re-introduction of on-device parsing (explicitly removed by user decision; the code is in git history if ever revisited).
- Editing the transcript in-app (v1: replace by re-dictating; text editing later if requested).
- Result picker for transcript-only hands (Option A — declined).

## Testing

- Formatter: transcript block for dictated-only hand (no result line) and for structured-hand-with-notes (result line + block); existing formatter tests unchanged.
- Save gating: transcript-only save persists notes and skips stack push (engine-level test on the save path with notes set).
- Edit round-trip: `init(editing:)` must carry notes through (transcript survives an edit).
- Removal completeness: zero references to deleted types (grep gate), suite green after test deletions.
