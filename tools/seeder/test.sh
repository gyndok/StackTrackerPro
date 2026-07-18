#!/bin/bash
# Test harness for the seeder CLI. No network required beyond the existing
# MapKit geocode lookup that `publish` already performs; no CloudKit key
# material is required — dry runs must never touch
# ~/.config/stacktrackerpro-seeder.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

echo "--- publish dry run (CloudKit Web Services path) ---"
output="$(./seeder publish tests/fixtures/minimal-draft.json --env development)"
echo "$output"

echo "$output" | grep -q "records/modify" \
    || { echo "FAIL: expected WS subpath containing 'records/modify' in output"; exit 1; }
echo "$output" | grep -q "X-Apple-CloudKit-Request-KeyID" \
    || { echo "FAIL: expected header name 'X-Apple-CloudKit-Request-KeyID' in output"; exit 1; }

echo "--- import-scrape (VegasPokerGuide fixtures) ---"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

scrape_output="$(./seeder import-scrape tests/fixtures/scrape-tournaments.json \
    --venues tests/fixtures/scrape-venues.json \
    --from 2026-07-01 --to 2026-07-31 \
    --out "$tmpdir")"
echo "$scrape_output"

expected_summary="emitted 7, skipped-day2 1, structures-attached 0, structure-warnings 0, venue-warnings 2"
echo "$scrape_output" | grep -qF "$expected_summary" \
    || { echo "FAIL: expected summary line '$expected_summary'"; exit 1; }

echo "$scrape_output" | grep -q "WARNING: mystery-room-2026-07-25-nlh-evening — venue slug 'mystery-room' not found" \
    || { echo "FAIL: expected unknown-venue-slug WARNING for mystery-room event"; exit 1; }
echo "$scrape_output" | grep -q "WARNING: goldcoast-2026-07-26-nlh-noon — venue 'goldcoast' address .* does not parse into city/state" \
    || { echo "FAIL: expected unparseable-address WARNING for goldcoast event"; exit 1; }

diff -ru tests/golden "$tmpdir" \
    || { echo "FAIL: import-scrape output does not match tests/golden"; exit 1; }

[ -f "$tmpdir/planethollywood-2026-07-22-day-2.json" ] \
    && { echo "FAIL: day2 event should not have produced a draft file"; exit 1; }
day2_files="$(find "$tmpdir" -name 'planethollywood-*' 2>/dev/null)"
[ -z "$day2_files" ] \
    || { echo "FAIL: day2 event produced unexpected file(s): $day2_files"; exit 1; }

echo "--- clone: single date ---"
clonetmp="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$clonetmp"' EXIT
cp tests/fixtures/minimal-draft.json "$clonetmp/champions-club-monster-2026-08-01.json"

clone_out="$(./seeder clone "$clonetmp/champions-club-monster-2026-08-01.json" --date 2026-08-08)"
echo "$clone_out"
[ "$clone_out" = "$clonetmp/champions-club-monster-2026-08-08.json" ] \
    || { echo "FAIL: expected clone output path .../champions-club-monster-2026-08-08.json, got: $clone_out"; exit 1; }
python3 -c "
import json
d = json.load(open('$clonetmp/champions-club-monster-2026-08-08.json'))
assert d['eventDate'] == '2026-08-08', f'expected eventDate 2026-08-08, got {d[\"eventDate\"]!r}'
"

echo "--- clone: weekly recurrence (template is a Saturday) ---"
recurtmp="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$clonetmp" "$recurtmp"' EXIT
cp tests/fixtures/minimal-draft.json "$recurtmp/champions-club-monster-2026-08-01.json"
[ "$(date -j -f %Y-%m-%d 2026-08-01 +%A)" = "Saturday" ] \
    || { echo "FAIL: test fixture assumption broken — 2026-08-01 is not a Saturday"; exit 1; }

./seeder clone "$recurtmp/champions-club-monster-2026-08-01.json" --repeat weekly --until 2026-08-22

recur_files="$(find "$recurtmp" -name 'champions-club-monster-2026-08-*.json' ! -name '*2026-08-01.json')"
recur_count="$(echo "$recur_files" | grep -c . || true)"
[ "$recur_count" -eq 3 ] \
    || { echo "FAIL: expected exactly 3 cloned recurrence files, got $recur_count: $recur_files"; exit 1; }

for d in 2026-08-08 2026-08-15 2026-08-22; do
    f="$recurtmp/champions-club-monster-$d.json"
    [ -f "$f" ] || { echo "FAIL: expected recurrence file missing: $f"; exit 1; }
    weekday="$(date -j -f %Y-%m-%d "$d" +%A)"
    [ "$weekday" = "Saturday" ] \
        || { echo "FAIL: $f expected Saturday, got $weekday"; exit 1; }
done

echo "--- clone: recurrence with --until before the first occurrence emits nothing, loudly ---"
zero_out="$(./seeder clone "$recurtmp/champions-club-monster-2026-08-01.json" --repeat weekly --until 2026-08-07)"
echo "$zero_out"
echo "$zero_out" | grep -qF "no occurrences generated (--until is before the first weekly recurrence)" \
    || { echo "FAIL: expected a zero-occurrence notice when --until precedes the first recurrence"; exit 1; }

echo "--- clone: --repeat + --date is a usage error ---"
if clone_conflict_output=$(./seeder clone "$recurtmp/champions-club-monster-2026-08-01.json" \
    --repeat weekly --date 2026-08-08 --until 2026-08-22 2>&1); then
    echo "FAIL: --repeat + --date should exit nonzero"
    exit 1
fi
echo "$clone_conflict_output" | grep -q "mutually exclusive" \
    || { echo "FAIL: expected a mutually-exclusive error message, got: $clone_conflict_output"; exit 1; }

echo "--- publish: structureless draft dry run WITHOUT --allow-empty-structure ---"
pubtmp="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$clonetmp" "$recurtmp" "$pubtmp"' EXIT
python3 -c "
import json
d = json.load(open('tests/fixtures/minimal-draft.json'))
d['blindLevels'] = []
json.dump(d, open('$pubtmp/structureless.json', 'w'))
"
skip_output="$(./seeder publish "$pubtmp/structureless.json" --env development)"
echo "$skip_output"
echo "$skip_output" | grep -q "^SKIP .*no blind levels" \
    || { echo "FAIL: expected SKIP mentioning 'no blind levels' for a structureless draft"; exit 1; }
echo "$skip_output" | grep -qF "published 0, skipped 1, failed 0 (dry run)" \
    || { echo "FAIL: expected summary line 'published 0, skipped 1, failed 0 (dry run)'"; exit 1; }

echo "--- publish: structureless draft dry run WITH --allow-empty-structure ---"
warn_output="$(./seeder publish "$pubtmp/structureless.json" --env development --allow-empty-structure)"
echo "$warn_output"
echo "$warn_output" | grep -q "^WARNING .*no blind levels" \
    || { echo "FAIL: expected WARNING mentioning 'no blind levels' with --allow-empty-structure"; exit 1; }
echo "$warn_output" | grep -q "DRY RUN — would POST to CloudKit Web Services" \
    || { echo "FAIL: expected the dry-run publish print to proceed with --allow-empty-structure"; exit 1; }
echo "$warn_output" | grep -qF "published 1, skipped 0, failed 0 (dry run)" \
    || { echo "FAIL: expected summary line 'published 1, skipped 0, failed 0 (dry run)'"; exit 1; }

echo "PASS"
