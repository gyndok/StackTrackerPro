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

echo "PASS"
