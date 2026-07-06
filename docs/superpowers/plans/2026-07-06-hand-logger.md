# Hand Logger (PokerPad Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Structured, tap-only poker hand logging inside StackTrackerPro's live tournament and cash sessions, with auto-captured context (level, blinds, stack, players), a per-session hand list with VPIP/PFR, and hands included in the AI recap export.

**Architecture:** A pure `@Observable` state machine (`HandEntryModel`) drives a staged input surface (`HandEntryView`) presented as a sheet from the active session screens. Hands persist as two new SwiftData models (`Hand`, `HandAction`) cascaded from `Tournament`/`CashSession`, CloudKit-safe. All game context is snapshotted at save time from the live session — there is no game-setup step (that is the core adaptation from the PokerPad PRD: StackTrackerPro already knows the stakes, level, and stack).

**Tech Stack:** Swift 6 / SwiftUI / SwiftData (+CloudKit), XCTest. No new dependencies.

## Global Constraints

- iOS deployment target 26.0; build/test destination: `platform=iOS Simulator,name=iPhone Air,OS=26.5`
- SwiftData + CloudKit rules: every stored property has a default or is optional; relationships optional arrays with cascade delete + inverse; new models must be added to the `Schema` list in `StackTrackerProApp.swift` AND the test helper in `StackTrackerProTests.swift`
- pbxproj uses explicit file references — every new file must be wired via the python pattern in Task 1 Step 6 (unique IDs `7E57...010B` onward; verify unused before use)
- Dark theme only: use `Color.backgroundPrimary`, `Color.cardSurface`, `Color.goldAccent`, `Color.textPrimary`, `Color.textSecondary`, `PokerTypography` fonts
- Icon-only buttons get `.accessibilityLabel`; tap targets ≥ 44pt
- NO blind-level countdown/clock UI anywhere (standing user decision)
- All unit tests live in `StackTrackerProTests/StackTrackerProTests.swift`; run with `xcodebuild -project StackTrackerPro.xcodeproj -scheme StackTrackerPro -destination 'platform=iOS Simulator,name=iPhone Air,OS=26.5' test`
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Out of scope (deferred, do NOT build): suited/offsuit shortcut, GTO verdicts, in-app AI calls, animated replayer, PokerStars HH export, opponent tracking, straddles, voice notes, PLO, stats dashboard beyond session VPIP/PFR

---

### Task 1: Hand data model

**Files:**
- Create: `StackTrackerPro/Models/Hand.swift`
- Modify: `StackTrackerPro/Models/Tournament.swift` (add relationship after `events`)
- Modify: `StackTrackerPro/Models/CashSession.swift` (add relationship next to its existing ones)
- Modify: `StackTrackerPro/App/StackTrackerProApp.swift` (schema list)
- Modify: `StackTrackerProTests/StackTrackerProTests.swift` (schema helper + tests)
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (wire Hand.swift)

**Interfaces:**
- Produces: `PlayingCard` (`rank: Character`, `suit: Character`, `init?(_ string: String)`, `var display: String`, `static func parseList(_ raw: String) -> [PlayingCard]`, `static func joinList(_ cards: [PlayingCard]) -> String`); enums `HandStreet`, `HeroPosition`, `HandActionType`, `HandResult` (all `String` raw, `CaseIterable`); `@Model Hand` (fields below, `var actions: [HandAction]? = []`, computed `heroCards: [PlayingCard]`, `board: [PlayingCard]`, `sortedActions: [HandAction]`, `netResult: Int`); `@Model HandAction` (`orderIndex`, `streetRaw`, `positionRaw`, `actionTypeRaw`, `amount`, `isHero`, `hand: Hand?`); `Tournament.hands`/`CashSession.hands` cascade arrays + `sortedHands`

- [ ] **Step 1: Write the failing tests** — append to `StackTrackerProTests.swift`:

```swift
// MARK: - Hand model

final class HandModelTests: XCTestCase {

    func testPlayingCardParsing() {
        XCTAssertEqual(PlayingCard("As")?.display, "A♠")
        XCTAssertEqual(PlayingCard("Th")?.display, "T♥")
        XCTAssertNil(PlayingCard("Zx"))
        XCTAssertNil(PlayingCard("A"))
        let cards = PlayingCard.parseList("As Kh 7d")
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(PlayingCard.joinList(cards), "As Kh 7d")
    }

    @MainActor
    func testHandPersistsWithActionsAndContext() throws {
        let container = try makeInMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext

        let t = Tournament(name: "Ultra Stack", buyIn: 600)
        context.insert(t)

        let hand = Hand(
            heroPosition: .btn,
            heroCardsRaw: "As Kh",
            levelNumber: 8, smallBlind: 600, bigBlind: 1200, ante: 1200,
            heroStackChips: 85_000, playersRemaining: 140, tableSize: 9
        )
        hand.boardRaw = "Ah 7d 2c"
        hand.resultRaw = HandResult.won.rawValue
        hand.potSize = 24_000
        hand.amountWon = 12_400
        hand.tournament = t
        context.insert(hand)

        let a1 = HandAction(orderIndex: 0, street: .preflop, position: .utg, actionType: .raise, amount: 3000, isHero: false)
        let a2 = HandAction(orderIndex: 1, street: .preflop, position: .btn, actionType: .raise, amount: 9000, isHero: true)
        a1.hand = hand; a2.hand = hand
        context.insert(a1); context.insert(a2)
        try context.save()

        XCTAssertEqual(t.sortedHands.count, 1)
        let saved = t.sortedHands[0]
        XCTAssertEqual(saved.heroCards.map(\.display), ["A♠", "K♥"])
        XCTAssertEqual(saved.board.count, 3)
        XCTAssertEqual(saved.sortedActions.map(\.orderIndex), [0, 1])
        XCTAssertEqual(saved.sortedActions[1].actionType, .raise)
        XCTAssertTrue(saved.sortedActions[1].isHero)
        XCTAssertEqual(saved.netResult, 12_400)
        XCTAssertEqual(saved.result, .won)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail** — `xcodebuild ... test 2>&1 | grep -E "error:|Executed"` — expected: compile error `cannot find 'PlayingCard' in scope`.

- [ ] **Step 3: Create `StackTrackerPro/Models/Hand.swift`:**

```swift
import Foundation
import SwiftData

// MARK: - Card

struct PlayingCard: Equatable, Hashable {
    static let ranks: [Character] = ["A","K","Q","J","T","9","8","7","6","5","4","3","2"]
    static let suits: [Character] = ["s","h","d","c"]

    let rank: Character
    let suit: Character

    init?(rank: Character, suit: Character) {
        guard Self.ranks.contains(rank), Self.suits.contains(suit) else { return nil }
        self.rank = rank
        self.suit = suit
    }

    init?(_ string: String) {
        guard string.count == 2,
              let r = string.first, let s = string.last,
              let card = PlayingCard(rank: r, suit: s) else { return nil }
        self = card
    }

    var raw: String { "\(rank)\(suit)" }

    var suitSymbol: String {
        switch suit {
        case "s": return "♠"
        case "h": return "♥"
        case "d": return "♦"
        default: return "♣"
        }
    }

    var display: String { "\(rank)\(suitSymbol)" }

    /// True for hearts/diamonds (red suits) — used for display tinting.
    var isRed: Bool { suit == "h" || suit == "d" }

    static func parseList(_ raw: String) -> [PlayingCard] {
        raw.split(separator: " ").compactMap { PlayingCard(String($0)) }
    }

    static func joinList(_ cards: [PlayingCard]) -> String {
        cards.map(\.raw).joined(separator: " ")
    }
}

// MARK: - Enums

enum HandStreet: String, CaseIterable {
    case preflop, flop, turn, river

    var label: String { rawValue.capitalized }
}

enum HeroPosition: String, CaseIterable {
    case utg = "UTG", utg1 = "UTG+1", mp = "MP", lj = "LJ", hj = "HJ"
    case co = "CO", btn = "BTN", sb = "SB", bb = "BB"
}

enum HandActionType: String, CaseIterable {
    case fold = "Fold", check = "Check", call = "Call"
    case bet = "Bet", raise = "Raise", allIn = "All-In"

    /// Actions where the hero voluntarily put chips in preflop (VPIP).
    var isVoluntaryChips: Bool {
        switch self {
        case .call, .bet, .raise, .allIn: return true
        case .fold, .check: return false
        }
    }
}

enum HandResult: String, CaseIterable {
    case won = "Won", lost = "Lost", chop = "Chop", folded = "Folded"
}

// MARK: - Models

@Model
final class Hand {
    var timestamp: Date = Date.now
    var heroPositionRaw: String = HeroPosition.btn.rawValue
    var heroCardsRaw: String = ""      // "As Kh"
    var boardRaw: String = ""          // "Ah 7d 2c Ts 3h"
    var resultRaw: String = HandResult.folded.rawValue
    var potSize: Int = 0               // 0 = not recorded
    var amountWon: Int = 0             // net; negative = loss
    var villainCardsRaw: String = ""
    var notes: String = ""
    var tagsRaw: String = ""           // comma-joined

    // Context snapshot (all zero when unknown / cash game)
    var levelNumber: Int = 0
    var smallBlind: Int = 0
    var bigBlind: Int = 0
    var ante: Int = 0
    var heroStackChips: Int = 0
    var playersRemaining: Int = 0
    var tableSize: Int = 9
    var stakes: String = ""            // cash stakes string, e.g. "1/3"

    @Relationship(deleteRule: .cascade, inverse: \HandAction.hand)
    var actions: [HandAction]? = []

    var tournament: Tournament?
    var cashSession: CashSession?

    init(
        heroPosition: HeroPosition = .btn,
        heroCardsRaw: String = "",
        levelNumber: Int = 0, smallBlind: Int = 0, bigBlind: Int = 0, ante: Int = 0,
        heroStackChips: Int = 0, playersRemaining: Int = 0, tableSize: Int = 9,
        stakes: String = ""
    ) {
        self.heroPositionRaw = heroPosition.rawValue
        self.heroCardsRaw = heroCardsRaw
        self.levelNumber = levelNumber
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
        self.ante = ante
        self.heroStackChips = heroStackChips
        self.playersRemaining = playersRemaining
        self.tableSize = tableSize
        self.stakes = stakes
    }

    var heroPosition: HeroPosition { HeroPosition(rawValue: heroPositionRaw) ?? .btn }
    var result: HandResult { HandResult(rawValue: resultRaw) ?? .folded }
    var heroCards: [PlayingCard] { PlayingCard.parseList(heroCardsRaw) }
    var board: [PlayingCard] { PlayingCard.parseList(boardRaw) }
    var villainCards: [PlayingCard] { PlayingCard.parseList(villainCardsRaw) }
    var tags: [String] { tagsRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var netResult: Int { amountWon }

    var sortedActions: [HandAction] {
        (actions ?? []).sorted { $0.orderIndex < $1.orderIndex }
    }

    /// Hero's preflop actions, for VPIP/PFR.
    var heroPreflopActions: [HandAction] {
        sortedActions.filter { $0.isHero && $0.street == .preflop }
    }

    var blindsDisplay: String {
        if !stakes.isEmpty { return stakes }
        guard bigBlind > 0 else { return "" }
        var s = "\(smallBlind.formatted())/\(bigBlind.formatted())"
        if ante > 0 { s += " ante \(ante.formatted())" }
        return s
    }
}

@Model
final class HandAction {
    var orderIndex: Int = 0
    var streetRaw: String = HandStreet.preflop.rawValue
    var positionRaw: String = HeroPosition.btn.rawValue
    var actionTypeRaw: String = HandActionType.check.rawValue
    var amount: Int = 0
    var isHero: Bool = false
    var hand: Hand?

    init(orderIndex: Int, street: HandStreet, position: HeroPosition, actionType: HandActionType, amount: Int = 0, isHero: Bool = false) {
        self.orderIndex = orderIndex
        self.streetRaw = street.rawValue
        self.positionRaw = position.rawValue
        self.actionTypeRaw = actionType.rawValue
        self.amount = amount
        self.isHero = isHero
    }

    var street: HandStreet { HandStreet(rawValue: streetRaw) ?? .preflop }
    var position: HeroPosition { HeroPosition(rawValue: positionRaw) ?? .btn }
    var actionType: HandActionType { HandActionType(rawValue: actionTypeRaw) ?? .check }

    var timelineDescription: String {
        let amountPart = amount > 0 ? " \(amount.formatted())" : ""
        return "\(positionRaw) \(actionTypeRaw.lowercased())\(amountPart)"
    }
}
```

- [ ] **Step 4: Wire relationships and schema.** In `Tournament.swift` after the `events` relationship add:

```swift
    @Relationship(deleteRule: .cascade, inverse: \Hand.tournament)
    var hands: [Hand]? = []
```

and next to `sortedEvents`:

```swift
    var sortedHands: [Hand] {
        (hands ?? []).sorted { $0.timestamp < $1.timestamp }
    }
```

In `CashSession.swift`, add the same pair with `inverse: \Hand.cashSession`. In `StackTrackerProApp.swift` schema list, after `TournamentEvent.self` add `Hand.self,` and `HandAction.self,`. Make the identical addition to `makeInMemoryContainer()` in the tests file.

- [ ] **Step 5: Wire `Hand.swift` into pbxproj** (adapt the proven pattern; verify IDs unused first):

```bash
python3 - <<'EOF'
p = "StackTrackerPro.xcodeproj/project.pbxproj"
s = open(p).read()
FR, BF = "7E570000000000000000010B", "7E570000000000000000010C"
for i in (FR, BF): assert i not in s
anchor = "/* End PBXBuildFile section */"
s = s.replace(anchor, f"\t\t{BF} /* Hand.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {FR} /* Hand.swift */; }};\n" + anchor)
anchor = "/* End PBXFileReference section */"
s = s.replace(anchor, f"\t\t{FR} /* Hand.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Hand.swift; sourceTree = \"<group>\"; }};\n" + anchor)
old = "\t\tAAC7DC5DCD23638D271D3093 /* Models */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = ("
s = s.replace(old, old + f"\n\t\t\t\t{FR} /* Hand.swift */,")
old = "\t\t\tfiles = (\n\t\t\t\t7A1011E24D55223C7B00EFB2 /* StackTrackerProApp.swift in Sources */,"
s = s.replace(old, old + f"\n\t\t\t\t{BF} /* Hand.swift in Sources */,")
open(p, "w").write(s)
print("wired Hand.swift")
EOF
```

- [ ] **Step 6: Run tests, verify pass** — full suite green, including both new tests.

- [ ] **Step 7: Commit** — `feat: Hand and HandAction models with context snapshot`

---

### Task 2: HandEntryModel state machine (pure logic)

**Files:**
- Create: `StackTrackerPro/Managers/HandEntryModel.swift`
- Modify: `StackTrackerProTests/StackTrackerProTests.swift`
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (IDs `...010D`/`...010E`, same pattern, Managers group `778F8A5CCA605DF481933210`)

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `@MainActor @Observable final class HandEntryModel` with: `enum Stage: Equatable { case position, holeCards, action(HandStreet), boardCards(HandStreet) , result }`; `private(set) var stage: Stage`; `private(set) var heroPosition: HeroPosition?`; `private(set) var heroCards: [PlayingCard]`; `private(set) var board: [PlayingCard]`; `struct DraftAction { let street: HandStreet; let position: HeroPosition; let type: HandActionType; let amount: Int; let isHero: Bool }`; `private(set) var draftActions: [DraftAction]`; `var actingPosition: HeroPosition`; `var result: HandResult?`; `var potSize: Int`; `var amountWon: Int`; `var villainCards: [PlayingCard]`; `var notes: String`; `var selectedTags: Set<String>`; `static let presetTags: [String]`; methods `selectPosition(_:)`, `addCard(_:) -> Bool`, `isCardDealt(_:) -> Bool`, `addAction(_:amount:)`, `advanceStreet()`, `finishHand()`, `undo()`, `potEstimate(sb:bb:ante:) -> Int`, `save(into:tournament:cashSession:seatsDefault:) -> Hand`

- [ ] **Step 1: Write the failing tests:**

```swift
// MARK: - Hand entry state machine

final class HandEntryModelTests: XCTestCase {

    @MainActor
    func testStageProgressionThroughFullHand() {
        let m = HandEntryModel()
        XCTAssertEqual(m.stage, .position)

        m.selectPosition(.btn)
        XCTAssertEqual(m.stage, .holeCards)
        XCTAssertEqual(m.actingPosition, .btn, "hero position preselected for actions")

        XCTAssertTrue(m.addCard(PlayingCard("As")!))
        XCTAssertEqual(m.stage, .holeCards, "still waiting for second card")
        XCTAssertTrue(m.addCard(PlayingCard("Kh")!))
        XCTAssertEqual(m.stage, .action(.preflop))

        XCTAssertFalse(m.addCard(PlayingCard("As")!), "dealt card rejected")
        XCTAssertTrue(m.isCardDealt(PlayingCard("As")!))

        m.addAction(.raise, amount: 3000)
        XCTAssertEqual(m.draftActions.count, 1)
        XCTAssertTrue(m.draftActions[0].isHero, "action at hero position is hero's")

        m.advanceStreet()
        XCTAssertEqual(m.stage, .boardCards(.flop))
        _ = m.addCard(PlayingCard("Ah")!)
        _ = m.addCard(PlayingCard("7d")!)
        XCTAssertEqual(m.stage, .boardCards(.flop))
        _ = m.addCard(PlayingCard("2c")!)
        XCTAssertEqual(m.stage, .action(.flop))

        m.advanceStreet()
        _ = m.addCard(PlayingCard("Ts")!)
        XCTAssertEqual(m.stage, .action(.turn))
        m.advanceStreet()
        _ = m.addCard(PlayingCard("3h")!)
        XCTAssertEqual(m.stage, .action(.river))

        m.finishHand()
        XCTAssertEqual(m.stage, .result)
    }

    @MainActor
    func testFinishFromPreflopSkipsBoard() {
        let m = HandEntryModel()
        m.selectPosition(.co)
        _ = m.addCard(PlayingCard("7s")!)
        _ = m.addCard(PlayingCard("2c")!)
        m.addAction(.fold)
        m.finishHand()
        XCTAssertEqual(m.stage, .result)
        XCTAssertEqual(m.result, .folded, "hero fold pre-selects Folded result")
    }

    @MainActor
    func testUndoRemovesLastInputPerStage() {
        let m = HandEntryModel()
        m.selectPosition(.sb)
        _ = m.addCard(PlayingCard("Qd")!)
        m.undo()
        XCTAssertEqual(m.heroCards.count, 0)
        XCTAssertFalse(m.isCardDealt(PlayingCard("Qd")!))
        m.undo()
        XCTAssertEqual(m.stage, .position, "undo past cards returns to position")
        XCTAssertNil(m.heroPosition)
    }

    @MainActor
    func testNonHeroActionAndPotEstimate() {
        let m = HandEntryModel()
        m.selectPosition(.bb)
        _ = m.addCard(PlayingCard("9c")!)
        _ = m.addCard(PlayingCard("9d")!)
        m.actingPosition = .utg
        m.addAction(.raise, amount: 600)
        XCTAssertFalse(m.draftActions[0].isHero)
        m.actingPosition = .bb
        m.addAction(.call, amount: 600)
        // pot = sb+bb+bbAnte + action amounts = 100+200+200 + 600+600
        XCTAssertEqual(m.potEstimate(sb: 100, bb: 200, ante: 200), 1700)
    }

    @MainActor
    func testSaveSnapshotsTournamentContext() throws {
        let container = try makeInMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let t = Tournament(name: "Test", buyIn: 250)
        context.insert(t)
        t.fieldSize = 200
        t.playersRemaining = 88
        let level = BlindLevel(levelNumber: 9, smallBlind: 1000, bigBlind: 1500, ante: 1500)
        level.tournament = t
        context.insert(level)
        t.currentBlindLevelNumber = 9
        let entry = StackEntry(chipCount: 42_000, blindLevelNumber: 9, currentSB: 1000, currentBB: 1500, currentAnte: 1500)
        entry.tournament = t
        context.insert(entry)

        let m = HandEntryModel()
        m.selectPosition(.hj)
        _ = m.addCard(PlayingCard("Js")!)
        _ = m.addCard(PlayingCard("Jd")!)
        m.addAction(.raise, amount: 3300)
        m.finishHand()
        m.result = .won
        m.amountWon = 5100
        m.selectedTags = ["value bet"]

        let hand = m.save(into: context, tournament: t, cashSession: nil, seatsDefault: 9)
        try context.save()

        XCTAssertEqual(hand.levelNumber, 9)
        XCTAssertEqual(hand.smallBlind, 1000)
        XCTAssertEqual(hand.bigBlind, 1500)
        XCTAssertEqual(hand.heroStackChips, 42_000)
        XCTAssertEqual(hand.playersRemaining, 88)
        XCTAssertEqual(hand.heroCardsRaw, "Js Jd")
        XCTAssertEqual(hand.sortedActions.count, 1)
        XCTAssertEqual(hand.tags, ["value bet"])
        XCTAssertEqual(t.sortedHands.count, 1)
    }
}
```

- [ ] **Step 2: Run tests, verify compile failure** (`cannot find 'HandEntryModel'`).

- [ ] **Step 3: Create `StackTrackerPro/Managers/HandEntryModel.swift`:**

```swift
import Foundation
import SwiftData
import Observation

/// Pure state machine behind the hand-entry surface. Owns the staged flow
/// (position → hole cards → per-street actions/boards → result), dealt-card
/// tracking, undo, and the final save with live-session context snapshot.
/// UI-free so the whole flow is unit-testable.
@MainActor @Observable
final class HandEntryModel {

    enum Stage: Equatable {
        case position
        case holeCards
        case action(HandStreet)
        case boardCards(HandStreet)
        case result
    }

    struct DraftAction {
        let street: HandStreet
        let position: HeroPosition
        let type: HandActionType
        let amount: Int
        let isHero: Bool
    }

    static let presetTags = ["bluff", "value bet", "set mining", "squeeze",
                             "overbet", "hero call", "bad beat", "cooler"]

    private(set) var stage: Stage = .position
    private(set) var heroPosition: HeroPosition?
    private(set) var heroCards: [PlayingCard] = []
    private(set) var board: [PlayingCard] = []
    private(set) var draftActions: [DraftAction] = []

    /// Position the next action applies to; defaults to hero, user may retarget.
    var actingPosition: HeroPosition = .btn

    // Result-stage fields
    var result: HandResult?
    var potSize: Int = 0
    var amountWon: Int = 0
    var villainCards: [PlayingCard] = []
    var notes: String = ""
    var selectedTags: Set<String> = []

    /// Every input in order, for undo.
    private enum Input {
        case position
        case heroCard
        case boardCard(HandStreet)
        case action
        case streetAdvance(from: Stage)
        case finish(from: Stage)
    }
    private var inputLog: [Input] = []

    private var dealt: Set<PlayingCard> { Set(heroCards + board + villainCards) }

    // MARK: - Inputs

    func selectPosition(_ position: HeroPosition) {
        heroPosition = position
        actingPosition = position
        stage = .holeCards
        inputLog.append(.position)
    }

    func isCardDealt(_ card: PlayingCard) -> Bool { dealt.contains(card) }

    /// Adds a card to whichever collection the current stage needs.
    /// Returns false (no-op) for already-dealt cards or non-card stages.
    @discardableResult
    func addCard(_ card: PlayingCard) -> Bool {
        guard !isCardDealt(card) else { return false }
        switch stage {
        case .holeCards:
            heroCards.append(card)
            inputLog.append(.heroCard)
            if heroCards.count == 2 { stage = .action(.preflop) }
            return true
        case .boardCards(let street):
            board.append(card)
            inputLog.append(.boardCard(street))
            let needed = street == .flop ? 3 : (street == .turn ? 4 : 5)
            if board.count == needed { stage = .action(street) }
            return true
        default:
            return false
        }
    }

    func addAction(_ type: HandActionType, amount: Int = 0) {
        guard case .action(let street) = stage else { return }
        draftActions.append(DraftAction(
            street: street,
            position: actingPosition,
            type: type,
            amount: amount,
            isHero: actingPosition == heroPosition
        ))
        inputLog.append(.action)
    }

    /// From an action stage, moves to the next street's board entry.
    func advanceStreet() {
        guard case .action(let street) = stage else { return }
        let next: HandStreet? = switch street {
        case .preflop: .flop
        case .flop: .turn
        case .turn: .river
        case .river: nil
        }
        let previous = stage
        if let next {
            stage = .boardCards(next)
            inputLog.append(.streetAdvance(from: previous))
        } else {
            finishHand()
        }
    }

    /// Jumps to the result stage from anywhere past hole cards.
    func finishHand() {
        guard stage != .position, stage != .result, heroCards.count == 2 else { return }
        let previous = stage
        stage = .result
        inputLog.append(.finish(from: previous))
        // Hero folding is the most common ending — pre-select it.
        if result == nil,
           let lastHero = draftActions.last(where: { $0.isHero }),
           lastHero.type == .fold {
            result = .folded
        }
    }

    func undo() {
        guard let last = inputLog.popLast() else { return }
        switch last {
        case .position:
            heroPosition = nil
            stage = .position
        case .heroCard:
            _ = heroCards.popLast()
            stage = .holeCards
        case .boardCard(let street):
            _ = board.popLast()
            stage = .boardCards(street)
        case .action:
            _ = draftActions.popLast()
            // stage unchanged (still the same action stage)
        case .streetAdvance(let from), .finish(let from):
            stage = from
            result = nil
        }
    }

    // MARK: - Derived

    /// Rough pot: blinds + one big-blind ante + every recorded amount.
    /// An estimate by design — the result screen lets the user correct it.
    func potEstimate(sb: Int, bb: Int, ante: Int) -> Int {
        sb + bb + ante + draftActions.reduce(0) { $0 + $1.amount }
    }

    var timeline: String {
        draftActions.map { "\($0.position.rawValue) \($0.type.rawValue.lowercased())\($0.amount > 0 ? " \($0.amount.formatted())" : "")" }
            .joined(separator: " › ")
    }

    // MARK: - Save

    /// Persists the draft as a Hand, snapshotting live context from the
    /// session it belongs to. Exactly one of tournament/cashSession is set.
    func save(into context: ModelContext, tournament: Tournament?, cashSession: CashSession?, seatsDefault: Int) -> Hand {
        let hand = Hand(
            heroPosition: heroPosition ?? .btn,
            heroCardsRaw: PlayingCard.joinList(heroCards),
            levelNumber: tournament?.currentBlindLevelNumber ?? 0,
            smallBlind: tournament?.currentBlinds?.smallBlind ?? 0,
            bigBlind: tournament?.currentBlinds?.bigBlind ?? 0,
            ante: tournament?.currentBlinds?.ante ?? 0,
            heroStackChips: tournament?.latestStack?.chipCount ?? 0,
            playersRemaining: tournament?.playersRemaining ?? 0,
            tableSize: seatsDefault,
            stakes: cashSession?.stakes ?? ""
        )
        hand.boardRaw = PlayingCard.joinList(board)
        hand.resultRaw = (result ?? .folded).rawValue
        hand.potSize = potSize
        hand.amountWon = amountWon
        hand.villainCardsRaw = PlayingCard.joinList(villainCards)
        hand.notes = notes
        hand.tagsRaw = selectedTags.sorted().joined(separator: ",")
        hand.tournament = tournament
        hand.cashSession = cashSession
        context.insert(hand)

        for (index, draft) in draftActions.enumerated() {
            let action = HandAction(
                orderIndex: index, street: draft.street, position: draft.position,
                actionType: draft.type, amount: draft.amount, isHero: draft.isHero
            )
            action.hand = hand
            context.insert(action)
        }
        return hand
    }
}
```

- [ ] **Step 4: Wire into pbxproj** (same script pattern, IDs `7E570000000000000000010D`/`...010E`, Managers group anchor `778F8A5CCA605DF481933210 /* Managers */`).

- [ ] **Step 5: Run tests — all pass.** Note: `CashSession.stakes` exists (used by ResultsView BB/hr); confirm property name with `grep -n "var stakes" StackTrackerPro/Models/CashSession.swift` and adjust `save` if it differs.

- [ ] **Step 6: Commit** — `feat: hand entry state machine with undo and context snapshot`

---

### Task 3: Hand entry UI

**Files:**
- Create: `StackTrackerPro/Views/Session/HandEntryView.swift`
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (IDs `...010F`/`...0110`, Session group `5EC39F7F309606F34F39AA68`)

**Interfaces:**
- Consumes: `HandEntryModel` (Task 2), theme tokens.
- Produces: `struct HandEntryView: View` with `init(tournament: Tournament?, cashSession: CashSession?)` — presented as a sheet; saves via `HandEntryModel.save` on completion and dismisses.

- [ ] **Step 1: Create the view.** One file, several private subviews. Complete implementation:

```swift
import SwiftUI
import SwiftData

/// Staged, tap-only hand entry ("the keyboard"). Presented as a sheet from
/// an active tournament or cash session; context is snapshotted on save.
struct HandEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let tournament: Tournament?
    let cashSession: CashSession?

    @State private var model = HandEntryModel()
    @AppStorage(SettingsKeys.defaultSeatsPerTable) private var seatsDefault = 9

    var body: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    entryBar
                    Divider().background(Color.cardSurface)
                    stageSurface
                }
            }
            .navigationTitle("Log Hand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .foregroundColor(.goldAccent)
                    }
                    .accessibilityLabel("Undo last input")
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.stage != .position)
    }

    // MARK: - Entry bar (always visible: cards + timeline)

    private var entryBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let position = model.heroPosition {
                    Text(position.rawValue)
                        .font(PokerTypography.chipLabel)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.goldAccent.opacity(0.25))
                        .clipShape(Capsule())
                        .foregroundColor(.goldAccent)
                }
                ForEach(model.heroCards, id: \.self) { CardChip(card: $0) }
                if !model.board.isEmpty {
                    Text("|").foregroundColor(.textSecondary)
                    ForEach(model.board, id: \.self) { CardChip(card: $0) }
                }
                Spacer()
            }
            if !model.timeline.isEmpty {
                Text(model.timeline)
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
    }

    // MARK: - Stage surfaces

    @ViewBuilder
    private var stageSurface: some View {
        switch model.stage {
        case .position:
            positionPad
        case .holeCards:
            cardPicker(title: "Your hole cards")
        case .boardCards(let street):
            cardPicker(title: "\(street.label) card\(street == .flop ? "s" : "")")
        case .action(let street):
            actionPad(street: street)
        case .result:
            resultForm
        }
    }

    private var positionPad: some View {
        VStack(spacing: 16) {
            Text("Your position")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(HeroPosition.allCases, id: \.self) { position in
                    Button {
                        model.selectPosition(position)
                        HapticFeedback.impact(.light)
                    } label: {
                        Text(position.rawValue)
                            .font(PokerTypography.statValue)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(Color.cardSurface)
                            .foregroundColor(.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(.horizontal, 16)
            Spacer()
        }
        .padding(.top, 24)
    }

    private func cardPicker(title: String) -> some View {
        VStack(spacing: 14) {
            Text(title)
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
            RankSuitPicker { card in
                if model.addCard(card) { HapticFeedback.impact(.light) }
            } isDealt: { model.isCardDealt($0) }
            if case .action = model.stage {} else if model.heroCards.count == 2 {
                Button("Skip board, finish hand") { model.finishHand() }
                    .foregroundColor(.textSecondary)
            }
            Spacer()
        }
        .padding(.top, 24)
    }

    private func actionPad(street: HandStreet) -> some View {
        VStack(spacing: 14) {
            Text("\(street.label) action")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)

            // Acting position selector (hero highlighted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HeroPosition.allCases, id: \.self) { position in
                        let isActing = model.actingPosition == position
                        let isHero = model.heroPosition == position
                        Button {
                            model.actingPosition = position
                        } label: {
                            Text(position.rawValue)
                                .font(PokerTypography.chipLabel)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(isActing ? Color.goldAccent : Color.cardSurface)
                                .foregroundColor(isActing ? .backgroundPrimary : (isHero ? .goldAccent : .textPrimary))
                                .clipShape(Capsule())
                        }
                        .accessibilityLabel("\(position.rawValue)\(isHero ? ", you" : "")\(isActing ? ", acting" : "")")
                    }
                }
                .padding(.horizontal, 16)
            }

            ActionButtons { type, amount in
                model.addAction(type, amount: amount)
                HapticFeedback.impact(.light)
            } bigBlind: {
                tournament?.currentBlinds?.bigBlind ?? 0
            } potEstimate: {
                model.potEstimate(
                    sb: tournament?.currentBlinds?.smallBlind ?? 0,
                    bb: tournament?.currentBlinds?.bigBlind ?? 0,
                    ante: tournament?.currentBlinds?.ante ?? 0
                )
            }

            HStack(spacing: 12) {
                if street != .river {
                    Button {
                        model.advanceStreet()
                    } label: {
                        Text("Next Street")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.goldAccent)
                            .foregroundColor(.backgroundPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Button {
                    model.finishHand()
                } label: {
                    Text("Finish Hand")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.cardSurface)
                        .foregroundColor(.goldAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 16)
            Spacer()
        }
        .padding(.top, 24)
    }

    private var resultForm: some View {
        Form {
            Section("Result") {
                Picker("Outcome", selection: Binding(
                    get: { model.result ?? .folded },
                    set: { model.result = $0 }
                )) {
                    ForEach(HandResult.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Pot").foregroundColor(.textSecondary)
                    Spacer()
                    TextField("0", value: $model.potSize, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Net won/lost").foregroundColor(.textSecondary)
                    Spacer()
                    TextField("0", value: $model.amountWon, format: .number)
                        .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                }
            }
            Section("Tags") {
                FlowTags(all: HandEntryModel.presetTags, selected: $model.selectedTags)
            }
            Section("Notes") {
                TextField("Optional note", text: $model.notes, axis: .vertical).lineLimit(2...4)
            }
            Section {
                Button {
                    _ = model.save(into: modelContext,
                                   tournament: tournament,
                                   cashSession: cashSession,
                                   seatsDefault: seatsDefault)
                    try? modelContext.save()
                    HapticFeedback.success()
                    dismiss()
                } label: {
                    Text("Save Hand")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.goldAccent)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            if model.potSize == 0 {
                model.potSize = model.potEstimate(
                    sb: tournament?.currentBlinds?.smallBlind ?? 0,
                    bb: tournament?.currentBlinds?.bigBlind ?? 0,
                    ante: tournament?.currentBlinds?.ante ?? 0
                )
            }
        }
    }
}

// MARK: - Components

private struct CardChip: View {
    let card: PlayingCard
    var body: some View {
        Text(card.display)
            .font(PokerTypography.statValue)
            .foregroundColor(card.isRed ? .red : .textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.backgroundPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct RankSuitPicker: View {
    let onCard: (PlayingCard) -> Void
    let isDealt: (PlayingCard) -> Bool

    @State private var pendingRank: Character?

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(PlayingCard.ranks, id: \.self) { rank in
                    Button {
                        pendingRank = rank
                        HapticFeedback.impact(.light)
                    } label: {
                        Text(String(rank))
                            .font(PokerTypography.statValue)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(pendingRank == rank ? Color.goldAccent : Color.cardSurface)
                            .foregroundColor(pendingRank == rank ? .backgroundPrimary : .textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(PlayingCard.suits, id: \.self) { suit in
                    let card = pendingRank.flatMap { PlayingCard(rank: $0, suit: suit) }
                    let disabled = card == nil || (card.map(isDealt) ?? true)
                    Button {
                        if let card { onCard(card); pendingRank = nil }
                    } label: {
                        Text(PlayingCard(rank: "A", suit: suit)!.suitSymbol)
                            .font(.system(size: 28))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.cardSurface)
                            .foregroundColor(suit == "h" || suit == "d" ? .red : .textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .opacity(disabled ? 0.3 : 1)
                    }
                    .disabled(disabled)
                    .accessibilityLabel("Suit \(PlayingCard(rank: "A", suit: suit)!.suitSymbol)")
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct ActionButtons: View {
    let onAction: (HandActionType, Int) -> Void
    let bigBlind: () -> Int
    let potEstimate: () -> Int

    @State private var pendingSize = 0
    @State private var showSizeEntry = false
    @State private var pendingType: HandActionType?

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(HandActionType.allCases, id: \.self) { type in
                    Button {
                        switch type {
                        case .fold, .check:
                            onAction(type, 0)
                        case .call, .bet, .raise, .allIn:
                            pendingType = type
                            pendingSize = 0
                            showSizeEntry = true
                        }
                    } label: {
                        Text(type.rawValue)
                            .font(PokerTypography.statValue)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.cardSurface)
                            .foregroundColor(.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .alert("Amount", isPresented: $showSizeEntry) {
            TextField("Chips", value: $pendingSize, format: .number)
                .keyboardType(.numberPad)
            Button("2.5x BB") { commit(bigBlind() * 5 / 2) }
            Button("Pot") { commit(potEstimate()) }
            Button("OK") { commit(pendingSize) }
            Button("Cancel", role: .cancel) { pendingType = nil }
        } message: {
            Text("Enter the amount, or use a quick size.")
        }
    }

    private func commit(_ amount: Int) {
        if let type = pendingType { onAction(type, max(0, amount)) }
        pendingType = nil
    }
}

private struct FlowTags: View {
    let all: [String]
    @Binding var selected: Set<String>

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            ForEach(all, id: \.self) { tag in
                let isOn = selected.contains(tag)
                Button {
                    if isOn { selected.remove(tag) } else { selected.insert(tag) }
                } label: {
                    Text(tag)
                        .font(PokerTypography.chipLabel)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(isOn ? Color.goldAccent.opacity(0.3) : Color.cardSurface)
                        .foregroundColor(isOn ? .goldAccent : .textPrimary)
                        .clipShape(Capsule())
                }
            }
        }
    }
}
```

- [ ] **Step 2: Wire into pbxproj** (IDs `...010F`/`...0110`, Session group anchor `5EC39F7F309606F34F39AA68 /* Session */`).

- [ ] **Step 3: Build** (not test — no new unit tests in this task; the state machine is already covered): expect `BUILD SUCCEEDED`. If `SettingsKeys.defaultSeatsPerTable` or `HapticFeedback.impact` signatures differ, check usages in `TournamentMetricsView.swift` and match.

- [ ] **Step 4: Commit** — `feat: staged hand entry surface (position, cards, actions, result)`

---

### Task 4: HandsPane — session hand list, stats header, detail view

**Files:**
- Create: `StackTrackerPro/Views/Session/HandsPane.swift`
- Modify: `StackTrackerProTests/StackTrackerProTests.swift` (VPIP/PFR tests)
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (IDs `...0111`/`...0112`, Session group)

**Interfaces:**
- Consumes: `Hand` (Task 1), `HandEntryView` (Task 3).
- Produces: `struct HandsPane: View` `init(tournament: Tournament?, cashSession: CashSession?, isReadOnly: Bool)`; `enum HandStats { static func vpipPercent(_ hands: [Hand]) -> Double; static func pfrPercent(_ hands: [Hand]) -> Double }` (defined in HandsPane.swift).

- [ ] **Step 1: Write the failing stats tests:**

```swift
// MARK: - Hand stats

final class HandStatsTests: XCTestCase {

    @MainActor
    private func hand(preflop: [(HandActionType, Bool)]) throws -> Hand {
        let h = Hand()
        h.actions = []
        for (i, (type, isHero)) in preflop.enumerated() {
            let a = HandAction(orderIndex: i, street: .preflop, position: .btn,
                               actionType: type, amount: 0, isHero: isHero)
            h.actions?.append(a)
        }
        return h
    }

    @MainActor
    func testVPIPAndPFR() throws {
        let container = try makeInMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        // Insert so relationships resolve
        let raised = try hand(preflop: [(.raise, true)])           // VPIP + PFR
        let called = try hand(preflop: [(.raise, false), (.call, true)]) // VPIP only
        let folded = try hand(preflop: [(.fold, true)])            // neither
        let checked = try hand(preflop: [(.check, true)])          // neither (BB check)
        for h in [raised, called, folded, checked] { container.mainContext.insert(h) }

        let hands = [raised, called, folded, checked]
        XCTAssertEqual(HandStats.vpipPercent(hands), 50.0)
        XCTAssertEqual(HandStats.pfrPercent(hands), 25.0)
        XCTAssertEqual(HandStats.vpipPercent([]), 0)
    }
}
```

- [ ] **Step 2: Run — compile failure** (`cannot find 'HandStats'`).

- [ ] **Step 3: Create `StackTrackerPro/Views/Session/HandsPane.swift`:**

```swift
import SwiftUI
import SwiftData

/// Session-level VPIP/PFR from structured hands. Pure, unit-tested.
enum HandStats {
    static func vpipPercent(_ hands: [Hand]) -> Double {
        guard !hands.isEmpty else { return 0 }
        let vpip = hands.filter { hand in
            hand.heroPreflopActions.contains { $0.actionType.isVoluntaryChips }
        }.count
        return Double(vpip) / Double(hands.count) * 100
    }

    static func pfrPercent(_ hands: [Hand]) -> Double {
        guard !hands.isEmpty else { return 0 }
        let pfr = hands.filter { hand in
            hand.heroPreflopActions.contains { $0.actionType == .raise || $0.actionType == .allIn }
        }.count
        return Double(pfr) / Double(hands.count) * 100
    }
}

/// Pager pane listing the session's structured hands, with a Log Hand
/// entry point and read-only detail.
struct HandsPane: View {
    let tournament: Tournament?
    let cashSession: CashSession?
    let isReadOnly: Bool

    @State private var showEntry = false

    private var hands: [Hand] {
        tournament?.sortedHands ?? cashSession?.sortedHands ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            statsHeader
            if hands.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(hands.reversed(), id: \.persistentModelID) { hand in
                        NavigationLink {
                            HandDetailView(hand: hand)
                        } label: {
                            HandRow(hand: hand)
                        }
                        .listRowBackground(Color.cardSurface)
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
            if !isReadOnly {
                Button {
                    showEntry = true
                } label: {
                    Label("Log Hand", systemImage: "suit.spade.fill")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.goldAccent)
                        .foregroundColor(.backgroundPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(12)
            }
        }
        .sheet(isPresented: $showEntry) {
            HandEntryView(tournament: tournament, cashSession: cashSession)
        }
    }

    private var statsHeader: some View {
        HStack(spacing: 16) {
            stat("Hands", "\(hands.count)")
            stat("VPIP", hands.isEmpty ? "---" : String(format: "%.0f%%", HandStats.vpipPercent(hands)))
            stat("PFR", hands.isEmpty ? "---" : String(format: "%.0f%%", HandStats.pfrPercent(hands)))
        }
        .padding(12)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(PokerTypography.chipLabel).foregroundColor(.textSecondary)
            Text(value).font(PokerTypography.statValue).foregroundColor(.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "suit.spade")
                .font(.system(size: 40)).foregroundColor(.textSecondary)
                .accessibilityHidden(true)
            Text("No hands logged yet")
                .font(PokerTypography.chipLabel).foregroundColor(.textSecondary)
            Spacer()
        }
    }
}

private struct HandRow: View {
    let hand: Hand

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(hand.heroPosition.rawValue)
                    .font(PokerTypography.chipLabel).foregroundColor(.goldAccent)
                ForEach(hand.heroCards, id: \.self) { card in
                    Text(card.display)
                        .font(PokerTypography.statValue)
                        .foregroundColor(card.isRed ? .red : .textPrimary)
                }
                Spacer()
                Text(hand.result.rawValue)
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(hand.result == .won ? .green : (hand.result == .lost ? .red : .textSecondary))
            }
            HStack {
                Text(hand.timestamp.formatted(date: .omitted, time: .shortened))
                if !hand.blindsDisplay.isEmpty { Text("· \(hand.blindsDisplay)") }
                if hand.amountWon != 0 {
                    Text("· \(hand.amountWon > 0 ? "+" : "")\(hand.amountWon.formatted())")
                }
            }
            .font(PokerTypography.chatCaption)
            .foregroundColor(.textSecondary)
        }
    }
}

struct HandDetailView: View {
    let hand: Hand

    var body: some View {
        ZStack {
            Color.backgroundPrimary.ignoresSafeArea()
            List {
                Section("Context") {
                    row("Position", hand.heroPosition.rawValue)
                    if hand.levelNumber > 0 { row("Level", "\(hand.levelNumber)") }
                    if !hand.blindsDisplay.isEmpty { row("Blinds", hand.blindsDisplay) }
                    if hand.heroStackChips > 0 { row("Stack", hand.heroStackChips.formatted()) }
                    if hand.playersRemaining > 0 { row("Players left", "\(hand.playersRemaining)") }
                }
                Section("Cards") {
                    row("Hole cards", hand.heroCards.map(\.display).joined(separator: " "))
                    if !hand.board.isEmpty {
                        row("Board", hand.board.map(\.display).joined(separator: " "))
                    }
                    if !hand.villainCards.isEmpty {
                        row("Villain", hand.villainCards.map(\.display).joined(separator: " "))
                    }
                }
                ForEach(HandStreet.allCases, id: \.self) { street in
                    let actions = hand.sortedActions.filter { $0.street == street }
                    if !actions.isEmpty {
                        Section(street.label) {
                            ForEach(actions, id: \.persistentModelID) { action in
                                HStack {
                                    Text(action.timelineDescription)
                                        .foregroundColor(action.isHero ? .goldAccent : .textPrimary)
                                    Spacer()
                                    if action.isHero {
                                        Text("you").font(PokerTypography.chatCaption).foregroundColor(.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
                Section("Result") {
                    row("Outcome", hand.result.rawValue)
                    if hand.potSize > 0 { row("Pot", hand.potSize.formatted()) }
                    if hand.amountWon != 0 { row("Net", hand.amountWon.formatted()) }
                    if !hand.tags.isEmpty { row("Tags", hand.tags.joined(separator: ", ")) }
                    if !hand.notes.isEmpty { row("Notes", hand.notes) }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Hand")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.textSecondary)
            Spacer()
            Text(value).foregroundColor(.textPrimary).multilineTextAlignment(.trailing)
        }
        .listRowBackground(Color.cardSurface)
    }
}
```

- [ ] **Step 4: Add `sortedHands` to CashSession if Task 1 missed it; wire pbxproj; run full suite — stats tests pass, build green.**

- [ ] **Step 5: Commit** — `feat: session hands pane with VPIP/PFR and hand detail`

---

### Task 5: Wire into session screens

**Files:**
- Modify: `StackTrackerPro/Views/Session/ActiveSessionView.swift` (TabView pages ~lines 27-64 + `pageIndicator`)
- Modify: `StackTrackerPro/Views/CashGame/CashActiveSessionView.swift` (same pattern)

**Interfaces:**
- Consumes: `HandsPane` (Task 4).

- [ ] **Step 1: Add the page.** In `ActiveSessionView`'s `TabView`, after the existing `HandNotesPane` page (find its `.tag(n)`), insert:

```swift
                HandsPane(
                    tournament: tournament,
                    cashSession: nil,
                    isReadOnly: tournament.status == .completed
                )
                .tag(N)   // next free index; renumber subsequent tags
```

Adjust every later `.tag(...)` and the `pageIndicator` dot count/labels to match (grep `pageCount` or the `ForEach` driving the dots; also update the accessibility "Page N of M" values if present).

- [ ] **Step 2: Same for `CashActiveSessionView`** with `tournament: nil, cashSession: session, isReadOnly: session.status == .completed` (match the cash view's status enum — grep `status == .completed` in that file for the exact spelling).

- [ ] **Step 3: Build; run the full test suite** (guards against tag mishaps breaking compile). Manually verify in simulator if convenient: `xcrun simctl` boot + install per memory notes, swipe to the Hands page, log a test hand end-to-end.

- [ ] **Step 4: Commit** — `feat: hands pane wired into tournament and cash session pagers`

---

### Task 6: Recap export includes structured hands

**Files:**
- Modify: `StackTrackerPro/Managers/TournamentRecapExporter.swift`
- Modify: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Consumes: `Hand`/`HandAction` (Task 1).
- Produces: a `## Structured Hands` section in `TournamentRecapExporter.markdown(for:)`, placed between the Hand Notes and Chat Transcript sections; prompt header updated to mention it.

- [ ] **Step 1: Failing test** — extend `TournamentRecapExporterTests.testMarkdownContainsAllSectionsAndData`: after the existing hand-note setup add:

```swift
        let hand = Hand(heroPosition: .btn, heroCardsRaw: "As Kh",
                        levelNumber: 2, smallBlind: 200, bigBlind: 300, ante: 300,
                        heroStackChips: 55_000, playersRemaining: 100, tableSize: 9)
        hand.timestamp = base.addingTimeInterval(2500)
        hand.boardRaw = "Ah 7d 2c"
        hand.resultRaw = HandResult.won.rawValue
        hand.amountWon = 4200
        hand.tournament = t
        context.insert(hand)
        let act = HandAction(orderIndex: 0, street: .preflop, position: .btn,
                             actionType: .raise, amount: 900, isHero: true)
        act.hand = hand
        context.insert(act)
```

and assertions:

```swift
        XCTAssertTrue(markdown.contains("## Structured Hands"))
        XCTAssertTrue(markdown.contains("A♠ K♥"))
        XCTAssertTrue(markdown.contains("BTN raise 900"))
```

- [ ] **Step 2: Run — assertion failure** (section missing).

- [ ] **Step 3: Implement.** In `markdown(for:)` insert `sections.append(structuredHandsSection(for: tournament))` before the chat transcript line, and add:

```swift
    private static func structuredHandsSection(for tournament: Tournament) -> String {
        var lines: [String] = ["## Structured Hands", ""]
        let hands = tournament.sortedHands
        guard !hands.isEmpty else {
            lines.append("_No structured hands logged._")
            return lines.joined(separator: "\n")
        }
        for (index, hand) in hands.enumerated() {
            var header = "### Hand \(index + 1) — \(stamp(hand.timestamp)) — \(hand.heroPosition.rawValue)"
            header += " — \(hand.heroCards.map(\.display).joined(separator: " "))"
            lines.append(header)
            var context = "Blinds \(hand.blindsDisplay)"
            if hand.levelNumber > 0 { context = "Level \(hand.levelNumber), " + context }
            if hand.heroStackChips > 0 { context += ", stack \(hand.heroStackChips.formatted())" }
            if hand.playersRemaining > 0 { context += ", \(hand.playersRemaining) left" }
            lines.append(context)
            if !hand.board.isEmpty {
                lines.append("Board: \(hand.board.map(\.display).joined(separator: " "))")
            }
            for street in HandStreet.allCases {
                let actions = hand.sortedActions.filter { $0.street == street }
                if !actions.isEmpty {
                    lines.append("- \(street.label): " + actions.map(\.timelineDescription).joined(separator: " › "))
                }
            }
            var result = "Result: \(hand.result.rawValue)"
            if hand.potSize > 0 { result += ", pot \(hand.potSize.formatted())" }
            if hand.amountWon != 0 { result += ", net \(hand.amountWon.formatted())" }
            lines.append(result)
            if !hand.villainCards.isEmpty { lines.append("Villain: \(hand.villainCards.map(\.display).joined(separator: " "))") }
            if !hand.tags.isEmpty { lines.append("Tags: \(hand.tags.joined(separator: ", "))") }
            if !hand.notes.isEmpty { lines.append("Note: \(hand.notes)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
```

Also extend the prompt header's item (5): change "using the timeline and hand notes" to "using the timeline, hand notes, and the street-by-street Structured Hands".

- [ ] **Step 4: Run full suite — green.**

- [ ] **Step 5: Commit** — `feat: structured hands in the AI recap export`

---

### Task 7: Final verification

- [ ] **Step 1:** Full test suite — all green (expect ~70 tests).
- [ ] **Step 2:** Release build: `xcodebuild ... -configuration Release build` — `BUILD SUCCEEDED`.
- [ ] **Step 3:** Simulator smoke test: boot iPhone Air (26.5), install Debug build, start a tournament, log one full hand (position → cards → raise → flop → finish → save), confirm it appears in the Hands pane and in an exported recap file.
- [ ] **Step 4:** Commit any fixes; push.
