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

echo "--- pokeratlas-fetch: fixture-driven fetch (no network) ---"
patmp="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$clonetmp" "$recurtmp" "$pubtmp" "$patmp"' EXIT

./pokeratlas-fetch.py --fixtures tests/fixtures/pokeratlas --venues tx-venues.yml \
    --from 2026-07-17 --to 2026-07-18 --out "$patmp/pokeratlas-tournaments.json"

python3 -c "
import json
d = json.load(open('$patmp/pokeratlas-tournaments.json'))
t = d['tournaments']
assert len(t) == 3, f'expected 3 events (Palace Poker unallowlisted + Lodge Austin out-of-window filtered out), got {len(t)}'
by_id = {e['id']: e for e in t}
monster = by_id['champions-club-houston-2026-07-18-278824']
flashback = by_id['champions-club-houston-2026-07-17-287721']
trap = by_id['tch-social-austin-2026-07-18-283101']
assert len(monster['structure_levels']) >= 8, f'expected >=8 structure_levels on the monster-stack event, got {len(monster[\"structure_levels\"])}'
assert monster['rake_usd'] is None, f'expected rake_usd null for the no-Buy-In-tab detail fixture (detail-nobuyintab.md), got {monster[\"rake_usd\"]!r}'
assert flashback['rake_usd'] == 20.0, f'expected rake_usd 20.0 (Total Buy-In 90 - Entry Fee 70) for the with-Buy-In fixture, got {flashback[\"rake_usd\"]!r}'
# The \$2K-GTD trap: title contains 'SS_Side \$2K GTD ... \$60 NLH' — the
# guarantee must never be read as the buy-in; \$60 comes from the URL slug.
assert trap['buy_in_usd'] == 60.0, f'expected buy_in_usd 60.0 from the slug (NOT 2.0 from the \$2K GTD guarantee), got {trap[\"buy_in_usd\"]!r}'
# Markdown escapes stripped from the emitted event name.
assert 'SS_Side' in trap['event_name'], f'expected unescaped SS_Side in event_name, got {trap[\"event_name\"]!r}'
assert chr(92) not in trap['event_name'], f'event_name still carries a backslash escape: {trap[\"event_name\"]!r}'
"

echo "--- pokeratlas-fetch output -> import-scrape (closing the loop: components 5 -> 2) ---"
padraft="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$clonetmp" "$recurtmp" "$pubtmp" "$patmp" "$padraft"' EXIT

pa_scrape_output="$(./seeder import-scrape "$patmp/pokeratlas-tournaments.json" --venues tx-venues.yml \
    --from 2026-07-01 --to 2026-07-31 --out "$padraft")"
echo "$pa_scrape_output"
echo "$pa_scrape_output" | grep -qF "emitted 3, skipped-day2 0, structures-attached 3, structure-warnings 0, venue-warnings 0" \
    || { echo "FAIL: expected PokerAtlas import-scrape summary line (incl. venue-warnings 0 — explicit city/state must suppress the address warning)"; exit 1; }

python3 -c "
import json, glob
files = sorted(glob.glob('$padraft/*.json'))
assert len(files) == 3, f'expected 3 drafts, got {len(files)}: {files}'
for f in files:
    d = json.load(open(f))
    assert len(d['blindLevels']) > 0, f'{f} landed with no blindLevels'
    assert d['timeZone'] == 'America/Chicago', f'{f} expected timeZone America/Chicago (from tx-venues.yml), got {d[\"timeZone\"]!r}'
    assert d['venueCity'] and d['venueState'], f'{f} missing city/state (explicit tx-venues.yml city/state must be used)'
champions = json.load(open('$padraft/champions-club-houston-2026-07-18-278824.json'))
# Dedup continuity: every previously published Champions record's dedup key
# uses this exact venueName — display_name changes fork the dedup space.
assert champions['venueName'] == 'Champions Club Texas', f'expected venueName Champions Club Texas, got {champions[\"venueName\"]!r}'
assert champions['venueCity'] == 'Houston' and champions['venueState'] == 'TX'
tch = json.load(open('$padraft/tch-social-austin-2026-07-18-283101.json'))
# TCH Austin has NO address in tx-venues.yml — city/state must come from
# the explicit fields (the explicit-city path).
assert tch['venueCity'] == 'Austin' and tch['venueState'] == 'TX', f'expected explicit Austin/TX, got {tch[\"venueCity\"]!r}/{tch[\"venueState\"]!r}'
assert tch['buyIn'] == 60 and tch['entryFee'] == 0, f'expected 60/0 for the trap event, got {tch[\"buyIn\"]}/{tch[\"entryFee\"]}'
"

echo "--- pokeratlas-fetch: inverted --from/--to fails loud before fetching ---"
if inverted_out=$(./pokeratlas-fetch.py --fixtures tests/fixtures/pokeratlas --venues tx-venues.yml \
    --from 2026-07-18 --to 2026-07-17 --out "$patmp/inverted.json" 2>&1); then
    echo "FAIL: inverted date range should exit nonzero"
    exit 1
fi
echo "$inverted_out"
echo "$inverted_out" | grep -q "^ERROR: --to 2026-07-17 is before --from 2026-07-18" \
    || { echo "FAIL: expected an inverted-range ERROR line, got: $inverted_out"; exit 1; }
[ ! -f "$patmp/inverted.json" ] \
    || { echo "FAIL: inverted range should not have written an output file"; exit 1; }

echo "--- pokeratlas-fetch: zero-parse detail page fails loud (no --keep-going) ---"
if broken_out=$(./pokeratlas-fetch.py --fixtures tests/fixtures/pokeratlas-broken --venues tx-venues.yml \
    --from 2026-07-17 --to 2026-07-18 --out "$patmp/broken.json" 2>&1); then
    echo "FAIL: a zero-parse detail page should exit nonzero"
    exit 1
fi
echo "$broken_out"
echo "$broken_out" | grep -q "^ERROR: zero parsed fields from https://www.pokeratlas.com/poker-tournament/" \
    || { echo "FAIL: expected 'ERROR: zero parsed fields' naming the page URL, got: $broken_out"; exit 1; }

echo "--- pokeratlas-fetch: zero-parse with --keep-going still exits nonzero and reports the count ---"
if kg_out=$(./pokeratlas-fetch.py --fixtures tests/fixtures/pokeratlas-broken --venues tx-venues.yml \
    --from 2026-07-17 --to 2026-07-18 --out "$patmp/broken-kg.json" --keep-going 2>&1); then
    echo "FAIL: --keep-going must still exit nonzero when any page failed"
    exit 1
fi
echo "$kg_out"
echo "$kg_out" | grep -q "^ERROR: zero parsed fields from" \
    || { echo "FAIL: expected the zero-parse ERROR even with --keep-going, got: $kg_out"; exit 1; }
echo "$kg_out" | grep -qF "1 page failure(s)" \
    || { echo "FAIL: expected the summary to report '1 page failure(s)', got: $kg_out"; exit 1; }

echo "--- pokeratlas-fetch: name-column stack ranges are levels, not breaks (PLO Blitz 2026-08-08) ---"
python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('paf', 'pokeratlas-fetch.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
table = '''
| Name | Length | Small Blind | Big Blind | Ante |
| --- | --- | --- | --- | --- |
| 400-700 | 15 | 100 | 200 |  |
| 800-1,400 | 15 | 200 | 400 | 400 |
| RACE OFF 100's | 15 |  |  |  |
| 6,000-10,500 | 15 | 1500 | 3000 | 3000 |
| Break | 10 |  |  |  |
'''
levels = m.parse_structure_table(table, source='test-name-ranges')
nb = [l for l in levels if not l['isBreak']]
br = [l for l in levels if l['isBreak']]
assert len(nb) == 3, f'expected 3 blind levels from name-range rows, got {len(nb)}'
assert len(br) == 2, f'expected RACE OFF + Break rows to stay breaks, got {len(br)}'
assert (nb[0]['smallBlind'], nb[0]['bigBlind'], nb[0]['ante']) == (100, 200, 0), nb[0]
assert (nb[2]['smallBlind'], nb[2]['bigBlind'], nb[2]['ante']) == (1500, 3000, 3000), nb[2]
assert br[0]['breakLabel'].startswith('RACE OFF'), br[0]
print('name-range table: 3 levels + 2 breaks OK')
"

echo "PASS"
