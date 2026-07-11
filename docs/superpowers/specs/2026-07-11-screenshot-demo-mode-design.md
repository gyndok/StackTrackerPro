# Screenshot Demo Mode — Design

> **STATUS: EXECUTED 2026-07-11** — all 3 plan tasks landed; `tools/screenshots/make-screenshots.sh` produced the 8-PNG marketing set at 1320x2868; suite 157/157 green, Debug + Release both clean. See plan doc for commit range and full verification notes.

**Approved:** 2026-07-11 with user (approach A). Purpose: reproducible, App Store-ready raw screenshots (6.9"-class, portrait) with rich dummy data, reusable every release for the store listing and the website.

## Purpose

A `#if DEBUG`-only demo mode: launch the app with `-DemoData` and it runs against an **in-memory, CloudKit-free container** seeded with polished fake content; `-DemoRoute <name>` jumps straight to a target screen. A shell script relaunches the app once per route on a 6.9"-class simulator with a clean status bar and captures PNGs. No user-facing code changes; Release builds compile the mode out entirely.

## Components

### 1. `StackTrackerPro/App/DemoData.swift` (new, DEBUG-gated; pbxproj IDs 0135/0136)

- `DemoData.isActive` — true when `ProcessInfo.processInfo.arguments` contains `-DemoData`.
- `DemoData.route` — the string after `-DemoRoute` (nil if absent).
- `DemoData.seed(into: ModelContext)` — idempotent, creates:
  - **Active tournament**: "$600 Ultra Stack", Horseshoe Las Vegas, started ~4.5h ago, currently Level 12 (display), field 2,481 entrants / 612 left. Stack entries forming a dramatic winning arc: 50,000 start → climb → dip to ~31,000 → recovery → 168,500 now (12–15 entries with believable timestamps). Blind structure (WSOP-style levels incl. breaks) so the levels pane and level picker look real.
  - **Chat history**: stack updates with AI confirmations, a bounty, a field-size update, and a **big-pot prompt** ("Big pot — +64,000 at Level 11. Log it? Just tell me your cards.") with the user's reply.
  - **Hands**: pending stub A♠K♠ (Pending Hands section visible); saved hands: (1) big win — hero K♠K♦ vs villain 9♥T♥ shown, board J♥8♥4♦2♣3♠, pot 142,000; (2) a lost hand; (3) a preflop fold; (4) a **Dictated-only** hand with a realistic transcript ("I had ace queen of diamonds in the cutoff…"); (5) a structured hand that also carries notes. One FadeNote from a break debrief.
  - **History for Results**: ~8 completed tournaments + 3 cash sessions across the prior 3 months, net-positive curve, one 1st place ($8,400), ITM ≈ 30%, mixed venues (Horseshoe LV, Wynn, Champions Club Texas).
- All dates computed relative to `Date.now` so screenshots never look stale.

### 2. App integration (all `#if DEBUG`)

- `StackTrackerProApp`: when `DemoData.isActive`, build the container with `ModelConfiguration(schema:, isStoredInMemoryOnly: true)` (no `cloudKitDatabase`) and seed it immediately after creation. Splash skipped (`showSplash = !DemoData.isActive` initial value) so captures are instant and never catch the fade.
- **Routing hooks** — views consult `DemoData.route` on appear:
  - `ContentView` gains a `TabView` selection binding; route `results` selects the Results tab; all session routes select Play.
  - Play flow auto-navigates into the active session; `ActiveSessionView.selectedPage` preselects the pane: `graph`→0, `metrics`→1, `chat`→7, `hands`→6.
  - `capture` — HandsPane presents `HandCaptureView` posed mid-hand: level/blinds set, hero BTN K♠K♦, villain added, preflop raises logged, board J♥8♥4♦ dealt, pot mid-build. The pose is produced by replaying real inputs through `HandCaptureModel` (no engine changes).
  - `dictation` — presents `DictationSheet` with a DEBUG-only `previewTranscript:` parameter: when non-nil the sheet renders the recording state with that transcript and never starts the engine (mic untouched).
  - `share` — HandsPane presents `HandSharePreview` for the big-win hand.
- Route names: `graph`, `metrics`, `capture`, `hands`, `dictation`, `chat`, `results`, `share`.

### 3. `tools/screenshots/make-screenshots.sh` (new) + short README

- Picks the largest 6.9"-class iPhone simulator on the newest iOS runtime (prefers "Pro Max" names, falls back to the largest available; verifies the captured PNG is 1320×2868 and warns if not).
- Builds Debug for that simulator, boots it, applies `simctl status_bar override` (9:41, full battery, full bars, wifi).
- For each of the 8 routes: `simctl launch --terminate-running-process` with `-DemoData -DemoRoute <name>`, short settle delay, `simctl io screenshot` → `marketing/screenshots/NN-<name>.png` (01-graph … 08-share).
- Clears the status-bar override afterward.

## Constraints

- Zero schema/CloudKit impact; demo container is in-memory and CloudKit-free — demo data cannot reach the user's store or iCloud.
- Every code addition sits inside `#if DEBUG` (or is a DEBUG-defaulted parameter unusable from Release paths); Release build must remain byte-equivalent in behavior.
- No engine (`HandCaptureModel`) changes; the capture pose replays ordinary inputs.
- Existing test suite stays green; both build configs clean (mandatory Release gate).

## Out of scope

- Framed/captioned marketing composites (raw screenshots only — may be a follow-up).
- iPad screenshot set, locale matrices, dark/light variants (app is dark-only).
- XCUITest automation.

## Testing / acceptance

- `make-screenshots.sh` produces 8 PNGs at 6.9" resolution showing: winning stack graph, metrics with zone badge, mid-hand capture screen, hands list with pending stub + Dictated row, dictation sheet with live-looking transcript, chat with big-pot prompt, results profit curve, share preview with colored suits.
- Suite green; Debug and Release builds clean; a normal launch (no args) behaves exactly as today.
