# Hand Logging v2 — "Capture Now, Enrich Later" Implementation Plan

> **STATUS: EXECUTED 2026-07-09** (commits 27f8deb..b0289cd, all 17 tasks complete, final review READY TO MERGE; voice = future plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the staged hand-entry flow with a two-surface system: 5-second Hand Stubs at the table (manual, chat shorthand, swing-detected, break-debrief) plus a full Hand Capture Screen for enrichment — computing everything the app already knows (street, pot, turn order, winner, stack-after) instead of asking for it.

**Architecture:** New `HandStub` / `FadeNote` / `HandVillain` SwiftData models hang off `Tournament` / `Hand`. Capture logic lives in UI-free `@Observable` engines (`HandCaptureModel`, plus pure helpers `HoleCardShorthand`, `SwingDetector`, `BreakDebriefEngine`, `PokerHandEvaluator`) mirroring the existing `HandEntryModel` testability pattern. Chat integration happens in `ChatManager.processUserMessage` (shorthand intercept, swing prompt, debrief Q&A). The old `HandEntryView`/`HandEntryModel` are deleted once `HandCaptureView` replaces them.

**Tech Stack:** SwiftUI, SwiftData (+CloudKit private DB), XCTest. No new dependencies.

**Out of scope (separate future plan):** Feature 4 voice dictation (needs the OnCall Scribe codebase port) and the F5.3 hybrid-dictation mic. The Capture Screen ships tap-only; the mic button slot is left out until that plan.

## Global Constraints

- **CloudKit model rules:** every attribute has a default value; every relationship is optional; to-many relationships declared as optional arrays with `@Relationship(deleteRule:inverse:)` on the parent side (mirror how `Tournament.hands` ↔ `Hand.tournament` is declared in `StackTrackerPro/Models/Tournament.swift`).
- **Schema registration:** every new `@Model` must be added to BOTH `StackTrackerPro/App/StackTrackerProApp.swift` (`Schema([...])`, starts line 18) and `StackTrackerProTests/StackTrackerProTests.swift` `makeInMemoryContainer()` (starts line 8). Miss one and tests crash at container creation.
- **pbxproj:** new files are hand-wired. Four entries per file: PBXBuildFile (~line 31), PBXFileReference (~line 148), group children (Models ~line 342, Managers ~line 284, Views/Session ~line 259, Views/Components near other component files), Sources build phase (~line 552). IDs are 24-hex; continue the existing sequence from `7E5700000000000000000113` upward (0101–0112 are taken). Pattern per file:
  ```
  7E57...N+1 /* X.swift in Sources */ = {isa = PBXBuildFile; fileRef = 7E57...N /* X.swift */; };
  7E57...N /* X.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = X.swift; sourceTree = "<group>"; };
  ```
- **Test command:** `xcodebuild test -project StackTrackerPro.xcodeproj -scheme StackTrackerPro -destination 'platform=iOS Simulator,name=iPhone Air,OS=26.5'` (append `-only-testing:StackTrackerProTests/StackTrackerProTests/<testName>` for a single test). Build-only check: same but `build`.
- **Commits:** direct to `main`, message trailer `Co-Authored-By: Claude <model> <noreply@anthropic.com>`.
- **No blind-level clock features** — the user has explicitly declined level countdown timers.
- **Never ask the user for computed data** (spec "Inference Requirements"): street, pot, players-in-hand, whose turn, winner, hero stack-after, level/blinds, hero stack-before, timestamp. Any UI collecting these is a bug.
- **Before App Store release** (not part of this plan's tasks, but required): exercise every new model + new field with non-nil relationships in a dev build, then deploy the CloudKit schema to Production via Console (see memory: stacktrackerpro-build-setup).

## Existing Interfaces (reference — verified 2026-07-08)

- `TournamentManager` (`StackTrackerPro/Managers/TournamentManager.swift`): `var activeTournament: Tournament?` (line 11), `var modelContext: ModelContext?` (14), `func updateStack(chipCount: Int)` (141), `func updateBlinds(...)` (158), `func startBreak(tableNumber:seatNumber:chipCount:duration:photoData:)` (396), `private func save()` (502), `private func logEvent(_:value:on:)` (130).
- `Tournament` (`StackTrackerPro/Models/Tournament.swift`): `currentBlindLevelNumber: Int` (45), `playersRemaining: Int` (47), `hands: [Hand]?` (83), `sortedHands` (174), `currentDisplayLevel: Int?` (203), `latestStack: StackEntry?` (207), `currentBlinds: BlindLevel?` (211), `averageStack: Int` (223), `status: TournamentStatus` (144), `sortedStackEntries`, `gameType`.
- `ChatManager.processUserMessage(text:)` (`StackTrackerPro/Managers/ChatManager.swift:32`): saves user msg → `parseMessage` → `applyEntities` → `responseEngine.generateResponse` → AI msg → `saveContext()`.
- `ParsedEntities` (`StackTrackerPro/Managers/RegexPokerParser.swift:3`): `chipCount`, `smallBlind`, `bigBlind`, `ante`, `levelNumber`, `totalEntries`, `playersRemaining`, `finishPosition`, `payoutAmount`, `bountyCollected`, `tookRebuy`, `isEliminated`, `handNote`.
- `Hand` / `HandAction` / `PlayingCard` / `HeroPosition` / `HandStreet` / `HandActionType` / `HandResult` (`StackTrackerPro/Models/Hand.swift`). `PlayingCard.parseList/joinList` use space-separated "Ah Kd".
- `ChatInputView` (`StackTrackerPro/Views/Session/ChatInputView.swift`): `@Binding var text`, `let isProcessing: Bool`, `let onSend: () -> Void`, `let onQuickAction: (QuickAction) -> Void`.
- `ActiveSessionView` (`StackTrackerPro/Views/Session/ActiveSessionView.swift`): `TabView(selection:)` panes tags 0–8; HandsPane at tag 6 (`HandsPane(tournament:cashSession:isReadOnly:)`); `ChatInputView` at bottom (line ~78).
- `HandsPane` (`StackTrackerPro/Views/Session/HandsPane.swift`): `@State showEntry` presents `HandEntryView` via `.sheet` (line 50); `HandRow`, `HandDetailView`.
- `TournamentRecapExporter` (`StackTrackerPro/Managers/TournamentRecapExporter.swift`): `markdown(for:)` assembles sections; `handNotesSection` (208), `structuredHandsSection` (225), timeline rows around line 175. Tests call `TournamentRecapExporter.markdown(for:)` (test line 866).
- `SettingsKeys` (`StackTrackerPro/Views/Settings/SettingsView.swift:7`).
- Test helper: `makeManagerAndTournament()` (`StackTrackerProTests/StackTrackerProTests.swift:1105`) returns `(TournamentManager, Tournament, ModelContainer)`.

---

# Phase A — Capture safety net (Features 1, 2, 6)

### Task 1: HandStub + FadeNote models, schema, project wiring

**Files:**
- Create: `StackTrackerPro/Models/HandStub.swift`
- Create: `StackTrackerPro/Models/FadeNote.swift`
- Modify: `StackTrackerPro/Models/Tournament.swift` (add two relationships + `pendingStubs`)
- Modify: `StackTrackerPro/Models/Hand.swift` (add `sourceStub`)
- Modify: `StackTrackerPro/App/StackTrackerProApp.swift:18` (schema)
- Modify: `StackTrackerProTests/StackTrackerProTests.swift:10` (test schema)
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (wire 2 files, IDs 0113–0116)
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces: `HandStub` (`createdAt: Date`, `levelNumber/smallBlind/bigBlind/ante/heroStackBefore/heroStackAfter/playersRemaining: Int`, `holeCards: String`, `quickResultRaw/quickVillainRaw/originRaw/statusRaw: String`, `tournament: Tournament?`, `enrichedHand: Hand?`, computed `origin: StubOrigin`, `status: StubStatus`, `quickResult: QuickResult?`, `quickVillain: QuickVillain?`, `setStatus(_:)`), `FadeNote` (`intervalStart/intervalEnd: Date`, `chipDelta: Int`, `userExplanation: String`, `tournament: Tournament?`), `Tournament.handStubs: [HandStub]?`, `Tournament.fadeNotes: [FadeNote]?`, `Tournament.pendingStubs: [HandStub]`, `Hand.sourceStub: HandStub?`.

- [ ] **Step 1: Write the failing test** (append to `StackTrackerProTests.swift`)

```swift
func testHandStubPersistsWithContextAndStatus() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let t = Tournament(name: "Stub Test", venue: "Test", buyIn: 100)
    context.insert(t)

    let stub = HandStub(
        levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000, ante: 25_000,
        heroStackBefore: 390_000, playersRemaining: 43,
        holeCards: "KQs", origin: .manual
    )
    stub.quickResultRaw = QuickResult.won.rawValue
    stub.quickVillainRaw = QuickVillain.covered.rawValue
    stub.tournament = t
    context.insert(stub)

    let fade = FadeNote(intervalStart: .now, intervalEnd: .now, chipDelta: -340_000,
                        userExplanation: "blinds and a few small ones")
    fade.tournament = t
    context.insert(fade)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<HandStub>()).first
    XCTAssertEqual(fetched?.holeCards, "KQs")
    XCTAssertEqual(fetched?.origin, .manual)
    XCTAssertEqual(fetched?.status, .pending)
    XCTAssertEqual(fetched?.quickResult, .won)
    XCTAssertEqual(fetched?.quickVillain, .covered)
    XCTAssertEqual(fetched?.heroStackBefore, 390_000)
    XCTAssertEqual(t.pendingStubs.count, 1)
    XCTAssertEqual(t.fadeNotes?.count, 1)

    fetched?.setStatus(.dismissed)
    XCTAssertTrue(t.pendingStubs.isEmpty)
}
```

(Use the same `Tournament` initializer arguments the neighboring tests use — check `makeManagerAndTournament()` at line 1105 and mirror it.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:StackTrackerProTests/StackTrackerProTests/testHandStubPersistsWithContextAndStatus`
Expected: BUILD FAILURE — `cannot find 'HandStub' in scope`.

- [ ] **Step 3: Create `StackTrackerPro/Models/HandStub.swift`**

```swift
import Foundation
import SwiftData

enum StubOrigin: String, CaseIterable {
    case manual, swingDetected, breakDebrief
}

enum StubStatus: String, CaseIterable {
    case pending, enriched, dismissed
}

enum QuickResult: String, CaseIterable {
    case won = "Won", lost = "Lost", chopped = "Chopped"
}

enum QuickVillain: String, CaseIterable {
    case shorter = "vs shorter", covered = "vs covered"
}

/// A 5-second capture of a hand's existence: auto-filled session context plus
/// the hero's hole cards. Enriched into a full Hand later (Capture Screen).
@Model
final class HandStub {
    var createdAt: Date = Date.now
    var levelNumber: Int = 0
    var smallBlind: Int = 0
    var bigBlind: Int = 0
    var ante: Int = 0
    var heroStackBefore: Int = 0      // 0 = unknown
    var heroStackAfter: Int = 0       // 0 = unknown; filled by enrichment
    var playersRemaining: Int = 0
    /// "Ah Kd" (exact), "KQs"/"AKo"/"99" (suit-agnostic), "" = awaiting cards
    var holeCards: String = ""
    var quickResultRaw: String = ""
    var quickVillainRaw: String = ""
    var originRaw: String = StubOrigin.manual.rawValue
    var statusRaw: String = StubStatus.pending.rawValue

    var tournament: Tournament?
    @Relationship(inverse: \Hand.sourceStub)
    var enrichedHand: Hand?

    init(levelNumber: Int = 0, smallBlind: Int = 0, bigBlind: Int = 0, ante: Int = 0,
         heroStackBefore: Int = 0, playersRemaining: Int = 0,
         holeCards: String = "", origin: StubOrigin = .manual) {
        self.levelNumber = levelNumber
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
        self.ante = ante
        self.heroStackBefore = heroStackBefore
        self.playersRemaining = playersRemaining
        self.holeCards = holeCards
        self.originRaw = origin.rawValue
    }

    var origin: StubOrigin { StubOrigin(rawValue: originRaw) ?? .manual }
    var status: StubStatus { StubStatus(rawValue: statusRaw) ?? .pending }
    var quickResult: QuickResult? { QuickResult(rawValue: quickResultRaw) }
    var quickVillain: QuickVillain? { QuickVillain(rawValue: quickVillainRaw) }

    func setStatus(_ status: StubStatus) { statusRaw = status.rawValue }

    var blindsDisplay: String {
        guard bigBlind > 0 else { return "" }
        var s = "\(smallBlind.formatted())/\(bigBlind.formatted())"
        if ante > 0 { s += "(\(ante.formatted()))" }
        return s
    }

    /// One-line recap export form: "L21 — KQs — Won vs covered (unenriched)"
    var exportLine: String {
        var parts: [String] = []
        parts.append(levelNumber > 0 ? "L\(levelNumber)" : "—")
        parts.append(holeCards.isEmpty ? "cards unknown" : holeCards)
        var result = quickResult?.rawValue ?? ""
        if let v = quickVillain { result += result.isEmpty ? v.rawValue : " \(v.rawValue)" }
        if !result.isEmpty { parts.append(result) }
        return parts.joined(separator: " — ") + " (unenriched)"
    }
}
```

- [ ] **Step 4: Create `StackTrackerPro/Models/FadeNote.swift`**

```swift
import Foundation
import SwiftData

/// A break-debrief explanation for a stack delta that was NOT a single hand
/// ("card dead, paid blinds, lost two small pots"). Lets the recap narrative
/// state fades authoritatively without inventing hands.
@Model
final class FadeNote {
    var createdAt: Date = Date.now
    var intervalStart: Date = Date.now
    var intervalEnd: Date = Date.now
    var chipDelta: Int = 0
    var userExplanation: String = ""
    var tournament: Tournament?

    init(intervalStart: Date = .now, intervalEnd: Date = .now,
         chipDelta: Int = 0, userExplanation: String = "") {
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.chipDelta = chipDelta
        self.userExplanation = userExplanation
    }
}
```

- [ ] **Step 5: Wire relationships**

In `Tournament.swift`, next to the existing `hands` relationship (line ~83), following the exact same `@Relationship` style used there:

```swift
@Relationship(deleteRule: .cascade, inverse: \HandStub.tournament)
var handStubs: [HandStub]? = []

@Relationship(deleteRule: .cascade, inverse: \FadeNote.tournament)
var fadeNotes: [FadeNote]? = []
```

And with the other computed accessors (near `sortedHands`, line ~174):

```swift
var pendingStubs: [HandStub] {
    (handStubs ?? [])
        .filter { $0.status == .pending }
        .sorted { $0.createdAt < $1.createdAt }
}

var sortedFadeNotes: [FadeNote] {
    (fadeNotes ?? []).sorted { $0.intervalStart < $1.intervalStart }
}
```

In `Hand.swift`, next to `var tournament: Tournament?` (line ~109):

```swift
var sourceStub: HandStub?
```

- [ ] **Step 6: Register schema in BOTH lists** — add `HandStub.self, FadeNote.self,` after `HandAction.self` in `StackTrackerProApp.swift` and in `makeInMemoryContainer()`.

- [ ] **Step 7: Wire pbxproj** — HandStub.swift (fileRef `7E5700000000000000000113`, buildFile `...0114`), FadeNote.swift (fileRef `...0115`, buildFile `...0116`); add both to the Models group children (next to `Hand.swift`, line ~342) and Sources phase (~552).

- [ ] **Step 8: Run test to verify it passes**

Run: the Step 2 command. Expected: PASS.

- [ ] **Step 9: Run the FULL suite** (schema changes can break unrelated container setup): `xcodebuild test ...` Expected: all pass (68 existing + 1 new).

- [ ] **Step 10: Commit** — `feat: HandStub and FadeNote models for hand logging v2`

---

### Task 2: Hole-card shorthand parser

**Files:**
- Create: `StackTrackerPro/Managers/HoleCardShorthand.swift`
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (IDs 0117–0118, Managers group ~line 284)
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces: `enum HoleCardShorthand` with `static func normalize(_ raw: String) -> String?` (returns storage form: exact `"Ah Kd"`, or suit-agnostic `"KQs"`/`"AKo"`/`"99"`/`"KQ"`; nil if not confidently a holding), `static func isExact(_ stored: String) -> Bool`, `static func exactCards(_ stored: String) -> [PlayingCard]` (empty unless exact), `static func display(_ stored: String) -> String` ("A♥ K♦" or the agnostic token verbatim).

- [ ] **Step 1: Write failing tests**

```swift
func testHoleCardShorthandNormalization() {
    // Exact
    XCTAssertEqual(HoleCardShorthand.normalize("AhKd"), "Ah Kd")
    XCTAssertEqual(HoleCardShorthand.normalize("ah kd"), "Ah Kd")
    XCTAssertEqual(HoleCardShorthand.normalize("KS QS"), "Ks Qs")
    // Suit-agnostic
    XCTAssertEqual(HoleCardShorthand.normalize("KQs"), "KQs")
    XCTAssertEqual(HoleCardShorthand.normalize("ako"), "AKo")
    XCTAssertEqual(HoleCardShorthand.normalize("99"), "99")
    XCTAssertEqual(HoleCardShorthand.normalize("kq"), "KQ")
    // Spoken-ish
    XCTAssertEqual(HoleCardShorthand.normalize("AK suited"), "AKs")
    XCTAssertEqual(HoleCardShorthand.normalize("ace king suited"), "AKs")
    XCTAssertEqual(HoleCardShorthand.normalize("pocket nines"), "99")
    XCTAssertEqual(HoleCardShorthand.normalize("queen jack offsuit"), "QJo")
    // Rejects
    XCTAssertNil(HoleCardShorthand.normalize("18000"))
    XCTAssertNil(HoleCardShorthand.normalize("level 12"))
    XCTAssertNil(HoleCardShorthand.normalize("no"))
    XCTAssertNil(HoleCardShorthand.normalize("As"))          // one card
    XCTAssertNil(HoleCardShorthand.normalize("AhAh"))        // duplicate
    XCTAssertNil(HoleCardShorthand.normalize("99s"))         // pair can't be suited
    XCTAssertNil(HoleCardShorthand.normalize("got a bounty"))
}

func testHoleCardShorthandHelpers() {
    XCTAssertTrue(HoleCardShorthand.isExact("Ah Kd"))
    XCTAssertFalse(HoleCardShorthand.isExact("KQs"))
    XCTAssertEqual(HoleCardShorthand.exactCards("Ah Kd").map(\.raw), ["Ah", "Kd"])
    XCTAssertTrue(HoleCardShorthand.exactCards("KQs").isEmpty)
    XCTAssertEqual(HoleCardShorthand.display("Ah Kd"), "A♥ K♦")
    XCTAssertEqual(HoleCardShorthand.display("KQs"), "KQs")
}
```

- [ ] **Step 2: Run to verify failure** (cannot find `HoleCardShorthand`).

- [ ] **Step 3: Implement `StackTrackerPro/Managers/HoleCardShorthand.swift`**

```swift
import Foundation

/// Parses user-typed / spoken-ish hole card entry into a canonical storage
/// string. Two storage forms:
///   exact       — "Ah Kd" (PlayingCard raws, space-joined)
///   suit-agnostic — "KQs" | "AKo" | "KQ" | "99"  (ranks high-first, optional s/o)
enum HoleCardShorthand {
    private static let rankWords: [String: Character] = [
        "ace": "A", "aces": "A", "king": "K", "kings": "K",
        "queen": "Q", "queens": "Q", "jack": "J", "jacks": "J",
        "ten": "T", "tens": "T", "nine": "9", "nines": "9",
        "eight": "8", "eights": "8", "seven": "7", "sevens": "7",
        "six": "6", "sixes": "6", "five": "5", "fives": "5",
        "four": "4", "fours": "4", "three": "3", "threes": "3",
        "deuce": "2", "deuces": "2", "two": "2", "twos": "2",
    ]

    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= 40 else { return nil }

        // Spoken-ish: translate rank words and suited/offsuit/pocket markers.
        var modifier: Character? = nil
        if text.contains("suited") { modifier = "s" }
        if text.contains("offsuit") || text.contains("off suit") { modifier = "o" }
        let isSpoken = text.contains("pocket") || modifier != nil
            || rankWords.keys.contains(where: { text.contains($0) })
        if isSpoken {
            for (word, rank) in rankWords.sorted(by: { $0.key.count > $1.key.count }) {
                text = text.replacingOccurrences(of: word, with: String(rank))
            }
            for junk in ["pocket", "suited", "offsuit", "off suit", "of", "and"] {
                text = text.replacingOccurrences(of: junk, with: " ")
            }
        }

        let compact = text.filter { !$0.isWhitespace }
        let ranks = Set("akqjt98765432")
        let suits = Set("shdc")

        // Exact form: rank+suit rank+suit  (4 meaningful chars)
        if compact.count == 4 {
            let chars = Array(compact)
            if ranks.contains(chars[0]), suits.contains(chars[1]),
               ranks.contains(chars[2]), suits.contains(chars[3]) {
                let c1 = "\(Character(chars[0].uppercased()))\(chars[1])"
                let c2 = "\(Character(chars[2].uppercased()))\(chars[3])"
                guard c1 != c2, PlayingCard(c1) != nil, PlayingCard(c2) != nil else { return nil }
                return "\(c1) \(c2)"
            }
        }

        // Suit-agnostic: two ranks + optional s/o modifier
        var body = compact
        var suffix: Character? = modifier
        if body.count == 3, let last = body.last, last == "s" || last == "o" {
            suffix = last
            body = String(body.dropLast())
        }
        guard body.count == 2,
              let r1 = body.first, let r2 = body.last,
              ranks.contains(r1), ranks.contains(r2) else { return nil }
        // Pairs can't be suited; single pair like "99" keeps no suffix.
        if r1 == r2 && suffix == "s" { return nil }
        let order = Array("akqjt98765432")
        let hi = order.firstIndex(of: r1)! <= order.firstIndex(of: r2)! ? r1 : r2
        let lo = hi == r1 ? r2 : r1
        var out = "\(Character(hi.uppercased()))\(Character(lo.uppercased()))"
        if r1 != r2, let suffix { out.append(suffix) }
        return out
    }

    static func isExact(_ stored: String) -> Bool {
        exactCards(stored).count == 2
    }

    static func exactCards(_ stored: String) -> [PlayingCard] {
        let cards = PlayingCard.parseList(stored)
        return cards.count == 2 ? cards : []
    }

    static func display(_ stored: String) -> String {
        let cards = exactCards(stored)
        guard cards.count == 2 else { return stored }
        return cards.map(\.display).joined(separator: " ")
    }
}
```

Watch out: the spoken branch replaces words with rank characters, so "ace king suited" → "a k " + modifier s → compact "ak" + suffix. The bare-word guard (`isSpoken`) prevents "no"/"got a bounty" from entering that path; the final two-rank guard rejects everything else.

- [ ] **Step 4: Run both tests → PASS.** Iterate on edge failures — the test list is the contract.
- [ ] **Step 5: Wire pbxproj (IDs 0117–0118), run full suite, commit** — `feat: hole-card shorthand parser`

---

### Task 3: TournamentManager stub APIs

**Files:**
- Modify: `StackTrackerPro/Managers/TournamentManager.swift`
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Consumes: `HandStub`, `StubOrigin`, `Tournament.pendingStubs`.
- Produces on `TournamentManager`:
  - `@discardableResult func createHandStub(holeCards: String, quickResult: QuickResult? = nil, quickVillain: QuickVillain? = nil, origin: StubOrigin = .manual) -> HandStub?`
  - `func attachCards(_ cards: String, to stub: HandStub)`
  - `func dismissStub(_ stub: HandStub)`

- [ ] **Step 1: Failing test**

```swift
func testCreateHandStubSnapshotsLiveContext() throws {
    let (manager, tournament, _) = try makeManagerAndTournament()
    manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
    manager.updateStack(chipCount: 390_000)
    manager.updateField(playersRemaining: 43)

    let stub = manager.createHandStub(holeCards: "KQs", quickResult: .won,
                                      quickVillain: .covered, origin: .manual)
    XCTAssertNotNil(stub)
    XCTAssertEqual(stub?.levelNumber, 21)
    XCTAssertEqual(stub?.smallBlind, 10_000)
    XCTAssertEqual(stub?.bigBlind, 25_000)
    XCTAssertEqual(stub?.ante, 25_000)
    XCTAssertEqual(stub?.heroStackBefore, 390_000)
    XCTAssertEqual(stub?.playersRemaining, 43)
    XCTAssertEqual(tournament.pendingStubs.count, 1)

    manager.attachCards("Ah Kd", to: stub!)
    XCTAssertEqual(stub?.holeCards, "Ah Kd")

    manager.dismissStub(stub!)
    XCTAssertEqual(stub?.status, .dismissed)
    XCTAssertTrue(tournament.pendingStubs.isEmpty)
}
```

- [ ] **Step 2: Run → fails** (no such member).
- [ ] **Step 3: Implement** in `TournamentManager` (near `recordHandNote`, line ~309). Follow the `mutableTournament` guard pattern used by `updateStack` (line 141):

```swift
// MARK: - Hand Stubs

@discardableResult
func createHandStub(holeCards: String,
                    quickResult: QuickResult? = nil,
                    quickVillain: QuickVillain? = nil,
                    origin: StubOrigin = .manual) -> HandStub? {
    guard let tournament = mutableTournament else { return nil }
    let blinds = tournament.currentBlinds
    let stub = HandStub(
        levelNumber: tournament.currentDisplayLevel ?? tournament.currentBlindLevelNumber,
        smallBlind: blinds?.smallBlind ?? 0,
        bigBlind: blinds?.bigBlind ?? 0,
        ante: blinds?.ante ?? 0,
        heroStackBefore: tournament.latestStack?.chipCount ?? 0,
        playersRemaining: tournament.playersRemaining,
        holeCards: holeCards,
        origin: origin
    )
    if let quickResult { stub.quickResultRaw = quickResult.rawValue }
    if let quickVillain { stub.quickVillainRaw = quickVillain.rawValue }
    tournament.handStubs?.append(stub)
    save()
    return stub
}

func attachCards(_ cards: String, to stub: HandStub) {
    stub.holeCards = cards
    save()
}

func dismissStub(_ stub: HandStub) {
    stub.setStatus(.dismissed)
    save()
}
```

- [ ] **Step 4: Run → PASS. Full suite. Commit** — `feat: TournamentManager hand stub APIs`

---

### Task 4: Stub sheet UI + chat-input stub button

**Files:**
- Create: `StackTrackerPro/Views/Session/HandStubSheet.swift`
- Create: `StackTrackerPro/Views/Components/CardPickerGrid.swift` (extracted, shared with Capture Screen later)
- Modify: `StackTrackerPro/Views/Session/ChatInputView.swift` (stub button + `onStub` closure)
- Modify: `StackTrackerPro/Views/Session/ActiveSessionView.swift` (sheet state + wiring)
- Modify: `StackTrackerPro/Views/CashGame/CashChatInputView.swift` — check whether it embeds `ChatInputView`; if it's a separate view, leave untouched (stubs are tournament-only this release). If `ChatInputView` is shared, pass `onStub: nil` from the cash path.
- Modify: pbxproj (IDs 0119–011C)

**Interfaces:**
- Produces: `CardPickerGrid(selected: [PlayingCard], dealt: Set<PlayingCard>, onPick: (PlayingCard) -> Void)` — rank grid A K Q J T 9 8 7 / 6 5 4 3 2 with a 4-suit toggle row (spec 5.5: exactly 13 ranks, no stray keys); `HandStubSheet(onSave: (String, QuickResult?, QuickVillain?) -> Void)`.
- `ChatInputView` gains `let onStub: (() -> Void)?` — when nil, no button (cash sessions).

- [ ] **Step 1: Implement `CardPickerGrid`** — two-tap card entry (tap rank, tap suit → commits card):

```swift
import SwiftUI

/// Two-tap card picker: tap a rank then a suit. Already-dealt cards are
/// rejected (button disabled). 13 ranks over two rows + one suit row.
struct CardPickerGrid: View {
    let dealt: Set<PlayingCard>
    let onPick: (PlayingCard) -> Void

    @State private var pendingRank: Character?

    private static let rankRows: [[Character]] = [
        ["A", "K", "Q", "J", "T", "9", "8", "7"],
        ["6", "5", "4", "3", "2"],
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Self.rankRows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { rank in
                        Button(String(rank == "T" ? "10" : String(rank))) {
                            pendingRank = rank
                        }
                        .buttonStyle(.bordered)
                        .tint(pendingRank == rank ? .goldAccent : .secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(Array("shdc"), id: \.self) { suit in
                    let card = pendingRank.flatMap { PlayingCard(rank: $0, suit: suit) }
                    Button {
                        if let card { onPick(card); pendingRank = nil }
                    } label: {
                        Text(suitSymbol(suit))
                            .font(.title2)
                            .foregroundColor(suit == "h" || suit == "d" ? .red : .primary)
                            .frame(width: 52, height: 40)
                    }
                    .buttonStyle(.bordered)
                    .disabled(pendingRank == nil || card == nil || dealt.contains(card!))
                }
            }
        }
    }

    private func suitSymbol(_ s: Character) -> String {
        switch s { case "s": "♠"; case "h": "♥"; case "d": "♦"; default: "♣" }
    }
}
```

- [ ] **Step 2: Implement `HandStubSheet`**

```swift
import SwiftUI

/// The 5-second capture sheet: hole cards (picker or typed shorthand),
/// optional one-tap result chips, Save. All context auto-fills at save time.
struct HandStubSheet: View {
    let onSave: (String, QuickResult?, QuickVillain?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var pickedCards: [PlayingCard] = []
    @State private var shorthand = ""
    @State private var quickResult: QuickResult?
    @State private var quickVillain: QuickVillain?

    private var storedCards: String? {
        if pickedCards.count == 2 { return PlayingCard.joinList(pickedCards) }
        return HoleCardShorthand.normalize(shorthand)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Picked cards display
                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { i in
                        Text(i < pickedCards.count ? pickedCards[i].display : "–")
                            .font(.title2.bold())
                            .frame(width: 56, height: 72)
                            .background(Color.cardSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if !pickedCards.isEmpty {
                        Button { pickedCards.removeAll() } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                    }
                }

                CardPickerGrid(dealt: Set(pickedCards)) { card in
                    guard pickedCards.count < 2 else { return }
                    pickedCards.append(card)
                }

                TextField("or type: KQs, AhKd, 99", text: $shorthand)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                // Optional one-tap chips
                HStack {
                    ForEach(QuickResult.allCases, id: \.self) { r in
                        Button(r.rawValue) { quickResult = (quickResult == r ? nil : r) }
                            .buttonStyle(.bordered)
                            .tint(quickResult == r ? .goldAccent : .secondary)
                    }
                }
                HStack {
                    ForEach(QuickVillain.allCases, id: \.self) { v in
                        Button(v.rawValue) { quickVillain = (quickVillain == v ? nil : v) }
                            .buttonStyle(.bordered)
                            .tint(quickVillain == v ? .goldAccent : .secondary)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Log Hand Stub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(storedCards ?? "", quickResult, quickVillain)
                        dismiss()
                    }
                    .disabled(storedCards == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
```

- [ ] **Step 3: Add the stub button to `ChatInputView`** — new property `let onStub: (() -> Void)?` after `onQuickAction`; in the text-input HStack, before the TextField:

```swift
if let onStub {
    Button(action: onStub) {
        Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled.fill")
            .font(.system(size: 24))
            .foregroundColor(.goldAccent)
    }
    .accessibilityLabel("Log hand stub")
}
```

Update the `#Preview` and every construction site (`ActiveSessionView`, and the cash path if shared) — cash passes `onStub: nil`.

- [ ] **Step 4: Wire in `ActiveSessionView`** — `@State private var showStubSheet = false`; pass `onStub: { showStubSheet = true }`; add alongside the existing sheets:

```swift
.sheet(isPresented: $showStubSheet) {
    HandStubSheet { cards, result, villain in
        tournamentManager.createHandStub(holeCards: cards, quickResult: result,
                                         quickVillain: villain, origin: .manual)
        HapticFeedback.impact(.light)
    }
}
```

(Match however `ActiveSessionView` names its manager — check the property list at the top of the file.)

- [ ] **Step 5: Wire pbxproj (0119–011C), build, manual smoke** — `xcodebuild build ...` then run in the simulator: start a tournament, tap the stub button, pick K♠ Q♠, tap Won, Save. Expected: sheet dismisses instantly; no chat interruption (acceptance F1).
- [ ] **Step 6: Commit** — `feat: hand stub sheet and chat-input stub button`

---

### Task 5: Chat shorthand `stub KQs` / `. KQs`

**Files:**
- Modify: `StackTrackerPro/Managers/ChatManager.swift`
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces: `static func stubShorthand(from text: String) -> String?` on `ChatManager` (internal, testable) — returns normalized cards when the message is a stub command.

- [ ] **Step 1: Failing tests**

```swift
func testChatStubShorthandCreatesStubAndAcks() async throws {
    let (manager, tournament, _) = try makeManagerAndTournament()
    manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
    manager.updateStack(chipCount: 390_000)
    let chat = ChatManager(tournamentManager: manager)

    await chat.processUserMessage(text: "stub KQs")

    XCTAssertEqual(tournament.pendingStubs.count, 1)
    XCTAssertEqual(tournament.pendingStubs.first?.holeCards, "KQs")
    let lastAI = tournament.sortedChatMessages.last(where: { $0.sender == .ai })
    XCTAssertTrue(lastAI?.text.contains("Stub saved") ?? false)
    XCTAssertTrue(lastAI?.text.contains("KQs") ?? false)
}

func testStubShorthandDetection() {
    XCTAssertEqual(ChatManager.stubShorthand(from: "stub KQs"), "KQs")
    XCTAssertEqual(ChatManager.stubShorthand(from: ". AhKd"), "Ah Kd")
    XCTAssertEqual(ChatManager.stubShorthand(from: "STUB 99"), "99")
    XCTAssertNil(ChatManager.stubShorthand(from: "stubborn opponent"))
    XCTAssertNil(ChatManager.stubShorthand(from: "18000"))
    XCTAssertNil(ChatManager.stubShorthand(from: "stub 18000"))
}
```

(Check `ChatMessage.sender` enum spelling in `Models/ChatMessage.swift` and `sortedChatMessages` on Tournament; adjust assertions to actual names.)

- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement.** In `ChatManager`:

```swift
/// "stub KQs" or ". KQs" → normalized cards; nil when not a stub command.
static func stubShorthand(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    let payload: String
    if lower.hasPrefix("stub ") {
        payload = String(trimmed.dropFirst(5))
    } else if trimmed.hasPrefix(". ") {
        payload = String(trimmed.dropFirst(2))
    } else {
        return nil
    }
    return HoleCardShorthand.normalize(payload)
}
```

In `processUserMessage`, right after the user message is appended (line ~41) and before parsing:

```swift
// Stub shorthand: "stub KQs" / ". KQs" — no parse, no sheet, one-line ack.
if let cards = Self.stubShorthand(from: text) {
    let stub = tournamentManager.createHandStub(holeCards: cards, origin: .manual)
    var ack = "Stub saved: \(HoleCardShorthand.display(cards))"
    if let stub {
        var ctx: [String] = []
        if stub.levelNumber > 0 { ctx.append("at L\(stub.levelNumber)") }
        if stub.heroStackBefore > 0 { ctx.append("stack \(stub.heroStackBefore.formatted())") }
        if !ctx.isEmpty { ack += " " + ctx.joined(separator: ", ") }
    }
    ack += "."
    tournament.chatMessages?.append(ChatMessage(sender: .ai, text: ack))
    saveContext()
    HapticFeedback.impact(.light)
    return
}
```

- [ ] **Step 4: Run → PASS. Full suite. Commit** — `feat: chat stub shorthand`

---

### Task 6: SwingDetector + sensitivity setting

**Files:**
- Create: `StackTrackerPro/Managers/SwingDetector.swift`
- Modify: `StackTrackerPro/Views/Settings/SettingsView.swift` (key + picker)
- Modify: pbxproj (IDs 011D–011E)
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces: `struct SwingDetector` with
  - `static func isSwing(previous: Int, new: Int, currentBB: Int, sensitivityPercent: Int) -> Bool`
  - `static func shouldSuppress(previousEntryDate: Date, now: Date, latestPendingStubDate: Date?) -> Bool`
- `SettingsKeys.swingSensitivity = "settings.hands.swingSensitivity"` (Int percent, 0 = off, default 20).

- [ ] **Step 1: Failing tests**

```swift
func testSwingDetectorThreshold() {
    // 390K → 985K at 25K BB: delta 595K vs max(78K, 200K) → swing
    XCTAssertTrue(SwingDetector.isSwing(previous: 390_000, new: 985_000,
                                        currentBB: 25_000, sensitivityPercent: 20))
    // Routine blind erosion: 390K → 380K → no
    XCTAssertFalse(SwingDetector.isSwing(previous: 390_000, new: 380_000,
                                         currentBB: 25_000, sensitivityPercent: 20))
    // Loss triggers too
    XCTAssertTrue(SwingDetector.isSwing(previous: 985_000, new: 760_000,
                                        currentBB: 25_000, sensitivityPercent: 20))
    // Off
    XCTAssertFalse(SwingDetector.isSwing(previous: 100_000, new: 500_000,
                                         currentBB: 1_000, sensitivityPercent: 0))
    // BB floor dominates for tiny stacks: 10K→13K at BB 1K = 3K < 8K
    XCTAssertFalse(SwingDetector.isSwing(previous: 10_000, new: 13_000,
                                         currentBB: 1_000, sensitivityPercent: 20))
}

func testSwingSuppression() {
    let now = Date()
    // >45 min since last update → ambiguous drift, suppress
    XCTAssertTrue(SwingDetector.shouldSuppress(
        previousEntryDate: now.addingTimeInterval(-46 * 60), now: now,
        latestPendingStubDate: nil))
    // Pending stub created 30s ago → duplicate, suppress
    XCTAssertTrue(SwingDetector.shouldSuppress(
        previousEntryDate: now.addingTimeInterval(-60), now: now,
        latestPendingStubDate: now.addingTimeInterval(-30)))
    // Clean case
    XCTAssertFalse(SwingDetector.shouldSuppress(
        previousEntryDate: now.addingTimeInterval(-10 * 60), now: now,
        latestPendingStubDate: now.addingTimeInterval(-10 * 60)))
}
```

- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement**

```swift
import Foundation

/// Pure swing-detection math (spec F2):
///   threshold = max(sensitivity% × previousStack, 8 × currentBB)
/// Suppressions: previous update older than 45 min (multi-pot drift → break
/// debrief handles it), or an existing pending stub within the last 90 s.
struct SwingDetector {
    static let staleUpdateMinutes: Double = 45
    static let duplicateWindowSeconds: Double = 90

    static func isSwing(previous: Int, new: Int, currentBB: Int, sensitivityPercent: Int) -> Bool {
        guard sensitivityPercent > 0, previous > 0 else { return false }
        let delta = abs(new - previous)
        let pctThreshold = Int((Double(previous) * Double(sensitivityPercent) / 100.0).rounded())
        let threshold = max(pctThreshold, 8 * max(currentBB, 0))
        guard threshold > 0 else { return false }
        return delta >= threshold
    }

    static func shouldSuppress(previousEntryDate: Date, now: Date,
                               latestPendingStubDate: Date?) -> Bool {
        if now.timeIntervalSince(previousEntryDate) > staleUpdateMinutes * 60 { return true }
        if let stubDate = latestPendingStubDate,
           now.timeIntervalSince(stubDate) < duplicateWindowSeconds { return true }
        return false
    }
}
```

- [ ] **Step 4: Settings.** Add `static let swingSensitivity = "settings.hands.swingSensitivity"` to `SettingsKeys`. In `SettingsView`, add to whichever section holds the defaults pickers:

```swift
@AppStorage(SettingsKeys.swingSensitivity) private var swingSensitivity = 20
// ...
Picker("Big-pot detection", selection: $swingSensitivity) {
    Text("Off").tag(0)
    Text("15% of stack").tag(15)
    Text("20% of stack").tag(20)
    Text("25% of stack").tag(25)
}
```

- [ ] **Step 5: Run tests → PASS. pbxproj (011D–011E). Full suite. Commit** — `feat: swing detection engine and sensitivity setting`

---

### Task 7: ChatManager swing integration (auto-stub + one-ask prompt)

**Files:**
- Modify: `StackTrackerPro/Managers/ChatManager.swift`
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Consumes: `SwingDetector`, `TournamentManager.createHandStub/attachCards/dismissStub`, `HoleCardShorthand`.
- Produces: `ChatManager.pendingSwingStub: HandStub?` (internal state), swing prompt line appended to the stack-update response.

**Behavior contract (spec F2):** one prompt per swing; a cards reply attaches; "no"/"skip" or any unrelated next message dismisses silently and the unrelated message processes normally. Never a second ask.

- [ ] **Step 1: Failing tests**

```swift
func testSwingCreatesAutoStubAndPrompt() async throws {
    let (manager, tournament, _) = try makeManagerAndTournament()
    manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
    let chat = ChatManager(tournamentManager: manager)
    await chat.processUserMessage(text: "390000")

    await chat.processUserMessage(text: "985000")
    XCTAssertEqual(tournament.pendingStubs.count, 1)
    XCTAssertEqual(tournament.pendingStubs.first?.origin, .swingDetected)
    let prompt = tournament.sortedChatMessages.last(where: { $0.sender == .ai })
    XCTAssertTrue(prompt?.text.contains("Big pot") ?? false)

    // Reply with cards → attaches
    await chat.processUserMessage(text: "AK suited")
    XCTAssertEqual(tournament.pendingStubs.first?.holeCards, "AKs")
}

func testSwingPromptDismissedByUnrelatedMessage() async throws {
    let (manager, tournament, _) = try makeManagerAndTournament()
    manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
    let chat = ChatManager(tournamentManager: manager)
    await chat.processUserMessage(text: "390000")
    await chat.processUserMessage(text: "985000")
    XCTAssertEqual(tournament.pendingStubs.count, 1)

    // Unrelated message → silent dismissal, message still processed
    await chat.processUserMessage(text: "120 players left")
    XCTAssertTrue(tournament.pendingStubs.isEmpty)   // dismissed, not pending
    XCTAssertEqual(tournament.playersRemaining, 120) // still applied
}

func testNoSwingPromptForRoutineDrift() async throws {
    let (manager, tournament, _) = try makeManagerAndTournament()
    manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
    let chat = ChatManager(tournamentManager: manager)
    await chat.processUserMessage(text: "390000")
    await chat.processUserMessage(text: "380000")
    XCTAssertTrue(tournament.pendingStubs.isEmpty)
}
```

Note: these tests exercise the regex parser path (AI parser unavailable in tests). If "390000" doesn't parse as a stack via `RegexPokerParser`, use the message forms the existing parser tests use (e.g., "390k").

- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement in `ChatManager`.**

Add state + sensitivity:

```swift
private(set) var pendingSwingStub: HandStub?

private var swingSensitivity: Int {
    UserDefaults.standard.object(forKey: SettingsKeys.swingSensitivity) as? Int ?? 20
}

private static let declineWords: Set<String> = ["no", "nope", "skip", "nah", "n"]
```

In `processUserMessage`, after the stub-shorthand intercept and before parsing, handle a pending swing question:

```swift
// One-ask swing follow-up: cards attach, anything else dismisses silently.
if let pending = pendingSwingStub {
    pendingSwingStub = nil
    if pending.status == .pending {
        if let cards = HoleCardShorthand.normalize(trimmed) {
            tournamentManager.attachCards(cards, to: pending)
            let ack = "Logged: \(HoleCardShorthand.display(cards)) — open it in Hands to add the full story."
            tournament.chatMessages?.append(ChatMessage(sender: .ai, text: ack))
            saveContext()
            HapticFeedback.impact(.light)
            return
        }
        // "no"/"skip" or unrelated → dismiss, never nag again.
        tournamentManager.dismissStub(pending)
        if Self.declineWords.contains(trimmed.lowercased()) {
            saveContext()
            return
        }
        // fall through: process the unrelated message normally
    }
}
```

Capture the previous entry before applying, then append the prompt after generating the response. Around the existing steps 3–4 (lines ~44–50):

```swift
let previousEntry = tournament.latestStack
let entities = await parseMessage(text)
applyEntities(entities, to: tournament)
var responseText = responseEngine.generateResponse(entities: entities, tournament: tournament)

if let newChips = entities.chipCount, let previous = previousEntry,
   tournament.status != .completed {
    let bb = tournament.currentBlinds?.bigBlind ?? 0
    let latestPendingStub = tournament.pendingStubs.last?.createdAt
    if SwingDetector.isSwing(previous: previous.chipCount, new: newChips,
                             currentBB: bb, sensitivityPercent: swingSensitivity),
       !SwingDetector.shouldSuppress(previousEntryDate: previous.timestamp, now: .now,
                                     latestPendingStubDate: latestPendingStub) {
        let stub = tournamentManager.createHandStub(holeCards: "", origin: .swingDetected)
        pendingSwingStub = stub
        let delta = newChips - previous.chipCount
        let sign = delta >= 0 ? "+" : "−"
        var line = "\n\nBig pot — \(sign)\(abs(delta).formatted())"
        if let level = tournament.currentDisplayLevel { line += " at Level \(level)" }
        line += ". Log it? Just tell me your cards."
        responseText += line
    }
}
```

(Check `StackEntry`'s date property name — likely `timestamp`; verify in `Models/StackEntry.swift`.)

- [ ] **Step 4: Run the three tests → PASS. Full suite. Commit** — `feat: swing detection auto-stub with one-ask chat prompt`

---

### Task 8: Break-time debrief (engine + chat integration + FadeNote)

**Files:**
- Create: `StackTrackerPro/Managers/BreakDebriefEngine.swift`
- Modify: `StackTrackerPro/Managers/ChatManager.swift`
- Modify: `StackTrackerPro/Models/Tournament.swift` (add `var lastDebriefAt: Date?`)
- Modify: `StackTrackerPro/Views/Session/ActiveSessionView.swift` (trigger after break starts — find where `BreakTimerSheet`/`startBreak` is invoked and call `chatManager.runBreakDebrief()` after)
- Modify: pbxproj (IDs 011F–0120)
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces:
  - `struct DebriefGap: Equatable { let start: Date; let end: Date; let delta: Int }`
  - `enum BreakDebriefEngine { static func unexplainedGaps(for tournament: Tournament, since: Date?, sensitivityPercent: Int, maxCount: Int) -> [DebriefGap] }`
  - `ChatManager.runBreakDebrief()` (also triggered by chat text "on break" / "break time"), `ChatManager.debriefDisabledForSession: Bool`.

**Behavior contract (spec F6):** at most once per break (`tournament.lastDebriefAt`); asks about up to 3 unexplained gaps, one at a time, largest |delta| first; cards reply → stub with cards (origin `.breakDebrief`); "one pot"-style reply → empty pending stub + pointer to Hands pane; any other freeform reply → `FadeNote` with the text verbatim; "later" defers (no `lastDebriefAt` update); "skip today" sets `debriefDisabledForSession`.

- [ ] **Step 1: Failing engine test**

```swift
func testDebriefFindsUnexplainedGapsLargestFirst() throws {
    let (manager, tournament, _) = try makeManagerAndTournament()
    manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
    // Three updates: 985K → 760K (−225K, unexplained), 760K → 645K (−115K, unexplained)
    manager.updateStack(chipCount: 985_000)
    manager.updateStack(chipCount: 760_000)
    manager.updateStack(chipCount: 645_000)

    let gaps = BreakDebriefEngine.unexplainedGaps(for: tournament, since: nil,
                                                  sensitivityPercent: 20, maxCount: 3)
    XCTAssertEqual(gaps.count, 2)
    XCTAssertEqual(gaps[0].delta, -225_000)   // largest first
    XCTAssertEqual(gaps[1].delta, -115_000)

    // A stub created now "explains" the most recent interval
    manager.createHandStub(holeCards: "KQs", origin: .manual)
    let after = BreakDebriefEngine.unexplainedGaps(for: tournament, since: nil,
                                                   sensitivityPercent: 20, maxCount: 3)
    XCTAssertEqual(after.count, 1)
    XCTAssertEqual(after[0].delta, -225_000)
}
```

- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement `BreakDebriefEngine`**

```swift
import Foundation

struct DebriefGap: Equatable {
    let start: Date
    let end: Date
    let delta: Int
}

/// Finds stack intervals with a swing-sized delta that have no stub or logged
/// hand near them — the "unexplained" gaps a break debrief should ask about.
enum BreakDebriefEngine {
    /// Timestamp slop when matching stubs/hands to an interval.
    static let explainPadding: TimeInterval = 10 * 60

    static func unexplainedGaps(for tournament: Tournament, since: Date?,
                                sensitivityPercent: Int, maxCount: Int = 3) -> [DebriefGap] {
        let entries = tournament.sortedStackEntries
        guard entries.count >= 2 else { return [] }

        let explainers: [Date] =
            (tournament.handStubs ?? []).filter { $0.status != .dismissed }.map(\.createdAt) +
            tournament.sortedHands.map(\.timestamp)

        var gaps: [DebriefGap] = []
        for (prev, next) in zip(entries, entries.dropFirst()) {
            if let since, next.timestamp <= since { continue }
            let delta = next.chipCount - prev.chipCount
            guard SwingDetector.isSwing(previous: prev.chipCount, new: next.chipCount,
                                        currentBB: next.currentBB,
                                        sensitivityPercent: sensitivityPercent) else { continue }
            let lo = prev.timestamp.addingTimeInterval(-explainPadding)
            let hi = next.timestamp.addingTimeInterval(explainPadding)
            let explained = explainers.contains { $0 >= lo && $0 <= hi }
            if !explained {
                gaps.append(DebriefGap(start: prev.timestamp, end: next.timestamp, delta: delta))
            }
        }
        return Array(gaps.sorted { abs($0.delta) > abs($1.delta) }.prefix(maxCount))
    }
}
```

(Verify `StackEntry` property names `timestamp` / `currentBB` in `Models/StackEntry.swift` before coding.)

- [ ] **Step 4: Run engine test → PASS.**
- [ ] **Step 5: Chat integration.** Add to `ChatManager`:

```swift
private(set) var debriefQueue: [DebriefGap] = []
private(set) var activeDebriefGap: DebriefGap?
var debriefDisabledForSession = false

func runBreakDebrief() {
    guard !debriefDisabledForSession,
          let tournament = tournamentManager.activeTournament,
          tournament.status == .active else { return }
    let gaps = BreakDebriefEngine.unexplainedGaps(
        for: tournament, since: tournament.lastDebriefAt,
        sensitivityPercent: swingSensitivity)
    guard !gaps.isEmpty else { return }
    tournament.lastDebriefAt = .now
    debriefQueue = gaps
    askNextDebriefQuestion(tournament: tournament, intro: true)
}

private func askNextDebriefQuestion(tournament: Tournament, intro: Bool) {
    guard let gap = debriefQueue.first else { activeDebriefGap = nil; return }
    debriefQueue.removeFirst()
    activeDebriefGap = gap
    let fmt = DateFormatter(); fmt.timeStyle = .short
    let dir = gap.delta >= 0 ? "picked up" : "dropped"
    var text = intro ? "Break debrief — couldn't account for this:\n" : ""
    text += "You \(dir) \(abs(gap.delta).formatted()) between \(fmt.string(from: gap.start)) and \(fmt.string(from: gap.end)). One pot or a fade? (Reply with your cards, a description, \"later\", or \"skip today\".)"
    tournament.chatMessages?.append(ChatMessage(sender: .ai, text: text))
    saveContext()
}
```

In `processUserMessage`, after the swing-stub block and before parsing, handle an active debrief answer:

```swift
if let gap = activeDebriefGap {
    activeDebriefGap = nil
    let lower = trimmed.lowercased()
    if lower == "later" {
        debriefQueue = []
        tournament.lastDebriefAt = nil     // re-ask next break
        tournament.chatMessages?.append(ChatMessage(sender: .ai, text: "No problem — I'll ask at the next break."))
        saveContext(); return
    }
    if lower.contains("skip today") {
        debriefQueue = []; debriefDisabledForSession = true
        tournament.chatMessages?.append(ChatMessage(sender: .ai, text: "Debriefs off for this session."))
        saveContext(); return
    }
    if let cards = HoleCardShorthand.normalize(trimmed) {
        tournamentManager.createHandStub(holeCards: cards, origin: .breakDebrief)
        tournament.chatMessages?.append(ChatMessage(sender: .ai,
            text: "Stub saved: \(HoleCardShorthand.display(cards)). Enrich it in the Hands pane when you have a minute."))
    } else if lower.contains("one pot") || lower.contains("1 pot") || lower == "pot" {
        tournamentManager.createHandStub(holeCards: "", origin: .breakDebrief)
        tournament.chatMessages?.append(ChatMessage(sender: .ai,
            text: "Stub added without cards — open it in Hands to fill in the details."))
    } else {
        let note = FadeNote(intervalStart: gap.start, intervalEnd: gap.end,
                            chipDelta: gap.delta, userExplanation: trimmed)
        note.tournament = tournament
        tournamentManager.modelContext?.insert(note)
        tournament.chatMessages?.append(ChatMessage(sender: .ai, text: "Noted — recorded as a fade, it'll show in your recap timeline."))
    }
    askNextDebriefQuestion(tournament: tournament, intro: false)
    saveContext()
    return
}
```

Also trigger from chat: in `processUserMessage` before parsing, `if trimmed.lowercased() == "on break" || trimmed.lowercased() == "break time" { ...append ack...; runBreakDebrief(); return }`. And in `ActiveSessionView`, after the break-start call site (find where `tournamentManager.startBreak(...)` is invoked from `BreakTimerSheet`'s confirm), add `chatManager.runBreakDebrief()`.

- [ ] **Step 6: Integration test**

```swift
func testDebriefFlowRecordsFadeNote() async throws {
    let (manager, tournament, _) = try makeManagerAndTournament()
    manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
    manager.updateStack(chipCount: 985_000)
    manager.updateStack(chipCount: 760_000)
    let chat = ChatManager(tournamentManager: manager)

    chat.runBreakDebrief()
    XCTAssertTrue(tournament.sortedChatMessages.last?.text.contains("dropped 225,000") ?? false)

    await chat.processUserMessage(text: "blinds and a few small ones")
    XCTAssertEqual(tournament.fadeNotes?.count, 1)
    XCTAssertEqual(tournament.fadeNotes?.first?.chipDelta, -225_000)
    // Once per break:
    chat.runBreakDebrief()
    XCTAssertEqual(tournament.sortedChatMessages.filter { $0.text.contains("debrief") }.count, 1)
}
```

- [ ] **Step 7: Run → PASS. pbxproj (011F–0120). Full suite. Commit** — `feat: break-time debrief with FadeNotes`

---

### Task 9: Recap export — pending stubs + FadeNotes

**Files:**
- Modify: `StackTrackerPro/Managers/TournamentRecapExporter.swift`
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

- [ ] **Step 1: Failing test**

```swift
func testRecapIncludesStubsAndFadeNotes() throws {
    let (manager, tournament, _) = try makeManagerAndTournament()
    manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
    manager.updateStack(chipCount: 390_000)
    let stub = manager.createHandStub(holeCards: "KQs", quickResult: .won,
                                      quickVillain: .covered, origin: .manual)
    XCTAssertNotNil(stub)
    let fade = FadeNote(intervalStart: .now, intervalEnd: .now, chipDelta: -340_000,
                        userExplanation: "card dead, paid blinds")
    fade.tournament = tournament

    let md = TournamentRecapExporter.markdown(for: tournament)
    XCTAssertTrue(md.contains("## Pending Hands"))
    XCTAssertTrue(md.contains("KQs"))
    XCTAssertTrue(md.contains("(unenriched)"))
    XCTAssertTrue(md.contains("card dead, paid blinds"))
}
```

- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement.** In `markdown(for:)` section assembly (line ~20), after `structuredHandsSection`, append `pendingStubsSection(for: tournament)`:

```swift
private static func pendingStubsSection(for tournament: Tournament) -> String {
    var lines: [String] = ["## Pending Hands (stubs awaiting enrichment)", ""]
    let stubs = tournament.pendingStubs
    guard !stubs.isEmpty else {
        lines.append("_None — every captured hand was enriched._")
        return lines.joined(separator: "\n")
    }
    for stub in stubs {
        lines.append("- \(stamp(stub.createdAt)) — \(stub.exportLine)")
    }
    return lines.joined(separator: "\n")
}
```

In the timeline row assembly (~line 175, where hand notes are appended), add FadeNotes:

```swift
for fade in tournament.sortedFadeNotes {
    let sign = fade.chipDelta >= 0 ? "+" : "−"
    rows.append((fade.intervalEnd,
        "Fade: \(sign)\(abs(fade.chipDelta).formatted()) — \(fade.userExplanation)"))
}
```

Also update the AI-prompt preamble (line ~80) to mention fades: extend "using the timeline, hand notes, and the street-by-street Structured Hands" with "and FadeNotes (player-confirmed gradual losses — treat them as authoritative, not unknowns)".

- [ ] **Step 4: Run → PASS. Full suite. Commit** — `feat: recap export includes stubs and fade notes`

**Phase A complete — this is a shippable point release (spec ship order 1–3).**

---

# Phase B — Enrichment surface (Feature 5)

### Task 10: HandVillain model + Hand v2 fields

**Files:**
- Create: `StackTrackerPro/Models/HandVillain.swift`
- Modify: `StackTrackerPro/Models/Hand.swift`
- Modify: both schema lists; pbxproj (IDs 0121–0122)
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces: `RelativeStack` enum (`.coversHero` "Covers me" / `.similar` "~Same" / `.shorter` "Shorter"), `HandVillain` (`orderIndex: Int`, `positionRaw: String`, `relativeStackRaw: String`, `approxStack: Int` 0=unset, `shownHolding: String` ""=mucked, `hand: Hand?`, computed `position: HeroPosition`, `relativeStack: RelativeStack`), and on `Hand`: `villains: [HandVillain]?` (cascade), `wasAutoDetected: Bool = false`, `heroStackAfter: Int = 0`, `winnerOverride: String = ""`, computed `sortedVillains`.

- [ ] **Step 1: Failing test**

```swift
func testHandVillainsPersistAndCascade() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let hand = Hand(heroPosition: .btn, heroCardsRaw: "Kh Kd")
    context.insert(hand)
    let v = HandVillain(orderIndex: 0, position: .utg, relativeStack: .coversHero)
    v.shownHolding = "9h Th"
    v.hand = hand
    context.insert(v)
    try context.save()

    XCTAssertEqual(hand.sortedVillains.count, 1)
    XCTAssertEqual(hand.sortedVillains.first?.position, .utg)
    XCTAssertEqual(hand.sortedVillains.first?.relativeStack, .coversHero)
    context.delete(hand)
    try context.save()
    XCTAssertEqual(try context.fetch(FetchDescriptor<HandVillain>()).count, 0)
}
```

- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement `HandVillain.swift`**

```swift
import Foundation
import SwiftData

enum RelativeStack: String, CaseIterable {
    case coversHero = "Covers me", similar = "~Same", shorter = "Shorter"
}

/// A specific opponent in a structured hand. No fixed count — multiway is
/// not a special case (spec 5.2).
@Model
final class HandVillain {
    var orderIndex: Int = 0
    var positionRaw: String = HeroPosition.utg.rawValue
    var relativeStackRaw: String = RelativeStack.coversHero.rawValue
    var approxStack: Int = 0          // 0 = not given
    var shownHolding: String = ""     // "9h Th"; "" = mucked/unknown
    var hand: Hand?

    init(orderIndex: Int = 0, position: HeroPosition = .utg,
         relativeStack: RelativeStack = .coversHero, approxStack: Int = 0) {
        self.orderIndex = orderIndex
        self.positionRaw = position.rawValue
        self.relativeStackRaw = relativeStack.rawValue
        self.approxStack = approxStack
    }

    var position: HeroPosition { HeroPosition(rawValue: positionRaw) ?? .utg }
    var relativeStack: RelativeStack { RelativeStack(rawValue: relativeStackRaw) ?? .coversHero }
    var shownCards: [PlayingCard] { PlayingCard.parseList(shownHolding) }

    var chipLabel: String {
        var label = "\(positionRaw) · \(relativeStackRaw)"
        if approxStack > 0 { label += " ≈\(approxStack.formatted())" }
        return label
    }
}
```

In `Hand.swift` add (next to `actions` relationship):

```swift
@Relationship(deleteRule: .cascade, inverse: \HandVillain.hand)
var villains: [HandVillain]? = []
var wasAutoDetected: Bool = false
var heroStackAfter: Int = 0        // 0 = not computed
var winnerOverride: String = ""    // manual override for chops/odd rulings

var sortedVillains: [HandVillain] {
    (villains ?? []).sorted { $0.orderIndex < $1.orderIndex }
}
```

(`potSize` already exists and serves as `computedPot`; `tagsRaw` already covers tags — Capture Screen writes spec tags into it.)

- [ ] **Step 4: Schema (both lists) + pbxproj. Run → PASS. Full suite. Commit** — `feat: HandVillain model and Hand v2 fields`

---

### Task 11: PokerHandEvaluator (showdown winner computation)

**Files:**
- Create: `StackTrackerPro/Managers/PokerHandEvaluator.swift`
- Modify: pbxproj (IDs 0123–0124)
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces:
  - `PokerHandEvaluator.Score: Comparable` (category 8=straight flush … 0=high card, plus tiebreak ranks).
  - `static func bestScore(_ cards: [PlayingCard]) -> Score?` — best 5-card hand from 5–7 cards.
  - `static func holdemWinners(board: [PlayingCard], holdings: [(id: UUID, cards: [PlayingCard])]) -> [UUID]` — ids sharing the top score (ties = chop). Hold'em only; PLO showdowns use the manual winner override.

- [ ] **Step 1: Failing tests**

```swift
func testEvaluatorRanksCategories() {
    func score(_ s: String) -> PokerHandEvaluator.Score {
        PokerHandEvaluator.bestScore(PlayingCard.parseList(s))!
    }
    XCTAssertGreaterThan(score("Ah Kh Qh Jh Th"), score("As Ad Ac Ah Kd"))   // royal > quads
    XCTAssertGreaterThan(score("As Ad Ac Kh Kd"), score("As Ad Ac Kh Qd"))   // boat > trips
    XCTAssertGreaterThan(score("2h 7h 9h Jh Kh"), score("As Ks Qs Jd 9c"))   // flush > high card
    XCTAssertGreaterThan(score("Ah 2d 3c 4s 5h"), score("As Ad Kc Qh Jd"))   // wheel > pair
    XCTAssertEqual(score("Ah Kd Qc Js Th"), score("Ad Kh Qs Jc Td"))          // same straight
    // 7-card: board pairs the best hand
    XCTAssertEqual(
        PokerHandEvaluator.bestScore(PlayingCard.parseList("Kh Kd Jh 8h 4d 2c 2s"))!.category,
        2  // two pair
    )
}

func testHoldemWinnersKKvs9T() {
    // Event #86 reference hand: KK vs 9T on J-8-4-2-Q board → KK wins
    let hero = UUID(), villain = UUID()
    let winners = PokerHandEvaluator.holdemWinners(
        board: PlayingCard.parseList("Jh 8h 4d 2c Qs"),
        holdings: [(hero, PlayingCard.parseList("Kh Kd")),
                   (villain, PlayingCard.parseList("9h Th"))])
    XCTAssertEqual(winners, [hero])
    // Chop: same straight
    let a = UUID(), b = UUID()
    let chop = PokerHandEvaluator.holdemWinners(
        board: PlayingCard.parseList("9h Th Jc Qs Kd"),
        holdings: [(a, PlayingCard.parseList("2h 3d")), (b, PlayingCard.parseList("4c 5s"))])
    XCTAssertEqual(Set(chop), Set([a, b]))
}
```

- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement**

```swift
import Foundation

/// Minimal 5–7 card hold'em hand evaluator. Categories:
/// 8 straight flush, 7 quads, 6 full house, 5 flush, 4 straight,
/// 3 trips, 2 two pair, 1 pair, 0 high card.
struct PokerHandEvaluator {
    struct Score: Comparable, Equatable {
        let category: Int
        let ranks: [Int]   // tiebreakers, high first

        static func < (lhs: Score, rhs: Score) -> Bool {
            if lhs.category != rhs.category { return lhs.category < rhs.category }
            for (l, r) in zip(lhs.ranks, rhs.ranks) where l != r { return l < r }
            return false
        }
    }

    private static let rankValue: [Character: Int] = [
        "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8,
        "9": 9, "T": 10, "J": 11, "Q": 12, "K": 13, "A": 14,
    ]

    static func bestScore(_ cards: [PlayingCard]) -> Score? {
        guard cards.count >= 5, cards.count <= 7 else { return nil }
        guard Set(cards).count == cards.count else { return nil }
        var best: Score?
        for combo in combinations(cards, choose: 5) {
            let s = scoreFive(combo)
            if best == nil || s > best! { best = s }
        }
        return best
    }

    static func holdemWinners(board: [PlayingCard],
                              holdings: [(id: UUID, cards: [PlayingCard])]) -> [UUID] {
        guard board.count == 5 else { return [] }
        var scored: [(UUID, Score)] = []
        for (id, cards) in holdings {
            guard cards.count == 2, let s = bestScore(board + cards) else { continue }
            scored.append((id, s))
        }
        guard let top = scored.map(\.1).max() else { return [] }
        return scored.filter { $0.1 == top }.map(\.0)
    }

    // MARK: - Internals

    private static func scoreFive(_ cards: [PlayingCard]) -> Score {
        let values = cards.map { rankValue[$0.rank]! }.sorted(by: >)
        let isFlush = Set(cards.map(\.suit)).count == 1
        let straightHigh = straightHighCard(values)

        var counts: [Int: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        // Sort rank groups by (count desc, rank desc) — canonical tiebreak order.
        let groups = counts.sorted { ($0.value, $0.key) > ($1.value, $1.key) }
        let shape = groups.map(\.value)
        let ordered = groups.map(\.key)

        if isFlush, let high = straightHigh { return Score(category: 8, ranks: [high]) }
        if shape == [4, 1] { return Score(category: 7, ranks: ordered) }
        if shape == [3, 2] { return Score(category: 6, ranks: ordered) }
        if isFlush { return Score(category: 5, ranks: values) }
        if let high = straightHigh { return Score(category: 4, ranks: [high]) }
        if shape == [3, 1, 1] { return Score(category: 3, ranks: ordered) }
        if shape == [2, 2, 1] { return Score(category: 2, ranks: ordered) }
        if shape == [2, 1, 1, 1] { return Score(category: 1, ranks: ordered) }
        return Score(category: 0, ranks: values)
    }

    private static func straightHighCard(_ sortedDesc: [Int]) -> Int? {
        let distinct = Array(Set(sortedDesc)).sorted(by: >)
        guard distinct.count == 5 else { return nil }
        if distinct.first! - distinct.last! == 4 { return distinct.first! }
        if distinct == [14, 5, 4, 3, 2] { return 5 }   // wheel
        return nil
    }

    private static func combinations(_ cards: [PlayingCard], choose k: Int) -> [[PlayingCard]] {
        guard cards.count > k else { return [cards] }
        var result: [[PlayingCard]] = []
        var combo: [PlayingCard] = []
        func recurse(_ start: Int) {
            if combo.count == k { result.append(combo); return }
            for i in start..<cards.count {
                combo.append(cards[i])
                recurse(i + 1)
                combo.removeLast()
            }
        }
        recurse(0)
        return result
    }
}
```

- [ ] **Step 4: Run → PASS. pbxproj. Full suite. Commit** — `feat: poker hand evaluator for showdown winner computation`

---

### Task 12: HandCaptureModel — participants, turn order, ledger, pot

**Files:**
- Create: `StackTrackerPro/Managers/HandCaptureModel.swift`
- Modify: pbxproj (IDs 0125–0126)
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces (consumed by Tasks 13–15):**

```swift
@MainActor @Observable
final class HandCaptureModel {
    struct VillainDraft: Identifiable, Equatable {
        let id: UUID                      // init with UUID()
        var position: HeroPosition
        var relative: RelativeStack
        var approxStack: Int              // 0 = unset
        var shownHolding: [PlayingCard]
        var mucked: Bool
    }
    enum Participant: Equatable, Hashable { case hero, villain(UUID) }
    struct LedgerEntry: Identifiable, Equatable {
        let id: UUID
        let street: HandStreet
        let participant: Participant
        let action: HandActionType
        let toAmount: Int                 // committed total on that street after this action
    }

    // Context (immutable after init)
    let levelNumber: Int; let smallBlind: Int; let bigBlind: Int; let ante: Int
    let heroCardCount: Int                // 2 (NLHE) or 4 (PLO)
    var heroStackBefore: Int              // editable, prefilled

    // Setup state
    var heroPosition: HeroPosition?
    var heroCards: [PlayingCard]
    var villains: [VillainDraft]
    func addVillain(position: HeroPosition, relative: RelativeStack, approxStack: Int)
    func removeVillain(id: UUID)

    // Live state (all derived by full replay of `ledger` + `board`)
    private(set) var ledger: [LedgerEntry]
    private(set) var board: [PlayingCard]
    var currentStreet: HandStreet         // derived
    var boardCardsNeeded: Int             // 0 unless a street just closed
    var participantToAct: Participant?    // nil when hand over / awaiting board
    var currentBet: Int                   // highest committed this street
    var pot: Int                          // live computed pot
    var potOverride: Int?                 // narration-bar tap override
    var legalActions: [HandActionType]    // for the action row
    var isHandOver: Bool
    var dealtCards: Set<PlayingCard>

    func add(action: HandActionType, toAmount: Int)   // toAmount ignored for fold/check
    func addBoardCard(_ card: PlayingCard) -> Bool
    func undoLast()
    func truncate(toLedgerIndex index: Int)
    func label(for participant: Participant) -> String  // "Hero (BTN)" / "UTG (covers)"
}
```

**Core rules (implement exactly):**
- Participant order = positions sorted by table order `[.utg, .utg1, .mp, .lj, .hj, .co, .btn, .sb, .bb]`. Preflop first-to-act = first participant after `.bb` in that order (wrap); postflop = first non-folded participant from `.sb` onward. Only hero + added villains exist; everyone else is implicitly folded ("folds to" costs zero taps).
- Per-street `committed[participant]` starts at 0, except preflop where an SB-seat participant starts at `smallBlind` and a BB-seat participant at `bigBlind`.
- `pot = ante + sb + bb + Σ over streets/participants of (committed − preflopPostedCredit)` — equivalently: seed `pot` with `ante + (SB participant absent ? smallBlind : 0) + (BB participant absent ? bigBlind : 0)`, then add every participant's committed totals per street (with preflop committed including their posted blind). Use `potOverride` when set.
- Action semantics: `bet`/`raise`/`allIn` set that participant's street committed to `toAmount` (must be > currentBet except all-in which may be a short jam); `call` sets committed to `min(currentBet, participant all-in cap — no cap modeled, just currentBet)`; `check` requires committed == currentBet; `fold` removes from active set.
- Street closes when every non-folded participant has acted at least once this street AND all non-folded, non-all-in participants' committed == currentBet. On close: preflop→flop needs 3 board cards, flop→turn 1, turn→river 1; after river close (or when ≤1 active, or all remaining all-in and board complete) `isHandOver = true`. If all active players are all-in before the river, remaining board cards are still requested (`boardCardsNeeded` walks forward street by street).
- Hand also ends immediately when folds leave one active participant.
- `undoLast()` pops the most recent input (ledger entry OR board card — keep a unified input log like `HandEntryModel.inputLog`) and replays. `truncate(toLedgerIndex:)` drops that entry and everything after (including later board cards), then replays.
- Derived state is ALWAYS computed by replaying inputs from scratch in a private `rebuild()` — no incremental mutation, so undo/truncate can't drift (spec acceptance: "Deleting/undoing any action recomputes pot, turn order, and street state correctly").

- [ ] **Step 1: Failing tests** — the Event #86 reference hand plus mechanics:

```swift
@MainActor
func testCaptureTurnOrderAndPot() throws {
    let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                 ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
    model.heroPosition = .btn
    for c in PlayingCard.parseList("Kh Kd") { XCTAssertTrue(model.addCard(c)) }
    model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
    let utg = model.villains[0].id

    // Preflop: UTG acts first (hero BTN, villain UTG; blinds are dead)
    XCTAssertEqual(model.participantToAct, .villain(utg))
    model.add(action: .raise, toAmount: 75_000)
    XCTAssertEqual(model.participantToAct, .hero)
    XCTAssertEqual(model.currentBet, 75_000)
    model.add(action: .call, toAmount: 0)

    // Street closed → flop needs 3 cards. Pot: ante+sb+bb dead (60K) + 150K
    XCTAssertEqual(model.boardCardsNeeded, 3)
    XCTAssertEqual(model.pot, 25_000 + 10_000 + 25_000 + 150_000)
    for c in PlayingCard.parseList("Jh 8h 4d") { XCTAssertTrue(model.addBoardCard(c)) }
    XCTAssertEqual(model.currentStreet, .flop)
    // Postflop: UTG first again (no SB/BB participants)
    XCTAssertEqual(model.participantToAct, .villain(utg))

    // Undo rewinds the board card and street state
    model.undoLast()
    XCTAssertEqual(model.boardCardsNeeded, 1)
    XCTAssertEqual(model.board.count, 2)
}

@MainActor
func testCaptureFoldEndsHand() throws {
    let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                 ante: 200, heroCardCount: 2, heroStackBefore: 40_000)
    model.heroPosition = .co
    for c in PlayingCard.parseList("As Kd") { _ = model.addCard(c) }
    model.addVillain(position: .bb, relative: .shorter, approxStack: 0)
    // Hero (CO) first preflop; BB already has 200 committed
    XCTAssertEqual(model.participantToAct, .hero)
    model.add(action: .raise, toAmount: 500)
    model.add(action: .fold, toAmount: 0)     // BB folds
    XCTAssertTrue(model.isHandOver)
    // Pot: ante 200 + sb dead 100 + bb 200 + hero 500 = 1000
    XCTAssertEqual(model.pot, 1000)
}
```

- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement `HandCaptureModel`** per the interface + rules above. Structure:

```swift
import Foundation
import Observation

@MainActor @Observable
final class HandCaptureModel {
    // ... (types + stored context from the interface block above)

    private enum Input {
        case action(Participant, HandActionType, Int)
        case boardCard(PlayingCard)
    }
    private var inputs: [Input] = []

    // Derived (recomputed by rebuild()):
    private(set) var ledger: [LedgerEntry] = []
    private(set) var board: [PlayingCard] = []
    private(set) var currentStreet: HandStreet = .preflop
    private(set) var boardCardsNeeded = 0
    private(set) var participantToAct: Participant?
    private(set) var currentBet = 0
    private(set) var isHandOver = false
    private(set) var foldedParticipants: Set<Participant> = []
    private(set) var allInParticipants: Set<Participant> = []
    private var committedByStreet: [HandStreet: [Participant: Int]] = [:]
    var potOverride: Int?

    static let tableOrder: [HeroPosition] = [.utg, .utg1, .mp, .lj, .hj, .co, .btn, .sb, .bb]

    var pot: Int {
        if let potOverride { return potOverride }
        var total = ante
        if participant(at: .sb) == nil { total += smallBlind }
        if participant(at: .bb) == nil { total += bigBlind }
        for (_, streetMap) in committedByStreet {
            for (_, amount) in streetMap { total += amount }
        }
        return total
    }
    // add(action:), addBoardCard(_:), undoLast(), truncate(toLedgerIndex:) all
    // append/remove from `inputs` then call rebuild().
    // rebuild(): reset all derived state; preflop committed seeds SB/BB
    // participants; walk inputs applying the street-close rules above.
}
```

Write the full replay implementation — every rule in "Core rules" — plus `legalActions` (`fold/check/call/bet` when currentBet == own committed; `fold/call/raise` otherwise; `allIn` always available when it's someone's turn), `addCard(_:)` for hero cards (rejects dealt cards, cap `heroCardCount`), `dealtCards` (hero + board + villains' shown), and `label(for:)`.

- [ ] **Step 4: Run → PASS. Full suite. Commit** — `feat: HandCaptureModel turn/pot/ledger engine`

---

### Task 13: HandCaptureModel — result flow + save

**Files:**
- Modify: `StackTrackerPro/Managers/HandCaptureModel.swift`
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces on `HandCaptureModel`:
  - `var needsShowdown: Bool` — hand over with ≥2 active participants.
  - `var showdownParticipants: [Participant]`
  - `func setShownHolding(_ cards: [PlayingCard], for id: UUID)` / `func setMucked(_ id: UUID)`
  - `var computedWinners: [Participant]` — no showdown → last aggressor (or lone survivor); showdown → `PokerHandEvaluator.holdemWinners` over hero + shown villains (hold'em only; empty when unevaluable, e.g. PLO or all mucked → UI requires manual pick).
  - `var winnerOverride: Set<Participant>?`
  - `var heroNet: Int` — winners split pot equally; hero's net = (share if winner else 0) − hero total contribution (across streets, incl. posted blind if hero in blinds; hero also pays ante share… **model simply**: hero contribution = Σ hero committed + (hero at BB ? ante : 0)).
  - `var heroStackAfter: Int` = `heroStackBefore + heroNet`.
  - `var selectedTags: Set<String>` (values: "Cooler", "Bluff", "Value", "Hero call", "Punt?").
  - `func save(into context: ModelContext, tournament: Tournament?, cashSession: CashSession?, sourceStub: HandStub?, tableSize: Int) -> Hand` — builds `Hand` (+`HandAction`s ordered, +`HandVillain`s), sets `potSize = pot`, `amountWon = heroNet`, `heroStackAfter`, `resultRaw` (won/lost/chop/folded from winners vs hero), `wasAutoDetected = sourceStub?.origin == .swingDetected`, `winnerOverride` description when overridden, `tagsRaw`, links `sourceStub` (sets `.enriched`, `enrichedHand`, `heroStackAfter` on the stub).
- Note: save does NOT push the stack update itself — the VIEW calls `tournamentManager.updateStack(chipCount: model.heroStackAfter)` after save (keeps the engine ModelContext-pure and testable).

- [ ] **Step 1: Failing test — the full Event #86 reference hand (KK vs 9T), ≤25 tap-equivalents:**

```swift
@MainActor
func testCaptureFullHandKKvs9T() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let t = Tournament(name: "Event 86", venue: "WSOP", buyIn: 500)
    context.insert(t)

    let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                 ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
    model.heroPosition = .btn
    for c in PlayingCard.parseList("Kh Kd") { _ = model.addCard(c) }
    model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
    let utg = model.villains[0].id

    model.add(action: .raise, toAmount: 75_000)   // UTG
    model.add(action: .raise, toAmount: 200_000)  // Hero 3-bets
    model.add(action: .allIn, toAmount: 390_000)  // UTG jams (covers)
    model.add(action: .call, toAmount: 0)          // Hero calls all-in

    // All-in preflop → board requested street by street
    for c in PlayingCard.parseList("Jh 8h 4d") { _ = model.addBoardCard(c) }
    _ = model.addBoardCard(PlayingCard("2c")!)
    _ = model.addBoardCard(PlayingCard("Qs")!)
    XCTAssertTrue(model.isHandOver)
    XCTAssertTrue(model.needsShowdown)

    model.setShownHolding(PlayingCard.parseList("9h Th"), for: utg)
    XCTAssertEqual(model.computedWinners, [.hero])

    // Pot: ante 25K + dead sb 10K + dead bb 25K + 390K + 390K = 840K
    XCTAssertEqual(model.pot, 840_000)
    // Hero net: 840K − 390K contribution = +450K
    XCTAssertEqual(model.heroNet, 450_000)
    XCTAssertEqual(model.heroStackAfter, 840_000)

    let hand = model.save(into: context, tournament: t, cashSession: nil,
                          sourceStub: nil, tableSize: 9)
    XCTAssertEqual(hand.result, .won)
    XCTAssertEqual(hand.potSize, 840_000)
    XCTAssertEqual(hand.amountWon, 450_000)
    XCTAssertEqual(hand.heroStackAfter, 840_000)
    XCTAssertEqual(hand.sortedVillains.first?.shownHolding, "9h Th")
    XCTAssertEqual(hand.sortedActions.count, 4)
}

@MainActor
func testCaptureNoShowdownWinnerIsLastAggressor() throws {
    let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                 ante: 200, heroCardCount: 2, heroStackBefore: 40_000)
    model.heroPosition = .btn
    for c in PlayingCard.parseList("7h 2c") { _ = model.addCard(c) }
    model.addVillain(position: .bb, relative: .coversHero, approxStack: 0)
    model.add(action: .raise, toAmount: 500)  // hero opens
    model.add(action: .fold, toAmount: 0)     // bb folds
    XCTAssertTrue(model.isHandOver)
    XCTAssertFalse(model.needsShowdown)
    XCTAssertEqual(model.computedWinners, [.hero])
    XCTAssertEqual(model.heroNet, model.pot - 500)
}

@MainActor
func testCaptureStubEnrichment() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let t = Tournament(name: "T", venue: "V", buyIn: 100)
    context.insert(t)
    let stub = HandStub(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                        ante: 25_000, heroStackBefore: 390_000, holeCards: "Kh Kd")
    stub.tournament = t
    context.insert(stub)

    let model = HandCaptureModel(stub: stub, heroCardCount: 2)
    XCTAssertEqual(model.heroCards.map(\.raw), ["Kh", "Kd"])   // exact cards prefill
    XCTAssertEqual(model.heroStackBefore, 390_000)

    model.heroPosition = .btn
    model.addVillain(position: .bb, relative: .shorter, approxStack: 0)
    model.add(action: .raise, toAmount: 500_000)  // effectively a jam for test
    model.add(action: .fold, toAmount: 0)
    let hand = model.save(into: context, tournament: t, cashSession: nil,
                          sourceStub: stub, tableSize: 9)
    XCTAssertEqual(stub.status, .enriched)
    XCTAssertIdentical(stub.enrichedHand, hand)
}
```

Adjust `Tournament(...)` initializers to the project's actual signature (mirror `makeManagerAndTournament`).

- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement** result flow + `save` + convenience `init(stub:heroCardCount:)` (copies level/blinds/ante/stack from the stub; `HoleCardShorthand.exactCards` prefills hero cards only when exact — suit-agnostic stubs leave cards empty and the view shows the token as a hint). Last-aggressor = participant of the last `bet/raise/allIn` in the ledger; if none (checked down with no showdown — impossible, hand over without showdown means folds) fall back to lone active participant. `resultRaw`: hero in winners and winners.count == 1 → `.won`; hero in winners and count > 1 → `.chop`; hero folded → `.folded`; else `.lost`.

- [ ] **Step 4: Run all Task 12+13 tests → PASS. Full suite. Commit** — `feat: HandCaptureModel result flow and save`

---

### Task 14: HandCaptureView UI

**Files:**
- Create: `StackTrackerPro/Views/Session/HandCaptureView.swift`
- Modify: pbxproj (IDs 0127–0128)

**Interfaces:**
- Consumes: everything Task 12/13 produced, `CardPickerGrid` (Task 4).
- Produces: `HandCaptureView(tournament: Tournament?, cashSession: CashSession?, stub: HandStub?, onSaved: (Hand) -> Void)` — presented `fullScreenCover` from HandsPane (Task 15).

**Layout (spec 5.1, top to bottom) — single scrolling screen:**
1. **Narration bar** — `model.narration` text, 2–3 lines, monospaced-digit; trailing computed-pot chip `Pot 840K` (tap → number-pad alert to set `potOverride`).
2. Top bar (toolbar): undo (`arrow.uturn.backward`), close (X, confirm-if-dirty). *(mic slot deferred to the voice plan)*
3. **Hero strip** — position row (9 buttons, one-tap), hole cards (current cards + `CardPickerGrid` when incomplete + shorthand hint when stub was suit-agnostic), stack field prefilled with `heroStackBefore` (editable numeric, k-shorthand accepted: "390k").
4. **Villain chips** — `+ Add Villain` opens inline editor: position row (hero's seat disabled) → three big relative-stack buttons `Covers me / ~Same / Shorter` → optional `≈ amount` field → Add. Chips show `chipLabel`; tap re-opens editor; swipe/long-press deletes.
5. **Action ledger** — grouped by street (`PRE — UTG r 75K · Hero r 200K …`, `FLOP J♥8♥4♦ — …`); last row shows inline ✕ (undo); tapping an earlier row → confirm dialog → `truncate(toLedgerIndex:)`.
6. **Action entry row** — label `model.label(for: participantToAct)` + buttons from `legalActions` (`Fold` `Check` `Call 75K` `Bet/Raise`).
7. **Sizing row** (appears when Bet/Raise tapped): `⅓ ½ ⅔ Pot 1.5x Jam #` — fractions compute from `model.pot` (round to a clean chip amount: nearest 500 below 10K BB, nearest 1000 above); `Jam` = `heroStackBefore` for hero / villain `approxStack` if set else prompt; `#` opens the number pad (k-shorthand; bare number ≤ 3-digit interpreted as BB × bigBlind, disambiguated in narration before commit).
8. **Board entry** — appears when `boardCardsNeeded > 0`: `CardPickerGrid(dealt: model.dealtCards)`.
9. **Result block** — when `isHandOver`: no showdown → winner line auto ("UTG folds — Hero wins 840K"); showdown → per-villain holding pickers (+ `Mucked` button) + hero result computed; `Override winner` menu for chops/rulings (sets `winnerOverride`).
10. **Tag row + Save** — one-tap tags `Cooler Bluff Value Hero call Punt?`; Save button enabled when `isHandOver` and (not `needsShowdown` or winners resolvable or override set).

On Save:

```swift
let hand = model.save(into: modelContext, tournament: tournament,
                      cashSession: cashSession, sourceStub: stub,
                      tableSize: seatsDefault)
if tournament != nil, model.heroStackAfter > 0 {
    tournamentManager.updateStack(chipCount: model.heroStackAfter)  // spec 5.4: auto-push
}
onSaved(hand)
dismiss()
```

Add `var narration: String` to `HandCaptureModel` in this task (pure string composition — e.g. `"NLHE L21 10K/25K(25K) · Hero BTN K♠Q♠ (390K) · UTG (covers) raises to 75K, Hero raises to 200K · FLOP J♥8♥4♦"`), with a unit test:

```swift
@MainActor
func testNarrationRendersHandSoFar() { /* build 2 actions, assert contains "Hero BTN", "raises to 75,000", "Pot" omitted (chip is separate) */ }
```

- [ ] **Step 1: Add `narration` + test → run → implement → pass.**
- [ ] **Step 2: Build the view** (subviews: `NarrationBar`, `HeroStrip`, `VillainEditor`, `LedgerList`, `ActionRow`, `SizingRow`, `ResultBlock` — all `private struct`s in the same file; keep the file under ~500 lines by leaning on the engine for ALL logic).
- [ ] **Step 3: `xcodebuild build` → fix compile errors.**
- [ ] **Step 4: Manual smoke in simulator** — enter the KK vs 9T hand by taps alone, counting: position (1) cards (4) villain (3) actions (4–6) board (10) showdown holding (4) save (1) ≈ 25 taps (spec acceptance 5.6).
- [ ] **Step 5: Commit** — `feat: Hand Capture Screen UI`

---

### Task 15: HandsPane rework — Pending Hands section + Capture routing

**Files:**
- Modify: `StackTrackerPro/Views/Session/HandsPane.swift`
- Test: build + manual smoke (pure view wiring)

**Changes:**
- Add a "Pending Hands" `Section` ABOVE the hands list when `tournament?.pendingStubs.isEmpty == false`: rows show `HoleCardShorthand.display(stub.holeCards)` (or "cards unknown"), `L\(levelNumber)`, stack, quick chips, relative time; origin icon (`bolt.fill` for `.swingDetected`, `cup.and.saucer.fill` for `.breakDebrief`). Badge count in the section header.
- Tapping a pending stub → `fullScreenCover` `HandCaptureView(tournament:cashSession:stub:onSaved:)`.
- Swipe actions on stub rows: Dismiss (`tournamentManager.dismissStub`), Delete.
- The existing `showEntry` "+" flow now presents `HandCaptureView` with `stub: nil` instead of `HandEntryView`.
- `isReadOnly` (completed tournaments): hide pending section actions, no capture entry.
- `HandDetailView` gains a "Villains" section (`hand.sortedVillains` → `chipLabel` + shown cards) and a Result line including `heroStackAfter` when > 0.

- [ ] **Step 1: Implement. Step 2: build + smoke (create stub via chat `stub KQs`, see it in Pending, tap → capture prefilled at L21 blinds, save → stub row moves to enriched hands list, stack update appears in chat pane). Step 3: Commit** — `feat: HandsPane pending stubs + capture screen routing`

---

### Task 16: Remove the old hand-entry flow

**Files:**
- Delete: `StackTrackerPro/Views/Session/HandEntryView.swift`
- Delete: `StackTrackerPro/Managers/HandEntryModel.swift`
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (remove IDs 010D/010E/010F/0110 — 8 lines: 2 PBXBuildFile, 2 PBXFileReference, 2 group children, 2 Sources entries)
- Modify: `StackTrackerProTests/StackTrackerProTests.swift` — delete `testStageProgressionThroughFullHand` (line ~979) and any other test referencing `HandEntryModel`; KEEP `testHandPersistsWithActionsAndContext` (line ~935) if it only uses `Hand`/`HandAction` — if it constructs a `HandEntryModel`, rewrite it against `HandCaptureModel.save` instead.
- Check: `grep -rn "HandEntryView\|HandEntryModel" StackTrackerPro StackTrackerProTests` must return zero hits after this task.

- [ ] **Step 1: Delete files + pbxproj entries + tests. Step 2: grep check → zero references. Step 3: Full suite + build → PASS. Step 4: Commit** — `refactor: remove old staged hand entry flow (replaced by Capture Screen)`

---

### Task 17: Final verification + release checklist

- [ ] **Step 1: Full test suite** — expected: all green (old count 68 − removed + ~15 new).
- [ ] **Step 2: End-to-end simulator run** (the /verify pass): active tournament → `stub KQs` in chat → stack update 390k → level 21 blinds → stack update 985k → swing prompt appears → reply "AK suited" → stub attached → break started → debrief asks about any remaining gap → reply "blinds mostly" → FadeNote; Hands pane → enrich the AKs stub through the Capture Screen → save → stack pushed; export recap → contains Pending Hands (any leftover), FadeNote in timeline, enriched hand with villains.
- [ ] **Step 3: CloudKit note for the user** — before the next App Store build: run the dev build so `CD_HandStub`, `CD_FadeNote`, `CD_HandVillain` and the new `CD_Hand`/`CD_Tournament` fields materialize (create one stub with an enriched hand + one fade note in dev), then deploy schema to Production in CloudKit Console.
- [ ] **Step 4: Update `docs/` + memory** — mark this plan executed; note the deferred voice plan needs the OnCall Scribe repo path.
- [ ] **Step 5: Commit any stragglers; do not bump the version** — the user manages version bumps in Xcode (always `grep -m2 MARKETING_VERSION StackTrackerPro.xcodeproj/project.pbxproj` first if asked to bump).

---

## Self-Review (performed at plan time)

- **Spec coverage:** F1 → Tasks 1–5 (stub model, sheet, button, shorthand, pending section in T15); F2 → Tasks 6–7; F6 → Task 8; F5 → Tasks 10–15 (5.1 layout T14; 5.2 villain model T10/T12; 5.4 result flow T13; 5.5 mockup corrections: 13-rank grid in T4's `CardPickerGrid`, no street selector/pot input/players input anywhere — computed in T12; 5.6 acceptance in T13 test + T14 smoke); Inference Requirements table → enforced by engine design (T12/T13); recap lines → Task 9. F4 (voice) + F5.3 (hybrid dictation) explicitly deferred to a follow-up plan — the spec's mic entry points are the only uncovered items, by scope decision with the user.
- **Placeholder scan:** none — every code step has concrete code; Task 12 Step 3 delegates detailed replay mechanics to the stated "Core rules" contract which enumerates every rule.
- **Type consistency:** `HandStub.setStatus(_:)`, `StubOrigin.swingDetected`, `HoleCardShorthand.normalize/display/exactCards/isExact`, `SwingDetector.isSwing/shouldSuppress`, `DebriefGap(start:end:delta:)`, `HandCaptureModel.add(action:toAmount:)/addBoardCard/undoLast/truncate(toLedgerIndex:)/save(into:tournament:cashSession:sourceStub:tableSize:)` used identically across tasks. `RelativeStack` defined once (Task 10) and consumed by Tasks 12–14.
- **Known verification points for the implementer:** exact `Tournament`/`ChatMessage`/`StackEntry` initializer and property names (`timestamp`, `sender`, `sortedChatMessages`) must be checked against the files before coding — flagged inline where relied upon.
