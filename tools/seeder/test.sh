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

expected_summary="emitted 5, skipped-day2 1, structures-attached 0, structure-warnings 0"
echo "$scrape_output" | grep -qF "$expected_summary" \
    || { echo "FAIL: expected summary line '$expected_summary'"; exit 1; }

diff -ru tests/golden "$tmpdir" \
    || { echo "FAIL: import-scrape output does not match tests/golden"; exit 1; }

[ -f "$tmpdir/planethollywood-2026-07-22-day-2.json" ] \
    && { echo "FAIL: day2 event should not have produced a draft file"; exit 1; }
day2_files="$(find "$tmpdir" -name 'planethollywood-*' 2>/dev/null)"
[ -z "$day2_files" ] \
    || { echo "FAIL: day2 event produced unexpected file(s): $day2_files"; exit 1; }

echo "PASS"
