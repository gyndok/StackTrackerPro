# Tournament Add-On Support — Design

Date: 2026-06-14
Status: Approved

## Problem

Some tournaments (e.g. Champions Club "25K GTD Saturday Special") offer an
**add-on**: a fixed-price purchase that grants chips, with the price split
between house rake and the prize pool. Example: $100 add-on → 30,000 chips,
$10 to the house, $90 to the prize pool.

The `Tournament` model has no add-on fields, so add-on chips and prize-pool
money are invisible to every calculation. This understates `totalChipsInPlay`,
`prizePool`, `houseRake`, the player's `totalInvestment`, and (transitively)
the average-stack projections (`averageStack`, `averageStackAtBubble`,
`averageStackAtFinalTable`) and `overlay`.

Add-on uptake varies across the field and is not knowable exactly, so the
field-wide count is an **observed, editable value**, not an assumption.

## Data model (new `Tournament` fields, CloudKit-safe defaults)

- `addOnAvailable: Bool = false` — master switch; all add-on math is ignored when false
- `addOnCost: Int = 0` — total price (e.g. 100)
- `addOnRake: Int = 0` — house cut (e.g. 10)
- `addOnChips: Int = 0` — chips granted per add-on (e.g. 30,000)
- `addOnsCount: Int = 0` — field-wide add-ons taken; editable during play
- `playerAddOnsUsed: Int = 0` — add-ons the player took; feeds their investment

Derived:
- `addOnToPrizePool: Int` = `max(0, addOnCost - addOnRake)` (e.g. 90) — keeps the
  three money figures internally consistent

## Calculation changes

All gated on `addOnAvailable`:
- `totalChipsInPlay` += `addOnsCount * addOnChips` → fixes Avg Stack, Avg @ Bubble, Avg @ FT
- `prizePool` += `addOnsCount * addOnToPrizePool` → fixes Overlay
- `houseRake` += `addOnsCount * addOnRake`
- `totalInvestment` += `playerAddOnsUsed * addOnCost` → fixes profit/ROI
- `playersNeededForGuarantee` — subtract add-on prize-pool money from the
  remaining guarantee before dividing; identical to current behavior when no
  add-ons exist

## UI

- **Setup (`TournamentSetupView`):** an "Add-On" section — toggle, then Cost /
  House Rake / Chips fields with "To prize pool" shown as a computed read-out.
- **Live (`TournamentMetricsView`):** an editable "Add-Ons" card (field-wide
  count) shown only when `addOnAvailable`; the editor also adjusts the player's
  own add-on count (`playerAddOnsUsed`).
- **Scanner (`PokerAtlasScanner`):** if the scan exposes add-on cost/chips,
  pre-fill those and set `addOnAvailable = true`. Rake split is venue-specific
  and entered by the user (PokerAtlas does not publish it).

## Testing

Unit tests: prize pool, total chips in play, house rake, the three average-stack
projections, and player investment — each with and without add-ons; plus the
derived `addOnToPrizePool` and the `addOnAvailable=false` short-circuit.
