# StackTrackerPro Community Tournament Seeder

Command-line pipeline for publishing `SharedTournament` records to the app's
CloudKit **public database** — so users open the Browse Nearby Events screen
and find tournaments already there. Runs entirely on your Mac; no app build
involved.

It compiles against the app's own `BlindStructureParsing.swift`, so structure
parsing (Poker Atlas *and* WSOP sheet formats) is byte-for-byte the same
logic the app ships with.

## One-time setup

1. Build the tool:
   ```
   tools/seeder/build.sh
   ```
2. Create a **CloudKit Server-to-Server key** (long-lived; no more re-minting
   a token every session):
   - [CloudKit Console](https://icloud.developer.apple.com) → open the
     **container** `iCloud.com.gyndok.stacktrackerpro` → **Server-to-Server
     Keys** → **Add a Key**.
   - Download the generated private key PEM and save it to
     `~/.config/stacktrackerpro-seeder/eckey.pem`, then lock it down:
     ```
     mkdir -p ~/.config/stacktrackerpro-seeder
     mv ~/Downloads/eckey_*.pem ~/.config/stacktrackerpro-seeder/eckey.pem
     chmod 600 ~/.config/stacktrackerpro-seeder/eckey.pem
     ```
     (Apple's downloaded PEM is already in the right format for this tool —
     no `openssl ec` conversion needed.)
   - Copy the key's hex **Key ID** (shown next to the key in the Console)
     into `~/.config/stacktrackerpro-seeder/keyid` (a plain text file,
     just the ID, no trailing content needed beyond a newline).
   - Verify it works:
     ```
     tools/seeder/seeder auth-check --env development
     ```
     prints `AUTH OK (development, N record(s) visible)` on success.

   Records published this way are owned by the key's server identity
   rather than your personal iCloud account, but the app's browser
   de-duplicates listings by `deduplicationKey`, not owner, so behavior for
   users is unchanged. Never commit `eckey.pem` — it's already gitignored
   (`tools/seeder/*.pem`).

3. If you'll be running `pokeratlas-fetch.py` (the Texas source, below),
   install and authenticate the Firecrawl CLI once:
   ```
   npm install -g firecrawl-cli
   firecrawl login
   ```
   Everything else that tool needs it does through this CLI — no separate
   API key handling in this repo.

   **Fallback (old path):** pass `--via-cktool` to `publish` to use the
   original `xcrun cktool create-record` flow with a short-lived
   **CloudKit user token** (management tokens cannot write data):
   [CloudKit Console](https://icloud.developer.apple.com) → click your
   **account name (top right)** → **Tokens & Keys** (the account-level page,
   not the one inside the container) → **User Tokens** → create one. Save it:
   ```
   xcrun cktool save-token --type user
   ```
   (paste when prompted; it lands in your keychain). User tokens are
   short-lived (a few hours) — regenerate at the start of each seeding
   session if you use this path.

## Workflow

### 1. Parse a structure sheet into an editable draft

```
tools/seeder/seeder parse "main event.pdf" --out wsop-main.json
tools/seeder/seeder parse screenshot1.png screenshot2.png --out saturday-special.json
```

Accepts WSOP structure-sheet PDFs and Poker Atlas screenshots (multiple files
merge into one event). OCR runs the app's exact pipeline. The output JSON is
a **draft**: blind levels and whatever metadata could be read are filled in;
`venueName`, `venueCity`, `venueState`, and `eventDate` are marked
`FILL ME IN` and must be edited by hand.

### 2. Review the draft

- `eventDate` (`yyyy-MM-dd`) controls **which day the listing appears** in
  the app's browser — users see events for *today* (UTC) within 50 miles.
  Seed a whole week at once; each event surfaces on its own date.
- `venueName`/`venueCity`/`venueState` drive geocoding; the pin location
  determines who sees the listing. Use the venue's real, findable name.
- Check `buyIn`, `entryFee`, `guarantee` — metadata OCR is best-effort.

### 3. Publish

```
# Dry run (default): prints the CloudKit Web Services request, writes nothing
tools/seeder/seeder publish wsop-main.json --env development

# Actually save, to development first, then production
tools/seeder/seeder publish wsop-main.json --env development --execute
tools/seeder/seeder publish wsop-main.json --env production --execute
```

Publish geocodes the venue (same MapKit search the app uses), builds the
record with the app's exact field set and deduplication key
(`venue|yyyy-MM-dd|buyIn|gameType`, UTC), and — by default — POSTs it
straight to CloudKit Web Services, signed with your Server-to-Server key
(see setup above). Pass `--via-cktool` to use the old `xcrun cktool
create-record` path with a user token instead. If a user later shares the
same event from the app, the browser collapses the two listings into one.

Dry run (the default, no `--execute`) never touches the S2S key — it only
prints the request that would be sent. `seeder auth-check --env
development|production` does a lightweight signed query to confirm the key
works before you publish anything for real.

### Bulk publish

`publish` takes multiple files/globs in one call and never aborts the whole
batch on a single bad file — each file is decoded and processed
independently, and a summary line always closes the run:

```
tools/seeder/seeder publish drafts/*.json --env production --execute --skip-existing
...
published 12, skipped 2, failed 1
```

- A validation problem (missing metadata, unparseable date, un-geocodable
  venue) prints `SKIP <file>: <reason>` and counts as skipped.
- Any other error (decode failure, network/CloudKit error, non-zero
  `cktool` exit) prints `FAIL <file>: <error>`, counts as failed, and lets
  the rest of the batch continue. The tool exits nonzero iff any file
  failed — so a broken draft never silently vanishes.
- `--allow-empty-structure` downgrades the "no blind levels" check from a
  skip to a `WARNING <file>: ...` line and publishes a metadata-only
  listing instead (structureless drafts from `import-scrape` without
  `--with-structures`, or without a usable PDF). Every other validation
  problem still skips, even with this flag set.
- `--skip-existing` queries CloudKit for a record with the draft's
  `deduplicationKey` before creating one, and prints
  `SKIP <file>: already published (<dedupKey>)` on a match — useful for
  re-running `publish drafts/*.json` after only some of a batch went
  through. It only works on the default CloudKit Web Services path (it
  needs the S2S key to sign the query): with `--via-cktool` it prints one
  `NOTICE` up front and proceeds without the duplicate check. On a dry
  run (no `--execute`) it prints what the check would do instead of
  performing it, so dry runs never touch the S2S key.

### Recurring events: `clone`

Seed the same weekly game without re-parsing a structure sheet every time —
`clone` copies an existing draft (blind levels included) onto a new date.

```
# One new date
tools/seeder/seeder clone champions-club-monster-2026-07-18.json --date 2026-07-25

# Every week through a date, starting the week after the template
tools/seeder/seeder clone champions-club-monster-2026-07-18.json --repeat weekly --until 2026-08-15
```

- Single-date mode writes one file: the input's basename with any trailing
  `-yyyy-MM-dd` stripped, then the new date appended
  (`champions-club-monster-2026-07-25.json`), and prints its path.
- `--repeat weekly --until YYYY-MM-DD` emits one draft per week, landing on
  the template's own weekday (computed from the template's `eventDate` in
  its own `timeZone`), starting from the first occurrence **strictly
  after** the template date and continuing **through `--until` inclusive**.
  Date math stays inside `Calendar`/`TimeZone` (adding whole days, never
  raw 7×86400-second arithmetic), so a template that lands near a DST
  transition still recurs on the correct weekday and local time. `--repeat`
  and `--date` are mutually exclusive; weekly is the only interval
  supported today (dailies at a venue differ by weekday template — clone
  each weekday once, then recur it).
- `--suffix`, `--time`, and `--name` override `dedupSuffix`,
  `startTimeLocal`, and `tournamentName` on every emitted file; everything
  else (venue, buy-in, blind structure) carries over unchanged.
- Seed recurring club events no more than ~4 weeks out — structures and
  guarantees change without notice, so a further-out clone can go stale
  before it's ever seen.

Review each cloned draft like any other (`eventDate` still drives which day
it surfaces), then `publish` them — `--skip-existing` is handy here so
re-running the recurrence command after the past week already published
doesn't re-create it.

## Bulk import from the VegasPokerGuide scraper

If you already have a scraped schedule (`~/Developer/VegasPokerGuide/pipeline`
produces `.out/tournaments.json` + `.out/venues.json`), skip `parse` entirely
and convert the whole batch to drafts in one shot:

```
tools/seeder/import-scrape .out/tournaments.json --venues .out/venues.json \
    --from 2026-07-20 --to 2026-07-26 --out drafts/
```

- One draft per event, named `<venue-slug>-<date>-<last-id-token>.json`.
- `--venue slug` (repeatable) restricts to specific venues.
- Day 2 flights (`is_day2: true`) are **skipped by default**; pass
  `--include-day2` to emit them too.
- `--with-structures` downloads each event's `structure_pdf_url` (cached by
  URL hash under `tools/seeder/.pdfcache/`, so re-runs don't re-fetch),
  parses it through the same shared `BlindStructureParsing` pipeline `parse`
  uses, and attaches `blindLevels` only when the parse yields **at least 8
  non-break levels** — otherwise it prints a warning and leaves the draft
  structureless. Venues flagged `override_per_event_url: true` in the venues
  file (multi-event PDF bundles, e.g. an all-events WSOP sheet) are skipped
  for structure attachment with a notice, since a single-event parse would
  mis-read them.
- `--venues` accepts either `venues.json` (preferred, full fidelity) or a
  `.yml`/`.yaml` file — the YAML path is a minimal grep-grade line parser
  that only understands flat `- slug: ...` / `key: value` blocks, good enough
  to carry `override_per_event_url` overrides but not a general YAML parser.
- Ends with a summary line: `emitted N, skipped-day2 N, structures-attached N,
  structure-warnings N, venue-warnings N`. A venue warning fires (and the
  draft is still emitted, with empty city/state) when an event's venue slug
  isn't in the venues file or the venue's address can't be split into
  city/state — `publish`'s validation remains the gate, but the failure is
  never silent.
- Field mapping (buy-in/entry-fee, guarantee, re-entry policy, flight
  dedup suffix, timezone) is documented in
  `docs/superpowers/specs/2026-07-17-seeder-bulk-upgrades-design.md`
  component 2 — that spec is the binding source for anything not covered
  by the buy-in/entry-fee rule below, which supersedes it (the 2026-07-18
  transcript-edit/buy-in/stepper spec corrected that mapping). `buyIn` is
  always the TOTAL per-entry cost (`round(buy_in_usd)`) and `entryFee` is
  the house-kept portion of it (`round(rake_usd ?? 0)`) — matching the
  app's Tournament model, where `entryFee` is never subtracted out of
  `buyIn`.

Review the emitted drafts (venue names/cities drive geocoding — the scraper's
`display_name` is used as-is), then `publish` them like any other draft.

## PokerAtlas Texas: year-round automated source

The VegasPokerGuide scraper only covers Las Vegas. `pokeratlas-fetch.py`
turns PokerAtlas's public Texas tournament listings into that same
`tournaments.json` shape, so the rest of the pipeline (`import-scrape` →
`publish`) doesn't know the difference:

```
tools/seeder/pokeratlas-fetch.py --area texas --venues tx-venues.yml \
    --from 2026-07-20 --to 2026-07-26 --out .out/pokeratlas-tournaments.json
```

- `tx-venues.yml` is the allowlist — **only these rooms are ever fetched**;
  everything else on the PokerAtlas listing page is ignored. It maps a
  PokerAtlas venue slug to a display name (matched case-insensitively
  against the bold venue text on the listing page), city, state, and IANA
  timezone. See the comment header in the file for how to add a room.
- The listing page (`/poker-tournaments/<area>/upcoming`) is scraped fresh
  every run; each qualifying event's own detail page is then scraped
  **sequentially, at most one request per second**, and cached indefinitely
  by URL under `tools/seeder/.pagecache/` — a re-run days later only
  re-fetches the listing, not pages it's already seen.
- Blind structures come back **inline** (`structure_levels`, same shape as
  `blindLevels`) straight from each detail page's structure table — no PDF
  download, and `import-scrape` prefers this inline structure over any
  `structure_pdf_url` when both are present.
- The buy-in/rake split comes from the detail page's Buy-In tab (Entry Fee /
  Total Buy-In) when PokerAtlas renders it; when it doesn't, `buy_in_usd`
  falls back to the title's total and `rake_usd` is left `null` (metadata-
  only on that split — `import-scrape` still emits the draft).
- `--fixtures <dir>` reads canned listing/detail markdown instead of calling
  `firecrawl` — that's what `test.sh` uses; there's no live network in tests.
- A page that yields nothing usable is a **loud failure**: it prints to
  stderr naming the page and the process exits nonzero. Default behavior
  stops at the first such page; `--keep-going` collects every failure,
  finishes the run with whatever did parse, prints all of them, and still
  exits nonzero if any occurred.

**ToS posture:** PokerAtlas's terms likely prohibit automated collection.
This fetcher is deliberately low-volume — allowlisted venues only,
date-windowed, rate-limited to ≤1 request/second, meant for a weekly
cadence — and you run it under your own judgment, not as a fire-and-forget
system. It is not "set and forget": PokerAtlas's page markup can change at
any time, and when it does, `pokeratlas-fetch.py`'s parsing will need
maintenance. Failures are designed to be loud (nonzero exit, the specific
page named) rather than silently returning nothing.

**Maintenance note:** if `pokeratlas-fetch.py` starts emitting zero events
or erroring on pages that look fine in a browser, PokerAtlas's markup has
probably drifted. Re-capture fresh fixtures with
`firecrawl scrape <url> markdown -o tools/seeder/tests/fixtures/pokeratlas/<file>.md`
and diff against the parsing regexes in `pokeratlas-fetch.py` before assuming
anything else is wrong — see
`tools/seeder/tests/fixtures/pokeratlas/README.md` for the current fixtures'
provenance.

## The three pipeline workflows

Straight from the design spec
(`docs/superpowers/specs/2026-07-17-seeder-bulk-upgrades-design.md`):

- **Weekly bulk:** run the scraper → `seeder import-scrape .out/tournaments.json --venues .out/venues.json --from 2026-07-20 --to 2026-07-26 --with-structures` → skim the drafts → `seeder publish drafts/*.json --env production --execute --skip-existing`. No token, no Claude.
- **Recurring single event:** `seeder clone champions-monster-2026-07-18.json --date 2026-07-25` → publish.
- **Year-round Texas weekly:** `pokeratlas-fetch.py --area texas --venues tx-venues.yml --from … --to …` → `seeder import-scrape .out/pokeratlas-tournaments.json …` → publish. Same pipeline, structures arrive inline (no PDFs).

For the recurring workflow specifically: seed no more than **~4 weeks out**.
Structures and guarantees change without notice at a running club, so a
clone (or a PokerAtlas pull) further out than that risks going stale before
anyone ever sees it. Re-run the recurrence/fetch closer to the date instead
of trying to seed a whole season at once.

## Verifying

CloudKit Console → Records → *environment* → Public Database →
`SharedTournament` → filter `eventDate` > yesterday → Query. Or open the
app's Browse Nearby Events within 50 miles of the venue on the event day.

## Notes

- Records created via the S2S key belong to the key's server identity
  (via `--via-cktool`, the user token's iCloud identity instead); either
  way the app's client-side dedup prefers the most recently contributed
  listing per key.
- The blind-level parser is shared with the app (`BlindStructureParsing.swift`).
  If you improve it there, rebuild the seeder and both stay in sync.
- Bulk sources (e.g. a scraped schedule JSON) can skip `parse` entirely:
  generate the event-draft JSON directly and go straight to `publish`.

## One-click weekly seeding

`weekly-seed.sh` wraps the whole Texas week (fetch → drafts → confirm → publish)
with auto-computed dates (today through +6 days). "Seed Tournaments.app" in
/Applications (built with `osacompile`, see git history) launches it in
Terminal — one click from Launchpad, review the draft table, press Enter to
publish. Re-runs are duplicate-safe (`--skip-existing`). Recreate the app with:

    osacompile -o "/Applications/Seed Tournaments.app" <<'EOS'
    tell application "Terminal"
        activate
        do script "~/Developer/StackTrackerPro/tools/seeder/weekly-seed.sh"
    end tell
    EOS
