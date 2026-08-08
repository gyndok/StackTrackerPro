#!/usr/bin/env python3
"""pokeratlas-fetch.py — component 5 of the seeder bulk-upgrades pipeline.

Turns PokerAtlas Texas listing/detail pages into the same tournaments.json
shape `seeder import-scrape` consumes (see
docs/superpowers/specs/2026-07-17-seeder-bulk-upgrades-design.md, component
5, which is the binding source for every rule below).

    pokeratlas-fetch.py --area texas --venues tx-venues.yml \
        --from YYYY-MM-DD --to YYYY-MM-DD --out .out/pokeratlas-tournaments.json
        [--fixtures <dir>] [--keep-going]

Stdlib only; shells out to the `firecrawl` CLI (must already be installed
and logged in — see README.md) rather than doing its own HTTP, since plain
HTTP to PokerAtlas is bot-blocked (403) but firecrawl renders the JS and
gets through.

ToS posture: PokerAtlas's terms likely prohibit automated collection. This
fetcher is deliberately low-volume — allowlisted venues only (tx-venues.yml),
date-windowed, rate-limited to <=1 request/second, meant for a weekly cadence
— and is run under the user's own judgment, not as a fire-and-forget system.
Page-structure changes will need occasional parser maintenance (see
tests/fixtures/pokeratlas/README.md), and failures here are loud: a page
that yields nothing usable prints to stderr and the process exits nonzero.

`--fixtures <dir>` bypasses firecrawl entirely and is what the test suite
uses (see test.sh) — it reads `<dir>/listing.md` for the listing page, and
assigns `<dir>/detail-*.md` files (sorted by filename) to qualifying listing
rows in the order they're encountered. There's no live per-URL mapping in
fixture mode since there's no real network call to key off of; this is a
deliberate stand-in for the live per-row `firecrawl scrape <href>` call.
"""

import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone as dt_timezone

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python 3.9+ ships zoneinfo
    ZoneInfo = None

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PAGECACHE_DIR = os.path.join(SCRIPT_DIR, ".pagecache")

# ---------------------------------------------------------------------------
# tx-venues.yml loader — a grep-grade line scanner mirroring the Swift
# loader in import-scrape.swift's loadVenuesFromYAMLGrep, so the same file
# works for both tools without needing a real YAML dependency.
# ---------------------------------------------------------------------------

_SLUG_LINE_RE = re.compile(r"^-\s*slug:\s*(.+)$")
_KV_LINE_RE = re.compile(r"^([A-Za-z_]+):\s*(.*)$")


def load_venues(path):
    """Returns {slug: {slug, display_name, city, state, timezone, address?}}."""
    venues = {}
    current = None

    def flush():
        if current and current.get("slug"):
            venues[current["slug"]] = current

    with open(path, encoding="utf-8") as f:
        for raw_line in f:
            stripped = raw_line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            m = _SLUG_LINE_RE.match(stripped)
            if m:
                flush()
                current = {"slug": m.group(1).strip().strip("\"'")}
                continue
            if current is None:
                continue
            m = _KV_LINE_RE.match(stripped)
            if m:
                key, value = m.group(1), m.group(2).strip().strip("\"'")
                current[key] = value
    flush()
    return venues


# ---------------------------------------------------------------------------
# Listing page parsing
# ---------------------------------------------------------------------------

ROW_START_RE = re.compile(r"^\s*\d+\.\s*\[", re.MULTILINE)
HREF_RE = re.compile(r"\]\((https://www\.pokeratlas\.com/poker-tournament/[^)\s]+)\)")
VENUE_BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")
TOPID_RE = re.compile(r"[?&]topid=(\d+)(?:-(\d{4}-\d{2}-\d{2}))?")
BULLET_RE = re.compile(r"^\s*-\s*(.+?)\s*$", re.MULTILINE)
TIME_RE = re.compile(r"^(\d{1,2}):(\d{2})\s*(am|pm)$", re.IGNORECASE)
DOLLAR_BULLET_RE = re.compile(r"^\$([\d,.]+)$")
DATE_ANNOT_RE = re.compile(r"^\s*\((\d{1,2})/(\d{1,2})\)\s*$", re.MULTILINE)

_GAME_CODE_MAP = {"PLO5": "PLO", "PL5CD": "PLO", "PL5COM": "PLO"}

# Buy-in price token inside a tournament URL slug: the number sandwiched
# between dashes right before either the start-time token (`-400-1100am-`,
# `-140-500pm-`) or the game token (`-300-nl-holdem`, `-40-pl-omaha`,
# `-40-ml-m-`). Guarantees in slugs carry a k/m suffix (`-2k-gtd-`,
# `-100k-gtd-`) so pure-digit matching never picks them up.
SLUG_PRICE_RE = re.compile(r"-(\d+)-(?:\d{3,4}(?:am|pm)\b|(?:nl|pl|ml)-)", re.IGNORECASE)

# Escaped markdown punctuation firecrawl emits inside titles/names
# (SS\_Side, \#, \$, \*, ...): `\X` -> `X`.
_MD_ESCAPE_RE = re.compile(r"\\(.)")


def unescape_md(text):
    if text is None:
        return None
    return _MD_ESCAPE_RE.sub(r"\1", text)


def slug_price(href):
    """Buy-in dollars from the URL slug, or None. The slug is the most
    reliable price source on PokerAtlas — titles routinely contain
    guarantee amounts ("$2K GTD") that look like prices."""
    path = href.split("?", 1)[0]
    m = SLUG_PRICE_RE.search(path)
    return float(m.group(1)) if m else None


def normalize_game_code(raw):
    code = raw.strip().upper()
    return _GAME_CODE_MAP.get(code, code)


def parse_time_12h(text):
    m = TIME_RE.match(text.strip())
    if not m:
        return None
    hh, mm, ampm = int(m.group(1)), int(m.group(2)), m.group(3).lower()
    if ampm == "pm" and hh != 12:
        hh += 12
    if ampm == "am" and hh == 12:
        hh = 0
    return (hh, mm)


def split_listing_rows(markdown_text):
    starts = [m.start() for m in ROW_START_RE.finditer(markdown_text)]
    starts.append(len(markdown_text))
    return [markdown_text[starts[i]:starts[i + 1]] for i in range(len(starts) - 1)]


def parse_listing_row(chunk, from_year):
    href_m = HREF_RE.search(chunk)
    if not href_m:
        return None
    href = href_m.group(1)

    venue_m = VENUE_BOLD_RE.search(chunk[:href_m.start()])
    if not venue_m:
        return None
    venue_name = venue_m.group(1).strip()
    if not venue_name:
        return None

    topid_m = TOPID_RE.search(href)
    if not topid_m:
        return None
    topid = topid_m.group(1)
    event_date = topid_m.group(2)  # "YYYY-MM-DD" or None

    bullets = [b.strip() for b in BULLET_RE.findall(chunk)]

    time_hhmm = None
    for b in bullets:
        if TIME_RE.match(b):
            time_hhmm = parse_time_12h(b)
            break

    price = None
    game = None
    for i, b in enumerate(bullets):
        m = DOLLAR_BULLET_RE.match(b)
        if m:
            price = float(m.group(1).replace(",", ""))
            if i + 1 < len(bullets):
                game = normalize_game_code(bullets[i + 1])
            break

    if event_date is None:
        annot_m = DATE_ANNOT_RE.search(chunk)
        if annot_m:
            month, day = int(annot_m.group(1)), int(annot_m.group(2))
            event_date = f"{from_year:04d}-{month:02d}-{day:02d}"

    # Trailing plain-text description line (the row's un-linked blurb) —
    # used only as an event_name fallback if the detail page's title can't
    # be parsed.
    description = None
    lines = chunk.splitlines()
    last_bullet_idx = -1
    for idx, line in enumerate(lines):
        if re.match(r"^\s*-\s*", line):
            last_bullet_idx = idx
    for line in lines[last_bullet_idx + 1:]:
        stripped = line.strip()
        if not stripped or stripped.startswith("[") or stripped.startswith("!"):
            continue
        description = stripped
        break

    return {
        "href": href,
        "venue_name": venue_name,
        "topid": topid,
        "event_date": event_date,
        "time_hhmm": time_hhmm,
        "price": price,
        "game": game,
        "description": unescape_md(description),
    }


# ---------------------------------------------------------------------------
# Detail page parsing
# ---------------------------------------------------------------------------

TITLE_H1_RE = re.compile(r"^#\s+(.+)$", re.MULTILINE)
DATE_LINE_RE = re.compile(
    r"^([A-Za-z]+),\s+([A-Za-z]+)\s+(\d{1,2})(?:st|nd|rd|th)?\s+(\d{4})\s*$", re.MULTILINE
)
DETAIL_TIME_RE = re.compile(r"^(\d{1,2}:\d{2}\s*(?:am|pm))\s*$", re.IGNORECASE | re.MULTILINE)
# Dollar tokens in a title, with a guarantee-detector: `$2K` / `$1M`
# (magnitude suffix) or `$N GTD` are guarantees, never buy-ins.
PRICE_TOKEN_RE = re.compile(r"\$([\d,]+)([KkMm]?)")
GTD_AFTER_RE = re.compile(r"^\s*gtd\b", re.IGNORECASE)


def first_valid_price(text):
    """First $N in `text` that is plausibly a buy-in: rejects $N followed
    by a K/M magnitude suffix or (case-insensitively) the word GTD."""
    for m in PRICE_TOKEN_RE.finditer(text):
        if m.group(2):
            continue  # $2K / $1.5M — a guarantee
        if GTD_AFTER_RE.match(text[m.end():]):
            continue  # "$500 GTD" — also a guarantee
        return float(m.group(1).replace(",", ""))
    return None


# Any 5-column markdown table row — candidate structure rows. Header,
# separator, and blank spacer rows are filtered out in parse_structure_table;
# what remains either parses as a level/break or gets a loud WARNING.
TABLE_ROW_RE = re.compile(
    r"^\|([^|\n]*)\|([^|\n]*)\|([^|\n]*)\|([^|\n]*)\|([^|\n]*)\|\s*$", re.MULTILINE
)
INT_RE = re.compile(r"^\d+$")
BUYIN_ENTRY_RE = re.compile(r"Entry Fee:?\s*\$([\d,.]+)", re.IGNORECASE)
BUYIN_TOTAL_RE = re.compile(r"Total Buy-?In:?\s*\$([\d,.]+)", re.IGNORECASE)
LEVEL_NAME_RE = re.compile(r"^level\s+(\d+)$", re.IGNORECASE)

_GAME_PATTERNS = [
    (re.compile(r"no\s*limit\s*holdem|nl\s*holdem|\bnlh\b", re.IGNORECASE), "NLH"),
    (re.compile(r"pot\s*limit\s*omaha|pl\s*omaha|\bplo\b", re.IGNORECASE), "PLO"),
    (re.compile(r"\bomaha\b", re.IGNORECASE), "OMAHA"),
    (re.compile(r"\bholdem\b", re.IGNORECASE), "NLH"),
]


def detect_game(text):
    for pattern, code in _GAME_PATTERNS:
        if pattern.search(text):
            return code
    return None


def parse_structure_table(text, source="<unknown>"):
    """Level/break rows in table order, numbered sequentially INCLUDING
    breaks (LevelDraft field names) — any row whose name isn't "Level N"
    is treated as a break/pause row (covers literal "Break" rows and
    color-up markers like "Race off 100s", which are functionally the
    same thing: the clock keeps running but blinds don't change).

    Malformed rows inside the table (non-numeric minutes/blinds, a "Level"
    row without a number) are DROPPED with a WARNING naming `source` and
    the row text — never silently. The page-level zero-parse gate in main()
    is unchanged: a page whose whole table fails still errors out loudly."""
    levels = []
    n = 0
    for m in TABLE_ROW_RE.finditer(text):
        name, mins, sb, bb, ante = (cell.strip() for cell in m.groups())
        if not name and not mins and not sb and not bb and not ante:
            continue  # blank spacer row
        if name and set(name) <= set("-: ") and (not mins or set(mins) <= set("-: ")):
            continue  # markdown separator row (| --- | --- | ... |)
        if name.lower() == "name" and mins.lower() == "length":
            continue  # the structure table's header row
        if not name:
            continue
        row_text = m.group(0).strip()

        if not INT_RE.match(mins):
            print(f"WARNING: {source} — dropping unparseable structure row "
                  f"(non-numeric minutes): {row_text}", file=sys.stderr)
            continue

        level_m = LEVEL_NAME_RE.match(name)
        if level_m:
            if not all(INT_RE.match(v) for v in (sb, bb, ante) if v):
                print(f"WARNING: {source} — dropping unparseable structure row "
                      f"(non-numeric blinds/ante): {row_text}", file=sys.stderr)
                continue
            n += 1
            levels.append({
                "levelNumber": n,
                "smallBlind": int(sb or 0),
                "bigBlind": int(bb or 0),
                "ante": int(ante or 0),
                "durationMinutes": int(mins),
                "isBreak": False,
            })
        elif name.lower().startswith("level"):
            # Looks like a level row but isn't "Level <N>" — never guess.
            print(f"WARNING: {source} — dropping unparseable structure row "
                  f"(unnumbered Level): {row_text}", file=sys.stderr)
            continue
        else:
            n += 1
            levels.append({
                "levelNumber": n,
                "smallBlind": 0,
                "bigBlind": 0,
                "ante": 0,
                "durationMinutes": int(mins),
                "isBreak": True,
                "breakLabel": name,
            })
    return levels


def parse_detail_page(text, source="<unknown>"):
    title_m = TITLE_H1_RE.search(text)
    title = title_m.group(1).strip() if title_m else None

    event_name = None
    buy_in_from_title = None
    game = None
    if title:
        if " - " in title:
            prefix, _, rest = title.partition(" - ")
        else:
            prefix, rest = title, title
        game = detect_game(prefix) or detect_game(title)
        buy_in_from_title = first_valid_price(prefix)
        if buy_in_from_title is None:
            buy_in_from_title = first_valid_price(title)
        event_name = unescape_md(re.sub(r"^\(\$[\d,.]+\)\s*", "", rest).strip())

    event_date = None
    date_m = DATE_LINE_RE.search(text)
    if date_m:
        _weekday, month_name, day, year = date_m.groups()
        try:
            month = datetime.strptime(month_name, "%B").month
            event_date = f"{int(year):04d}-{month:02d}-{int(day):02d}"
        except ValueError:
            event_date = None

    time_hhmm = None
    time_m = DETAIL_TIME_RE.search(text)
    if time_m:
        time_hhmm = parse_time_12h(time_m.group(1).replace(" ", ""))

    levels = parse_structure_table(text, source=source)

    entry_m = BUYIN_ENTRY_RE.search(text)
    total_m = BUYIN_TOTAL_RE.search(text)
    if entry_m and total_m:
        entry = float(entry_m.group(1).replace(",", ""))
        total = float(total_m.group(1).replace(",", ""))
        buy_in_usd = total
        rake_usd = round(total - entry, 2)
    else:
        buy_in_usd = buy_in_from_title
        rake_usd = None

    return {
        "event_name": event_name,
        "buy_in_usd": buy_in_usd,
        "rake_usd": rake_usd,
        "game": game,
        "event_date": event_date,
        "time_hhmm": time_hhmm,
        "structure_levels": levels,
    }


# ---------------------------------------------------------------------------
# firecrawl subprocess + caching
# ---------------------------------------------------------------------------

def firecrawl_scrape(url):
    try:
        result = subprocess.run(
            ["firecrawl", "scrape", url, "markdown", "--wait-for", "3000"],
            capture_output=True, text=True, timeout=60,
        )
    except FileNotFoundError:
        raise RuntimeError(
            "firecrawl CLI not found on PATH — install and `firecrawl login` per README.md setup"
        )
    if result.returncode != 0:
        raise RuntimeError(f"firecrawl scrape failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout


def pagecache_path(cache_dir, url):
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()
    return os.path.join(cache_dir, f"{digest}.md")


def fetch_detail_cached(url, cache_dir):
    """Detail pages are cached indefinitely by URL hash — re-runs within a
    week (or longer) only re-fetch the listing, not every detail page."""
    path = pagecache_path(cache_dir, url)
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return f.read()
    text = firecrawl_scrape(url)
    os.makedirs(cache_dir, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return text


def iso_start_at(event_date, hh, mm, tz_name):
    year, month, day = (int(x) for x in event_date.split("-"))
    if ZoneInfo is not None:
        dt = datetime(year, month, day, hh, mm, tzinfo=ZoneInfo(tz_name))
        return dt.isoformat()
    # Extremely defensive fallback if zoneinfo is somehow unavailable —
    # emit a naive local time with no offset rather than crash.
    return f"{event_date}T{hh:02d}:{mm:02d}:00"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--area", default="texas", help="PokerAtlas area slug (default: texas)")
    p.add_argument("--venues", required=True, help="tx-venues.yml allowlist path")
    p.add_argument("--from", dest="from_date", required=True, metavar="YYYY-MM-DD")
    p.add_argument("--to", dest="to_date", required=True, metavar="YYYY-MM-DD")
    p.add_argument("--out", required=True, help="output tournaments.json path")
    p.add_argument("--fixtures", help="read listing.md/detail-*.md from this dir instead of firecrawl")
    p.add_argument("--keep-going", action="store_true",
                    help="collect all page failures instead of stopping at the first one")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])

    if args.to_date < args.from_date:
        print(f"ERROR: --to {args.to_date} is before --from {args.from_date} — "
              f"inverted date range, nothing would ever match", file=sys.stderr)
        sys.exit(1)

    try:
        venues = load_venues(args.venues)
    except OSError as exc:
        print(f"ERROR: cannot read venues file {args.venues}: {exc}", file=sys.stderr)
        sys.exit(1)
    # Listing rows are matched on the room's bold text on the PokerAtlas
    # page. That's `listing_name` when the venue defines one (used when the
    # dedup-critical display_name differs from what PokerAtlas shows, e.g.
    # "Champions Club Texas" vs the listing's "Champions Club"), with
    # display_name accepted as well.
    allow_by_name = {}
    for v in venues.values():
        for name in (v.get("listing_name"), v.get("display_name")):
            if name:
                allow_by_name[name.strip().lower()] = v

    if args.fixtures:
        with open(os.path.join(args.fixtures, "listing.md"), encoding="utf-8") as f:
            listing_text = f.read()
        detail_queue = sorted(glob.glob(os.path.join(args.fixtures, "detail-*.md")))
    else:
        listing_url = f"https://www.pokeratlas.com/poker-tournaments/{args.area}/upcoming"
        listing_text = firecrawl_scrape(listing_url)  # never cached — always fresh
        detail_queue = None

    from_year = int(args.from_date[:4])
    rows = split_listing_rows(listing_text)
    if not args.fixtures and not any(parse_listing_row(c, from_year) for c in rows):
        # A listing page with zero parseable tournament rows is a JS-render
        # failure, never reality (PokerAtlas always lists something) — retry
        # once, then fail loudly rather than reporting a silent empty day.
        print("WARNING: listing parsed to zero rows — re-fetching once", file=sys.stderr)
        listing_text = firecrawl_scrape(listing_url)
        rows = split_listing_rows(listing_text)
        if not any(parse_listing_row(c, from_year) for c in rows):
            print(f"ERROR: listing page yielded no tournament rows twice ({listing_url}) — "
                  f"page markup may have changed; not writing an empty output", file=sys.stderr)
            sys.exit(1)

    events = []
    errors = []
    made_first_call = False

    for chunk in rows:
        row = parse_listing_row(chunk, from_year)
        if row is None:
            continue

        venue = allow_by_name.get(row["venue_name"].strip().lower())
        if venue is None:
            continue  # not on the allowlist — ignored on purpose

        if row["event_date"] is not None:
            if row["event_date"] < args.from_date or row["event_date"] > args.to_date:
                continue  # known date, out of window — never fetched

        try:
            if args.fixtures:
                if not detail_queue:
                    raise RuntimeError(f"no more detail-*.md fixtures available for {row['href']}")
                detail_path = detail_queue.pop(0)
                with open(detail_path, encoding="utf-8") as f:
                    detail_text = f.read()
                detail_source = detail_path
            else:
                if made_first_call:
                    time.sleep(5)  # Firecrawl free-tier rate limit is ~14 req/min  # spec: <=1 request/second
                made_first_call = True
                detail_text = fetch_detail_cached(row["href"], DEFAULT_PAGECACHE_DIR)
                detail_source = row["href"]

            detail = parse_detail_page(detail_text, source=detail_source)
        except Exception as exc:  # noqa: BLE001 - loud, deliberate catch-all
            print(f"ERROR: failed to fetch/parse detail page {row['href']}: {exc}", file=sys.stderr)
            errors.append(row["href"])
            if not args.keep_going:
                sys.exit(1)
            continue

        if not detail["structure_levels"] and detail["buy_in_usd"] is None and not detail["event_name"]:
            print(f"ERROR: zero parsed fields from {row['href']}", file=sys.stderr)
            errors.append(row["href"])
            if not args.keep_going:
                sys.exit(1)
            continue

        event_date = row["event_date"] or detail["event_date"]
        if event_date is None:
            print(f"ERROR: could not determine event date for {row['href']} "
                  f"(missing from both the listing topid/annotation and the detail page)", file=sys.stderr)
            errors.append(row["href"])
            if not args.keep_going:
                sys.exit(1)
            continue
        if event_date < args.from_date or event_date > args.to_date:
            continue  # resolved (from the detail page) to be out of window

        hh_mm = row["time_hhmm"] or detail["time_hhmm"] or (12, 0)
        tz_name = venue.get("timezone", "America/Chicago")
        start_at_pt = iso_start_at(event_date, hh_mm[0], hh_mm[1], tz_name)

        game = detail["game"] or row["game"] or "OTHER"
        event_name = detail["event_name"] or row["description"] or "Unknown Event"

        # Buy-in priority: an explicit Buy-In section total (the only source
        # that also gives us the rake split) beats everything; otherwise the
        # URL slug's price token beats the title's $N (titles routinely
        # embed guarantees like "$2K GTD" that masquerade as prices); the
        # listing row's own $-bullet is the last resort.
        if detail["rake_usd"] is not None:
            buy_in_usd = detail["buy_in_usd"]
        else:
            buy_in_usd = slug_price(row["href"])
            if buy_in_usd is None:
                buy_in_usd = detail["buy_in_usd"]
            if buy_in_usd is None:
                buy_in_usd = row["price"]

        events.append({
            "id": f"{venue['slug']}-{event_date}-{row['topid']}",
            "venue": venue["slug"],
            "date_pt": event_date,
            "start_at_pt": start_at_pt,
            "game": game,
            "game_category": game.lower(),
            "event_name": event_name,
            "buy_in_usd": buy_in_usd,
            "rake_usd": detail["rake_usd"],
            "re_entry": {"type": "unknown"},
            "is_day2": False,
            "structure_levels": detail["structure_levels"],
        })

    out_dir = os.path.dirname(os.path.abspath(args.out))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(
            {"generated_at": datetime.now(dt_timezone.utc).isoformat(), "tournaments": events},
            f, indent=2, sort_keys=True,
        )
        f.write("\n")

    suffix = f"; {len(errors)} page failure(s)" if errors else ""
    print(f"fetched {len(events)} event(s) into {args.out}{suffix}")

    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
