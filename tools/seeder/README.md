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
2. Create a **CloudKit management token**: [CloudKit Console](https://icloud.developer.apple.com)
   → container `iCloud.com.gyndok.stacktrackerpro` → Settings → **Tokens & Keys**
   → New Management Token. Then save it locally:
   ```
   xcrun cktool save-token
   ```
   (paste the token when prompted; it lands in your keychain)

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
# Dry run (default): prints the cktool command, writes nothing
tools/seeder/seeder publish wsop-main.json --env development

# Actually save, to development first, then production
tools/seeder/seeder publish wsop-main.json --env development --execute
tools/seeder/seeder publish wsop-main.json --env production --execute
```

Publish geocodes the venue (same MapKit search the app uses), builds the
record with the app's exact field set and deduplication key
(`venue|yyyy-MM-dd|buyIn|gameType`, UTC), and calls
`xcrun cktool create-record`. If a user later shares the same event from the
app, the browser collapses the two listings into one.

## Verifying

CloudKit Console → Records → *environment* → Public Database →
`SharedTournament` → filter `eventDate` > yesterday → Query. Or open the
app's Browse Nearby Events within 50 miles of the venue on the event day.

## Notes

- Records created here belong to the token's iCloud identity; the app's
  client-side dedup prefers the most recently contributed listing per key.
- The blind-level parser is shared with the app (`BlindStructureParsing.swift`).
  If you improve it there, rebuild the seeder and both stay in sync.
- Bulk sources (e.g. a scraped schedule JSON) can skip `parse` entirely:
  generate the event-draft JSON directly and go straight to `publish`.
