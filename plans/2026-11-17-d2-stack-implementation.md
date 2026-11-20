# D2: stack tables and compare their columns: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pick 2 to 8 cards and press Check. sideview shows how their columns line up: types, labels, near-miss
names, and how many values a cast would turn into NA. One more click opens the stacked table as a card. The
card's generated code rebuilds it, lazy inputs stay lazy, and `sv_stack_check()` / `sv_stack()` give the same
answer in the console.

**Architecture:** Stacking is a new derive op, `"stack"`, on D1's derived-card mechanism.
- R computes the check, and R keeps the resolved per-column *plan* in the card's `derived$args$plan`, as D1 does for
  SUPP (D1 decision 8).
- The code is written twice, by an R writer (`sv_stack_code()`) for the console and the check preview, and by the
  JS `deriveExpr()` stack branch for `compose()`. A test holds the two byte-equal, as the codebook CSV twin does.
- Lazy stacks are one duckdb `union_all()` query, never collected.

**Tech Stack:** R 4.5.2 (dplyr, vctrs through `bind_rows()`, dbplyr, duckdb and arrow in Suggests), plain ES5 JS
(`inst/www`), testthat with `testServer`, node through `helper-node.R`, chromote real-browser tests, axe-core.

**Spec:** `plans/2026-11-16-derived-cards-design.md`, section 6, plus the parts of sections 8 to 12 that name
stacking. The build notes are in `plans/2026-11-17-d2-stack-design.md`. Read both before any task. Read section 5
of the spec too, because the derive rules there (5.1 inputs "as loaded", 5.3 CDISC, 5.4 code twin) apply.

## Global Constraints

- **Branch:** `d/d2-stack`, cut from `d2/plan` (which holds this plan), in `C:\src\sv-a11y`. It becomes one PR.
  - There is **no version bump**: 0.10.0 waits for D3.
  - Never commit on `main`. Never push or merge.
  - Never commit `tests/testthat/_problems/` or `testthat-problems.rds`.
- **Line endings:** keep CRLF where a file has it (`MEMORY.md`, `NEWS.md`, `DESCRIPTION`, `inst/www/sideview.js`,
  `plans/*.md`). Check with `file <path>` first. There is no Python on this machine, so script CRLF edits with
  node (`fs.readFileSync` / `writeFileSync`, keeping `\r\n`).
- **Commit trailer:** `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **R:** run as `"/c/Program Files/R/R-4.5.2/bin/Rscript.exe"`.
  - Run tests with `devtools::test(filter = "<file>")`.
  - Real-browser tests need `NOT_CRAN=true`.
  - The full suite takes over 30 minutes, so run it in the background.
- **JS:** check syntax with `node --check inst/www/<file>.js`.
- **Exports:** `sv_stack_check()` and `sv_stack()`, with roxygen docs, go into `_pkgdown.yml` next to
  `sv_unmatched`.
- **Generated R code** must `parse()`. The in-memory form runs with dplyr only (no sideview function, no pipe).
- **JS rules:**
  - Escape table-derived text before `innerHTML`. Use `CSS.escape` in selectors.
  - New handlers go through `onMessage()`; inputs go out with `send()`.
  - Remove every global listener in `destroy()`.
- **CSS:** use `--sv-*` tokens under `.sideview-container`. Icons are inline SVG only.
- **Lazy tables are never collected.** Only `collect(head(tbl, 0))`, counts, NA-count sums and row windows come
  back. A test must fail if a full table is collected, as in test-lazy.R.
- **Module mode is an untrusted client.** A forged `stack_check_request` or stack `derive_request` must not make R
  read an object outside the store, run code, or change the store when it is refused.
- **Inputs:** 2 to 8 cards, no card twice. A derived card may be an input. Grid cards only.
- **Card name:** `<first>_stacked`, then `_2`, `_3`, through `sv_derive_name()` (with `make.names()`).
- **Id column:** `source` holds each input's card name. If any input has a `source` column, use the first free name
  of `source_2`, `source_3`, and so on.
- **Row count:** the stacked card has exactly the sum of its inputs' rows.
- **CDISC tag:** kept only when every input has a tag and all name the same domain. Otherwise there is none.
- **Text:** R writes all of D2's text (`sv_say_*` in `R/say.R`); there is no JS twin. The Open button reads
  "Open stacked card (1,240 rows)", or "Open stacked card (1,240 rows; 3 values become NA)" when a cast turns
  values into NA.
- **Announce:** use `engine.announce()`, as D1 does: "Table wave1_stacked added, 1,240 rows."

## Decisions this plan makes (gaps in spec 6 and the build notes)

These are my calls. A task implements each one, and none of them reopens the spec.

1. **Type vocabulary** (the column table shows these):
   - The names are `lgl`, `int`, `num` (double, and `integer64`), `chr`, `fct` (factor or ordered), `date` (Date)
     and `dttm` (POSIXct).
   - Any other class is `other`, named by its `class(x)[1]`.
   - A list column is refused with the error "Column <col> in <table> is a list column; it cannot be stacked."
   - A lazy input's types are read from `collect(head(tbl, 0))` of its duckdb placement, with the card's factor
     levels (`sv_lazy_factors()`) and zones (`sv_lazy_zones()`) put back. So an Arrow int64 column reads as `num`,
     and an Arrow dictionary column reads as `fct`.
2. **Default target**, which the spec's order decides:
   - The order is `lgl < int < num < chr`.
   - `date` with `dttm` gives `dttm`.
   - `date` or `dttm` with any of `lgl`, `int`, `num` or `chr` gives `chr`.
   - `fct` with anything other than `fct` gives `chr`.
   - All `fct` gives `fct`, with the union of levels, in the order `bind_rows()` gives. An ordered factor mixed with
     a plain one, or two ordered factors with different levels, gives `chr`, because vctrs refuses to combine them.
   - The same `other` class in every input is kept; otherwise the target is `chr`.
3. **Offered targets** are the default, `chr`, and every type present in the column, filtered to the ones the cast
   table below can reach from every type present. Each cast either converts a value exactly or gives NA, and the
   NA count reports that. Nothing is rounded or truncated silently.

   | to | from, and what converts (everything else becomes NA) |
   |---|---|
   | `lgl` | `int`/`num`: 0 and 1 only. `chr`: exactly `"TRUE"` / `"FALSE"`. |
   | `int` | `lgl`. `num`: whole values within ±2147483647 that are not NaN. `chr`: `sv_supp_int_re`, within the same range. |
   | `num` | `lgl`, `int`. `chr`: `sv_supp_dbl_re` and `abs(x) <= 1e308`, as in the SUPP merge, so `"0x1A"`, `"Inf"` and `"1d3"` become NA. |
   | `chr` | every type. `dttm` uses `format(x, "%Y-%m-%d %H:%M:%S", tz = <zone>)`, never `as.character()`, which drops midnight times element by element. `num` uses `as.character()`. |
   | `date` | `dttm`: the UTC date. `chr`: `^[0-9]{4}-[0-9]{2}-[0-9]{2}$` and a valid date. |
   | `dttm` | `date`: midnight UTC (`as.POSIXct(x)`, which is UTC in R 4.5). The column keeps the first `dttm` input's zone, as `bind_rows()` does. |
   | `fct` | only when every input is `fct` (decision 2). |

   - **Known deviation:** as `sv_lazy_text_expr()` documents, `num` to `chr` gives `"1e+05"` in R and `"100000"` in
     duckdb, and float noise differs. The twin fixtures use whole numbers and ordinary decimals.
4. **Fixes:** `args$fixes` is a list of `{column, action, to}`.
   - `cast`: `column` is the stack column (after renames), and `to` is one of its offered targets.
   - `rename`: `column` is a near-miss name, and `to` is the first table's spelling of its case partner. Every input
     whose column is exactly `column` is renamed. After the rename the two rows merge, and the cast rules apply to
     the merged column.
   - `keep`: an explicit no-op, which is the default for every column and every near-miss.
   - A fix naming a column that is not in the stack fails with "Not in the stack: <col>".
   - A target that is not offered fails with "<col> cannot be cast to <to>."
   - A rename that is not a near-miss pair fails with "<col> is not a near-miss of <to>."
   - More fixes than columns is refused ("Too many fixes.").
5. **The check takes fixes.** The wire input is `stack_check_request {id, tables, fixes?}`. Each change to a fix in
   the UI sends a new check, so the NA counts and the column table always match what Open builds. R checks the
   fixes again at open time (build notes, decision 1).
6. **Column order:** the id column first, then every column in order of first appearance across the inputs, as
   `bind_rows()` gives. Rows keep input order and then row order in memory. A lazy card has no order, so the
   twins compare rows sorted, as `test-derive-code.R` does.
7. **Labels:**
   - The kept label is the first input's label for that column, or failing that the first label met in input
     order.
   - `bind_rows()` drops labels (I checked dplyr 1.2.1), so the in-memory code wraps the stack in
     `dplyr::mutate(..., COL = structure(COL, label = "..."))`, one argument per labelled column.
   - Lazy code writes no labels. The lazy card carries them in `col_labels`, set by R from the plan.
8. **Time zones:** `dttm` columns whose zones differ get the status "time zone differs (<first> zone kept)". The
   instants are not changed.
9. **Code forms** (one expression each, with no pipe, so the pipe setting cannot change the text):
   - **All inputs in memory:** `dplyr::bind_rows(<a> = <ref a>, <b> = dplyr::mutate(<ref b>, <col> = <cast>), .id = "source")`.
     It is wrapped in the label `mutate()` when any label is kept. A `rename` fix is
     `dplyr::rename(<ref>, AGE = Age)` inside the same argument.
   - **Any input lazy:** every input goes onto one duckdb connection. Each is wrapped as
     `dplyr::mutate(<placed ref>, source = "<name>", <missing col> = <typed NA>, <col> = <cast>)`, then
     `dplyr::select()` puts the columns in stack order, and the inputs are joined by nested
     `dplyr::union_all(a, dplyr::union_all(b, c))`.
     - Placement follows `crossBackend()`'s forms. A duckdb input stays where it is.
     - An Arrow input becomes `dplyr::compute(arrow::to_duckdb(<ref>, con = dbplyr::remote_con(<duck ref>)))`, or
       `arrow::to_duckdb(<ref>)` when there is no duckdb input.
     - A data frame becomes `dplyr::copy_to(dbplyr::remote_con(<duck ref>), <ref>, name = "sideview_<card>_<i>", overwrite = TRUE)`.
       With no duckdb input it becomes `arrow::to_duckdb(arrow::arrow_table(<ref>))`.
     - So the code's kind is always `'duckdb'`.
     - Two duckdb inputs on different connections are refused with D1's `sv_lazy_cross_con` message.
   - **Lazy casts** use `dbplyr::sql("TRY_CAST(...)")` where dbplyr has no exact translation. dbplyr's
     `as.numeric()` is `NUMERIC`, which is DECIMAL(18,3) in duckdb, and a plain `CAST` errors on bad text.
     Columns quoted in `sql()` go through `DBI::dbQuoteIdentifier()` in R, and through the same quoting rule in JS.
     NaN counts as missing in both the guard and the NA count: use `isnan()`, never `is.nan()`. duckdb's
     `NaN = NaN` is true.
10. **NA count:** for each input and each cast column, the number of rows where the value is not missing (not NA,
    not NaN) and the cast gives NA. In memory it is a vector sum. Lazy, it is one `summarise()` query per input.
    The reply carries it per column per input, and the text gives the total.
11. **One builder pane for the drawer and the list view.**
    - `stack` joins `DRAWER_TABS` and `BUILDER_TABS` only when `hasR()`. The widget never draws it.
    - `movePanes()` moves the same pane into the list view's Stack host, as for Filter and Summarise, so the two
      cannot disagree.
    - The list view's `BUILDERS` gets `['stack', 'Stack']` when the engine has R.
12. **Pick order is stack order.** The picker is a list of grid cards with checkboxes (a fieldset with a legend).
    Ticking a card appends it to the order, and unticking removes it. The picked order shows as a numbered list.
    Check is disabled until 2 cards are picked, and the ninth checkbox is disabled while 8 are picked.

## Review Focus

1. **NaN in a `num` column cast to `int` or `chr`, lazy vs in memory.**
   - duckdb says `NaN IS NULL` is false and `NaN = NaN` is true, so a naive guard counts NaN as a new NA or errors
     in the cast.
   - Expected: the same NA count and values as in memory.
   - Test: Task 3, the `"NaN and Inf in casts agree"` test.
2. **Odd numeric text in a `chr` to `num` or `int` cast**: `"\t12"`, `" 12 "`, `"1e5"`, `"0x1A"`, `"Inf"`, `""`,
   `"1e999"`.
   - Expected: the same NA count in R and duckdb. `"0x1A"`, `"Inf"` and `"1e999"` become NA in both, never 26 or
     Inf.
   - Test: Task 1 (the R cast) and Task 3 (the lazy twin).
3. **An input that already has `source`** (and `source_2` in another input):
   - Expected: the id column is `source_3`, the user's `source` columns stack as an ordinary column, and the code
     uses `.id = "source_3"`.
   - Test: Task 2, plus the Task 4 code twin.
4. **An input with zero rows** (an empty derived card), or an all-NA logical column against `chr`:
   - Expected: the types still come from the columns, the row count adds 0, the status is
     "type differs -> as.character" with 0 NA, and the code rebuilds the card.
   - Test: Task 2 in memory, Task 3 over duckdb.
5. **Non-syntactic and awkward names**: a card `wave 2`, a column `` `visit date` ``, and a label with `"`, `\` and
   non-ASCII text.
   - Expected: the code parses and rebuilds the card. The card name becomes `wave.2_stacked` when `wave 2` is first.
     The label is the same string after the round trip.
   - Test: Task 4.

---

### Task 1: R stack check in memory, `sv_stack_check()`

**Files:**
- Create: `R/stack.R`
- Create: `tests/testthat/test-stack.R`
- Modify: `R/say.R` (the stack text functions)

**Interfaces:**
- Consumes: `sv_supp_int_re`, `sv_supp_dbl_re` and `sv_supp_dbl_max` (`R/supp.R`).
- Produces:
  - `sv_stack_type(x)` (internal). It returns one of the decision 1 names, with `attr(, "class1")` for `other`.
  - `sv_stack_plan(tables, fixes = list())` (internal). `tables` is a named list of data frames in stack order. It
    returns a list:
    - `inputs`: the names;
    - `id_col`;
    - `n_rows`: the sum;
    - `columns`: a list, one entry per stack column, each
      `{name, types, labels, zones, target, targets, cast, rename_from, near_miss_of, na, status}`.
      - `types`, `labels`, `zones` and `na` have one element per input, NA where the column is absent.
      - `cast` is a character vector of per-input targets, NA where no cast is needed.
      - `rename_from` holds the original per-input names after a rename fix.
      - `status` is a character vector of the status strings.
    - `kept_labels`: a named character vector;
    - `tz`: the kept zone per `dttm` column.

    It is a plain list, so it travels as JSON in `derived$args$plan`. Task 3 adds a lazy branch with the same
    return value.
  - `sv_stack_cast(x, from, to, zone = NULL)` (internal). It is the in-memory cast table of decision 3, and returns
    the cast vector.
  - Exported `sv_stack_check(..., cast = NULL, rename = NULL)`.
    - `...` are tables, named by their expressions when unnamed, as `sideview()` names them.
    - `cast` is a named character vector (`c(AGE = "chr")`), and `rename` is one too (`c(Age = "AGE")`). They become
      `fixes`.
    - It returns class `sv_stack_check`: the plan, plus `table` (a data frame with one row per column: `Column`,
      one column per input, `Status`), `text` (character) and `code`. Task 2 fills `code`.
  - `print.sv_stack_check()`. It prints `text`, then the table with no row names, then `code`.
  - In `R/say.R`, `sv_say_stack_status(col, plan)` returns the status strings:
    - "type differs -> as.numeric", naming the cast function: `as.logical`, `as.integer`, `as.numeric`,
      `as.character`, `as.Date` or `as.POSIXct`, or "factor levels joined";
    - "label differs (wave1 label kept)";
    - "only in wave1 (NA in wave2)", or "only in wave1, wave3 (NA in wave2)";
    - "near-miss for AGE? (case)";
    - "time zone differs (wave1 zone kept)";
    - "3 values in wave2 become NA";
    - "ok" when nothing differs.
  - In `R/say.R`, `sv_say_stack_text(plan)` returns the summary lines, for example "Stack 3 tables: 1,240 rows,
    14 columns.", "2 columns change type; 3 values become NA." and "1 near-miss name left apart.". It also returns
    `sv_say_stack_open(plan)`, the Open label from the Global Constraints.

- [ ] **Step 1: Write the failing tests** in `test-stack.R`, on synthetic `wave1` / `wave2` / `wave3` data frames:
  - `test_that("types and the default target follow the cast order")`: one column per pair. Expect these targets:
    `lgl`+`int` gives `int`; `int`+`num` gives `num`; `num`+`chr` gives `chr`; `date`+`chr` gives `chr`;
    `date`+`dttm` gives `dttm`; `fct`+`chr` gives `chr`; `fct`+`fct` gives `fct` with levels `c("x","y","z")`;
    ordered+`fct` gives `chr`; `lgl`+`chr` gives `chr`.
  - `test_that("offered targets come from the cast table")`:
    - `num`+`chr` offers `c("chr", "num")`;
    - `date`+`num` offers `"chr"` only;
    - `lgl`+`int`+`num` offers `c("num", "chr", "lgl", "int")`, in the order default, `chr`, then present types.
  - `test_that("casts convert exactly or give NA, and NA is counted")`:
    - `chr` to `num` on `c("12", " 12 ", "\t12", "1e5", "0x1A", "Inf", "", "1e999", NA)` gives
      `c(12, 12, 12, 1e5, NA, NA, NA, NA, NA)`, and the NA count is 5;
    - `num` to `int` on `c(1, 2.5, NaN, 3e9, NA)` gives `c(1L, NA, NA, NA, NA)`, and the count is 2 (NaN and NA were
      already missing);
    - `int` to `lgl` on `c(0L, 1L, 2L)` gives `c(FALSE, TRUE, NA)`, and the count is 1;
    - `dttm` to `chr` keeps `"2024-01-01 00:00:00"` for a midnight value;
    - `date` to `dttm` gives midnight UTC.
  - `test_that("near-miss is flagged, never merged, and the rename fix merges it")`:
    - `wave1$AGE` (num) and `wave2$Age` (chr) give two rows, the second with the status
      "near-miss for AGE? (case)";
    - with `rename = c(Age = "AGE")` they give one row `AGE` with the target `num`;
    - `rename = c(Age = "RACE")` errors "is not a near-miss of".
  - `test_that("labels: first kept, differences listed")`: a `RACE` label `"Race"` in wave1 and `"RACE"` in wave2
    gives `kept_labels[["RACE"]] == "Race"` and the status "label differs (wave1 label kept)".
  - `test_that("a column in some inputs only")`: the status is "only in wave1 (NA in wave2)", and the NA count is 0.
  - `test_that("bad fixes are refused")`: a cast on an unknown column, a target that is not offered, and a list
    column each give their decision 4 or decision 1 messages.
  - `test_that("print shows the table")`: `expect_snapshot(print(sv_stack_check(wave1, wave2)))`.
- [ ] **Step 2: Run them and see them fail.** Run `devtools::test(filter = "stack")`. Expected: FAIL, "could not
  find function".
- [ ] **Step 3: Implement** `sv_stack_type()`, `sv_stack_cast()`, `sv_stack_plan()` (in-memory branch),
  `sv_stack_check()`, the print method and the three `sv_say_stack_*` functions.
  - The near-miss partner is found with `tolower()` across all inputs' names.
  - A column whose names clash case-insensitively *within one input* is not a near-miss.
- [ ] **Step 4: Run them and see them pass.** Run `devtools::test(filter = "stack")`. Expected: PASS.
- [ ] **Step 5: Commit.** Run `devtools::document()` and add `sv_stack_check` to `_pkgdown.yml`. Commit with
  "feat: stack column check and sv_stack_check()".

### Task 2: In-memory stack rows, the `stack` derive op, `sv_stack()`, the R code writer

**Files:**
- Modify: `R/stack.R`, `R/derive.R`, `tests/testthat/test-stack.R`, `tests/testthat/test-derive.R`

**Interfaces:**
- Consumes: Task 1's `sv_stack_plan()` and `sv_stack_cast()`. D1's `sv_derive_clean()`, `sv_derive_name()`,
  `sv_derive_card()` and `sv_derive_rows()`.
- Produces:
  - `sv_stack_rows(tables, plan)` (internal): the stacked data frame. It renames, casts, runs `bind_rows(.id = plan$id_col)`
    and sets the kept labels. Tables are in memory here; Task 3 adds the lazy branch.
  - `sv_stack_code(plan, refs, kinds)` (internal). It returns `list(code, kind)`:
    - `refs` is a character vector, the R reference per input (a card's `code_ref`, or its name for a derived
      input), as JS `refFor()` gives it;
    - `kinds` holds `NA`, `"duckdb"` or `"arrow"` per input;
    - the forms are those of decision 9. Task 2 writes the in-memory form, and Task 3 the lazy form.
  - `sv_stack_check()` now fills `code` with `sv_stack_code()` on the call's expressions.
  - Exported `sv_stack(..., check = NULL)`. When `check` is `NULL` it is `sv_stack_check(...)` with no fixes. Its
    `inputs` must equal the names of `...`, otherwise it errors "`check` was made for other tables."
  - In `R/derive.R`:
    - `"stack"` is appended to `sv_derive_ops`.
    - `sv_derive_clean()` takes 2 to 8 unique `inputs` for `stack`, and exactly 2 for the other ops. The errors
      are "A stack needs 2 to 8 tables." and "A table can be stacked only once."
    - Its `args` allowlist for `stack` is `fixes` (each element has exactly `column`, `action` and `to`, all scalar
      strings through `sv_derive_scalar()`, `to` may be NULL for `keep`) and `id_col`.
    - `sv_derive_name()` has a `stack` branch giving `paste0(inputs[1L], "_stacked")`.
    - `sv_derive_card()` runs the plan, stores `derived$args = list(fixes, id_col, plan)`, sets `col_labels` from
      `plan$kept_labels`, and keeps the CDISC tag by the Global Constraints rule.
    - A client `id_col` must not be a column of any input, otherwise "<id> is a column of <table>." is returned.

- [ ] **Step 1: Write the failing tests:**
  - In `test-stack.R`:
    - `test_that("rows equal bind_rows and the sum of inputs")`:
      - `expect_equal(nrow(sv_stack(wave1, wave2, wave3)), nrow(wave1) + nrow(wave2) + nrow(wave3))`;
      - the result equals `dplyr::bind_rows(wave1 = ..., .id = "source")` after the same casts, with labels removed
        for the comparison;
      - the `source` values are the card names.
    - `test_that("id column avoids taken names")`: Review Focus 3 gives `"source_3"`.
    - `test_that("zero-row input and all-NA logical column")`: Review Focus 4.
    - `test_that("labels survive in the result")`: `attr(res$RACE, "label") == "Race"`.
    - `test_that("in-memory code parses, runs with dplyr only and rebuilds")`:
      - `code <- sv_stack_check(wave1, wave2, cast = c(AGE = "chr"))$code`;
      - `expect_parses(code)`;
      - `eval(parse(text = code), envir = list2env(list(wave1 = wave1, wave2 = wave2), parent = baseenv()))`, with
        `dplyr` reached only through `::`, equals `sv_stack(wave1, wave2, check = <that check>)`, labels included.
  - In `test-derive.R`:
    - `test_that("stack derive card: name, rows, tag, args")`:
      - `sv_derive_card(list(op = "stack", inputs = list("wave1", "wave2"), args = list(fixes = list())), store, con_env)`
        gives the name `"wave1_stacked"`, `dims[1]` equal to the sum, `card$derived$args$plan$id_col == "source"`,
        and `col_labels[["RACE"]] == "Race"`;
      - with CDISC tags AE and AE the tag is kept; AE and DM gives `NULL`.
    - `test_that("stack requests are cleaned")`:
      - 1 input or 9 inputs, a repeated input, an unknown input, a fix with an extra field, and an `id_col` that is
        a column are each refused with their messages;
      - the store is unchanged.
- [ ] **Step 2: Run them and see them fail.** Run `devtools::test(filter = "stack|derive")`. Expected: FAIL.
- [ ] **Step 3: Implement** `sv_stack_rows()`, the in-memory `sv_stack_code()`, `sv_stack()` and the `R/derive.R`
  changes.
  - Strings in the code are written with `encodeString(x, quote = '"')`. Names are written with `sv_escape_ident()`
    (`R/codegen.R`), which backticks non-syntactic names as `ident()` in sv-pipeline.js does.
    Task 4 holds R and JS to the same text.
- [ ] **Step 4: Run them and see them pass.** Expected: PASS, with D1's derive tests still green.
- [ ] **Step 5: Commit.** Run `devtools::document()` and add `sv_stack` to `_pkgdown.yml`. Commit with
  "feat: stack derive op, sv_stack() and its code".

### Task 3: Lazy stack: N-way placement, lazy check and rows, lazy code

**Files:**
- Modify: `R/lazy.R`, `R/stack.R`, `tests/testthat/test-lazy.R` (a new block)

**Interfaces:**
- Consumes: `sv_lazy_place()`'s rules, `sv_lazy_attach()`, `sv_lazy_decode_dictionaries()`, `sv_lazy_zones()`,
  `sv_lazy_with_zones()`, `sv_lazy_factors()` and `sv_lazy_text_expr()`. Also `sv_derived_source()` and
  `sv_lazy_derived_tbl()`.
- Produces:
  - `sv_lazy_place_n(tables, con_env)` (internal). It returns `list(tbls, con, cleanup)`. It applies
    `sv_lazy_place()`'s rules to N inputs:
    - all duckdb inputs must share one connection, which is used; with none, the session connection is used;
    - the error classes `sv_lazy_not_duckdb` and `sv_lazy_cross_con` and their messages are reused, with "join
      check" replaced by "stack".
  - `sv_lazy_stack_plan(tables, fixes, con_env)`. It gives the same return value as `sv_stack_plan()`, with types
    by decision 1 and NA counts by decision 10, and only `head(0)` plus one aggregated query per input.
    `sv_stack_plan()` dispatches to it when any table is lazy.
  - `sv_lazy_stack(tables, plan, con_env)`: a duckdb tbl, the `union_all()` of decision 9, with these attributes:
    - `sv_tz`: the kept zones;
    - `sv_factors`: union levels for `fct` targets;
    - `sv_cleanup`.
  - `sv_lazy_derived_tbl()` dispatches `op == "stack"` to `sv_lazy_stack()`. A stacked card's `source` is
    `sv_derived_source("stack", args, inputs)`.
  - `sv_stack_code()` writes the lazy form when any `kinds` is not NA.
  - `sv_stack()` is lazy in, lazy out.

- [ ] **Step 1: Write the failing tests** in `test-lazy.R`, using `dc_fixture()`-style setup for the kinds `df`,
  `duckdb` and `arrow`:
  - `test_that("lazy stack equals in-memory stack")`: for the kind sets `c("duckdb","duckdb")`, `c("arrow","arrow")`,
    `c("df","duckdb")`, `c("arrow","df","duckdb")`:
    - the rows of `dplyr::collect(sv_stack(...))`, sorted, equal the in-memory `sv_stack()` sorted, with
      `tolerance = 1e-12`;
    - `nrow` equals the sum;
    - the lazy check's `kept_labels` equal the in-memory ones.
  - `test_that("each cast rule agrees lazily")`: every row of the decision 3 table, over duckdb, gives the same
    values and NA counts as Task 1, including Review Focus 2's strings.
  - `test_that("NaN and Inf in casts agree")`: Review Focus 1.
  - `test_that("time zones and factors survive")`: two `dttm` inputs in different zones keep the first zone
    (`sv_tz`). Two dictionary or factor inputs give a factor with the union of levels when rows are fetched with
    `sv_lazy_rows_window()`.
  - `test_that("lazy stack is never collected")`: use test-lazy.R's existing collect trap, and expect the check,
    the card build and the row count to pass without collecting.
  - `test_that("two duckdb connections are refused")`: `expect_error(..., class = "sv_lazy_cross_con")`.
  - `test_that("zero-row lazy input")`: Review Focus 4 over duckdb.
- [ ] **Step 2: Run them and see them fail.** Run `devtools::test(filter = "lazy")`. Expected: FAIL in the new
  block only.
- [ ] **Step 3: Implement** the four functions and the lazy code form.
  - Typed NAs for missing columns: `NA_character_`, `NA_real_`, `NA_integer_`, `NA`, `as.Date(NA)` and
    `as.POSIXct(NA)`.
  - Write each lazy cast once, as an `rlang` expression builder that `sv_lazy_stack()` evaluates, and print the
    same expression into the code with `rlang::expr_deparse()` joined. Task 4 checks that the JS text matches it.
- [ ] **Step 4: Run them and see them pass.** Run `devtools::test(filter = "lazy|stack|derive")`. Expected: PASS.
- [ ] **Step 5: Commit** with "feat: lazy stack as one duckdb union_all".

### Task 4: Pipeline stack step and its code (JS), with the twin tests

**Files:**
- Modify: `inst/www/sv-pipeline.js`
- Modify: `tests/testthat/test-derive-code.R`, `tests/testthat/test-stack.R` (byte-equal block),
  `tests/testthat/test-pipeline.R` (step label, liveness, undo)

**Interfaces:**
- Consumes: the plan shape (Task 1), `sv_stack_code()` (Tasks 2 and 3), and D1's `deriveStep()`, `deriveLive()`,
  `deriveExpr()`, `compose()`, `refFor()` and `lazyKind()`.
- Produces:
  - `Pipeline.deriveLive(step)` accepts 2 to 8 inputs for `op === 'stack'`. Other ops stay at exactly 2.
  - `Pipeline.deriveExpr(step)` for `stack` returns `{code, kind}` from `step.args.plan`. `kind` is `null` in
    memory, else `'duckdb'`. It returns `{code: '', kind: null}` when there is no plan.
  - The step label is `'stack of ' + inputs.join(' + ')`, both at line ~368 and in the engine's step kind labels
    (~line 8210).

- [ ] **Step 1: Write the failing tests:**
  - In `test-stack.R`, `test_that("R and JS write the same stack code")`:
    - for a matrix of plans (casts of every target, a rename, kept labels, a `source_3` id, a missing column) and
      kind sets (all in memory; duckdb; arrow; df + duckdb; arrow + df), with refs including a non-syntactic one;
    - the JS `deriveExpr({kind:'derive', op:'stack', table, inputs, args:{plan}})` through `run_pipeline_js()`
      equals `sv_stack_code(plan, refs, kinds)$code` byte for byte.
  - In `test-derive-code.R`, `test_that("stack code rebuilds the card")`:
    - for the kind sets of Task 3, compose in node, `expect_parses()`, and eval on `fx$objs`;
    - the result's rows, sorted and collected, equal the rows of `dc_card(fx, "stack", inputs, list(fixes = ...))`;
    - in memory, the labels are equal too;
    - Review Focus 5's names are in this matrix.
  - In `test-pipeline.R`:
    - a stack step of 3 inputs is live, and is not live when one input is gone;
    - `compose()` writes it before the chains;
    - undo removes it, and redo brings it back with the same `args`;
    - a state round trip (`getState()` then `applyState()` in node) keeps `args.plan`.
- [ ] **Step 2: Run them and see them fail.** Run `devtools::test(filter = "stack|derive-code|pipeline")`.
  Expected: FAIL.
- [ ] **Step 3: Implement** the stack branch. Port `sv_stack_code()`'s forms using the existing `ident()`, `str()`
  and `crossBackend()` helpers. Run `node --check inst/www/sv-pipeline.js`.
- [ ] **Step 4: Run them and see them pass.** Expected: PASS.
- [ ] **Step 5: Commit** with "feat: pipeline stack step and code twin".

### Task 5: Server: `stack_check_request`, the stack derive path, module refusals

**Files:**
- Modify: `R/app_server.R`, `tests/testthat/test-module.R`, `tests/testthat/test-derive.R` (gadget `testServer`
  block), `CLAUDE.md` (the inputs and messages list)

**Interfaces:**
- Consumes: `sv_stack_plan()`, `sv_stack_code()` and `sv_say_stack_*()`. D1's `derive_request` handler, which now
  takes `op: "stack"` unchanged.
- Produces:
  - An input `stack_check_request {id, tables, fixes?}`.
  - A message `sideview_stack_check {id, columns, n_rows, id_col, name, open_label, code_preview, text}`, or
    `{id, error}`. It carries `ns` in module mode through `send()`.
    - `columns` is the plan's `columns`, with `table` (the cells for the column-table row: one string per input,
      such as `num`, `chr "Race"` or `-`) added.
    - `name` is the card name Open would get.
    - `code_preview` is `sv_stack_code()` on the store's refs and kinds.
  - The handler cleans `tables` and `fixes` with the same rules as `sv_derive_clean()` for `stack`, through one
    shared helper `sv_stack_clean(tables, fixes, store)`. It names only store cards, and lazy cards go through
    `lazy_or_preview()`.

- [ ] **Step 1: Write the failing tests:**
  - In the gadget `testServer`:
    - a check for `wave1`, `wave2` replies with the column rows, `n_rows` equal to the sum, the text lines and code
      that parses;
    - a `cast` fix changes `columns[[k]]$target` and the NA count;
    - Open (`derive_request` with `op = "stack"` and the same fixes) adds a card whose `dims[1]` is `n_rows`.
  - In the module tests, `test_that("forged stack requests are refused")`:
    - `tables` naming `Sys.getenv`, a non-store name, 9 tables, a repeated table, a fix column `"x; system('id')"`,
      and 10,000 fixes each get an `{id, error}` reply;
    - `card_store$names()` is unchanged;
    - no other message is sent.
- [ ] **Step 2: Run them and see them fail.** Run `devtools::test(filter = "module|derive")`. Expected: FAIL.
- [ ] **Step 3: Implement** the handler and `sv_stack_clean()`. Add both wire names to `CLAUDE.md`'s list, in the
  form the list uses for others.
- [ ] **Step 4: Run them and see them pass.** Expected: PASS.
- [ ] **Step 5: Commit** with "feat: stack_check_request handler".

### Task 6: Engine: the Stack drawer tab (canvas)

**Files:**
- Modify: `inst/www/sideview.js`, `inst/www/sideview.css`, `tests/testthat/test-layout-browser.R`, `tests/testthat/test-a11y-browser.R`,
  `tests/testthat/test-widget.R` (no tab)

**Interfaces:**
- Consumes: `sideview_stack_check` (Task 5), D1's `requestDerive(offer)` with
  `offer = {op: 'stack', inputs, args: {fixes, id_col}, n, label}`, `derivedArrived()`, `announce()`,
  `onMessage()` and `send()`.
- Produces:
  - `{id: 'stack', label: 'Stack'}` in `DRAWER_TABS`, and `stack` in `BUILDER_TABS`, both only when `hasR()`.
  - `SideviewEngine.prototype.renderStackBuilder(pane)`, which draws:
    - the picker (decision 12);
    - a Check button;
    - after a reply, a `<table>` with a `<caption>` and `<th scope="col">` headers (Column, one per input,
      Status);
    - for each column with more than one target, a labelled `<select>`;
    - for each near-miss, a "Rename <col> to <partner>" checkbox, off by default;
    - the text lines and a `<pre>` code preview;
    - the Open button with R's `open_label`.
  - `SideviewEngine.prototype.requestStackCheck(tables, fixes)`. Its `id` is `JSON.stringify([tables, fixes])`. A
    reply whose `id` is not the latest is ignored.
  - The state is kept on the engine (`this._stack = {picked, fixes, reply}`), so a re-render or `movePanes()`
    keeps it. A card removed from the canvas leaves `picked`, and the reply is cleared.
  - Pressing Open twice zooms to the existing card (D1 decision 4).

- [ ] **Step 1: Write the failing tests:**
  - In `test-layout-browser.R`, `test_that("Stack tab: pick, check, open")`, using real mouse input
    (`b$Input$dispatchMouseEvent`):
    - open the Stack tab, tick `wave2` then `wave1`, and press Check;
    - the table header order is `wave2`, `wave1`;
    - change a target and see the NA count text change;
    - press Open; the new card `wave2_stacked` does not overlap any card, and its row badge equals the sum;
    - at 1400×900, 1024×700 and 560×520 the pane does not overflow the drawer horizontally.
  - In `test-a11y-browser.R`, `test_that("Stack tab passes axe")`:
    - `sv_axe_run()` after a check reply gives no violations;
    - every `select` and checkbox has a name (`sv_ax_unnamed()` is empty);
    - the announcement "Table wave2_stacked added, N rows." is in the live region.
  - In the widget tests, `sideview_widget(wave1, wave2)` has no `[data-sv-tab="stack"]`. Opening a state that
    holds a stack step shows the step disabled with D1's toast.
- [ ] **Step 2: Run them and see them fail** with `NOT_CRAN=true`. Run
  `devtools::test(filter = "layout-browser|a11y-browser|widget")`. Expected: FAIL in the new tests.
- [ ] **Step 3: Implement** the tab, the builder, the handler and the CSS. Follow the SUPP builder's markup and
  token use. Run `node --check inst/www/sideview.js`.
- [ ] **Step 4: Run them and see them pass.** Expected: PASS. Also check the tab by eye in the built-in browser,
  in light and dark themes.
- [ ] **Step 5: Commit** with "feat: Stack drawer tab".

### Task 7: List view Stack builder

**Files:**
- Modify: `inst/www/sv-listview.js`, `tests/testthat/test-a11y-browser.R` (where the list view builder tests live)

**Interfaces:**
- Consumes: Task 6's pane and the `movePanes()` path (decision 11).
- Produces: `['stack', 'Stack']` in the list view's `BUILDERS` when `engine.hasR()`. The heading
  `sv-lv-b-stack` is focusable as the others are.

- [ ] **Step 1: Write the failing test** `test_that("list view Stack builder matches the drawer")`. Switch to the
  list view, pick and check with the keyboard only (`sv_key()` / `sv_tab()`), and expect:
  - the text lines and the table cells equal those the drawer showed for the same picks;
  - Open adds the card, and returning to the canvas shows it.
- [ ] **Step 2: Run it and see it fail** with `NOT_CRAN=true`. Expected: FAIL.
- [ ] **Step 3: Implement.** Run `node --check inst/www/sv-listview.js`.
- [ ] **Step 4: Run it and see it pass.** Expected: PASS.
- [ ] **Step 5: Commit** with "feat: list view Stack builder".

### Task 8: Docs and the full check

**Files:**
- Modify:
  - `NEWS.md` (under the 0.10.0 heading D1 opened);
  - `README.md` (one Key Features bullet: "**Stack Tables**: `sv_stack_check()` / `sv_stack()` and the Stack tab
    line up columns, flag type, label and near-miss differences, and open the stacked table as a card");
  - the derived-cards article ("Unmatched rows, stacking and comparing data cuts"): a stacking section with
    synthetic waves;
  - `CLAUDE.md`: the stack twin rule, next to the SUPP twin rule, saying that `sv_stack_code()` and
    `deriveExpr()` are byte-equal, that `sv_stack_plan()` / `sv_lazy_stack_plan()` and `sv_stack_rows()` /
    `sv_lazy_stack()` are twins, and that both are tested;
  - `MEMORY.md` (the change log and the roadmap task list: D2 in review);
  - `docs/` (a rebuilt site, with `docs/CLAUDE.*` and `docs/MEMORY.*` dropped).

- [ ] **Step 1:** Write the docs. Run `pkgdown::check_pkgdown()`. Expected: no problems.
- [ ] **Step 2:** Run the full suite in the background with `NOT_CRAN=true`. Expected: 0 failures, and no new
  skips beyond the known ones.
- [ ] **Step 3:** Run `devtools::check()`. Expected: 0 errors, 0 warnings, 0 new notes.
- [ ] **Step 4:** Rebuild the site, drop the dev notes, and commit with "docs: D2 stacking: NEWS, README, article,
  CLAUDE.md".
- [ ] **Step 5:** Record in `MEMORY.md` what was verified in a real browser. List the RStudio checks still to do
  (dialog, Viewer pane, external browser): pick, check, change a fix, Open, then Save and Open the state. They are
  recorded only after the user says they did them.
