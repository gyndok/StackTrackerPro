# Voice Hand Entry (Hand Logging v2 — Feature 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dictate a poker hand in natural speech and land on the Hand Capture Screen fully populated — on-device transcription (SpeechAnalyzer) → on-device structured parsing (FoundationModels) → replayed through the existing HandCaptureModel engine, with anything uncertain surfaced as tappable disambiguation chips. Never auto-commit: the populated Capture Screen IS the preview.

**Architecture:** Three new units with hard boundaries: `DictationEngine` (mic → live transcript, hardware-facing, not unit-testable), `HandTranscriptParser` (transcript + table context → `ParsedHandDraft` via FoundationModels guided generation, availability-gated), and `VoiceHandMapper` (pure function: draft → mutations on `HandCaptureModel` + `[MappingIssue]` — the deterministic, fully-tested core). UI is one reusable `DictationSheet` plus mic buttons on the three entry surfaces. Voice and taps fill the same engine state interchangeably (spec 5.3).

**Tech Stack:** Speech framework (SpeechAnalyzer/SpeechTranscriber, iOS 26), AVFoundation (AVAudioEngine mic tap), FoundationModels (@Generable guided generation), SwiftUI. No new dependencies, **no new SwiftData models or fields** (transcripts are ephemeral — zero CloudKit schema impact).

## Global Constraints

- **iOS 26 deployment floor is already set** — SpeechAnalyzer and FoundationModels both require it; no availability regression to worry about, but BOTH must degrade gracefully when the on-device models aren't present (mirror `AIPokerParser.isAvailable` / `statusMessage` pattern exactly, including the `#if canImport` fallback and the NSLock-guarded 60s availability cache).
- **A `LanguageModelSession` is NEVER reused across parses** — fresh session per call, same rationale documented in AIPokerParser.swift:118-124.
- **Never auto-commit a voice parse** (spec F4): the mapper populates the model; the user reviews on the Capture Screen and taps Save themselves. No code path may call `model.save(...)` as a result of dictation.
- **Privacy:** audio never leaves the device; the transcript is only ever passed to the on-device FoundationModels session. No transcript persistence.
- **Mic permission:** add `INFOPLIST_KEY_NSMicrophoneUsageDescription = "StackTrackerPro uses the microphone to dictate poker hands for the hand logger.";` to the APP target's build configurations — find every block containing `INFOPLIST_KEY_NSCameraUsageDescription` in `StackTrackerPro.xcodeproj/project.pbxproj` (~line 871) and add the mic key alongside it in each. SpeechAnalyzer does not use the legacy SFSpeechRecognizer authorization; if runtime testing proves otherwise, also add `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` the same way and request `SFSpeechRecognizer.requestAuthorization` — verify on device and document what you found.
- **pbxproj hand-wiring:** four entries per new file, IDs continue from `7E5700000000000000000129` (0113–0128 are taken). Assignments: DictationEngine.swift fileRef `...0129`/buildFile `...012A`; HandTranscriptParser.swift `...012B`/`...012C`; VoiceHandMapper.swift `...012D`/`...012E`; DictationSheet.swift `...012F`/`...0130`.
- **Test command:** `xcodebuild test -project StackTrackerPro.xcodeproj -scheme StackTrackerPro -destination 'platform=iOS Simulator,name=iPhone Air,OS=26.5'` (`-only-testing:` while iterating). Suite is currently 117 tests, all green — keep it that way.
- **Test hygiene (project convention):** no raw array indexing after non-halting asserts (guard+XCTFail or XCTUnwrap); `@MainActor` where the tested type is; any static test seams reset via `defer`.
- **FoundationModels tests are non-deterministic:** gate every test that invokes the real model with `try XCTSkipUnless(HandTranscriptParser.shared.isAvailable, "on-device model unavailable")` and assert **loose invariants** (cards mentioned appear, action count ≥ N), never exact equality on model output. All exact-equality testing belongs to the deterministic mapper.
- **Commits:** direct to `main`, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **SpeechAnalyzer API caution:** the reference code in Task 3 is from the iOS 26 SDK surface but this API is new — if actual SDK signatures differ, adapt to the real SDK (compiler is the authority) and record every deviation in your report. If the API shape differs so much the design doesn't hold, STOP and report BLOCKED rather than improvising a different architecture.

## Existing Interfaces (verified 2026-07-09 at HEAD 170c0de)

- `HandCaptureModel` (`StackTrackerPro/Managers/HandCaptureModel.swift`): `heroPosition: HeroPosition?` (didSet rebuilds), `heroCards: [PlayingCard]`, `addCard(_:) -> Bool`, `addVillain(position:relative:approxStack:)`, `villains: [VillainDraft]` (private(set); `VillainDraft` has `id/position/relative/approxStack/shownHolding/mucked`), `add(action:toAmount:)`, `addBoardCard(_:) -> Bool`, `participantToAct: Participant?`, `legalActions: [HandActionType]`, `currentBet: Int`, `boardCardsNeeded: Int`, `currentStreet: HandStreet`, `isHandOver: Bool`, `needsShowdown: Bool`, `setShownHolding(_:for:)`, `setMucked(_:)`, `dealtCards: Set<PlayingCard>`, `pot: Int`, `narration: String`, `undoLast()`, `heroStackBefore: Int`, `heroCardCount: Int`, init `(levelNumber:smallBlind:bigBlind:ante:heroCardCount:heroStackBefore:)` and `(stub:heroCardCount:)`.
- `HandCaptureView(tournament:cashSession:stub:onSaved:)` (`StackTrackerPro/Views/Session/HandCaptureView.swift`): toolbar currently has undo + close; the model lives in `@State`.
- `HandStubSheet(onSave:)` (`StackTrackerPro/Views/Session/HandStubSheet.swift`), presented from `ActiveSessionView` (`.sheet(isPresented: $showStubSheet)`).
- `HandsPane` (`StackTrackerPro/Views/Session/HandsPane.swift`): pending stub rows, `fullScreenCover(item:)` presenting HandCaptureView; `@Environment(TournamentManager.self)`.
- `AIPokerParser` (`StackTrackerPro/Managers/AIPokerParser.swift`): the FoundationModels house pattern to mirror.
- `HoleCardShorthand.normalize/exactCards/display` (`StackTrackerPro/Managers/HoleCardShorthand.swift`); `PlayingCard.parseList` (space-separated "Jh 8h 4d").
- `HeroPosition` raw values: "UTG","UTG+1","MP","LJ","HJ","CO","BTN","SB","BB". `RelativeStack` raw values: "Covers me","~Same","Shorter". `HandActionType`: fold/check/call/bet/raise/allIn. `HandStreet`: preflop/flop/turn/river.

---

### Task 1: ParsedHandDraft schema + HandTranscriptParser

**Files:**
- Create: `StackTrackerPro/Managers/HandTranscriptParser.swift`
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (IDs 012B/012C, Managers group)
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Produces:
  - `struct HandContext { let levelNumber: Int; let smallBlind: Int; let bigBlind: Int; let ante: Int; let heroStack: Int; let heroCardCount: Int }`
  - `@Generable struct ParsedHandDraft` (+ `SpokenVillain`, `SpokenAction`) — see Step 3; available (with plain non-Generable mirror) even when FoundationModels is absent so the mapper (Task 2) always compiles.
  - `final class HandTranscriptParser` — `static let shared`, `var isAvailable: Bool`, `var statusMessage: String`, `func parse(transcript: String, context: HandContext) async throws -> ParsedHandDraft`, `static func instructions(for context: HandContext) -> String` (pure, deterministic, testable).

- [ ] **Step 1: Write the failing tests**

```swift
func testHandTranscriptInstructionsIncludeContext() {
    let ctx = HandContext(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                          ante: 25_000, heroStack: 390_000, heroCardCount: 2)
    let instructions = HandTranscriptParser.instructions(for: ctx)
    XCTAssertTrue(instructions.contains("10,000/25,000"))
    XCTAssertTrue(instructions.contains("390,000"))
    XCTAssertTrue(instructions.contains("Jh 8h 4d"))       // canonical card format example
    XCTAssertTrue(instructions.lowercased().contains("only the transcript provided"))
}

func testHandTranscriptParserParsesReferenceHand() async throws {
    let parser = HandTranscriptParser.shared
    try XCTSkipUnless(parser.isAvailable, "on-device model unavailable")
    let ctx = HandContext(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                          ante: 25_000, heroStack: 390_000, heroCardCount: 2)
    let transcript = """
        I had kings on the button, king of hearts king of diamonds. UTG covered me and \
        raised to seventy five thousand, I three-bet to two hundred K, he jammed, I called. \
        Board came jack of hearts eight of hearts four of diamonds, deuce of clubs, three of spades. \
        He showed nine ten of hearts.
        """
    let draft = try await parser.parse(transcript: transcript, context: ctx)
    // Loose invariants only — model output is non-deterministic.
    XCTAssertEqual(HoleCardShorthand.normalize(draft.heroCards ?? ""), "Kh Kd")
    XCTAssertEqual(draft.heroPosition?.uppercased(), "BTN")
    XCTAssertGreaterThanOrEqual(draft.villains.count, 1)
    XCTAssertGreaterThanOrEqual(draft.actions.count, 3)
    let flopCards = PlayingCard.parseList(draft.flop ?? "")
    XCTAssertEqual(flopCards.count, 3)
}
```

- [ ] **Step 2: Run to verify failure** (`cannot find 'HandTranscriptParser'`).

- [ ] **Step 3: Implement `HandTranscriptParser.swift`.** Mirror AIPokerParser's structure exactly (canImport guard, NSLock availability cache with 60s recheck, fresh session per parse, availability recheck on error). The schema and instructions:

```swift
import Foundation

/// Table context injected into the parsing instructions so spoken numbers
/// resolve correctly ("seventy five" at 10K/25K blinds means 75,000 chips).
struct HandContext {
    let levelNumber: Int
    let smallBlind: Int
    let bigBlind: Int
    let ante: Int
    let heroStack: Int
    let heroCardCount: Int
}

#if canImport(FoundationModels)
import FoundationModels

@Generable
struct SpokenVillain {
    @Guide(description: "Villain's seat: one of UTG, UTG+1, MP, LJ, HJ, CO, BTN, SB, BB. Null if not stated.")
    var position: String?
    @Guide(description: "Relative stack: 'covers' if they cover the hero, 'same' if similar, 'shorter' if shorter. Null if not stated.")
    var relativeStack: String?
    @Guide(description: "Villain's approximate chip count if a number was stated.")
    var approxStack: Int?
    @Guide(description: "Villain's shown hole cards at showdown in canonical form like 'Th 9h'. Null if mucked or unknown.")
    var shownCards: String?
}

@Generable
struct SpokenAction {
    @Guide(description: "Who acted: 'hero' or a seat name (UTG, MP, CO, BTN, SB, BB...).")
    var actor: String?
    @Guide(description: "Street: preflop, flop, turn, or river.")
    var street: String?
    @Guide(description: "Action: fold, check, call, bet, or raise.")
    var action: String?
    @Guide(description: "Total chip amount the action is TO (a raise to 75,000 → 75000). Null for fold/check/call.")
    var amount: Int?
    @Guide(description: "True if the action was all-in (jam, shove, ship).")
    var isAllIn: Bool?
}

@Generable
struct ParsedHandDraft {
    @Guide(description: "Hero's seat: one of UTG, UTG+1, MP, LJ, HJ, CO, BTN, SB, BB.")
    var heroPosition: String?
    @Guide(description: "Hero's hole cards, canonical: exact like 'Kh Kd' when suits were spoken, else rank shorthand like 'KQs' or '99'.")
    var heroCards: String?
    @Guide(description: "Every opponent mentioned, one entry per distinct seat.")
    var villains: [SpokenVillain]
    @Guide(description: "Every action in strict chronological order, including hero's.")
    var actions: [SpokenAction]
    @Guide(description: "Flop cards, canonical like 'Jh 8h 4d'. Null if the hand ended preflop.")
    var flop: String?
    @Guide(description: "Turn card, canonical like '2c'. Null if not reached.")
    var turn: String?
    @Guide(description: "River card, canonical like '3s'. Null if not reached.")
    var river: String?
}
#else
// Plain mirrors so VoiceHandMapper compiles without FoundationModels.
struct SpokenVillain { var position: String?; var relativeStack: String?; var approxStack: Int?; var shownCards: String? }
struct SpokenAction { var actor: String?; var street: String?; var action: String?; var amount: Int?; var isAllIn: Bool? }
struct ParsedHandDraft {
    var heroPosition: String?; var heroCards: String?
    var villains: [SpokenVillain] = []; var actions: [SpokenAction] = []
    var flop: String?; var turn: String?; var river: String?
}
#endif
```

`instructions(for:)` (pure `static func` outside the canImport so the deterministic test always runs) must state: parse ONLY the transcript provided, never invent actions; cards in canonical two-char form ("Jh 8h 4d" example verbatim); spoken numbers are chips scaled to the stakes — include the literal context lines `Blinds are 10,000/25,000 with a 25,000 ante` style via `.formatted()`, `Hero's stack is 390,000`, `"seventy five" or "seventy five K" near these stakes means 75,000`, `"five one" means 51,000 when a bet, not 5.1`; jam/shove/ship = all-in; "he had me covered" → relativeStack covers.

`parse(transcript:context:)`: guard isAvailable else throw `AIParserError.modelUnavailable`; `LanguageModelSession(instructions: Self.instructions(for: context))`; `session.respond(to: transcript, generating: ParsedHandDraft.self)`; recheck availability on error (copy AIPokerParser's pattern).

- [ ] **Step 4: Run both tests** — instructions test must PASS deterministically; the parser test passes or SKIPS depending on model availability. Run the parser test 3 consecutive times if it's runnable — loosen assertions if any run fails on model variance (that's what loose invariants are for).
- [ ] **Step 5: pbxproj (012B/012C). Full suite. Commit** — `feat: hand transcript parser (FoundationModels)`

---

### Task 2: VoiceHandMapper — draft → engine mutations + disambiguation issues

**Files:**
- Create: `StackTrackerPro/Managers/VoiceHandMapper.swift`
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (IDs 012D/012E, Managers group)
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces:**
- Consumes: `ParsedHandDraft`/`SpokenVillain`/`SpokenAction` (Task 1), the full `HandCaptureModel` mutation surface (see Existing Interfaces).
- Produces:
  - `enum MappingIssue: Equatable, Identifiable` with cases `unknownHeroCards(String)`, `unknownPosition(String)`, `duplicateVillainSeat(String)`, `outOfTurnAction(actor: String, street: String)`, `missingAmount(actor: String, street: String)`, `invalidCard(text: String, place: String)`, `boardMismatch(String)`, `unknownShownCards(actor: String, text: String)`; `var id: String` (case name + payload), `var label: String` (human chip text, e.g. `"Couldn't place UTG's flop raise — add it by tap"`).
  - `@MainActor enum VoiceHandMapper { static func apply(_ draft: ParsedHandDraft, to model: HandCaptureModel) -> [MappingIssue] }`

**Mapping rules (binding):**
1. Hero position: parse `draft.heroPosition` against `HeroPosition` raw values (case-insensitive, accept "UTG1"→"UTG+1"). Unknown/nil → leave model untouched + `unknownPosition`. Set BEFORE villains/actions (didSet rebuilds).
2. Hero cards: `HoleCardShorthand.normalize(draft.heroCards ?? "")`; exact → `model.addCard` each (respecting `heroCardCount`); suit-agnostic → leave cards empty + `unknownHeroCards(normalized)` (the chip tells the user to pick suits); nil/unparseable → `unknownHeroCards(raw)`.
3. Villains: for each with a valid position not equal to hero's and not already used → `model.addVillain(position:relative:approxStack:)` where relativeStack "covers*"→`.coversHero`, "same"/"similar"→`.similar`, "short*"→`.shorter`, default `.coversHero`. Invalid position → `unknownPosition`; duplicate seat → `duplicateVillainSeat`.
4. Actions, in draft order: resolve actor → participant ("hero" or hero's own seat name → `.hero`; a villain's seat → that villain). Then compare with `model.participantToAct`: match → `model.add(action:toAmount:)`; mismatch or unresolvable actor → `outOfTurnAction` and SKIP (never force the engine out of order — the engine's turn computation is authoritative). Action mapping: fold/check/call direct (toAmount 0); bet/raise with amount → that amount; `isAllIn == true` → `.allIn` with amount ?? (hero ? `model.heroStackBefore` : skip-with-`missingAmount`); bet/raise with nil amount → `missingAmount` + skip.
5. Board: whenever `model.boardCardsNeeded > 0` between actions, consume the pending street's cards (`draft.flop`→3 via `PlayingCard.parseList`, then `turn`, then `river`, 1 each). Wrong count / unparseable / rejected by `addBoardCard` (duplicate) → `invalidCard`/`boardMismatch` + stop consuming that street. Board consumption is interleaved with action application: apply actions until `participantToAct == nil && boardCardsNeeded > 0`, feed board, continue.
6. Showdown: after all actions, for each villain whose `shownCards` parses to exactly 2 cards not already dealt → `model.setShownHolding`; unparseable → `unknownShownCards`. (Explicit mucks stay untouched — user taps Mucked.)
7. Never throw; every anomaly becomes an issue. An empty draft returns issues, not a crash.

- [ ] **Step 1: Write the failing tests** (the deterministic heart of this plan — write ALL of these):

```swift
@MainActor
func testMapperAppliesReferenceHandCleanly() throws {
    let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                 ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
    var draft = ParsedHandDraft()
    draft.heroPosition = "BTN"
    draft.heroCards = "Kh Kd"
    draft.villains = [SpokenVillain(position: "UTG", relativeStack: "covers", approxStack: nil, shownCards: "9h Th")]
    draft.actions = [
        SpokenAction(actor: "UTG", street: "preflop", action: "raise", amount: 75_000, isAllIn: false),
        SpokenAction(actor: "hero", street: "preflop", action: "raise", amount: 200_000, isAllIn: false),
        SpokenAction(actor: "UTG", street: "preflop", action: "raise", amount: 390_000, isAllIn: true),
        SpokenAction(actor: "hero", street: "preflop", action: "call", amount: nil, isAllIn: false),
    ]
    draft.flop = "Jh 8h 4d"; draft.turn = "2c"; draft.river = "3s"

    let issues = VoiceHandMapper.apply(draft, to: model)
    XCTAssertTrue(issues.isEmpty, "unexpected issues: \(issues.map(\.label))")
    XCTAssertTrue(model.isHandOver)
    XCTAssertEqual(model.pot, 840_000)
    XCTAssertEqual(model.board.count, 5)
    let villain = try XCTUnwrap(model.villains.first)
    XCTAssertEqual(villain.shownHolding.map(\.raw), ["9h", "Th"])
    XCTAssertEqual(model.computedWinners, [.hero])
}

@MainActor
func testMapperFlagsOutOfTurnAndSkips() {
    let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                 ante: 200, heroCardCount: 2, heroStackBefore: 40_000)
    var draft = ParsedHandDraft()
    draft.heroPosition = "BTN"
    draft.heroCards = "As Kd"
    draft.villains = [SpokenVillain(position: "UTG", relativeStack: "shorter", approxStack: nil, shownCards: nil)]
    // Hero acts first in the draft but UTG is first to act — out of turn.
    draft.actions = [SpokenAction(actor: "hero", street: "preflop", action: "raise", amount: 500, isAllIn: false)]
    let issues = VoiceHandMapper.apply(draft, to: model)
    XCTAssertTrue(issues.contains { if case .outOfTurnAction = $0 { return true }; return false })
    XCTAssertTrue(model.ledger.isEmpty)   // skipped, not force-applied
}

@MainActor
func testMapperFlagsSuitAgnosticHeroCards() {
    let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                 ante: 200, heroCardCount: 2, heroStackBefore: 40_000)
    var draft = ParsedHandDraft()
    draft.heroPosition = "CO"
    draft.heroCards = "KQ suited"
    let issues = VoiceHandMapper.apply(draft, to: model)
    XCTAssertTrue(model.heroCards.isEmpty)
    XCTAssertTrue(issues.contains { if case .unknownHeroCards(let s) = $0 { return s == "KQs" }; return false })
}

@MainActor
func testMapperFlagsMissingAmountAndDuplicateSeat() {
    let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                 ante: 200, heroCardCount: 2, heroStackBefore: 40_000)
    var draft = ParsedHandDraft()
    draft.heroPosition = "BTN"
    draft.heroCards = "Ah Kh"
    draft.villains = [
        SpokenVillain(position: "UTG", relativeStack: nil, approxStack: nil, shownCards: nil),
        SpokenVillain(position: "UTG", relativeStack: nil, approxStack: nil, shownCards: nil),
    ]
    draft.actions = [SpokenAction(actor: "UTG", street: "preflop", action: "raise", amount: nil, isAllIn: false)]
    let issues = VoiceHandMapper.apply(draft, to: model)
    XCTAssertEqual(model.villains.count, 1)
    XCTAssertTrue(issues.contains { if case .duplicateVillainSeat = $0 { return true }; return false })
    XCTAssertTrue(issues.contains { if case .missingAmount = $0 { return true }; return false })
}

@MainActor
func testMapperEmptyDraftProducesIssuesNotCrash() {
    let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                 ante: 200, heroCardCount: 2, heroStackBefore: 40_000)
    let issues = VoiceHandMapper.apply(ParsedHandDraft(), to: model)
    XCTAssertFalse(issues.isEmpty)
    XCTAssertNil(model.heroPosition)
}
```

(If `SpokenVillain`/`SpokenAction` memberwise inits differ under @Generable, construct with `var` + property assignment — adjust tests accordingly, not the schema.)

- [ ] **Step 2: Run → fail.** Step 3: **Implement** per the seven binding rules. Step 4: **Run → all green.** Step 5: **pbxproj (012D/012E). Full suite. Commit** — `feat: voice hand mapper with disambiguation issues`

---

### Task 3: DictationEngine (mic → live on-device transcript)

**Files:**
- Create: `StackTrackerPro/Managers/DictationEngine.swift`
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (IDs 0129/012A, Managers group); mic-permission build settings (see Global Constraints)
- Test: `StackTrackerProTests/StackTrackerProTests.swift` (state-machine only — no hardware in CI)

**Interfaces:**
- Produces: `@MainActor @Observable final class DictationEngine` — `enum State: Equatable { case idle, requestingPermission, preparingModel, listening, stopping, error(String) }`, `private(set) var state: State`, `private(set) var finalizedTranscript: String`, `private(set) var volatileTranscript: String`, `var fullTranscript: String { finalizedTranscript + volatileTranscript }`, `func start() async`, `func stop() async -> String` (returns the final transcript), `static var isSupported: Bool` (locale asset installable/installed).

- [ ] **Step 1: Failing state test**

```swift
@MainActor
func testDictationEngineInitialStateAndTranscriptComposition() {
    let engine = DictationEngine()
    XCTAssertEqual(engine.state, .idle)
    XCTAssertEqual(engine.fullTranscript, "")
}
```

(That's the honest limit of CI coverage — the rest is device-manual, Task 6.)

- [ ] **Step 2: Run → fail.** Step 3: **Implement.** Reference shape (VERIFY every signature against the SDK — see Global Constraints caution):

```swift
import Foundation
import Observation
import AVFoundation
import Speech

/// On-device dictation: AVAudioEngine mic tap streamed into the iOS 26
/// SpeechAnalyzer. Audio and transcript never leave the device.
@MainActor @Observable
final class DictationEngine {
    enum State: Equatable {
        case idle, requestingPermission, preparingModel, listening, stopping
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var finalizedTranscript = ""
    private(set) var volatileTranscript = ""
    var fullTranscript: String { finalizedTranscript + volatileTranscript }

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    func start() async {
        guard state == .idle || state.isError else { return }
        finalizedTranscript = ""; volatileTranscript = ""

        state = .requestingPermission
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .error("Microphone access denied — enable it in Settings.")
            return
        }

        state = .preparingModel
        do {
            let locale = Locale.current
            let transcriber = SpeechTranscriber(locale: locale,
                                                transcriptionOptions: [],
                                                reportingOptions: [.volatileResults],
                                                attributeOptions: [])
            self.transcriber = transcriber
            // Download the on-device model if this locale isn't installed yet.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

            let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
            self.inputBuilder = builder

            resultsTask = Task { [weak self] in
                guard let transcriber = self?.transcriber else { return }
                do {
                    for try await result in transcriber.results {
                        guard let self else { return }
                        let text = String(result.text.characters)
                        if result.isFinal {
                            self.finalizedTranscript += text + " "
                            self.volatileTranscript = ""
                        } else {
                            self.volatileTranscript = text
                        }
                    }
                } catch {
                    self?.state = .error("Transcription failed: \(error.localizedDescription)")
                }
            }

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = audioEngine.inputNode
            let micFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
                self?.feed(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            try await analyzer.start(inputSequence: stream)
            state = .listening
        } catch {
            teardownAudio()
            state = .error("Couldn't start dictation: \(error.localizedDescription)")
        }
    }

    nonisolated private func feed(_ buffer: AVAudioPCMBuffer) {
        Task { @MainActor in
            guard state == .listening, let format = analyzerFormat else { return }
            if buffer.format == format {
                inputBuilder?.yield(AnalyzerInput(buffer: buffer))
                return
            }
            if converter == nil { converter = AVAudioConverter(from: buffer.format, to: format) }
            guard let converter,
                  let out = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(format.sampleRate / 10)) else { return }
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            if error == nil { inputBuilder?.yield(AnalyzerInput(buffer: out)) }
        }
    }

    func stop() async -> String {
        guard state == .listening else { return fullTranscript.trimmingCharacters(in: .whitespaces) }
        state = .stopping
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        teardownAudio()
        state = .idle
        return fullTranscript.trimmingCharacters(in: .whitespaces)
    }

    private func teardownAudio() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        analyzer = nil; transcriber = nil; inputBuilder = nil; converter = nil
    }
}

private extension DictationEngine.State {
    var isError: Bool { if case .error = self { return true }; return false }
}
```

- [ ] **Step 4: State test green; BUILD must succeed** (this is where SDK-signature reality hits — adapt and document). Step 5: **Add the mic-permission INFOPLIST_KEY to every app-target build config. pbxproj (0129/012A). Full suite. Commit** — `feat: on-device dictation engine (SpeechAnalyzer)`

---

### Task 4: DictationSheet + Capture Screen mic integration

**Files:**
- Create: `StackTrackerPro/Views/Session/DictationSheet.swift`
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift` (toolbar mic button, `autoStartDictation` param, issues chip row)
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (IDs 012F/0130, Session group)

**Interfaces:**
- Consumes: `DictationEngine`, `HandTranscriptParser`, `VoiceHandMapper`, `HandCaptureModel`.
- Produces: `DictationSheet(context: HandContext, onResult: (ParsedHandDraft) -> Void)`; `HandCaptureView` gains `autoStartDictation: Bool = false` (trailing default → existing call sites unaffected) and `@State private var mappingIssues: [MappingIssue]`.

**DictationSheet behavior:** on appear, `await engine.start()`; shows a pulsing mic indicator while `.listening`, the live `fullTranscript` in a scrolling text area, state-specific messages for `.preparingModel` ("Downloading speech model…") and `.error` (message + Retry button), and a prominent "Done — Build Hand" button that runs: `let transcript = await engine.stop()` → guard non-empty → `HandTranscriptParser.shared.parse(transcript:context:)` (spinner while parsing; on `isAvailable == false` show `statusMessage` and keep the raw transcript visible so the user can retry or cancel) → `onResult(draft)` → dismiss. Cancel button stops the engine and dismisses without calling `onResult`.

**HandCaptureView integration:**
- Toolbar gains `Button { showDictation = true } label: { Image(systemName: "mic.fill") }` (the slot Task 14 of the v2 plan reserved). `.sheet(isPresented: $showDictation) { DictationSheet(context: handContext, onResult: applyDraft) }` where `handContext` is built from the model's level/blinds/ante/heroStackBefore/heroCardCount.
- `applyDraft(_:)`: `mappingIssues = VoiceHandMapper.apply(draft, to: model)` — voice fills the SAME state as taps; the narration bar/ledger update live because the model is `@Observable`.
- **Issues chip row**: when `!mappingIssues.isEmpty`, a horizontal `ScrollView` of orange chips above the ledger, each showing `issue.label` with an ✕ to dismiss (`mappingIssues.removeAll { $0.id == issue.id }`). The standard pickers/action row on the same screen are the resolution mechanism (v1 disambiguation: informational chips + the always-present tap UI; auto-focusing pickers per chip is deliberately out of scope).
- `autoStartDictation`: `.onAppear { if autoStartDictation && model.ledger.isEmpty { showDictation = true } }`.
- **Never auto-commit**: `applyDraft` must not call save; Save stays behind `model.isResolvable` exactly as today.

- [ ] **Step 1: Implement DictationSheet.** Step 2: **Integrate into HandCaptureView.** Step 3: **Build clean (`xcodebuild build ...`), full suite still green.** Step 4: **pbxproj (012F/0130). Commit** — `feat: dictation sheet and capture screen hybrid voice entry`

---

### Task 5: Entry points — stub sheet "talk instead" + pending-row mic

**Files:**
- Modify: `StackTrackerPro/Views/Session/HandStubSheet.swift` (mic button → `onDictate` closure)
- Modify: `StackTrackerPro/Views/Session/ActiveSessionView.swift` (present capture with autoStartDictation from the stub sheet's mic)
- Modify: `StackTrackerPro/Views/Session/HandsPane.swift` (mic accessory on pending stub rows → capture with autoStartDictation; "+" long-press or menu alternative NOT added — keep the single "+" tap behavior)

**Details:**
- `HandStubSheet` gains `let onDictate: (() -> Void)?` — when non-nil, a "🎙 Talk instead" bordered button under the quick chips; tapping calls `onDictate()` then `dismiss()`. All construction sites updated (ActiveSessionView passes a closure; anywhere else passes nil).
- `ActiveSessionView`: `@State private var showVoiceCapture = false`; the stub sheet's `onDictate` sets it; `fullScreenCover(isPresented: $showVoiceCapture) { HandCaptureView(tournament: tournament, cashSession: nil, stub: nil, autoStartDictation: true, onSaved: { _ in }) }` (match the argument order/labels of the actual initializer — check `HandCaptureView.swift` before writing; `autoStartDictation` slots wherever the initializer puts it).
- `HandsPane`: pending stub rows gain a trailing `mic.fill` button (not swipe — visible affordance) that routes to the SAME `fullScreenCover(item:)` used by row-tap but with `autoStartDictation: true` — extend the presented-item type to carry the flag (e.g. wrap in a small `struct CapturePresentation: Identifiable { let stub: HandStub?; let autoDictate: Bool; var id: ... }`) rather than adding parallel state. `isReadOnly` hides the mic button.
- Stub-context wins: launching from a stub already prefills level/blinds/stack from the stub (existing `init(stub:)`), and `HandContext` is built from the model — so "stub context wins for level/blinds/stack; voice wins for actions/cards" (spec F4 merge rule) holds by construction. The ±10-minute stub-merge prompt for free-floating dictations is explicitly deferred (YAGNI: every voice entry point here already knows its stub or is deliberately stub-free).

- [ ] **Step 1: Implement all three.** Step 2: **Build clean + full suite green.** Step 3: **Commit** — `feat: voice entry points (stub sheet, pending rows)`

---

### Task 6: Final verification + device checklist

- [ ] **Step 1: Full suite** — expect 117 + new tests, all green; run the mapper tests plus the parser availability-gated test 3× for stability.
- [ ] **Step 2: Build + simulator launch smoke** (mirror v2's Task 17: install, launch, screenshot, open the Capture Screen, tap the mic — in the simulator the expected outcome is a graceful `.preparingModel`→`.error` or permission path, NOT a crash).
- [ ] **Step 3: Write the device-manual checklist** into the report and `docs/superpowers/plans/2026-07-09-voice-hand-entry.md` footer (the user runs this on their iPhone — the true acceptance test):
  1. First mic tap → permission prompt with the new usage string.
  2. Speech model downloads once, then dictation starts in <2s on subsequent uses.
  3. Speak the Event #86 reference hand (20s) → Capture Screen populates: KK on the button, UTG covers, 3-bet/jam/call line, full board, 9T shown, pot 840K, winner Hero — with ≤2 disambiguation chips to resolve (spec F4 acceptance).
  4. Fix one sizing by tap after dictating (hybrid check).
  5. Airplane mode: everything still works end-to-end (all on-device).
  6. Save → stack pushes → stub (if launched from one) shows enriched.
- [ ] **Step 4: Update memory** (stacktrackerpro-build-setup: no new CloudKit types from this plan; voice is schema-neutral) **and mark this plan executed. Commit** — `docs: mark voice hand entry plan executed`

---

## Self-Review (performed at plan time)

- **Spec coverage (F4 + 5.3):** on-device transcription ✓ (T3); parser handles vernacular ✓ (T1 instructions); preview-never-auto-commit ✓ (T4 binding); entry points: capture-screen mic ✓ (T4), stub sheet ✓ (T5), pending row ✓ (T5) — the spec's fourth entry point (long-press chat mic) is dropped: the chat field has no mic today and adding one is scope without demand; offline queueing obsolete (parsing is on-device — noted in header); ±10-min stub merge deferred with rationale (T5); acceptance criterion (reference hand, ≤2 disambiguation taps) in the device checklist (T6); hybrid voice+tap ✓ (T4 applyDraft into the shared model). Disambiguation chips are informational-v1 (chip + always-present pickers), a deliberate narrowing of 5.3's tap-to-open-picker — flagged here for the record.
- **Placeholder scan:** clean — every code step has concrete code; T4/T5 UI steps specify exact behaviors and bindings.
- **Type consistency:** `ParsedHandDraft/SpokenVillain/SpokenAction` (T1) consumed by T2 tests/mapper and T4 `onResult`; `HandContext` produced T1, consumed T4; `MappingIssue.id/.label` used by T4 chips; `DictationEngine.state/fullTranscript/start/stop` used by T4 sheet; `autoStartDictation` produced T4, consumed T5.
- **Known risk, named:** SpeechAnalyzer SDK-signature drift (T3) — explicitly instructed to adapt-and-document or BLOCK, never improvise architecture.
