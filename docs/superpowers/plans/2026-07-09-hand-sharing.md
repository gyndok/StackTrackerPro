# Hand Sharing Implementation Plan

> **STATUS: EXECUTED 2026-07-09** (commits 18df8ba..eb6aff6, 3 tasks, reviews clean; 159 tests)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Share any logged hand as a formatted text hand history (Unicode suit glyphs) via the iOS share sheet, from HandDetailView and immediately after saving on the Capture Screen, with an in-app color preview.

**Architecture:** One pure formatter (`HandHistoryFormatter`) reads a persisted `Hand` and emits the canonical text; one small sheet (`HandSharePreview`) colorizes it for display and hands the plain string to `ShareLink`; two thin entry points present the sheet. No model, schema, or engine changes.

**Tech Stack:** SwiftUI (`ShareLink`, `AttributedString`), XCTest. Spec: `docs/superpowers/specs/2026-07-09-hand-share-design.md`.

## Global Constraints

- **No new SwiftData models or fields; no CloudKit schema impact; no `HandCaptureModel` engine changes** (spec Constraints).
- **Shared payload is plain text with suit glyphs; color exists only in the in-app preview** (spec Purpose).
- **All numbers in formatter output use en_US grouping** (`IntegerFormatStyle<Int>.number.locale(Locale(identifier: "en_US"))`) — same determinism lesson as HandTranscriptParser (locale-dependent `.formatted()` broke tests once already; see that file's pinned pattern).
- pbxproj hand-wiring, four entries per new file: HandHistoryFormatter.swift fileRef `7E5700000000000000000131`/buildFile `...0132` (Managers group); HandSharePreview.swift fileRef `...0133`/buildFile `...0134` (Views/Session group).
- Test command: `xcodebuild test -project StackTrackerPro.xcodeproj -scheme StackTrackerPro -destination 'platform=iOS Simulator,name=iPhone Air,OS=26.5'`. Suite is 152 green at HEAD 63fce70 — keep it green.
- Test hygiene: XCTUnwrap/guard before indexing; no raw indexing after non-halting asserts.
- Commits direct to `main`, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Existing Interfaces (verified at HEAD 63fce70)

- `Hand` (`StackTrackerPro/Models/Hand.swift`): `levelNumber/smallBlind/bigBlind/ante/heroStackChips/potSize/amountWon: Int`, `stakes: String`, `heroPositionRaw/resultRaw/boardRaw/heroCardsRaw: String`, computed `heroCards/board: [PlayingCard]`, `result: HandResult` (won/lost/chop/folded), `sortedActions: [HandAction]` (`street: HandStreet`, `positionRaw: String`, `actionType: HandActionType` (fold/check/call/bet/raise/allIn), `amount: Int`, `isHero: Bool`), `sortedVillains: [HandVillain]` (`positionRaw: String`, `shownHolding: String`, `shownCards: [PlayingCard]`).
- `PlayingCard.display` → `"K♠"` (rank char + suit glyph); `PlayingCard.parseList("Jh 8h 4d")`.
- `HandDetailView` lives in `StackTrackerPro/Views/Session/HandsPane.swift` (NavigationStack + List, ~line 229 has the Villains section added recently).
- `HandCaptureView.swift` save flow (Save button action, ~line 345 area): `model.save(...)` → conditional `tournamentManager.updateStack(...)` gated on `model.shouldPushStackUpdate` → `onSaved(hand)` → `dismiss()`. Read the CURRENT code before modifying — several fix rounds touched this file this week.

---

### Task 1: HandHistoryFormatter

**Files:**
- Create: `StackTrackerPro/Managers/HandHistoryFormatter.swift`
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (IDs 0131/0132, Managers group, four sections)
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces: `enum HandHistoryFormatter { static func text(for hand: Hand) -> String }` — Task 2 consumes exactly this.

**Format rules (binding, from the spec):**
1. **Header line:** tournament hands (`bigBlind > 0 && stakes.isEmpty`): `Level {levelNumber} — {sb}/{bb} ({ante})` — omit ` ({ante})` when ante == 0, omit `Level {n} — ` when levelNumber == 0. Cash hands (`!stakes.isEmpty`): the stakes string verbatim. Then ` · Hero {POS} {cards} ({stack})` — cards concatenated glyphs (`K♠K♦`, no separator), ` ({stack})` omitted when heroStackChips == 0, the cards segment omitted when heroCards is empty. When there is no blinds/stakes part, the line is just the hero segment without the leading ` · `.
2. **Street lines:** for each street in preflop/flop/turn/river: include a line if that street has actions OR board cards. Prefix: `PRE:` for preflop; `FLOP {c1c2c3}`, `TURN {c4}`, `RIVER {c5}` with concatenated glyphs from `hand.board` slices (flop = first 3, turn = 4th, river = 5th — render only slices that exist). When a board street also has actions, append `: ` then the actions (`FLOP J♥8♥4♦: BB checks · Hero bets 50,000`). Actions joined with ` · `, each `{actor} {verb}`: actor = `Hero` when isHero else `positionRaw`; verbs: fold→`folds`, check→`checks`, call→`calls` (no amount), bet→`bets {amount}`, raise→`raises to {amount}`, allIn→`all-in {amount}` (bet/raise/all-in omit the amount when it's 0).
3. **Result line:** shown holdings first — for each villain with `shownHolding` non-empty: `{POS} shows {glyphs}`, multiple joined by `, `. Then ` — ` and the result: won → `Hero wins {potSize} (+{amountWon})` (omit `{potSize} ` when potSize == 0; omit ` (+…)` when amountWon == 0); lost → `Hero loses ({amountWon})` with the sign as stored (negative renders `(-13,000)`); chop → `Chop (+{amountWon})` (omit when 0); folded → `Hero folds`. No shows → result stands alone.
4. All numbers en_US grouped. Lines joined with `\n`; no trailing newline; skip empty lines entirely.

- [ ] **Step 1: Write the failing tests** (a new `HandHistoryFormatterTests: XCTestCase` class; fixtures built directly on `Hand`/`HandAction`/`HandVillain` in an in-memory container is NOT needed — these types work detached; construct plain instances):

```swift
final class HandHistoryFormatterTests: XCTestCase {

    private func referenceHand() -> Hand {
        let hand = Hand(heroPosition: .btn, heroCardsRaw: "Ks Kd",
                        levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                        ante: 25_000, heroStackChips: 390_000)
        hand.boardRaw = "Jh 8h 4d 2c 3s"
        hand.resultRaw = HandResult.won.rawValue
        hand.potSize = 840_000
        hand.amountWon = 450_000
        let actions: [(HeroPosition, HandActionType, Int, Bool)] = [
            (.utg, .raise, 75_000, false),
            (.btn, .raise, 200_000, true),
            (.utg, .allIn, 390_000, false),
            (.btn, .call, 0, true),
        ]
        for (i, a) in actions.enumerated() {
            let act = HandAction(orderIndex: i, street: .preflop, position: a.0,
                                 actionType: a.1, amount: a.2, isHero: a.3)
            act.hand = hand
            hand.actions?.append(act)
        }
        let villain = HandVillain(orderIndex: 0, position: .utg, relativeStack: .coversHero)
        villain.shownHolding = "9h Th"
        villain.hand = hand
        hand.villains?.append(villain)
        return hand
    }

    func testFormatsReferenceHand() {
        let expected = """
        Level 21 — 10,000/25,000 (25,000) · Hero BTN K♠K♦ (390,000)
        PRE: UTG raises to 75,000 · Hero raises to 200,000 · UTG all-in 390,000 · Hero calls
        FLOP J♥8♥4♦
        TURN 2♣
        RIVER 3♠
        UTG shows 9♥T♥ — Hero wins 840,000 (+450,000)
        """
        XCTAssertEqual(HandHistoryFormatter.text(for: referenceHand()), expected)
    }

    func testFormatsPreflopFoldWithoutBoard() {
        let hand = Hand(heroPosition: .co, heroCardsRaw: "Ah Jc",
                        levelNumber: 3, smallBlind: 200, bigBlind: 400,
                        ante: 400, heroStackChips: 55_000)
        hand.resultRaw = HandResult.folded.rawValue
        let acts: [(HeroPosition, HandActionType, Int, Bool)] = [
            (.co, .raise, 1_000, true), (.bb, .raise, 3_500, false), (.co, .fold, 0, true),
        ]
        for (i, a) in acts.enumerated() {
            let act = HandAction(orderIndex: i, street: .preflop, position: a.0,
                                 actionType: a.1, amount: a.2, isHero: a.3)
            act.hand = hand
            hand.actions?.append(act)
        }
        let expected = """
        Level 3 — 200/400 (400) · Hero CO A♥J♣ (55,000)
        PRE: Hero raises to 1,000 · BB raises to 3,500 · Hero folds
        Hero folds
        """
        XCTAssertEqual(HandHistoryFormatter.text(for: hand), expected)
    }

    func testFormatsCashHeaderAndPostflopActions() {
        let hand = Hand(heroPosition: .btn, heroCardsRaw: "Qs Qd", stakes: "$1/$3")
        hand.boardRaw = "Jh 8h 4d"
        hand.resultRaw = HandResult.won.rawValue
        hand.amountWon = 120
        let acts: [(HandStreet, HeroPosition, HandActionType, Int, Bool)] = [
            (.preflop, .btn, .raise, 15, true), (.preflop, .bb, .call, 0, false),
            (.flop, .bb, .check, 0, false), (.flop, .btn, .bet, 20, true),
            (.flop, .bb, .fold, 0, false),
        ]
        for (i, a) in acts.enumerated() {
            let act = HandAction(orderIndex: i, street: a.0, position: a.1,
                                 actionType: a.2, amount: a.3, isHero: a.4)
            act.hand = hand
            hand.actions?.append(act)
        }
        let expected = """
        $1/$3 · Hero BTN Q♠Q♦
        PRE: Hero raises to 15 · BB calls
        FLOP J♥8♥4♦: BB checks · Hero bets 20 · BB folds
        Hero wins (+120)
        """
        XCTAssertEqual(HandHistoryFormatter.text(for: hand), expected)
    }

    func testFormatsChopAndMuckedVillainExcluded() {
        let hand = Hand(heroPosition: .sb, heroCardsRaw: "Ah Kh",
                        levelNumber: 0, smallBlind: 100, bigBlind: 200,
                        ante: 0, heroStackChips: 0)
        hand.resultRaw = HandResult.chop.rawValue
        hand.potSize = 3_000
        hand.amountWon = 0
        let shown = HandVillain(orderIndex: 0, position: .bb, relativeStack: .similar)
        shown.shownHolding = "Ad Kd"
        shown.hand = hand
        hand.villains?.append(shown)
        let mucked = HandVillain(orderIndex: 1, position: .co, relativeStack: .shorter)
        mucked.hand = hand
        hand.villains?.append(mucked)
        let expected = """
        100/200 · Hero SB A♥K♥
        BB shows A♦K♦ — Chop
        """
        XCTAssertEqual(HandHistoryFormatter.text(for: hand), expected)
    }

    func testPartialHandNeverCrashes() {
        let hand = Hand()
        let text = HandHistoryFormatter.text(for: hand)
        XCTAssertFalse(text.isEmpty)   // at least the result line ("Hero folds" default)
    }
}
```

Note the second test pins a subtle rule: a hero fold produces BOTH the PRE action `Hero folds` and the standalone result line `Hero folds` — that is intended (the result line always closes the history). Note the fourth pins header-without-level (`100/200 · …`, no `Level 0 — `).

- [ ] **Step 2: Run to verify failure** (`cannot find 'HandHistoryFormatter'`).

- [ ] **Step 3: Implement `StackTrackerPro/Managers/HandHistoryFormatter.swift`:**

```swift
import Foundation

/// Formats a persisted Hand as a shareable plain-text hand history with
/// Unicode suit glyphs. Pure and deterministic: numbers are en_US-grouped
/// regardless of device locale (same lesson as HandTranscriptParser).
enum HandHistoryFormatter {

    private static let numberStyle = IntegerFormatStyle<Int>.number
        .locale(Locale(identifier: "en_US"))

    static func text(for hand: Hand) -> String {
        var lines: [String] = []
        if let header = headerLine(for: hand) { lines.append(header) }
        lines.append(contentsOf: streetLines(for: hand))
        lines.append(resultLine(for: hand))
        return lines.joined(separator: "\n")
    }

    // MARK: - Header

    private static func headerLine(for hand: Hand) -> String? {
        var contextPart: String?
        if !hand.stakes.isEmpty {
            contextPart = hand.stakes
        } else if hand.bigBlind > 0 {
            var blinds = "\(fmt(hand.smallBlind))/\(fmt(hand.bigBlind))"
            if hand.ante > 0 { blinds += " (\(fmt(hand.ante)))" }
            contextPart = hand.levelNumber > 0 ? "Level \(hand.levelNumber) — \(blinds)" : blinds
        }

        var heroPart = "Hero \(hand.heroPositionRaw)"
        let cards = glyphs(hand.heroCards)
        if !cards.isEmpty { heroPart += " \(cards)" }
        if hand.heroStackChips > 0 { heroPart += " (\(fmt(hand.heroStackChips)))" }

        if let contextPart { return "\(contextPart) · \(heroPart)" }
        // No blinds/stakes context and no cards/stack → header adds nothing.
        return hand.heroCards.isEmpty && hand.heroStackChips == 0 ? nil : heroPart
    }

    // MARK: - Streets

    private static func streetLines(for hand: Hand) -> [String] {
        let board = hand.board
        var lines: [String] = []
        for street in HandStreet.allCases {
            let actions = hand.sortedActions.filter { $0.street == street }
            let boardPart = boardGlyphs(for: street, board: board)
            guard !actions.isEmpty || boardPart != nil else { continue }

            var prefix: String
            switch street {
            case .preflop: prefix = "PRE"
            case .flop: prefix = "FLOP"
            case .turn: prefix = "TURN"
            case .river: prefix = "RIVER"
            }
            if let boardPart { prefix += " \(boardPart)" }

            if actions.isEmpty {
                lines.append(prefix)
            } else {
                let joined = actions.map(describe).joined(separator: " · ")
                lines.append("\(prefix): \(joined)")
            }
        }
        return lines
    }

    private static func boardGlyphs(for street: HandStreet, board: [PlayingCard]) -> String? {
        switch street {
        case .preflop: return nil
        case .flop: return board.count >= 3 ? glyphs(Array(board[0..<3])) : nil
        case .turn: return board.count >= 4 ? board[3].display : nil
        case .river: return board.count >= 5 ? board[4].display : nil
        }
    }

    private static func describe(_ action: HandAction) -> String {
        let actor = action.isHero ? "Hero" : action.positionRaw
        let amount = action.amount > 0 ? " \(fmt(action.amount))" : ""
        switch action.actionType {
        case .fold: return "\(actor) folds"
        case .check: return "\(actor) checks"
        case .call: return "\(actor) calls"
        case .bet: return "\(actor) bets\(amount)"
        case .raise: return action.amount > 0 ? "\(actor) raises to\(amount)" : "\(actor) raises"
        case .allIn: return "\(actor) all-in\(amount)"
        }
    }

    // MARK: - Result

    private static func resultLine(for hand: Hand) -> String {
        let shows = hand.sortedVillains
            .filter { !$0.shownHolding.isEmpty }
            .map { "\($0.positionRaw) shows \(glyphs($0.shownCards))" }
            .joined(separator: ", ")

        let outcome: String
        switch hand.result {
        case .won:
            var s = "Hero wins"
            if hand.potSize > 0 { s += " \(fmt(hand.potSize))" }
            if hand.amountWon != 0 { s += " (+\(fmt(hand.amountWon)))" }
            outcome = s
        case .lost:
            outcome = hand.amountWon != 0 ? "Hero loses (\(fmt(hand.amountWon)))" : "Hero loses"
        case .chop:
            outcome = hand.amountWon != 0 ? "Chop (+\(fmt(hand.amountWon)))" : "Chop"
        case .folded:
            outcome = "Hero folds"
        }
        return shows.isEmpty ? outcome : "\(shows) — \(outcome)"
    }

    // MARK: - Helpers

    private static func fmt(_ n: Int) -> String { n.formatted(numberStyle) }
    private static func glyphs(_ cards: [PlayingCard]) -> String {
        cards.map(\.display).joined()
    }
}
```

- [ ] **Step 4: Run the five tests → PASS** (iterate on exact-string mismatches — the tests are the contract; fix the implementation, not the expected strings, unless a rule genuinely conflicts, in which case document it).
- [ ] **Step 5: pbxproj (0131/0132). Full suite (expect 157). Commit** — `feat: hand history text formatter`

---

### Task 2: HandSharePreview + entry points

**Files:**
- Create: `StackTrackerPro/Views/Session/HandSharePreview.swift`
- Modify: `StackTrackerPro/Views/Session/HandsPane.swift` (HandDetailView toolbar share)
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift` (post-save Saved ✓ Share/Done)
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (IDs 0133/0134, Session group)

**Interfaces:**
- Consumes: `HandHistoryFormatter.text(for:)` (Task 1).
- Produces: `HandSharePreview(hand: Hand)` — a self-contained sheet.

**HandSharePreview:**

```swift
import SwiftUI

/// In-app preview of a hand's text history with colored suits; shares the
/// PLAIN text (color cannot travel in shared plain text — by design).
struct HandSharePreview: View {
    let hand: Hand
    @Environment(\.dismiss) private var dismiss

    private var plainText: String { HandHistoryFormatter.text(for: hand) }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(colorized(plainText))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding()
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Share Hand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: plainText) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Red for ♥/♦ glyph plus its preceding rank character; default color otherwise.
    private func colorized(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        var index = result.startIndex
        var previous: AttributedString.Index?
        while index < result.endIndex {
            let ch = result.characters[index]
            if ch == "♥" || ch == "♦" {
                let next = result.index(afterCharacter: index)
                result[index..<next].foregroundColor = .red
                if let previous {
                    result[previous..<index].foregroundColor = .red
                }
            }
            previous = index
            index = result.index(afterCharacter: index)
        }
        return result
    }
}
```

(Verify the `AttributedString` index APIs against the SDK — `index(afterCharacter:)` naming may differ (`result.index(index, offsetByCharacters: 1)` is the fallback); the compiler is the authority. Behavior contract: each ♥/♦ and the single character before it render red.)

**HandDetailView (HandsPane.swift):** add a toolbar item — `Button { showShare = true } label: { Label("Share Hand", systemImage: "square.and.arrow.up") }` with `@State private var showShare = false` and `.sheet(isPresented: $showShare) { HandSharePreview(hand: hand) }`. Match whatever toolbar structure HandDetailView already has (it may have none — add `.toolbar` to its List/NavigationStack content).

**HandCaptureView post-save:** read the CURRENT save-button action first (this file changed several times this week — the flow is save → conditional stack push → onSaved → dismiss). Change: keep save + push + `onSaved(hand)` exactly where they are; replace the immediate `dismiss()` with state `savedHand = hand; showSavedDialog = true` and add:

```swift
.confirmationDialog("Hand saved", isPresented: $showSavedDialog, titleVisibility: .visible) {
    Button("Share…") { showSavedShare = true }
    Button("Done") { dismiss() }
} message: { Text("Share it or head back to the table.") }
.sheet(isPresented: $showSavedShare, onDismiss: { dismiss() }) {
    if let savedHand { HandSharePreview(hand: savedHand) }
}
```

Semantics: Done → dismiss as before; Share → preview; closing the preview dismisses the capture screen (the hand is already saved either way). Dialog dismissed by tapping outside → also `dismiss()` (add `Button("Done", role: .cancel)` so the cancel path is explicit). `onSaved` firing before the dialog keeps HandsPane/stub state consistent regardless of path.

- [ ] **Step 1: Implement all three pieces.** Step 2: **Build clean (zero new warnings) + full suite green (157).** Step 3: **pbxproj (0133/0134). Commit** — `feat: hand share preview and entry points`

---

### Task 3: Verification

- [ ] **Step 1: Full suite + build** at HEAD — 157 green, zero new warnings.
- [ ] **Step 2: Simulator smoke:** open a logged hand → Share → preview shows colored suits → share sheet opens with plain text. Log a hand on the Capture Screen → Save → "Hand saved" dialog → both paths.
- [ ] **Step 3: Mark the spec/plan executed; commit** — `docs: mark hand sharing plan executed`

## Self-Review (performed at plan time)

- **Spec coverage:** formatter rules 1–4 ↔ spec's format section (header/streets/result/graceful degradation) ✓; preview with in-app-only color ✓; both entry points ✓; batch share and reporter mode explicitly absent (tabled) ✓; no schema ✓.
- **Placeholder scan:** clean; the one deliberately-open item (AttributedString index API naming) states the fallback and the behavior contract.
- **Type consistency:** `HandHistoryFormatter.text(for:)` produced T1, consumed T2; `HandSharePreview(hand:)` produced T2, consumed by both entry points; fixture initializers match `Hand`/`HandAction`/`HandVillain` as verified at HEAD.
- **Fixture note:** Task 1 builds detached model instances (no ModelContext) — `@Model` classes support this; if SwiftData objects to detached relationship appends, fall back to an in-memory container like HandStubTests (documented escape hatch, not a placeholder).
