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
- Field mapping (buy-in/rake split, guarantee, re-entry policy, flight
  dedup suffix, timezone) is documented in
  `docs/superpowers/specs/2026-07-17-seeder-bulk-upgrades-design.md`
  component 2 — that spec is the binding source if this README and the code
  ever disagree.

Review the emitted drafts (venue names/cities drive geocoding — the scraper's
`display_name` is used as-is), then `publish` them like any other draft.

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
