# sideview D3: compare data cuts by key (build notes)

- **Date:** 2026-11-21
- **Parent spec:** `plans/2026-11-16-derived-cards-design.md` (approved 2026-11-16). Sections 5, 7, 8 and 9 there are
  the design; this note only fixes what D1 and D2's finished code changes or leaves open. Points I settled myself are
  **(my call)**; the user approved them all in chat on 2026-11-21.
- **Status:** approved; ready to plan.
- **Delivery:** one PR (D3), branch `d/d3-compare` from `main`. It bumps the version to **0.10.0** (parent spec: the
  version goes to 0.10.0 with D3).

## Intent (from the parent spec)
A biostatistician compares two cuts of the same table (June vs September AE extract) by key: how many rows were
added, removed, changed or stayed the same, which columns changed type, and the rows behind each count as cards that
behave like any other card and that the generated code rebuilds. It was ranked highest of D's three features.

## What D1 and D2 already give D3
- `R/derive.R`: `sv_derive_ops` (add the three compare ops), `sv_derive_clean()` / `sv_derive_validate()` /
  `sv_derive_card()`, `sv_derive_name()`, `sv_derive_request_of()`; the wire `derive_request` /
  `sideview_derive_result` / `sideview_card_add` with `derived`; the `derive` pipeline step and its `compose()`
  assignment; state restore and refit (`sv_derive_state_refresh`, JS `derivedArrived`), undo, module routing, lazy
  placement.
- D2's Check -> Open pattern (`stack_check_request` / `sideview_stack_check`, short check ids, `sv_stack_clean()` as the
  shared validator for module input), the drawer Stack tab and list view Stack builder as layout patterns.
- D2's lazy machinery: duckdb required for a lazy op (Arrow without duckdb refused), a data frame mixed with a lazy
  table is copied into the lazy table's duckdb connection, date-time to text via `sv_lazy_tz_text_expr()` with the
  plan's `tz_text`, `epoch_us()` for date-time arithmetic, `sv_escape_ident()` for quoting.
- `sv_key_kind()` (R/diagnostics.R) and `sv_keys_natural()` (R/cdisc_keys.R).

## Rules (parent spec 7.3, unchanged)
Added / removed / changed / same by key; a key repeated in **either** version leaves all its rows, in both versions,
out of every count and card, reported as a warning with up to 5 sample keys; compared columns are those in both
versions with the same `sv_key_kind()` (so integer = double and factor = character); type-changed columns are listed,
not compared; key columns are not compared; equality is exact, NA (and NaN) in both is the same, NA in one is changed;
counts per column = rows where that column changed. The identities
`added + changed + same + repeated_rows_new = nrow(new)` and `removed + changed + same + repeated_rows_old = nrow(old)`
hold, and tests check them.

## Decisions for the build **(my calls, approved)**
1. **Compare is not stored.** `compare_request {id, old, new, by}` -> `sideview_compare {id, ...summary, text}`
   computes from the inputs. Each Open button sends `derive_request` with `op` one of `compare_added`,
   `compare_removed`, `compare_changed` and `args: {old, new, by}`; R recomputes at open, so a stale summary cannot
   build a card the code would not rebuild.
2. **Key.** Pre-filled as parent spec 7.1 (the CDISC natural key when both cards carry the same domain tag, else the
   shared columns the existing key suggestions would pick, else empty) and editable. Refused with an error reply: an
   empty key, a key column missing from either version, and old = new (the same card). A derived card may be an input.
3. **Key columns whose kinds differ** between versions compare as text, as the join check does.
4. **The `_changed` card** has the key columns, then `column`, `old`, `new` (`old` / `new` character), ordered by key,
   then by the column's position in the new table. Lazy: date-time values become text with D2's zone code (this adds
   about 20 KB per date-time column to saved state, as D2's stack does); numbers are compared after `as.numeric()` in
   the lazy-vs-memory test (parent spec 7.4).
5. **Names** `<old>_removed`, `<new>_added`, `<new>_changed` (`_2`, `_3` on a clash), as parent spec 7.4 and 5.1.
6. **Label changes are out of D3** (not compared, not listed).
7. **Lazy:** duckdb required; mixed data frame + lazy copies the data frame in, as D2; nothing is collected (counts
   are summarise queries; cards are lazy).
8. **Widget:** no Compare tab; a state with a compare step opened there shows D1's no-R toast.
9. **Console:** `sv_compare(old, new, by)` returning class `sv_compare` (summary fields plus `added`, `removed`,
   `changed`), printed as the summary of parent spec 7.2; exported and in `_pkgdown.yml`.
10. **List view:** a Compare builder under the Stack builder, showing the same `text` R sends.
11. **Version 0.10.0** in this PR: DESCRIPTION, NEWS heading, asset versions follow `sv_asset_version()`.

## Tests the plan must contain
- Compare rules on synthetic data: added, removed, changed, same; repeated keys in old only, new only, both; NA/NaN in
  both and in one; a type-changed column; a key with NA; empty versions; identical versions; integer vs double column
  compared by value; key kinds differing (compared as text). Both row identities above.
- Lazy twins (duckdb and Arrow, and data frame + lazy) equal to the in-memory result (`tolerance = 1e-12`; `_changed`
  number text compared after `as.numeric()`); a test that fails on `collect()` of a full table.
- Generated code for each of the three cards `parse()`s, runs with dplyr only and rebuilds the card (node compose ->
  R eval -> `expect_equal()` with the R-built card).
- Module: a forged `compare_request` / `derive_request` naming a card outside the store, or a missing key column, is
  refused with an error reply and no store change.
- Pipeline: the three derive steps' order, undo/redo, state save -> open rebuilds the cards.
- Real browser (chromote): the Compare tab with real mouse input, card placement not overlapping, list view text equal
  to the drawer text, axe-core on the new tab.
- Manual (the user, in RStudio): recorded in MEMORY.md only after the user reports it.

## Left to the builder
Drawer layout of the Compare tab (follow the Stack tab, `--sv-*` tokens, inline SVG icons, B's keyboard rules), the
exact wording of `text` and toasts within the existing voice, and how the compare ops share code with D2's lazy
helpers in `R/lazy.R`.
