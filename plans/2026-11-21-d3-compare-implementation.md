# D3: compare data cuts by key: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pick an old and a new version of a table, check or edit the key, and press Check. sideview counts the rows
added, removed, changed and the same, lists the columns that changed type, and gives the changed values per column.
One click opens the added rows, the removed rows or the changed values as a card. The card's generated code rebuilds
it, lazy inputs stay lazy, and `sv_compare()` gives the same answer in the console.

**Architecture:** Compare adds three derive ops, `compare_added`, `compare_removed` and `compare_changed`, to D1's
derived-card mechanism. It uses D2's Check -> Open pattern.
- R computes the summary, and stores the resolved *plan* (keys, compared columns, kinds, zones) in the card's
  `derived$args$plan`, as D2 does for stack.
- An R writer (`sv_compare_code()`) and the JS `deriveExpr()` compare branch both write the code. A test holds them
  byte-equal, as D2's stack twin does.
- Lazy compare is duckdb queries (anti joins, an inner join, summarise counts). Nothing is collected.

**Tech Stack:** R 4.5.2 (dplyr, dbplyr, duckdb and arrow in Suggests), plain ES5 JS (`inst/www`), testthat with
`testServer`, node through `helper-node.R`, chromote real-browser tests, axe-core.

**Spec:** `plans/2026-11-16-derived-cards-design.md` sections 7, 8 and 9 (the design), plus section 5 (derive rules:
5.1 inputs "as loaded", 5.3 CDISC, 5.4 code twin). The build notes in `plans/2026-11-21-d3-compare-design.md` fix the
open points; they win over the spec where they differ. Read both before any task. D2's plan
(`plans/2026-11-17-d2-stack-implementation.md`) is the pattern this plan follows.

## Global Constraints

- **Branch:** `d/d3-compare` in `C:\src\sv-a11y` (holds the build notes and this plan). It becomes one PR.
  - **Version 0.10.0** in this PR: `DESCRIPTION`, the `NEWS.md` heading. Asset versions follow `sv_asset_version()`.
  - Never commit on `main`. Never push or merge.
  - Never commit `tests/testthat/_problems/` or `testthat-problems.rds`.
- **Line endings:** keep CRLF where a file has it (`MEMORY.md`, `NEWS.md`, `DESCRIPTION`, `inst/www/sideview.js`,
  `plans/*.md`). Check with `file <path>` first. There is no Python on this machine, so script CRLF edits with
  node (`fs.readFileSync` / `writeFileSync`, keeping `\r\n`) or use the Edit tool.
- **Commit trailer:** `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **R:** run as `"/c/Program Files/R/R-4.5.2/bin/Rscript.exe"`.
  - Run tests with `devtools::test(filter = "<file>")`.
  - Real-browser tests need `NOT_CRAN=true`.
  - The full suite takes over 30 minutes, so run it in the background.
- **JS:** check syntax with `node --check inst/www/<file>.js`.
- **Exports:** `sv_compare()` with roxygen docs, in `_pkgdown.yml` next to `sv_stack`.
- **Generated R code** must `parse()`. The in-memory form runs with dplyr only (no sideview function, no pipe).
- **JS rules:**
  - Escape table-derived text before `innerHTML`. Use `CSS.escape` in selectors.
  - New handlers go through `onMessage()`; inputs go out with `send()`.
  - Remove every global listener in `destroy()`.
- **CSS:** use `--sv-*` tokens under `.sideview-container`. Icons are inline SVG only.
- **Lazy tables are never collected.** Only `collect(head(tbl, 0))`, summarise counts, the repeated-key sample
  (at most 5 rows) and row windows come back. A test must fail if a full table is collected, as in test-lazy.R.
- **Module mode is an untrusted client.** A forged `compare_request` or compare `derive_request` must not make R
  read an object outside the store, run code, or change the store when it is refused.
- **Inputs:** exactly 2 cards, old then new, not the same card. A derived card may be an input. Grid cards only.
- **Rules (build notes, unchanged):**
  - Rows are added, removed, changed or the same by key.
  - A key repeated in **either** version leaves all its rows, in both versions, out of every count and card. It is
    reported as a warning with up to 5 sample keys.
  - Compared columns are those in both versions with the same `sv_key_kind()`, so integer = double and
    factor = character.
  - Type-changed columns are listed, not compared. Key columns are not compared. Label changes are out of D3.
  - Equality is exact. NA (and NaN) in both is the same; NA in one is changed.
  - The count per column is the number of rows where that column changed.
  - These identities hold: `added + changed + same + repeated_rows_new = nrow(new)` and
    `removed + changed + same + repeated_rows_old = nrow(old)`.
- **Card names:** `<old>_removed`, `<new>_added`, `<new>_changed`, then `_2`, `_3` on a clash, through
  `sv_derive_name()` (with `make.names()`).
- **The `_changed` card** has the key columns, then `column`, `old`, `new` (`old` and `new` are character). It is
  ordered by key, then by the column's position in new.
- **CDISC tag:** `_removed` keeps old's tag, `_added` keeps new's tag, and `_changed` has none.
- **Text:** R writes all of D3's text (`sv_say_compare_*` in `R/say.R`); there is no JS twin. It follows spec 7.2:
  ```
  ae_2026_06 -> ae_2026_09, key STUDYID + USUBJID + AESEQ
  Rows:    1,204 -> 1,251   added 52 · removed 5 · changed 31 · same 1,168
  Columns: added AEACN2 · removed none · type changed AESTDTC (chr -> Date)
  Changed values by column:  AESEV 18 · AEOUT 9 · AEENDTC 7
  Warnings: 2 keys repeat: 4 rows in old, 3 in new, not compared
  ```
  The buttons read "Open added rows (52)", "Open removed rows (5)" and "Open changed values (31 rows)".
- **Announce:** use `engine.announce()`, as D1 and D2 do: "Table ae_2026_09_added added, 52 rows."

## Decisions this plan makes (gaps in spec 7 and the build notes)

These are my calls. A task implements each one, and none of them reopens the spec.

1. **Wire.** `compare_request {id, old, new, by?}` -> `sideview_compare {id, ...summary, text, open, code_preview}`,
   or `{id, error}`. With `by` absent, R fills the key (decision 2) and the reply carries it, so the drawer can
   show it. The check id is short, as D2's: `'cp' + seq + '_' + Date.now().toString(36)`, and only the reply to
   the latest id is drawn.
2. **Key suggestion:** `sv_compare_key(old_card, new_card)`:
   - When both cards carry the same CDISC domain tag, use `sv_keys_natural()` of that domain, kept to the columns
     in both versions.
   - Otherwise use the shared columns that `sv_suggest_mappings()` would pick for the pair (same names, confidence
     at least 0.6), in new's column order.
   - Otherwise use `character(0)`. The reply then carries `by: []` and the error "Pick the key columns.", and the
     drawer shows the key picker empty.
3. **`by` is one name list.** Key columns have the same name in both versions (a data cut keeps its names). `by` is
   a character vector of 1 to `sv_derive_max_pairs` (20) names. These are refused, each with an error reply:
   - an empty key: "Pick the key columns.";
   - a key column missing from a version: "Not in <table>: <col>";
   - `old == new`: "Pick two different tables.";
   - an unknown card, which uses D1's message;
   - more than 20 keys: D1's "A derived table takes at most 20 key pairs.";
   - a list column as a key: "Column <col> in <table> is a list column; it cannot be a key."
4. **Open travels as a derive.** Each Open sends `derive_request {op, inputs: [old, new], args: {by}}`, so old and
   new travel as `inputs`, as for every derive op. This refines build-note decision 1, which wrote
   `args: {old, new, by}`. R recomputes the plan at open time.
5. **Plan.** `sv_compare_plan(old, new, by)` returns a plain list, so it travels as JSON:
   - `by`;
   - `keys`, one entry per key column: `{name, kind_old, kind_new, text}`. `text` is TRUE when the kinds differ
     (decision 3 of the build notes);
   - `compared`, one entry per compared column, in new's column order: `{name, kind, from_old, from_new, zone_old,
     zone_new, tz_text_old, tz_text_new}`;
     - `from_*` is the column's D2 type name (`sv_stack_type()`), used to pick the text cast;
     - `zone_*` is the date-time zone;
     - `tz_text_*` is only filled for a lazy date-time (D2's `sv_stack_add_tz_text()` way). It adds about 20 KB per
       date-time column to saved state, as the build notes accept.
   - `type_changed`: a list of `{column, old, new}` with D2 type names (`lgl`, `int`, `num`, `chr`, `fct`, `date`,
     `dttm`, or the class for `other`). The text writes `date` as `Date` and `dttm` as `date-time`, so it reads
     "AESTDTC (chr -> Date)" as in spec 7.2;
   - `only_old`, `only_new`: column names;
   - `lazy`: TRUE when either input is lazy.

   The step stores `derived$args = list(by, plan)`. `derivedArrived` (sideview.js) refits a compare step's args from
   R's `d.args`, as it does for stack. `sv_derive_state_refresh()` refreshes compare steps as it refreshes stack
   steps.
6. **Summary fields** (the reply, and `sv_compare()`'s return value):
   - `old_name`, `new_name`, `by`, `n_old`, `n_new`;
   - `added`, `removed`, `changed`, `same`;
   - `repeated_keys` (distinct keys repeated in either version), `repeated_rows_old` and `repeated_rows_new` (the
     rows of that version whose key repeats in *either* version, so a key twice in old and once in new adds 2 and
     1), and `repeated_sample` (at most 5 keys, each a named list of key values);
   - `compared`, `type_changed`, `only_old`, `only_new` (from the plan);
   - `per_column`: a named integer vector (a JSON object on the wire) of changed rows per compared column, in new's
     order, with zero counts kept;
   - `changed_values`: the `_changed` card's row count, which is the sum of `per_column`;
   - `text` (from `sv_say_compare_text()`), and `open`: `{added, removed, changed}`, the three labels.
   - An Open button whose count is 0 is shown disabled, with its label unchanged ("Open added rows (0)").
7. **Text of a value** (`old` and `new` in `_changed`):
   - It uses D2's text casts: `sv_stack_cast_code(x, from, "chr", zone)` in memory and
     `sv_stack_lazy_cast(cn, from, "chr", zone)` lazy, so date-times are written `"%Y-%m-%d %H:%M:%S"` in the
     column's own zone. Factors are written as their labels.
   - A missing value (NA or NaN) is `NA_character_`, never `"NaN"`.
   - Known deviation (D2's): number text can differ between R and duckdb (`"1e+05"` vs `"100000"`). The twin test
     compares `old` and `new` of numeric columns after `as.numeric()`.
8. **Keys of differing kinds** join on text. Both sides get `.sv_k<i> = <text cast of the key>` columns (wrapped
   around each input with `dplyr::mutate()`), the forms of decision 9 use `.sv_k<i>` in place of those keys in
   `.by` and `by`, and `dplyr::select(-.sv_k1, ...)` drops them at the end.
   - In `_added` and `_removed` the original key columns keep their own types.
   - In `_changed` the original key columns are not join columns, so they come back suffixed. The `transmute()`
     writes `<key> = <key>.new`, so the key columns take new's values and types.
9. **Code forms** (one expression each, no pipe, so the pipe setting cannot change the text). Let `K` be
   `c("STUDYID", "USUBJID")` written with `encodeString()`, and `.sv_u(x)` stand for
   `dplyr::filter(x, dplyr::n() == 1L, .by = c(<K>))`, written out in full. The code never defines a helper.
   - **`_added`:** `dplyr::anti_join(<.sv_u(new)>, <old>, by = <K>, na_matches = "na")`. A key repeated in old is
     in old, so the anti join already leaves it out; a key repeated in new is left out by `.sv_u(new)`. Task 1's
     repeated-key test pins this.
   - **`_removed`:** the mirror: `dplyr::anti_join(<.sv_u(old)>, <new>, by = <K>, na_matches = "na")`.
   - **`_changed`:**
     ```
     local({
       .sv_both <- dplyr::inner_join(<.sv_u(old)>, <.sv_u(new)>, by = <K>, suffix = c(".old", ".new"),
                                     na_matches = "na")
       dplyr::arrange(dplyr::bind_rows(
         dplyr::transmute(dplyr::filter(.sv_both, <changed cond of col 1>), <keys>, column = "AESEV",
                          old = <text of AESEV.old>, new = <text of AESEV.new>),
         ...
       ), <key syms>)
     })
     ```
     - The changed condition is `!(is.na(a) & is.na(b)) & (is.na(a) | is.na(b) | a != b)`, with `a`/`b` the
       `.old`/`.new` columns. A factor or character pair compares `as.character()` values.
     - `dplyr::arrange()` is stable, so the key order is followed by the column order of `bind_rows()`.
     - With no compared column, the body is a zero-row tibble with the key columns of new, then `column`, `old`,
       `new` as character: `dplyr::transmute(dplyr::filter(.sv_both, FALSE), <keys>, column = NA_character_,
       old = NA_character_, new = NA_character_)`.
     - A key column that is also a compared name does not occur, because key columns are not compared. A non-key
       column present only in one version has no suffix, which is fine because it is not compared.
   - **Any input lazy:** both inputs go onto one duckdb connection with `crossBackend()`'s forms, as D2 does
     (a data frame is copied in with `dplyr::copy_to()`; Arrow goes through `arrow::to_duckdb()`). The kind is
     always `'duckdb'`.
     - The unique-key filter is the same `dplyr::filter(x, dplyr::n() == 1L, .by = ...)`. dbplyr writes it as a
       window, and Task 3 checks it runs on duckdb.
     - In the changed condition, a double column uses `(is.na(a) | isnan(a))` for "missing", never `is.nan()`.
     - Text casts are D2's lazy casts (decision 7). `dplyr::arrange()` is left out, because a lazy card has no
       order; the twins compare rows sorted.
     - `local()` is kept, so the code is one expression in both forms.
10. **Counting.** In memory, R uses the same steps as the code. Lazy, one `summarise()` query per count:
    - the unique-key tables (window filter) of each side;
    - `added` and `removed` are counts of the anti joins;
    - one `summarise()` over `.sv_both` gives `nrow(.sv_both)`, `changed` as `sum(<cond 1> | <cond 2> | ...)` and
      `per_column` as `sum(<cond>)` per column;
    - `same` is `nrow(.sv_both) - changed`;
    - `repeated_*` use `dplyr::count(.by = K)` with `n > 1`, summed, and the sample is `head(5)`.
11. **One builder pane for the drawer and the list view**, as D2 decision 11:
    - `compare` joins `DRAWER_TABS` (after `stack`) and `BUILDER_TABS` only when `hasR()`. The widget never draws
      it.
    - `movePanes()` moves the same pane into the list view's Compare host, under the Stack builder.
    - The list view's `BUILDERS` gets `['compare', 'Compare']` after `['stack', 'Stack']` when the engine has R.
12. **The picker** is two labelled `<select>`s ("Old version", "New version") of grid cards, and a key fieldset
    with a legend ("Key columns"): one checkbox per column in both versions, ticked from R's `by`. Changing either
    select clears `by`, so the next check asks R for a new suggestion. Ticking a key sends a new check with that
    `by`. Check is disabled until two different cards are picked.

## Review Focus

1. **NaN against NA and against a number, lazy vs in memory.**
   - duckdb says `NaN IS NULL` is false and `NaN = NaN` is true.
   - Expected: NaN in both, or NaN against NA, is the same; NaN against 1 is changed; the text is NA. The same in
     both backends.
   - Test: Task 1 (`"NA and NaN compare as missing"`) and Task 3 (`"lazy NaN agrees"`).
2. **A key with NA on both sides** (`AESEQ = NA` in old and new).
   - Expected: the rows match (NA matches NA, as the join check), and count as same or changed; never as one added
     plus one removed.
   - Test: Task 1, Task 3 and the Task 4 code twin.
3. **A key repeated in one version only** (two rows of key 7 in new, one in old).
   - Expected: key 7 is in no card and no count. `repeated_rows_new = 2` and `repeated_rows_old = 1`, and both
     identities hold.
   - Test: Task 1 (`"repeated keys leave every count"`), Task 4's code twin.
4. **Non-syntactic names:** a card `wave 2`, a key `` `visit id` `` and a compared column `` `visit date` ``.
   - Expected: the code parses and rebuilds each card. The names are `wave.2_added` and so on. The `column` value
     is the plain name `visit date`.
   - Test: Task 4.
5. **Zero-row and identical versions; factor against character.**
   - Expected: identical versions give `same = nrow`, zero cards' Open buttons disabled. Zero-row old gives every
     new row as added. A factor column against the same values as character is compared, not type changed, and
     gives no changed rows.
   - Test: Task 1 in memory, Task 3 over duckdb.

---

### Task 1: R compare in memory, `sv_compare()`

**Files:**
- Create: `R/compare.R`
- Create: `tests/testthat/test-compare.R`
- Modify: `R/say.R` (the compare text functions)

**Interfaces:**
- Consumes: `sv_key_kind()` (R/diagnostics.R), `sv_stack_type()` and `sv_stack_cast()` (R/stack.R),
  `sv_derive_max_pairs` (R/derive.R).
- Produces:
  - `sv_compare_plan(old, new, by, old_name = "old", new_name = "new")` (internal): decision 5's list. It errors with
    decision 3's messages. Task 3 adds a lazy branch with the same return value.
  - `sv_compare_rows(old, new, plan)` (internal): `list(added, removed, changed, summary)`, three data frames and
    decision 6's fields, all in memory.
  - Exported `sv_compare(old, new, by = NULL)`.
    - The names come from the call's expressions (`deparse(substitute())`), as `sv_stack_check()` names them.
    - `by = NULL` uses `sv_compare_key()` on two plain data frames, without CDISC tags; if it gives no key, the
      error is "Pick the key columns."
    - It returns class `sv_compare`: decision 6's fields, plus `added`, `removed` and `changed` (data frames), and
      `code` (a list of three strings, filled by Task 2).
  - `print.sv_compare()`: prints `text`, then one line per card: "added: 52 rows" and so on.
  - `sv_compare_key(old, new, old_tag = NULL, new_tag = NULL)` (internal): decision 2.
  - In `R/say.R`:
    - `sv_say_compare_text(s)` gives the lines of the Global Constraints sample. "none" fills an empty list. The
      "Changed values by column" line lists only columns with a count above 0, highest first, ties in new's order.
      The "Warnings" line is left out when no key repeats.
    - `sv_say_compare_open(s)` gives `list(added, removed, changed)`, the three button labels.

- [ ] **Step 1: Write the failing tests** in `test-compare.R`, on synthetic `cut1` / `cut2` data frames with a
  key `USUBJID` + `AESEQ` and columns `AESEV` (chr), `AEDY` (int in cut1, double in cut2), `AESTDTC` (chr in cut1,
  Date in cut2), `ONLY1` and `ONLY2`:
  - `test_that("added, removed, changed and same by key")`: exact counts, and the three data frames:
    - `added` has new's columns and only new keys; `removed` has old's columns;
    - `changed` has columns `USUBJID`, `AESEQ`, `column`, `old`, `new`, ordered by key then by new's column order;
    - `per_column` is `c(AESEV = 2L, AEDY = 1L)`.
  - `test_that("both identities hold")` on every fixture in this file:
    `added + changed + same + repeated_rows_new == n_new` and `removed + changed + same + repeated_rows_old == n_old`.
  - `test_that("repeated keys leave every count")`: repeated in old only, new only, and both. Review Focus 3.
    `repeated_sample` holds at most 5 keys when 7 repeat.
  - `test_that("NA and NaN compare as missing")`: Review Focus 1 in memory: NA/NA, NaN/NaN and NA/NaN are the same;
    NA/1 and NaN/1 are changed; `old` is `NA_character_` for both.
  - `test_that("a key with NA matches")`: Review Focus 2.
  - `test_that("type changes are listed, not compared")`: `type_changed` is
    `list(list(column = "AESTDTC", old = "chr", new = "date"))`; `AESTDTC` is not in `per_column`.
  - `test_that("integer and double compare by value")`: `AEDY` 3L vs 3 is the same, 3L vs 4 is changed.
  - `test_that("factor and character compare")`: Review Focus 5.
  - `test_that("keys of differing kinds compare as text")`: `AESEQ` int in old, chr in new; `"1"` matches `1L`;
    `_added` keeps new's `chr` key.
  - `test_that("empty and identical versions")`: Review Focus 5.
  - `test_that("bad keys are refused")`: each message of decision 3.
  - `test_that("key suggestion")`: two AE-tagged cards give the natural key kept to shared columns; untagged ones
    give the shared-name key; no shared column gives `character(0)`.
  - `test_that("text and labels")`: `expect_snapshot(print(sv_compare(cut1, cut2, by = c("USUBJID", "AESEQ"))))`,
    and `sv_say_compare_open()` gives `"Open changed values (3 rows)"` for 3 changed rows.
- [ ] **Step 2: Run them and see them fail.** Run `devtools::test(filter = "compare")`. Expected: FAIL, "could not
  find function".
- [ ] **Step 3: Implement** `sv_compare_key()`, `sv_compare_plan()` (in-memory branch), `sv_compare_rows()`,
  `sv_compare()`, the print method and the two `sv_say_compare_*` functions. Compute the rows with the same dplyr
  steps as decision 9's code forms, so Task 2's twin test can hold the code to them.
- [ ] **Step 4: Run them and see them pass.** Run `devtools::test(filter = "compare")`. Expected: PASS.
- [ ] **Step 5: Commit.** Run `devtools::document()` and add `sv_compare` to `_pkgdown.yml`. Commit with
  "feat: compare two cuts by key and sv_compare()".

### Task 2: The three compare derive ops and the R code writer

**Files:**
- Modify: `R/compare.R`, `R/derive.R`, `tests/testthat/test-compare.R`, `tests/testthat/test-derive.R`

**Interfaces:**
- Consumes: Task 1's `sv_compare_plan()` and `sv_compare_rows()`. D1's `sv_derive_clean()`, `sv_derive_name()`,
  `sv_derive_card()`, `sv_derive_rows()`, `sv_derive_scalar()` and `sv_derive_clean_by()`. D2's
  `sv_stack_card_tables()` and `sv_stack_cast_code()`.
- Produces:
  - `sv_compare_code(plan, refs, kinds, op)` (internal). It returns `list(code, kind)`. `refs` has 2 R references
    (old, new) as JS `refFor()` gives them, `kinds` has `NA`, `"duckdb"` or `"arrow"` per input, and `op` is one of
    the three ops. The forms are those of decision 9; this task writes the in-memory form, Task 3 the lazy form.
  - `sv_compare()` fills `code` with `sv_compare_code()` on the call's expressions.
  - `sv_compare_clean(old, new, by, store, con_env = NULL, card_full = sv_card_is_lazy)` (internal): the one cleaner
    for both `compare_request` (Task 5) and the derive ops. It returns `list(inputs, cards, by, plan)` and errors
    with decision 3's messages. It names only store cards.
  - In `R/derive.R`:
    - `"compare_added"`, `"compare_removed"` and `"compare_changed"` are appended to `sv_derive_ops`.
    - `sv_derive_clean()` dispatches the three ops to `sv_compare_clean()` before the 2-input path. Its `args`
      allowlist is `by` only (a list of scalar strings through `sv_derive_scalar()`).
    - `sv_derive_name()` gives `<old>_removed`, `<new>_added` and `<new>_changed`.
    - `sv_derive_card()` builds the card from `sv_compare_rows()`, stores `derived$args = list(by, plan)`, and sets
      the CDISC tag by the Global Constraints rule. `col_labels` keep the source card's labels for `_added` and
      `_removed`; `_changed` has none.

- [ ] **Step 1: Write the failing tests:**
  - In `test-compare.R`, `test_that("in-memory code parses, runs with dplyr only and rebuilds")`: for each op,
    `code <- sv_compare(cut1, cut2, by = K)$code[[op]]`; `expect_parses(code)`; `eval()` it in
    `list2env(list(cut1 = cut1, cut2 = cut2), parent = baseenv())` and `expect_equal()` it with the matching data
    frame of `sv_compare()`, for the fixtures of Review Focus 2, 3 and 5 and the differing-kinds key.
  - In `test-derive.R`:
    - `test_that("compare derive cards: names, rows, tags, args")`: `sv_derive_card()` for each op on store cards
      `cut1`, `cut2` gives `cut1_removed`, `cut2_added`, `cut2_changed`; `dims[1]` equal to the summary counts
      (`changed_values` for `_changed`); `derived$args$plan$by` equals `by`; with AE tags on both, `_removed` and
      `_added` are AE and `_changed` has no tag; a second open gives `cut2_added_2`.
    - `test_that("compare requests are cleaned")`: an empty `by`, a missing key column, `old == new`, an unknown
      input, 21 keys, an extra `args` field and a non-string key each give their message, and the store is
      unchanged.
- [ ] **Step 2: Run them and see them fail.** Run `devtools::test(filter = "compare|derive")`. Expected: FAIL.
- [ ] **Step 3: Implement** `sv_compare_code()` (in-memory form), `sv_compare_clean()` and the `R/derive.R`
  branches. Strings in the code go through `encodeString(x, quote = '"')`, and names through `sv_escape_ident()`,
  as `sv_stack_code()` does.
- [ ] **Step 4: Run them and see them pass.** Expected: PASS, with D1's and D2's derive tests still green.
- [ ] **Step 5: Commit** with "feat: compare derive ops and their code".

### Task 3: Lazy compare: plan, counts, cards and code

**Files:**
- Modify: `R/lazy.R`, `R/compare.R`, `tests/testthat/test-lazy.R` (a new block)

**Interfaces:**
- Consumes: `sv_lazy_place_n()`, `sv_stack_lazy_cast()`, `sv_stack_add_tz_text()`, `sv_stack_zero_df()`,
  `sv_lazy_zones()`, `sv_lazy_factors()`, `sv_derived_source()` and `sv_lazy_derived_tbl()`.
- Produces:
  - `sv_lazy_compare_plan(old, new, by, con_env)`: the same return value as `sv_compare_plan()`, with kinds from
    `collect(head(tbl, 0))` of the duckdb placement (factor levels and zones put back), and `tz_text` filled for
    date-time compared columns. `sv_compare_plan()` dispatches to it when either input is lazy.
  - `sv_lazy_compare(old, new, plan, con_env, op = NULL)`. With `op = NULL` it returns decision 6's summary (counts
    by decision 10, nothing collected). With an op it returns the duckdb tbl of that card, with the attributes
    `sv_tz`, `sv_factors` and `sv_cleanup`, as `sv_lazy_stack()` does.
  - `sv_lazy_derived_tbl()` dispatches the three compare ops to `sv_lazy_compare()`. A compare card's `source` is
    `sv_derived_source(op, args, inputs)`.
  - `sv_compare_code()` writes the lazy form when either `kinds` is not NA.
  - `sv_compare()` is lazy in, lazy out: its `added`, `removed` and `changed` are duckdb tbls.

- [ ] **Step 1: Write the failing tests** in `test-lazy.R`, with `dc_fixture()`-style setup for the kinds `df`,
  `duckdb` and `arrow`:
  - `test_that("lazy compare equals in-memory compare")`: for the kind pairs `c("duckdb","duckdb")`,
    `c("arrow","arrow")`, `c("df","duckdb")` and `c("arrow","df")`:
    - every summary field equals the in-memory one (`tolerance = 1e-12`);
    - the rows of each card, collected and sorted, equal the in-memory card sorted; `old` and `new` of numeric
      columns are compared after `as.numeric()`.
  - `test_that("lazy NaN agrees")`: Review Focus 1 over duckdb and Arrow.
  - `test_that("lazy keys: NA, repeats and differing kinds")`: Review Focus 2 and 3 and the text key, over duckdb.
  - `test_that("date-times become text in their zone")`: a POSIXct column in `"Asia/Singapore"` that changes gives
    the same `old` / `new` text as in memory.
  - `test_that("lazy compare is never collected")`: test-lazy.R's collect trap; the summary, the three cards and
    their row counts pass without collecting.
  - `test_that("two duckdb connections are refused")`: `expect_error(..., class = "sv_lazy_cross_con")`.
  - `test_that("zero-row lazy version")`: Review Focus 5 over duckdb.
- [ ] **Step 2: Run them and see them fail.** Run `devtools::test(filter = "lazy")`. Expected: FAIL in the new
  block only.
- [ ] **Step 3: Implement** the lazy plan, counts, cards and code form. Write each lazy expression once, as an
  `rlang` expression that `sv_lazy_compare()` evaluates and that the code prints with `sv_stack_show()`, as D2 does.
  The error text of `sv_lazy_place_n()` names "the stack"; pass the word in (a `what = "stack"` argument) so compare
  says "These tables are on different duckdb connections; compare unavailable."
- [ ] **Step 4: Run them and see them pass.** Run `devtools::test(filter = "lazy|compare|stack|derive")`.
  Expected: PASS.
- [ ] **Step 5: Commit** with "feat: lazy compare on duckdb".

### Task 4: Pipeline compare steps and their code (JS), with the twin tests

**Files:**
- Modify: `inst/www/sv-pipeline.js`, `inst/www/sideview.js` (`derivedArrived` only), `R/derive.R`
  (`sv_derive_state_refresh()`)
- Modify: `tests/testthat/test-derive-code.R`, `tests/testthat/test-compare.R` (byte-equal block),
  `tests/testthat/test-pipeline.R`

**Interfaces:**
- Consumes: the plan shape (Task 1 and 3), `sv_compare_code()` (Tasks 2 and 3), D1's `deriveStep()`,
  `deriveLive()`, `deriveExpr()`, `compose()`, `refFor()`, `lazyKind()` and `crossBackend()`, and D2's
  `stackCastCode()`, `stackLazyCast()`, `stackQid()`, `stackSql()`, `ident()` and `str()`.
- Produces:
  - `Pipeline.deriveLive(step)`: the compare ops need exactly 2 live inputs, as the other 2-input ops.
  - `Pipeline.deriveExpr(step)` for the three ops returns `{code, kind}` from `step.args.plan`. `kind` is `null` in
    memory, else `'duckdb'`. It returns `{code: '', kind: null}` when there is no plan.
  - The step labels are `'added rows of ' + new + ' vs ' + old`, `'removed rows of ' + old + ' vs ' + new` and
    `'changed values of ' + new + ' vs ' + old`, both in sv-pipeline.js and in the engine's step kind labels.
  - `derivedArrived` refits the step args from R's `d.args` for the compare ops, as for `stack`.
  - `sv_derive_state_refresh()` refreshes `args` of compare steps as for stack steps.

- [ ] **Step 1: Write the failing tests:**
  - In `test-compare.R`, `test_that("R and JS write the same compare code")`: for a matrix of plans (a plain key,
    a two-column key, a differing-kinds key, no compared column, a date-time column, a factor column, the names of
    Review Focus 4) and kind pairs (both in memory; duckdb + duckdb; arrow + arrow; df + duckdb; arrow + df), and
    each op, the JS `deriveExpr({kind: 'derive', op, table, inputs, args: {by, plan}})` through
    `run_pipeline_js()` equals `sv_compare_code(plan, refs, kinds, op)$code` byte for byte.
  - In `test-derive-code.R`, `test_that("compare code rebuilds the cards")`: for the kind pairs of Task 3 and each
    op, compose in node, `expect_parses()`, eval on `fx$objs`, and expect the rows, sorted and collected, to equal
    those of `dc_card(fx, op, c("cut1", "cut2"), list(by = K))`. Review Focus 2, 3 and 4 are in the matrix.
  - In `test-pipeline.R`:
    - the three steps of one pair are live, and none is live when an input is gone;
    - `compose()` writes them in the order they were added, before the chains;
    - undo removes the last, and redo brings it back with the same `args`;
    - a state round trip (`getState()` then `applyState()` in node) keeps `args.plan`.
  - In `test-derive.R`:
    - `test_that("state refresh refits compare args")`: a state whose compare step holds a stale plan gets R's
      plan after `sv_derive_state_refresh()`;
    - `test_that("a saved state rebuilds the compare cards")`: a state with all three compare steps, opened with
      `sv_derive_from_state()`, rebuilds three cards with the same names and `dims` as before the save.
- [ ] **Step 2: Run them and see them fail.** Run `devtools::test(filter = "compare|derive-code|pipeline|derive")`.
  Expected: FAIL.
- [ ] **Step 3: Implement** the compare branch. Port `sv_compare_code()`'s forms with the existing helpers. Run
  `node --check inst/www/sv-pipeline.js` and `node --check inst/www/sideview.js`.
- [ ] **Step 4: Run them and see them pass.** Expected: PASS.
- [ ] **Step 5: Commit** with "feat: pipeline compare steps and code twin".

### Task 5: Server: `compare_request`, the compare derive path, module refusals

**Files:**
- Modify: `R/app_server.R`, `tests/testthat/test-module.R`, `tests/testthat/test-derive.R` (the gadget `testServer`
  block), `CLAUDE.md` (the inputs and messages list)

**Interfaces:**
- Consumes: `sv_compare_clean()`, `sv_compare_key()`, `sv_compare_rows()` / `sv_lazy_compare()`,
  `sv_compare_code()`, `sv_say_compare_*()`, and D1's `derive_request` handler, which takes the three ops unchanged.
- Produces:
  - An input `compare_request {id, old, new, by?}`.
  - A message `sideview_compare {id, by, ...decision 6 fields, text, open, code_preview}`, or `{id, error, by?}`.
    It carries `ns` in module mode through `send()`. `code_preview` is
    `list(added, removed, changed)`, from `sv_compare_code()` on the store's refs and kinds.
  - The handler follows `stack_check_request` (R/app_server.R): `rid` through `sv_derive_scalar(id, 200)` (a
    missing id gives a toast), the body in a `tryCatch` that returns `list(error =)`, lazy cards through
    `lazy_or_preview()`, and the reply through `dispatch_message("sideview_compare", result)`. The key suggestion
    uses the cards' CDISC tags.

- [ ] **Step 1: Write the failing tests:**
  - In the gadget `testServer`:
    - a check for `cut1`, `cut2` without `by` replies with the suggested `by`, the counts, the text lines and three
      code previews that parse;
    - a check with `by = "USUBJID"` only replies with that key;
    - Open (`derive_request` with `op = "compare_changed"`, `inputs = list("cut1", "cut2")`, `args = list(by = K)`)
      adds a card whose `dims[1]` is the reply's `changed_values`.
  - In the module tests, `test_that("forged compare requests are refused")`:
    - `old` naming `Sys.getenv`, a non-store name, `old == new`, a key `"x; system('id')"`, 10,000 keys and a list as
      `by` each get an `{id, error}` reply;
    - a compare `derive_request` with the same inputs is refused too;
    - `card_store$names()` is unchanged, and no other message is sent.
- [ ] **Step 2: Run them and see them fail.** Run `devtools::test(filter = "module|derive")`. Expected: FAIL.
- [ ] **Step 3: Implement** the handler. Add `compare_request` and `sideview_compare` to `CLAUDE.md`'s list, in the
  form the list uses for others.
- [ ] **Step 4: Run them and see them pass.** Expected: PASS.
- [ ] **Step 5: Commit** with "feat: compare_request handler".

### Task 6: Engine: the Compare drawer tab (canvas)

**Files:**
- Modify: `inst/www/sideview.js`, `inst/www/sideview.css`, `tests/testthat/test-layout-browser.R`,
  `tests/testthat/test-a11y-browser.R`, `tests/testthat/test-widget.R` (no tab)

**Interfaces:**
- Consumes: `sideview_compare` (Task 5), D1's `requestDerive(offer)` with
  `offer = {op, inputs: [old, new], args: {by}, n, label}`, `derivedArrived()`, `announce()`, `onMessage()` and
  `send()`. The Stack tab's code (`renderStackBuilder`, `requestStackCheck`, `onStackCheck`, `stackOpen`,
  `stackId`) is the pattern.
- Produces:
  - `{id: 'compare', label: 'Compare'}` in the drawer tabs after `stack`, and `compare` in `BUILDER_TABS`, both only
    when `hasR()`.
  - `SideviewEngine.prototype.renderCompareBuilder(pane)`, which draws:
    - the picker of decision 12;
    - a Check button;
    - after a reply, the `text` lines; a `<table>` with a `<caption>` ("Changed values by column") and
      `<th scope="col">` headers (Column, Changed rows) from `per_column`; the three `<pre>` code previews in a
      `<details>`;
    - the three Open buttons with R's `open` labels, disabled at count 0;
    - an error reply shows its text in the pane and keeps the picker.
  - `SideviewEngine.prototype.requestCompareCheck(old, new, by)` with decision 1's id. A reply whose `id` is not the
    latest is ignored.
  - The state is kept on the engine (`this._compare = {old, new, by, reply}`), so a re-render or `movePanes()` keeps
    it. A card removed from the canvas clears `old` or `new` and the reply. Focus returns to the control that sent
    the check (`data-compare-key`), as in the Stack tab.
  - Pressing an Open button twice zooms to the existing card (D1 decision 4).

- [ ] **Step 1: Write the failing tests:**
  - In `test-layout-browser.R`, `test_that("Compare tab: pick, check, open")`, with real mouse input
    (`b$Input$dispatchMouseEvent`) and the D2 helpers (`sv_stk_click`, `sv_stk_open_tab`):
    - open the Compare tab, pick `cut1` as old and `cut2` as new, and press Check;
    - the key boxes `USUBJID` and `AESEQ` are ticked, and the text has "added 1 · removed 1";
    - untick `AESEQ` and see the text change (repeated keys appear);
    - tick it again, press "Open changed values"; the new card `cut2_changed` does not overlap any card, and its
      row badge equals `changed_values`;
    - at 1400×900, 1024×700 and 560×520 the pane does not overflow the drawer horizontally.
  - In `test-a11y-browser.R`, `test_that("Compare tab passes axe")`:
    - `sv_axe_run()` after a reply gives no violations;
    - every `select` and checkbox has a name (`sv_ax_unnamed()` is empty);
    - the announcement "Table cut2_changed added, N rows." is in the live region.
  - In the widget tests, `sideview_widget(cut1, cut2)` has no `[data-sv-tab="compare"]`. Opening a state that holds a
    compare step shows the step disabled with D1's toast.
- [ ] **Step 2: Run them and see them fail** with `NOT_CRAN=true`. Run
  `devtools::test(filter = "layout-browser|a11y-browser|widget")`. Expected: FAIL in the new tests.
- [ ] **Step 3: Implement** the tab, the builder, the handler and the CSS, following the Stack tab's markup and
  tokens. Run `node --check inst/www/sideview.js`.
- [ ] **Step 4: Run them and see them pass.** Expected: PASS. Also check the tab by eye in the built-in browser, in
  light and dark themes.
- [ ] **Step 5: Commit** with "feat: Compare drawer tab".

### Task 7: List view Compare builder

**Files:**
- Modify: `inst/www/sv-listview.js`, `tests/testthat/test-a11y-browser.R` (where the list view builder tests live)

**Interfaces:**
- Consumes: Task 6's pane and the `movePanes()` path (decision 11).
- Produces: `['compare', 'Compare']` in the list view's `BUILDERS`, after `['stack', 'Stack']`, when
  `engine.hasR()`. The heading `sv-lv-b-compare` is focusable as the others are.

- [ ] **Step 1: Write the failing test** `test_that("list view Compare builder matches the drawer")`. Switch to the
  list view, pick and check with the keyboard only (`sv_key()` / `sv_tab()`), and expect:
  - the text lines and the per-column table cells equal those the drawer showed for the same picks;
  - Open adds the card, and returning to the canvas shows it.
- [ ] **Step 2: Run it and see it fail** with `NOT_CRAN=true`. Expected: FAIL.
- [ ] **Step 3: Implement.** Run `node --check inst/www/sv-listview.js`.
- [ ] **Step 4: Run it and see it pass.** Expected: PASS.
- [ ] **Step 5: Commit** with "feat: list view Compare builder".

### Task 8: Version 0.10.0, docs and the full check

**Files:**
- Modify:
  - `DESCRIPTION` (Version: 0.10.0);
  - `NEWS.md` (the 0.10.0 heading holds D1, D2 and D3; date it when the PR is made);
  - `README.md` (one Key Features bullet: "**Compare Data Cuts**: `sv_compare()` and the Compare tab count rows
    added, removed and changed by key, list type changes, and open each set of rows as a card");
  - the derived-cards article ("Unmatched rows, stacking and comparing data cuts"): a comparing section with two
    synthetic AE cuts;
  - `CLAUDE.md`: the compare twin rule next to the stack twin rule: `sv_compare_code()` and `deriveExpr()` are
    byte-equal, `sv_compare_plan()` / `sv_lazy_compare_plan()` and `sv_compare_rows()` / `sv_lazy_compare()` are
    twins, and all are tested;
  - `MEMORY.md` (the change log and the roadmap task list: D3 in review);
  - `docs/` (a rebuilt site, with `docs/CLAUDE.*` and `docs/MEMORY.*` and their `sitemap.xml` / `search.json`
    entries dropped).

- [ ] **Step 1:** Write the docs and bump the version. Run `pkgdown::check_pkgdown()`. Expected: no problems.
- [ ] **Step 2:** Run the full suite in the background with `NOT_CRAN=true`. Expected: 0 failures, and no new skips
  beyond the known ones.
- [ ] **Step 3:** Run `devtools::check()`. Expected: 0 errors, 0 warnings, 0 new notes.
- [ ] **Step 4:** Rebuild the site, drop the dev notes, and commit with "docs: D3 compare: NEWS, README, article,
  CLAUDE.md; version 0.10.0".
- [ ] **Step 5:** Record in `MEMORY.md` what was verified in a real browser. List the RStudio checks still to do
  (dialog, Viewer pane, external browser): pick, check, change the key, Open each card, then Save and Open the
  state, with in-memory, Arrow and duckdb cuts. They are recorded only after the user says they did them.
