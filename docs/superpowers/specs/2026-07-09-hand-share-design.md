# Hand Sharing (Share Sheet) — Design

**Approved:** 2026-07-09, brainstormed with user. Schema-free slice; reporter mode, player names, and batch multi-select share are explicitly tabled (see Out of Scope).

## Purpose

Share a logged hand as a formatted text hand history via the iOS share sheet — the "text the hand to your buddy at the other table" move. Text format with Unicode suit glyphs (♠♥♦♣) travels everywhere (iMessage, Mail, Discord, forums); color exists only in the in-app preview, since plain shared text cannot carry color.

## Components

### 1. HandHistoryFormatter (new — `StackTrackerPro/Managers/HandHistoryFormatter.swift`)

Pure, stateless, fully unit-tested. Reads only what `Hand` already persists.

```swift
enum HandHistoryFormatter {
    /// Full text history for one saved hand, with Unicode suit glyphs.
    static func text(for hand: Hand) -> String
}
```

Output format (reference example):

```
Level 21 — 10,000/25,000 (25,000) · Hero BTN K♠K♦ (390,000)
PRE: UTG raises to 75,000 · Hero raises to 200,000 · UTG all-in 390,000 · Hero calls
FLOP J♥8♥4♦
TURN 2♣
RIVER 3♠
UTG shows 9♥T♥ — Hero wins 840,000 (+450,000)
```

Rules:
- Header: `Level N — SB/BB (ante)` for tournament hands; cash hands use the stakes string (`$1/$3`) instead. Then `Hero <POS> <cards> (<stack>)` — cards via `PlayingCard` glyph rendering (`K♠K♦`); omit stack when 0.
- Streets: one line per street that has actions, prefixed `PRE:`/`FLOP …`/`TURN …`/`RIVER …`; board cards appear on their street line. Actions from `sortedActions` in order, ` · ` separated, `<actor> <verb> [amount]` where actor is `Hero` or the villain's position; amounts formatted with grouping.
- Showdown: each villain with a non-empty `shownHolding` gets `<POS> shows <cards>`; result line from `resultRaw`/`amountWon`: `Hero wins <pot> (+net)`, `Hero loses (−net)`, `Chop`, or `Hero folds` — pot from `potSize` when > 0.
- Missing data degrades gracefully (no actions → header + result only; no board → no street lines). Never crashes on partial hands.

### 2. HandSharePreview (new — `StackTrackerPro/Views/Session/HandSharePreview.swift`)

Small sheet: renders the formatter's text in monospaced style with in-app color (♥/♦ red, ♠/♣ primary — colorize by scanning glyph characters in an `AttributedString`; the shared payload remains the plain string). One prominent **Share** button wrapping SwiftUI `ShareLink`/`UIActivityViewController` with the plain text, plus Done.

### 3. Entry points (two)

- **HandDetailView** (`HandsPane.swift`): toolbar Share button → `HandSharePreview(hand:)`.
- **Capture Screen post-save** (`HandCaptureView.swift`): Save currently runs save→stack-push→onSaved→dismiss. It becomes: save→stack-push→show a compact "Saved ✓" confirmation with **Share** / **Done**. Share presents `HandSharePreview` for the just-saved hand; dismissing the preview (or tapping Done) completes the existing onSaved→dismiss path unchanged. No behavior change for users who tap Done.

## Out of Scope (tabled by user, 2026-07-09)

- **Batch multi-select share** — trimmed from this update.
- **Reporter/coverage mode** (standalone logging without a tournament) and **player names** on Hand/HandVillain — both require CloudKit schema additions; deferred until after the current schema ships. Design direction when revisited: coverage-flagged tournament session (reuses level/blinds context, Hands pane, recap export) + additive `name` fields.
- Rendered image share cards (option B from brainstorm) — the formatter output is the future input to that.

## Testing

Formatter unit tests: exact-string match on the KK-vs-9T reference hand; multiway (two villains, one mucked); chop; preflop fold (no board); cash-session header (stakes, no level); partial hand (no actions). View wiring verified by build + device smoke (share sheet is UI-only).

## Constraints

- No new SwiftData models or fields; no schema impact; no engine changes.
- Project conventions apply (pbxproj hand-wiring for the two new files, test hygiene, commit trailer).
