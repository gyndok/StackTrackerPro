# Hand Capture Flow — Design

**Approved:** 2026-09-27 (audit → brainstorm; all four choices made by the user: result-first A, bottom bar B, card grid A, sizing A; design approved as presented). Ships as **1.3.0**.

## Problem

The capture screen is engine-correct but tap-expensive. A routine hand (BTN A♥K♦ 3-bets an UTG open, c-bets a K-high flop, takes it down) costs ~30 taps plus repeated scrolling to find the "to act" row. Four causes, all UI:

1. Everything is one long `ScrollView`; the action row sits below hero, villains, and a growing ledger.
2. Showdown blocks Save until every villain's cards are entered or mucked; the escape hatch is buried in a `Menu`.
3. The rank→suit picker doubles every card tap (12 per hand).
4. Preflop sizing presets are raise-to totals that all disable when facing a raise, forcing the system keyboard.

The engine (`HandCaptureModel`) is not the problem and is left alone except for one read-only derived property (§3).

## Scope

In: pinned bottom bar with a context strip; one-tap 52+13 card grid; context-aware sizing presets + inline keypad; result-first showdown; collapsed setup chips; immediate dismiss on save with a toast. Out (follow-on tier, not this release): one-tap seat-to-add villains, street macros ("check around"), position-row redesign.

## 1. Screen structure

`HandCaptureView` becomes:

```
VStack(spacing: 0) {
    ScrollView { narration · transcript · hero chips · villains · ledger · result+tags+save }
    CaptureBottomBar(state:)          // pinned above the safe area
}
```

The bar has exactly one state at a time, derived from engine state by a pure function (`CaptureBarState.derive`, tested). Priority, first match wins:

| State | Condition | Bar content |
|---|---|---|
| `done` | `isHandOver` | Bar hidden. Result, tags, Save live in the scroll; the board stays visible in the narration card. |
| `dealingBoard` | `boardCardsNeeded > 0` | Header "Flop cards (3)" / "Turn card" / "River card" + `CardGrid`. |
| `sizing(type)` | `pendingActionType != nil` | Context strip + preset chips / keypad (§3). |
| `dealingHero` | `heroCards.count < heroCardCount && ledger.isEmpty && !heroCardsDeferred` | Header "Your cards" + `CardGrid` + a "Later" link that sets the view-local `heroCardsDeferred` flag. |
| `needsVillain` | `villains.isEmpty && ledger.isEmpty` | Text: "Add a villain to start the hand" (no buttons). |
| `acting` | otherwise (`participantToAct != nil`) | Context strip + "UTG (covers) to act" + legal action buttons. |

**Context strip** (present in `acting` and `sizing`): `STREET · board so far · Pot N`. It replaces the separate Board card in the scroll area; the last board card's inline delete (today's `isLastPick` rule) moves onto the strip's last card chip.

**Action buttons** are unchanged in semantics: `Fold · Check|Call N · Bet|Raise · All-in`, from `legalActions`; All-in with unknown stack falls through to the keypad as today. Tap handling and haptics carry over verbatim.

Toolbar (✕, mic, undo), level picker via the narration header, transcript card, ledger tap-to-truncate, the villain remove/edit confirmations, and the close-confirm dialog are all unchanged.

## 2. Card grid

New `CardGrid` (Views/Components/CardGrid.swift): 5 rows × 13 columns — ♠ ♥ ♦ ♣ then an **x** (unknown-suit) row — one tap per card. Row label at the left; ranks A→2 left to right; ♥/♦ cells red; the x row rendered dashed/secondary. Cells are `.frame(maxWidth: .infinity, minHeight: 30)` so 13 fit any supported width.

Disabling rule is today's, unchanged: a real-suit cell is disabled when the card is in `dealtCards`; x cells are never disabled. Callback `onPick(PlayingCard)`; the caller decides caps (hero count, 2 for shown cards, board needs).

`CardGrid` replaces `CardPickerGrid` at every call site — hero cards (now in the bar), board (bar), villain shown cards (scroll editors), showdown rows, and `HandStubSheet` — and `CardPickerGrid.swift` is deleted. One picker in the app.

## 3. Sizing

`SizingPresets` (pure, in a new `StackTrackerPro/Managers/CaptureInput.swift` together with `ChipInput`, `SizingInput`, and `CaptureBarState`, all moved out of the view file):

```swift
static func chips(street: HandStreet, currentBet: Int, minRaiseTotal: Int?, pot: Int, bigBlind: Int)
    -> [(label: String, toAmount: Int)]
```

Spot classification, exhaustive:
- **Unopened preflop** — `street == .preflop && currentBet <= bigBlind` (nobody has raised; limpers don't change it): `2bb · 2.5bb · 3bb · Pot`. Same as today.
- **Facing a bet or raise** — `street == .preflop && currentBet > bigBlind`, or postflop with `currentBet > 0`: `Min · 2.5× · 3× · 4× · Pot`. Multiples are of `currentBet`, as raise-to totals. `Min` = `minRaiseTotal`.
- **Unopened postflop** — postflop with `currentBet == 0`: `⅓ · ½ · ⅔ · Pot · 1.5×` of `pot`, as bet totals. Same as today.
- `Pot` when facing action keeps today's definition: `currentBet + pot`, rounded.
- **Rounding**: unit by big blind — 1 below 20, 5 below 100, 100 below 1,000, 500 below 10,000, else 1,000; nearest multiple, floored at one unit for positive amounts; a non-positive amount rounds to 0 (so zero-pot chips are disabled).
- A chip is disabled when its total `<= currentBet`; when the actor's `jamTotal` is known and the total `>= jamTotal`, the chip is also disabled (Jam covers it).
- `Jam` and `#` chips are always present, as today.

**`minRaiseTotal`** is the one engine addition: a read-only computed property on `HandCaptureModel`, `currentBet + max(lastRaiseIncrement, bigBlind)`, where `lastRaiseIncrement` is the difference between the last aggressive entry's `toAmount` on the current street and the bet level it raised over (preflop base level = `bigBlind`). `nil` when `currentBet == 0`. Pure derivation over the ledger; unit tested (open→min 3-bet, 3-bet→min 4-bet, postflop bet→min raise, and preflop unopened = 2bb).

**Keypad.** `#` swaps the chip row for an inline keypad inside the bar — `1–9 · 0 · k · bb · ⌫` — plus a live readout of the raw text and a confirm button labelled with the resolved total ("Raise to 27,000" / "Bet 12,000" / "All-in 42,500"; disabled while unparseable). Parsing is `SizingInput.parse` unchanged (literal chips, `k`, `m` not offered on the pad, `bb`). `k`/`bb` append as suffix text; ⌫ deletes one character. Cancel returns to the chips. **No `TextField` remains on the capture screen's bar; the system keyboard never appears there.** (The villain editor's approx-stack field and the pot/stack alerts keep their text fields — they're off the hot path.)

## 4. Result-first showdown

`ResultBlock` (moved to `CaptureResultBlock.swift`) when `isHandOver`:

- If `needsShowdown`: a **result row** of prominent buttons — `Hero won`, one `<villain label> won` per non-folded villain, and `Chop` (= the set of all non-folded participants) when 2+ candidates. Selected styling reflects `winnerOverride ?? Set(computedWinners)`.
  - Tap semantics: if the tapped set equals `Set(computedWinners)` (non-empty) → `winnerOverride = nil` (trust computed); otherwise `winnerOverride = tappedSet`.
  - Beneath: a disclosure **"Add shown cards"** revealing today's per-villain `VillainShowdownRow`s (now on `CardGrid`) with their Mucked/Edit affordances. Collapsed by default.
  - The override banner ("Winner overridden…", one-tap clear) now shows **only when `computedWinners` is non-empty and differs from `winnerOverride`** — an override without cards is the normal case, not a warning.
- If not a showdown (everyone folded): no result row; the result line alone, as today.
- The `Override Winner` menu is removed (the row supersedes it). Result line and tags unchanged. Save gating stays on `model.canSave` — with a result tapped, `isResolvable` is already true.

## 5. Collapsed setup

- **Hero** renders as a chip row: `[BTN | Seat?] [A♥K♦ | Cards?] [42,500 ✎]`. Tapping the seat chip toggles the existing `PositionGrid` inline below the row; tapping the cards chip clears `heroCards` (engine already clears stale overrides) and re-enters `dealingHero` on a fresh hand, or shows the grid inline in the Hero section once actions exist (the bar's `dealingHero` state is fresh-hand only — it must not displace a live betting round); the stack chip opens the existing stack alert. The tracker "Use current" hint stays.
- **Villains** keep today's rows (chip + eye + minus) and the existing inline add/edit editor; only the visual weight changes (compact chips, section collapses to one line when empty: `+ Add villain`).
- Text for the chips comes from a pure helper (`CaptureChips.heroChips(model)`), tested.

## 6. Save and dismiss

Save calls `onSaved(hand)` and dismisses immediately. The "Hand saved — Share… / Done" dialog, `showSavedDialog`, `showSavedShare`, and `savedHand` are removed from the capture view. The presenter shows a **toast** (`SavedHandToast`, 4 s, "Hand saved" + `Share` button) — `HandsPane` for all three of its presentations (new / stub / edit), wiring `Share` to its existing `shareHand` sheet. Any other presenter of `HandCaptureView` found during implementation gets the same toast.

## 7. Files

- `StackTrackerPro/Views/Session/HandCaptureView.swift` — composition, toolbar, sheets/dialogs, save. Shrinks substantially.
- `StackTrackerPro/Views/Session/CaptureBottomBar.swift` — bar + states, context strip, action row, sizing chips, keypad.
- `StackTrackerPro/Views/Session/CaptureSetupSections.swift` — hero chips, `PositionGrid`, villain section, `VillainInlineEditor`, `VillainShownCardsEditor`.
- `StackTrackerPro/Views/Session/CaptureResultBlock.swift` — result-first block, `VillainShowdownRow`.
- `StackTrackerPro/Views/Components/CardGrid.swift` (new) — `CardPickerGrid.swift` deleted.
- `StackTrackerPro/Views/Components/SavedHandToast.swift` (new).
- `StackTrackerPro/Managers/CaptureInput.swift` (new) — `ChipInput`, `SizingInput` (moved), `SizingPresets`, `CaptureBarState`, `CaptureChips`.
- `StackTrackerPro/Managers/HandCaptureModel.swift` — `minRaiseTotal` only.
- `project.pbxproj` — hand-wire the new files (4 entries each; IDs continue from `…0139`), remove `CardPickerGrid`.

## 8. Testing & verification

- Engine suite (185) must stay green — it is the regression net for everything the bar drives.
- New unit tests: `SizingPresets.chips` (unopened preflop, facing open, facing 3-bet, unopened postflop, facing postflop bet, disable rules, rounding across the three units); `minRaiseTotal` cases above; `CaptureBarState.derive` priority table (each row, plus `heroCardsDeferred`); `CaptureChips.heroChips` text; result-row tap semantics (computed match clears override; mismatch sets it) via the engine.
- Release gate: `xcodebuild build -configuration Release -destination 'generic/platform=iOS Simulator'`.
- Simulator pass (iPhone Air, `-DemoData -DemoRoute capture`): drive one full hand through all six bar states and result-first save; confirm the system keyboard never appears from the bar; regenerate the marketing screenshot set (capture route).
- Tap-count check on the audit's reference hand: target ≤ 16 (from ~30).

## 9. Out of scope / follow-on tier

One-tap seat-to-add villains; "Check around" / "Fold to hero" macros; single-row position picker; typed-shorthand card entry on the capture screen.

> **STATUS: EXECUTED 2026-09-27** (1.3.0 build 22; suite 212/212, Release clean; cash sessions seed blinds from the stakes string (TestFlight finding); reference hand 19 taps, no keyboard, no scrolling for controls).
