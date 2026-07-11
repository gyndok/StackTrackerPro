# Screenshot Demo Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `-DemoData`/`-DemoRoute` launch arguments put the app into a DEBUG-only, in-memory, CloudKit-free demo world posed on any of 8 screens; a script captures App Store-ready PNGs.

**Architecture:** One new DEBUG-gated file (`DemoData.swift`) owns argument parsing, seeding, and the capture-screen pose; five existing files gain small `#if DEBUG` hooks (container swap, splash skip, tab/pane/sheet routing, dictation preview); a shell script drives the simulator. Spec: `docs/superpowers/specs/2026-07-11-screenshot-demo-mode-design.md`.

**Tech Stack:** SwiftUI, SwiftData (in-memory config), simctl. No new dependencies.

## Global Constraints

- Every code addition is inside `#if DEBUG` or is a DEBUG-only-usable default parameter; a normal launch (no args) must behave exactly as today, and Release must build clean: `xcodebuild build -configuration Release -destination 'generic/platform=iOS Simulator'`.
- Demo container: `ModelConfiguration(schema:, isStoredInMemoryOnly: true)` with **no** `cloudKitDatabase` — demo data must never touch the real store or iCloud.
- No `HandCaptureModel` engine changes — the mid-hand pose uses only existing public API (`setLevel`, `heroPosition`, `heroStackBefore`, `addCard`, `addVillain`, `add(action:toAmount:)`, `addBoardCard`).
- pbxproj hand-wiring, four entries: DemoData.swift fileRef `7E5700000000000000000135` / buildFile `...0136` (App group).
- Test command: `xcodebuild test -project StackTrackerPro.xcodeproj -scheme StackTrackerPro -destination 'platform=iOS Simulator,name=iPhone Air,OS=26.5'`. Suite is 156 green at HEAD — keep green, plus the new seed test.
- All demo dates relative to `Date.now` (no hardcoded absolute dates).
- Commits direct to `main`, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Verified Interfaces (read before coding; all at HEAD 4302b3b+)

- `Tournament(name:gameType:buyIn:entryFee:deductions:bountyAmount:guarantee:startDate:startingChips:reentryPolicy:)`; mutable: `statusRaw`, `actualStartDate`, `fieldSize`, `playersRemaining`, `venueName`, `currentBlindLevelNumber`, `finishPosition`, `payout`, `endDate`; relationships `blindLevels/stackEntries/chatMessages/hands/handStubs/fadeNotes/fieldSnapshots` (all optional arrays — append pattern `t.stackEntries?.append(e)` after insert, or set `e.tournament = t`).
- `StackEntry(timestamp:chipCount:blindLevelNumber:currentSB:currentBB:currentAnte:seatsAtTable:source:)`.
- `ChatMessage(timestamp:sender:text:isProactive:)`, `MessageSender.user/.ai`.
- `BlindLevel(levelNumber:smallBlind:bigBlind:ante:durationMinutes:isBreak:breakLabel:)`.
- `FieldSnapshot(timestamp:totalEntries:playersRemaining:avgStack:)`.
- `Hand(heroPosition:heroCardsRaw:levelNumber:smallBlind:bigBlind:ante:heroStackChips:playersRemaining:tableSize:stakes:)`; mutable `boardRaw`, `resultRaw`, `potSize`, `amountWon`, `notes`, `timestamp`; `HandAction(orderIndex:street:position:actionType:amount:isHero:)` with `act.hand = hand`; `HandVillain(orderIndex:position:relativeStack:)` + `.shownHolding`.
- `HandStub(levelNumber:smallBlind:bigBlind:ante:heroStackBefore:playersRemaining:holeCards:origin:)` (status defaults pending).
- `FadeNote(intervalStart:intervalEnd:chipDelta:userExplanation:)`.
- `CashSession(stakes:gameType:buyInTotal:venueName:date:)`; mutable `statusRaw`, `cashOut`, `endTime`.
- `ContentView` (App/ContentView.swift): `TabView` currently WITHOUT selection; tabs Play/Results/Settings.
- `TournamentListView` navigates via `NavigationLink` rows — demo bypasses it (ContentView shows `ActiveSessionView(tournament:)` directly).
- `ActiveSessionView`: `@State private var selectedPage = 0`; panes 0 graph, 1 metrics, 6 hands, 7 chat.
- `HandsPane`: `@State showEntry: Bool` (fullScreenCover → fresh `HandCaptureView`), `capturePresentation: CapturePresentation?`, `shareHand: Hand?` (sheet → `HandSharePreview`).
- `HandCaptureView`: owns `@State private var model: HandCaptureModel`; add the pose hook in its `.onAppear`.
- `DictationSheet`: renders from `engine.state` / engine transcript; fields `onResult: (String) -> Void`.
- `PlayingCard.parseList("Ks Kd")` → `[PlayingCard]`; `RelativeStack.coversHero` exists (used in HandVillain seeds).
- Splash: `StackTrackerProApp.@State showSplash = true`.

---

### Task 1: DemoData core + container/seed integration + seed test

**Files:**
- Create: `StackTrackerPro/App/DemoData.swift`
- Modify: `StackTrackerPro.xcodeproj/project.pbxproj` (IDs 0135/0136, App group, four sections)
- Modify: `StackTrackerPro/App/StackTrackerProApp.swift`
- Test: `StackTrackerProTests/StackTrackerProTests.swift`

**Interfaces (Produces — Task 2/3 rely on exactly these):**

```swift
#if DEBUG
@MainActor
enum DemoData {
    static var isActive: Bool          // args contain "-DemoData"
    static var route: String?          // value after "-DemoRoute"
    static var activeTournament: Tournament?   // set by seed()
    static var bigWinHand: Hand?               // set by seed() (share route)
    static func seed(into context: ModelContext)   // idempotent
    static func poseMidHand(_ model: HandCaptureModel)
    static var dictationPreviewTranscript: String  // fixed realistic text
}
#endif
```

- [ ] **Step 1: Write `DemoData.swift`.** Entire file wrapped in `#if DEBUG … #endif`. Contents:
  - `isActive` / `route` read `ProcessInfo.processInfo.arguments` (route = element following `"-DemoRoute"`).
  - `seed(into:)` — guard `activeTournament == nil` (idempotent). Build, in order:
    - **Active tournament** "$600 Ultra Stack", venueName "Horseshoe Las Vegas", buyIn 500, entryFee 100, guarantee 500_000, startingChips 50_000, `statusRaw = "active"`, `actualStartDate = now-4.5h`, fieldSize 2_481, playersRemaining 612, `currentBlindLevelNumber = 12`. Blind levels 1–16: 30-min levels doubling sensibly (L1 100/200/200 … L12 1_500/3_000/3_000 … L16 5_000/10_000/10_000) with 15-min breaks after L4/L8/L12 (numbered sequentially like the parser does).
    - **Stack entries** (13, timestamps spread over 4.5h, blind fields matching the level at that time): 50_000, 62_000, 58_500, 71_000, 94_000, 88_000, 61_000, 31_500, 47_000, 78_000, 104_500, 142_000, 168_500.
    - **Field snapshots**: (2_481, 1_950), (2_481, 1_240), (2_481, 612) at −3h/−90m/−10m.
    - **Chat** (10 messages, alternating user/ai, timestamps interleaved with stack entries): stack updates with zone confirmations, "bounty collected" + ai reply, "612 left" + ai reply, then the proactive pair — user "I have 168k", ai (isProactive true) "✅ Stack updated to 168,500. M-ratio: 22.4 — Green Zone.\n\nBig pot — +64,000 at Level 11. Log it? Just tell me your cards."
    - **Pending stub**: `HandStub(levelNumber: 12, smallBlind: 1_500, bigBlind: 3_000, ante: 3_000, heroStackBefore: 168_500, playersRemaining: 612, holeCards: "As Ks", origin: .manual)`.
    - **Saved hands** (5, timestamps over the session, `hand.tournament = t`):
      1. Big win (assign to `bigWinHand`): hero BTN `"Ks Kd"`, L11 1_000/2_000/2_000, stack 104_500, board `"Jh 8h 4d 2c 3s"`, resultRaw "won", potSize 142_000, amountWon 64_000; actions PRE: UTG raise 7_000 / BTN(hero) raise 21_000 / UTG call; FLOP: UTG check / hero bet 24_000 / UTG call; TURN: check-check; RIVER: UTG bet 46_000 / hero call; villain UTG `.coversHero`, shownHolding "9h Th".
      2. Loss: hero CO `"Ah Qh"`, L9, resultRaw "lost", amountWon −28_000, potSize 61_000, simple PRE/FLOP action.
      3. Preflop fold: hero UTG `"7c 2d"`, L10, resultRaw "folded", one PRE fold action.
      4. **Dictated-only**: hero MP `"Ad Qd"`, L12, **no actions**, `notes = "I had ace queen of diamonds in the middle position, raised to seventy five hundred, big blind called. Flop came queen ten four with two clubs, he check called fifteen thousand. Turn was a king, we both checked. River blanked and he folded to my thirty thousand."`, resultRaw stays default.
      5. Structured + notes: hero SB `"9s 9c"`, L8, resultRaw "won", amountWon 22_000, notes "Villain was steaming after losing the last pot."
    - **FadeNote**: interval −70m…−55m, chipDelta −27_000, "Lost a flip with AK against tens, then paid off a river bet."
    - **History**: 8 completed tournaments (venues Horseshoe Las Vegas / Wynn Las Vegas / Champions Club Texas, dates now−90d…now−7d, buyIns 250–1_700; five with `finishPosition`+`payout` — one 1st place payout 8_400 on buyIn 600 — three busts payout 0; every one `statusRaw = "completed"`, `endDate` set) + 3 completed cash sessions (stakes "2/5", buyInTotal 1_000, cashOuts 1_850/720/2_400). Net across everything clearly positive.
  - `poseMidHand(_:)` — exactly:
    ```swift
    static func poseMidHand(_ model: HandCaptureModel) {
        model.setLevel(number: 12, smallBlind: 1_500, bigBlind: 3_000, ante: 3_000)
        model.heroStackBefore = 168_500
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Ks Kd") { _ = model.addCard(c) }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 210_000)
        model.add(action: .raise, toAmount: 7_000)      // UTG (villain acts first preflop)
        model.add(action: .call, toAmount: 0)           // hero BTN closes preflop
        for c in PlayingCard.parseList("Jh 8h 4d") { _ = model.addBoardCard(c) }
        model.add(action: .bet, toAmount: 12_000)       // UTG leads flop → hero's decision is live
    }
    ```
    (Verify the turn order against `HandCaptureModel.streetOrder` while implementing; if hero acts first anywhere, reorder the action calls so the pose ends awaiting hero on the flop.)
  - `dictationPreviewTranscript` = the same prose as hand 4's notes.
- [ ] **Step 2: pbxproj** — four entries for DemoData.swift (PBXBuildFile, PBXFileReference, App group children, Sources build phase), IDs 0135/0136.
- [ ] **Step 3: App integration** (`StackTrackerProApp.swift`):
  - Container closure: at the top insert
    ```swift
    #if DEBUG
    if DemoData.isActive {
        let demoConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [demoConfig])
        DemoData.seed(into: container.mainContext)
        return container
    }
    #endif
    ```
    (schema declaration moves above this; `try!` acceptable here — DEBUG-only, in-memory creation cannot realistically fail and a loud crash is the right failure mode for a screenshot run.)
  - Splash: `@State private var showSplash = true` → initialize in `init()`: `_showSplash = State(initialValue: !DemoData.isActive)` wrapped `#if DEBUG` (else keep `true`).
  - In the ContentView `.onAppear` (after `setContext` calls): `#if DEBUG if DemoData.isActive { tournamentManager.activeTournament = DemoData.activeTournament } #endif`.
- [ ] **Step 4: Seed test** in `StackTrackerProTests`:
    ```swift
    @MainActor func testDemoSeedPopulatesWorld() throws {
        let container = try makeInMemoryContainer()
        let ctx = container.mainContext
        DemoData.seed(into: ctx)
        let t = try XCTUnwrap(DemoData.activeTournament)
        XCTAssertEqual(t.status, .active)
        XCTAssertEqual((t.stackEntries ?? []).count, 13)
        XCTAssertEqual((t.hands ?? []).count, 5)
        XCTAssertEqual((t.handStubs ?? []).filter { $0.status == .pending }.count, 1)
        XCTAssertNotNil(DemoData.bigWinHand)
        let dictated = (t.hands ?? []).first { $0.sortedActions.isEmpty && !$0.notes.isEmpty }
        XCTAssertNotNil(dictated)
        let completed = try ctx.fetch(FetchDescriptor<Tournament>()).filter { $0.statusRaw == "completed" }
        XCTAssertEqual(completed.count, 8)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<CashSession>()).count, 3)
        DemoData.seed(into: ctx)   // idempotent
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Tournament>()).filter { $0.statusRaw == "completed" }.count, 8)
    }
    ```
    (Adjust `notes` optionality to the real `Hand.notes` type when writing.)
- [ ] **Step 5:** Full suite green; Debug AND Release builds clean.
- [ ] **Step 6:** Commit `feat: DEBUG demo-data mode (seeder + in-memory container)`.

### Task 2: Routing hooks

**Files:**
- Modify: `StackTrackerPro/App/ContentView.swift`
- Modify: `StackTrackerPro/Views/Session/ActiveSessionView.swift`
- Modify: `StackTrackerPro/Views/Session/HandsPane.swift`
- Modify: `StackTrackerPro/Views/Session/HandCaptureView.swift`
- Modify: `StackTrackerPro/Views/Session/DictationSheet.swift`

**Interfaces (Consumes):** `DemoData.isActive/route/activeTournament/bigWinHand/poseMidHand/dictationPreviewTranscript` from Task 1. Route names: `graph`, `metrics`, `capture`, `hands`, `dictation`, `chat`, `results`, `share`.

- [ ] **Step 1: ContentView** — add `@State private var selectedTab = 0`, convert `TabView` to `TabView(selection: $selectedTab)` with `Tab("Play", systemImage: "suit.spade.fill", value: 0)`, Results value 1, Settings value 2 (pure refactor, no behavior change). Inside the Play tab's `NavigationStack`, wrap the existing VStack:
    ```swift
    #if DEBUG
    if DemoData.isActive, DemoData.route != "results", let demo = DemoData.activeTournament {
        ActiveSessionView(tournament: demo)
    } else { existingContent }
    #else
    existingContent
    #endif
    ```
    (Factor the current VStack into `private var playRoot: some View` so it appears once.) Add `.onAppear { #if DEBUG if DemoData.isActive && DemoData.route == "results" { selectedTab = 1 } #endif }`.
- [ ] **Step 2: ActiveSessionView** — in its outermost `.onAppear` (add one if none) `#if DEBUG`:
    ```swift
    switch DemoData.route {
    case "metrics": selectedPage = 1
    case "hands", "capture", "share": selectedPage = 6
    case "chat": selectedPage = 7
    default: break   // graph & dictation stay on 0/6 default handling below
    }
    if DemoData.route == "dictation" { selectedPage = 6 }
    ```
- [ ] **Step 3: HandsPane** — `.onAppear` `#if DEBUG` (guard `DemoData.isActive`):
    - route `capture` → `showEntry = true`
    - route `share` → `shareHand = DemoData.bigWinHand`
    - route `dictation` → set the existing state that presents `DictationSheet` (the capture-toolbar path presents it from HandCaptureView — instead present it from HandsPane by adding `@State private var demoShowDictation = false` + `.sheet(isPresented: $demoShowDictation) { DictationSheet(previewTranscript: DemoData.dictationPreviewTranscript) { _ in } }` wrapped in `#if DEBUG`).
- [ ] **Step 4: HandCaptureView** — in `.onAppear` `#if DEBUG`: `if DemoData.isActive && DemoData.route == "capture" && editingHand == nil && stub == nil { DemoData.poseMidHand(model) }`.
- [ ] **Step 5: DictationSheet** — add `var previewTranscript: String? = nil` (last-but-one parameter, before `onResult`, defaulted so existing call sites compile unchanged). Where the body switches on `engine.state`, treat `previewTranscript != nil` as the listening state and render the preview text in the transcript area; in the `.task`/start path, `if previewTranscript != nil { return }` so the engine never starts and the mic is untouched.
- [ ] **Step 6: Smoke every route** on the iPhone Air 26.5 simulator: build Debug once, then for each of the 8 routes `xcrun simctl launch --terminate-running-process <UDID> com.gyndok.stacktrackerpro -DemoData -DemoRoute <name>` + screenshot + eyeball (correct screen, demo data visible, no crash). Also launch once with NO arguments and confirm the normal app (real store, splash) still appears.
- [ ] **Step 7:** Full suite green; both configs build.
- [ ] **Step 8:** Commit `feat: demo-route hooks for screenshot capture`.

### Task 3: Capture script + screenshots + closeout

**Files:**
- Create: `tools/screenshots/make-screenshots.sh` (chmod +x), `tools/screenshots/README.md`
- Create (output): `marketing/screenshots/01-graph.png` … `08-share.png`

- [ ] **Step 1: Script.** Bash, `set -euo pipefail`. Behavior:
    1. Pick device: newest iOS runtime; prefer a device whose name contains "Pro Max"; if none exists, `xcrun simctl create "Screenshot 6.9" "iPhone 17 Pro Max" <newest-runtime-id>` (fall back to the largest existing iPhone if the device type is unknown).
    2. `xcodebuild build` Debug for that destination into a derivedDataPath under `tools/screenshots/.build`; locate the .app.
    3. Boot; `xcrun simctl status_bar <UDID> override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 --operatorName ""`; install the app.
    4. Routes array `graph metrics capture hands dictation chat results share` with index; for each: launch `--terminate-running-process` with `-DemoData -DemoRoute <r>`, `sleep 3`, `simctl io screenshot marketing/screenshots/0N-<r>.png`.
    5. `status_bar clear`; print a table of outputs with `sips -g pixelWidth -g pixelHeight`, and `echo "WARNING: not 1320x2868"` when a file isn't App Store 6.9" size.
- [ ] **Step 2: README.md** — 15 lines: what it does, how to run, where PNGs land, note that re-running after UI changes refreshes the whole set.
- [ ] **Step 3: Run it.** Verify all 8 PNGs exist, read 3-4 of them visually (graph shows the swing arc; hands list shows Pending + Dictated rows; capture shows mid-hand pose with pot and action buttons; results shows positive profit curve).
- [ ] **Step 4:** Full suite + both configs at HEAD one final time.
- [ ] **Step 5:** Mark spec + this plan EXECUTED; commit `feat: screenshot capture script + marketing screenshot set` (include the PNGs).

## Self-Review

- Spec coverage: components 1/2/3 → Tasks 1/2/3; constraints section mirrored in Global Constraints; acceptance = T3 steps 3–4. ✓
- Placeholder scan: poseMidHand code complete; seed contents enumerated with concrete numbers; no TBDs. ✓
- Type consistency: `DemoData` members used in Task 2 match the Task 1 interface block verbatim; route strings identical across tasks and script. ✓

> **STATUS: EXECUTED 2026-07-11**
>
> Commits `40cdc6e`..`7de8ebe` (Task 1: `40cdc6e`, `ea077b9`; Task 2: `84e5264`, `6ed0681`; Task 3: `7de8ebe` "feat: screenshot capture script + marketing screenshot set"). `tools/screenshots/make-screenshots.sh` ran against the iPhone 17 Pro Max simulator (iOS 26.5, already present on this machine — the "Pro Max" device-name match succeeded, so the create-fallback path was not exercised) and produced all 8 PNGs in `marketing/screenshots/` at exactly 1320x2868 (App Store 6.9"). Re-ran the script a second time to confirm re-runnability (reuse of the booted device, overwrite of existing PNGs) — clean. Visually verified 01-graph (swing arc), 02-metrics, 03-capture (mid-hand pose, pot 33,500, live Fold/Call/Bet-Raise buttons), 04-hands (Pending A♠K♠ stub + Dictated MP A♦Q♦ row), 05-dictation (verbatim transcript, mic untouched), 06-chat (bounty + big-pot prompt), 07-results (positive cumulative P/L curve), 08-share (share sheet with big-win hand) — all correct, no crashes or empty screens. Final gate: full suite 157/157 green (`iPhone Air`, OS 26.5) and Release build succeeded (`generic/platform=iOS Simulator`). Simulator shut down after the run, status bar cleared.
