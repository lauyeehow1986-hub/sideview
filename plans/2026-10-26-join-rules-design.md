# Join rules: design

- **Date:** 2026-10-26
- **Release:** sideview 0.4.0, sub-project 2 of 4 (see `MEMORY.md`, "Next release")
- **Status:** design approved in chat, section by section; awaiting review of this written spec
- **Builds on:** `plans/2026-10-25-lazy-full-data-design.md` (sub-project 1: full data for arrow/duckdb cards)

## 1. Problem

A join step on the canvas joins on equal keys only. Two everyday clinical tasks can't be drawn:

- **Date windows:** "labs within 7 days of the visit", "doses inside a treatment period", "adverse events
  that overlap a dosing period".
- **Nearest match:** "the last lab on or before each visit", "the first visit after each lab".

`dplyr::join_by()` (dplyr 1.1.0) covers both with `between()`, `overlaps()` and `closest()`. The join check
today also stops at advice: it finds 1:m or unmatched rows but the generated code doesn't guard against
them. dplyr's `relationship` and `unmatched` arguments can make that check fail loudly when the data change.

## 2. What the user told us

- Date-window and nearest-match joins are common in their work; they also use arrow and duckdb tables.
- **Approach A:** extend the existing join step (not a new step kind, not R-only).
- All four date shapes: between, window, before/after, overlaps.
- **Strict** is a per-step toggle, off by default.
- The rule is edited **in the join step** (Pipeline tab), not in a separate dialog.
- On duckdb/arrow, nearest-match joins are **emulated in duckdb**.
- Window bounds: whole days from **-3650 to +3650**, `from <= to`.

## 3. Goals and non-goals

**Goals**
1. A join step can carry one date rule; the generated code uses `join_by()` and runs as written on data
   frames, duckdb tables and arrow tables.
2. The join check applies the rule, in all three twins, and says how many key matches the rule drops.
3. A Strict toggle writes `relationship` / `unmatched` from the check, on in-memory chains.
4. Saved workspaces without rules load unchanged.

**Non-goals**
- More than one rule per join, or rules on non-key joins (a rule always sits next to at least one
  equality key from a spline). A rule join with no equality key is not offered.
- Hour or minute windows on date-times (the window counts whole days).
- `closest()` combined with right or full joins.
- Strict on lazy chains (duckdb rejects `relationship` / `unmatched`; arrow ignores them).

## 4. The step

The `join` step (`sv-pipeline.js`) gains two optional fields:

```js
{ kind: 'join', key, table, right, type, by: [{left, right}],
  rule: null | {
    shape: 'between',  xCol, yFrom, yTo             // x date inside a y period
    shape: 'window',   xCol, yCol, from, to          // y date in [x + from, x + to] days
    shape: 'before',   xCol, yCol, inclusive         // nearest y on or before x
    shape: 'after',    xCol, yCol, inclusive         // nearest y on or after x
    shape: 'overlaps', xFrom, xTo, yFrom, yTo        // x period overlaps y period
  },
  strict: false }
```

- `x*` columns belong to `table` (left), `y*` columns to `right`.
- Columns must be Date, POSIXct or numeric (numeric covers study days such as `ADY`). Both sides of one
  comparison must be the same kind (Date with Date, date-time with date-time, numeric with numeric).
- `from` and `to` are integers in [-3650, 3650] with `from <= to`. Defaults: -7 and +7. They count days
  for Date and date-time columns, and the column's own unit for numeric columns (study days).
- `inclusive` defaults to `true` ("same day counts").
- All bounds are closed, as in dplyr.
- `before` / `after` allow only `left_join`, `inner_join`, `semi_join`, `anti_join`.
- New methods: `Pipeline.setJoinRule(id, rule | null)` and `Pipeline.setJoinStrict(id, bool)`, both
  undoable; `setJoinRule` with before/after on a right/full step switches the type to `left_join`.
- `describe()` adds the rule, e.g. `· lab_date within -7..+7 days of visit_date`,
  `· last lab_date on or before visit_date`, `· visit_date between start and end`,
  `· ae_start..ae_end overlaps start..end`.

## 5. Generated code

Keys come from the splines, e.g. `id`. In-memory examples (`dose`, `labs`, `ae` are right tables):

| Rule | Code |
|---|---|
| between | `dplyr::left_join(dose, by = dplyr::join_by(id, between(vdate, start, end)))` |
| window | `dplyr::mutate(.sv_lo = vdate - 7, .sv_hi = vdate + 7)`, then `dplyr::left_join(labs, by = dplyr::join_by(id, between(y$ldate, x$.sv_lo, x$.sv_hi)))`, then `dplyr::select(-.sv_lo, -.sv_hi)` |
| before | `dplyr::left_join(labs, by = dplyr::join_by(id, closest(vdate >= ldate)))` (`>` when `inclusive` is false) |
| after | `dplyr::left_join(labs, by = dplyr::join_by(id, closest(vdate <= ldate)))` (`<` when not inclusive) |
| overlaps | `dplyr::left_join(ae, by = dplyr::join_by(id, overlaps(xs, xe, ys, ye)))` |

- **Window offsets** are written by column kind and chain kind: Date and numeric use `vdate + n`
  (`vdate - 7` for a negative n); a date-time uses `as.difftime(n, units = "days")` in memory and
  `lubridate::days(n)` on duckdb (dbplyr turns it into an INTERVAL). `from = 0` writes the column alone.
- **Lazy chains (duckdb, arrow):** between, window and overlaps are written as above. An arrow side goes
  through `arrow::to_duckdb()` (wrapped in `dplyr::compute()`, as sub-project 1 does), because arrow has no
  inequality join. before/after are emulated:

  ```r
  dplyr::mutate(.sv_row = dplyr::row_number()) |>
    dplyr::left_join(labs, by = dplyr::join_by(id, vdate >= ldate)) |>
    dplyr::group_by(.sv_row) |>
    dplyr::filter(is.na(ldate) | ldate == max(ldate, na.rm = TRUE)) |>
    dplyr::ungroup() |>
    dplyr::select(-.sv_row)
  ```

  `after` uses `<=` and `min()`. `inner_join` drops the `is.na()` term. `semi_join` / `anti_join` need no
  emulation: the nearest match exists exactly when any match exists, so they use the inequality alone.
  Ties are kept, as `closest()` keeps them. (Checked in a probe: same rows as `closest()` in memory.)
- **Strict** (in-memory chains, toggle on) appends the arguments from the latest join check
  (`strict_args`, section 6): `relationship = "<one-to-one|one-to-many|many-to-one|many-to-many>"` and
  `unmatched = "error"` only when the join type would drop no rows (left: every `right` row matched;
  right: every `table` row matched; inner: both; full: never written, it drops nothing). No check yet, a
  "no matches" relationship, or a semi/anti join: nothing is written.
- Every generated form must `parse()`, with both `%>%` and `|>`.

## 6. The join check with a rule

**Signatures.** With `rule = NULL` each twin returns exactly what it returns today.

- `sv_join_diagnostics(x, y, by, sample_n = 5L, x_name = "x", y_name = "y", rule = NULL)` (R/diagnostics.R)
- `sv_lazy_join_diagnostics(..., rule = NULL)` (R/lazy.R), runs in duckdb, returns counts only
- `SideviewPipeline.joinDiagnostics(xCols, yCols, by, { rule, ... })` (sv-pipeline.js)

`rule` uses the step's field names (a list in R, an object in JS).

**What a match is.** A pair of rows is a match when the keys match (NA matches NA, as `na_matches = "na"`)
and the rule holds. For before/after only the nearest y row(s) per x row count; ties are kept.

**Fields.**
- From the matching pairs: `matched_x`, `matched_y`, `match_rate_x`, `match_rate_y`, `relationship`,
  `rows` (per join type), `unmatched_x`, `unmatched_y`.
- `rows` is `NA` for `right_join` and `full_join` under before/after.
- Key-only fields stay key-only: `distinct_x`, `distinct_y`, `distinct_matched`, `dup_keys_x`,
  `dup_keys_y`, `na_x`, `na_y`.
- New: `rule` (echoed), `rule_dropped_x` / `rule_dropped_y` (rows that match on the key but fail the rule),
  `strict_args` (named list / object `{relationship, unmatched}` with each element present only when Strict
  would write it; `NULL` for semi/anti joins). A row with NA in a rule column never passes the rule.
- Hints (trim, case, leading zeros) are measured with the rule applied.
- `sv_join_diagnostics_json()` carries the new fields; `print()` shows the rule and the dropped counts.

**How each twin computes it.**
- **R in memory:** dplyr runs the rule join on the key and rule columns plus row numbers, then counts the
  pairs. dplyr is the reference by definition.
- **duckdb:** the same join in SQL (the section 5 emulation for before/after), aggregated to counts.
- **JS:** groups `y` rows by key, then scans the rule inside each group (nearest per x row for
  before/after).

**Known difference.** The widget compares date-times as wall-clock text from the JSON, so a window across a
daylight-saving change can be off by an hour from R. Documented in `?sideview` and NEWS.

## 7. UI

**Join step row (Pipeline tab).**
- A **Date rule** button (inline SVG calendar icon) opens an inline row under the step.
  - Shape select: none, between, window, before, after, overlaps.
  - Column selects list only Date, date-time and numeric columns of the two tables, matched by kind.
  - Window: from/to number inputs (default -7, +7). Before/after: a "same day counts" checkbox.
  - Invalid input (not a whole number, outside [-3650, 3650], from > to, missing column) shows an inline
    message and disables **Apply**; the code doesn't change until the rule is valid.
  - **Apply** (or Ctrl+Enter) calls `setJoinRule`; **Esc** closes the row; "none" removes the rule.
- The step label shows the rule (section 4).
- A **Strict** checkbox on the step calls `setJoinStrict`. On a lazy chain it is disabled with the title
  "Strict runs in R only: duckdb rejects relationship and unmatched, and arrow ignores them".
- While before/after is set, `right` and `full` are disabled in the join type select; applying before/after
  to a right/full step switches it to left and shows a toast saying so.

**Join check panel (Discrepancy tab).**
- The title adds the rule, e.g. "rule: lab_date within -7..+7 days of visit_date".
- A row "Dropped by the rule: X visit rows / Y labs rows", read as "X rows match on the key but not the rule".
- The rows table shows "-" for `NA` counts, with the note "Unknown for right and full joins with a nearest
  match".
- A line with what Strict would write (`relationship = "one-to-many", unmatched = "error"`) or why
  `unmatched` was left out ("12 labs rows would be dropped").

**Wire.** `join_diagnostics_request` gains an optional `rule`; the reply `sideview_join_diagnostics`
carries the new fields. The widget computes in the browser. CLAUDE.md lists both changes.

All new controls follow the existing rules: escaped text, `CSS.escape` in selectors, `--sv-*` tokens,
inline SVG icons only, listeners removed in `destroy()`, and a new shortcut (Ctrl+Enter in the rule row)
added to the `?` dialog.

## 8. Errors

- A rule on a column whose kind changed (e.g. a reloaded table) is shown as invalid in the step; the code
  writes the join without the rule and the step shows "Rule needs fixing".
- A join check error under a rule shows "Join check unavailable" with the message, as today.
- A Strict join that fails in **Run in R** shows dplyr's error in the toast, which is the point of Strict.

## 9. State

- `rule` and `strict` are optional step fields in the workspace state; the schema stays v0.3.0.
- Old states load unchanged. A state with a rule opened in sideview 0.3.x drops the rule silently; NEWS says
  so. (The version guard is sub-project 4.)

## 10. Testing

- **Code:** node tests for every shape x both pipes x in-memory / duckdb / arrow chains, Date, date-time and
  numeric columns, negative / zero / positive offsets, inclusive on and off; every result `parse()`s.
- **Run:** R tests run the generated code on data frames, duckdb and arrow, each after a `gc()`, and compare
  with `dplyr::join_by()` on data frames (`expect_equal`, tolerance 1e-12, rows sorted).
- **Strict:** the written arguments match the check; a left join with an unmatched `right` row gets no
  `unmatched`; a changed table makes **Run in R** fail with dplyr's error.
- **Check parity:** random seeds over the four shapes (plus window offsets) and each column kind, with ties
  and NA dates: R and JS give the same fields; row counts equal dplyr; lazy equals in-memory on duckdb and
  arrow fixtures (tolerance 1e-12).
- **UI:** mock-DOM scenarios for the rule row (validation, Apply, Esc, undo, type switch); a real-browser
  test (chromote, real input) that sets a window rule and checks the code drawer and the panel; a check in
  RStudio (gadget) recorded in MEMORY.md.

## 11. Files touched

- `inst/www/sv-pipeline.js`: step fields, `setJoinRule`, `setJoinStrict`, `describe`, join code, the rule
  in `joinDiagnostics()`.
- `inst/www/sideview.js`, `inst/www/sideview.css`: rule row, Strict checkbox, panel additions.
- `R/diagnostics.R`, `R/lazy.R`: `rule` in both R twins.
- `R/app_server.R`: pass `rule` through `join_diagnostics_request`.
- `DESCRIPTION`: `dplyr (>= 1.1.0)`.
- Tests: `test-pipeline.R`, `test-diagnostics.R`, `test-lazy.R`, `test-layout-browser.R`, `gui-test-runner.js`.
- Docs: NEWS.md, roxygen (`sv_join_diagnostics(rule =)`, `?sideview` known differences), CLAUDE.md (twin
  rule, wire fields), the tour, a README bullet, MEMORY.md.
