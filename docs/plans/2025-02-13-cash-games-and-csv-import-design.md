# Cash Game Tracking & CSV Import — Design Document

## Summary

Add a full cash game tracking section to StackTrackerPro with live session tracking, a unified Results tab combining cash and tournament history with a cumulative P/L graph and filters, and CSV import for bulk session history.

---

## 1. Data Model: `CashSession`

New SwiftData `@Model` alongside the existing `Tournament` model.

### Fields

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| id | UUID | auto | Primary key |
| date | Date | Date.now | Session date |
| startTime | Date | Date.now | When session began |
| endTime | Date? | nil | When session ended |
| stakes | String | "" | e.g. "1/2", "2/5", "5/10" |
| gameTypeRaw | String | "NLH" | Same GameType enum as Tournament |
| buyInTotal | Int | 0 | Total money invested (dollars) |
| cashOut | Int? | nil | Ending cash-out amount |
| venueName | String? | nil | Location name |
| venueID | UUID? | nil | Soft reference to Venue |
| statusRaw | String | "setup" | setup, active, completed |
| notes | String? | nil | General session notes |
| isImported | Bool | false | True if created via CSV import |

### Relationships (cascade delete)

| Relationship | Type | Notes |
|-------------|------|-------|
| stackEntries | [StackEntry] | Reuse existing model |
| chatMessages | [ChatMessage] | Reuse existing model |
| handNotes | [HandNote] | Reuse existing model |

### Computed Properties

- `profit: Int?` — `cashOut - buyInTotal` (nil if session incomplete)
- `duration: TimeInterval?` — `endTime - startTime` (nil if session incomplete)
- `hourlyRate: Double?` — `profit / (duration / 3600)` (nil if either is nil)
- `totalHours: Double?` — `duration / 3600`

### Relationship Changes

`StackEntry`, `ChatMessage`, and `HandNote` currently have a `tournament: Tournament?` relationship. Add an optional `cashSession: CashSession?` relationship to each so they can belong to either session type. Each entry belongs to exactly one session (tournament XOR cashSession).

---

## 2. Shared Protocol: `PokerSession`

To power the unified Results tab, define a protocol both models conform to:

```swift
protocol PokerSession {
    var id: UUID { get }
    var date: Date { get }
    var profit: Int? { get }
    var duration: TimeInterval? { get }
    var hourlyRate: Double? { get }
    var gameTypeRaw: String { get }
    var venueName: String? { get }
    var statusRaw: String { get }
    var sessionTypeLabel: String { get } // "Cash" or "Tournament"
}
```

Both `Tournament` and `CashSession` conform to this protocol. The Results tab works with `[any PokerSession]`.

---

## 3. Navigation Changes

### Play Tab

Add a segmented control at the top:

```
[ Tournaments | Cash Games ]
```

- **Tournaments** segment: existing `TournamentListView` (unchanged)
- **Cash Games** segment: new `CashSessionListView`
  - Shows active/setup cash sessions
  - "New Cash Session" button (presents `CashSessionSetupView` as sheet)
  - Tap active session to enter `CashActiveSessionView`

### History Tab → Results Tab (renamed)

- Tab icon remains `clock.fill`, label changes to "Results"
- Filter chips at top: `All | Cash | Tournaments`
- Cumulative P/L graph (filtered by selection)
- Mixed session list sorted by date (most recent first)
- Analytics dashboard updates based on active filter

---

## 4. Cash Session Setup View

Simple form matching the tournament setup pattern:

**Sections:**

1. **GAME INFO**
   - Stakes picker: preset buttons (1/2, 1/3, 2/5, 5/10) + custom text field
   - Game Type picker (NLH, PLO, Mixed — same as tournament)

2. **VENUE**
   - Venue name text field

3. **BUY-IN**
   - Buy-in amount (dollar input)

4. **Start Session** button

Validation: stakes non-empty, buyIn > 0.

---

## 5. Cash Live Session View

Pager (TabView) tailored for cash games:

| Page | View | Notes |
|------|------|-------|
| 0 | StackGraphView | Reuse, show $ values instead of chips |
| 1 | CashSessionStatsView | Duration, current P/L, hourly rate, total invested |
| 2 | HandNotesPane | Reuse existing |
| 3 | ChatThreadView | Reuse, adapted context for cash |

### Status Bar (always visible at top)

- Session timer (running duration)
- Current stack / P/L
- Hourly rate (live)

### Chat Input (bottom)

Quick action buttons adapted for cash:
- **Add-on** — record additional buy-in (adds to buyInTotal)
- **Stack Update** — update current chip/dollar count
- **Hand Note** — quick hand note entry
- **Cash Out** — end session, enter cash-out amount

### End Session Flow

- Prompt for cash-out amount
- Show session summary: duration, P/L, hourly rate
- Option to add notes
- Share card option (like tournament recap)

---

## 6. Unified Results Tab

### Filter Bar

Horizontal chips at top: `All | Cash | Tournaments`

Selecting a filter updates both the graph and the session list.

### Cumulative P/L Graph

- Single cumulative line showing running profit/loss over time
- Uses SwiftUI Charts (AreaMark + LineMark, same pattern as existing analytics)
- X-axis: dates, Y-axis: cumulative P/L in dollars
- Zero line RuleMark for reference
- Data source: all completed sessions sorted by date, filtered by selection
- Each data point = one session's ending cumulative P/L

### Session List

Mixed list of cash and tournament sessions, sorted by date descending.

Each row shows:
- Session type icon (cards icon for cash, trophy for tournament)
- Date
- Game type + stakes (cash) or tournament name (tournament)
- Venue
- P/L badge (green positive, red negative)
- Duration

### Analytics Dashboard (updated)

Stats adapt based on active filter:

**Always shown:**
- Total Profit
- Win Rate
- Avg Hourly Rate
- Total Sessions
- Total Hours Played

**Cash-only additions:**
- Avg Session Length
- Best/Worst Session
- Profit by Stakes breakdown
- Profit by Venue

**Tournament-only additions (existing):**
- ROI
- ITM Rate
- Avg Finish Position
- Avg Field Size
- Avg Buy-in

**Combined ("All") view:**
- Shows universal stats
- Breakdown section: cash profit vs tournament profit

---

## 7. CSV Import

### Import Location

Settings tab → new "Import Session History" row. Tapping opens a document picker (`.csv` UTType).

### Expected CSV Format

Required column order (header row expected):

```
Date, Format, Variant, Stakes, Location, Buy-in ($), Cash-out ($), Profit/Loss ($), Duration (hours), Hourly Rate ($/hr), Notes
```

### Parsing Rules

| Column | Mapping | Parsing |
|--------|---------|---------|
| Date | `date` / `startDate` | Parse with multiple format attempts: "MM/dd/yyyy", "yyyy-MM-dd", "M/d/yy" |
| Format | Determines model type | "Cash" → CashSession, "Tournament" → Tournament |
| Variant | `gameTypeRaw` | Map to GameType enum (NLHE→NLH, PLO→PLO, etc.) |
| Stakes | `stakes` (cash) / ignored (tournament) | String, stored as-is |
| Location | `venueName` | String |
| Buy-in ($) | `buyInTotal` (cash) / `buyIn` (tournament) | Parse as Int, strip "$" and "," |
| Cash-out ($) | `cashOut` (cash) / `payout` (tournament) | Parse as Int, strip "$" and "," |
| Profit/Loss ($) | Validation only | Used to verify buyIn/cashOut math; not stored separately |
| Duration (hours) | Compute `endTime` from `startTime` + duration | Parse as Double |
| Hourly Rate ($/hr) | Validation only | Derived from profit/duration; not stored separately |
| Notes | `notes` | String, optional |

### Import Flow

1. User taps "Import Session History" in Settings
2. Document picker opens (filter: .csv)
3. Parse CSV, show preview: "Found X cash sessions and Y tournaments"
4. Show first few rows as preview with any parsing warnings
5. User confirms import
6. Create `CashSession` or `Tournament` objects with `isImported = true`, `statusRaw = "completed"`
7. For tournaments created via import: set `finishPosition = nil`, minimal fields populated
8. Show completion summary: "Imported X sessions (Y cash, Z tournaments)"

### Error Handling

- Skip rows with unparseable dates (log warning)
- Skip rows with missing buy-in (log warning)
- Show count of skipped rows with reasons
- Duplicate detection: warn if session with same date + venue + buy-in already exists

---

## 8. Schema Registration

Update `StackTrackerProApp.swift` to include `CashSession` in the SwiftData schema:

```swift
let schema = Schema([
    Tournament.self,
    CashSession.self,  // NEW
    BlindLevel.self,
    StackEntry.self,
    ChatMessage.self,
    HandNote.self,
    BountyEvent.self,
    FieldSnapshot.self,
    Venue.self,
    ChipStackPhoto.self,
])
```

---

## 9. Settings Additions

New settings under "SESSION DEFAULTS":
- Default Stakes (text field, e.g. "1/2")

New section "DATA":
- Import Session History (CSV import trigger)
- Export Session History (future — not in scope)

---

## 10. Sharing

New `CashSessionRecapCardView` mirroring `SessionRecapCardView`:
- Hero: P/L amount (large, green/red)
- Metrics row: Stakes | Duration | Hourly Rate | Buy-in
- Mini stack chart (if entries exist)
- Venue + date footer

---

## Out of Scope (Future)

- CSV export
- Table change logging during cash sessions
- Opponent tracking in cash games
- Multi-currency support
- Hand history import (poker client formats)
