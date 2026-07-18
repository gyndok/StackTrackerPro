#!/bin/bash
# One-click weekly seeding: fetch the coming week's Texas tournaments from
# PokerAtlas, convert to drafts, show them, and (after you confirm) publish
# to production. Safe to re-run anytime: --skip-existing prevents duplicates,
# and every failure is loud. Launched from "Seed Tournaments.app" or by hand.
set -euo pipefail
cd "$(dirname "$0")"

FROM=$(date +%Y-%m-%d)                    # today
TO=$(date -j -v+6d +%Y-%m-%d)             # six days out = the coming week
RUN_DIR=".weekly/$FROM"
mkdir -p "$RUN_DIR"

echo "══════════════════════════════════════════════════"
echo "  StackTrackerPro weekly seed — $FROM → $TO"
echo "══════════════════════════════════════════════════"

./pokeratlas-fetch.py --area texas --venues tx-venues.yml \
    --from "$FROM" --to "$TO" --out "$RUN_DIR/week.json"

./seeder import-scrape "$RUN_DIR/week.json" --venues tx-venues.yml \
    --out "$RUN_DIR/drafts"

echo
echo "── Drafts ─────────────────────────────────────────"
python3 - "$RUN_DIR/drafts" <<'PY'
import json, glob, sys
for f in sorted(glob.glob(sys.argv[1] + "/*.json")):
    d = json.load(open(f))
    lv = len(d["blindLevels"])
    print(f'  {d["eventDate"]}  {d["startTimeLocal"]:>5}  ${d["buyIn"]:>5}  '
          f'{d["venueName"][:28]:28}  {d["tournamentName"][:44]:44}  {lv} rows')
PY
echo "───────────────────────────────────────────────────"
echo
read -r -p "Publish these to PRODUCTION? [Enter = yes, Ctrl+C = abort] "

./seeder publish "$RUN_DIR"/drafts/*.json --env production --execute --skip-existing

echo
echo "Done. This window can be closed."
