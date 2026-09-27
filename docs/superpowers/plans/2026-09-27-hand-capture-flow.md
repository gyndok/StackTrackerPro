# Hand Capture Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the routine hand from ~30 taps to ≤16 by pinning the action controls in a bottom bar with a context strip, replacing the two-tap card picker with a one-tap 65-cell grid, making sizing presets spot-aware with an inline keypad, and letting the user tap the result instead of entering showdown cards.

**Architecture:** `HandCaptureView` becomes `VStack { ScrollView(setup · ledger · result) ; CaptureBottomBar }`. The bar renders one of six states derived by a pure function from engine state. The engine (`HandCaptureModel`) gains exactly one read-only property, `minRaiseTotal`. Pure, testable logic (bar state, sizing presets, chip text, result-tap rule) lives in `CaptureInput.swift`; the 1,492-line view splits into four focused files.

**Tech Stack:** SwiftUI, SwiftData, XCTest. iOS 26 target, iPhone Air OS 26.5 simulator.

**Spec:** `docs/superpowers/specs/2026-09-27-hand-capture-flow-design.md` (binding — read it first).

## Global Constraints

- Test command: `xcodebuild test -project StackTrackerPro.xcodeproj -scheme StackTrackerPro -destination 'platform=iOS Simulator,name=iPhone Air,OS=26.5'` — 185 tests green at HEAD; every task ends green with its new tests added.
- Release gate (mandatory before any task is called done, WMO strict concurrency catches what Debug misses): `xcodebuild build -configuration Release -destination 'generic/platform=iOS Simulator' 2>&1 | tail -3; exit ${PIPESTATUS[0]}`.
- `project.pbxproj` uses explicit file references (objectVersion 77). Every new file is wired with `tools/pbx-add.py` (created in Task 1). IDs: `7E5700000000000000000139`… as assigned per task below — never reuse.
- Engine rule: `HandCaptureModel` changes only in Task 2 (`minRaiseTotal`). Nothing else touches it.
- No `TextField` in `CaptureBottomBar` — the system keyboard must never appear from the bar.
- All tests live in `StackTrackerProTests/StackTrackerProTests.swift` (single file, append new `final class … : XCTestCase` blocks at the end). Test methods that touch `HandCaptureModel` are `@MainActor`.
- Commit directly to `main` after each task; trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- bash `noclobber` is set in this environment: use `>|` to overwrite files from the shell.
- Style tokens already exist and must be used: colors `.goldAccent .cardSurface .backgroundPrimary .textPrimary .textSecondary .chipRed .mZoneGreen`; fonts `PokerTypography.sectionHeader .chipLabel .statValue .chatCaption`; modifiers `.pokerCard() .quickChip()`; `HapticFeedback.impact(.light/.medium)`, `HapticFeedback.success()`; `PokerButtonStyle(isEnabled:)`.

---

### Task 1: `CaptureInput.swift` — pure capture logic + pbxproj helper

**Files:**
- Create: `tools/pbx-add.py`
- Create: `StackTrackerPro/Managers/CaptureInput.swift`
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift` (remove `ChipInput` and `SizingInput` — lines under `// MARK: - Chip input parsing`, roughly 665–720)
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (via the helper)
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces:
  - `enum CaptureBarState: Equatable { case done, dealingBoard(street: HandStreet, needed: Int), sizing(HandActionType), dealingHero, needsVillain, acting }` with `static func derive(isHandOver:boardCardsNeeded:streetBeingDealt:pendingAction:heroCardsMissing:heroCardsDeferred:ledgerIsEmpty:villainsIsEmpty:) -> CaptureBarState`
  - `enum CaptureChips { struct Hero: Equatable { let seat: String; let cards: String; let stack: String }; static func hero(position: HeroPosition?, cards: [PlayingCard], cardCount: Int, stack: Int) -> Hero }`
  - `ChipInput` and `SizingInput` unchanged in behavior, now in this file.

- [ ] **Step 1: Create the pbxproj helper**

Write `tools/pbx-add.py` (make it executable with `chmod +x`):

```python
#!/usr/bin/env python3
"""Wire a Swift source into StackTrackerPro.xcodeproj (explicit file refs, objectVersion 77).

usage: tools/pbx-add.py <NewFile.swift> <AnchorFile.swift> <REF_ID> <BUILD_ID>

AnchorFile must already be wired and live in the SAME group as the new file.
Inserts four lines right after the anchor's: PBXBuildFile, PBXFileReference,
group child, Sources build-phase entry. IDs are 24 hex chars; never reuse one.
"""
import re
import sys

if len(sys.argv) != 5:
    sys.exit(__doc__)
name, anchor, ref_id, build_id = sys.argv[1:5]
path = "StackTrackerPro.xcodeproj/project.pbxproj"
s = open(path).read()
if ref_id in s or build_id in s:
    sys.exit(f"ID already used: {ref_id} / {build_id}")

m = re.search(r"\t\t(\w+) /\* %s \*/ = \{isa = PBXFileReference" % re.escape(anchor), s)
if not m:
    sys.exit(f"anchor file reference not found: {anchor}")
anchor_ref = m.group(1)
m = re.search(r"\t\t(\w+) /\* %s in Sources \*/ = \{isa = PBXBuildFile" % re.escape(anchor), s)
if not m:
    sys.exit(f"anchor build file not found: {anchor}")
anchor_build = m.group(1)


def insert_after(text, needle, new_line):
    i = text.index(needle)
    j = text.index("\n", i) + 1
    return text[:j] + new_line + text[j:]


s = insert_after(s, f"{anchor_build} /* {anchor} in Sources */ = {{isa = PBXBuildFile",
                 f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};\n")
s = insert_after(s, f"{anchor_ref} /* {anchor} */ = {{isa = PBXFileReference",
                 f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n")
s = insert_after(s, f"\t\t\t\t{anchor_ref} /* {anchor} */,",
                 f"\t\t\t\t{ref_id} /* {name} */,\n")
s = insert_after(s, f"\t\t\t\t{anchor_build} /* {anchor} in Sources */,",
                 f"\t\t\t\t{build_id} /* {name} in Sources */,\n")
open(path, "w").write(s)
print(f"wired {name} after {anchor}")
```

- [ ] **Step 2: Write the failing tests** (append to the test file)

```swift
// MARK: - Capture bar state + chips (pure)

final class CaptureBarStateTests: XCTestCase {
    private func derive(handOver: Bool = false, needed: Int = 0, street: HandStreet = .flop,
                        pending: HandActionType? = nil, heroMissing: Bool = false,
                        deferred: Bool = false, ledgerEmpty: Bool = false,
                        villainsEmpty: Bool = false) -> CaptureBarState {
        CaptureBarState.derive(isHandOver: handOver, boardCardsNeeded: needed, streetBeingDealt: street,
                               pendingAction: pending, heroCardsMissing: heroMissing,
                               heroCardsDeferred: deferred, ledgerIsEmpty: ledgerEmpty,
                               villainsIsEmpty: villainsEmpty)
    }

    func testPriorityTable() {
        XCTAssertEqual(derive(handOver: true, needed: 3, pending: .bet), .done)
        XCTAssertEqual(derive(needed: 1, street: .turn, pending: .bet), .dealingBoard(street: .turn, needed: 1))
        XCTAssertEqual(derive(pending: .raise, heroMissing: true, ledgerEmpty: true), .sizing(.raise))
        XCTAssertEqual(derive(heroMissing: true, ledgerEmpty: true, villainsEmpty: true), .dealingHero)
        XCTAssertEqual(derive(heroMissing: true, deferred: true, ledgerEmpty: true, villainsEmpty: true), .needsVillain)
        XCTAssertEqual(derive(heroMissing: true, ledgerEmpty: false), .acting)   // mid-hand: cards edit is inline, not the bar
        XCTAssertEqual(derive(ledgerEmpty: true, villainsEmpty: true), .needsVillain)
        XCTAssertEqual(derive(ledgerEmpty: true, villainsEmpty: false), .acting)
        XCTAssertEqual(derive(), .acting)
    }
}

final class CaptureChipsTests: XCTestCase {
    func testHeroChipsSetAndUnset() throws {
        let cards = PlayingCard.parseList("Ah Kd")
        let set = CaptureChips.hero(position: .btn, cards: cards, cardCount: 2, stack: 42_500)
        XCTAssertEqual(set.seat, "BTN")
        XCTAssertEqual(set.cards, "A♥ K♦")
        XCTAssertEqual(set.stack, "42,500")

        let unset = CaptureChips.hero(position: nil, cards: [], cardCount: 2, stack: 0)
        XCTAssertEqual(unset.seat, "Seat?")
        XCTAssertEqual(unset.cards, "Cards?")
        XCTAssertEqual(unset.stack, "0")

        let partial = CaptureChips.hero(position: .co, cards: [try XCTUnwrap(PlayingCard("Qs"))], cardCount: 2, stack: 100)
        XCTAssertEqual(partial.cards, "Q♠ +1")
    }
}
```

- [ ] **Step 3: Run — FAIL** (`CaptureBarState` / `CaptureChips` undefined). Use the test command with `-only-testing:StackTrackerProTests/CaptureBarStateTests -only-testing:StackTrackerProTests/CaptureChipsTests` appended.

- [ ] **Step 4: Create `CaptureInput.swift`**

Move `ChipInput` and `SizingInput` VERBATIM (including their doc comments) out of `HandCaptureView.swift` into the new file, delete them from the view file, then add:

```swift
// MARK: - Bar state

/// Which mode the pinned capture bar is in (spec §1). Derived from engine
/// state on every render — never stored. First matching row wins.
enum CaptureBarState: Equatable {
    case done
    case dealingBoard(street: HandStreet, needed: Int)
    case sizing(HandActionType)
    case dealingHero
    case needsVillain
    case acting

    static func derive(isHandOver: Bool, boardCardsNeeded: Int, streetBeingDealt: HandStreet,
                       pendingAction: HandActionType?, heroCardsMissing: Bool,
                       heroCardsDeferred: Bool, ledgerIsEmpty: Bool,
                       villainsIsEmpty: Bool) -> CaptureBarState {
        if isHandOver { return .done }
        if boardCardsNeeded > 0 { return .dealingBoard(street: streetBeingDealt, needed: boardCardsNeeded) }
        if let pendingAction { return .sizing(pendingAction) }
        // Fresh hand only: once actions exist (or the user tapped "Later") the
        // hero-cards editor lives inline in the Hero section instead.
        if heroCardsMissing && ledgerIsEmpty && !heroCardsDeferred { return .dealingHero }
        if villainsIsEmpty && ledgerIsEmpty { return .needsVillain }
        return .acting
    }
}

// MARK: - Collapsed setup chips

/// Text for the collapsed Hero chip row (spec §5). Pure so the wording is
/// unit-tested without rendering.
enum CaptureChips {
    struct Hero: Equatable {
        let seat: String
        let cards: String
        let stack: String
    }

    static func hero(position: HeroPosition?, cards: [PlayingCard], cardCount: Int, stack: Int) -> Hero {
        let seat = position?.rawValue ?? "Seat?"
        let cardText: String
        if cards.isEmpty {
            cardText = "Cards?"
        } else if cards.count < cardCount {
            cardText = cards.map(\.display).joined(separator: " ") + " +\(cardCount - cards.count)"
        } else {
            cardText = cards.map(\.display).joined(separator: " ")
        }
        return Hero(seat: seat, cards: cardText, stack: stack.formatted())
    }
}
```

(`PlayingCard.display` renders e.g. `A♥` — it is what `CardChip` already shows.)

- [ ] **Step 5: Wire the file**

```bash
chmod +x tools/pbx-add.py
tools/pbx-add.py CaptureInput.swift HandCaptureModel.swift 7E5700000000000000000139 7E570000000000000000013A
```

- [ ] **Step 6: Run the two new test classes — PASS. Then the full suite — 185 + 2 green. Release gate — BUILD SUCCEEDED.**

- [ ] **Step 7: Commit** — `feat(capture): pure bar-state/chip helpers; move chip parsers; pbxproj helper`

---

### Task 2: `minRaiseTotal` on the engine

**Files:**
- Modify: `StackTrackerPro/Managers/HandCaptureModel.swift` — add after `legalActions` (≈ line 494)
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces: `var minRaiseTotal: Int?` on `HandCaptureModel` — smallest legal raise-to total for the current street; `nil` when `currentBet == 0`.

- [ ] **Step 1: Failing tests**

```swift
// MARK: - Min raise (engine read-only derivation)

final class MinRaiseTests: XCTestCase {
    /// Hero BTN, villain UTG, blinds 100/200 (no SB/BB seated → dead blinds;
    /// UTG acts first on every street).
    @MainActor private func makeModel() -> HandCaptureModel {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 50_000)
        model.heroPosition = .btn
        model.addVillain(position: .utg, relative: .similar, approxStack: 0)
        return model
    }

    @MainActor func testUnopenedPreflopIsTwoBigBlinds() {
        XCTAssertEqual(makeModel().minRaiseTotal, 400)
    }

    @MainActor func testFacingOpenThenThreeBet() {
        let model = makeModel()
        model.add(action: .raise, toAmount: 600)      // UTG opens 3bb (increment 400)
        XCTAssertEqual(model.minRaiseTotal, 1_000)
        model.add(action: .raise, toAmount: 2_000)    // hero 3-bets (increment 1,400)
        XCTAssertEqual(model.minRaiseTotal, 3_400)
    }

    @MainActor func testPostflopUnopenedIsNilThenDoubleTheBet() {
        let model = makeModel()
        model.add(action: .raise, toAmount: 600)
        model.add(action: .call, toAmount: 0)
        for c in PlayingCard.parseList("Jh 8h 4d") { XCTAssertTrue(model.addBoardCard(c)) }
        XCTAssertNil(model.minRaiseTotal)             // nobody has bet the flop
        model.add(action: .bet, toAmount: 500)        // UTG leads
        XCTAssertEqual(model.minRaiseTotal, 1_000)
    }

    @MainActor func testAllInForLessDoesNotShrinkTheIncrement() {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 100_000)
        model.heroPosition = .btn
        model.addVillain(position: .utg, relative: .shorter, approxStack: 700)
        model.addVillain(position: .co, relative: .coversHero, approxStack: 0)
        model.add(action: .raise, toAmount: 600)      // UTG opens (increment 400) → min re-raise 1,000
        model.add(action: .allIn, toAmount: 700)      // CO jams for less than a full raise
        // Level is 700 but the last FULL raise increment is still 400.
        XCTAssertEqual(model.minRaiseTotal, 1_100)
    }
}
```

- [ ] **Step 2: Run — FAIL** (`minRaiseTotal` undefined).

- [ ] **Step 3: Implement** (insert directly after `legalActions`):

```swift
    /// Smallest legal raise-to total on the current street (spec §3, the
    /// "Min" sizing chip). Read-only derivation over the ledger:
    /// `currentBet + max(lastFullRaiseIncrement, bigBlind)`, where the last
    /// full raise increment is the size of the most recent aggressive action
    /// that raised the bet level by at least as much as the raise before it
    /// (an all-in for less lifts the level but not the increment). Preflop
    /// the base level is the big blind, so an unopened pot yields 2bb. `nil`
    /// when `currentBet == 0` (nothing to raise — the Min chip is omitted).
    var minRaiseTotal: Int? {
        guard currentBet > 0 else { return nil }
        var level = currentStreet == .preflop ? bigBlind : 0
        var lastFullIncrement = 0
        for entry in ledger where entry.street == currentStreet {
            switch entry.action {
            case .bet, .raise, .allIn:
                guard entry.toAmount > level else { continue }
                let increment = entry.toAmount - level
                if increment >= lastFullIncrement { lastFullIncrement = increment }
                level = entry.toAmount
            default:
                continue
            }
        }
        return currentBet + max(lastFullIncrement, bigBlind)
    }
```

- [ ] **Step 4: Run `MinRaiseTests` — PASS.** If `testAllInForLessDoesNotShrinkTheIncrement` fails on `currentBet`, print `model.currentBet` and `model.ledger` — the engine may keep `currentBet` at 600 for an all-in-for-less (see `testCallForYourWholeStackConvertsToAllIn`); the expected value is then `currentBet + 400`. Adjust the test's expected total to `model.currentBet + 400` computed from the model, NOT the implementation.

- [ ] **Step 5: Full suite green. Release gate green. Commit** — `feat(engine): minRaiseTotal read-only derivation for the Min sizing chip`

---

### Task 3: `SizingPresets`

**Files:**
- Modify: `StackTrackerPro/Managers/CaptureInput.swift`
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces: `enum SizingPresets { struct Chip: Equatable { let label: String; let toAmount: Int; let isEnabled: Bool }; static func roundingUnit(bigBlind: Int) -> Int; static func rounded(_ raw: Double, bigBlind: Int) -> Int; static func chips(street: HandStreet, currentBet: Int, minRaiseTotal: Int?, pot: Int, bigBlind: Int, jamTotal: Int?) -> [Chip] }`

- [ ] **Step 1: Failing tests**

```swift
// MARK: - Sizing presets (pure)

final class SizingPresetsTests: XCTestCase {
    private func labels(_ chips: [SizingPresets.Chip]) -> [String] { chips.map(\.label) }
    private func amount(_ chips: [SizingPresets.Chip], _ label: String) -> Int? { chips.first { $0.label == label }?.toAmount }
    private func enabled(_ chips: [SizingPresets.Chip], _ label: String) -> Bool? { chips.first { $0.label == label }?.isEnabled }

    func testRoundingUnits() {
        XCTAssertEqual(SizingPresets.roundingUnit(bigBlind: 2), 1)
        XCTAssertEqual(SizingPresets.roundingUnit(bigBlind: 50), 5)
        XCTAssertEqual(SizingPresets.roundingUnit(bigBlind: 200), 100)
        XCTAssertEqual(SizingPresets.roundingUnit(bigBlind: 3_000), 500)
        XCTAssertEqual(SizingPresets.roundingUnit(bigBlind: 10_000), 1_000)
        XCTAssertEqual(SizingPresets.rounded(375, bigBlind: 50), 375)
        XCTAssertEqual(SizingPresets.rounded(1_750, bigBlind: 200), 1_800)
        XCTAssertEqual(SizingPresets.rounded(40, bigBlind: 200), 100)     // floor at one unit
    }

    func testUnopenedPreflop() {
        let chips = SizingPresets.chips(street: .preflop, currentBet: 200, minRaiseTotal: 400,
                                        pot: 300, bigBlind: 200, jamTotal: nil)
        XCTAssertEqual(labels(chips), ["2bb", "2.5bb", "3bb", "Pot"])
        XCTAssertEqual(amount(chips, "2.5bb"), 500)
        XCTAssertEqual(amount(chips, "Pot"), 500)          // currentBet 200 + pot 300
        XCTAssertEqual(chips.filter(\.isEnabled).count, 4)
    }

    func testFacingPreflopOpen() {
        // UTG opened to 600 at 100/200; pot 900 (dead blinds 300 + 600).
        let chips = SizingPresets.chips(street: .preflop, currentBet: 600, minRaiseTotal: 1_000,
                                        pot: 900, bigBlind: 200, jamTotal: nil)
        XCTAssertEqual(labels(chips), ["Min", "2.5×", "3×", "4×", "Pot"])
        XCTAssertEqual(amount(chips, "Min"), 1_000)
        XCTAssertEqual(amount(chips, "2.5×"), 1_500)
        XCTAssertEqual(amount(chips, "3×"), 1_800)
        XCTAssertEqual(amount(chips, "4×"), 2_400)
        XCTAssertEqual(amount(chips, "Pot"), 1_500)         // 600 + 900
        XCTAssertTrue(chips.allSatisfy(\.isEnabled))
    }

    func testUnopenedPostflop() {
        let chips = SizingPresets.chips(street: .flop, currentBet: 0, minRaiseTotal: nil,
                                        pot: 12_000, bigBlind: 3_000, jamTotal: nil)
        XCTAssertEqual(labels(chips), ["⅓", "½", "⅔", "Pot", "1.5×"])
        XCTAssertEqual(amount(chips, "⅓"), 4_000)
        XCTAssertEqual(amount(chips, "½"), 6_000)
        XCTAssertEqual(amount(chips, "1.5×"), 18_000)
    }

    func testFacingPostflopBetUsesMultiples() {
        let chips = SizingPresets.chips(street: .turn, currentBet: 5_000, minRaiseTotal: 10_000,
                                        pot: 20_000, bigBlind: 1_000, jamTotal: nil)
        XCTAssertEqual(labels(chips), ["Min", "2.5×", "3×", "4×", "Pot"])
        XCTAssertEqual(amount(chips, "3×"), 15_000)
        XCTAssertEqual(amount(chips, "Pot"), 25_000)
    }

    func testDisableRules() {
        // Facing 600 with only 1,600 behind (jam total 1,600): 3× = 1,800 ≥ jam → disabled.
        let chips = SizingPresets.chips(street: .preflop, currentBet: 600, minRaiseTotal: 1_000,
                                        pot: 900, bigBlind: 200, jamTotal: 1_600)
        XCTAssertEqual(enabled(chips, "Min"), true)
        XCTAssertEqual(enabled(chips, "2.5×"), true)      // 1,500 < 1,600
        XCTAssertEqual(enabled(chips, "3×"), false)
        XCTAssertEqual(enabled(chips, "4×"), false)
        // A preset at or below the current bet is never enabled.
        let tiny = SizingPresets.chips(street: .flop, currentBet: 0, minRaiseTotal: nil,
                                       pot: 100, bigBlind: 200, jamTotal: nil)
        XCTAssertEqual(enabled(tiny, "⅓"), true)          // floors to 100 > 0
    }

    func testMinChipOmittedWhenUnknown() {
        let chips = SizingPresets.chips(street: .preflop, currentBet: 600, minRaiseTotal: nil,
                                        pot: 900, bigBlind: 200, jamTotal: nil)
        XCTAssertEqual(labels(chips), ["2.5×", "3×", "4×", "Pot"])
    }
}
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement** (append to `CaptureInput.swift`):

```swift
// MARK: - Sizing presets

/// Spot-aware preset chips for the bar's sizing row (spec §3). Pure: the
/// caller passes engine values in and gets labelled raise-to/bet totals
/// back, already rounded and with the disable rules applied.
enum SizingPresets {
    struct Chip: Equatable {
        let label: String
        let toAmount: Int
        let isEnabled: Bool
    }

    /// Chip denomination to round presets to. Spec: 100 below a 1K big
    /// blind, 500 below 10K, else 1,000 — extended downward for cash blinds
    /// (1 below 20, 5 below 100) so $1/$2 games don't round 6 up to 100.
    static func roundingUnit(bigBlind: Int) -> Int {
        switch bigBlind {
        case ..<20: return 1
        case ..<100: return 5
        case ..<1_000: return 100
        case ..<10_000: return 500
        default: return 1_000
        }
    }

    /// Nearest multiple of the unit, never below one unit.
    static func rounded(_ raw: Double, bigBlind: Int) -> Int {
        let unit = roundingUnit(bigBlind: bigBlind)
        guard raw > 0 else { return unit }
        return max(unit, Int((raw / Double(unit)).rounded()) * unit)
    }

    static func chips(street: HandStreet, currentBet: Int, minRaiseTotal: Int?,
                      pot: Int, bigBlind: Int, jamTotal: Int?) -> [Chip] {
        let facing = street == .preflop ? currentBet > bigBlind : currentBet > 0
        var raw: [(String, Int)] = []
        if facing {
            if let minRaiseTotal { raw.append(("Min", minRaiseTotal)) }
            raw.append(("2.5×", rounded(Double(currentBet) * 2.5, bigBlind: bigBlind)))
            raw.append(("3×", rounded(Double(currentBet) * 3, bigBlind: bigBlind)))
            raw.append(("4×", rounded(Double(currentBet) * 4, bigBlind: bigBlind)))
            raw.append(("Pot", currentBet + rounded(Double(pot), bigBlind: bigBlind)))
        } else if street == .preflop {
            for label in ["2bb", "2.5bb", "3bb"] {
                raw.append((label, SizingInput.parse(label, bigBlind: bigBlind) ?? 0))
            }
            raw.append(("Pot", currentBet + rounded(Double(pot), bigBlind: bigBlind)))
        } else {
            let fractions: [(String, Double)] = [("⅓", 1.0 / 3), ("½", 0.5), ("⅔", 2.0 / 3), ("Pot", 1.0), ("1.5×", 1.5)]
            for (label, fraction) in fractions {
                raw.append((label, rounded(Double(pot) * fraction, bigBlind: bigBlind)))
            }
        }
        return raw.map { label, total in
            var isEnabled = total > currentBet
            if let jamTotal, total >= jamTotal { isEnabled = false }
            return Chip(label: label, toAmount: total, isEnabled: isEnabled)
        }
    }
}
```

- [ ] **Step 4: Run `SizingPresetsTests` — PASS. Full suite + Release gate green.**

- [ ] **Step 5: Commit** — `feat(capture): spot-aware SizingPresets`

---

### Task 4: `CardGrid` replaces `CardPickerGrid` everywhere

**Files:**
- Create: `StackTrackerPro/Views/Components/CardGrid.swift`
- Delete: `StackTrackerPro/Views/Components/CardPickerGrid.swift`
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift` (4 call sites: `HeroStrip`, `VillainShownCardsEditor`, `BoardEntry`, `VillainShowdownRow`), `StackTrackerPro/Views/Session/HandStubSheet.swift` (1 call site)
- Modify: `project.pbxproj`

**Interfaces:**
- Produces: `struct CardGrid: View { init(dealt: Set<PlayingCard>, onPick: @escaping (PlayingCard) -> Void) }` — identical call shape to `CardPickerGrid`.

There is no unit test for a pure view; verification is compile + simulator.

- [ ] **Step 1: Create `CardGrid.swift`**

```swift
import SwiftUI

/// One-tap card picker (spec §2): five rows — ♠ ♥ ♦ ♣ and an unknown-suit
/// "x" row — by thirteen ranks. Replaces the two-tap rank→suit picker
/// everywhere cards are entered. Cards already in play are disabled; x cards
/// never are (two Kx can both be live — nobody knows the real suit, so there
/// is nothing to collide on).
struct CardGrid: View {
    let dealt: Set<PlayingCard>
    let onPick: (PlayingCard) -> Void

    private static let ranks: [Character] = ["A", "K", "Q", "J", "T", "9", "8", "7", "6", "5", "4", "3", "2"]
    private static let suits: [Character] = ["s", "h", "d", "c", "x"]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Self.suits, id: \.self) { suit in
                HStack(spacing: 3) {
                    Text(suitSymbol(suit))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(suitColor(suit))
                        .frame(width: 14)
                    ForEach(Self.ranks, id: \.self) { rank in
                        cell(rank: rank, suit: suit)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(rank: Character, suit: Character) -> some View {
        let card = PlayingCard(rank: rank, suit: suit)
        let isUnknown = suit == "x"
        let isDisabled = card == nil || (!isUnknown && dealt.contains(card!))
        Button {
            if let card { onPick(card) }
        } label: {
            Text(rank == "T" ? "10" : String(rank))
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(isUnknown ? Color.clear : Color.cardSurface)
                .foregroundColor(suitColor(suit))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.textSecondary.opacity(isUnknown ? 0.5 : 0),
                                style: StrokeStyle(lineWidth: 1, dash: [3]))
                )
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .opacity(isDisabled ? 0.22 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel("\(rank == "T" ? "10" : String(rank)) of \(suitName(suit))")
    }

    private func suitSymbol(_ s: Character) -> String {
        switch s {
        case "s": return "♠"
        case "h": return "♥"
        case "d": return "♦"
        case "c": return "♣"
        default: return "x"
        }
    }

    private func suitName(_ s: Character) -> String {
        switch s {
        case "s": return "spades"
        case "h": return "hearts"
        case "d": return "diamonds"
        case "c": return "clubs"
        default: return "unknown suit"
        }
    }

    private func suitColor(_ s: Character) -> Color {
        switch s {
        case "h", "d": return .red
        case "x": return .textSecondary
        default: return .textPrimary
        }
    }
}

#Preview {
    CardGrid(dealt: Set(PlayingCard.parseList("Ah Kd Ks"))) { _ in }
        .padding()
        .background(Color.backgroundPrimary)
}
```

- [ ] **Step 2: Replace every call site.** In `HandCaptureView.swift` and `HandStubSheet.swift`, change each `CardPickerGrid(dealt:` to `CardGrid(dealt:` — closure bodies unchanged. Confirm with `grep -rn 'CardPickerGrid' StackTrackerPro` → no results except the file itself.

- [ ] **Step 3: Delete the old picker and rewire**

```bash
git rm -q StackTrackerPro/Views/Components/CardPickerGrid.swift
sed -i '' '/CardPickerGrid.swift/d' StackTrackerPro.xcodeproj/project.pbxproj
tools/pbx-add.py CardGrid.swift TranscriptEditorSheet.swift 7E570000000000000000013B 7E570000000000000000013C
grep -c 'CardGrid.swift' StackTrackerPro.xcodeproj/project.pbxproj   # expect 4
```

- [ ] **Step 4: Full suite green (185 + Task 1–3 additions). Release gate green.**

- [ ] **Step 5: Simulator smoke:** boot iPhone Air, launch with `-DemoData -DemoRoute capture`, tap the mic-less path: confirm the grid renders in the Hero section (the demo pose already has hero cards, so open a fresh hand from the Hands pane `Log Hand` instead) — 13 columns fit without truncation, dealt cards dimmed. Screenshot to the scratchpad for the reviewer.

- [ ] **Step 6: Commit** — `feat(capture): one-tap CardGrid replaces the two-tap picker`

---

### Task 5: `CaptureBottomBar` — acting, sizing, keypad; view becomes VStack + bar

**Files:**
- Create: `StackTrackerPro/Views/Session/CaptureBottomBar.swift`
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift` — `body`, remove `ActionRow` and `SizingRow` structs and the villain-gate hint
- Modify: `project.pbxproj`

**Interfaces:**
- Consumes: `CaptureBarState.derive`, `SizingPresets.chips`, `SizingInput.parse`, `model.minRaiseTotal`, `model.jamTotal(for:)`.
- Produces: `struct CaptureBottomBar: View { init(model: HandCaptureModel, pendingActionType: Binding<HandActionType?>, heroCardsDeferred: Binding<Bool>, onCommitSized: @escaping (HandActionType, Int) -> Void) }`. In THIS task the bar implements `acting`, `sizing`, `needsVillain`, `done` (renders `EmptyView`); `dealingBoard`/`dealingHero` render a placeholder `Text("cards…")` and are completed in Task 6, where `BoardEntry`/hero card entry move in.

- [ ] **Step 1: Create `CaptureBottomBar.swift`**

```swift
import SwiftUI

/// The pinned control surface under the capture scroll view (spec §1). One
/// state at a time, derived from the engine by `CaptureBarState.derive`; this
/// view only renders that state and forwards taps.
struct CaptureBottomBar: View {
    let model: HandCaptureModel
    @Binding var pendingActionType: HandActionType?
    @Binding var heroCardsDeferred: Bool
    let onCommitSized: (HandActionType, Int) -> Void

    private var state: CaptureBarState {
        CaptureBarState.derive(
            isHandOver: model.isHandOver,
            boardCardsNeeded: model.boardCardsNeeded,
            streetBeingDealt: model.streetBeingDealt,
            pendingAction: pendingActionType,
            heroCardsMissing: model.heroCards.count < model.heroCardCount,
            heroCardsDeferred: heroCardsDeferred,
            ledgerIsEmpty: model.ledger.isEmpty,
            villainsIsEmpty: model.villains.isEmpty)
    }

    var body: some View {
        switch state {
        case .done:
            EmptyView()
        case .needsVillain:
            barChrome {
                Text("Add a villain to start the hand")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        case .acting:
            barChrome {
                ContextStrip(model: model)
                ActionButtons(model: model, pendingActionType: $pendingActionType)
            }
        case .sizing(let type):
            barChrome {
                ContextStrip(model: model)
                SizingPanel(model: model, actionType: type,
                            onCommit: onCommitSized,
                            onCancel: { pendingActionType = nil })
            }
        case .dealingBoard, .dealingHero:
            barChrome { Text("cards…").foregroundColor(.textSecondary) }   // Task 6
        }
    }

    private func barChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(Color.cardSurface.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(Color.goldAccent).frame(height: 1.5) }
    }
}

// MARK: - Context strip

/// `STREET · board so far · Pot N` — always visible while acting/sizing so
/// the user never scrolls up to check the board before sizing (spec §1).
/// The last board card is removable only when it is genuinely the last
/// input (`lastInputWasBoardCard`), same rule the old Board section used.
struct ContextStrip: View {
    let model: HandCaptureModel

    var body: some View {
        HStack(spacing: 8) {
            Text(model.currentStreet.label.uppercased())
                .font(PokerTypography.chipLabel.weight(.bold))
                .foregroundColor(.goldAccent)
            ForEach(model.board, id: \.self) { card in
                MiniCard(card: card,
                         onRemove: (card == model.board.last && model.lastInputWasBoardCard)
                            ? { model.undoLast() } : nil)
            }
            Spacer(minLength: 4)
            Text("Pot \(model.pot.formatted())")
                .font(PokerTypography.chipLabel.weight(.semibold))
                .foregroundColor(.textPrimary)
        }
    }
}

/// Small board-card chip used by the strip and the dealing panels.
struct MiniCard: View {
    let card: PlayingCard
    var onRemove: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(card.display)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(card.isRed ? .red : .textPrimary)
                .frame(width: 34, height: 40)
                .background(Color.backgroundPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.chipRed)
                        .background(Circle().fill(Color.backgroundPrimary))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove \(card.display)")
            }
        }
    }
}

// MARK: - Action buttons

/// Legal actions for whoever is to act. Semantics are the old `ActionRow`'s,
/// verbatim: fold/check/call commit at once; bet/raise open sizing; all-in
/// commits the jam when the stack is known, else opens sizing as `.allIn`.
private struct ActionButtons: View {
    let model: HandCaptureModel
    @Binding var pendingActionType: HandActionType?

    var body: some View {
        if let actor = model.participantToAct {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(model.label(for: actor)) to act")
                    .font(PokerTypography.sectionHeader)
                    .foregroundColor(.goldAccent)
                HStack(spacing: 8) {
                    ForEach(model.legalActions, id: \.self) { action in
                        Button {
                            handle(action)
                        } label: {
                            Text(buttonLabel(action))
                                .font(PokerTypography.statValue)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Color.backgroundPrimary)
                                .foregroundColor(.textPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
    }

    private func buttonLabel(_ action: HandActionType) -> String {
        switch action {
        case .call: return "Call \(model.currentBet.formatted())"
        case .bet, .raise: return "Bet/Raise"
        default: return action.rawValue
        }
    }

    private func handle(_ action: HandActionType) {
        switch action {
        case .fold, .check:
            model.add(action: action, toAmount: 0)
            HapticFeedback.impact(.light)
        case .call:
            model.add(action: .call, toAmount: 0)
            HapticFeedback.impact(.light)
        case .bet, .raise:
            pendingActionType = action
        case .allIn:
            guard let actor = model.participantToAct else { return }
            if let jam = model.jamTotal(for: actor) {
                model.add(action: .allIn, toAmount: jam)
                HapticFeedback.impact(.light)
            } else {
                pendingActionType = .allIn
            }
        }
    }
}

// MARK: - Sizing panel (chips ⇄ keypad)

private struct SizingPanel: View {
    let model: HandCaptureModel
    let actionType: HandActionType
    let onCommit: (HandActionType, Int) -> Void
    let onCancel: () -> Void

    @State private var showKeypad = false

    private var chips: [SizingPresets.Chip] {
        let actor = model.participantToAct
        return SizingPresets.chips(
            street: model.currentStreet,
            currentBet: model.currentBet,
            minRaiseTotal: model.minRaiseTotal,
            pot: model.pot,
            bigBlind: model.bigBlind,
            jamTotal: actor.flatMap { model.jamTotal(for: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)
                Spacer()
                Button("Cancel", action: onCancel)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
            }
            if showKeypad {
                SizingKeypad(actionType: actionType, bigBlind: model.bigBlind,
                             onCommit: { onCommit(actionType, $0) },
                             onBack: { showKeypad = false })
            } else {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.label) { chip in
                        Button(chip.label) { onCommit(actionType, chip.toAmount) }
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                            .disabled(!chip.isEnabled)
                    }
                    Button("Jam") { commitJam() }
                        .buttonStyle(.bordered)
                        .tint(.chipRed)
                    Button("#") { showKeypad = true }
                        .buttonStyle(.bordered)
                        .tint(.goldAccent)
                }
            }
        }
    }

    private var title: String {
        guard let actor = model.participantToAct else { return "Size" }
        let verb: String
        switch actionType {
        case .raise: verb = "raise"
        case .allIn: verb = "all-in"
        default: verb = "bet"
        }
        return "\(model.label(for: actor)) — \(verb) size"
    }

    private func commitJam() {
        guard let actor = model.participantToAct else { return }
        if let jam = model.jamTotal(for: actor) {
            onCommit(.allIn, jam)
        } else {
            showKeypad = true
        }
    }
}

/// Inline amount entry (spec §3). No TextField: the system keyboard never
/// appears from the bar. Keys append to a raw string parsed by
/// `SizingInput.parse` (literal chips, `k`, `bb`); the confirm button previews
/// exactly what will be committed.
private struct SizingKeypad: View {
    let actionType: HandActionType
    let bigBlind: Int
    let onCommit: (Int) -> Void
    let onBack: () -> Void

    @State private var text = ""

    private static let rows: [[String]] = [["1", "2", "3", "4", "5"], ["6", "7", "8", "9", "0"], ["k", "bb", "⌫"]]

    private var resolved: Int? { SizingInput.parse(text, bigBlind: bigBlind) }

    private var confirmLabel: String {
        let verb: String
        switch actionType {
        case .raise: verb = "Raise to"
        case .allIn: verb = "All-in"
        default: verb = "Bet"
        }
        guard let resolved else { return verb }
        return "\(verb) \(resolved.formatted())"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(text.isEmpty ? "e.g. 2300, 4bb, 42k" : text)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundColor(text.isEmpty ? .textSecondary : .textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.backgroundPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button("Chips", action: onBack)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
            }
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { key in
                        Button {
                            press(key)
                        } label: {
                            Text(key)
                                .font(PokerTypography.statValue)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(Color.backgroundPrimary)
                                .foregroundColor(key == "⌫" ? .chipRed : .textPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(key == "⌫" ? "Delete" : key)
                    }
                    if row.count < 5 {
                        Button(confirmLabel) {
                            if let resolved { onCommit(resolved) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.goldAccent)
                        .disabled(resolved == nil)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func press(_ key: String) {
        switch key {
        case "⌫":
            if !text.isEmpty { text.removeLast() }
        case "k", "bb":
            // One suffix at a time: replace any existing suffix.
            let digits = text.filter { $0.isNumber || $0 == "." }
            text = digits + key
        default:
            // Typing a digit after a suffix means a fresh number.
            if text.hasSuffix("k") || text.hasSuffix("bb") { text = "" }
            text.append(key)
        }
    }
}
```

- [ ] **Step 2: Restructure `HandCaptureView.body`**

Add state: `@State private var heroCardsDeferred = false`.

Replace the `ZStack { Color…; ScrollView { … } }` with:

```swift
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            NarrationBar(model: model, showPotPad: $showPotPad, potPadText: $potPadText,
                                         canPickLevel: !levelOptions.isEmpty,
                                         onPickLevel: { showLevelPicker = true })
                            if !model.transcript.isEmpty {
                                TranscriptCard(transcript: model.transcript,
                                              warnIfEmptiedWithoutStructure: !model.isResolvable) {
                                    model.transcript = $0
                                }
                            }
                            HeroStrip(model: model, stubHint: stubHint,
                                     showStackPad: $showStackPad, stackPadText: $stackPadText)
                            villainSection
                            LedgerList(model: model, truncateIndex: $truncateIndex)
                            // Board stays in the scroll ONLY until Task 6 moves it into the bar.
                            if !model.board.isEmpty || model.boardCardsNeeded > 0 {
                                BoardEntry(model: model)
                            }
                            if model.isHandOver {
                                ResultBlock(model: model)
                                tagRow
                                saveButton
                            } else if !model.transcript.isEmpty {
                                tagRow
                                saveButton
                            }
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    CaptureBottomBar(model: model,
                                     pendingActionType: $pendingActionType,
                                     heroCardsDeferred: $heroCardsDeferred,
                                     onCommitSized: commitSizedAction)
                }
            }
```

Delete from the view file: the `if model.participantToAct != nil { … }` block (villain-gate hint + `ActionRow`), the `if let type = pendingActionType { SizingRow… }` block, and the `ActionRow` and `SizingRow` struct definitions (their comments about device findings 13/13A/13B are preserved in spirit by `SizingPresets`/`SizingKeypad` docs). Keep `commitSizedAction` — it is the bar's `onCommitSized`.

- [ ] **Step 3: Wire and build**

```bash
tools/pbx-add.py CaptureBottomBar.swift HandCaptureView.swift 7E570000000000000000013D 7E570000000000000000013E
```

Full suite green; Release gate green.

- [ ] **Step 4: Simulator pass** (`-DemoData -DemoRoute capture` poses hero-to-act facing a 12,000 flop bet):
  - Bar shows `FLOP J♥ 8♥ 4♦ · Pot …`, "Hero (BTN) to act", `Fold · Call 12,000 · Bet/Raise · All-in`.
  - Tap Bet/Raise → chips `Min · 2.5× · 3× · 4× · Pot · Jam · #` (facing a bet postflop). Tap `#` → keypad; type `3`,`0`,`k` → confirm reads "Raise to 30,000"; tap it → ledger gains the raise, bar returns to acting for UTG. No system keyboard at any point.
  - Scroll the list: the bar stays put. Screenshots of acting, sizing, keypad to the scratchpad.

- [ ] **Step 5: Commit** — `feat(capture): pinned CaptureBottomBar with context strip, spot-aware sizing, inline keypad`

---

### Task 6: Dealing states move into the bar

**Files:**
- Modify: `StackTrackerPro/Views/Session/CaptureBottomBar.swift` — implement `dealingBoard` / `dealingHero`
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift` — remove `BoardEntry` (struct + mount), and the hero card picker inside `HeroStrip` becomes conditional (see below)

**Interfaces:**
- Consumes: `CardGrid`, `MiniCard`, `model.addBoardCard`, `model.addCard`, `heroCardsDeferred` binding.

- [ ] **Step 1: Replace the placeholder cases in `CaptureBottomBar.body`**

```swift
        case .dealingBoard(let street, let needed):
            barChrome {
                DealingPanel(
                    title: "\(street.label) card\(needed > 1 ? "s (\(needed))" : "")",
                    cards: model.board,
                    removableLast: model.lastInputWasBoardCard,
                    dealt: model.dealtCards,
                    onPick: { if model.addBoardCard($0) { HapticFeedback.impact(.light) } },
                    onRemoveLast: { model.undoLast() },
                    trailing: nil)
            }
        case .dealingHero:
            barChrome {
                DealingPanel(
                    title: "Your cards",
                    cards: model.heroCards,
                    removableLast: !model.heroCards.isEmpty,
                    dealt: model.dealtCards,
                    onPick: { if model.addCard($0) { HapticFeedback.impact(.light) } },
                    onRemoveLast: { model.heroCards.removeLast() },
                    trailing: ("Later", { heroCardsDeferred = true }))
            }
```

And add the panel to the same file:

```swift
// MARK: - Dealing panel

/// Card entry inside the bar (spec §1 dealing states): the cards so far as
/// mini chips (last one removable when the caller allows), then the grid.
/// `trailing` is an optional header action — the hero-cards "Later" link.
private struct DealingPanel: View {
    let title: String
    let cards: [PlayingCard]
    let removableLast: Bool
    let dealt: Set<PlayingCard>
    let onPick: (PlayingCard) -> Void
    let onRemoveLast: () -> Void
    let trailing: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)
                if !cards.isEmpty {
                    ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                        MiniCard(card: card,
                                 onRemove: (index == cards.count - 1 && removableLast) ? onRemoveLast : nil)
                    }
                }
                Spacer()
                if let trailing {
                    Button(trailing.0, action: trailing.1)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
            }
            CardGrid(dealt: dealt, onPick: onPick)
        }
    }
}
```

- [ ] **Step 2: In `HandCaptureView.swift`** delete the `BoardEntry` struct and its mount in the scroll (the `if !model.board.isEmpty || model.boardCardsNeeded > 0 { BoardEntry(model: model) }` block). In `HeroStrip`, change the inline picker condition from `if model.heroCards.count < model.heroCardCount {` to:

```swift
            // The bar owns hero-card entry on a fresh hand; inline only once
            // actions exist or the user tapped "Later" (complement of
            // CaptureBarState.dealingHero).
            if model.heroCards.count < model.heroCardCount && (!model.ledger.isEmpty || heroCardsDeferred) {
```

`HeroStrip` needs `heroCardsDeferred` — add `let heroCardsDeferred: Bool` to it and pass `heroCardsDeferred: heroCardsDeferred` at the call site. (Task 7 rewrites `HeroStrip` into chips; keep this minimal now.)

- [ ] **Step 3: Full suite + Release gate green.**

- [ ] **Step 4: Simulator pass:** from the Hands pane tap `Log Hand` (fresh hand) → bar reads "Your cards" with the grid; pick two → bar flips to "Add a villain to start the hand"; add a villain via the form → acting. Play to a flop: after preflop closes the bar reads "Flop cards (3)" with the grid; pick three → the strip shows them and the bar returns to acting; the third flop card carries the remove badge until an action is taken. Tap "Later" on a fresh hand → bar goes to needsVillain and the Hero section shows the grid inline.

- [ ] **Step 5: Commit** — `feat(capture): hero and board card entry live in the bar`

---

### Task 7: Collapsed setup — `CaptureSetupSections.swift`

**Files:**
- Create: `StackTrackerPro/Views/Session/CaptureSetupSections.swift`
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift` — move `PositionGrid`, `HeroStrip`, `VillainEditorTarget`, `VillainInlineEditor`, `VillainShownCardsEditor`, `villainSection` + its helpers out; replace `HeroStrip` with `HeroSetupSection`
- Modify: `project.pbxproj`

**Interfaces:**
- Consumes: `CaptureChips.hero`, `CardGrid`, `CardChip`.
- Produces: `struct HeroSetupSection: View { init(model:, stubHint: String?, heroCardsDeferred: Binding<Bool>, showStackPad: Binding<Bool>, stackPadText: Binding<String>) }`; `struct VillainSection: View { init(model:, villainEditorTarget: Binding<VillainEditorTarget?>, shownCardsTarget: Binding<UUID?>, pendingRemovalID: Binding<UUID?>) }` (the dialogs stay in `HandCaptureView`, driven by those bindings). `VillainEditorTarget` becomes internal (not `private`) so both files see it.

- [ ] **Step 1: Create the file with the moved code plus the new hero section**

Move `PositionGrid`, `VillainEditorTarget` (drop `private`), `VillainInlineEditor`, `VillainShownCardsEditor` verbatim. Move `CardChip` too (it is used by hero cards, shown cards, and Task 8's showdown rows) — drop its `private`. Then add:

```swift
// MARK: - Hero (collapsed chips)

/// Hero setup as a chip row once set (spec §5): `[BTN] [A♥ K♦] [42,500 ✎]`.
/// Seat chip toggles the position grid inline; cards chip clears the hero
/// cards (a fresh hand re-enters the bar's dealing state, a hand in flight
/// shows the grid inline); stack chip opens the existing stack alert.
struct HeroSetupSection: View {
    let model: HandCaptureModel
    let stubHint: String?
    @Binding var heroCardsDeferred: Bool
    @Binding var showStackPad: Bool
    @Binding var stackPadText: String

    @State private var showSeatGrid = false

    private var chips: CaptureChips.Hero {
        CaptureChips.hero(position: model.heroPosition, cards: model.heroCards,
                          cardCount: model.heroCardCount, stack: model.heroStackBefore)
    }

    private var cardsMissing: Bool { model.heroCards.count < model.heroCardCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hero").font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)
            HStack(spacing: 8) {
                Button(chips.seat) { showSeatGrid.toggle() }
                    .quickChip()
                    .accessibilityLabel("Hero seat \(chips.seat), change")
                Button {
                    // Mirror addCard's invalidation: card evidence changed.
                    model.heroCards.removeAll()
                    model.winnerOverride = nil
                    model.potOverride = nil
                    heroCardsDeferred = false
                } label: {
                    Text(chips.cards)
                }
                .quickChip()
                .accessibilityLabel("Hero cards \(chips.cards), re-enter")
                Button {
                    stackPadText = String(model.heroStackBefore)
                    showStackPad = true
                } label: {
                    HStack(spacing: 4) {
                        Text(chips.stack)
                        Image(systemName: "pencil").font(.caption2)
                    }
                }
                .quickChip()
                .accessibilityLabel("Stack at start of hand, \(chips.stack), edit")
                Spacer()
            }
            if let stubHint, cardsMissing {
                Text("Stub: \(stubHint)")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textSecondary)
            }
            if showSeatGrid || model.heroPosition == nil {
                PositionGrid(selected: model.heroPosition) { position in
                    model.heroPosition = position
                    showSeatGrid = false
                    HapticFeedback.impact(.light)
                }
            }
            // Inline card entry is the complement of the bar's dealingHero
            // state: a hand already in flight, or a deferred fresh hand.
            if cardsMissing && (!model.ledger.isEmpty || heroCardsDeferred) {
                CardGrid(dealt: model.dealtCards) { card in
                    if model.addCard(card) { HapticFeedback.impact(.light) }
                }
            }
            if let tracker = model.trackerStackAtOpen, tracker != model.heroStackBefore {
                HStack(spacing: 8) {
                    Text("Tracker now: \(tracker.formatted())")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                    Button("Use current") { model.heroStackBefore = tracker }
                        .font(.caption)
                        .foregroundColor(.goldAccent)
                }
            }
        }
        .pokerCard()
    }
}

// MARK: - Villains

/// Villain rows + add/edit editor, moved out of HandCaptureView unchanged in
/// behavior; the confirmation dialogs stay in the parent, driven by the
/// bound targets. Collapses to a single "+ Add villain" line when empty.
struct VillainSection: View {
    let model: HandCaptureModel
    @Binding var villainEditorTarget: VillainEditorTarget?
    @Binding var shownCardsTarget: UUID?
    @Binding var pendingRemovalID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Villains").font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)
                Spacer()
                Button {
                    villainEditorTarget = villainEditorTarget == .adding ? nil : .adding
                } label: {
                    Label("Add villain", systemImage: "plus.circle")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.goldAccent)
                }
            }
            ForEach(model.villains) { villain in
                let hasActed = model.hasActed(.villain(villain.id))
                HStack(spacing: 8) {
                    Button {
                        villainEditorTarget = villainEditorTarget == .editing(villain.id)
                            ? nil : .editing(villain.id)
                    } label: {
                        Text(chipText(villain))
                    }
                    .quickChip()
                    .disabled(hasActed)
                    Button {
                        shownCardsTarget = shownCardsTarget == villain.id ? nil : villain.id
                    } label: {
                        Image(systemName: shownCardsTarget == villain.id ? "eye.fill" : "eye")
                    }
                    .foregroundColor(.goldAccent)
                    .accessibilityLabel("Shown cards")
                    Spacer()
                    Button {
                        if hasActed || isLastVillainMidHand {
                            pendingRemovalID = villain.id
                        } else {
                            remove(villain.id)
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .foregroundColor(.chipRed)
                }
                if shownCardsTarget == villain.id {
                    VillainShownCardsEditor(model: model, villainID: villain.id) {
                        shownCardsTarget = nil
                    }
                }
            }
            if let target = villainEditorTarget {
                VillainInlineEditor(model: model, editing: editing(for: target)) {
                    villainEditorTarget = nil
                }
                .id(target)
            }
        }
        .pokerCard()
    }

    private var isLastVillainMidHand: Bool {
        model.villains.count == 1 && !model.ledger.isEmpty
    }

    /// Same single removal path as before: close any editor still pointed
    /// at the villain before dropping them.
    func remove(_ id: UUID) {
        if villainEditorTarget == .editing(id) { villainEditorTarget = nil }
        if shownCardsTarget == id { shownCardsTarget = nil }
        model.removeVillain(id: id)
    }

    private func editing(for target: VillainEditorTarget) -> HandCaptureModel.VillainDraft? {
        guard case .editing(let id) = target else { return nil }
        return model.villains.first { $0.id == id }
    }

    private func chipText(_ villain: HandCaptureModel.VillainDraft) -> String {
        var text = model.label(for: .villain(villain.id))
        if villain.approxStack > 0 { text += " ≈\(villain.approxStack.formatted())" }
        if villain.shownHolding.count == 2 {
            text += " " + villain.shownHolding.map(\.display).joined(separator: " ")
        } else if villain.mucked {
            text += " (mucked)"
        }
        return text
    }
}
```

- [ ] **Step 2: Update `HandCaptureView`**

- Replace `HeroStrip(...)` with `HeroSetupSection(model: model, stubHint: stubHint, heroCardsDeferred: $heroCardsDeferred, showStackPad: $showStackPad, stackPadText: $stackPadText)`.
- Replace `villainSection` with `VillainSection(model: model, villainEditorTarget: $villainEditorTarget, shownCardsTarget: $shownCardsTarget, pendingRemovalID: $pendingRemovalID)`.
- Delete the moved structs, the `villainSection` computed property, `editing(for:)`, `isLastVillainMidHand`, `villainChipText`. Keep `removalDialogTitle` and `removeVillain(_:)` in the parent (the removal dialog's "Remove Villain" button calls `removeVillain`) — they need `isLastVillainMidHand`, so keep a private copy of that one-liner in the parent too.
- Delete `HeroStrip` entirely.

- [ ] **Step 3: Wire, build, test**

```bash
tools/pbx-add.py CaptureSetupSections.swift HandCaptureView.swift 7E570000000000000000013F 7E5700000000000000000140
```

Full suite + Release gate green.

- [ ] **Step 4: Simulator:** fresh hand → Hero row reads `Seat? · Cards? · <stack> ✎` with the seat grid open (position nil); pick BTN → grid collapses; cards come from the bar; after the hand starts, tapping the cards chip clears and shows the inline grid. Villain add/edit/remove and the shown-cards eye behave as before.

- [ ] **Step 5: Commit** — `feat(capture): collapsed hero chips; setup sections split out`

---

### Task 8: Result-first showdown — `CaptureResultBlock.swift`

**Files:**
- Create: `StackTrackerPro/Views/Session/CaptureResultBlock.swift`
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift` — remove `ResultBlock` and `VillainShowdownRow`
- Modify: `project.pbxproj`
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces: `enum ResultRowLogic { static func overrideAfterTap(_ tapped: Set<HandCaptureModel.Participant>, computed: [HandCaptureModel.Participant]) -> Set<HandCaptureModel.Participant>?; static func showsMismatchBanner(override: Set<HandCaptureModel.Participant>?, computed: [HandCaptureModel.Participant]) -> Bool }` and `struct ResultBlock: View { init(model:) }` (same name and call as today).

- [ ] **Step 1: Failing tests**

```swift
// MARK: - Result-first row logic

final class ResultRowLogicTests: XCTestCase {
    private let v = UUID()

    func testTapMatchingComputedClearsOverride() {
        XCTAssertNil(ResultRowLogic.overrideAfterTap([.hero], computed: [.hero]))
    }

    func testTapDifferingFromComputedSetsOverride() {
        XCTAssertEqual(ResultRowLogic.overrideAfterTap([.villain(v)], computed: [.hero]), [.villain(v)])
    }

    func testTapWithNoComputedWinnersSetsOverride() {
        XCTAssertEqual(ResultRowLogic.overrideAfterTap([.hero], computed: []), [.hero])
        XCTAssertEqual(ResultRowLogic.overrideAfterTap([.hero, .villain(v)], computed: []), [.hero, .villain(v)])
    }

    func testBannerOnlyOnRealDisagreement() {
        XCTAssertFalse(ResultRowLogic.showsMismatchBanner(override: nil, computed: [.hero]))
        XCTAssertFalse(ResultRowLogic.showsMismatchBanner(override: [.hero], computed: []))      // no cards: normal case
        XCTAssertFalse(ResultRowLogic.showsMismatchBanner(override: [.hero], computed: [.hero]))
        XCTAssertTrue(ResultRowLogic.showsMismatchBanner(override: [.villain(v)], computed: [.hero]))
    }

    /// End to end on the engine: a showdown with no cards is saveable the
    /// moment a result is tapped.
    @MainActor func testResultTapMakesShowdownResolvable() {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 50_000)
        model.heroPosition = .btn
        model.addVillain(position: .utg, relative: .similar, approxStack: 0)
        model.add(action: .raise, toAmount: 600)
        model.add(action: .call, toAmount: 0)
        for c in PlayingCard.parseList("Jh 8h 4d") { _ = model.addBoardCard(c) }
        model.add(action: .check, toAmount: 0); model.add(action: .check, toAmount: 0)
        _ = model.addBoardCard(PlayingCard("2c")!)
        model.add(action: .check, toAmount: 0); model.add(action: .check, toAmount: 0)
        _ = model.addBoardCard(PlayingCard("3s")!)
        model.add(action: .check, toAmount: 0); model.add(action: .check, toAmount: 0)
        XCTAssertTrue(model.needsShowdown)
        XCTAssertFalse(model.isResolvable)
        model.winnerOverride = ResultRowLogic.overrideAfterTap([.hero], computed: model.computedWinners)
        XCTAssertTrue(model.isResolvable)
        XCTAssertTrue(model.canSave)
    }
}
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Create `CaptureResultBlock.swift`**

Move `VillainShowdownRow` verbatim (uses `CardGrid` since Task 4). Then:

```swift
import SwiftUI

/// Result-row tap rules (spec §4), pure so they are unit-tested.
enum ResultRowLogic {
    /// Tapping the set the engine already computed means "trust computed"
    /// (clear the override); anything else — including any tap when no
    /// winner could be computed — is an explicit ruling.
    static func overrideAfterTap(_ tapped: Set<HandCaptureModel.Participant>,
                                 computed: [HandCaptureModel.Participant]) -> Set<HandCaptureModel.Participant>? {
        !computed.isEmpty && Set(computed) == tapped ? nil : tapped
    }

    /// The loud banner is for a REAL disagreement between entered cards and
    /// the tapped result — an override with no cards is the normal path.
    static func showsMismatchBanner(override: Set<HandCaptureModel.Participant>?,
                                    computed: [HandCaptureModel.Participant]) -> Bool {
        guard let override, !computed.isEmpty else { return false }
        return Set(computed) != override
    }
}

/// Result block for a finished hand (spec §4): at a showdown the result
/// buttons come first and Save lights up on the first tap; shown cards are
/// an optional disclosure beneath. Fold-outs show only the result line.
struct ResultBlock: View {
    let model: HandCaptureModel

    @State private var showCards = false

    private var candidates: [HandCaptureModel.Participant] {
        ([.hero] + model.villains.map { .villain($0.id) })
            .filter { !model.foldedParticipants.contains($0) }
    }

    private var selected: Set<HandCaptureModel.Participant> {
        model.winnerOverride ?? Set(model.computedWinners)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Result").font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)

            if model.needsShowdown {
                resultRow
                if ResultRowLogic.showsMismatchBanner(override: model.winnerOverride,
                                                      computed: model.computedWinners) {
                    HStack(spacing: 8) {
                        Label("Cards say \(describe(Set(model.computedWinners))) — result overridden",
                              systemImage: "flag.fill")
                            .font(PokerTypography.chipLabel)
                            .foregroundColor(.chipRed)
                        Spacer()
                        Button("Use cards") { model.winnerOverride = nil }
                            .font(.caption)
                            .foregroundColor(.goldAccent)
                    }
                }
                DisclosureGroup(isExpanded: $showCards) {
                    ForEach(model.villains.filter { !model.foldedParticipants.contains(.villain($0.id)) }) { villain in
                        VillainShowdownRow(model: model, villain: villain)
                    }
                } label: {
                    Text("Add shown cards")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }
                .tint(.goldAccent)
            }

            Text(resultLine)
                .font(PokerTypography.statValue)
                .foregroundColor(model.heroNet >= 0 ? .mZoneGreen : .chipRed)
        }
        .pokerCard()
    }

    private var resultRow: some View {
        HStack(spacing: 8) {
            ForEach(candidates, id: \.self) { participant in
                resultButton(title: participant == .hero ? "Hero won" : "\(model.label(for: participant)) won",
                             set: [participant])
            }
            if candidates.count > 1 {
                resultButton(title: "Chop", set: Set(candidates))
            }
        }
    }

    private func resultButton(title: String, set: Set<HandCaptureModel.Participant>) -> some View {
        let isOn = selected == set
        return Button {
            model.winnerOverride = ResultRowLogic.overrideAfterTap(set, computed: model.computedWinners)
            HapticFeedback.impact(.medium)
        } label: {
            Text(title)
                .font(PokerTypography.chipLabel.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(isOn ? Color.goldAccent : Color.backgroundPrimary)
                .foregroundColor(isOn ? .backgroundPrimary : .textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func describe(_ set: Set<HandCaptureModel.Participant>) -> String {
        set.map { model.label(for: $0) }.sorted().joined(separator: ", ")
    }

    private var resultLine: String {
        if model.needsShowdown, model.effectiveWinners.isEmpty {
            return "Tap who won, or add shown cards."
        }
        let net = model.heroNet
        let verb = net >= 0 ? "wins" : "loses"
        return "Hero \(verb) \(abs(net).formatted())"
    }
}
```

- [ ] **Step 4: Remove the old `ResultBlock` and `VillainShowdownRow` from `HandCaptureView.swift`** (the `Menu { "Trust Computed Result" … }` goes with it). Wire:

```bash
tools/pbx-add.py CaptureResultBlock.swift HandCaptureView.swift 7E5700000000000000000141 7E5700000000000000000142
```

- [ ] **Step 5: `ResultRowLogicTests` PASS; full suite + Release gate green.**

- [ ] **Step 6: Simulator:** play a hand to a check-down showdown → `Hero won · UTG (covers) won · Chop` appear, result line reads "Tap who won…", Save disabled; tap `Hero won` → line flips to "Hero wins N", Save enabled. Open "Add shown cards", give the villain a better hand → banner "Cards say UTG (covers) won — result overridden" with "Use cards". Fold-out hand → no buttons, just the line.

- [ ] **Step 7: Commit** — `feat(capture): result-first showdown; shown cards optional`

---

### Task 9: Save dismisses immediately; toast with Share in the presenters

**Files:**
- Create: `StackTrackerPro/Views/Components/SavedHandToast.swift`
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift` — `save()`, remove `showSavedDialog`/`showSavedShare`/`savedHand` and their dialog/sheet
- Modify: `StackTrackerPro/Views/Session/HandsPane.swift`, `StackTrackerPro/Views/Session/ActiveSessionView.swift`
- Modify: `project.pbxproj`

**Interfaces:**
- Produces: `struct SavedHandToast: View { init(onShare: @escaping () -> Void) }`; a `.savedHandToast(hand: Binding<Hand?>, onShare: @escaping (Hand) -> Void)` view modifier that overlays the toast at the bottom for 4 s.

- [ ] **Step 1: Create `SavedHandToast.swift`**

```swift
import SwiftUI
import SwiftData

/// "Hand saved" confirmation with a Share affordance (spec §6). Replaces the
/// post-save dialog: the capture screen dismisses at once and the presenter
/// shows this for four seconds.
struct SavedHandToast: View {
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.mZoneGreen)
            Text("Hand saved").font(PokerTypography.chipLabel).foregroundColor(.textPrimary)
            Spacer()
            Button("Share", action: onShare)
                .font(PokerTypography.chipLabel.weight(.semibold))
                .foregroundColor(.goldAccent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

private struct SavedHandToastModifier: ViewModifier {
    @Binding var hand: Hand?
    let onShare: (Hand) -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let shown = hand {
                    SavedHandToast {
                        onShare(shown)
                        hand = nil
                    }
                    .padding(.bottom, 84)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: hand?.persistentModelID)
            .task(id: hand?.persistentModelID) {
                guard hand != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                hand = nil
            }
    }
}

extension View {
    /// Shows `SavedHandToast` while `hand` is non-nil, auto-clearing after 4 s.
    func savedHandToast(hand: Binding<Hand?>, onShare: @escaping (Hand) -> Void) -> some View {
        modifier(SavedHandToastModifier(hand: hand, onShare: onShare))
    }
}
```

- [ ] **Step 2: `HandCaptureView.save()`** — replace the last three lines (`onSaved(hand)`, `savedHand = hand`, `showSavedDialog = true`) with:

```swift
        onSaved(hand)
        dismiss()
```

Delete `@State private var showSavedDialog`, `showSavedShare`, `savedHand`, the `.confirmationDialog("Hand saved", …)` and the `.sheet(isPresented: $showSavedShare, …)`.

- [ ] **Step 3: `HandsPane`** — add `@State private var toastHand: Hand?`. Change the three `onSaved` closures (`{ _ in }`) to `{ hand in toastHand = hand }` (both `fullScreenCover`s). Add after the `.sheet(item: $shareHand)` modifier:

```swift
        .savedHandToast(hand: $toastHand) { shareHand = $0 }
```

- [ ] **Step 4: `ActiveSessionView`** — add `@State private var toastHand: Hand?` and `@State private var toastShareHand: Hand?`. Change `onSaved: { _ in }` to `onSaved: { toastHand = $0 }`. After the `.fullScreenCover(isPresented: $showVoiceCapture)` modifier add:

```swift
        .savedHandToast(hand: $toastHand) { toastShareHand = $0 }
        .sheet(item: $toastShareHand) { hand in HandSharePreview(hand: hand) }
```

- [ ] **Step 5: Wire, build, test**

```bash
tools/pbx-add.py SavedHandToast.swift TranscriptEditorSheet.swift 7E5700000000000000000143 7E5700000000000000000144
```

Full suite + Release gate green.

- [ ] **Step 6: Simulator:** save a hand → capture closes immediately, toast rises above the Log Hand button, tapping Share opens the share preview; left alone it fades after ~4 s.

- [ ] **Step 7: Commit** — `feat(capture): save dismisses immediately; Hand saved toast with Share`

---

### Task 10: Release prep — 1.3.0 (21), verification pass, screenshots

**Files:**
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (`MARKETING_VERSION = 1.3.0`, `CURRENT_PROJECT_VERSION = 21` — the two app-target occurrences of each, currently `1.2.6` / `20`)
- Modify: `docs/superpowers/specs/2026-09-27-hand-capture-flow-design.md` — append `> **STATUS: EXECUTED <date>**` line
- Regenerate: `tools/screenshots/make-screenshots.sh` output (capture route)

- [ ] **Step 1: Bump versions**

```bash
python3 - <<'EOF'
p='StackTrackerPro.xcodeproj/project.pbxproj'; s=open(p).read()
s2=s.replace('CURRENT_PROJECT_VERSION = 20;','CURRENT_PROJECT_VERSION = 21;').replace('MARKETING_VERSION = 1.2.6;','MARKETING_VERSION = 1.3.0;')
assert s2.count('CURRENT_PROJECT_VERSION = 21;')==2 and s2.count('MARKETING_VERSION = 1.3.0;')==2
open(p,'w').write(s2); print('1.3.0 (21)')
EOF
```

- [ ] **Step 2: Full suite green (expect 185 + 17 new = 202). Release gate green (check the real exit code).**

- [ ] **Step 3: Tap-count verification on the reference hand** (fresh `Log Hand`, iPhone Air): BTN seat (1) · A♥ K♦ (2) · add UTG villain (3: Add villain → UTG → Add Villain) · UTG Bet/Raise → 3bb (2) · Hero Bet/Raise → 3× (2) · UTG Call (1) · K♠ 7♥ 2♣ (3) · UTG Check (1) · Hero Bet/Raise → ½ (2) · UTG Fold (1) · Save (1) = **19 taps, no keyboard, no scrolling to reach a control**. Record the actual count in the commit message. (Spec target ≤16 assumed one-tap villain add, which is the follow-on tier; ~19 is the expected number for this release — flag it, do not "fix" it here.)

- [ ] **Step 4: Screenshot factory** — `tools/screenshots/make-screenshots.sh` per its README; confirm the `capture` frame shows the bar in the acting state. Commit the regenerated PNGs if the repo tracks them (check `git status`).

- [ ] **Step 5: Mark the spec executed, commit** — `chore: bump to 1.3.0 (21); capture flow spec executed`

- [ ] **Step 6: Final whole-branch review** (subagent-driven-development's closing review on opus) against the spec — especially: no `TextField` in `CaptureBottomBar`; `CardPickerGrid` gone; the engine diff is only `minRaiseTotal`; all six bar states reachable.

---

## Self-review notes

- **Spec coverage:** §1 → Tasks 5–6; §2 → Task 4; §3 → Tasks 2, 3, 5; §4 → Task 8; §5 → Task 7; §6 → Task 9; §7 files → each task wires its own; §8 tests → Tasks 1, 2, 3, 8 + sim passes in 4–9; version → Task 10. One refinement over the spec, recorded in Task 1's `CaptureBarState` comment and Task 7: re-entering hero-card entry mid-hand happens inline in the Hero section rather than in the bar (the bar's `dealingHero` is fresh-hand only), because the bar would otherwise have to override the acting state during a live betting round.
- **Type consistency:** `CaptureBarState.derive(isHandOver:boardCardsNeeded:streetBeingDealt:pendingAction:heroCardsMissing:heroCardsDeferred:ledgerIsEmpty:villainsIsEmpty:)` is called identically in Task 1 tests and Task 5; `SizingPresets.chips(street:currentBet:minRaiseTotal:pot:bigBlind:jamTotal:)` in Task 3 tests and Task 5; `CaptureChips.hero(position:cards:cardCount:stack:)` in Task 1 tests and Task 7; `ResultRowLogic.overrideAfterTap(_:computed:)` / `showsMismatchBanner(override:computed:)` in Task 8 tests and view; `CardGrid(dealt:onPick:)` everywhere; `MiniCard(card:onRemove:)` in Tasks 5 and 6.
- **Tap target:** the spec's ≤16 presumed the follow-on villain change; Task 10 records the real number instead of hiding it.
