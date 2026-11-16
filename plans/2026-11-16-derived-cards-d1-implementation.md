# D1: derived cards and unmatched rows: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One click from a join-check or SUPP-check count to a card holding those rows. The card is built by R, its
generated code rebuilds it, lazy inputs stay lazy, and the same rows come from the console.

**Architecture:** A *derived card* is a pipeline `derive` step (`op` + `inputs` + `args`) plus a card that R builds
from the card store and registers there (spec section 4, approach A). R decides which buttons to offer, and writes
their text, by adding `derive_offers` to its join-check and SUPP-check replies. The canvas drawer and the list view
render those offers, so the widget, which has no R, shows none. `compose()` writes each live derive step as
`<name> <- <expression>` before the chains. A code-twin test evaluates that code and compares it with the card R built.

**Tech Stack:** R 4.5.2 (dplyr, dbplyr, duckdb, arrow in Suggests), plain JS (ES5 style, as in `inst/www`),
testthat with `testServer`, node through `helper-node.R`, chromote real-browser tests.

**Spec:** `plans/2026-11-16-derived-cards-design.md`. D1 covers sections 5, 8 (unmatched and SUPP parts only),
9 (`derive_request`, `derive_forget`, `sideview_derive_result`), 10 and 12. Read sections 3, 5 and 10 before any task.

## Global Constraints

- **Branch:** `d/d1-derived-cards`, cut from `d/spec`, in `C:\src\sv-a11y`.
  - Never commit on `main`. Never push or merge.
  - Never commit `tests/testthat/_problems/` or `testthat-problems.rds`.
- **Line endings:** keep CRLF where a file has it (`MEMORY.md`, `NEWS.md`, `DESCRIPTION`, `inst/www/sideview.js`,
  `plans/*.md`). Check with `file <path>` first. Edit CRLF files with Python `open(p, newline='')`, utf-8.
- **Commit trailer:** `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **R:** run as `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"`.
  - Run tests with `devtools::test(filter = "<file>")`.
  - Real-browser tests need `NOT_CRAN=true`.
  - JS syntax check: `node --check inst/www/<file>.js`.
- **Exports:** an exported R function has the `sv_` prefix and roxygen docs, and goes into `_pkgdown.yml`.
- **Generated R code** must `parse()`. Every new generator gets a test (`expect_parses()` in `helper-node.R`).
- **JS:**
  - Escape table-derived text before `innerHTML`. Use `CSS.escape` in selectors.
  - A new R-to-client handler goes through `onMessage()`.
  - Every input a module sends goes out with `send()`, so it carries `ns`.
  - Remove every global listener in `destroy()`.
- **CSS:** use `--sv-*` tokens only, scoped under `.sideview-container`. Icons are inline SVG only (no emoji or
  Unicode glyphs).
- **Lazy tables are never collected.** Only counts, row windows, `collect(head(tbl, 0))` and data bounded by the
  SUPP card's size come back. A test must fail if the full table is collected, as in test-lazy.R today.
- **Module mode is an untrusted client.** A forged `derive_request` must not make R read an object outside the
  store, run code, or change the store when it is refused.
- **Card names:**
  - `<x>_unmatched_<y>` (side x) or `<y>_unmatched_<x>` (side y);
  - `<kept>_outside_window`;
  - `<supp>_orphans`;
  - `<supp>_bad_idvarval`.
  - A taken name gets `_2`, `_3`, and so on. The result goes through `make.names()`.
- **Button counts:**
  - With no rule, `unmatched` uses `na_matches = "na"`, so n = `n_x - matched_x`.
  - With a date rule, both ops use `na_matches = "never"`, so `unmatched + outside_window = n_x - matched_x`.
  - The same holds for side y. `supp_orphans` n = `n_orphan`, and `supp_bad_idvarval` n = `bad_idvarval$n`.
- **CDISC tag:** `unmatched` and `outside_window` take the kept card's tag. `supp_*` take the SUPP card's tag.
- **Announcements:** use B's live region (`engine.announce`), for example "Table ae_unmatched_dm added, 12 rows."
- **Text:**
  - Button labels say what they do, for example "Open 12 unmatched ae rows as a card".
  - R writes D's text (`sv_say_*`). There is no JS twin.

## Decisions this plan makes (spec section 11 and gaps)

These are my calls. A task implements each one; none of them reopens the spec.

1. **R offers the buttons.**
   - The `join_diagnostics_request` and `supp_check_request` handlers add `derive_offers` to their replies.
   - `derive_offers` is an R-only field, like `cdisc_notes`. The twins (`sv_join_diagnostics()`,
     `SideviewPipeline.joinDiagnostics()`, `sv_supp_check()`) do not produce it.
   - Each offer is `{op, inputs, args, n, label}`. An offer with `n == 0` is not sent.
2. **Mixed-kind keys get no offer.** When `sv_join_type_issues()` is not empty there is no offer, and a
   `derive_request` for such keys is refused with that same message.
   - Why: dplyr refuses the join, so no runnable code could equal the card.
   - This narrows spec 5.1's "keys of different kinds compare as text".
3. **`name` in `derive_request` is exact.**
   - With a `name` (a re-request from undo/redo, a reload or a state file), R uses exactly that name. If it is
     taken by another card, R answers the error "A table named <n> is already on the canvas."
   - With no `name`, R chooses one as above.
4. **Pressing an offer twice does not make a second card.** If a live derive step has the same `op`, `inputs` and
   `args` (compared as JSON), the engine zooms to its card (`zoomToCard()`) instead.
5. **Derive liveness is computed, not stored.**
   - `Pipeline.deriveLive(step)` is true when every input is a table in `this.tables`.
   - `disableMissing()` never sets `enabled = false` on a derive step. Derive steps have no toggle.
   - A step that is not live is skipped by `compose()`, shown as "waiting for <input>", and becomes live again when
     its input returns. Restoring the input therefore brings the card back by a new `derive_request` (spec 5.4).
6. **One reconcile loop in the engine.** `SideviewEngine.reconcileDerived()` runs after every pipeline change and
   every `syncTableMeta()`, and repeats until nothing changes:
   - a live derive step with no card and no pending request sends `derive_request` with `name = step.table`;
   - a card whose `data-derived` is set and that has no live derive step is removed (`removeCard()`), and
     `derive_forget {name}` is sent.
   - This one path covers undo, redo, step deletion, cascades and state-file Open.
7. **SUPP cards are in memory.**
   - The SUPP side is collected after the RDOMAIN filter, as the merge code already does.
   - The parent's keys come back only for the SUPP subjects:
     `filter(USUBJID %in% !!ids) %>% distinct(keys, idvars) %>% collect()`. This size is bounded by the SUPP card
     and works on dbplyr and Arrow with no cross-backend join.
   - `supp_*` cards are data frames, and their code ends in memory.
8. **The SUPP plan comes from R, not the client.** On a SUPP `derive_request`, R runs `sv_supp_check()` itself and
   puts its plan in the card's `derived$args$plan`. The browser's derive step stores that plan, and `compose()`
   writes from it.
9. **The lazy kind of a derived card in code** is the backend its derive expression ends in.
   - `Pipeline.lazyKind(name)` asks `deriveExpr(step).kind` first.
   - R's card is always duckdb (`lazy_source = "duckdb"`) or a data frame.
10. **Every derive join writes `na_matches` explicitly.**
    - dbplyr defaults to `"never"`, while dplyr and arrow default to `"na"`. I checked arrow 23 locally: it honours
      both values.
    - A rule on an Arrow input moves to duckdb first, as `compose()` already does (arrow has no inequality join).
11. **Side y with a date rule** is written with the y card as the join's `x`. The rule uses explicit `x$` / `y$`
    prefixes, swapped (dplyr and dbplyr accept this; I checked both locally). See Task 7 for the forms.
12. **Placement:** `SideviewEngine.freeSpotNear(meta)` tries, in order: right of the input card, below it, left of
    it, above it, each with a 24px gap. It takes the first spot whose rectangle overlaps no card. If none is free,
    it falls back to `addCardFromR`'s far-right rule.

## Review Focus

1. **A derived card built on another derived card**, then its root input removed:
   - both cards go, and both steps wait;
   - the root comes back, then both cards come back in step order with the same rows.
   - Test: Task 8 browser test and Task 6 module cascade test.
2. **NA keys on duckdb.** dbplyr's default `na_matches` is `"never"`, so a missing `na_matches = "na"` would show
   up only here. Test: Task 7 code twin with NA keys over duckdb and Arrow, n equal to the offer's n.
3. **Non-syntactic table and column names** (`` `my key` ``, a card named `ae 2026`): the derive code must quote
   them and the name must become syntactic. Test: Tasks 1 and 7.
4. **Arrow int64 SUPP parent keys beyond the int32 range**: the parent keys collect as `integer64`. The level key
   must still match, using `as.numeric()` on both sides for a double level. Test: Task 2 lazy fixture.
5. **A forged module `derive_request`**: an input naming `Sys.getenv`, a column `"x; system('id')"`, a huge
   `args`, or an unknown op. Each is refused with an error reply and no store change. Test: Task 5.

---

### Task 1: R derive core: unmatched and outside_window in memory, `sv_unmatched()`

**Files:**
- Create: `R/derive.R`
- Create: `tests/testthat/test-derive.R`
- Modify: `R/say.R` (one function)

**Interfaces:**
- Produces:
  - `sv_derive_ops <- c("unmatched", "outside_window", "supp_orphans", "supp_bad_idvarval")` (internal).
    D2/D3 append to it.
  - `sv_derive_rows(op, tables, args)` (internal). `tables` is a named list of two tables in the request's
    `inputs` order. `args` is the parsed args. It returns the result table: a data frame when every table is a data
    frame; a lazy table otherwise (Task 3). The console and the card builder both call it.
  - `sv_derive_name(op, inputs, args, taken, name = NULL)` (internal). It returns a syntactic name, or stops with
    the "already on the canvas" message (decision 3).
  - Exported `sv_unmatched(x, y, by, rule = NULL, side = c("x", "y"), what = c("unmatched", "outside_window"))`.
    - `by` has the form `sv_join_diagnostics()` takes.
    - `what = "outside_window"` with no rule is an error: "outside_window needs a date rule."
  - `sv_say_derive_offer(op, n, kept, other)` in `R/say.R`, giving:
    - "Open 12 unmatched ae rows as a card";
    - "Open 3 ae rows outside the date window as a card";
    - "Open 2 orphan suppae rows as a card";
    - "Open 1 suppae row with a bad IDVARVAL as a card".
    - Singular and plural follow `n`, as the existing `sv_say_*` functions do.
- The `args` shape for these ops:
  - `by` is a list of `{x, y}` column pairs.
  - `rule` is a rule list (`sv_join_rule_normalize()` form), or `NULL`.
  - `side` is `"x"` or `"y"`.
  - The result's columns are those of the kept table, in its order. The rows keep its row order.

- [ ] **Step 1: Write the failing tests** in `test-derive.R`, on small synthetic data frames
  (`ae`: USUBJID with one NA and one key absent from dm; `dm`: USUBJID; a date fixture for rules):
  - `test_that("unmatched with no rule equals n_x - matched_x, NA matching NA")`:
    - `d <- sv_join_diagnostics(ae, dm, "USUBJID")`;
    - `expect_equal(nrow(sv_unmatched(ae, dm, "USUBJID")), d$n_x - d$matched_x)`;
    - the same for `side = "y"` with `d$n_y - d$matched_y`;
    - the NA key row is not in the result when dm also has an NA key.
  - `test_that("with a rule, unmatched + outside_window partition what the rule drops")`: for each shape
    (`between`, `window` with `from = -3, to = 3`, `before`, `after`, `overlaps`) and each side:
    - `nrow(unmatched) + nrow(outside_window) == n - matched`;
    - `nrow(outside_window) == d$rule_dropped_x` (or `_y`).
  - `test_that("rows equal dplyr")`:
    - no rule: `expect_equal(sv_unmatched(ae, dm, "USUBJID"), dplyr::anti_join(ae, dm, by = "USUBJID", na_matches = "na"))`;
    - with a rule, side x: `dplyr::semi_join(..., na_matches = "never")`, then `anti_join(..., join_by(...), na_matches = "never")`.
  - `test_that("mixed key kinds are refused")`: numeric vs character key, `expect_error(..., "dplyr will refuse")`.
  - `test_that("names")`:
    - `sv_derive_name("unmatched", c("ae", "dm"), list(side = "x"), character())` is `"ae_unmatched_dm"`;
    - with `"ae_unmatched_dm"` taken it is `"ae_unmatched_dm_2"`;
    - `inputs = c("ae 2026", "dm")` gives `"ae.2026_unmatched_dm"`;
    - `name = "ae_unmatched_dm"` with that name taken errors "already on the canvas".
  - `test_that("say")`: the four label strings above, at `n = 1` and at `n = 12`.
- [ ] **Step 2: Run them and see them fail.** Run `devtools::test(filter = "derive")`. Expected: FAIL, "could not
  find function".
- [ ] **Step 3: Implement** `sv_derive_rows()` (in-memory branch), `sv_derive_name()`, `sv_unmatched()` and
  `sv_say_derive_offer()`.
  - Check the rule with `sv_join_rule_problem()`, and the key kinds with `sv_join_type_issues()`; reuse their
    messages.
  - Build the rule join with `dplyr::join_by()` from the normalised rule, as the forms in Task 7 do, so the R rows
    and the generated code are the same expression.
  - `sv_unmatched()` hands a lazy `x` or `y` to Task 3's branch, and stops with "needs duckdb" until then.
- [ ] **Step 4: Run them and see them pass.** Run `devtools::test(filter = "derive")`. Expected: PASS.
- [ ] **Step 5: Commit.** Run `devtools::document()`, then add `sv_unmatched` to `_pkgdown.yml` next to
  `sv_join_diagnostics` and commit with "feat: derived rows core and sv_unmatched()".

### Task 2: SUPP ops: `supp_orphans`, `supp_bad_idvarval`, `sv_supp_orphans()`

**Files:**
- Modify: `R/derive.R`, `R/supp.R` (export only), `tests/testthat/test-derive.R`, `tests/testthat/test-lazy.R`
  (a new block)

**Interfaces:**
- Consumes: `sv_supp_check()` and its `plan` (`keys`, `idvars` with `idvar` / `type`, `rdomain_col`).
  `sv_supp_convert()` does the IDVARVAL conversion.
- Produces:
  - Exported `sv_supp_orphans(parent, supp, rdomain = NULL, what = c("orphans", "bad_idvarval"))`. It runs
    `sv_supp_check()` for the plan, then `sv_derive_rows()`.
  - `sv_derive_rows()` for `supp_orphans` and `supp_bad_idvarval`. Here `tables = list(parent, supp)`, and
    `args = list(plan = <plan>, rdomain = <chr>)`. The result is always a data frame (decision 7).
    - Its columns are the SUPP columns.
    - Its rows are in SUPP row order, after the RDOMAIN filter.
- The algorithm (the generated code in Task 7 writes the same steps):
  1. `s` = SUPP filtered to `RDOMAIN == rdomain` when `plan$rdomain_col`, collected when lazy.
     `.sv_row = seq_len(nrow(s))`.
  2. `.sv_iv` = `""` when IDVAR is NA or blank (`trimws`), else `as.character(IDVAR)`.
  3. `p` = the parent filtered to `USUBJID %in% unique(s$USUBJID)` (on a lazy parent the filter runs in the backend),
     then `distinct(<keys>, <level idvars>)`, then collected. The plan's keys always include USUBJID (check in
     `sv_supp_check_df`).
  4. For each plan level `lv`:
     - the rows with `.sv_iv == lv`;
     - `.sv_k` = the IDVARVAL converted to the level type (`sv_supp_convert()`), not computed for the subject
       level `""`;
     - a row is *bad* when the level is not `""` and its key does not convert, under the check's rule (NA, or a
       double with `abs() > 1e308`);
     - an *orphan* is a row that converts and has no partner in `distinct(p, keys, lv)`: an in-memory
       `anti_join(..., na_matches = "na")`. On `p`'s level column, use `as.numeric()` for a double level and
       `as.integer()` for an integer level (Review Focus 4).
  5. Bind the levels' rows, `arrange(.sv_row)`, and drop `.sv_row`, `.sv_iv` and `.sv_k`.

- [ ] **Step 1: Write the failing tests:**
  - `test_that("supp_orphans count equals the check's n_orphan")`:
    - a fixture with orphans at the AESEQ level and at the subject level;
    - `expect_equal(nrow(sv_supp_orphans(ae, suppae)), sv_supp_check(ae, suppae)$n_orphan)`.
  - `test_that("bad_idvarval count equals bad_idvarval$n")`:
    - `IDVARVAL` values `"x"`, `" 3 "` (converts, given the ASCII whitespace class), and `"1e999"`;
    - each lands where the check puts it.
  - `test_that("orphans + bad + matched = n_supp")`, using the check's `n_matched`.
  - `test_that("RDOMAIN filter")`: a SUPP with AE and CM rows; only AE rows come back.
  - In test-lazy.R: `test_that("supp ops over duckdb and Arrow equal the in-memory rows")`:
    - the parent as a duckdb table and as an Arrow table with int64 keys, including one key above
      `.Machine$integer.max`;
    - the SUPP in memory and on duckdb;
    - `expect_equal(tolerance = 1e-12)` with the data frame result;
    - the existing "collect is refused" guard wraps the parent.
- [ ] **Step 2: Run them and see them fail.** Expected: FAIL (no function).
- [ ] **Step 3: Implement** the two ops in `sv_derive_rows()` and the console function. Export it with roxygen,
  and add it to `_pkgdown.yml` next to `sv_supp_check`.
- [ ] **Step 4: Run them and see them pass:** `devtools::test(filter = "derive|lazy")`.
- [ ] **Step 5: Commit** with "feat: SUPP orphan and bad IDVARVAL rows, sv_supp_orphans()".

### Task 3: Lazy unmatched and outside_window, and the derived-card recipe

**Files:**
- Modify: `R/lazy.R`, `R/derive.R`, `tests/testthat/test-lazy.R`

**Interfaces:**
- Consumes: `sv_lazy_place(x, y, con_env)`, which returns `list(x, y, cleanup)`. `sv_lazy_release(tbl, con_env)`.
- Produces:
  - `sv_lazy_unmatched(x, y, args, con_env)` in `R/lazy.R`, the twin of the in-memory branch. It places both
    tables, applies the same dplyr expression as Task 1, and returns a duckdb tbl that carries the kept side's
    `sv_tz` / `sv_factors` attributes and a `sv_cleanup` attribute (the `cleanup` function).
  - `sv_derived_source(op, args, inputs)` returns `structure(list(op, args, inputs), class = "sv_derived_source")`.
    `inputs` is a named list of the input **card objects**.
  - `sv_lazy_tbl()` gains one branch: a `sv_derived_source` resolves through `sv_lazy_derived_tbl(source,
    con_env, key)`.
    - That function builds each input's tbl: `sv_lazy_tbl(card$source, con_env, card$id)` for a lazy card, the
      data frame otherwise. It then calls `sv_lazy_unmatched()`.
    - The result is cached in `con_env$tbls[[key]]`.
  - `sv_lazy_release()` also runs `attr(tbl, "sv_cleanup")` when it is set.
  - `sv_card_is_lazy()` is TRUE for a card whose `source` is a `sv_derived_source`.
- [ ] **Step 1: Write the failing tests** (test-lazy.R):
  - `test_that("lazy unmatched equals in-memory over duckdb, Arrow and mixed inputs")`:
    - every pair of `{df, duckdb, arrow}` with at least one lazy side;
    - no rule, and the `between` and `window` rules, each side;
    - `expect_equal(dplyr::collect(r) |> dplyr::arrange(dplyr::across(dplyr::everything())), <in-memory, arranged>, tolerance = 1e-12)`.
  - `test_that("building a lazy derived card never collects")`: with the collect guard on both inputs, `sv_lazy_tbl()`
    of the recipe plus `sv_lazy_count()` succeeds.
  - `test_that("release runs cleanup")`: after `sv_lazy_release()`, the attached temporary table is gone from
    `DBI::dbListTables(con)`.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.** In `sv_derive_rows()`, send any lazy input to `sv_lazy_unmatched()`. The console's
  `sv_unmatched()` then returns a lazy table for lazy input.
- [ ] **Step 4: Run them and see them pass:** `devtools::test(filter = "lazy|derive")`.
- [ ] **Step 5: Commit** with "feat: lazy derived cards (recipe on the session connection)".

### Task 4: Offers in the check replies

**Files:**
- Modify: `R/derive.R`, `R/app_server.R` (`join_diagnostics_request` and `supp_check_request` handlers),
  `tests/testthat/test-derive.R`, `tests/testthat/test-app.R` (or the file that tests those handlers today)

**Interfaces:**
- Produces:
  - `sv_derive_offers_join(d, x_name, y_name, by, rule)`. `d` is the check result. It returns a list of offers
    `{op, inputs = c(x_name, y_name), args = list(by, rule, side), n, label}`:
    - `unmatched` x and y always;
    - `outside_window` x and y only with a rule;
    - none when `sv_join_type_issues()` is not empty;
    - offers with `n == 0` are dropped.
  - `sv_derive_offers_supp(chk, parent_name, supp_name, rdomain)` returns the `supp_orphans` and
    `supp_bad_idvarval` offers, with `args = list(rdomain = rdomain)`. The plan is left out, per decision 8.
  - Both handlers set `reply$derive_offers` (a JSON array, `[]` when empty) on success, gadget and module alike.
    They are not set on an error reply.
- [ ] **Step 1: Write the failing tests:**
  - the offers for a no-rule check (2 offers, the counts from Task 1);
  - a rule check (4, or fewer when one is 0);
  - mixed kinds (0);
  - a SUPP check (2);
  - a `testServer` test showing `derive_offers` in the `sideview_join_diagnostics` message
    (`session$setInputs(join_diagnostics_request = ...)`, then read the sent message as existing tests do).
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement** the two offer functions and the two handler lines.
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit** with "feat: R offers derived cards in join and SUPP check replies".

### Task 5: `derive_request` and `derive_forget` handlers, store, payload

**Files:**
- Modify: `R/derive.R`, `R/app_server.R`, `R/card_store.R` (`sv_card_payload`), `R/normalize.R`
  (`new_sideview_card()` gains `derived = NULL`), `tests/testthat/test-module.R`, `tests/testthat/test-card-store.R`

**Interfaces:**
- Produces:
  - `sv_derive_validate(req, store)`. It returns `NULL` or an error string. It checks:
    - `op %in% sv_derive_ops`;
    - `inputs` is a character vector of 2 store names;
    - for the unmatched ops: `args$side` is `"x"` or `"y"`, `by` is 1 to 20 pairs of length-1 strings, each named
      column exists in its input (checked with `sv_lazy_names()`, which never reads data), the rule passes
      `sv_join_rule_problem()`, and the key kinds match (decision 2);
    - for the SUPP ops: `rdomain` is NULL or matches `^[A-Z][A-Z0-9]{0,7}$`.
    - Anything else in `args` is dropped, not passed on.
  - `sv_derive_card(req, store, con_env)` returns a `sideview_card` with `derived = list(op, inputs, args)`:
    - for the SUPP ops, `args` gains R's `plan` (decision 8);
    - lazy inputs give `source = sv_derived_source(...)`, `is_lazy = TRUE`, `lazy_source = "duckdb"`, `dims[1]`
      from `sv_lazy_count()`, and `data` the 50-row preview;
    - the CDISC tag follows the Global Constraints;
    - the name comes from `sv_derive_name()`.
  - `sv_card_payload()` adds `derived` (`{op, inputs, args}` as JSON-safe lists) when the card has one.
  - Handlers, registered in the gadget and in the module (they are not code-execution inputs):
    - `input$derive_request` checks with `sv_derive_validate()`, then on success builds, `store$add()`s, and sends
      `sideview_card_add` with `{card: <payload>, request_id: req$id}`;
    - on failure (validation, a build error, a lost link) it sends `sideview_derive_result {id, error}` and leaves
      the store unchanged. A lost link or a missing duckdb falls back as the existing `lazy_or_preview` path does,
      with one `sideview_toast`.
    - `input$derive_forget {name}` calls `forget(id)` and `store$remove(name)` only when the card has `derived`.
      Anything else is ignored quietly.
- [ ] **Step 1: Write the failing tests** (`testServer` on `sideviewServer`, plus the gadget server where tests
  already build it):
  - a valid request adds `ae_unmatched_dm` to the store, the sent payload has `derived$op == "unmatched"` and
    `request_id`, and `dims[1]` equals the offer's n;
  - refused with `sideview_derive_result$error` and an unchanged `store$names()`:
    - an unknown op;
    - an input `"Sys.getenv"`;
    - a column `"x; system('id')"`;
    - 21 key pairs;
    - mixed key kinds;
  - a taken exact `name` gives an error;
  - `derive_forget` of a plain card leaves it in the store, and of a derived card removes it and runs `forget`;
  - a lazy derived card (duckdb fixture) gives a payload with no `source` field (extend the `source` is never
    serialised test in test-lazy.R).
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them and see them pass:** `devtools::test(filter = "module|card-store|lazy|derive")`.
- [ ] **Step 5: Commit** with "feat: derive_request / derive_forget handlers".

### Task 6: Cascade, rebuild on replace, derived cards from state (R side)

**Files:**
- Modify: `R/derive.R`, `R/module.R` (`sv_proxy_remove`, `sv_proxy_replace`, `sv_set_state`, `sideviewServer`),
  `R/sideview.R`, `tests/testthat/test-module.R`, `tests/testthat/test-state.R`

**Interfaces:**
- Produces:
  - `sv_derive_dependants(store, name)` returns the names of the derived cards that read `name`, directly or
    transitively, in dependency order. They are read from each card's `derived$inputs`; there is no separate graph.
  - `sv_proxy_remove()` removes the card's dependants from the store first, last-built first, and sends
    `sideview_card_remove` for each.
  - `sv_proxy_replace()`, after the replace, rebuilds each dependant in order with `sv_derive_card()` under the
    same name and sends `sideview_card_replace`. When a rebuild fails (a column in `args` is gone), that card and
    its own dependants are removed as above, with one `sideview_toast` naming them.
  - `sv_derive_from_state(cards, state)`. `state` is the parsed list (`sv_state_from_json()`). The function walks
    `state$pipeline$steps` for `kind == "derive"` in order, builds each card whose inputs are present (exact name =
    `step$table`), and returns `cards` with the derived cards appended. A step that fails is skipped (its browser
    step waits).
  - `sideview(state =)`, `sideviewServer(state =)` and `sv_set_state()` call it before cards are sent.
- [ ] **Step 1: Write the failing tests:**
  - cascade: a chain `ae -> ae_unmatched_dm -> ae_unmatched_dm_unmatched_ex`; `sv_remove_card("ae")` leaves
    neither derived card in the store, and sends two removes in the order child, parent, then the input;
  - rebuild: `sv_replace_card("dm", <dm with one more subject>)` sends a `sideview_card_replace` for
    `ae_unmatched_dm` with one row fewer;
  - rebuild failure: replace `dm` with a table that has no `USUBJID`; the derived card is removed and one toast is
    sent;
  - state: a state JSON with one derive step, given to `sideviewServer(state =)`, has the derived card in the store
    before `sideview_ready`; the same through `sv_set_state()` and the gadget's `sideview(state =)` card list
    (test the card list builder, not the app).
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit** with "feat: derived cards follow their inputs (remove, replace, state)".

### Task 7: The pipeline `derive` step and its code (JS), with the code twin

**Files:**
- Modify: `inst/www/sv-pipeline.js`, `tests/testthat/test-pipeline.R`
- Create: `tests/testthat/test-derive-code.R`

**Interfaces:**
- Consumes: the derive step `{kind: 'derive', key, table, op, inputs, args}`. `key` is
  `JSON.stringify(['derive', op, inputs, args])`, and `args` for the SUPP ops includes `plan`.
- Produces (on `SideviewPipeline` / `Pipeline.prototype`):
  - `deriveLive(step)` returns a boolean (decision 5).
  - `deriveExpr(step)` returns `{code, kind}`. `code` is the right-hand side of the assignment. `kind` is `'arrow'`,
    `'duckdb'` or `null`, the backend the expression ends in.
  - `lazyKind(name)`: when a live derive step has `table === name`, it returns that step's `deriveExpr().kind`.
  - `refFor(name)` returns `ident(name)` for a derived card.
  - `compose()`:
    - live derive steps first, in step order, as `<ident(table)> <- <code>`;
    - derive steps are not chain steps (excluded from `chains`);
    - a chain on a derived card starts from `ident(table)`, using `lazyKind` as above;
    - no `collect()` is added to a derive assignment (spec 5.4).
  - `disableMissing()` skips derive steps (decision 5).
  - `normalize()` keeps unknown fields. An older sideview ignores `kind: 'derive'`; the test is a load of a
    state with one.
- **Code forms.** `X` is the kept table, `Y` the other table, and `k` / `k2` the key pair. All names are written with
  `ident()`, and every join writes `na_matches`.
  - `unmatched`, no rule, side x: `dplyr::anti_join(X, Y, by = <joinBy(by)>, na_matches = "na")`.
  - `unmatched`, rule, side x: the same with `na_matches = "never"`.
  - `outside_window`, side x:
    `X %>% dplyr::semi_join(Y, by = <keys>, na_matches = "never") %>% dplyr::anti_join(Y, by = dplyr::join_by(<keys>, <rule>), na_matches = "never")`.
  - Side y uses the same forms with `Y` as the join's first argument and the key pairs flipped. The rule
    conditions get explicit swapped prefixes:
    - `between`: `between(y$<xCol>, x$<yFrom>, x$<yTo>)`;
    - `window`: the other table is first given `dplyr::mutate(.sv_lo = <offset>, .sv_hi = <offset>)`, then
      `between(x$<yCol>, y$.sv_lo, y$.sv_hi)`;
    - `before`: `y$<xCol> >= x$<yCol>` (`>` when not inclusive);
    - `after`: `<=` (`<` when not inclusive);
    - `overlaps`: `overlaps(y$<xFrom>, y$<xTo>, x$<yFrom>, x$<yTo>)`.
    - For semi and anti joins, `before` / `after` are plain inequalities (no `closest()`), in memory and lazy, as
      the existing lazy semi and anti path already does.
  - **Cross-backend:** extract `render()`'s cross-backend join block (copy, `copy_to`, `to_duckdb` + `compute`, and
    a rule moving Arrow to duckdb) into one helper that `render()` and `deriveExpr()` both call. The existing
    test-pipeline.R must pass unchanged.
  - `supp_orphans` / `supp_bad_idvarval`: one `local({ ... })` block that writes Task 2's algorithm.
    - Reuse `suppKeyExpr(type)` for `.sv_k`, the SUPP side as the merge's `<supp>_q` line writes it (RDOMAIN
      filter, `collect()` when lazy), and `!!unique(s$USUBJID)` in the parent filter.
    - `kind` is `null`.
- [ ] **Step 1: Write the failing pipeline tests** (test-pipeline.R, node through `run_pipeline_js()`):
  - one derive step composes to `ae_unmatched_dm <- dplyr::anti_join(ae, dm, by = "USUBJID", na_matches = "na")`;
  - a filter step on `ae_unmatched_dm` after it composes to that line, a blank line, then
    `ae_unmatched_dm %>%\n  dplyr::filter(...)`;
  - a derive step whose input is missing from `setTables` is not written, and `deriveLive()` is false;
  - `disableMissing("dm")` leaves the derive step's `enabled` unchanged;
  - undo of `add(derive)` removes the step, and redo restores it;
  - `toJSON()` then `load()` round-trips the step;
  - `lazyKind("ae_unmatched_dm")` is `'arrow'` when `ae` and `dm` are Arrow with no rule, and `'duckdb'` with a rule;
  - every form above passes `expect_parses()`.
- [ ] **Step 2: Write the failing code-twin tests** (`test-derive-code.R`). For every op, both sides, every rule
  shape, and inputs in memory, on duckdb and on Arrow (plus one mixed df + duckdb pair):
  1. build the card with `sv_derive_card()`;
  2. compose the derive step in node with the card's `derived` spec and the tables' lazy kinds;
  3. `eval(parse(text = code))` in an environment holding the input objects under their card names;
  4. `dplyr::collect()` when lazy;
  5. `expect_equal()` with the card's rows (the collected source for a lazy card), both sorted with
     `dplyr::arrange(dplyr::across(dplyr::everything()))`, at `tolerance = 1e-12`.
  - Include NA keys (Review Focus 2) and a non-syntactic column `` `my key` `` (Review Focus 3).
  - Skip the duckdb or Arrow cases when the package is missing, as test-lazy.R does.
- [ ] **Step 3: Run them and see them fail.**
- [ ] **Step 4: Implement** in `sv-pipeline.js`, then run `node --check inst/www/sv-pipeline.js`.
- [ ] **Step 5: Run them and see them pass:** `devtools::test(filter = "pipeline|derive-code")`.
- [ ] **Step 6: Commit** with "feat: derive pipeline step and code (twin of the R builder)".

### Task 8: Engine: buttons, request, placement, reconcile, state Open (canvas)

**Files:**
- Modify: `inst/www/sideview.js` (CRLF), `inst/www/sideview.css`, `tests/testthat/test-layout-browser.R`,
  `tests/testthat/test-a11y-browser.R`, `tests/testthat/gui-test-runner.js` (only if the mock DOM needs the new
  attributes)

**Interfaces:**
- Consumes: `derive_offers` on `sideview_join_diagnostics` and `sideview_supp_check`, the `derived` and
  `request_id` fields on `sideview_card_add`, `sideview_derive_result {id, error}`, and the pipeline functions
  from Task 7.
- Produces:
  - `renderJoinCheck()` and `renderSuppCheck()` show one button per offer, under the counts.
    - The button is a real `<button>` with the offer's `label` as its text (escaped) and `data-action="derive-open"`.
    - The engine keeps the offer in a map keyed by a per-render id; the offer JSON is not put in the DOM.
    - There is no button when the reply has no `derive_offers` (the widget, and older R).
  - `SideviewEngine.requestDerive(offer)` applies decision 4 (zoom to an existing card), else
    `send('derive_request', {id, op, inputs, args})` and records `pending[id]`.
  - On `sideview_card_add` with `data.card.derived`:
    - place the card with `freeSpotNear()` (decision 12);
    - set `data-derived="true"` on the card element;
    - when `request_id` is pending and no derive step has `table === name`, `pipeline.add({kind: 'derive',
      key, table: name, op, inputs, args})` (one undo step);
    - `announce('Table <name> added, <n> rows.')` with n = `dims[0]`.
  - On `sideview_derive_result`: `showToast(error, 'danger')`, clear `pending`, and announce the error.
  - `reconcileDerived()` (decision 6), called from the pipeline `onChange` handler and from the end of
    `syncTableMeta()`. Guard against re-entry with a flag.
  - The Pipeline tab: a derive step shows "Derived: <table> from <inputs>" with no enable toggle. When not live it
    shows "waiting for <missing input>" in the disabled style.
  - `openState()`: after the state is applied, `reconcileDerived()` sends the requests. Saved card positions are
    applied when the cards arrive, matched by name as `applyState` already does for cards.
  - Widget (`!this.hasR()`): after `applyState`, when the pipeline has derive steps, show one toast: "Derived tables
    are not available in a saved page; their steps are skipped." `compose()` already skips them, because their cards
    are never live there.
- [ ] **Step 1: Write the failing browser tests** (chromote, real mouse input through `b$Input$dispatchMouseEvent`):
  - gadget with `ae` and `dm`: connect `USUBJID`, open the join check, click "Open 2 unmatched ae rows as a card";
    - a card `ae_unmatched_dm` appears;
    - its rectangle overlaps no other card;
    - the Pipeline tab lists the derive step;
    - the code drawer contains `ae_unmatched_dm <- dplyr::anti_join(`;
  - Undo removes the card, and Redo brings it back with the same row count;
  - a second click on the same button adds no card (decision 4);
  - a module app: the host calls `sv_remove_card(session, "ae")`; both derived cards in a two-level chain go, and
    `sv_add_card()` of `ae` again brings both back;
  - state: Save, then Open of that file in a fresh gadget, gives the same derived cards and positions;
  - axe-core (test-a11y-browser.R) on the drawer with the offer buttons shown: no violations.
- [ ] **Step 2: Run them and see them fail:** `NOT_CRAN=true`, `devtools::test(filter = "layout-browser|a11y-browser")`.
- [ ] **Step 3: Implement**, then run `node --check inst/www/sideview.js`.
- [ ] **Step 4: Run them and see them pass, and run the full suite:** `devtools::test()`. Expected: no failures.
- [ ] **Step 5: Commit** with "feat: open check counts as derived cards on the canvas".

### Task 9: List view buttons

**Files:**
- Modify: `inst/www/sv-listview.js`, `tests/testthat/test-layout-browser.R` (or the list-view browser test file in use)

**Interfaces:**
- Consumes: the same `derive_offers` and `SideviewEngine.requestDerive(offer)` (Task 8).
- Produces: `writeJoinResult()` / `onJoinDiag()` and the SUPP section's result render one `<button>` per offer, with
  the offer's label, after the result text. A click calls `engine.requestDerive(offer)`. The new card then shows in
  the list view's table list through the existing `syncTables()`.
- [ ] **Step 1: Write the failing browser test:**
  - in the list view, run the join check for `ae` / `dm`;
  - the button text equals the drawer's;
  - pressing it with the keyboard (Enter) adds `ae_unmatched_dm` to the list;
  - the live region says "Table ae_unmatched_dm added, 2 rows.".
- [ ] **Step 2: Run it and see it fail.**
- [ ] **Step 3: Implement.** Run `node --check inst/www/sv-listview.js`.
- [ ] **Step 4: Run it and see it pass.**
- [ ] **Step 5: Commit** with "feat: list view opens check counts as cards".

### Task 10: Docs, wire names, full check

**Files:**
- Modify: `CLAUDE.md`, `NEWS.md` (CRLF), `README.md`, `_pkgdown.yml`, `MEMORY.md` (CRLF), `vignettes/` (the CDISC
  article, or the article the spec section 12 names), `docs/` (rebuilt)

- [ ] **Step 1: `CLAUDE.md`:**
  - add `derive_request` and `derive_forget` to the inputs;
  - add `sideview_derive_result` to the messages, and `derived` / `request_id` to `sideview_card_add`;
  - add `derive_offers` to `sideview_join_diagnostics` and `sideview_supp_check`, as an R-only field like
    `cdisc_notes`;
  - add a **Derived cards** paragraph:
    - inputs as loaded;
    - the R builder <-> `compose()` code twin (`test-derive-code.R`);
    - the reconcile loop;
    - derive liveness is computed;
    - `source` stays unserialised.
- [ ] **Step 2: `NEWS.md`:** a `# sideview 0.10.0 (development)` heading with the D1 bullets. **`README.md`:** one Key
  Features bullet. Add a short article section with synthetic data and no screenshots yet (screenshots come with D3).
- [ ] **Step 3: Check:**
  - `pkgdown::check_pkgdown()` is clean;
  - `devtools::document()`;
  - `devtools::check()` gives 0 errors and 0 warnings;
  - rebuild `docs/`, then delete `docs/CLAUDE.*` and `docs/MEMORY.*` and their `sitemap.xml` / `search.json`
    entries.
- [ ] **Step 4: `MEMORY.md`:**
  - the roadmap row: "D1 implemented on `d/d1-derived-cards`, not pushed";
  - a change-log entry listing what was verified, in which browser, and the full test counts;
  - the manual RStudio checks (dialog, Viewer pane, external browser) listed as **to do by the user**.
- [ ] **Step 5: Commit** with "docs: derived cards (D1)".
