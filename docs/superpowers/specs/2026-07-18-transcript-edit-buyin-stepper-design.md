# Transcript Editing + Buy-In Editor + Players Stepper — Design

**Approved:** 2026-07-18 with user (live-play feedback from the Champions Club Monster Stack). Three table-tested improvements shipped together, plus a root-cause repair.

## Root cause discovered during design

The app's `Tournament` model treats **`buyIn` = TOTAL per-entry price** and **`entryFee` = the house portion subtracted from it** (`prizePoolContributionPerPlayer = buyIn − entryFee − bountyAmount − deductions`, Tournament.swift:315; `totalInvestment = buyIn × (1+rebuys) + add-ons`, :249). The seeder and the user manual used the OPPOSITE convention (buy-in = prize-pool portion). An imported seeded event therefore carried `buyIn: 330` where the app meant `400` — today's "total investment $330" bug. PokerAtlas-fetched events (total-price) already match the app's convention.

## Feature 1 — Editable dictation transcripts

**At dictation time** (`DictationSheet`):
- While listening, the transcript area renders live from the engine as today (read-only).
- Once recording stops, the area becomes an editable `TextEditor` seeded with the engine's transcript. The user corrects mis-hearings, then **Use Transcript** returns the edited text.
- Resuming recording after a manual edit prompts: "Resume dictation? New speech will be appended to your edited text." — on confirm, engine restarts and its new utterances append to the edited base (the engine's fresh buffer concatenates after the edited text with a separating space); Cancel keeps editing.
- Empty-transcript hint/cancel behaviors unchanged.

**On saved hands:**
- `HandDetailView`'s Transcript section gains an **Edit** button → sheet with a `TextEditor` over the hand's `notes`, Save/Cancel. Save writes `hand.notes` directly (SwiftData autosaves; no engine involvement).
- The capture screen's `TranscriptCard` (visible during enrichment/edit sessions) gains a pencil affordance opening the same editor bound to `model.transcript`.
- The shared editor is one small reusable view (`TranscriptEditorSheet`) used by all three entry points.

**Rules:** editing never changes a hand's structured data or result; a transcript edited to empty on a dictated-only hand keeps the hand savable only if structure exists (existing `canSave` logic already handles this — an empty transcript with no actions disables Save; the editor warns before saving an empty transcript on a dictated-only hand: "This hand has no logged actions; clearing the transcript leaves it empty."). Zero schema impact (`Hand.notes`).

## Feature 2 — Buy-in editor + convention repair

**In-app editor:**
- On the Metrics pane, the Investment metric row becomes tappable (and gains a small edit glyph). It presents `BuyInEditSheet` with three fields:
  - **Total buy-in** (what left your wallet per entry)
  - **To prize pool**
  - **House fee**
  with the invariant `total = prizePool + fee` maintained live: editing Total keeps Fee and rebalances Prize pool; editing Prize pool or Fee rebalances Total. Negative results clamp to 0 with the offending field highlighted. (Bounty and `deductions` are NOT in this sheet — they have their own fields; the sheet shows a one-line footnote when `bountyAmount > 0` or `deductions > 0` explaining that prize-pool math also subtracts those.)
- Save writes `tournament.buyIn = total`, `tournament.entryFee = fee` (prize pool remains derived). All downstream metrics (totalInvestment, profit, ROI, prizePool, hourly) recompute automatically. Works mid-tournament and on completed tournaments (opened read-only? No — completed tournaments allow the same edit; profit history corrects).
- Field labels use plain language, not the ambiguous "Buy-in"/"Entry fee" pair, so the convention confusion can't recur in the UI.

**Convention repair at the sources (same release):**
- **Seeder** (`tools/seeder/import-scrape.swift`): mapping becomes `buyIn = round(buy_in_usd)` (TOTAL), `entryFee = round(rake_usd ?? 0)`. Goldens updated. This also aligns seeder dedup keys with PokerAtlas-fetched events going forward (both use total).
- **Seeder docs/fixtures** and `tools/seeder/README.md` wording updated to the app convention.
- **User manual** (`docs/manual.html` fields table): "Buy-in / Entry Fee" row rewritten: Buy-in = total cost of one entry; Entry fee = the portion the house keeps.
- **No data migration**: already-published SharedTournament records keep their values (users can correct an imported tournament with the new editor in three taps — the feature exists precisely for this). The TEST/dev records are unaffected.

## Feature 3 — Players-remaining stepper in the status bar

- `StatusBarView` (fixed at the top of every session pane): the players-remaining element gains compact **−** and **+** buttons flanking the count (44pt tap targets, subtle styling consistent with the bar).
- **−** decrements `playersRemaining` by 1 (floor 1); **+** increments (ceiling `fieldSize` when `fieldSize > 0`, otherwise unbounded). Haptic tick on each tap.
- Steps do NOT create chat messages or FieldSnapshots on every tap (a bustout is not an announcement); instead, a trailing debounce (~10s after the last tap) records ONE FieldSnapshot with the settled value so average-stack and pace metrics stay historized without snapshot spam.
- The stepper appears only while the tournament is active and `playersRemaining > 0` was ever set (nothing to step from zero — the existing Metrics-pane edit seeds the first value); read-only/completed sessions hide it.
- The existing Metrics-pane edit popup stays for bulk corrections.

## Touch points

- `StackTrackerPro/Views/Session/DictationSheet.swift` — post-stop editing + resume-append confirm.
- `StackTrackerPro/Views/Components/TranscriptEditorSheet.swift` — NEW small shared editor (pbxproj wiring).
- `StackTrackerPro/Views/Session/HandsPane.swift` (detail Edit), `HandCaptureView.swift` (TranscriptCard pencil).
- `StackTrackerPro/Views/Session/TournamentMetricsView.swift` — investment row tap + `BuyInEditSheet` (new view, may live in the same file if small).
- `StackTrackerPro/Views/Session/StatusBarView.swift` — stepper.
- `StackTrackerPro/Models/Tournament.swift` — no formula changes (formulas are correct under the model's own convention); doc comments clarified.
- `tools/seeder/import-scrape.swift` + goldens + README; `docs/manual.html`.

## Constraints

- No schema/CloudKit changes anywhere (all fields exist).
- `HandCaptureModel` engine untouched except none — transcript is already a stored property; no replay interaction.
- Release-config build gate; suite green (167) plus new tests; seeder `test.sh` green after mapping change.
- DemoData/screenshot routes must still build (TranscriptCard change is additive).

## Out of scope

- Re-transcribing audio (audio is never stored — editing is text-only).
- Editing rebuy/add-on counts in the new sheet (existing quick actions cover them).
- Stepper long-press acceleration; multi-bustout entry (type in the Metrics popup for that).
- Correcting already-published SharedTournament records server-side.

## Testing

- Transcript: engine-stop → edit → Use Transcript returns edited text; resume-append concatenation; saved-hand edit persists to notes; empty-transcript warning on dictated-only hands; edit round-trip via `init(editing:)` unaffected.
- Buy-in sheet rebalance math (total-driven, prize-driven, fee-driven, clamp-at-zero) as pure logic tests; metrics recompute (totalInvestment/profit) after buyIn/entryFee writes.
- Stepper: floor/ceiling clamps; debounced single FieldSnapshot after a tap burst (test the debounce decision logic, not wall-clock timing).
- Seeder: updated goldens (total-price mapping); dedup keys now match PokerAtlas totals; full `test.sh`.
