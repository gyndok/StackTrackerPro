# All-In Run-Out Capture + Unknown Suits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** All-in-ness is captured however the user enters a shove (visible button + automatic conversion from raise/bet/call when the stack is known), so the engine's existing run-out kicks in; and `x` becomes a legal unknown suit everywhere cards are entered, with winner detection going manual when x makes showdown evaluation ambiguous.

**Architecture:** `PlayingCard` accepts `x`; `HandCaptureModel` gains input-time all-in conversion, x-aware dedup, and an x-ambiguity guard in `computedWinners` (the existing empty-winners → `winnerOverride`-required mechanism does the rest); the view unhides the All-in action button and the card picker gains a fifth suit. Spec: `docs/superpowers/specs/2026-07-11-allin-runout-and-unknown-suits-design.md`.

**Tech Stack:** Swift/SwiftUI, XCTest. No schema changes, no new files except none.

## Global Constraints

- No schema/CloudKit changes; `x` flows through the existing raw string fields.
- The replay/run-out core (`ReplayEngine`) is NOT restructured — conversion happens at input ingestion (`add(action:toAmount:)`), before the input is appended.
- Release gate mandatory (engine file is WMO-sensitive): `xcodebuild build -configuration Release -destination 'generic/platform=iOS Simulator'`.
- Test command: `xcodebuild test -project StackTrackerPro.xcodeproj -scheme StackTrackerPro -destination 'platform=iOS Simulator,name=iPhone Air,OS=26.5'`. Suite is 157 green at HEAD — keep green plus new tests.
- Test hygiene: XCTUnwrap/guard before indexing; no raw indexing after non-halting asserts.
- Commits direct to `main`, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Verified Interfaces (at HEAD; re-read while coding)

- `PlayingCard` (Models/Hand.swift:6-49): `ranks`/`suits` static arrays, failable `init?(rank:suit:)` validating against them, `init?(_ String)`, `raw`, `suitSymbol`, `display`, `isRed`, `parseList`/`joinList`. Struct is `Equatable, Hashable` — untouched.
- `HandCaptureModel` (Managers/HandCaptureModel.swift): `addCard(_:) -> Bool` (:320, guards `!dealtCards.contains(card)`), `addBoardCard(_:) -> Bool` (:341, same guard), `setShownHolding(_:for:)` (:545), `dealtCards: Set<PlayingCard>` (:447), `add(action:toAmount:)` (:335 — appends `.action(id:actor:type:toAmount)` then `rebuild()`), `participantToAct`, `currentBet`, `currentStreet`, `committedByStreet: [HandStreet: [Participant: Int]]` (per-street TO-amounts, blinds seeded preflop), `heroStackBefore`, `villains: [VillainDraft]` (`approxStack: Int // 0 = unset`), `legalActions` (:422 — already appends `.allIn`), `computedWinners` (:605 — showdown branch guards hold'em/complete cards then calls `PokerHandEvaluator.holdemWinners`; empty result → `isResolvable` false → UI requires `winnerOverride`), `boardCardsNeeded`, `isHandOver`.
- Replay `.allIn` semantics (:975): `committed[street][actor] = amount; curBet = max(curBet, amount); allIn.insert(actor)` — an all-in-for-less (amount < curBet) leaves curBet unchanged. Correct as-is.
- Run-out (:921-947): `startNextStreet`/`resolveAfterAction` already skip betting when `ableToAct().count <= 1`. Not modified — regression-tested.
- `HandCaptureView.swift`: action row filters All-in out (:1101 `ForEach(model.legalActions.filter { $0 != .allIn })`); the action handler has a dead `case .allIn: break` (:1136); `SizingRow` already has `commitJam()`/`jamAmount(for:)` (:1260-1280) that computes a jam total or falls back to the number pad, committing via `onCommit(.allIn, amount)`.
- `CardPickerGrid.swift` (Views/Components): rank rows + one suit row `ForEach(Array("shdc"))`, button disabled when `pendingRank == nil || card == nil || dealt.contains(card!)`, local `suitSymbol(_:)` copy.
- Card colorization: `card.isRed ? .red : .textPrimary` (HandsPane.swift:309, HandCaptureView.swift:771). `HandHistoryFormatter` renders via `card.display`.

---

### Task 1: PlayingCard `x` + dedup rule + ambiguity gate (model level)

**Files:**
- Modify: `StackTrackerPro/Models/Hand.swift` (PlayingCard)
- Modify: `StackTrackerPro/Managers/HandCaptureModel.swift` (addCard/addBoardCard/setShownHolding guards; computedWinners guard)
- Test: `StackTrackerProTests/StackTrackerProTests.swift` (new class `UnknownSuitTests`)

**Interfaces (Produces):** `PlayingCard.unknownSuit: Character = "x"`; `PlayingCard.hasUnknownSuit: Bool`; cards like `PlayingCard("Kx")` valid. Task 3's picker and rendering rely on `suitSymbol == "x"`, `isRed == false`.

- [ ] **Step 1: Failing tests** (add class; adjust helper names to file conventions):

```swift
final class UnknownSuitTests: XCTestCase {

    func testPlayingCardParsesUnknownSuit() throws {
        let card = try XCTUnwrap(PlayingCard("Kx"))
        XCTAssertEqual(card.rank, "K")
        XCTAssertEqual(card.suit, "x")
        XCTAssertTrue(card.hasUnknownSuit)
        XCTAssertEqual(card.raw, "Kx")
        XCTAssertEqual(card.display, "Kx")
        XCTAssertFalse(card.isRed)
        XCTAssertEqual(PlayingCard.parseList("Ac Kx").count, 2)
        XCTAssertNil(PlayingCard("Xx"))          // rank still validated
        XCTAssertNil(PlayingCard(rank: "K", suit: "y"))
    }

    @MainActor func testUnknownSuitCardsAreNeverDuplicates() {
        let model = HandCaptureModel(levelNumber: 5, smallBlind: 100, bigBlind: 200,
                                     ante: 200, heroStack: 20_000)   // match real init
        XCTAssertTrue(model.addCard(PlayingCard("Kx")!))
        XCTAssertTrue(model.addCard(PlayingCard("Kx")!))              // Kx Kx legal
        XCTAssertEqual(model.heroCards.count, 2)
    }

    @MainActor func testUnknownSuitAtShowdownRequiresManualWinner() {
        // Heads-up to showdown with an x in hero's hand: computedWinners must be
        // empty, isResolvable false until winnerOverride, then true.
        let model = makeHeadsUpShowdownModel(heroCards: "Ah Kx", villainShown: "Qs Qd")
        XCTAssertTrue(model.isHandOver)
        XCTAssertTrue(model.computedWinners.isEmpty)
        XCTAssertFalse(model.isResolvable)
        model.winnerOverride = [.hero]
        XCTAssertTrue(model.isResolvable)
    }

    @MainActor func testFoldOutWithUnknownSuitResolvesNormally() {
        // Hero holds Kx, villain folds preflop: no showdown → resolvable as today.
        let model = makeFoldOutModel(heroCards: "Kx Kd")
        XCTAssertTrue(model.isResolvable)
    }
}
```

Build the two `make…Model` helpers on the real `HandCaptureModel` API (setLevel/heroPosition/addCard/addVillain/add(action:)/addBoardCard/setShownHolding) — copy the arrangement style of the existing engine tests in the file; read `HandCaptureModel.init` for the true initializer signature and fix the test's construction accordingly.

- [ ] **Step 2: Run — expect FAIL** (`PlayingCard("Kx")` nil; duplicate rejected; evaluator runs on x).
- [ ] **Step 3: Implement.**
  - `PlayingCard`: add `static let unknownSuit: Character = "x"`; validation accepts it: `guard Self.ranks.contains(rank), Self.suits.contains(suit) || suit == Self.unknownSuit`; `var hasUnknownSuit: Bool { suit == Self.unknownSuit }`; `suitSymbol` returns `"x"` for it (add a case BEFORE the default-clubs case); `isRed` already false for x (leave, but extend its doc comment). `suits` array unchanged.
  - `HandCaptureModel` dedup (all three sites): change the guard to `card.hasUnknownSuit || !dealtCards.contains(card)` (addCard :320, addBoardCard :341); in `setShownHolding` apply the same rule wherever it rejects duplicates (read it — if it currently has no dedup, leave it).
  - `computedWinners` showdown branch: before building `holdings`, add
    ```swift
    // Unknown-suit cards make showdown evaluation ambiguous (flushes
    // unprovable) — never guess; the empty result routes the UI to the
    // manual winnerOverride, same as PLO/incomplete-card showdowns.
    let showdownCards = board + heroCards + villains.flatMap(\.shownHolding)
    guard !showdownCards.contains(where: \.hasUnknownSuit) else { return [] }
    ```
- [ ] **Step 4: Run — expect PASS.** Full suite green (157 + 4).
- [ ] **Step 5: Both configs build. Commit** `feat: unknown-suit (x) cards with manual-winner gating`.

### Task 2: All-in auto-conversion at input ingestion + run-out regression tests

**Files:**
- Modify: `StackTrackerPro/Managers/HandCaptureModel.swift` (`add(action:toAmount:)` + two private helpers)
- Test: `StackTrackerProTests/StackTrackerProTests.swift` (new class `AllInConversionTests`)

**Interfaces (Consumes):** `committedByStreet`, `currentBet`, `currentStreet`, `participantToAct`, `heroStackBefore`, `villains[].approxStack`. **Produces:** converted `.allIn` inputs in the log (Task 3's ledger labels and share text need nothing new).

**Conversion rules (binding, from spec):** For the actor about to act, with `base` = `heroStackBefore` for hero, `approxStack` for a villain when `> 0`, else no conversion:
- `totalCommitted(actor)` = Σ over all streets of `committedByStreet[s][actor]` (includes seeded blinds).
- `remaining` = `base − totalCommitted(actor)`; if `remaining <= 0` treat as no conversion (defensive).
- `.call`: cost = `currentBet − committedThisStreet`; if `cost >= remaining` → record `.allIn` with `toAmount = committedThisStreet + remaining`.
- `.bet`/`.raise` with entered total `t`: chips in = `t − committedThisStreet`; if `chipsIn >= remaining` → record `.allIn` with `toAmount = committedThisStreet + remaining` (cap beyond-stack entries at the stack).
- `.fold`/`.check`/`.allIn` inputs pass through unchanged.

- [ ] **Step 1: Failing tests:**

```swift
final class AllInConversionTests: XCTestCase {

    // THE reported bug: shove entered via Raise, called → board-only run-out.
    @MainActor func testShoveEnteredAsRaiseTriggersRunOut() {
        let model = makeHeadsUpModel(heroStack: 50_000)   // hero BTN, villain UTG w/ approxStack 0
        // villain opens, hero "raises" all their chips, villain calls
        model.add(action: .raise, toAmount: 6_000)         // villain (UTG acts first)
        model.add(action: .raise, toAmount: 50_000)        // hero — full stack: must convert
        XCTAssertTrue(model.allInParticipants.contains(.hero))
        model.add(action: .call, toAmount: 0)              // villain calls
        // Flop: cards owed, nobody to act
        XCTAssertEqual(model.boardCardsNeeded, 3)
        XCTAssertNil(model.participantToAct)
        for c in PlayingCard.parseList("Jh 8h 4d") { model.addBoardCard(c) }
        XCTAssertNil(model.participantToAct)               // no turn betting
        XCTAssertEqual(model.boardCardsNeeded, 1)
        model.addBoardCard(PlayingCard("2c")!)
        XCTAssertNil(model.participantToAct)               // no river betting
        model.addBoardCard(PlayingCard("3s")!)
        XCTAssertTrue(model.isHandOver)
    }

    @MainActor func testCallForYourWholeStackConvertsToAllIn() {
        let model = makeHeadsUpModel(heroStack: 8_000)
        model.add(action: .raise, toAmount: 12_000)        // villain bets more than hero has
        model.add(action: .call, toAmount: 0)              // hero call = all-in for less
        XCTAssertTrue(model.allInParticipants.contains(.hero))
        // curBet must stay 12_000 (all-in for less does not reopen)
        XCTAssertEqual(model.currentBet, 12_000)
    }

    @MainActor func testVillainWithKnownStackConverts() {
        let model = makeHeadsUpModel(heroStack: 100_000, villainApprox: 30_000)
        model.add(action: .raise, toAmount: 30_000)        // villain raises entire stack
        XCTAssertEqual(model.allInParticipants.count, 1)   // villain converted
    }

    @MainActor func testVillainWithUnknownStackDoesNotConvert() {
        let model = makeHeadsUpModel(heroStack: 100_000)   // approxStack 0
        model.add(action: .raise, toAmount: 30_000)
        XCTAssertTrue(model.allInParticipants.isEmpty)
    }

    @MainActor func testMultiwaySidePotKeepsBetting() {
        // 3-handed: short villain jams, two big stacks call → flop betting continues.
        let model = makeThreeWayModel(heroStack: 100_000, v1Approx: 15_000, v2Approx: 90_000)
        model.add(action: .raise, toAmount: 15_000)        // v1 (converted: whole stack)
        model.add(action: .call, toAmount: 0)              // v2
        model.add(action: .call, toAmount: 0)              // hero
        for c in PlayingCard.parseList("Jh 8h 4d") { model.addBoardCard(c) }
        XCTAssertNotNil(model.participantToAct)            // side-pot betting continues
    }
}
```

Helpers again mirror existing engine-test arrangement (read the real init + `allInParticipants` exposure name — grep the model for the public all-in set; if it isn't exposed, assert via ledger labels or add the minimal read-only accessor).

- [ ] **Step 2: Run — expect FAIL** (no conversions today).
- [ ] **Step 3: Implement** in `add(action:toAmount:)` before the append:

```swift
func add(action: HandActionType, toAmount: Int) {
    guard let actor = participantToAct else { return }
    let (type, amount) = convertingToAllInIfNeeded(actor: actor, action: action, toAmount: toAmount)
    inputs.append(.action(id: UUID(), actor, type, amount))
    rebuild()
}

/// Spec 2026-07-11: a call/bet/raise that commits the actor's last chip is
/// recorded as `.allIn` so the engine's run-out logic can see it. Only when
/// the actor's stack is known (hero always; villain when approxStack > 0).
private func convertingToAllInIfNeeded(actor: Participant, action: HandActionType,
                                       toAmount: Int) -> (HandActionType, Int) {
    guard action == .call || action == .bet || action == .raise else { return (action, toAmount) }
    let base: Int
    switch actor {
    case .hero: base = heroStackBefore
    case .villain(let id):
        guard let v = villains.first(where: { $0.id == id }), v.approxStack > 0 else {
            return (action, toAmount)
        }
        base = v.approxStack
    }
    var total = 0
    for (_, streetMap) in committedByStreet { for (_, c) in streetMap { _ = c } }
    // (use the model's existing total-committed helper if one exists — :415 area
    // computes exactly this; reuse it rather than re-summing)
    total = committedByStreet.values.reduce(0) { $0 + ($1[actor] ?? 0) }
    let committedThisStreet = committedByStreet[currentStreet]?[actor] ?? 0
    let remaining = base - total
    guard remaining > 0 else { return (action, toAmount) }
    let chipsIn = (action == .call ? currentBet : toAmount) - committedThisStreet
    guard chipsIn >= remaining else { return (action, toAmount) }
    return (.allIn, committedThisStreet + remaining)
}
```

(The dead-looking loop above is a reminder to REUSE the existing total helper at :415 if it fits — delete whichever branch you don't use; no dead code in the commit.)

- [ ] **Step 4: Run — expect PASS.** Full suite green.
- [ ] **Step 5: Both configs (Release gate matters here — engine file). Commit** `feat: auto-convert stack-committing actions to all-in (run-out fix)`.

### Task 3: UI — All-in button, x in the picker, rendering + closeout

**Files:**
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift`
- Modify: `StackTrackerPro/Views/Components/CardPickerGrid.swift`
- Test: `StackTrackerProTests/StackTrackerProTests.swift` (formatter case)
- Docs: mark spec + plan EXECUTED.

- [ ] **Step 1: Action row.** Remove the `.filter { $0 != .allIn }` (:1101) so All-in renders as the last button. Replace the dead `case .allIn: break` (:1136) with the jam behavior: compute the actor's jam total using the same logic as `SizingRow.jamAmount(for:)` — if known, `model.add(action: .allIn, toAmount: jam)` (plus the same haptic as other commits); if unknown (villain, no approxStack), open the existing number pad flow committing `.allIn` with the typed amount. Read `SizingRow` first; if its jam helpers can be reused without duplication (e.g. move `jamAmount` onto `HandCaptureModel` as `func jamTotal(for participant: Participant) -> Int?`), do that instead of copying the math — one source of truth. If SizingRow retains its own jam affordance, both now route through the same helper.
- [ ] **Step 2: Formatter test** (in the existing `HandHistoryFormatterTests` class):

```swift
func testFormatterRendersUnknownSuitCards() {
    let hand = Hand(heroPosition: .co, heroCardsRaw: "Ac Kx",
                    levelNumber: 3, smallBlind: 200, bigBlind: 400,
                    ante: 400, heroStackChips: 55_000)
    hand.resultRaw = HandResult.folded.rawValue
    let text = HandHistoryFormatter.text(for: hand)
    XCTAssertTrue(text.contains("A♣Kx"))
}
```

Run: expect PASS immediately (display already yields `Kx` after Task 1) — if it fails, fix the formatter, not the test.
- [ ] **Step 3: CardPickerGrid.** Suit row iterates `Array("shdcx")`; the x button label is `"x"` (`.font(.title2)`, `.foregroundColor(.secondary)`); construct via `PlayingCard(rank:suit:)` which now accepts x; disabled rule becomes `pendingRank == nil || card == nil || (!card!.hasUnknownSuit && dealt.contains(card!))` (keep the force-unwraps consistent with the existing line or refactor to `if let` for all — do not mix). Update the local `suitSymbol` copy to return `"x"`.
- [ ] **Step 4: Visual check** in the simulator: build Debug, open capture (demo mode `-DemoData -DemoRoute capture` is fine), verify the action row shows All-in, pick a `Kx` card, confirm neutral styling in hero cards and (via a quick saved-hand share preview) in share text.
- [ ] **Step 5: Full suite + both configs.**
- [ ] **Step 6: Closeout.** STATUS: EXECUTED lines on spec + this plan; commit `feat: all-in action button + unknown-suit picker and rendering`.

## Self-Review

- Spec coverage: fix prongs 1/2/3 → T3 step 1 + T2; run-out semantics locked by T2 regression tests; x rules (parse/display/dedup/manual-winner/fold-out/shorthand-untouched/persistence) → T1 + T3; formatter rendering → T3 step 2. Evaluator untouched ✓ (gate is in computedWinners).
- Placeholders: conversion math fully specified; the one either/or (reuse total helper) states the criterion and forbids dead code.
- Type consistency: `hasUnknownSuit`, `convertingToAllInIfNeeded`, `jamTotal(for:)` names used once each; `.allIn` semantics cited from replay (:975).

> **STATUS: EXECUTED 2026-07-11**
>
> Commits `2149d7f`..`17c2451` (Task 1: `2149d7f` "feat: unknown-suit (x) cards with manual-winner gating"; Task 2: `17c2451` "feat: auto-convert stack-committing actions to all-in (run-out fix)"; Task 3: UI + closeout — see commit that includes this doc update, message `feat: all-in action button + unknown-suit picker and rendering`).
>
> Task 3 work: removed the action row's `.filter { $0 != .allIn }` so All-in renders as the last legal-action button; the jam-total math (previously duplicated in `SizingRow.jamAmount`) was moved onto `HandCaptureModel` as `func jamTotal(for participant:) -> Int?` — the this-street raise-to total (known stack minus prior-streets-committed), `nil` when a villain's `approxStack` is unset — and `convertingToAllInIfNeeded` was refactored to call it (one source of truth, functionally identical conversion math verified by inspection and by the full suite staying green). The action row's All-in tap now calls `model.jamTotal(for:)`: known → `model.add(action: .allIn, toAmount: jam)` + the same light haptic as the row's other commits; unknown (villain, no approxStack) → routes into the existing bet/raise number-pad flow via `pendingActionType = .allIn`, which now commits `.allIn` with the typed total (added an `.allIn` case to `SizingRow`'s confirm-label `verb` switch — "All-in" — while at it). `SizingRow.jamAmount` was replaced with a one-line call to the model helper, which fixes a latent inaccuracy: the old inline version ignored chips already committed on earlier streets when computing the "Jam" chip total. `CardPickerGrid`'s suit row now iterates `"shdcx"`, the `x` button renders `.secondary`-colored `"x"`, and the disabled rule keeps real-card dedup (`dealt.contains`) while never disabling the unknown-suit card (`!card!.hasUnknownSuit && dealt.contains(card!)`).
>
> Also folded in two Minor findings from the Task 2 review: `testMultiwaySidePotKeepsBetting` now additionally asserts the short villain converted (`model.allInParticipants.contains(.villain(v1id))`) and that `participantToAct` after the flop is not that villain (postflop order there is UTG→CO→BTN); and `convertingToAllInIfNeeded`'s doc comment gained a sentence on the deliberate re-edit behavior (a legacy hand whose shove was saved as a plain raise is retroactively re-tagged `.allIn` when reopened for edit, with post-shove filler actions from the old bug silently dropped on replay, pot/winners unchanged).
>
> Verification: added `testFormatterRendersUnknownSuitCards` (passed immediately, no formatter change needed — `PlayingCard.display` already renders `Kx` via Task 1's `suitSymbol`). Full suite 167/167 green (`iPhone Air`, iOS 26.5, Debug) — 166 prior + this one new test. Release build succeeded (`generic/platform=iOS Simulator`, WMO). Visual check: booted the iPhone Air simulator, launched with `-DemoData -DemoRoute capture`, screenshotted, and confirmed the action row shows `Fold / Call 12,000 / Bet/Raise / All-In`. The x-card picker path was not separately screenshotted (tapping isn't scriptable outside XCUITest) — verified instead by the `CardPickerGrid` code being structurally identical to the four real-suit buttons, plus the `UnknownSuitTests` suite exercising the model-level x behavior end to end.
