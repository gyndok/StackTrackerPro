# Champions Club Summer Poker Open 2026 — Seeding Checklist (Front page: Aug 5–11)

Source: SPO-2026-Schedule-Front-UPDATED.pdf (official flyer, $1.2M+ GTD, Aug 5–17).
Purpose: cross-check the weekly `pokeratlas-fetch` runs during series weeks — every event
below should appear in the drafts for its date (venue slug `champions-club-houston`,
displayed as "Champions Club Texas"). Any missing row is a hand-seed candidate
(`seeder parse` on the structure sheet, or clone-and-edit). Day 2s/final tables are
skipped by the importer by default — expected, not gaps.

⚠️ BACK PAGE (Aug 12–17) still needed — ask for it before the second series week.

| Date | Time | Event | Buy-in | GTD |
|---|---|---|---|---|
| Wed 8/5 | 11:00 AM | 100K GTD NLH Monster Stack | $400 | $100,000 |
| Wed 8/5 | 6:00 PM | 5K GTD NLH | $250 | $5,000 |
| Wed 8/5 | 9:00 PM | Kickstarter Satellite into Main Event | $100 | 1 Seat |
| Thu 8/6 | 9:00 AM | Kickstarter Satellite into Main Event | $100 | 1 Seat |
| Thu 8/6 | 11:00 AM | ★ 500K GTD NLH Main Event (1A) | $800 | $500,000 |
| Thu 8/6 | 3:00 PM | Milestone Satellite to Main Event | $160 | 5 Seats |
| Thu 8/6 | 4:00 PM | 10K GTD H.O.R.S.E. | $500 | $10,000 |
| Thu 8/6 | 5:00 PM | ★ 500K GTD NLH Main Event (1B) | $800 | $500,000 |
| Thu 8/6 | 9:00 PM | Kickstarter Satellite into Main Event | $100 | 1 Seat |
| Fri 8/7 | 9:00 AM | Kickstarter Satellite into Main Event | $100 | 1 Seat |
| Fri 8/7 | 11:00 AM | ★ 500K GTD NLH Main Event (1C) | $800 | $500,000 |
| Fri 8/7 | 3:00 PM | Milestone Satellite to Main Event | $160 | 5 Seats |
| Fri 8/7 | 5:00 PM | ★ 500K GTD NLH Main Event (1D) | $800 | $500,000 |
| Fri 8/7 | 9:00 PM | Kickstarter Satellite into Main Event | $100 | 1 Seat |
| Sat 8/8 | 9:00 AM | Kickstarter Satellite into Main Event | $100 | 1 Seat |
| Sat 8/8 | 11:00 AM | ★ 500K GTD NLH Main Event (1E) | $800 | $500,000 |
| Sat 8/8 | 3:00 PM | Milestone Satellite to Main Event | $160 | 5 Seats |
| Sat 8/8 | 5:00 PM | ★ 500K GTD NLH Main Event (1F) | $800 | $500,000 |
| Sat 8/8 | 9:00 PM | ★ 500K GTD NLH Main Event (Turbo 1G) | $800 | $500,000 |
| Sun 8/9 | 8:00 AM | ★ 500K GTD NLH Main Event (Turbo 1H) | $800 | $500,000 |
| Sun 8/9 | 1:00 PM | Women's NLH | $250 | $10,000 |
| Sun 8/9 | 3:00 PM | ★ Main Event Day 2 (importer skips Day 2s — expected) | $800 | — |
| Sun 8/9 | 5:00 PM | 10K GTD Big O | $300 | $10,000 |
| Sun 8/9 | 9:00 PM | Kickstarter Satellite into PLO Championship | $120 | 1 Seat |
| Mon 8/10 | 10:00 AM | Senior's NLH | $250 | $10,000 |
| Mon 8/10 | TBD | ★ Main Event Final Table (not a fresh entry — expected skip) | — | — |
| Mon 8/10 | 2:00 PM | 10K GTD Turbo NLH | $300 | $10,000 |
| Mon 8/10 | 4:00 PM | 150K GTD PLO Championship (Day 1?) | $1,100 | $150,000 |
| Mon 8/10 | 6:00 PM | Milestone Satellite to PLO Championship | $220 | 3 Seats |
| Mon 8/10 | 9:00 PM | Kickstarter Satellite into PLO Championship | $120 | 1 Seat |
| Tue 8/11 | 11:00 AM | 25K GTD 6-MAX NLH | $500 | $25,000 |
| Tue 8/11 | 2:00 PM | Milestone Satellite to PLO Championship | $220 | 3 Seats |
| Tue 8/11 | 4:00 PM | 150K GTD PLO Championship | $1,100 | $150,000 |
| Tue 8/11 | 6:00 PM | 5K GTD NLH | $250 | $5,000 |
| Tue 8/11 | 9:00 PM | Kickstarter Satellite into PLO Championship | $120 | 1 Seat |

## Notes for series weeks

- Main Event flights share date+buy-in on multi-flight days (8/6, 8/7, 8/8): verify BOTH
  flights survive as separate drafts (dedup suffix must differ; if PokerAtlas doesn't
  encode flights, the second same-day $800 NLH will collide — hand-adjust `dedupSuffix`
  to 1A/1B etc. in the colliding drafts before publish).
- PLO Championship dedup: $1,100 PLO appears 8/10 AND 8/11 — different dates, no collision.
- Run the rocket ship at least Mon + Wed + Fri during series weeks (PokerAtlas listing
  only surfaces the nearest day or two per pull).
