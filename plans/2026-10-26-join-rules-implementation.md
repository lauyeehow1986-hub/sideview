# Join rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A join step can carry one date rule (between, window, before, after, overlaps) and a Strict toggle. The generated
`join_by()` code runs on data frames, duckdb tables and arrow tables, and the three join-check twins apply the rule.

**Architecture:** The step model and every line of generated code live in `inst/www/sv-pipeline.js`, which is pure JS and
the single source of code. The rule check has three twins: JS `joinDiagnostics()`, R `sv_join_diagnostics()`, and the
duckdb `sv_lazy_join_diagnostics()`. They share field names and are held equal by parity tests. The engine
(`sideview.js`) edits the rule inline in the join step and feeds check results back to the pipeline, so Strict can write
`relationship` / `unmatched`.

**Tech Stack:** R 4.5.2, dplyr >= 1.1.0 (`join_by`), dbplyr/duckdb/arrow (Suggests), Node for the pipeline tests, testthat 3,
shinytest2/chromote for browser tests.

**Spec:** `plans/2026-10-26-join-rules-design.md`

## Global Constraints

- R: `"/c/Program Files/R/R-4.5.2/bin/Rscript.exe"`. Browser tests need `NOT_CRAN=true`. Never run two browser runs at
  once: they share Chrome's port.
- `DESCRIPTION`: `dplyr (>= 1.1.0)` under Imports. arrow, duckdb, dbplyr and DBI stay in Suggests behind `requireNamespace()` /
  `skip_if_not_installed()`.
- Rule columns are Date, POSIXct (shown as "date-time") or numeric. Both sides of one comparison must be the same kind.
- Window `from` / `to` are whole numbers in [-3650, 3650] with `from <= to`. The defaults are -7 and +7, and `inclusive`
  defaults to `true`.
- before/after work only with `left_join`, `inner_join`, `semi_join` and `anti_join`.
- Generated code: every form must `parse()` with both `%>%` and `|>`. Columns go through `ident()` (backticks).
  Helper columns are named `.sv_lo`, `.sv_hi`, `.sv_row` and `.sv_yd`, and none of them is left in the output.
- Twin rule: R in memory, duckdb and JS give the same fields for the same data. Lazy equals in-memory at
  `tolerance = 1e-12`. Change all three together, and record the twin and the wire fields in CLAUDE.md.
- Lazy tables are never collected (only counts and samples come back). Arrow joins with a rule run in duckdb through
  `dplyr::compute(arrow::to_duckdb(...))`.
- UI: escape text before `innerHTML`, use `CSS.escape` in selectors, `--sv-*` tokens only, inline SVG icons (no emoji), and
  remove every global listener in `destroy()`. Add Ctrl+Enter in the rule row to the `?` list.
- Synthetic data only. Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No push, merge or PR
  without the user's yes.

## Rulings on the spec (amendments made while planning)

These come from a probe (`dplyr 1.2.1`) and from gaps the spec leaves open. Each one is binding for the tasks below, and
the user is asked to confirm it at plan review.

- **R1. Missing values in rule joins.** dplyr's default `na_matches = "na"` makes `NA >= NA`, `between(NA, NA, NA)` and
  `overlaps` on NAs match. Duckdb SQL never matches NULL in an inequality. To get one answer in every engine, and the
  spec's "a row with NA in a rule column never passes the rule", **every join that has a rule writes
  `na_matches = "never"`**. Under a rule, a missing *key* also matches nothing. The check uses the same semantics for
  its pair fields, while the key-only fields (`na_x`, `na_y`, `distinct_*`, `dup_keys_*`) keep today's meaning. With a
  rule, the missing-key warning reads: `Missing keys (N in x, M in y): with a date rule they match nothing (na_matches = "never").`
- **R2. `strict_args` is per join type**, like `rows`: `{left_join: {...}, inner_join: {...}, right_join: {...}, full_join: {...}}`.
  An entry is absent when Strict would write nothing for that type: semi/anti joins, "no matches", and right/full under
  before/after. `full_join` entries never have `unmatched`. Strict also works on key-only joins, so `strict_args` is
  added to **every** result, with or without a rule. `rule`, `rule_dropped_x` and `rule_dropped_y` are present only
  when a rule is given. Every other field is unchanged when `rule = NULL`.
- **R3. Emulated nearest match copies the y column to `.sv_yd`** before the join, so a y date with the same name as an x
  column (`date` in both) still works. The output columns then match `closest()` (`d.x`, `d.y`).
- **R4. Unknown row counts.** In R, `rows$right_join` / `rows$full_join` under before/after are `NA_real_`.
  `sv_join_diagnostics_json()` drops NA entries from `rows`, and the JS twin leaves those keys out. The panel shows "-"
  for a missing key.
- **R5. Column kinds reach the pipeline through `setTables(meta)`.** `meta[name].kinds = {<col>: <keyKind>}` is filled
  by the engine from the card's `colTypes`. A rule column whose kind is missing or wrong makes the rule invalid.
- **R6. Arrow and data-frame chains with a rule all move into duckdb** (see the matrix in Task 3). Arrow has no
  inequality join.

## Review Focus

1. **The same column name on both sides of a rule** (`date` in both tables). The code should run and give dplyr's
   `date.x` / `date.y`. Tests: Task 2 (in memory) and Task 3 (emulation).
2. **Missing dates and missing keys in rule columns.** Every engine should give the same rows and the same check, and
   NA should never match. Tests: Tasks 2, 3, 4, 5 and 6.
3. **Non-syntactic names** (`visit date`) in rule slots and keys. These need backticks inside `join_by()`, including the
   `x$` / `y$` forms. Tests: Task 2 (parse and run) and Task 3.
4. **A table reloaded so a rule column changed kind or vanished.** The step should say "Rule needs fixing" and the code
   should keep the key join. Tests: Task 1 (model) and Task 9 (UI).
5. **Ties in a nearest match** (two labs on the same date). The tie should be kept in every engine and counted
   one-to-many. Tests: Tasks 3 and 5.

---

### Task 1: The rule in the step model

**Files:**
- Modify: `inst/www/sv-pipeline.js` (`setTables`, `describe`, the new functions, `api`)
- Create: `tests/testthat/test-join-rules.R`

**Interfaces:**
- Produces:
  - `P.RULE_SHAPES = ['between','window','before','after','overlaps']`.
  - `P.ruleSlots(shape) -> [{slot, side:'x'|'y'}]`:
    - between: `xCol` x, `yFrom` y, `yTo` y.
    - window: `xCol`, `yCol`.
    - before / after: `xCol`, `yCol`.
    - overlaps: `xFrom` x, `xTo` x, `yFrom` y, `yTo` y.
  - `P.ruleProblem(rule, kindsX, kindsY, type) -> null | string`. It returns the first problem, checked in this order,
    with these exact messages:
    1. unknown shape: `Unknown date rule.`
    2. empty slot: `Pick a column for every slot.`
    3. kind missing or not Date / date-time / numeric: `<col> is not a date, date-time or number.`
    4. kinds differ: `<a> is <kindA> but <b> is <kindB>: both sides of a date rule need the same kind.`
    5. window bound not an integer in range: `Window bounds must be whole numbers from -3650 to 3650.`
    6. `from > to`: `The window start must not be after its end.`
    7. before/after with right/full: `A nearest-match rule works with left, inner, semi and anti joins only.`
  - `P.ruleLabel(rule, kindX) -> string`, with no leading `· `. See the label table below.
  - `Pipeline.prototype.setJoinRule(id, rule|null) -> bool` and `Pipeline.prototype.setJoinStrict(id, bool) -> bool`.
    Both are undoable through `change()`. The rule is stored normalized: window `from`/`to` as numbers, `inclusive` as a
    boolean.
  - `Pipeline.prototype.joinRuleProblem(step) -> null | string`: `ruleProblem` with the kinds from `this.tables`.
  - `Pipeline.prototype.joinSig(step) -> string`: `JSON.stringify([table, right, by pairs, rule || null])`. This replaces
    the engine's `joinDiagSig`, which moves here.
  - `Pipeline.prototype.setJoinCheck(sig, strictArgs|null)` and `clearJoinChecks()`. These are not state: no undo, not in
    `toJSON()`. They emit `'checks'` only when something changed.

Labels (`describe()` appends `' · ' + label` to the join text, or `' · Rule needs fixing'` when `joinRuleProblem`
is not null):

| rule | label |
|---|---|
| window, Date/date-time | `lab_date within -7..+7 days of visit_date` (signed offsets, `0` unsigned) |
| window, numeric | `ady within -7..+7 of vady` |
| before | `last lab_date on or before visit_date` / `last lab_date before visit_date` (inclusive false) |
| after | `first lab_date on or after visit_date` / `first lab_date after visit_date` |
| between | `visit_date between start and end` |
| overlaps | `ae_start..ae_end overlaps start..end` |

- [ ] **Step 1: Write the failing tests** in `test-join-rules.R`, using `run_pipeline_js()`:
  - `"setJoinRule stores a rule, describes it, and undoes"`:
    1. `addJoinKey('visits','labs','id','id')`, then `setTables` with kinds `{visit_date:'Date'}` and `{lab_date:'Date'}`.
    2. `setJoinRule(id, {shape:'window', xCol:'visit_date', yCol:'lab_date', from:-7, to:7})`.
    3. Expect `describe(step)` to be `'left join labs on id · lab_date within -7..+7 days of visit_date'`.
    4. After `undo()`, expect `step.rule` to be undefined or null.
  - `"before/after switch a right join to left"`: `type:'right_join'` plus `setJoinRule(... shape:'before' ...)` gives
    `type === 'left_join'`. A single undo restores both the right join and no rule.
  - `"ruleProblem gives each message"`: one call per numbered message above, with `expect_identical` on each string.
    Include `from:'7.5'`, `from:-3651`, `from:8, to:7`, and kinds `{a:'Date'}` vs `{b:'date-time'}`.
  - `"a rule on a changed column needs fixing"`: set the rule, then `setTables` with `lab_date` now `'character'`.
    `describe` ends in `· Rule needs fixing`.
  - `"setJoinStrict is undoable and joinSig includes the rule"`: the sig changes when the rule changes. `setJoinCheck`
    does not touch `undoStack.length`.
  - `"rule and strict survive the workspace state"` (spec §9): `toJSON()` then a new pipeline's load gives the same
    `rule` and `strict`. A v0.3.0 state without them loads unchanged, and `sv_state_from_json(sv_state_json(s))` in R
    keeps a one-step rule (numbers, `inclusive`) intact.
- [ ] **Step 2: Run them and see them fail.**
  Run: `Rscript -e "devtools::load_all(); testthat::test_file('tests/testthat/test-join-rules.R')"`
  Expected: FAIL (`setJoinRule is not a function`).
- [ ] **Step 3: Implement** the Interfaces block in `sv-pipeline.js`:
  - `setTables` keeps `kinds` (an object of strings, defaulting to `{}`), and its no-op comparison includes kinds.
  - Kinds use the existing `keyKind()` names: `'Date'`, `'date-time'`, `'numeric'`.
  - Export everything listed under Produces on `api`.
- [ ] **Step 4: Run the tests.** Run: same command. Expected: PASS. Also run `node --check inst/www/sv-pipeline.js`.
- [ ] **Step 5: Commit.** `git commit -m "feat(pipeline): join steps carry a date rule and a Strict flag"`

### Task 2: In-memory join code with a rule

**Files:**
- Modify: `inst/www/sv-pipeline.js` (`verbs()` join case, `joinBy` gets a `join_by()` sibling)
- Modify: `DESCRIPTION` (`dplyr (>= 1.1.0)`)
- Test: `tests/testthat/test-join-rules.R`

**Interfaces:**
- Consumes: Task 1 (`step.rule`, `joinRuleProblem`, `tables[..].kinds`).
- Produces:
  - `joinByCall(pairs, ruleExpr|null) -> 'dplyr::join_by(id, site == site_code, <rule>)'` (internal). Equal-named pairs
    are written bare, others as `l == r`. Every name goes through `ident()`.
  - `verbs(step, refFor, ctx)`, extended. `ctx.kindOf(col) -> kind`, because a window needs the x column's kind.
    `ctx.kind` is the chain backend (`null` in memory).

The in-memory forms, with `.sv_lo`/`.sv_hi` mutate lines before the join and a select after it:

| shape | lines |
|---|---|
| between | `dplyr::left_join(R, by = dplyr::join_by(id, between(vdate, start, end)), na_matches = "never")` |
| window | `dplyr::mutate(.sv_lo = vdate - 7, .sv_hi = vdate + 7)`; `dplyr::left_join(R, by = dplyr::join_by(id, between(y$ldate, x$.sv_lo, x$.sv_hi)), na_matches = "never")`; `dplyr::select(-.sv_lo, -.sv_hi)` |
| before | `... dplyr::join_by(id, closest(vdate >= ldate)) ...` (`>` when not inclusive) |
| after | `... closest(vdate <= ldate) ...` (`<` when not inclusive) |
| overlaps | `... dplyr::join_by(id, overlaps(xs, xe, ys, ye)) ...` |

- **Offsets:**
  - Date and numeric: `vdate + 7` / `vdate - 7`.
  - date-time: `vdate + as.difftime(7, units = "days")` / `vdate - as.difftime(7, units = "days")`.
  - `0`: the column alone (`.sv_lo = vdate`).
- **No rule, or a rule with a problem:** the existing `by = c(...)` form, unchanged. Existing pipeline tests must still
  pass byte for byte.

- [ ] **Step 1: Write the failing tests**:
  - `"rule joins write join_by and parse"`: loop over 5 shapes × `%>%`/`|>` × kinds Date/date-time/numeric (where the
    shape allows) × offsets `(-7,7)`, `(0,3)`, `(-10,-2)` × inclusive TRUE/FALSE.
    - Every `compose()` passes `expect_parses()`.
    - Spot-check with `expect_match(fixed = TRUE)` for each table row above, plus
      `vdate + as.difftime(7, units = "days")` and `.sv_lo = vdate,`.
  - `"rule joins run like join_by on data frames"`: a synthetic fixture.
    - `visits(id, vdate Date, vtime POSIXct UTC, vday int)` with an NA vdate.
    - `labs(id, ldate, ltime, lday)` with a tie (two labs on one date), an NA date and an NA id.
    - `dose(id, start, end)`.
    - For each shape × left/inner (plus semi/anti for before/after), `eval(parse(text = compose()))` equals a
      hand-written `dplyr::*_join(..., by = join_by(...), na_matches = "never")`, compared after `dplyr::arrange(dplyr::across(dplyr::everything()))`.
  - `"same-named and non-syntactic rule columns run"` (Review Focus 1 and 3):
    - `date` in both tables with before: the output has `date.x` and `date.y`.
    - A column named `visit date`: it parses and runs.
  - `"an invalid rule falls back to the key join"`: the kind changed, so the code equals the no-rule code.
- [ ] **Step 2: Run them and see them fail.** Expected: FAIL (no `join_by` in the code).
- [ ] **Step 3: Implement** the forms in `verbs()`, and pass `ctx.kindOf` from `compose()`'s `render()` (from
  `self.tables[t].kinds`). Bump DESCRIPTION.
- [ ] **Step 4: Run the tests**, then `Rscript -e "devtools::test(filter = 'pipeline')"`. Expected: PASS, with the old
  tests unchanged.
- [ ] **Step 5: Commit.** `git commit -m "feat(pipeline): date-window and nearest-match joins via join_by()"`

### Task 3: Rule joins on duckdb and arrow chains

**Files:**
- Modify: `inst/www/sv-pipeline.js` (`compose()` `render()` join branch, `verbs()` lazy forms)
- Test: `tests/testthat/test-join-rules.R`

**Interfaces:**
- Consumes: Task 2 forms.
- Produces: the lazy forms. The chain matrix applies **only when the step has a valid rule**. Otherwise today's code is
  unchanged.

| left chain × right | what is written |
|---|---|
| duckdb × df | as today (`copy = TRUE`) |
| duckdb × duckdb, duckdb × arrow, arrow × duckdb, df × duckdb | as today |
| arrow × df | `wrapHead('dplyr::compute(arrow::to_duckdb(', '))')`, kind `duckdb`, `con = null`, `copy = TRUE` |
| arrow × arrow | as arrow × df for the left; right `dplyr::compute(arrow::to_duckdb(<ref>))` |
| df × arrow | `wrapHead('dplyr::compute(arrow::to_duckdb(arrow::arrow_table(', ')))')`; right `dplyr::compute(arrow::to_duckdb(<ref>))` |

Without `con =`, both sides land on arrow's default duckdb connection, so they share one connection.

**Lazy forms (kind `duckdb` at the join):**
- between, window and overlaps are written as in memory. A date-time offset is written `lubridate::days(7)` (dbplyr
  translates it to an INTERVAL; lubridate itself is not needed at run time).
- before/after with left or inner:
  ```
  dplyr::mutate(.sv_row = dplyr::row_number())
  dplyr::left_join(dplyr::mutate(R, .sv_yd = ldate), by = dplyr::join_by(id, vdate >= .sv_yd), na_matches = "never"[, copy = TRUE])
  dplyr::group_by(.sv_row)
  dplyr::filter(is.na(.sv_yd) | .sv_yd == max(.sv_yd, na.rm = TRUE))
  dplyr::ungroup()
  dplyr::select(-.sv_row, -.sv_yd)
  ```
  - after: `<=` and `min()`. Not inclusive: `>` / `<`.
  - inner_join: `inner_join`, and the filter drops `is.na(.sv_yd) | `.
- before/after with semi or anti: `dplyr::semi_join(R, by = dplyr::join_by(id, vdate >= ldate), na_matches = "never")`,
  with no emulation.

- [ ] **Step 1: Write the failing tests**:
  - `"lazy rule joins parse"`: the Task 2 loop again with `setTables` marking the left and/or right as `duckdb` / `arrow`
    in every matrix row. Every result parses. Expect `.sv_row` for before on duckdb, and `lubridate::days(7)` for a
    duckdb date-time window.
  - `"lazy rule joins return the in-memory rows"`: `skip_if_not_installed("duckdb")`, `("arrow")`, `("dbplyr")`.
    - The Task 2 fixture is registered in duckdb (`dplyr::copy_to`) and as arrow tables (date-time with `tz = "UTC"`).
    - Each matrix row × shape × left/inner/semi/anti runs `gc()`, then the code, then `dplyr::collect()`.
    - The result equals the data-frame `join_by` reference (`expect_equal(tolerance = 1e-12)`, rows and columns
      sorted, POSIXct compared as numeric seconds).
    - The tie row appears twice (Review Focus 5). The same-named `date` case works on duckdb (Review Focus 1).
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement** the matrix in `render()` and the lazy forms in `verbs()`.
- [ ] **Step 4: Run** `test-join-rules.R`, then `Rscript -e "devtools::test(filter = 'lazy')"` (no regressions). Expected:
  PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(pipeline): rule joins on duckdb and arrow, nearest match emulated"`

### Task 4: R in-memory check with a rule, and strict_args

**Files:**
- Create: `R/join_rules.R`
- Modify: `R/diagnostics.R` (`sv_join_diagnostics`, `print`, `sv_join_warnings`, `sv_join_diagnostics_json`, roxygen)
- Test: `tests/testthat/test-diagnostics.R`

**Interfaces:**
- Produces:
  - `sv_join_diagnostics(x, y, by, sample_n = 5L, x_name = "x", y_name = "y", rule = NULL)`, where `rule` is a list
    with the step's field names.
  - `sv_join_rule_problem(rule, kinds_x, kinds_y, type = "left_join") -> NULL | character(1)`. These are the same
    messages, in the same order, as `P.ruleProblem`. `sv_join_diagnostics()` stops with this message when it is not
    NULL (`type` is not checked there).
  - `sv_join_rule_label(rule, kind_x) -> character(1)`, the same strings as `P.ruleLabel`.
  - `sv_join_rule_pairs(x, y, by_x, by_y, rule, fn = NULL) -> data.frame(.rx, .ry)`:
    - Each key becomes one string column (`sv_join_keys`, `fn` applied), set to `NA` when any part is NA.
    - It then runs `dplyr::inner_join(..., na_matches = "never", relationship = "many-to-many")` on that key and the
      rule columns (window bounds computed in R: `x + from`; date-time `x + from * 86400`), using `closest()` for
      before/after.
  - `sv_join_strict_args(core, n_x, n_y, rule) -> named list` per Ruling R2:
    - `relationship` is always written when the relationship is not "no matches".
    - `unmatched = "error"` is written for left when `matched_y == n_y`, for right when `matched_x == n_x`, and for
      inner when both hold. It is never written for full.
  - New fields:
    - `strict_args`, always.
    - With a rule: `rule` (echoed), and `rule_dropped_x` / `rule_dropped_y`. Each counts rows with a key partner
      (NA keys excluded, as R1) and no rule pair.
    - `matched_*`, `match_rate_*`, `relationship`, `rows`, `unmatched_*` and hints come from the pairs.
    - `rows$right_join` / `full_join` are `NA_real_` under before/after.

- [ ] **Step 1: Write the failing tests** in `test-diagnostics.R`:
  - `"a rule check counts like dplyr"`: for each shape (window offsets included) × Date/date-time/numeric over 5 random
    seeds with ties and NA dates and keys:
    - `d$rows$left_join == nrow(dplyr::left_join(x, y, by = <join_by>, na_matches = "never"))`, and likewise for
      inner, semi and anti (right and full only for between/window/overlaps).
    - `matched_x == dplyr::n_distinct` of the x rows in the inner join.
  - `"rule fields and strict_args"`:
    - A left join with an unmatched labs row has no `unmatched` in `strict_args$left_join`.
    - A fully matched left join has `list(relationship = "one-to-many", unmatched = "error")`.
    - semi/anti and "no matches" leave the entry out.
    - Under before, `is.na(d$rows$right_join)` holds.
    - `rule_dropped_x` equals the hand count.
  - `"no rule changes nothing but adds strict_args"`: compare an existing fixture's result minus `strict_args` with
    `expect_identical` to the fields the existing tests check.
  - `"print and json show the rule"`:
    - `print` has `rule: lab_date within -7..+7 days of visit_date` and `dropped by the rule:`.
    - The json has no `right_join` in `rows` under before.
  - `"a bad rule stops with the shared message"`: `expect_error(..., "Window bounds must be whole numbers")`.
  - The missing-key warning text under a rule (R1).
- [ ] **Step 2: Run them and see them fail.** Run: `Rscript -e "devtools::test(filter = 'diagnostics')"`.
- [ ] **Step 3: Implement** `R/join_rules.R` and wire it into `sv_join_diagnostics()`. Hints call
  `sv_join_rule_pairs(..., fn = fixes[[nm]]$fn)`. Document `rule =` and the new fields in roxygen, then run
  `devtools::document()`.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(diagnostics): the join check applies a date rule and reports strict args"`

### Task 5: The JS check twin with a rule

**Files:**
- Modify: `inst/www/sv-pipeline.js` (`joinDiagnostics`, new `ruleValue`, `rulePairs`, `strictArgs`)
- Test: `tests/testthat/test-diagnostics.R`

**Interfaces:**
- Consumes: Task 1 (`ruleProblem`, `ruleLabel`) and Task 4 field definitions.
- Produces:
  - `P.joinDiagnostics(xCols, yCols, by, {rule, sampleN, xName, yName, xTypes, yTypes})`. With a rule, `xCols` /
    `yCols` must hold the rule columns too.
  - `P.strictArgs(d, rule)`.
  - `ruleValue(v, kind) -> number | NaN` (internal):
    - Date `'YYYY-MM-DD'` becomes days since 1970-01-01 UTC.
    - date-time `'YYYY-MM-DD[ T]HH:MM[:SS[.fff]]'` becomes ms since the epoch, read as UTC wall-clock (the documented
      DST difference).
    - numeric stays as it is.
    - Missing or unparseable gives NaN, which never matches.
  - Offsets are scaled: Date 1, date-time 86 400 000, numeric 1.
- How it computes: group the y rows by key (NA keys excluded under a rule), then scan each group per x row. For
  before/after, keep only the y rows at the nearest value (all ties). Then compute the Task 4 fields from the pairs.
  `rows` leaves out `right_join` / `full_join` under before/after (R4).

- [ ] **Step 1: Write the failing test** `"the JS twin gives the same rule check as R"`:
  - Use the Task 4 seeds and shapes, sending Dates and POSIXct as `format()` text (UTC fixture).
  - Expect equal values for: `matched_*`, `match_rate_*`, `rule_dropped_*`, `relationship`, the non-NA `rows`,
    `strict_args`, setequal `unmatched_*`, the hint fixes and `warnings`.
  - Add a label parity check: `sv_join_rule_label()` equals `P.ruleLabel()` for each shape.
  - Add a problem-message parity check: `sv_join_rule_problem()` equals `P.ruleProblem()` for each bad case from Task 1.
- [ ] **Step 2: Run it and see it fail.**
- [ ] **Step 3: Implement.** Keep the no-rule path byte-identical apart from `strict_args`, and extend the existing
  parity test to compare `strict_args`.
- [ ] **Step 4: Run** `devtools::test(filter = 'diagnostics')`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(pipeline): the browser join check applies a date rule"`

### Task 6: The duckdb check twin with a rule

**Files:**
- Modify: `R/lazy.R` (`sv_lazy_join_diagnostics`, `sv_lazy_place` call with the rule columns, new `sv_lazy_rule_pairs`)
- Test: `tests/testthat/test-lazy.R`

**Interfaces:**
- Consumes:
  - Task 3: the emulation SQL shape.
  - Task 4: `sv_join_rule_problem`, `sv_join_strict_args`, `sv_join_counts_from`, `sv_join_warnings`.
- Produces:
  - `sv_lazy_join_diagnostics(x, y, by, sample_n = 5L, x_name = "x", y_name = "y", con_env = sv_lazy_env(), rule = NULL)`.
  - The rule columns are placed with the keys (`cols_x` / `cols_y`).
  - `sv_lazy_rule_pairs(side_x, side_y, nk, rule)` is a lazy tbl of `(.rx, .ry)`. It does the inner join in duckdb with
    `na_matches = "never"`, and for before/after a grouped filter on `max()` / `min()` (`>` / `<` when not inclusive).
  - One aggregate (`n_distinct(.rx)`, `n_distinct(.ry)`, max count per `.rx` and per `.ry`, `n()`) feeds the Task 4
    fields. An unmatched sample is an anti-join of the x keys against the pairs, limited to `sample_n`.
  - A date-time window on duckdb compares instants: `x + from * 86400` seconds as an INTERVAL via `lubridate::days()`
    translation.

- [ ] **Step 1: Write the failing test** `"the lazy rule check equals the in-memory one"`:
  - Use the Task 4 fixture as duckdb tables and as arrow tables (date-time `tz = "UTC"`), and run `gc()` before each.
  - For each shape and kind, `expect_equal(lazy, in_memory, tolerance = 1e-12)` on the whole object, with
    `unmatched_*` sorted.
  - Add the NA-date and tie rows (Review Focus 2 and 5).
- [ ] **Step 2: Run it and see it fail.** Run: `NOT_CRAN=true Rscript -e "devtools::test(filter = 'lazy')"`.
- [ ] **Step 3: Implement.** Hints keep today's rule: only character keys change, measured with the rule applied.
- [ ] **Step 4: Run** `test-lazy.R` and `test-diagnostics.R`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(lazy): the duckdb join check applies a date rule"`

### Task 7: Strict in the generated code

**Files:**
- Modify: `inst/www/sv-pipeline.js` (`verbs()` join case, `compose()` passes the check)
- Test: `tests/testthat/test-join-rules.R`

**Interfaces:**
- Consumes:
  - Task 1: `setJoinCheck(sig, strictArgs)` and `joinSig`.
  - Task 4/5: `strict_args`.
- Produces: when `step.strict` is true, the chain is in memory at the join (`ctx.kind == null`), and
  `this.checks[joinSig(step)][step.type]` exists, the join call gets `, relationship = "<rel>"` and, when present,
  `, unmatched = "error"`, written after `na_matches` and before `copy`. Otherwise the code is unchanged.

- [ ] **Step 1: Write the failing tests**:
  - `"strict writes the checked arguments"`:
    1. Compute `strict_args` with R `sv_join_diagnostics()` on the fixture.
    2. Pass it in with `setJoinCheck`, then `setJoinStrict(id, true)`.
    3. The code contains `relationship = "one-to-many"`, and `unmatched = "error"` only for the fully matched case. It
       parses with both pipes.
    4. Strict on a duckdb chain writes neither argument.
  - `"a strict join fails when the data change"`: evaluate the strict code against a copy of `labs` with one extra
    duplicate. `expect_error(..., "relationship|many")` from dplyr.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `test-join-rules.R`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(pipeline): Strict writes relationship and unmatched from the join check"`

### Task 8: Wire and engine plumbing

**Files:**
- Modify: `R/app_server.R` (`join_diagnostics_request` observer)
- Modify: `inst/www/sideview.js`:
  - `syncTableMeta` adds `kinds` from `vt.colTypes` through `keyKind`.
  - `joinDiagFor` uses `pipeline.joinSig` and puts `rule` in the request.
  - `localJoinDiagnostics` fetches the rule columns and passes `rule`.
  - `onJoinDiagnostics` calls `pipeline.setJoinCheck(data.id, data.strict_args || null)`.
  - When cards are replaced, `clearJoinChecks()` runs alongside the `joinDiag` reset.
- Modify: `CLAUDE.md` (the wire list: `join_diagnostics_request` gains `rule`, and the reply fields; the twin rule names
  the rule check)
- Test: `tests/testthat/test-diagnostics.R`

**Interfaces:**
- Consumes: Tasks 4–6 signatures.
- Produces:
  - The request becomes `{id, left, right, by:[{left,right}], rule?}`.
  - The server converts `rule` from a Shiny list. Numbers come as doubles and `inclusive` as a logical. The rule
    columns are added to the missing-column check, and the server calls the R or lazy twin with `rule =`.
  - The reply has the new fields through `sv_join_diagnostics_json()`.

- [ ] **Step 1: Write the failing tests** (testServer, as in the existing `"the server answers join_diagnostics_request"`):
  - A request with a window `rule` answers with `rule_dropped_x` and `strict_args$left_join$relationship`.
  - A request naming a missing rule column answers `error = "Not in labs: nope"`.
  - A lazy duckdb card gives the same reply as the data frame.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement**, and `node --check inst/www/sideview.js`.
- [ ] **Step 4: Run** `devtools::test(filter = 'diagnostics|app')`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(gadget): join checks carry the date rule over the wire"`

### Task 9: The rule row and the Strict checkbox

**Files:**
- Modify: `inst/www/sideview.js`:
  - `renderPipeline` join `<li>`.
  - The delegated click/change/keydown handlers next to the `.sideview-step-jointype` handler.
  - The `SHORTCUTS` entry `'Add the step in a builder tab, or apply a date rule'` for Ctrl+Enter.
- Modify: `inst/www/sideview.css` (rule row layout under `.sideview-container`, `--sv-*` tokens)
- Test: `tests/testthat/gui-test-runner.js` (new `scenario8`), and its check in `tests/testthat/test-computer-use-gui.R`

**Interfaces:**
- Consumes: Task 1 (`ruleSlots`, `ruleProblem`, `ruleLabel`, `setJoinRule`, `setJoinStrict`, `joinRuleProblem`).
- Produces this DOM inside the join step `<li>`:
  - `button.sideview-step-rule[data-step-action="rule"]` with an inline SVG calendar and `aria-label="Date rule"`.
  - `input.sideview-step-strict[type=checkbox]` with the label "Strict". It is disabled on a lazy chain, with the exact
    title `Strict runs in R only: duckdb rejects relationship and unmatched, and arrow ignores them`.
  - With the row open (`engine.ruleDraft = {stepId, rule}`), `div.sideview-rule-row` holds:
    - `select.sideview-rule-shape`: none, between, window, before, after, overlaps.
    - `select.sideview-rule-col[data-slot]`: only Date, date-time and numeric columns. Once an x slot is chosen, the y
      lists show only that kind.
    - `input.sideview-rule-from` / `-to` (`type=number step=1 min=-3650 max=3650`).
    - `input.sideview-rule-inclusive` ("same day counts").
    - `span.sideview-rule-msg[role=alert]`.
    - `button.sideview-rule-apply`, disabled while `ruleProblem` is not null.
    - `button.sideview-rule-cancel`.
- Behaviour:
  - Apply or Ctrl+Enter calls `setJoinRule`; "none" with Apply calls `setJoinRule(id, null)`.
  - Esc closes the row and keeps the code.
  - Under before/after, `right_join` / `full_join` options are disabled in the type select.
  - Applying before/after to a right/full step shows the info toast
    `Nearest-match rules need a left, inner, semi or anti join: switched to left join.`
  - A step whose rule has a problem shows the text `Rule needs fixing` (class `is-invalid`) on the rule button's label.

- [ ] **Step 1: Write the failing mock-DOM scenario** `scenario8`:
  1. Open the rule row and pick window.
  2. Set from = 8 and to = 7: Apply is disabled and the message is `The window start must not be after its end.`
  3. Fix it and Apply: the drawer code contains `.sv_lo`.
  4. Ctrl+Z: the rule is gone.
  5. Esc closes the row.
  6. Before on a right join switches the type to left and raises the toast.
  7. Strict toggles `step.strict`.
  8. The kind of a rule column changes (re-sync the tables): the step shows `Rule needs fixing`.
  9. The `?` list has the new Ctrl+Enter text.
- [ ] **Step 2: Run** `node tests/testthat/gui-test-runner.js` (or the R test wrapper). Expected: scenario8 FAIL.
- [ ] **Step 3: Implement.** Remove any new global listener in `destroy()`.
- [ ] **Step 4: Run** the runner and `node --check inst/www/sideview.js`. Expected: PASS, with the earlier scenarios
  unchanged.
- [ ] **Step 5: Commit.** `git commit -m "feat(ui): edit a join's date rule inline; Strict toggle"`

### Task 10: The join check panel shows the rule

**Files:**
- Modify: `inst/www/sideview.js` (`renderJoinCheck`, `joinDiagLine`)
- Modify: `inst/www/sideview.css`
- Test: `tests/testthat/gui-test-runner.js` (`scenario8` continues, or `scenario9`)

**Interfaces:**
- Consumes: the reply fields (Tasks 4–6, 8).
- Produces this text in the panel:
  - The title adds `rule: <ruleLabel>`.
  - A row `Dropped by the rule: X <table> rows / Y <right> rows`, with the title
    `Rows that match on the key but not the rule`.
  - A row type missing from `rows` shows `-` with the note `Unknown for right and full joins with a nearest match`.
  - The Strict line, for the step's type:
    - `Strict would write: relationship = "one-to-many", unmatched = "error"`.
    - Without `unmatched`, a reason: left gives `unmatched left out: 12 labs rows would be dropped`; right counts table
      rows; inner gives `12 visits rows and 3 labs rows would be dropped`.
    - semi/anti: `Strict does not apply to semi and anti joins.`
    - No entry: `Strict needs at least one match.`
  - All numbers go through `fmtN`, and all names are escaped.

- [ ] **Step 1: Write the failing scenario.** Feed a canned `sideview_join_diagnostics` reply (before rule, an
  unmatched labs row) and expect each string above.
- [ ] **Step 2: Run it and see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the runner. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(ui): the join check panel shows the rule, drops and strict args"`

### Task 11: Real-browser and RStudio verification, docs, full suite

**Files:**
- Modify: `tests/testthat/test-layout-browser.R` (a new test)
- Modify: `NEWS.md`, `README.md` (one Key Features bullet), the tour (wherever `sv_tour` / tour text lists join features:
  `grep -rn "tour" R inst/www`), `R/sideview.R` roxygen (`@section Known differences`: DST and wall-clock in the widget),
  `MEMORY.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write the browser test** `"a window rule edits from the join step and shows in code and panel"`
  (`skip_if_no_browser()`, real input with `b$Input$dispatchMouseEvent` / `dispatchKeyEvent`):
  1. Launch with synthetic `visits` / `labs` that have Date columns, and connect `id`.
  2. Click the rule button and choose window.
  3. Type `-3` and `3`, then press Ctrl+Enter.
  4. Expect the drawer code to match `.sv_lo = visit_date - 3`, and `parse()` it in R.
  5. Expect the panel's dropped counts to equal `sv_join_diagnostics(..., rule = ...)`.
  6. Check `getBoundingClientRect()`: the rule row sits inside the drawer and does not overlap the step's own controls,
     at 1400×900 and 560×700.
- [ ] **Step 2: Run it.** Run: `NOT_CRAN=true Rscript -e "devtools::test(filter = 'layout-browser')"`, alone in the
  background. Expected: PASS.
- [ ] **Step 3: Write the docs.**
  - NEWS (0.4.0): rule joins; Strict; `na_matches = "never"` under a rule (R1); a 0.3.x install drops a saved rule
    silently; the widget DST note.
  - README bullet: `- **Date-Window Joins**: ...`.
  - Tour text.
  - CLAUDE.md twin and wire lines (if Task 8 missed any).
  - Run `devtools::document()` and `pkgdown::check_pkgdown()`.
- [ ] **Step 4: RStudio check.** Install to a temp library, then run
  `sideview(visits, labs, viewer = "dialog")` in RStudio through computer use:
  1. Set a before rule and turn Strict on.
  2. Run in R: the result has dplyr's columns.
  3. Edit the data so a lab is duplicated and run again: dplyr's error appears in the toast.

  Save the screenshots to the scratchpad only, and log what was verified in `MEMORY.md` (a new Log entry dated
  2026-10-26 or later).
- [ ] **Step 5: Full suite.** Run `NOT_CRAN=true Rscript -e "devtools::test()"` in the background (about 20 min), then
  `Rscript -e "devtools::check()"`. Expected: 0 failures; check gives 0 errors and 0 warnings.
- [ ] **Step 6: Commit.** `git commit -m "docs: join rules in NEWS, README, tour; browser and RStudio checks"`
