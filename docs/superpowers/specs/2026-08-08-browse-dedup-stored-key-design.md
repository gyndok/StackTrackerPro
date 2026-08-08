# Browse Dedup: Prefer Stored Key + Fetcher Level-Row Fix — Design

**Authorized:** 2026-08-08 ("yes, build the fix while I play"). Two production bugs found on SPO Main Event day.

## Bug 1 — Flight 1F invisible in Browse Nearby Events (app, ships in 1.2.6)

Server records for Main Event flights E/F/G are correct and distinct — each stores
`deduplicationKey` with a flight suffix (`Champions Club Texas|2026-08-08|800|NLH|E`, `|F`, `|G`).
But `CloudKitService.deduplicateListings` RECOMPUTES keys from
`venueName|utcDay|buyIn|gameType` (no suffix), so same-day same-price flights collide
client-side: E and F merged (E survived on contributedAt), G survived only because its
9 PM CT start rolls into the next UTC day.

### Fix (binding)

- `SharedTournamentListing` gains `deduplicationKey: String?`, parsed from the CKRecord
  field (nil for legacy records that predate the field).
- `deduplicateListings` keys on `listing.deduplicationKey ?? recomputedKey`. Stored keys
  (which carry flight suffixes) win; legacy records behave exactly as before.
- `buildDeduplicationKey`/`deduplicateListings` become static internal so the dedup rule
  is unit-testable without touching CKContainer.
- Save path unchanged — the app's own share flow never writes suffixes; suffixes come
  from the seeder.

### Tests

- Two listings, same venue/day/buyIn/gameType, stored keys `…|E` and `…|F` → both survive.
- Two legacy listings (nil stored key), same fields → one survives, later `contributedAt` wins.
- Stored-key record + legacy record whose recomputed key differs → both survive.
- Suite green + Release gate (`xcodebuild build -configuration Release -destination 'generic/platform=iOS Simulator'`).

## Bug 2 — PLO Blitz shows "0 blind levels" (fetcher, fix + data repair today)

`pokeratlas-fetch.py parse_structure_table` treats any row whose Name column isn't
"Level N" as a break. The TCH Houston PLO Blitz table puts stack ranges in Name
("400-700") with real SB/BB/Ante columns → all 34 rows published as breaks; the app
row counts non-break levels → "0 blind levels". Verified: only this one record affected
(production scan of Aug 8–9, 15 records).

### Fix (binding)

- A row whose SB and BB cells are both numeric (commas allowed) is a LEVEL regardless of
  its Name; rows with blank/non-numeric blinds (literal "Break", "RACE OFF 100's") stay breaks.
- Repair the live record (`D7A601CC…`, `Texas Card House Houston|2026-08-08|25|PLO`) via
  S2S forceUpdate with the re-parsed structure from the cached detail page.

### Tests

- Offline harness case: name-range table parses to levels with correct SB/BB/ante; race-off
  row stays a break.
