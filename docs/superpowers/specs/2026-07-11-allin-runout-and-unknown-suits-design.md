# All-In Run-Out Capture + Unknown Suits — Design

**Approved:** 2026-07-11 with user. Two hand-logger refinements from live-play feedback, shipped together.

## Problem 1 — all-in hands keep asking for betting action

The engine's run-out logic already works (`ReplayEngine.startNextStreet` / `resolveAfterAction`: once `ableToAct().count <= 1`, later streets collect board cards only — heads-up and multiway both correct). The failure is upstream: **nothing marks a player all-in unless the `.allIn` action type was used**, and the UI makes that nearly impossible:

- The action row filters All-in out (`HandCaptureView.swift:1101` — `legalActions.filter { $0 != .allIn }`); it is only reachable inside the amount pad.
- A shove entered as "Raise to 390,000" or a call-for-less entered as "Call" leaves `allIn` empty, so betting rounds keep opening — the user's reported bug.

### Fix (three prongs, engine + UI)

1. **All-in becomes a first-class action button.** Whenever betting actions are legal, the row shows Fold · Check/Call · Bet/Raise · All-in (remove the filter; All-in routes through the existing amount flow where an amount is needed, defaulting to the actor's known remaining stack when it is known).
2. **Hero auto-conversion (engine).** In `HandCaptureModel.add(action:toAmount:)` (or inside the replay ingestion, whichever keeps rebuild consistent): when the actor is the hero and the action is call/bet/raise whose total commitment this street ≥ hero's remaining stack (`heroStackBefore` minus all prior-street commitments and blinds paid), record the input as `.allIn` with the correct total. Tapping Raise and typing your whole stack just works.
3. **Villain auto-conversion when stack known (engine).** Same rule for a villain whose `approxStack > 0` (0 = unset, already the engine convention). Unset stacks change nothing — the visible All-in button covers that case.

Auto-conversion is deterministic at input time and stored in the inputs log as `.allIn`, so replay/rebuild, edit round-trip, and the share formatter all see the converted action with no special cases.

### Semantics (binding)

- Betting continues while ≥2 non-folded players have chips behind (side pots — multiway correct).
- The moment ≤1 player has chips behind and the street's action closes, remaining streets are board-card-only; after the river the hand is over (already implemented — covered by a new regression test, not re-built).

## Problem 2 — suits the user didn't see

Allow **`x` as an unknown suit** anywhere a card is entered: hero cards, villain shown cards, board cards. `Ac Kx` is a legal holding.

### Rules (binding)

- `PlayingCard`: `x` becomes a valid suit character for validation/parsing (`PlayingCard("Kx")` succeeds; `parseList`/`joinList`/`raw` round-trip it). The canonical `suits` array used by pickers stays `[s,h,d,c]`; pickers add a fifth "x" option explicitly.
- Display: rank + `x` (e.g. `Kx`) with neutral/dimmed styling — `isRed == false`, `suitSymbol` for `x` is `"x"`. Same rendering in the capture screen, hand detail, share preview, and share text.
- **Duplicates:** an unknown-suit card is never a duplicate of anything (collision unprovable) — `Kx Kx` pocket kings are legal; `Kx` alongside `Ks` is legal. Exact-match duplicate checks in pickers/engine must special-case suit `x`. (`Equatable` on the struct is untouched; the dedup call sites get the rule.)
- **Winner detection goes manual on ambiguity:** if any card among the board + shown hands at resolution carries suit `x`, the engine performs no automatic evaluation — the existing winner override control is **required before Save enables** for that hand. No guessed results. Hands with `x` cards but no showdown resolution (folds) are unaffected.
- Chat/stub shorthand grammar (`AKs` = suited, `AKo` = offsuit) is untouched; `x` participates only in explicit two-character card tokens.
- Persistence: `x` flows through the existing raw string fields (`heroCardsRaw`, `boardRaw`, `shownHolding`) — **zero schema impact**.

## Touch points

- `StackTrackerPro/Models/Hand.swift` — `PlayingCard` (validation, suitSymbol, display, isRed docs).
- `StackTrackerPro/Managers/HandCaptureModel.swift` — auto-conversion at input ingestion; ambiguity flag (`requiresManualWinner`-style computed) driving save gating; dedup rule at `addCard`/`addBoardCard`/`setShownHolding`.
- `StackTrackerPro/Views/Session/HandCaptureView.swift` — action row includes All-in; card pickers gain the x option; winner-required prompt when ambiguous.
- `StackTrackerPro/Managers/HandHistoryFormatter.swift` + `HandSharePreview` — `x` rendering (neutral color in preview; plain `x` in text).
- `PokerHandEvaluator` — untouched (never invoked with x cards; the gate is upstream).

## Constraints

- No schema/CloudKit changes. Engine changes limited to input ingestion + save gating; the replay/run-out core is not restructured.
- Release-config build gate mandatory (engine file is WMO-sensitive).
- Suite stays green (157) plus new tests.

## Out of scope

- Range notation ("AKs", "KK") as card entry; x in the chat shorthand grammar.
- Retroactively editing saved hands' actions into all-ins (edit flow re-enters via the capture screen, which now auto-converts — sufficient).
- Villain stack tracking improvements beyond the existing approxStack field.

## Testing

- **Regression (the reported bug):** heads-up, villain shove entered as plain raise, hero calls with smaller stack → hero auto-converted to all-in → flop/turn/river collect cards only, no `participantToAct`, hand ends after river.
- Multiway side-pot: 3 players, one all-in, two with chips → betting continues on later streets (unchanged behavior locked by test).
- Villain auto-conversion fires only when `approxStack > 0`.
- `PlayingCard` x parsing/round-trip/display; `Kx Kx` accepted by dedup rule; `x` in board.
- Ambiguity gating: showdown with any x card → no auto winner, save requires override; fold-out hands with x cards save normally.
- Formatter renders x hands correctly in text output.
