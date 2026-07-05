# Structure Library, Event Timeline, and AI Recap Export — Design

Date: 2026-07-04
Status: Approved (user: "this looks perfect")
Build order: A → B → C

## A. Structure Library (+ PDF import)

**Problem:** PokerAtlas links WSOP events to structure PDFs; screenshots of
those don't OCR into the blind editor, forcing manual entry every time.

**Model:** `BlindStructureTemplate` (SwiftData, CloudKit-synced, defaults on
every field): `name`, `venueName?`, `startingChips`, `createdDate`, and the
level list encoded as JSON `Data` (array of a Codable level struct:
levelNumber, SB, BB, ante, durationMinutes, isBreak, breakLabel).

**UI:**
- Blind editor menu: "Save to Library…" (name prompt, defaults to tournament
  name) and "Load from Library".
- Setup screen: "Load from Library" alongside the scan actions.
- Library list: searchable (name/venue), newest first, swipe-to-delete.

**PDF import:** scan menu gains "Import PDF" (fileImporter, UTType.pdf).
Renders up to the first 6 pages via PDFKit at high resolution and feeds the
images through the existing `PokerAtlasScanner.scan(images:)` pipeline.

## B. Complete the event timeline

**Already timestamped:** stack entries, field snapshots, chat messages, hand
notes, break entries, bounty events, chip photos, actual start/pauses/end.

**Gaps:** rebuys (counter only), level changes (mutated in place), add-on
count changes.

**Model:** `TournamentEvent` (SwiftData, cascade from Tournament, CloudKit-
safe): `timestamp`, `typeRaw` (rebuy | levelChange | addOnField | addOnPlayer
| pause | resume | completed), `intValue`. `TournamentManager` mutators append
events. No UI.

## C. AI Recap export

**Entry point:** "Export Recap File" in the ⋯ menu of a completed tournament.

**Output:** one Markdown file via ShareLink (`<name>-recap.md`):
1. Ready-made prompt header instructing a frontier model to produce a PDF
   recap (stack-over-time chart, entrants/players progression, key hands,
   financial summary).
2. Tournament summary (venue, buy-in/fees/add-ons, entries, finish, payout,
   profit, pause-aware duration).
3. Blind structure table.
4. Chronological merged timeline (stacks, levels, field, rebuys, add-ons,
   breaks, bounties, notes) with timestamps.
5. Stack series as a CSV code block (precise data for charting).
6. Hand notes in full + chat transcript.

**Format rationale:** Markdown over JSON — equally machine-readable, token-
efficient, human-readable.

**Out of scope:** in-app AI calls (future Pro tier), sharing structures
between users, any blind-level clock (standing user decision).
