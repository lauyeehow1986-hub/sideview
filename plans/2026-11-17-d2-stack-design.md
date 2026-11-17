# sideview D2: stack and compare columns (build notes)

- **Date:** 2026-11-17
- **Parent spec:** `plans/2026-11-16-derived-cards-design.md` (approved 2026-11-16). Sections 5 and 6 there are the
  design; this note only fixes what D1's finished code changes or leaves open. Points I settled myself are **(my call)**.
- **Status:** ready to plan. Build after the weekly reset, on Opus (the cast rules and the lazy/in-memory match are the risk).
- **Delivery:** one PR (D2), branch from `main`. No version bump (0.10.0 waits for D3).

## What D1 already gives D2
- `R/derive.R`: `sv_derive_ops` (add `"stack"`), `sv_derive_clean()` / `sv_derive_validate()` / `sv_derive_card()`,
  `sv_derive_name()`, `sv_derive_request_of()`; the wire `derive_request` / `sideview_derive_result` /
  `sideview_card_add` with `derived`; the `derive` pipeline step and `compose()` assignment; state, undo, module
  routing, lazy placement (`sv_lazy_place()`). D2 adds an op and a check, not a new mechanism.
- Section 6 of the parent spec stands as written (exact-name match, near-miss flag, cast order, labels, `source` id
  column, lazy `union_all()`).

## Decisions for the build **(my calls)**
1. **Check is not stored.** `stack_check_request {id, tables}` -> `sideview_stack_check {id, columns, code_preview,
   text}` computes from the inputs; `Open stacked card` sends `derive_request` with `op: "stack"` and
   `args: {fixes: [{column, action: "cast"|"rename"|"keep", to}], id_col}`. R re-checks `fixes` against the data at
   open time (a stale check cannot build a card the code would not rebuild).
2. **2 to 8 inputs**, no input twice; a derived card may be an input ("as loaded" rule of 5.1).
3. **A cast that would turn non-missing values into NA warns and does not block.** The count is shown beside the
   Open button and in the summary text; the generated code carries the same cast, so the card equals its code.
4. **Row count of the stacked card = the sum of its inputs' rows** (the button shows it; a test holds it).
5. **Name** `<first>_stacked` (`_2`, `_3` on a clash), as 5.1; `source` id column is `source`, or `source_2`... if taken.
6. **CDISC tag** is kept only when all inputs share one (5.3).
7. **Widget:** no Stack tab; a state with a stack step opened there is shown disabled with the D1 toast.
8. **Console:** `sv_stack_check(...)` (printed column table) and `sv_stack(..., check = )`, as 8 of the parent spec.
9. **List view:** a Stack builder under the existing builder sections, showing the same `text` R sends.

## Tests the plan must contain
- In-memory vs lazy (duckdb and arrow) stack: same rows, same row count, same labels, `expect_equal(tolerance = 1e-12)`.
- Each cast rule in 6 (logical < integer < double < character; Date/POSIXct; factor union), incl. NA-introducing counts.
- Near-miss (case) flagged and never merged; label differences listed; column only in some inputs is NA elsewhere.
- Generated code `parse()`s, runs with dplyr only, and rebuilds the card; state round trip and undo of the derive step.
- Module: client naming a card outside the store is refused; the real-browser test for the Stack tab (layout + axe).

## Left to the builder
Drawer layout of the Stack tab (follow the Join/SUPP builder patterns and `--sv-*` tokens), the column-table markup
(a real `<table>` with headers, for the screen reader pass), and the exact wording of `text`.
