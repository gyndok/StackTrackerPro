# Seeder Bulk Upgrades Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Seeding becomes a token-free, bulk, self-serve pipeline: Server-to-Server auth, a converter from the VegasPokerGuide scraper, clone with weekly recurrence, bulk publish with a duplicate guard, and a PokerAtlas Texas fetcher.

**Architecture:** All inside `tools/seeder` — zero app changes. The Swift CLI grows three source files (auth, import, existing main) compiled together by `build.sh`; the PokerAtlas fetcher is a separate Python script shelling out to the `firecrawl` CLI. Spec: `docs/superpowers/specs/2026-07-17-seeder-bulk-upgrades-design.md` (binding for every field mapping and rule).

**Tech Stack:** Swift (CryptoKit ECDSA P-256, Foundation URLSession), Python 3 (stdlib only), firecrawl CLI, bash test harness.

## Global Constraints

- Seeder/tools only — no app code, schema, or CloudKit record-type changes; emitted record field set stays byte-compatible (`SharedTournament`, dedup key `venue|yyyy-MM-dd(UTC)|buyIn|gameType[|suffix]`).
- No secrets in the repo: key material only under `~/.config/stacktrackerpro-seeder/`; add `.gitignore` entries for `tools/seeder/*.pem`, `tools/seeder/.pdfcache/`, `tools/seeder/.pagecache/`, `tools/seeder/drafts/`.
- Scraper repo (`~/Developer/VegasPokerGuide`) is read-only input.
- `build.sh` stays the single Swift build entry (extend its file list).
- Tests never hit the network; `tools/seeder/test.sh` is the harness and must exit nonzero on any failure.
- Failures loud, never silently empty (spec component 5 rule, applied everywhere).
- Commits direct to `main`, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Verified Current State (tools/seeder/main.swift, 380 lines)

- `EventDraft`/`LevelDraft` Codable structs (:29-67) — the draft schema all components share.
- `runParse` (:144), `geocode(name:city:state:)` (:206), `runPublish(files:environment:execute:)` (:219) — publish ALREADY loops multiple files; validation currently **skips drafts with empty `blindLevels`** (:238 "no blind levels") — Task 3 adds `--allow-empty-structure` to reconcile with structureless scrape drafts.
- Publish builds a `fields` dict and shells to `xcrun cktool create-record` (:281-320); dedup key at :271 appends `|suffix` when set.
- CLI dispatch: bare `switch command` at :346 with hand-rolled arg loops — follow that style, no dependencies.
- Scraper input sample verified 2026-07-17: `~/Developer/VegasPokerGuide/pipeline/.out/tournaments.json` = `{generated_at, source_sheet_updated_at, tournaments:[…]}` with fields `id` ("venetian-2026-05-18-nlh-1a"), `venue` (slug), `date_pt`, `start_at_pt` (ISO with offset), `game`, `game_category`, `event_name`, `buy_in_usd`, `guarantee_usd`, `re_entry{type,count,raw}`, `is_day2`, `structure_pdf_url`, `starting_stack`, `level_minutes` (string!), `rake_usd` (float or null), `notes`. `.out/venues.json` = `{venues:[{slug, display_name, series_name, address, …}]}`; venues.yml has `override_per_event_url: true` on WSOP-style venues.

## File Structure

- `tools/seeder/main.swift` — dispatch + parse/publish/clone (grows modestly)
- `tools/seeder/cloudkit-ws.swift` — NEW: S2S key loading, request signing, `wsModifyRecords`/`wsQueryDedupKey`, `runAuthCheck`
- `tools/seeder/import-scrape.swift` — NEW: scraper JSON → drafts, incl. `--with-structures`
- `tools/seeder/pokeratlas-fetch.py` — NEW: component 5 (Python, executable)
- `tools/seeder/tx-venues.yml` — NEW: PokerAtlas venue allowlist
- `tools/seeder/tests/fixtures/…` + `tools/seeder/test.sh` — NEW: harness + goldens
- `tools/seeder/README.md` — grows sections per task

---

### Task 1: Server-to-Server auth (`cloudkit-ws.swift`) + auth-check

**Files:**
- Create: `tools/seeder/cloudkit-ws.swift`
- Modify: `tools/seeder/main.swift` (publish routes through WS by default; `--via-cktool` fallback; new `auth-check` command)
- Modify: `tools/seeder/build.sh` (add cloudkit-ws.swift to the compile list)
- Modify: `.gitignore` (the four entries from Global Constraints)
- Test: extend `tools/seeder/test.sh` (create it here; Task 2 grows it)

**Interfaces (Produces):**
```swift
struct S2SKey { let keyID: String; let privateKey: P256.Signing.PrivateKey }
func loadS2SKey() throws -> S2SKey            // ~/.config/stacktrackerpro-seeder/{keyid,eckey.pem}; Err with setup instructions when missing
func wsSubpath(env: String, operation: String) -> String
    // "/database/1/iCloud.com.gyndok.stacktrackerpro/\(env)/public/records/\(operation)"
func signedRequest(subpath: String, body: Data, key: S2SKey) throws -> URLRequest
func wsModifyRecords(env: String, recordType: String, fields: [String: Any], key: S2SKey) async throws
func wsQueryByDedupKey(env: String, dedupKey: String, key: S2SKey) async throws -> Bool   // Task 3 consumes
func runAuthCheck(environment: String) async throws
```

- [ ] **Step 1: Signing core.** Apple's CloudKit Web Services signature (documented in "Composing Web Service Requests"): for each request compute

```swift
let dateString = ISO8601DateFormatter().string(from: Date())            // e.g. 2026-07-17T21:00:00Z
let bodyHash = Data(SHA256.hash(data: body)).base64EncodedString()
let message = "\(dateString):\(bodyHash):\(subpath)"
let signature = try key.privateKey.signature(for: Data(message.utf8))   // P256.Signing, SHA-256 over raw message bytes
var request = URLRequest(url: URL(string: "https://api.apple-cloudkit.com" + subpath)!)
request.httpMethod = "POST"
request.httpBody = body
request.setValue(key.keyID, forHTTPHeaderField: "X-Apple-CloudKit-Request-KeyID")
request.setValue(dateString, forHTTPHeaderField: "X-Apple-CloudKit-Request-ISO8601Date")
request.setValue(signature.derRepresentation.base64EncodedString(), forHTTPHeaderField: "X-Apple-CloudKit-Request-SignatureV1")
```

Key loading: `P256.Signing.PrivateKey(pemRepresentation:)` from `~/.config/stacktrackerpro-seeder/eckey.pem`; `keyid` file holds the hex key ID. Missing/unreadable → `Err` whose message contains the full setup ritual (Console → container → Server-to-Server Keys → Add; `openssl ec -in downloaded.pem …` note if Apple's PEM needs no conversion, state that).
- [ ] **Step 2: `wsModifyRecords`.** Body: `{"operations":[{"operationType":"create","record":{"recordType":"SharedTournament","fields":<fields>}}]}`. The existing publish already builds `fields` in web-services shape (`{"type":…,"value":…}` → NOTE: cktool's field JSON uses `"type"` keys like `stringType`; the WS API wants `{"value": …}` only, with types inferred, EXCEPT timestamps (millis since epoch) and doubles. Write a `toWSFields(_:)` converter: `stringType`→string, `int64Type`→Int, `doubleType`→Double, `timestampType`→ISO string parsed to millis Int). Parse the response; any `serverErrorCode` in it → thrown `Err` printing the code and reason. HTTP ≠ 200 → `Err` with status + body prefix.
- [ ] **Step 3: Wire into publish.** In `runPublish`, replace the cktool shell-out with `wsModifyRecords` when `--via-cktool` is absent; keep the cktool path verbatim behind the flag. Dry run (no `--execute`) prints, for the WS path: the subpath, the three header NAMES, and the fields JSON path — never key material.
- [ ] **Step 4: `auth-check` command.** `seeder auth-check --env development`: signed `records/query` body `{"query":{"recordType":"SharedTournament"},"resultsLimit":1}` → prints `AUTH OK (\(env), \(n) record(s) visible)` or the server error. Add to the usage text.
- [ ] **Step 5: `wsQueryByDedupKey`.** Query body with `filterBy:[{"fieldName":"deduplicationKey","comparator":"EQUALS","fieldValue":{"value":dedupKey}}]`. If the server answers with a "field not queryable"-class error, fall back automatically: unfiltered query (resultsLimit 200) and client-side match on the field, and print one notice suggesting the Console index. Returns whether a match exists.
- [ ] **Step 6: `test.sh` (first version).** Bash, `set -euo pipefail`, runs from tools/seeder: `./build.sh`; then `./seeder publish tests/fixtures/minimal-draft.json --env development` (dry run, no key needed — dry run must not require the key; enforce that in code: key loads lazily only on `--execute`/auth-check) and greps the output for `records/modify` and `X-Apple-CloudKit-Request-KeyID`. Create `tests/fixtures/minimal-draft.json` (a trimmed valid draft with 2 blind levels). `echo PASS` at the end.
- [ ] **Step 7:** Run `./test.sh` → PASS. Manual acceptance is deferred until the user mints the key (README section written now: Console steps, file locations, chmod 600).
- [ ] **Step 8: Commit** `feat(seeder): CloudKit Server-to-Server auth + auth-check`.

### Task 2: `import-scrape` (+ fixtures, goldens, `--with-structures`)

**Files:**
- Create: `tools/seeder/import-scrape.swift`; fixtures `tools/seeder/tests/fixtures/scrape-tournaments.json`, `scrape-venues.json`; goldens under `tools/seeder/tests/golden/`
- Modify: `tools/seeder/main.swift` (dispatch + usage), `tools/seeder/build.sh` (compile list), `tools/seeder/test.sh`, `tools/seeder/README.md`

**Interfaces (Consumes):** `EventDraft`/`LevelDraft` from main.swift; the shared `BlindStructureParsing` already compiled in. **Produces:** `runImportScrape(args: [String]) throws` invoked by dispatch; drafts on disk that Task 3's publish handles.

- [ ] **Step 1: Fixtures.** `scrape-tournaments.json`: 6 events per the spec — (1) normal with rake 95.0 + structure_pdf_url, (2) `rake_usd: null`, (3) `is_day2: true`, (4) flight id `…-nlh-1a` → suffix "1A", (5) `re_entry {type:"count", count:2}`, (6) venue flagged for structure-skip. `scrape-venues.json`: venues incl. `override_per_event_url: true` on the flagged one, addresses ending "…, Las Vegas, NV 89109". Six matching golden drafts under `tests/golden/` written BY HAND from the spec's mapping table (this is the test's authority — do not generate them from the code).
- [ ] **Step 2: Implement mapping** exactly per spec component 2 (name/series prefix, display_name, city+state from the address's last two comma segments with the state taken as the 2-letter token, buyIn = buy_in_usd − round(rake) / entryFee = round(rake), null-rake rule, guarantee/stack/gameTypeRaw rules, eventDate/startTimeLocal/timeZone per-venue map defaulting America/Los_Angeles, reentry mapping, dedupSuffix from trailing id token when it matches `^\d+[a-z]$` case-insensitively, day2 skip + `--include-day2`). Inline `structure_levels` on an input event (spec: component 5 addition) maps straight onto `blindLevels` and wins over `--with-structures`. Output files `<venue>-<date>-<last-id-token>.json` into `--out` (default `drafts/`). Summary line: `emitted N, skipped-day2 N, structures-attached N, structure-warnings N`.
- [ ] **Step 3: `--with-structures`.** For events with a `structure_pdf_url` and no inline levels: download to `.pdfcache/<sha256-of-url>.pdf` (skip download when cached; use `URLSession` sync wrapper), run the same parse path `runParse` uses on the PDF, attach only when ≥8 non-break levels, else warning line. Venues with `override_per_event_url: true` (read from the venues file — support BOTH `venues.json` and a `.yml` with a `grep`-grade line parser only for that one key; document that json is preferred) skip with a notice. Network use is allowed here at RUNTIME but the test path never exercises `--with-structures` against the network — fixture event (1)'s golden is produced WITHOUT structures.
- [ ] **Step 4: test.sh additions.** Run import-scrape on the fixtures into a temp dir; `diff -ru` against `tests/golden/`; assert the day2 event produced no file and the summary line matches expected counts exactly.
- [ ] **Step 5:** `./test.sh` → PASS (both tasks' sections). Commit `feat(seeder): import-scrape converter from VegasPokerGuide output`.

### Task 3: `clone` (+ weekly recurrence) and publish upgrades

**Files:**
- Modify: `tools/seeder/main.swift` (clone command; publish: summary counts, `--skip-existing`, `--allow-empty-structure`), `tools/seeder/test.sh`, `tools/seeder/README.md`

**Interfaces (Consumes):** `wsQueryByDedupKey` from Task 1. **Produces:** final CLI surface for the README.

- [ ] **Step 1: `clone`.** `seeder clone <file> (--date YYYY-MM-DD | --repeat weekly --until YYYY-MM-DD) [--suffix S] [--time HH:mm] [--name N]`. Single-date mode: decode EventDraft, apply overrides, write `<basename-minus-old-date>-<newdate>.json` (strip a trailing `-\d{4}-\d{2}-\d{2}` from the basename before appending), print the path. Recurrence: compute the template's weekday from `eventDate` in the draft's own timeZone; emit one file per week strictly after the template date through `--until` inclusive; `--repeat` with `--date` → usage error. Date math via `Calendar(identifier: .gregorian)` with the draft's zone — no day-count arithmetic across DST.
- [ ] **Step 2: Publish upgrades.**
  - Summary after the loop: `published N, skipped N, failed N` (failures no longer abort the whole batch — catch per file, print `FAIL <file>: <error>`, continue, exit nonzero at the end if any failed).
  - `--skip-existing`: before creating, `wsQueryByDedupKey`; on match print `SKIP <file>: already published (<dedupKey>)`. On the cktool fallback path, `--skip-existing` prints a one-line notice that the guard requires the WS path and proceeds without it.
  - `--allow-empty-structure`: downgrades the "no blind levels" validation from skip to a warning (drafts from scrape-without-structures publish metadata-only listings — spec component 2 allows them; the default stays strict).
- [ ] **Step 3: test.sh additions.** Clone: single date (filename + eventDate assert via python3 -c json), recurrence from a Saturday template `--until` 3 weeks out → exactly 3 files, all Saturdays (assert weekday via `date -j -f`), `--repeat`+`--date` exits nonzero. Publish: dry-run over a structureless draft WITHOUT the flag → output contains `SKIP`; WITH `--allow-empty-structure` → contains the warning but proceeds to the dry-run print; summary line format asserted.
- [ ] **Step 4:** `./test.sh` → PASS. Commit `feat(seeder): clone with weekly recurrence + bulk publish guards`.

### Task 4: `pokeratlas-fetch.py` + venue allowlist + README

**Files:**
- Create: `tools/seeder/pokeratlas-fetch.py` (chmod +x), `tools/seeder/tx-venues.yml`, fixtures `tools/seeder/tests/fixtures/pokeratlas/{listing.md,detail-tch.md,detail-nobuyintab.md}`
- Modify: `tools/seeder/test.sh`, `tools/seeder/README.md` (full pipeline walkthrough + ToS posture + S2S key setup consolidated)

**Interfaces (Consumes):** emits the Task 2 input schema (tournaments.json shape + optional `structure_levels`). **Produces:** `.out/pokeratlas-tournaments.json`.

- [ ] **Step 1: `tx-venues.yml`.** Start with the user's venues (verifiable slugs from pokeratlas.com URLs): `champions-social-houston` (confirm the exact slug by checking a scraped listing URL at implementation time — the listing fixture will contain real hrefs), plus 2-3 obvious Houston/Austin rooms as examples, each: `slug, display_name, city, state: TX, timezone: America/Chicago`. Comment header: how to add a venue.
- [ ] **Step 2: Fixtures from the real site (one-time live fetch during implementation is permitted for FIXTURE CAPTURE only):** save a listing page and one detail page markdown via `firecrawl scrape … -o`, trim to representative size (~150 lines each), hand-derive `detail-nobuyintab.md` by deleting the Buy-In section. Note in a fixtures README line that they're snapshots dated 2026-07-17.
- [ ] **Step 3: Implement** (stdlib only; subprocess to `firecrawl`):
  - `--fixtures <dir>` env-style escape hatch: when set, read the fixture files instead of invoking firecrawl (this is what tests use).
  - Parse listing markdown: tournament rows = numbered list items containing `poker-tournament/` hrefs; extract venue display text, href, and the `topid=<id>[-<date>]` param; event date from the topid suffix when present else from the detail page. Filter: venue must map to an allowlisted slug (match on the venue display text via the yml's display_name, case-insensitive) and date within `--from/--to`.
  - Detail pages sequentially, `time.sleep(1)` between firecrawl invocations (spec: ≤1 req/s). Parse: title line for event name + `$N` buy-in total + game; structure table rows `| Level N | mins | sb | bb | ante |` and `| Break | mins |` into `structure_levels` (LevelDraft field names, sequential numbering including breaks — same convention as the app parser); Buy-In section `Entry Fee`/`Total Buy-In` when present → rake = total − entry; absent → `buy_in_usd` = title total, `rake_usd: null`.
  - Emit tournaments.json shape: `id` = `<slug>-<date>-<topid>`, `venue` = slug, `date_pt` → the local date (keep the field name for schema compatibility; document that it's venue-local), `start_at_pt` = ISO from the slug/listing time (e.g. `500pm`) in the venue timezone, `game_category` lowercased from game, `re_entry {type:"unknown"}` unless the page states it, `is_day2: false`, `structure_levels` inline, no `structure_pdf_url`.
  - Loud failures: any page that yields zero parsed fields → stderr line naming the URL + nonzero exit at the end (`--keep-going` collects and reports all).
- [ ] **Step 4: test.sh additions.** Run `pokeratlas-fetch.py --fixtures tests/fixtures/pokeratlas --venues tx-venues.yml --from … --to … --out <tmp>/pa.json`; assert: event count, one event carries ≥8 `structure_levels`, the no-tab fixture produced `rake_usd: null`; then pipe that output through `seeder import-scrape` and assert a draft lands with `blindLevels` populated (closing the loop: components 5 → 2).
- [ ] **Step 5: README.** Consolidate: setup (S2S key ritual, firecrawl login), the three workflows from the spec verbatim, ToS posture paragraph (spec wording), maintenance note (markup drift → fixtures refresh), 4-weeks-out guidance for recurrence.
- [ ] **Step 6:** Full `./test.sh` → PASS. Commit `feat(seeder): PokerAtlas Texas fetcher + venue allowlist + pipeline README`.

### Task 5: End-to-end acceptance + closeout (mostly user-assisted)

- [ ] **Step 1:** User mints the S2S key (README ritual); `seeder auth-check --env development` then `--env production` → AUTH OK.
- [ ] **Step 2:** Live PokerAtlas pull for the coming week (user's venues) → import → `publish --env development --execute --skip-existing` → verify in the app's Browse Nearby Events (dev build) → production publish.
- [ ] **Step 3:** Re-run the same publish with `--skip-existing` → everything skips (guard proven live).
- [ ] **Step 4:** Mark spec + plan EXECUTED; update the seeding-workflow memory (token ritual obsolete; new commands); commit docs.

## Self-Review

- Spec coverage: C1→T1, C2→T2, C3→T3(clone), C4→T3(publish), C5→T4, acceptance→T5; structure_levels-beats-PDF rule in T2 step 2; empty-structure reconciliation surfaced explicitly (T3, spec-consistent).
- Placeholders: signing message format, WS body shapes, fixture inventories, and filename rules all concrete; the two implementation-time lookups (exact venue slug, PEM conversion note) are named as lookups with where-to-look, not TBDs.
- Type consistency: `S2SKey`, `wsQueryByDedupKey(env:dedupKey:key:)`, `runImportScrape(args:)` used identically across tasks; LevelDraft field names reused for `structure_levels`.

> **STATUS: EXECUTED 2026-07-18** (commits 75a743e..cdd5e10; test.sh green all sections; final whole-branch review READY; live acceptance complete per Task 5 — see spec STATUS for details).
