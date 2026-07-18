# Seeder Bulk Upgrades — Design

**Approved:** 2026-07-17 with user (direction approved in conversation; spec pending review). Goal: seeding SharedTournaments becomes a self-serve bulk pipeline — no Claude in the loop, no short-lived tokens, weeks of events in one command.

## Context

Today's flow (tools/seeder): screenshots → `seeder parse` or hand-built JSON → `seeder publish` via `xcrun cktool create-record`, which requires a **CloudKit user token minted in the Console every few hours** — the dominant friction. Meanwhile the user's VegasPokerGuide scraper (`~/Developer/VegasPokerGuide/pipeline`, output `.out/tournaments.json`) already produces 1,100+ structured events per run with venue slugs, dates, start times with UTC offsets, buy-in/rake splits, guarantees, stacks, re-entry policy, flight identifiers, and per-event structure-PDF URLs; `.out/venues.json` maps slugs → display names + street addresses.

## Components (5, all inside `tools/seeder` — zero app changes)

### 1. Server-to-Server auth (kills the token ritual)

- `seeder publish` gains a default auth path that calls CloudKit Web Services directly: `POST https://api.apple-cloudkit.com/database/1/iCloud.com.gyndok.stacktrackerpro/{environment}/public/records/modify` with the three signing headers (`X-Apple-CloudKit-Request-KeyID`, `-ISO8601Date`, `-SignatureV1`), ECDSA P-256 over `date:body-sha256-base64:subpath` per Apple's spec, via CryptoKit.
- Key material: one-time setup in CloudKit Console → Server-to-Server Keys. Private key PEM lives at `~/.config/stacktrackerpro-seeder/eckey.pem` (chmod 600) with `keyid` alongside — **never inside the repo**; the seeder errors with setup instructions when missing. README documents the console steps.
- `--via-cktool` keeps the old user-token path as a fallback.
- Note: records created by the server key are owned by the key's server identity, not the user's iCloud account. The app's browser collapses listings by `deduplicationKey`, not owner — no behavior change.

### 2. `seeder import-scrape` (the bulk converter)

`seeder import-scrape <tournaments.json> --venues <venues.json> --from YYYY-MM-DD --to YYYY-MM-DD [--venue slug]… [--out drafts/] [--with-structures]`

- Emits **one draft JSON per event** (existing EventDraft schema) into the out dir, named `<venue>-<date>-<slug>.json`.
- Field mapping (binding):
  - `tournamentName` = `event_name`; when `venues.json` provides a `series_name` not already contained in the event name, prefix it: `"Wynn Summer Classic — NLH 1A"`.
  - `venueName` = venue `display_name`; `venueCity`/`venueState` parsed from the venue `address` (last two comma segments → city, 2-letter state); geocoding continues to use the existing MapKit path at publish.
  - `buyIn` = `buy_in_usd − round(rake_usd)` (prize contribution), `entryFee` = `round(rake_usd)` — matches the app's convention. When `rake_usd` is null, `buyIn` = `buy_in_usd`, `entryFee` = 0.
  - `guarantee` = `guarantee_usd ?? 0`; `startingChips` = `starting_stack ?? 0`; `gameTypeRaw` = `game_category` uppercased (`nlh`→NLH, `plo`→PLO; anything else → the raw `game` string).
  - `eventDate` = `date_pt`; `startTimeLocal` = HH:mm extracted from `start_at_pt`; `timeZone` = the venue's IANA zone (per-venue map, default `America/Los_Angeles`).
  - `reentryPolicy`: `unlimited`→"Unlimited", `none`→"None", numeric `count`→its string.
  - `dedupSuffix` = trailing flight token of the scraper `id` when present (e.g. `…-nlh-1a` → "1A"), else empty.
  - **Day 2s skipped by default** (`is_day2 == true`); `--include-day2` overrides.
- `--with-structures`: for each event with a `structure_pdf_url`, download (cached by URL hash under `tools/seeder/.pdfcache/`), run the existing shared `BlindStructureParsing` pipeline, and attach `blindLevels` **only when the parse yields ≥ 8 non-break levels**; otherwise leave levels empty and print a warning line. Venues flagged `override_per_event_url: true` in venues.yml (e.g. WSOP's all-in-one bundle) are skipped for structure attachment with a notice — multi-event PDFs would mis-parse.
- Summary table at the end: emitted / skipped-day2 / structure-attached / structure-warnings.

### 3. `seeder clone` (the recurring-event shortcut)

`seeder clone <existing.json> --date YYYY-MM-DD [--suffix 1B] [--time HH:mm] [--name "…"]` → writes `<basename>-<date>.json` with `eventDate` (and optional suffix/time/name) replaced, everything else — structure included — carried over. Prints the new path.

**Recurrence (the post-summer workhorse):** `seeder clone <existing.json> --repeat weekly --until YYYY-MM-DD` emits one draft per week on the template's weekday, starting from the first occurrence strictly after the template's `eventDate`, through `--until` inclusive. Each draft gets its own `eventDate` (dedup keys stay per-day). `--repeat` and `--date` are mutually exclusive. Weekly is the only interval in v1 (dailies at a venue differ by weekday template — clone each weekday once, then recur). README guidance: seed recurring club events no more than ~4 weeks out, since structures and guarantees change without notice.

### 4. Bulk publish + duplicate guard

- `seeder publish` accepts **multiple files/globs**; per-file result lines and an end summary (published / failed / skipped).
- `--skip-existing`: before creating, query the public DB for a record matching the draft's `deduplicationKey`; skip with a notice when found. Works on both auth paths (Web Services `records/query`, or cktool equivalent). Default off (explicit flag), so re-publishing to refresh a listing stays possible.

### 5. `pokeratlas-fetch` (year-round Texas source)

A Python script (`tools/seeder/pokeratlas-fetch.py`) that turns PokerAtlas pages into the same `tournaments.json` schema `import-scrape` consumes — feasibility proven 2026-07-17: plain HTTP is bot-blocked (403) but the Firecrawl CLI renders listings AND full blind-structure tables (36 levels + 4 breaks scraped clean from a TCH Austin detail page); robots.txt does not disallow these paths.

- Invocation: `pokeratlas-fetch.py --area texas --venues tx-venues.yml --from YYYY-MM-DD --to YYYY-MM-DD --out .out/pokeratlas-tournaments.json`.
- `tx-venues.yml` (new, committed): allowlist of the venues worth seeding — PokerAtlas venue slug → display name, city, state, IANA timezone (`America/Chicago`). Only allowlisted venues are fetched; everything else in the listing is ignored.
- Flow: scrape the area's `/poker-tournaments/<area>/upcoming` listing (Firecrawl, `--wait-for`), filter rows to allowlisted venues within the window, then scrape each remaining event's detail page **sequentially at ≤1 request/second**. Parse: title/slug for buy-in total, game, and start time; the detail page's structure table into levels+breaks; the Buy-In tab (via one Firecrawl interact step) for the entry/fee split — when the tab doesn't render, fall back to `buy_in_usd` = title total, `rake_usd` = null.
- Output schema additions consumed by component 2: an optional `structure_levels` array (same shape as EventDraft `blindLevels`) — **`import-scrape` prefers inline `structure_levels` over `structure_pdf_url`** when both exist (component 2 gains this one rule).
- Caching: detail pages cached by URL under `.pdfcache/` siblings (`.pagecache/`), so re-runs within a week only fetch the listing.
- **ToS posture (documented in README, user-accepted):** PokerAtlas terms likely prohibit automated collection; this fetcher is deliberately low-volume (allowlisted venues, date-windowed, rate-limited, weekly cadence) and the user runs it under their own judgment. Not a fire-and-forget system — page-structure changes will need occasional parser maintenance, and failures must be loud (nonzero exit + which page broke), never silently empty.
- Dependency: the `firecrawl` CLI (already installed/authenticated on this machine); the script shells out to it — no Python HTTP of its own.

## The new workflows

- **Weekly bulk:** run the scraper → `seeder import-scrape .out/tournaments.json --venues .out/venues.json --from 2026-07-20 --to 2026-07-26 --with-structures` → skim the drafts → `seeder publish drafts/*.json --env production --execute --skip-existing`. No token, no Claude.
- **Recurring single event:** `seeder clone champions-monster-2026-07-18.json --date 2026-07-25` → publish.
- **Year-round Texas weekly:** `pokeratlas-fetch.py --area texas --venues tx-venues.yml --from … --to …` → `seeder import-scrape .out/pokeratlas-tournaments.json …` → publish. Same pipeline, structures arrive inline (no PDFs).

## Constraints

- Seeder/tools only — **no app code, schema, or CloudKit record-type changes**; the emitted record field set stays byte-compatible with today's (`SharedTournament`, same dedup key format `venue|yyyy-MM-dd(UTC)|buyIn|gameType[|suffix]`).
- No secrets in the repo: key material only under `~/.config/stacktrackerpro-seeder/`; add a `.gitignore` guard for `*.pem` and `.pdfcache/` under tools/seeder anyway.
- The scraper repo is read-only input — no changes to VegasPokerGuide.
- `build.sh` remains the single build entry; new code stays in the seeder's existing Swift sources (split into a second file if main.swift grows unwieldy — compile both in build.sh).

## Out of scope

- In-app "Publish Event" button (separate future feature, needs app work).
- Mac app / web UI wrappers.
- Scraper changes, non-Vegas venue sources beyond what tournaments.json already carries, automatic scheduling (cron) of the pipeline.

## Testing / acceptance

- Fixture-driven: `tools/seeder/tests/fixtures/` gets a trimmed tournaments.json (6 events covering: normal, null rake, day2, flight suffix, unlimited/count re-entry, WSOP-flagged venue) + venues.json; `tools/seeder/test.sh` runs `import-scrape` against them and diffs the emitted drafts against golden files, exercises `clone` (date+suffix, and `--repeat weekly --until` asserting the emitted dates land on the template's weekday and stop at the bound), and runs a `publish --dry-run` over the drafts asserting the dedup keys and the Web Services request path/headers are printed (no network in tests).
- Component 5: fixture-driven too — saved listing/detail markdown pages under `tests/fixtures/pokeratlas/`; the parser runs against fixtures with the Firecrawl calls stubbed (env var pointing at fixture dir), golden-diffed output incl. inline `structure_levels`; one fixture exercises the missing-Buy-In-tab fallback. Live fetch is manual acceptance only.
- Signing self-check: `seeder auth-check --env development` performs one signed `records/query` and reports success/failure — the acceptance test for component 1 (run manually; requires the real key).
- End-to-end acceptance (manual, once): import one real week with `--with-structures`, publish to development with `--skip-existing`, verify in the app's Browse Nearby Events, then production.
