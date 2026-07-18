# PokerAtlas fixtures

Snapshots of PokerAtlas Texas pages dated **2026-07-17** (captured via the
`firecrawl` CLI during Task 4 implementation — see
`docs/superpowers/specs/2026-07-17-seeder-bulk-upgrades-design.md` component
5). `listing.md` is a trimmed, lightly-edited real listing page; the two
detail fixtures' provenance (real vs. hand-written sections) is documented
in an HTML comment at the top of each file. PokerAtlas markup will drift
over time — when `pokeratlas-fetch.py`'s tests start failing against real
pulls, re-capture these with `firecrawl scrape <url> markdown -o <file>`
and re-diff against `pokeratlas-fetch.py`'s parsing regexes before assuming
the parser itself is wrong.

The sibling `../pokeratlas-broken/` directory holds fully synthetic
fixtures for the loud-failure paths (a qualifying listing row whose detail
page parses to nothing). It lives separately because detail fixtures in
THIS directory are assigned to qualifying listing rows in sorted-filename
order — a broken detail file here would hijack a working row's slot.
