# Full data for arrow and duckdb cards: design

- **Date:** 2026-10-25
- **Release:** sideview 0.4.0, sub-project 1 of 4 (see `MEMORY.md`, "Next release")
- **Status:** design approved in chat, section by section; awaiting review of this written spec

## 1. Problem

An arrow or duckdb table on the canvas keeps only its first 50 rows. `sv_normalize()` (`R/normalize.R`)
stores `head(x, 50)` as `card$data` and throws the lazy object away. Every server-side check then runs on
those 50 rows:

| Feature | Handler in `R/app_server.R` | Today, for a lazy card |
|---|---|---|
| Sort, filter, scroll | `sideview_rows_request` → `sv_rows_window()` | sorts and filters 50 rows |
| Join check | `join_diagnostics_request` → `sv_join_diagnostics()` | match rates from 50 rows |
| Column inspector | `column_profile_request` → `sv_column_profile()` | quartiles of 50 rows |
| Codebook | `codebook_export` → `sv_codebook()` | profiles 50 rows |

Nothing tells the user. A 50-million-row parquet dataset looks checked when it is not, so the join check
and codebook can mislead exactly the user who most needs them.

## 2. What the user told us

- They use arrow and duckdb in their work.
- Their sessions mix in-memory data frames with larger-than-memory tables.
- **Route 1 chosen:** duckdb is the single engine for lazy tables.
- **No size threshold:** an arrow or duckdb table always goes through duckdb, whatever its size. Data
  frames always stay in R. (A "collect small lazy tables" rule was offered and declined.)

## 3. Goals and non-goals

**Goals**
1. Sort, filter, scroll, the join check, the inspector and the codebook use the whole table for arrow and
   duckdb cards.
2. Only summaries and row windows come back into R. A lazy table is never collected by sideview.
3. The results are the same as the in-memory functions give on the same data, field by field.
4. Generated code stays lazy, joins across kinds correctly and ends in one `collect()`.
5. When the whole table can't be used, the UI says "first 50 rows" everywhere it matters.
6. `sv_join_diagnostics()`, `sv_column_profile()` and `sv_codebook()` accept duckdb and arrow tables
   from R scripts too.

**Non-goals (this release)**
- Cancelling a running query.
- Auto Map, the Discrepancy tab's value comparison and the copilot schema summary on the full table.
  They stay on the preview, labelled. The copilot gets the true row count.
- Full data inside a saved or embedded widget (no R session there).
- Joining two duckdb tables that live on two different connections.

## 4. Architecture

### 4.1 The card keeps its source

`new_sideview_card()` gains one field:

- `source`: the original lazy object as the user passed it (an arrow `Table`, `Dataset`,
  `RecordBatch`, `arrow_dplyr_query` or a `tbl_duckdb_connection`). It is `NULL` for data frames and for
  the mock list objects the tests use.

`card$data` stays the 50-row preview, used for the first paint. `dims` keeps the true row count.

A card also gains `code_ref`: the R text that names the table in generated code. Usually this is the card
name. A card made from a whole `duckdb_connection` uses `dplyr::tbl(con, "visits")`, written with the
argument expression the user passed.

`source` is never serialised. `sideview_widget()`, `sv_state_json()` and the card JSON leave it out, and a
test checks this.

### 4.2 One new file, `R/lazy.R`

All lazy logic lives here, so the in-memory functions stay unchanged.

| Function | Purpose |
|---|---|
| `sv_has_duckdb()` | `requireNamespace()` for duckdb, dbplyr and DBI. Tests mock it to fake "not installed". |
| `sv_card_is_lazy(card)` | `TRUE` when the card has a `source` and duckdb is available |
| `sv_lazy_tbl(source, con_env)` | Turns a source into a `tbl_duckdb_connection`. Arrow goes through `arrow::to_duckdb(con = <private connection>, auto_disconnect = FALSE)`, and a duckdb tbl is returned as is. |
| `sv_lazy_con(con_env)` | Opens sideview's private duckdb connection on first use and caches it in `con_env` |
| `sv_lazy_close(con_env)` | Disconnects the private connection with `shutdown = TRUE`. It never touches a user connection. |
| `sv_lazy_rows_window(tbl, req, cache)` | Lazy twin of `sv_rows_window()` |
| `sv_lazy_join_diagnostics(x, y, by, ...)` | Lazy twin of `sv_join_diagnostics()` |
| `sv_lazy_column_profile(tbl, column, ...)` | Lazy twin of `sv_column_profile()` |
| `sv_lazy_attach(df, con)` / `sv_lazy_detach()` | `duckdb::duckdb_register()` / `duckdb_unregister()` a data frame as a view for one join check |

The exported functions dispatch on their input. `sv_join_diagnostics()` uses the lazy path when `x` or
`y` is a lazy table. `sv_column_profile()` gets a `column` argument for lazy input, because a lazy table
has no plain vector to pass. `sv_codebook()` accepts lazy tables among its `...`. Data-frame behaviour and
output are unchanged.

### 4.3 Server wiring

The four handlers ask `sv_card_is_lazy(card)` and call the lazy twin when it is `TRUE`. Otherwise they keep
today's call. The session holds one `con_env`, and the app closes the private connection in
`shiny::onStop()`. That fits the gadget lifecycle in `sv_new_lifecycle()`: a browser reload keeps it open.

`render_card_tag()` writes the real `dims[1]` into `data-total-rows`, not `nrow(card$data)`.

### 4.4 Where a join check runs

| Left | Right | Runs on | How the other side gets there |
|---|---|---|---|
| duckdb | duckdb, same connection | that connection | nothing to do |
| duckdb | duckdb, other connection | not run | message: "These tables are on different duckdb connections; join check unavailable." |
| duckdb | arrow | duckdb's connection | `arrow::to_duckdb(con = remote_con(left))` |
| duckdb | data frame | duckdb's connection | `sv_lazy_attach()` for the check, then `sv_lazy_detach()` |
| arrow | arrow or data frame | private connection | `to_duckdb()` / `sv_lazy_attach()` |
| data frame | data frame | R | today's `sv_join_diagnostics()` |

Right-hand duckdb with a left-hand arrow table or data frame is the mirror image and uses the duckdb side's
connection.

## 5. Data flow per feature

The browser sends the same requests and gets the same replies. The only new message field is
`rows_profiled` (section 7).

### 5.1 Sort, filter and scroll
- The pipeline is `tbl |> mutate(.sv_row = row_number()) |> filter(...) |> arrange(<col>, .sv_row)`,
  then one `LIMIT`/`OFFSET` window per request. `.sv_row` keeps the table's own scan order for ties
  and for unsorted rows (duckdb `preserve_insertion_order`, on by default).
- The filter is built from the popover's column, operator and value with rlang, not by parsing R text.
  "Contains" is `stringr::str_detect(col, stringr::fixed(value))`. The duckdb backend rejects
  `grepl(fixed = TRUE)`; this was checked on duckdb 1.4.3 / dbplyr 2.5.1 / arrow 23. Comparisons use the
  column type from the schema, as `sv_filter_condition()` does.
- `total` is one `count()` query, cached per sort and filter spec in the existing `order_cache`
  environment.
- Order matches `dplyr::arrange()` on a data frame: `NA` last in both directions, and C-locale strings
  (duckdb's default binary collation, checked).
- `row_ids` are `.sv_row - 1`, so they mean the same as the in-memory row ids.

### 5.2 Join check
- Per side: `group_by(keys) |> summarise(n = n(), first = min(.sv_row))`. The two count tables are joined
  on the keys with `IS NOT DISTINCT FROM`, so `NA` matches `NA` as in dplyr. One aggregate query then gives:
  `distinct_x/y`, `distinct_matched`, `matched_x/y`, `dup_keys_x/y`, the relationship flags and the row
  count for each join type. This is the same arithmetic as `sv_join_counts()`.
- `n_x`, `n_y`, `na_x`, `na_y`: one `count()` with `sum(is.na(...))` per side.
- Unmatched samples: `LIMIT sample_n`, ordered by `first`. That gives first-appearance order, as
  `unique()` does in R. Values are formatted in R with `format_key()` / `sv_join_decode()`.
- Type issues come from the schema (`sv_key_kind()` on the preview columns), so no query is needed.
- Hints (trim, case, leading zeros): when some rows don't match, re-run the counts with
  `trim()`, `lower()` or `regexp_replace(v, '^0+(?=[0-9])', '')` applied to character keys. That is up to
  3 queries. duckdb's regex has no look-ahead, so the zeros rule becomes the equivalent
  `regexp_replace(v, '^0+([0-9])', '\1')`. The parity tests hold it to R's result.
- Warnings and status reuse `sv_join_warnings()` unchanged.

### 5.3 Column inspector
Each column takes a few queries:
1. `n`, `n_missing`, `n_distinct`.
2. Numeric: `quantile_cont` at 0, .25, .5, .75 and 1 (the same as R `type = 7`), `avg`, `stddev_samp`.
   Dates and date-times: the order statistic at `ceiling(n * p)`, as `sv_column_profile()` picks it.
3. Histogram: `floor((v - lo) / width)` with the last bin closed, as in `sv_histogram()`.
4. Top values: `count(v)`, ordered by `n DESC, v`, `LIMIT top_n`. It is skipped under the same rules
   (unique key, numeric with many distinct values).
5. Issues, with the texts built by the same R code:
   - leading or trailing spaces (`v != trim(v)`);
   - empty strings;
   - case or spacing variants (`group_by(lower(trim(v)))` with more than one distinct `v`, plus the first
     group's first 3 values for the example);
   - all values numeric text (`bool_and(regexp_full_match(...))`);
   - values beyond 3 IQR (count, plus the top 3 distinct examples).

`sv_profile_issues()` is split so that the issue texts are formatted from counts. The in-memory and lazy
paths then share one formatter, and the texts can't drift apart.

### 5.4 Codebook
- `sv_codebook()` runs the profile over every column. In the gadget, a toast shows
  "Profiling visits_db: column 40 of 200".
- New column `rows_profiled`, placed after `n`. It is the number of rows the profile used: the full count
  for in-memory and duckdb, and 50 for a preview-only card. The JS `codebookRow()` / `codebookCsv()` add
  the same column, so the byte-equal CSV test still holds.

### 5.5 Staying on the preview
- Auto Map (`sv_suggest_mappings()`), the Discrepancy tab's value comparison and the copilot schema
  summary keep using `card$data`.
- The copilot summary states the true row count from `dims` and adds "(ranges from the first 50 rows)"
  for lazy cards. Privacy is unchanged: schema only, never raw rows.

## 6. Generated code

`sv-pipeline.js` stays the only place code is generated. Each card's JSON gains
`lazy: "arrow" | "duckdb" | null` and `codeRef`.

- **One `collect()` at the end** of any pipeline that starts from, or joins, a lazy card:
  ```r
  visits_db |>
    filter(sbp > 140) |>
    left_join(patients, by = "id", copy = TRUE) |>
    collect()
  ```
- **Joins across kinds**

  | Left | Right | Code |
  |---|---|---|
  | duckdb | data frame | `copy = TRUE` |
  | arrow | data frame | plain join (arrow converts it; checked) |
  | duckdb | arrow | `arrow::to_duckdb(right, con = dbplyr::remote_con(left))` |
  | arrow | duckdb | `arrow::to_duckdb(left, con = dbplyr::remote_con(right))` as the left input |
  | arrow | arrow | plain join |
  | data frame | duckdb | the data frame moves into duckdb, so the left/right order and the column order stay: `dplyr::copy_to(dbplyr::remote_con(visits_db), patients, overwrite = TRUE) \|> left_join(visits_db, by = "id")` |
  | data frame | arrow | `arrow::arrow_table(patients) \|> left_join(visits_arrow, by = "id")` |

- **Contains filters** on lazy cards use `stringr::str_detect(col, stringr::fixed("..."))`. Data-frame
  cards keep `grepl(fixed = TRUE)`.
- **Reshape on arrow:** arrow has no pivot, so `collect()` goes just before the step, with a comment
  `# reshape runs in R`, and the final `collect()` is dropped. duckdb pivots lazily (dbplyr).
- **User-typed Mutate expressions** stay lazy. If "Run in R" fails on a lazy pipeline, the error toast
  adds: "This step may need data in R: move collect() above it."
- The R-side generators used by auto-clean get the same `collect()` rule where they emit a full pipeline.

## 7. When the full table isn't used

| Situation | What happens |
|---|---|
| Arrow card, duckdb not installed | Checks run on the preview. The header says "First 50 of 1,234,567 rows", with the tooltip "Install duckdb to check the whole table". |
| Saved or embedded widget | Lazy cards embed the preview and the JS computes on it. Same labels. The code shown is still lazy and correct. |
| Mock or unknown lazy object | Preview only, labelled |

- The join check, inspector and codebook replies carry `rows_profiled`, and the browser shows
  "Based on the first 50 rows" when it is smaller than the table.
- The widget passes the true row count in the card JSON, so it can show the same label.

## 8. Errors

- Every lazy call is wrapped in `tryCatch()`. On error (connection closed by the user, parquet file moved,
  an unsupported type) the handler answers from the preview, sets `rows_profiled = 50` and sends the toast
  "Lost the link to visits_db; showing the first 50 rows." The card stays preview-only for the rest of the
  session, so the toast doesn't repeat. The app keeps running.
- Slow queries: the join step and inspector show "Checking the whole table…" until the reply arrives.
  They can't be cancelled in this release.
- Data frames attached for a join check are detached in `on.exit()`, even after an error.

## 9. Testing

1. **Parity** (`tests/testthat/test-lazy.R`, `skip_if_not_installed()` for duckdb and arrow):
   - **Fixtures:** synthetic only: `NA` keys, extra spaces, case variants, leading zeros, duplicate
     keys, dates, numeric text, outliers, ties.
   - Each fixture runs as a data frame, a duckdb table and an arrow table.
   - `sv_join_diagnostics()`, `sv_column_profile()` and `sv_codebook()` must be `expect_identical()`
     (numbers with `expect_equal()` tolerance 1e-12).
   - Row windows must match too, over a grid of sorts and filters (every operator, ascending,
     descending, `NA`s, ties, offset past the end).
2. **Mixed joins:** every row of the table in 4.4 has a test, including the "different connections"
   message and detach-after-error.
3. **Code:**
   - every lazy pipeline the JS produces must `parse()`;
   - on the fixtures, running it must equal the in-memory pipeline after both are sorted by all
     columns;
   - one test for each row of the join table in section 6 and for the arrow reshape rule.
4. **Not serialised:** `source` never appears in widget JSON or saved state.
5. **Real browser** (chromote, `NOT_CRAN=true`), gadget with a 200,000-row duckdb table:
   - the header shows the true total;
   - a descending sort puts the true maximum first;
   - the filtered count equals `dplyr::count()`;
   - the inspector median equals R's.

   Then `local_mocked_bindings(sv_has_duckdb = function() FALSE)` with an arrow table: the
   "First 50 rows" labels appear. Closing the connection mid-session gives the toast, and the app stays
   up.
6. **Speed** (skipped on CRAN): a join check on two 1,000,000-row duckdb tables finishes within
   5 seconds on the dev machine.
7. **RStudio by hand** (project verification rule): open a parquet `Dataset` in `viewer = "dialog"`, run
   a join check and the inspector, press **Done** and run the returned code. Record the result in
   `MEMORY.md`.
8. **Existing suites:** all green with `NOT_CRAN=true`; `devtools::check()` with no errors or warnings.

## 10. Files touched

- **New:** `R/lazy.R`, `tests/testthat/test-lazy.R`
- **Changed:**
  - `R/normalize.R` (`source`, `code_ref`)
  - `R/app_server.R` (dispatch, `onStop`, toasts)
  - `R/app_ui.R` (`data-total-rows`, labels)
  - `R/diagnostics.R` and `R/codebook.R` (dispatch, shared issue formatter, `rows_profiled`)
  - `R/widget.R` (drop `source`, pass the row count)
  - `R/llm.R` / `R/copilot.R` (true row count)
  - `inst/www/sv-pipeline.js` (lazy codegen, `rows_profiled`)
  - `inst/www/sideview.js` (labels)
  - `inst/www/sideview.css` (label style with `--sv-*` tokens)
  - the browser tests
- **Docs:**
  - roxygen for the three exported functions;
  - `NEWS.md`;
  - `CLAUDE.md` (the lazy-card rule and the new `rows_profiled` field);
  - a short "Big tables" section in the tour article.
- **DESCRIPTION:** `stringr` joins `Suggests` (it is used only in generated code and lazy filters).
