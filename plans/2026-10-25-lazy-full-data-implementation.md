# Full data for arrow and duckdb cards: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sort, filter, scroll, the join check, the column inspector and the codebook use the whole table for arrow
and duckdb cards. They run through duckdb and never collect the table. When only the 50-row preview can be used,
the UI says so.

**Architecture:** The card keeps its lazy object in a new `source` field. All lazy logic lives in a new
`R/lazy.R`: lazy twins of `sv_rows_window()`, `sv_join_diagnostics()` and `sv_column_profile()`, plus one private
duckdb connection per Shiny session. The exported functions and the four server handlers dispatch to the twins.
`sv-pipeline.js` learns which tables are lazy and emits correct lazy code ending in one `collect()`.

**Tech Stack:**
- R 4.5.2 with dplyr, dbplyr 2.5.1, duckdb 1.4.3, DBI 1.3.0, arrow 23.0.0.1, rlang and stringr
- testthat 3 and shiny::testServer
- chromote for the real-browser tests
- node for the JS tests

**Spec:** `plans/2026-10-25-lazy-full-data-design.md`. Read it with this plan.

## Global Constraints

**Dependencies**
- duckdb, dbplyr, DBI and arrow stay in `Suggests:`, behind `requireNamespace()`. Add `stringr` to `Suggests:`.
- A lazy table is never collected by sideview. Only summaries, row windows and a 0-row `collect(head(tbl, 0))`
  (to learn R column classes) come back into R.
- Data-frame behaviour and output are unchanged, except for the new codebook column `rows_profiled`.
- Lazy results must equal the in-memory functions on the same data: `expect_equal(tolerance = 1e-12)`, which is
  exact for text.

**Fixed text**
- `"These tables are on different duckdb connections; join check unavailable."`
- `"First 50 of 1,234,567 rows"`, with the tooltip `"Install duckdb to check the whole table"`.
  The 50 is the preview row count and the big number is `dims[1]`; both use a comma big mark.
- `"Based on the first 50 rows"`
- `"Lost the link to visits_db; showing the first 50 rows."`
- `"Checking the whole table…"`
- `"Profiling visits_db: column 40 of 200"`
- `"This step may need data in R: move collect() above it."`
- `"(ranges from the first 50 rows)"`

**Data, privacy and wire format**
- Synthetic fixtures only.
- Only the schema goes to the LLM, never rows.
- `source` is never serialised: not in widget JSON, not in state, not in card attributes.

**Project conventions**
- Inline SVG icons only; no emoji or Unicode glyph icons.
- CSS uses `--sv-*` tokens, and every rule is scoped under `.sideview-container`.
- JS escapes table-derived text before `innerHTML`.
- Every generated line of R code must `parse()`.
- Keep the CLAUDE.md lists of inputs and messages in sync. This plan adds one custom message, `sideview_toast`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

**Commands**
- Run R with `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"` (written as `Rscript` below).
- Unit tests: `Rscript -e "devtools::test(filter = '<name>')"`
- Browser tests: set `NOT_CRAN=true`.

## Deviations from the spec (decided while planning)
- **No arrow reshape rule.** The pipeline has no reshape or pivot step; the builders are filter, arrange, mutate,
  recode and summarise. Task 9 instead runs every existing step kind on duckdb and arrow.
- **`rows_profiled` is a codebook column only.** The join check reply already carries `n_x`/`n_y`, and the
  inspector reply carries `n`. The browser compares those with the card's true row count to decide on the
  "Based on the first 50 rows" banner, so no extra reply field is needed.
- **Codebook `n` for preview-only cards.** `n` is the table's true row count and `rows_profiled` is the number of
  rows profiled. `n_missing`, `pct_missing` and the rest describe the profiled rows. For data frames and full lazy
  cards, `n == rows_profiled`.
- **Connection lifetime.** The private connection is created per Shiny session and closed in
  `session$onSessionEnded()`. A reload opens a new session, so nothing leaks. This matches the spec's intent for
  `onStop()`.

## Review Focus
1. **Whitespace other than spaces.** R's `trimws()` strips `[ \t\r\n]`, but duckdb's `trim(v)` strips only spaces.
   Lazy trims must use `trim(v, ' \t\r\n')`. Tested in Task 5 (issues) and Task 4 (trim hint).
2. **Contains filter on a numeric column.** The lazy path uses `str_detect(as.character(col), fixed(value))`.
   Parity holds for integer columns, and that is tested in Task 3. Doubles cast differently (`"130.0"` in duckdb
   versus `"130"` in R); this is documented in NEWS and in the tour's "Big tables" section.
3. **The user's connection is left clean.**
   - A join check registers arrow tables and data frames on the user's duckdb connection only temporarily.
   - After success *and* after an error, `DBI::dbListTables(con)` must equal what it was before.
   - Tested in Task 4.
4. **The user closes their connection mid-session.**
   - The handler answers from the preview and sends one toast.
   - Later requests for that card use the preview with no second toast.
   - The app stays up.
   - Tested in Task 7 with `testServer`.
5. **Zero-row and all-NA lazy tables.** These produce the same profile, join diagnostics and empty window as the
   data-frame functions, with no SQL error. Tested in Tasks 3, 4 and 5.

---

### Task 1: Card `source`/`code_ref`, `sv_has_duckdb()`, never serialised

**Files:**
- Create: `R/lazy.R` (top of file only)
- Modify:
  - `R/normalize.R:30-77` (`new_sideview_card`), plus the real-arrow and real-duckdb branches (≈ lines 235-300 and 386-478)
  - `R/widget.R:100-120`
  - `R/state.R` (no change expected; covered by the test)
- Test: `tests/testthat/test-lazy.R` (new)

**Interfaces:**
- `new_sideview_card()` gains `source = NULL` and `code_ref = NULL`. It stores `card$source` and `card$code_ref`;
  `code_ref` defaults to `name`.
  - The existing `is_lazy` (logical) and `lazy_source` (`"arrow"`/`"duckdb"`) fields stay and keep their meaning.
- Real arrow objects and real `tbl_duckdb_connection` objects set `source = x`.
- A whole `duckdb_connection` sets:
  - `source = dplyr::tbl(x, tbl_name)`;
  - `code_ref = sprintf('dplyr::tbl(%s, "%s")', <deparsed argument expression>, tbl_name)`, where the expression
    comes from `sv_normalize(..., name =)` callers via a new `expr` argument, defaulting to the card name.
- Mock list objects (with `raw$data`) keep `source = NULL`.
- `sv_has_duckdb() -> logical(1)`: `isTRUE(getOption("sideview.use_duckdb", TRUE))` and
  `requireNamespace()` for duckdb, dbplyr and DBI. The option is the switch the browser tests use in a background
  process; unit tests may mock the function instead.
- `sv_card_is_lazy(card) -> logical(1)`: `!is.null(card$source) && sv_has_duckdb()`. Arrow sources also need
  `requireNamespace("arrow")`.
- `sideview_widget()` sets these before serialising:
  - `card$source <- NULL`;
  - `card$lazy <- if (isTRUE(card$is_lazy)) card$lazy_source else NULL`;
  - `card$codeRef <- card$code_ref`;
  - `card$totalRows <- card$dims[1]`.

- [ ] **Step 1: Write failing tests** in `test-lazy.R`, inside a `skip_if_not_installed("duckdb"); skip_if_not_installed("arrow")` block:
  - `test_that("lazy cards keep their source")`:
    - `sv_normalize(dplyr::tbl(con, "v"), name = "v")$source` inherits `"tbl_duckdb_connection"`;
    - `sv_normalize(arrow::arrow_table(df), name = "a")$source` inherits `"ArrowTabular"`;
    - `sv_normalize(df)$source` is `NULL`;
    - `$code_ref` equals the name.
  - `test_that("a whole connection gets a tbl() code_ref")`: `sv_normalize(con, name = "con")$code_ref == 'dplyr::tbl(con, "v")'`.
  - `test_that("source is never serialised")`:
    - build `w <- sideview_widget(v = dplyr::tbl(con, "v"))`;
    - `expect_null(w$x$cards[[1]]$source)`, `expect_identical(w$x$cards[[1]]$lazy, "duckdb")` and
      `expect_identical(w$x$cards[[1]]$totalRows, nrow(df))`;
    - `jsonlite::toJSON(w$x, auto_unbox = TRUE, force = TRUE)` succeeds and does not contain `"source"`;
    - `sv_state_json()` of a state built from those cards does not contain `"source"`.
  - `test_that("sv_card_is_lazy respects the option")`: `withr::local_options(sideview.use_duckdb = FALSE)` gives
    `FALSE` for a duckdb card.
- [ ] **Step 2: Run them and see them fail.** Run `Rscript -e "devtools::test(filter = 'lazy')"`. Expected: FAIL (`source` is NULL; `sv_has_duckdb` not found).
- [ ] **Step 3: Implement the fields, the two helpers and the widget scrub.**
- [ ] **Step 4: Run the lazy, normalize, widget and state tests.** Expected: PASS.
- [ ] **Step 5: Commit** with the message `feat(lazy): cards keep their lazy source (never serialised)`.

### Task 2: Private connection, `sv_lazy_tbl()`, attach/detach

**Files:**
- Modify: `R/lazy.R`
- Test: `tests/testthat/test-lazy.R`

**Interfaces:**
- `sv_lazy_env() -> environment`: a new environment holding `con = NULL` and `tbls = list()`. There is one per
  session.
- `sv_lazy_con(con_env) -> duckdb_connection`: opens `DBI::dbConnect(duckdb::duckdb())` on first use and caches it.
- `sv_lazy_close(con_env)`:
  - calls `DBI::dbDisconnect(con, shutdown = TRUE)` on the private connection only, then sets it to `NULL`;
  - is safe to call twice.
- `sv_lazy_tbl(source, con_env, key = NULL) -> tbl_duckdb_connection`:
  - a duckdb tbl is returned as is;
  - an arrow object becomes `arrow::to_duckdb(source, con = sv_lazy_con(con_env), auto_disconnect = FALSE)`,
    cached in `con_env$tbls[[key]]` when `key` is given.
- `sv_lazy_attach(df, con) -> list(tbl, name)`:
  - calls `duckdb::duckdb_register(con, name, df)` with `name = paste0("sv_tmp_", <8 random hex>)`;
  - `tbl` is `dplyr::tbl(con, name)`.
- `sv_lazy_detach(con, name)`: `duckdb::duckdb_unregister(con, name)`, wrapped in `try`.
- `sv_lazy_detach_arrow(con, name)`: `duckdb::duckdb_unregister_arrow(con, name)`, wrapped in `try`. It undoes a
  `to_duckdb()` on a user connection; the table name is `dbplyr::remote_name()`.

- [ ] **Step 1: Write failing tests.**
  - `"private connection opens once and closes"`:
    - two `sv_lazy_con(e)` calls are `identical()`;
    - after `sv_lazy_close(e)`, `e$con` is `NULL`;
    - a second `sv_lazy_close(e)` does not error.
  - `"sv_lazy_tbl converts arrow and caches by key"`:
    - `dplyr::collect()` of the result equals the data frame;
    - a second call with the same key returns the cached object.
  - `"attach/detach leaves the connection clean"`: `DBI::dbListTables(con)` is the same before and after
    attach + detach.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement the functions above.**
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with the message `feat(lazy): private duckdb connection and table helpers`.

### Task 3: `sv_lazy_rows_window()`

**Files:**
- Modify: `R/lazy.R`
- Test: `tests/testthat/test-lazy.R`

**Interfaces:**
- Consumes `sv_rows_window(df, req, order_cache)` (`R/rows.R`). Its reply is `list(offset, total, row_ids, columns)`.
- `sv_lazy_filter_expr(col, op, value, numeric) -> language`:
  - built with `rlang::sym()` and `rlang::expr()`, never by parsing text;
  - `numeric` and the literal rule are the same as `sv_filter_condition()`;
  - contains is `stringr::str_detect(<col or as.character(col) when numeric>, stringr::fixed(value))`.
- `sv_lazy_rows_window(tbl, req, order_cache = NULL) -> same list as sv_rows_window()`:
  - the pipeline is `mutate(.sv_row = row_number())`, then the filter, then `arrange(col | desc(col), .sv_row)`;
  - the window comes from the same sort keys, without `arrange()` (dbplyr has no OFFSET verb):
    - use `dbplyr::window_order(<sort keys>, .sv_row)` and `mutate(.sv_rank = row_number())`;
    - then `filter(.sv_rank > offset, .sv_rank <= offset + limit)`;
    - then `arrange(.sv_rank)` and `collect()`;
  - `row_ids` is `.sv_row - 1L`, as integer;
  - `columns` uses `sv_format_cells()` on the collected window, with `.sv_*` columns dropped;
  - `total` is a `count()` under the filter, memoised in `order_cache` under the same `spec_key` as `sv_rows_window()`;
  - the offset and limit clamping is identical to `sv_rows_window()`.

- [ ] **Step 1: Write the failing parity test** `"lazy row windows equal in-memory windows"`.
  - **Fixture:** 300 rows with
    - an integer `id`;
    - a character `name` with `NA`, `" a"`, `"A"`, `"a"`, ties and `"b\t"`;
    - a double `x` with `NA` and ties;
    - a `Date` column `d`.
  - **Grid:**
    - `sort` over each column in `asc`/`desc`, plus `NULL`;
    - `filter` over `NULL`, contains `"a"` on `name`, contains `"1"` on `id`, `equals`, `not_equals`, `gt`, `gte`,
      `lt` and `lte` on `x` with value `"0.5"`, and `equals ""` on `name`;
    - `offset` in `0`, `10` and `295` (past the end), with `limit 20`.
  - **Assertion:** for duckdb and arrow sources,
    `expect_equal(sv_lazy_rows_window(sv_lazy_tbl(src, e), req), sv_rows_window(df, req), tolerance = 1e-12)`.
  - **Zero-row case:** a zero-row table gives `total == 0` and `row_ids` of `integer(0)`.
- [ ] **Step 2: Run the test and see it fail.**
- [ ] **Step 3: Implement the two functions above.**
- [ ] **Step 4: Run the test.** Expected: PASS.
- [ ] **Step 5: Commit** with the message `feat(lazy): full-table row windows`.

### Task 4: Lazy join check and placement

**Files:**
- Modify: `R/lazy.R`, `R/diagnostics.R:35` (dispatch only)
- Test: `tests/testthat/test-lazy.R`

**Interfaces:**
- Consumes: `sv_join_counts`, `format_key`, `sv_join_decode`, `sv_key_kind`, `sv_join_type_issues`,
  `sv_join_warnings` (`R/diagnostics.R`, unchanged).
- `sv_is_lazy_input(x) -> logical`: `TRUE` for `tbl_lazy`, `ArrowTabular`, `Dataset` and `arrow_dplyr_query`.
- `sv_lazy_place(x, y, con_env) -> list(x, y, cleanup)`. It follows the spec §4.4 table.
  - Both results are tbls on one connection. `cleanup()` detaches whatever was attached or registered.
  - Different duckdb connections raise `rlang::abort("These tables are on different duckdb connections; join check unavailable.", class = "sv_lazy_cross_con")`.
- `sv_lazy_join_diagnostics(x, y, by, sample_n = 5L, x_name = "x", y_name = "y", con_env = sv_lazy_env()) -> same list as sv_join_diagnostics()`:
  - It calls `on.exit(placed$cleanup(), add = TRUE)` right after placement.
  - **Counts:** per-side `group_by(keys) |> summarise(n = n(), first = min(.sv_row))`. The two sides are joined
    with `dplyr::full_join(..., na_matches = "na")`, which dbplyr emits as `IS NOT DISTINCT FROM`. One collected
    aggregate then feeds the same arithmetic as `sv_join_counts()`. Factor that arithmetic into
    `sv_join_counts_from(cx, cy)`, which takes two per-key count data frames, and have `sv_join_counts()` call it.
    The per-key tables can be large, so aggregate them in SQL. Only unmatched samples come back as rows
    (`LIMIT sample_n`, ordered by `first`).
  - **Hints:** run only when some rows don't match, on character keys only. There are three variants:
    - `trim(v, ' \t\r\n')`;
    - `lower(trim(v, ' \t\r\n'))`;
    - `regexp_replace(v, '^0+([0-9])', '\1')`.
- `sv_join_diagnostics()` starts with: if `sv_is_lazy_input(x) || sv_is_lazy_input(y)`, return
  `sv_lazy_join_diagnostics(...)`.

- [ ] **Step 1: Write the failing tests.**
  - `"lazy join diagnostics equal in-memory"`:
    - The fixtures have `NA` keys, `" P1"`/`"p1"`/`"P1\t"`, `"007"` against `"7"`, duplicate keys on both sides,
      a two-column key, and different key names (`by = c(pid = "patient_id")`).
    - Run every combination of {df, duckdb, arrow} × {df, duckdb, arrow} except df × df.
    - Each must be `expect_equal(..., tolerance = 1e-12)` to `sv_join_diagnostics(df_x, df_y, by)`.
  - `"zero-row and all-NA keys"`: these match the in-memory result.
  - `"different connections give the message"`: `expect_error(..., class = "sv_lazy_cross_con")`, and the
    message equals the fixed text.
  - `"user connection is left clean"`:
    - `DBI::dbListTables(con)` is unchanged after duckdb × arrow and duckdb × df checks;
    - it is also unchanged after a forced error: mock `sv_join_counts_from` to `stop()`, and `expect_error`.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement placement, the counts refactor and dispatch.**
- [ ] **Step 4: Run the lazy and diagnostics tests.** `test-diagnostics.R` (R/JS parity) must still pass.
- [ ] **Step 5: Commit** with the message `feat(lazy): full-table join check`.

### Task 5: Shared issue formatter and lazy column profile

**Files:**
- Modify: `R/codebook.R:24-176`, `R/lazy.R`
- Test: `tests/testthat/test-lazy.R`, `tests/testthat/test-codebook.R`

**Interfaces:**
- Split `sv_profile_issues(kind, vals, p)` into two functions. `sv_profile_issues()` keeps its signature and
  returns `sv_format_issues(p, sv_issue_counts(kind, vals, p))`.
  - `sv_issue_counts(kind, vals, p) -> list(spaced, empty, variants_n, variants_eg, numeric_text, far_n, far_eg)`.
    The counts are integer, `variants_eg` is character (up to 3), `numeric_text` is logical and `far_eg` is
    numeric (up to 3, descending).
  - `sv_format_issues(p, counts) -> character` holds every text that exists today.
- `sv_column_profile(x, top_n = 10L, bins = 20L, column = NULL)`:
  - for lazy input, `column` is required (error `"Give \`column\` for a lazy table."`);
  - it then returns `sv_lazy_column_profile(x, column, top_n, bins)`.
- `sv_lazy_column_profile(tbl, column, top_n = 10L, bins = 20L, con_env = sv_lazy_env()) -> same list as sv_column_profile()`:
  - `kind` and `class` come from `collect(head(select(tbl, column), 0))`. `label` is `NULL`.
  - The queries follow spec §5.3.
  - Date and date-time order statistics: one query keeps rows with `row_number(v) %in% ceiling(n * c(.25, .5, .75))`, plus `min`/`max`.
  - `sv_lazy_issue_counts(tbl, column, kind, p) -> same list as sv_issue_counts()`. It uses
    `trim(v, ' \t\r\n')` and `regexp_full_match()` with the R regex from `sv_profile_issues()`.
  - All of this feeds `sv_format_issues()`.

- [ ] **Step 1: Write the failing tests.**
  - `"sv_profile_issues is unchanged"`: the existing `test-codebook.R` issue texts still pass. Add one
    tab-whitespace case.
  - `"lazy column profile equals in-memory"`:
    - Columns:
      - numeric with outliers and ties;
      - integer key (`unique_key` TRUE);
      - character with `" x"`, `"X"`, `"x\t"`, `""` and `NA`;
      - numeric text;
      - Date;
      - logical;
      - all-NA;
      - a zero-row table.
    - For duckdb and arrow, `expect_equal(sv_column_profile(src, column = c), sv_column_profile(df[[c]]), tolerance = 1e-12)`.
  - `"lazy input needs column"`: `expect_error(sv_column_profile(tbl), "Give \`column\`")`.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement the split, the dispatch and the lazy profile.**
- [ ] **Step 4: Run the lazy and codebook tests.** The JS profile parity in `test-codebook.R` must still pass.
- [ ] **Step 5: Commit** with the message `feat(lazy): full-table column inspector`.

### Task 6: Codebook `rows_profiled` (R and JS) and lazy tables in `sv_codebook()`

**Files:**
- Modify:
  - `R/codebook.R:178-236`
  - `inst/www/sv-pipeline.js:802-860` (`codebookRow`, `CODEBOOK_FIELDS`, `codebookCsv`)
- Test: `tests/testthat/test-codebook.R`, `tests/testthat/test-lazy.R`

**Interfaces:**
- `sv_codebook(..., top_n = 5L, file = NULL, progress = NULL)`:
  - accepts lazy tables among `...`, and internal `sv_preview_table(df, n_total)` objects
    (`structure(list(data = df, n_total = n_total), class = "sv_preview_table")`, not exported). The server
    uses these for preview-only lazy cards;
  - `progress` is an optional `function(table, j, n_cols)`, called before each column;
  - the error for other inputs becomes `"\`%s\` is not a data frame or lazy table."`.
- `sv_codebook_row(table, column, position, x, top_n, n_total = NULL)`:
  - `x` is a vector, or `list(tbl = , column = )` for lazy input;
  - the output adds `rows_profiled = p$n` right after `n`, and `n = n_total %||% p$n`.
- JS `codebookRow(table, column, position, values, topN, nTotal)` gets the same rule.
  `CODEBOOK_FIELDS` inserts `'rows_profiled'` after `'n'`.

- [ ] **Step 1: Write the failing tests.**
  - `"codebook has rows_profiled after n"`:
    - `names(sv_codebook(df))[6:7] == c("n", "rows_profiled")`;
    - for a data frame, `rows_profiled == n`.
  - `"preview codebook row reports table size"`: `sv_codebook_row("t", "a", 1, df$a[1:50], 5, n_total = 1000)`
    gives `n == 1000` and `rows_profiled == 50`.
  - Extend the byte-equal CSV test: it still passes, and add a case with `nTotal`/`n_total`.
  - `"lazy codebook equals in-memory"`: `sv_codebook(v = duckdb_tbl, a = arrow_tbl)` equals
    `sv_codebook(v = df, a = df)`.
  - `progress` is called once per column with the right `j` and `n_cols`.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement this in R and JS.**
- [ ] **Step 4: Run the codebook and lazy tests.** Also run `node --check inst/www/sv-pipeline.js`. Expected: PASS.
- [ ] **Step 5: Commit** with the message `feat(codebook): rows_profiled column; lazy tables`.

### Task 7: Server wiring, fallback and toasts

**Files:**
- Modify:
  - `R/app_server.R:205-284` (four handlers) and the server setup
  - `R/app_ui.R:200-230,333` (badge and attributes)
  - `R/llm.R:18-60`
- Test: `tests/testthat/test-app.R`, `tests/testthat/test-copilot.R` (or `test-llm.R`)

**Interfaces:**
- In `sideview_server()`:
  - set `con_env <- sv_lazy_env()` and `lazy_failed <- new.env()` (card ids as names);
  - add `session$onSessionEnded(function() sv_lazy_close(con_env))`.
- `card_full(card) = sv_card_is_lazy(card) && is.null(lazy_failed[[card$id]])`.
- `lazy_or_preview(card, f_lazy, f_preview)` runs `f_lazy()` inside `tryCatch` when the card is full.
  - **On error:** it records `lazy_failed[[card$id]] <- TRUE` and sends `sideview_toast` with
    `list(text = sprintf("Lost the link to %s; showing the first %d rows.", card$name, nrow(card$data)), type = "warning")`.
    It then returns `f_preview()`.
  - **Cross-connection errors** (class `sv_lazy_cross_con`) do not mark the card as failed. The join reply
    carries `error = <message>`, which the browser already shows.
- **Handlers:**
  - rows: `sv_lazy_rows_window(sv_lazy_tbl(card$source, con_env, card$id), req, cache)`;
  - join: placement via `sv_lazy_join_diagnostics`;
  - profile: `sv_lazy_column_profile`;
  - codebook:
    - passes the lazy tbls for full cards and `sv_preview_table(card$data, card$dims[1])` for preview-only lazy
      cards (Task 6);
    - its progress callback sends `sideview_toast` `sprintf("Profiling %s: column %d of %d", table, j, n_cols)`,
      throttled to once per 250 ms.
- **New custom message `sideview_toast`** `{text, type}`. The client calls `showToast(text, type)`. Add it to
  CLAUDE.md.
- **`render_card_tag()` attributes:**
  - `data-total-rows` is `card$dims[1]` when full, else `nrow(card$data)`;
  - `data-table-rows` is `card$dims[1]`;
  - `data-lazy` is `card$lazy_source` (only when `is_lazy`);
  - `data-code-ref` is `card$code_ref`;
  - `data-rows-basis` is `"full"` or `"preview"`.
- **Badge text:**
  - for preview-only lazy cards with `dims[1] > nrow(data)`: `sprintf("First %s of %s rows", fmt_n(nrow(data)), fmt_n(dims[1]))`;
  - add `title = "Install duckdb to check the whole table"` when `!sv_has_duckdb()`;
  - otherwise the badge is unchanged.
- `sv_build_schema_context()`: for `is_lazy` cards, the Dimensions line uses `card$dims[1]` and appends
  `" (ranges from the first N rows)"` with `N = nrow(card$data)`. Data-frame output is unchanged.

- [ ] **Step 1: Write the failing tests** (testServer, duckdb fixture of 1,000 rows).
  - `"rows request uses the whole lazy table"`: the reply `total` is 1000, and a descending sort's first value is
    the true max.
  - `"join and profile requests use the whole table"`: the reply's `n_x` is 1000 and the profile's `n` is 1000.
  - `"closed connection falls back once"`:
    - after `DBI::dbDisconnect(con, shutdown = TRUE)`, two rows requests each answer from the preview (`total == 50`);
    - exactly one `sideview_toast` is sent, with the fixed text.
  - `"preview badge and attributes"`:
    - with `withr::local_options(sideview.use_duckdb = FALSE)`, `render_card_tag()` HTML contains
      `First 50 of 1,000 rows`, `Install duckdb to check the whole table` and `data-total-rows="50"`;
    - with duckdb on, it contains `data-total-rows="1000"` and `data-rows-basis="full"`.
  - `"schema context states the true row count"`: the context contains `1000 rows` and
    `(ranges from the first 50 rows)`.
  - Use a message spy to capture dispatched messages: wrap `session$sendCustomMessage` as the existing
    `test-app.R` tests do.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement the wiring.**
- [ ] **Step 4: Run all tests:** `Rscript -e "devtools::test()"`. Expected: all green.
- [ ] **Step 5: Commit** with the message `feat(gadget): lazy cards use the whole table; preview fallback`.

### Task 8: Browser labels, banners and the real-browser test

**Files:**
- Modify:
  - `inst/www/sideview.js`: around 2681 (widget badge); the join step diagnostics render near 3634; the
    inspector near 3846; `attachRemoteRows` near 2934; the custom-message registration
  - `inst/www/sideview.css`
- Test: `tests/testthat/test-layout-browser.R` (or a new `test-lazy-browser.R` using `helper-browser.R`)

**Interfaces:**
- `tableRows(cardEl|cardData) -> number` is `data-table-rows` in the gadget and `cardData.totalRows` in the
  widget. `rowsBasis` is `"full"` or `"preview"`; widget lazy cards are always `"preview"`.
- **Widget badge:** for a lazy card with `totalRows > preview rows`, `"First " + n + " of " + total.toLocaleString('en-US') + " rows"`.
- **Banner:** `.sideview-basis-note` reads "Based on the first 50 rows" (with the actual N), shown when:
  - in a join reply, `n_x < tableRows(x)` or `n_y < tableRows(y)`;
  - in an inspector reply, `p.n < tableRows`.
- **Pending text:** "Checking the whole table…" replaces the current pending text in the join step and inspector
  when the card's basis is `"full"`.
- **Messages:** handle the `sideview_toast` message.
- **CSS:** `.sideview-container .sideview-basis-note` uses `color: var(--sv-text-muted)` and `font-size: 12px`
  (the sheet has no font-size tokens). Check that `test-theme.R` still passes.

- [ ] **Step 1: Write the failing browser test** `"lazy duckdb card uses the whole table"` (`skip_if_no_browser()`, `skip_if_not_installed("duckdb")`).
  - Start with `sv_start_app('{con <- DBI::dbConnect(duckdb::duckdb()); set.seed(1); DBI::dbWriteTable(con, "big", data.frame(id = 1:200000, x = round(rnorm(200000), 4))); big <- dplyr::tbl(con, "big"); sideview(patients, big, run = FALSE)}')`.
  - Assert that:
    - the card badge contains `200000`;
    - after a real header click to sort `x` descending, the first cell equals R's `max(x)`, formatted as
      `sv_format_cells`;
    - a `gt 2` filter's reported count equals `dplyr::count(dplyr::filter(big, x > 2))`;
    - the inspector median for `x` equals `stats::median(x)` from R;
    - no JS errors.
  - **Second test**, `"preview-only labels"`: run the same app with `options(sideview.use_duckdb = FALSE)` and an
    arrow table. The badge reads `First 50 of 200,000 rows` and the inspector shows the "Based on the first 50
    rows" note.
  - Use real input (`b$Input$dispatchMouseEvent`) for clicks, as the other browser tests do.
- [ ] **Step 2: Run the test with `NOT_CRAN=true` and see it fail.**
- [ ] **Step 3: Implement the JS and CSS.**
- [ ] **Step 4: Run the checks:**
  - `node --check inst/www/sideview.js`;
  - the browser tests with `NOT_CRAN=true`;
  - the mock GUI runner (`test-features-verification.R`).

  Expected: PASS.
- [ ] **Step 5: Commit** with the message `feat(ui): full-table and preview labels for lazy cards`.

### Task 9: Lazy code generation

**Files:**
- Modify:
  - `inst/www/sv-pipeline.js`: `condition` at 58, `verbs` at 107, `compose` at 374-439, `api` at 864
  - `inst/www/sideview.js`:
    - the Pipeline construction at 671 (feed table meta);
    - `submitBuilder` at 4342 (pass `lazy`);
    - the `sideview_eval_result` handler at 4945 (error hint)
  - `R/codegen.R` (`sv_auto_clean_rules`)
- Test: `tests/testthat/test-pipeline.R` (node) and `tests/testthat/test-codegen.R`

**Interfaces:**
- `Pipeline.setTables(meta)` takes `meta = { <name>: { lazy: 'arrow'|'duckdb'|null, codeRef: string } }`.
  - It is called from the gadget, built from card attributes, and from the widget, built from card JSON.
  - It is stored in `getState()` only through the cards, not as pipeline state.
- `condition(col, op, val, numeric, lazy)` emits contains as follows:
  - when `lazy` is truthy: `stringr::str_detect(<col>, stringr::fixed("..."))`, with `<col>` becoming
    `as.character(<col>)` when `numeric`;
  - otherwise it is unchanged.
- `compose()`:
  - `refFor(name)` returns `meta[name].codeRef || name`;
  - cross-kind joins follow spec §6 exactly;
  - when the chain's base table or any joined table is lazy, it appends `collect()` as the last call.
- **Eval error hint:** when a `sideview_eval_result` error arrives and the pipeline has a lazy table, the toast
  text is `<error> + " " + "This step may need data in R: move collect() above it."`.
- **Auto-clean:** `sv_auto_clean_rules(payload, df_name, col, pipe, lazy = FALSE)`. When `lazy` is set, it uses
  `stringr::str_trim()` / `stringr::str_to_lower()` in place of `trimws()` / `tolower()` wherever dbplyr or arrow
  cannot translate them. Find out by running the generated code in Step 1.
  - The server passes `lazy = isTRUE(card$is_lazy)`.

- [ ] **Step 1: Write the failing tests.**
  - **Node unit tests:**
    - one per row of the §6 join table: expected code strings, with `copy = TRUE`, `arrow::to_duckdb(..., con = dbplyr::remote_con(...))`, `dplyr::copy_to(...)` and `arrow::arrow_table(...)`;
    - lazy contains on character and numeric columns;
    - `collect()` appears exactly once and last;
    - a data-frame-only pipeline is byte-identical to today's.
  - **R test `"lazy pipelines parse and run"`:**
    - for each join-table row, and for a pipeline using every step kind (filter, arrange, rename, mutate, recode,
      summarise, custom auto-clean) on duckdb and on arrow;
    - the generated code must `parse()`;
    - `eval` in an env with the fixtures must equal the same pipeline generated for data frames;
    - compare with both sides sorted by all columns, as tibbles, `tolerance = 1e-12`.
  - **Gadget hint test:** send an eval error for a lazy pipeline via the mock runner and check the toast text ends
    with the fixed hint.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement the JS changes and the auto-clean `lazy` argument.**
- [ ] **Step 4: Run all tests:** `node --check inst/www/*.js`; `Rscript -e "devtools::test()"`. Expected: all green.
- [ ] **Step 5: Commit** with the message `feat(codegen): lazy pipelines with cross-kind joins and one collect()`.

### Task 10: Speed check, docs and the RStudio check

**Files:**
- Modify:
  - `tests/testthat/test-lazy.R`
  - `NEWS.md`
  - `CLAUDE.md`
  - the tour article `vignettes/articles/tour.Rmd`, then rebuild the site into `docs/` and drop the dev notes from it
  - `DESCRIPTION`
  - `_pkgdown.yml` (if needed)
  - `MEMORY.md`
  - roxygen for `sv_join_diagnostics`, `sv_column_profile` and `sv_codebook`, then the regenerated `man/`

- [ ] **Step 1: Add the speed test.** `"join check on 1M-row duckdb tables is under 5 s"` uses `skip_on_cran()` and checks `system.time(...)[["elapsed"]] < 5`. Run it and record the time in MEMORY.md.
- [ ] **Step 2: Update the docs.**
  - **Roxygen:** state that lazy input is accepted, the `column` argument, the `progress` argument and the
    `rows_profiled` and `n` meaning. Note the numeric-contains caveat.
  - **NEWS.md:** add a "0.4.0 (development)" section.
  - **CLAUDE.md:** add a lazy-card rule (`source` never serialised; `R/lazy.R` twins and the parity tests), the
    `sideview_toast` message and the `rows_profiled` codebook column.
  - **Tour:** add a "Big tables" section.
  - **DESCRIPTION:** add `stringr` to Suggests.
- [ ] **Step 3: Build and check.**
  - Run `Rscript -e "devtools::document()"`, then `Rscript -e "pkgdown::check_pkgdown()"`.
  - Then run `devtools::check()` with `NOT_CRAN=true`: 0 errors and 0 warnings.
- [ ] **Step 4: Check by hand in RStudio** (computer use).
  1. Write a synthetic 1M-row parquet `Dataset` to the scratchpad.
  2. Run `sideview(ds, patients, viewer = "dialog")`.
  3. Run a join check and the inspector.
  4. Press **Done** and run the returned code.
  5. Record the results in MEMORY.md, with screenshots in the scratchpad only.
- [ ] **Step 5: Commit** with the message `docs: big tables (0.4.0 part 1)`.
