# sideview 0.8.0 text-first accessibility (A + C): implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give blind programmers a list view, plain-sentence console output and announcements, and guard all of
it with an accessibility test harness, without changing what the canvas does.

**Architecture:** First the harness (C): AX-tree, keyboard and axe-core checks in chromote. Then A, in four
stacked PRs:
- **A1:** sentence formatters, in R and JS twins, plus the print methods built on them.
- **A2:** a live region, the shortcuts switch, table ARIA and alert toasts.
- **A3:** a list view in its own JS file (`inst/www/sv-listview.js`). It is owned by `SideviewEngine` and reads
  the same `VirtualTable`, pipeline and request paths as the canvas.
- **A4:** docs, the NVDA pass and the release notes.

**Tech Stack:**
- R 4.5.2, testthat 3 and roxygen2.
- Shiny, htmlwidgets and htmltools.
- chromote, for `Accessibility.getFullAXTree` and `Input.dispatchKeyEvent`.
- axe-core 4.10.3, installed with npm in CI only.
- Node.js, for the JS twin tests.
- Vanilla JS (ES5 style, as `sideview.js`).

**Spec:** `plans/2026-11-14-accessibility-text-first-design.md`

## Global Constraints

- **Data:** synthetic fixtures only. Never commit real patient data.
- **Assets:** a new JS file must be added to:
  - `sv_asset_version()`'s `files` and the `script =` vector in `R/app_ui.R:31-55`;
  - the widget dependency in `R/widget.R`.

  Never hard-code an asset version.
- **CSS:** `--sv-*` tokens only, every rule scoped under `.sideview-container`. Dark tokens are kept equal in
  `.sv-theme-dark` and in the `@media (prefers-color-scheme: dark) .sv-theme-auto` block (test-theme.R), and
  meet WCAG 4.5:1.
- **Icons:** inline SVG icons only. No emoji or Unicode glyph icons.
- **JS:**
  - escape all table-derived text before `innerHTML`, and use `CSS.escape` in selectors;
  - remove every global listener in `destroy()`;
  - register every new R-to-client handler through `onMessage()`.
- **Sentences:**
  - counts use `big.mark = ","` (R `fmt_n()`, JS `fmtN()`);
  - percentages use one decimal, followed by the word "percent";
  - at most 3 sample keys;
  - a missing value reads "missing";
  - ASCII only, apart from data values;
  - one fact per sentence;
  - at most 100 characters a sentence, apart from data values.
- **Module:**
  - the list view sends only inputs the canvas already sends, and names only cards in the R store;
  - Insert Script, Run & Exit, Run in R and Run Console are not rendered in a module;
  - the Copilot section is absent without `llm_fn`.
- **Options:** `getOption("sideview.view", "canvas")` (validated with `match.arg(c("canvas", "list"))`) and
  `getOption("sideview.shortcuts", TRUE)`.
- **State:** `view.mode` is optional and has no schema bump (as `view.labels_row`). It is never required on load.
- **Honest label:** use this text verbatim: "checked with NVDA and automated WCAG tests; not yet tested by blind
  users".
- **Tests:** run test files singly: `Rscript -e "devtools::test(filter = '<name>')"`. Browser tests need
  `NOT_CRAN=true`. Check JS syntax with `node --check inst/www/<file>.js`.
- **Git and release:**
  - Commit with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never use bare `git stash`.
  - Never push, open a PR or merge without the user's say-so.
  - Each PR updates `NEWS.md` and `MEMORY.md` (with what was verified). It updates `CLAUDE.md` when it adds an
    input, a message, a rule or an option.
- **Branches:** stacked, each cut from the previous one:
  - `a11y/c-harness` from `main`
  - `a11y/a1-console`
  - `a11y/a2-announce`
  - `a11y/a3-listview`
  - `a11y/a4-docs`

## Rulings made by this plan

1. **`sv_detect_discrepancies()` returns a list, not a data frame** (`R/codegen.R:279`). Its class is
   `c("sv_discrepancies", "list")`, and `unclass()` gives the plain list. `sv_suggest_mappings()` is a data frame:
   - its class is `c("sv_mappings", "data.frame")`;
   - `as.data.frame.sv_mappings()` drops the subclass;
   - `[.sv_mappings` is not defined, so subsets keep printing as sentences.

   Spec section 7 was corrected to match when this plan was written.
2. **ARIA counts include the header row.** `aria-rowcount` = data rows + 1. The header row has
   `aria-rowindex="1"`, and data row *i* (0-based in the sorted, filtered table) has `aria-rowindex = i + 2`.
   Tests assert `rowcount == true_rows + 1`. This is the ARIA rule; the spec's "equals the true row count" means
   the data rows.
3. **Percentages are rounded half up on exact integers**, so R and JS agree byte for byte (see Task 6).
4. **The toast stack loses `aria-live`.** Non-error toasts are spoken through the announcer, and error toasts
   carry `role="alert"`, so nothing is spoken twice.
5. **"Filter" in the list view** does not open the canvas popover. It opens the Transform section's Filter
   builder with the table and column selected, and focuses the first empty field.

## Review Focus

1. **Sort or filter on the canvas, then a page read in the list view.** The page shows the sorted, filtered rows,
   with `aria-rowindex` taken from the filtered order. Test: Task 13, `list rows follow canvas sort and filter`.
2. **A lazy card in the gadget.** Paging fetches row windows through `sideview_rows_request` and never collects the
   table. Test: Task 13, `list paging of a lazy card asks R for windows`.
3. **Drawer panes moved into the list view and back.** A half-filled builder keeps its values, and one click runs
   one handler. Test: Task 15, `moved panes keep input and fire once`.
4. **Names with `<`, `"`, spaces or non-ASCII letters.** They render as text in headings, captions, labels and
   selectors. Test: Task 13, `list view escapes names`.
5. **The shortcuts switch when `localStorage` throws.** Shortcuts are off in the list view, and typing in an input
   never fires a shortcut in either state. Test: Task 9, `shortcuts default off in list view when storage throws`
   (completed in Task 12) and `typing never fires shortcuts`.

---

## PR C: accessibility test harness (`a11y/c-harness`)

### Task 1: AX-tree and keyboard helpers, and accessible names on today's controls

**Files:**
- Create: `tests/testthat/helper-a11y.R`
- Create: `tests/testthat/test-a11y-browser.R`
- Modify: wherever a control without a name is found, most likely `R/app_ui.R` (toolbar) and
  `inst/www/sideview.js` (`buildToolbar` near line 1940, the drawer near `DRAWER_TABS`, line 4181, the AI bar)

**Interfaces:**
- Consumes (from `helper-browser.R`):
  - `skip_if_no_browser()`
  - `sv_start_app(app_expr, app_file)` → `list(proc, url)`
  - `sv_open_page(url, width, height, wait_for)` → the chromote session
  - `sv_js(b, expr)` and `sv_wait_js(b, expr, timeout)`
  - `sv_example_app("proxy")`
  - `sv_fixture_code`
- Produces (in `helper-a11y.R`):
  - `sv_ax_tree(b)`: a `data.frame` with columns `role`, `name`, `ignored` (logical), `backend_id` (integer),
    `level` (integer or NA, for headings), `focusable` (logical). Built from
    `b$Accessibility$getFullAXTree()$nodes`.
  - `sv_ax_unnamed(tree)`: the rows where `role %in% c("button", "textbox", "combobox", "checkbox", "switch",
    "spinbutton", "searchbox", "listbox", "slider")`, `!ignored` and `name == ""`.
  - `sv_key(b, key, code = key, modifiers = 0L, text = NULL)`: a `keyDown` then a `keyUp` through
    `b$Input$dispatchKeyEvent`. Modifiers use the CDP bit mask: Alt 1, Ctrl 2, Meta 4, Shift 8.
  - `sv_tab(b, n = 1L, shift = FALSE)`.
  - `sv_focus_info(b)`: a list of `tag`, `role`, `name` (`aria-label`, else the text content) and `classes` for
    `document.activeElement`.
  - `sv_widget_url(widget_expr)`: evaluates `save_sideview(<expr>, tmp, selfcontained = FALSE)` in the test
    process and returns `paste0("file:///", normalizePath(tmp, "/"))`.
  - `sv_a11y_pages()`: a named list of three page specs for the gadget, the widget and the module. Each is
    `list(open = function(theme, width, height) b)` and uses the fixture `patients`, `visits`, `labs`.

- [ ] **Step 1: Write the failing tests.** In `test-a11y-browser.R`:

```r
test_that("every control has an accessible name (canvas, all modes)", {
  skip_if_no_browser()
  for (mode in names(sv_a11y_pages())) {
    b <- sv_a11y_pages()[[mode]]$open(theme = "light", width = 1360, height = 820)
    bad <- sv_ax_unnamed(sv_ax_tree(b))
    expect_equal(nrow(bad), 0, info = paste(mode, paste(bad$role, collapse = ", ")))
    b$close()
  }
})
test_that("Tab reaches the toolbar, then the drawer tabs, in DOM order", {
  skip_if_no_browser()
  b <- sv_a11y_pages()$gadget$open("light", 1360, 820)
  seen <- vapply(1:40, function(i) { sv_tab(b); sv_focus_info(b)$name }, "")
  expect_true(any(grepl("Fit", seen)))
  expect_true(which(grepl("Fit", seen))[1] < which(grepl("Pipeline", seen))[1])
})
```

- [ ] **Step 2: Run and see it fail, or pass.** Run
  `NOT_CRAN=true Rscript -e "devtools::test(filter = 'a11y-browser')"`. Expected: the unnamed-control test FAILS
  and lists the controls without names (icon buttons, inputs labelled only by placeholder). If it passes, go on.
- [ ] **Step 3: Give each listed control a name.** Use a visible `<label for>` where there is visible text, and
  `aria-label` on icon-only buttons, with the same text as the `title`. Do not change behaviour.
- [ ] **Step 4: Run again.** The same command. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "test: AX-tree and keyboard helpers; name every control"`

### Task 2: axe-core matrix for the canvas, and fixes or accepted rules

**Files:**
- Modify: `tests/testthat/helper-a11y.R`
- Modify: `tests/testthat/test-a11y-browser.R`
- Modify: `inst/www/sideview.css`, for contrast and target-size fixes found

**Interfaces:**
- Produces:
  - `sv_axe_path()`: the value of `Sys.getenv("SV_AXE_PATH")` if that file exists, else
    `file.path(sv_pkg_root(), "node_modules/axe-core/axe.min.js")` if it exists, else `""`.
  - `skip_if_no_axe()`: skips with "axe-core not found (set SV_AXE_PATH)".
  - `sv_axe_run(b, context = ".sideview-container")`: injects the file once
    (`Runtime.evaluate` of its text), then runs
    `axe.run(context, {runOnly: {type: "tag", values: SV_AXE_TAGS}})` with `awaitPromise = TRUE`, and returns
    `violations` as a data frame with `id`, `impact`, `n_nodes`, `targets` (the first 3 selectors, pasted).
  - The constant `SV_AXE_TAGS <- c("wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa")`.
  - The named character vector `SV_AXE_ACCEPTED` in `test-a11y-browser.R`, mapping a rule id to its reason. It
    starts empty and gets an entry only for a violation that belongs to sub-project B.

- [ ] **Step 1: Write the failing test.** For each `mode` in the gadget, widget and module, each `theme` in light
  and dark, and each `size` in `c(1360, 820)` and `c(375, 812)`:

```r
v <- sv_axe_run(b)
v <- v[!v$id %in% names(SV_AXE_ACCEPTED), ]
expect_equal(nrow(v), 0, info = paste(mode, theme, size[1], paste(v$id, v$targets, collapse = "; ")))
```

- [ ] **Step 2: Run it.** Run `npm install --no-save axe-core@4.10.3` in the package root (`node_modules` is
  already in `.Rbuildignore` and `.gitignore`; add it if not). Then run
  `NOT_CRAN=true Rscript -e "devtools::test(filter = 'a11y-browser')"`. Expected: FAIL, with a list of
  violations.
- [ ] **Step 3: Triage each violation.**
  - Fix it when the fix is local: colour tokens (re-run test-theme.R), a missing label, or a target smaller than
    24 px (`min-width`/`min-height: 24px` on `.sideview-container button`).
  - Otherwise add it to `SV_AXE_ACCEPTED` with a one-line reason, and add a backlog line in `MEMORY.md` under
    "Sub-project B".
- [ ] **Step 4: Run again.** Run the same command, then
  `Rscript -e "devtools::test(filter = 'theme')"`. Expected: both PASS.
- [ ] **Step 5: Commit.** `git commit -m "test: axe-core WCAG 2.2 AA matrix for the canvas; contrast and target fixes"`

### Task 3: Today's shortcut and typing rules, and the CI job

**Files:**
- Modify: `tests/testthat/test-a11y-browser.R`
- Modify: `.github/workflows/R-CMD-check.yaml`
- Modify: `NEWS.md`, `MEMORY.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: `sv_key()` and `sv_tab()` from Task 1.
- Produces: the CI job `a11y` in `R-CMD-check.yaml`.

- [ ] **Step 1: Write the tests.**
  - `typing never fires shortcuts`: focus the AI bar input, `sv_key(b, "f")`, then
    `sv_key(b, "d")`. Expect the zoom (`engine.panzoom.getScale()`) unchanged, the drawer state unchanged, and the
    input value `"fd"`.
  - `canvas shortcuts fire when the canvas owns the keyboard`: focus the container, then `sv_key(b, "d")`.
    Expect the drawer to toggle.
- [ ] **Step 2: Run.** Run `NOT_CRAN=true Rscript -e "devtools::test(filter = 'a11y-browser')"`. Expected: PASS
  (these pin today's behaviour). If one fails, fix `isTypingTarget` / `ownsKeyboard` in `sideview.js:1745-1760`.
- [ ] **Step 3: Add the CI job.** In `R-CMD-check.yaml` add the job `a11y`:
  - `runs-on: ubuntu-latest`, with `env: NOT_CRAN: true` and
    `SV_AXE_PATH: ${{ github.workspace }}/node_modules/axe-core/axe.min.js`.
  - Steps:
    1. checkout;
    2. `r-lib/actions/setup-r@v2`;
    3. `r-lib/actions/setup-r-dependencies@v2`, with `extra-packages: any::chromote, any::shinytest2,
       any::duckdb, any::arrow`;
    4. `actions/setup-node@v4` with `node-version: 20`;
    5. `browser-actions/setup-chrome@v1`;
    6. `npm install --no-save axe-core@4.10.3`;
    7. `Rscript -e 'for (f in c("a11y-browser", "say")) devtools::test(filter = f, stop_on_failure = TRUE)'`.

  `say` is the test file from Task 6.
- [ ] **Step 4: Update the docs.**
  - **`CLAUDE.md`, "Build, test, run":** "Accessibility tests: `test-a11y-browser.R` (AX tree, keys, axe-core).
    Install `npm install --no-save axe-core@4.10.3` or set `SV_AXE_PATH`. An accepted axe rule goes in
    `SV_AXE_ACCEPTED` with its reason."
  - **`NEWS.md` (development version):** the harness.
  - **`MEMORY.md`:** what ran, the counts, and the accepted rules.
- [ ] **Step 5: Commit.** `git commit -m "ci: a11y job with pinned axe-core; pin shortcut/typing rules"`

---

## PR A1: sentences in the console (`a11y/a1-console`)

### Task 4: Shared sentence helpers (R and JS twins)

**Files:**
- Create: `R/say.R`
- Modify: `inst/www/sv-pipeline.js` (helpers, plus their names in the `api` object near line 2290)
- Create: `tests/testthat/test-say.R`

**Interfaces:**
- Consumes: R `fmt_n()` (`R/diagnostics.R:186`) and JS `fmtN()` (`sv-pipeline.js:1155`).
- Produces, as internal R functions with JS twins (exported on `SideviewPipeline`):

| R | JS | Result |
|---|---|---|
| `sv_say_pct(num, den)` | `sayPct(num, den)` | `"93.3 percent"`, or `NA_character_` / `null` when `den == 0` |
| `sv_say_list(x)` | `sayList(x)` | `"A"`, `"A and B"`, `"A, B, and C"` (Oxford comma); `""` when empty |
| `sv_say_samples(x, total = NULL, max = 3)` | `saySamples(x, total, max)` | the first `max` of `x` through `sv_say_value`; if `total > shown`: `"A, B, C, and 7 more"`, else `sv_say_list(shown)` |
| `sv_say_value(v)` | `sayValue(v)` | `NA` / `null` → `"missing"`; a string containing `", "` → wrapped as `"(P05, 2)"`; else `as.character(v)` / `String(v)` |
| `sv_say_num(v)` | `sayNum(v)` | a whole number → `fmt_n(v)`; otherwise the codebook key text of the value rounded to 6 significant digits: R `format_key(signif(v, 6))` (`R/codebook.R:339`), JS `numKey(signif6(v))` (`sv-pipeline.js:1455,1599`) |
| `sv_say_check_lines(x)` | `sayCheckLines(x)` | a character vector, with each element longer than 100 characters reported by the tests only (not truncated) |

  The percentage algorithm is the same in both. `num` and `den` are integer counts:

```
tenths = floor((2000 * num + den) / (2 * den))   # rounds half up exactly
text   = paste0(tenths %/% 10, ".", tenths %% 10, " percent")
```

- [ ] **Step 1: Write the failing tests.** In `test-say.R`, using `run_pipeline_js()` from `helper-node.R`:

```r
test_that("say helpers: R and JS agree byte for byte", {
  cases <- list(c(140, 150), c(1, 3), c(2, 3), c(1, 8), c(0, 7), c(7, 7), c(1, 2000))
  r <- vapply(cases, function(k) sv_say_pct(k[1], k[2]), "")
  js <- unlist(run_pipeline_js(sprintf("out = %s.map(function (k) { return P.sayPct(k[0], k[1]); });",
                                       jsonlite::toJSON(cases))))
  expect_identical(r, js)
  expect_identical(r[1:2], c("93.3 percent", "33.3 percent"))
  expect_identical(sv_say_pct(1, 2000), "0.1 percent")   # 0.05 rounds up
  expect_identical(sv_say_list(c("A", "B", "C")), "A, B, and C")
  expect_identical(sv_say_samples(c("P05", "P09", "P12", "P20"), total = 10), "P05, P09, P12, and 7 more")
  expect_identical(sv_say_samples(c("P05", "P09")), "P05 and P09")
  expect_identical(sv_say_value(NA), "missing")
  expect_identical(sv_say_num(1234567), "1,234,567")
  # the same vectors through P.sayList / P.saySamples / P.sayValue / P.sayNum give identical strings
})
```

- [ ] **Step 2: Run and see it fail.** Run `Rscript -e "devtools::test(filter = 'say')"`. Expected: FAIL,
  `could not find function "sv_say_pct"`.
- [ ] **Step 3: Implement the six R functions in `R/say.R` and their twins in `sv-pipeline.js`.** Add the JS names
  to the `api` object.
- [ ] **Step 4: Run.** Run the same command, then `node --check inst/www/sv-pipeline.js`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat: sentence helpers with R/JS twins"`

### Task 5: `sv_say_join` / `sayJoin`, and the join print method

**Files:**
- Modify: `R/say.R`, `R/diagnostics.R:161-184` (`print.sv_join_diagnostics` rewritten)
- Modify: `inst/www/sv-pipeline.js`
- Modify: `tests/testthat/test-say.R`, `tests/testthat/test-diagnostics.R` (update the print expectations),
  `tests/testthat/test-lazy.R`

**Interfaces:**
- Consumes:
  - the Task 4 helpers;
  - `sv_join_rule_label(rule, kind_x)` (`R/join_rules.R:78`) and JS `ruleLabel()`;
  - the fields of `sv_join_diagnostics()` (`R/diagnostics.R`) and of `joinDiagnostics()`. Both have the same
    snake_case fields.
- Produces:
  - `sv_say_join(d, x_name = "x", y_name = "y")`: a character vector.
  - JS `sayJoin(d, xName, yName)`: an array of strings.
  - `print.sv_join_diagnostics(x, ...)`: `cat(sv_say_join(x, attr(x, "x_name") %||% "x", ...), sep = "\n")`.
    If the names are not stored on the object, store them as `x_name` / `y_name` fields in
    `sv_join_diagnostics()` and its lazy twin. Add the fields to both twins and to `joinDiagnostics()`. The
    parity test covers them.

The sentences come in this order, each emitted only when its condition holds. `X` and `Y` are the names; `K` is
the key text: `sv_say_list` of the `left` column names, written `left = right` when the two names differ.

| # | Condition | Sentence |
|---|---|---|
| 1 | `!is.null(d$error)` | `"Join check failed: <error>."`, and nothing else |
| 2 | always | `"Join of X and Y by K is <relationship with '-' replaced by ' '>."` |
| 3 | rule present | `"Date rule: <sv_join_rule_label(rule, rule_kind)>."` |
| 4 | `rule_dropped_x + rule_dropped_y > 0` | `"The rule drops <n> X rows and <m> Y rows."` |
| 5 | always | `"<matched_x> of <n_x> X rows match, <pct>."` (`pct` omitted with its comma when `n_x == 0`) |
| 6 | always | the same for Y |
| 7 | `n_x - matched_x > 0` | `"<k> X rows have no match, for example <samples>."` When `dup_keys_x == 0`, `samples = sv_say_samples(unmatched_x, total = k)`. Otherwise it is `"keys " + sv_say_samples(unmatched_x)`. |
| 8 | the same for Y | |
| 9 | `na_x > 0` / `na_y > 0` | `"<n> X rows have a missing key."` |
| 10 | always | `"Rows by join type: left <n>, inner <n>, right <n>, full <n>, semi <n>, anti <n>."` (from `rows`) |
| 11 | each hint | `"<Label with first letter upper-cased> would match <extra_x> more X rows."` If `extra_y > 0`, add `" and <extra_y> more Y rows"` before the full stop. |
| 12 | each `type_issues`, then `warnings` | the text as it is, with a `.` added if it does not end in `.`, `!` or `?` |

Example output for the fixture with 150 patients, 140 matched and P05, P09, P12 unmatched: line 1 is
`"Join of patients and visits by patient_id is one to many."`, and line 3 is
`"10 patients rows have no match, for example P05, P09, P12, and 7 more."`

- [ ] **Step 1: Write the failing tests.**
  - In `test-say.R`, `sayJoin twin`: build 4 fixtures (one to one; one to many with unmatched rows; a multi-key
    join with a hint; a date rule that drops rows) plus one `{error}` result.
    - For each, compute `sv_say_join(sv_join_diagnostics(...), "patients", "visits")` in R.
    - Compute `P.sayJoin(P.joinDiagnostics(...), "patients", "visits")` in Node on the same data (as
      test-diagnostics.R's parity test does).
    - `expect_identical(r, js)`.
    - Assert the example lines above exactly.
  - Also assert:

```r
expect_true(all(!grepl("[^\x20-\x7e]", lines_without_data)))
expect_true(all(nchar(lines_without_data) <= 100))
```

    `lines_without_data` is the fixture with ASCII names.
  - In `test-lazy.R`, `lazy join says the same`: `sv_say_join(sv_lazy_join_diagnostics(<duckdb tables>), ...)`
    is identical to the in-memory sentences, for a duckdb fixture and an arrow fixture.
  - In `test-diagnostics.R`: `expect_output(print(d), "Join of x and y by id is one to one.", fixed = TRUE)`.
    This replaces the old padded-line expectations.
- [ ] **Step 2: Run and see them fail.** Run `Rscript -e "devtools::test(filter = 'say')"`. Expected: FAIL.
- [ ] **Step 3: Implement `sv_say_join`, `sayJoin` and the new print method.**
- [ ] **Step 4: Run the test files.** Run `say`, then `diagnostics`, then `lazy`, then `join-rules`, one at a time.
  Run `node --check inst/www/sv-pipeline.js`. Expected: all PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat: join checks as sentences (sv_say_join / sayJoin)"`

### Task 6: SUPP and profile sentences, classes and print methods

**Files:**
- Modify: `R/say.R`, `R/supp.R`, `R/codebook.R`, `R/lazy.R` (lines 1454 and 1652: add the class),
  `R/app_server.R` (handlers near lines 343 and 386, which send `unclass()`)
- Modify: `R/codegen.R:279` (`sv_detect_discrepancies` class) and `R/copilot.R:36` (`sv_suggest_mappings`
  class), plus every place where the server sends them to the browser
- Modify: `inst/www/sv-pipeline.js`
- Test: `test-say.R`, `test-supp.R`, `test-codebook.R`, `test-lazy.R`, `test-copilot.R`, `test-codegen.R`

**Interfaces:**
- Produces:
  - `sv_say_supp(chk, parent_name, supp_name)` and JS `saySupp(chk, parentName, suppName)`.
  - `sv_say_profile(p, name)` and JS `sayProfile(p, name)`.
  - The classes `sv_supp_check`, `sv_column_profile`, `sv_discrepancies` (on a list) and `sv_mappings` (on a
    `data.frame`), with:
    - `print.sv_supp_check()`, `print.sv_column_profile()`, `print.sv_discrepancies()` and `print.sv_mappings()`;
    - `as.data.frame.sv_mappings()`.

    These are registered with `@export` (S3method) in roxygen. The class functions are internal.
  - `sv_supp_check()` and `sv_column_profile()` return objects with `name` stored as fields (`parent_name`,
    `supp_name`; `name` for the profile, when it is known). The JSON helpers drop these fields, so the browser
    payload is unchanged.

**SUPP sentences**, in order. `S` is `supp_name` and `P` is `parent_name`:

| # | Condition | Sentence |
|---|---|---|
| 1 | `error` | `"SUPP check failed: <error>."` only |
| 2 | always | `"Merging S into P adds <n> columns: <sv_say_list(column names)>."` (one column: `"adds 1 column: AESOSP."`) |
| 3 | always | `"<n_matched> of <n_supp> S rows match a P row."` |
| 4 | `n_orphan > 0` | `"<n_orphan> S rows have no P row, for example <samples>."` Each sample is `"<USUBJID> <IDVAR> <IDVARVAL>"`. |
| 5 | `bad_idvarval$n > 0` | `"<n> S rows have an IDVARVAL that does not convert, for example <samples>."` |
| 6 | `n_other_rdomain > 0` | `"<n> S rows are for another domain and are left out."` |
| 7 | `repeats$n > 0` | `"<n> S rows repeat a QNAM for the same P row."` |
| 8 | `length(clashes)` | `"These QNAMs clash with P columns: <list>."` |
| 9 | `length(two_level)` | `"These QNAMs use more than one IDVAR: <list>."` |
| 10 | `drift$stale` | `"Merge needs refreshing: <sv_say_list(drift$reasons)>."` |

**Profile sentences**, in order. `N` is the name; `L` is the label, added as `", L"` when it is non-empty:

| # | Condition | Sentence |
|---|---|---|
| 1 | always | `"NL is a <kind word> column."` The kind words are: numeric → `number`, character → `text`, logical → `true or false`, date → `date`, datetime → `date-time`, other → the first class. |
| 2 | always | `n_missing == 0`: `"No values are missing."`; otherwise `"<n_missing> of <n> values are missing, <pct>."` |
| 3 | always | `"It has <n_distinct> distinct values."` (one: `"1 distinct value"`) |
| 4 | `unique_key` | `"Every value is unique, so it can be a key."` |
| 5 | numeric and `stats` | `"Minimum <min>, median <median>, maximum <max>."` then `"Mean <mean>, standard deviation <sd>."` (via `sv_say_num`) |
| 6 | date or datetime and `stats` | `"Earliest <min>, latest <max>."` |
| 7 | `nrow(top) > 0` and not numeric | `"Most common values: <v> (<n>), ... up to 5."`; then, if `n_other > 0`, `"<n_other> rows have other values."` |
| 8 | each `issues` | the text as it is, with a `.` added if it is missing |

**Discrepancies print** (R only):
- `"<exact_count> values match exactly."`
- `"<fuzzy_count> values nearly match."`
- `"<only_x_count> values are only in x, for example <samples of only_in_x>."` and the same for y.
- `"Match rate <pct>."`, using `sv_say_pct(exact_count, unique_x)`.

**Mappings print** (R only):
- `"<n> suggested joins."` (`"No suggested joins."` when there are none);
- then one line per row: `"<from_table>.<from_col> to <to_table>.<to_col>, confidence <sprintf('%.2f')>: <reason>."`;
- rows that share a `group` get the prefix `"Group <group>: "`.

- [ ] **Step 1: Write the failing tests.**
  - `saySupp twin` and `sayProfile twin` in `test-say.R`.
    - SUPP: use `sv_cdisc_fixtures()` in four cases: clean, orphans, a bad IDVARVAL, and a clash.
    - Profile: a numeric column, a text column, a date column, an all-NA column and a unique key.
    - R and JS are identical in each case.
  - In `test-supp.R` and `test-codebook.R`:
    - `expect_s3_class(sv_supp_check(...), "sv_supp_check")` and `expect_output(print(chk), "Merging SUPPAE into AE adds")`.
    - The browser JSON is unchanged: `expect_identical(sv_supp_check_json(chk), <the snapshot of the JSON text
      before this task>)`. Capture the snapshot in Step 1 by running the current code once and pasting the
      string.
  - In `test-lazy.R`: `sv_lazy_supp_check` and `sv_lazy_column_profile` carry the classes, and their sentences are
    identical to the in-memory ones (duckdb and arrow).
  - In `test-copilot.R`:
    - `expect_s3_class(m, "sv_mappings")`;
    - `expect_identical(class(as.data.frame(m)), "data.frame")`;
    - `expect_output(print(m[0, ]), "No suggested joins.")`.
  - In `test-codegen.R`:
    - `expect_s3_class(d, "sv_discrepancies")`;
    - `expect_true(is.list(unclass(d)))`;
    - `expect_output(print(d), "values match exactly.")`.
- [ ] **Step 2: Run and see them fail.** Run `say`, then `supp`, then `codebook`, then `copilot`, then `codegen`,
  one at a time. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - The classes go on the return values, in-memory and lazy.
  - The server handlers and the JSON helpers call `unclass()` / `as.data.frame()` before `jsonlite`.
  - Add the sentence functions, then the print methods built on them.
- [ ] **Step 4: Run the test files.** Run each file named in Step 2, plus `lazy`, `module` and `app`, singly. Run
  `node --check inst/www/sv-pipeline.js`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat: SUPP checks, profiles, discrepancies and mappings print as sentences"`

### Task 7: `sv_describe()`, and the A1 docs

**Files:**
- Create: `R/describe.R`
- Test: `tests/testthat/test-describe.R`
- Modify: `_pkgdown.yml` (the reference index), `NAMESPACE` / `man/` (via `devtools::document()`), `NEWS.md`,
  `MEMORY.md`, `CLAUDE.md`

**Interfaces:**
- Consumes:
  - `sv_normalize()` / `sideview_card` fields `name`, `dims` and `cdisc` tag;
  - `sv_column_profile(x, column = )`, which goes to `sv_lazy_column_profile()` for a lazy table;
  - `sv_say_num()` and `fmt_n()`.
- Produces: `sv_describe(x, ..., n_levels = 5)` (exported). It returns the lines invisibly, as a character vector
  of class `sv_description`, with `print.sv_description()` (`cat(x, sep = "\n")`).
  - **Table line:** `"<name>, <domain> domain, <rows> rows by <cols> columns, <k> columns have missing values."`
    The domain part is left out when the table is untagged. Use `"1 column has"` when `k == 1` and `"no columns
    have"` when `k == 0`.
  - **Column line** (indented two spaces): `"<name>, <label>, <kind word>: <n_missing> missing, <n_distinct> distinct"`.
    - numbers add `", min <min>, median <median>, max <max>"`;
    - text adds `", top <v> (<n>), ..."` for the first `n_levels` rows of `top`.

    The line ends with `"."`, and the label is left out when it is empty.
  - Names come from the `...` names, or from the deparsed expressions, as in `sideview()`.

- [ ] **Step 1: Write the failing tests.**
  - `sv_describe(patients)` gives the expected first line and one line per column.
  - `expect_invisible(sv_describe(patients))`.
  - The same lines for a duckdb `tbl` and an arrow table holding the same data. Skip when the package is missing,
    and never call `collect()` (assert the lazy profile function was used, as test-lazy.R does).
  - `n_levels = 2` limits the top values.
  - The ASCII and 100-character rules hold for ASCII fixtures.
- [ ] **Step 2: Run and see them fail.** Run `Rscript -e "devtools::test(filter = 'describe')"`. Expected: FAIL.
- [ ] **Step 3: Implement it and update the docs.**
  - Write the roxygen with a runnable example on a small `data.frame`, then run `devtools::document()`.
  - Add `sv_describe` to `_pkgdown.yml`, then run `pkgdown::check_pkgdown()`. Expected: clean.
  - **`NEWS.md`:** "Results print as sentences. Use `as.data.frame()` (mappings) or `unclass()` (discrepancies,
    checks, profiles) for the raw object." Also note the new `sv_describe()`.
  - **`CLAUDE.md`:** "Sentences: `sv_say_join` / `sv_say_supp` / `sv_say_profile` (R/say.R) and `sayJoin` /
    `saySupp` / `sayProfile` (sv-pipeline.js) are twins (test-say.R, byte-equal). Change them together."
- [ ] **Step 4: Run the test files.** Run `describe`, `say`, `codebook` and `lazy` singly. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat: sv_describe() text summaries; docs for console sentences"`

---

## PR A2: announcements and the shortcuts switch (`a11y/a2-announce`)

### Task 8: Live region and announcements

**Files:**
- Modify: `inst/www/sideview.js`, `inst/www/sideview.css` (`.sv-sr-only`: the standard visually-hidden pattern)
- Test: `tests/testthat/test-a11y-browser.R`, `tests/testthat/gui-test-runner.js` (if a mock-DOM test breaks
  on the toast change)

**Interfaces:**
- Consumes:
  - `onJoinDiagnostics` (4699), `onSuppCheck` (5188), `onColumnProfile` (5544), `showToast` (6785) and the
    copilot reply handler (6879);
  - the pipeline's change emit;
  - `P.sayJoin`, `P.saySupp` and `P.sayProfile`.
- Produces:
  - `engine.announce(text)`: queues `text` into `.sideview-announcer` (`aria-live="polite"`, `role="status"`,
    class `sv-sr-only`), one per engine, created in the engine's constructor.
    - Messages are spaced at least 500 ms apart.
    - Text equal to the previous message is cleared, then set again 50 ms later, so it is spoken again.
    - Each message is pushed to `engine.announceLog` (the last 50, for tests).
  - `engine.stepAnnouncement(kind, verb, count)` → a string. `verb` is `added` or `removed`, giving
    `"Join step added. 3 steps."`. Undo and redo give `"Undone. 2 steps."` and `"Redone. 3 steps."`, and a single
    step reads `"1 step."`. The kind words are: join `Join`, filter `Filter`, arrange `Sort`, mutate `Mutate`,
    recode `Recode`, summarise `Summarise`, pivot `Reshape`, supp `SUPP merge`, custom `Custom`, any other
    `Pipeline`.
  - Calls added:
    - a finished join, SUPP or profile check announces its first sentence;
    - a step add, remove, undo or redo announces;
    - Copy announces `"Code copied."` and Insert announces `"Code inserted."`;
    - a non-error toast announces its text;
    - a copilot reply announces `"Copilot replied, <n> lines of code."` (`"Copilot replied."` when there is no
      code).
  - Toasts (Ruling 4): the stack loses `aria-live`, error toasts get `role="alert"` and the others have no role.

- [ ] **Step 1: Write the failing tests.**
  - `join check is announced as its first sentence`: in the gadget, add a connection with
    `engine.addConnections([{fromTable: 'patients', fromCol: 'patient_id', toTable: 'visits', toCol:
    'patient_id', type: 'left_join'}])`. Wait until `engine.announceLog` contains a string starting with
    `"Join of"`. It must equal `sv_say_join(sv_join_diagnostics(patients, visits, by = "patient_id"),
    "patients", "visits")[1]`, computed in the test process.
  - `step changes are announced`: after that join, `announceLog` contains `"Join step added. 1 step."`. After
    `engine.pipeline.undo()` it contains `"Undone. 0 steps."`.
  - `error toasts are alerts`: `showToast('x', 'error')` makes an element with `role="alert"`. No ancestor of a
    toast has `aria-live`.
- [ ] **Step 2: Run and see them fail.** Run `NOT_CRAN=true Rscript -e "devtools::test(filter = 'a11y-browser')"`.
  Expected: FAIL.
- [ ] **Step 3: Implement it as specified in Interfaces.**
- [ ] **Step 4: Run the checks.** Run the same command, `node --check inst/www/sideview.js` and
  `node tests/testthat/gui-test-runner.js` (or the test file that wraps it). Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat: live-region announcements; error toasts as alerts"`

### Task 9: Shortcuts switch (WCAG 2.1.4)

**Files:**
- Modify: `inst/www/sideview.js` (the shortcut handler near 2733, the `?` dialog), `R/app_ui.R`
  (`sv_ui_build`: `data-sv-shortcuts`), `R/widget.R` (`options$shortcuts`),
  `inst/htmlwidgets/sideview.js` (pass `options.shortcuts`)
- Test: `tests/testthat/test-a11y-browser.R`, `tests/testthat/test-widget.R`, `tests/testthat/test-app.R`

**Interfaces:**
- Produces:
  - `engine.shortcutsOn()` → a boolean, decided in this order:
    1. the stored value of `localStorage['sideview.shortcuts']`, `"on"` or `"off"` (read in try/catch; a throw
       counts as no value);
    2. otherwise the R default: `data-sv-shortcuts="false"` or `options.shortcuts === false` means off;
    3. otherwise the view: off when `engine.view === 'list'`, on otherwise.

    Before A3, `engine.view` is always `'canvas'`.
  - `engine.setShortcuts(on)`: stores `"on"` / `"off"` (try/catch), updates every
    `[data-sv-shortcuts-switch]` (`role="switch"`, `aria-checked`) and announces `"Keyboard shortcuts on."` or
    `"Keyboard shortcuts off."`.
  - In the `?` dialog, a `<button role="switch" data-sv-shortcuts-switch aria-checked>` labelled "Keyboard
    shortcuts" at the top of the list.
  - The single-key handler returns early when `!this.shortcutsOn()`. `Ctrl+K` and `Ctrl+Enter` are not gated.
  - On the R side, `sv_ui_build()` writes `data-sv-shortcuts="false"` when
    `isFALSE(getOption("sideview.shortcuts", TRUE))`, and `sideview_widget()` sets
    `options$shortcuts <- getOption("sideview.shortcuts", TRUE)` unless the user set it.

- [ ] **Step 1: Write the failing tests.**
  - `shortcuts switch turns single keys off`: focus the container. `engine.setShortcuts(false)`, then
    `sv_key(b, "d")`: the drawer does not toggle. Then `sv_key(b, "k", modifiers = 2L)`: the search dialog opens.
  - `R option turns shortcuts off`: start the gadget with `options(sideview.shortcuts = FALSE)`; then
    `engine.shortcutsOn() === false`.
  - `shortcuts default off in list view when storage throws`: before the engine starts, add the init script
    `Object.defineProperty(window, 'localStorage', {get: function () { throw new Error('blocked'); }})` (CDP
    `Page.addScriptToEvaluateOnNewDocument`). `shortcutsOn()` is true in canvas view. The list-view half of this
    test is added in Task 12.
  - `typing never fires shortcuts` (Task 3) runs again with shortcuts on and with them off.
  - In `test-widget.R`: `sideview_widget(mtcars)$x$options$shortcuts` is `TRUE`, and is `FALSE` under
    `withr::with_options(list(sideview.shortcuts = FALSE), ...)`.
  - In `test-app.R`: the container tag has `data-sv-shortcuts="false"` under the option.
- [ ] **Step 2: Run and see them fail.** Run `a11y-browser`, then `widget`, then `app`, singly. Expected: FAIL.
- [ ] **Step 3: Implement it as specified.**
- [ ] **Step 4: Run.** Run the same files and `node --check`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat: keyboard shortcuts switch and sideview.shortcuts option"`

### Task 10: Table ARIA on canvas cards, and the A2 docs

**Files:**
- Modify: `inst/www/sideview.js` (`VirtualTable` render near lines 39-600)
- Modify: `NEWS.md`, `MEMORY.md`, `CLAUDE.md`
- Test: `tests/testthat/test-a11y-browser.R`

**Interfaces:**
- Produces (Ruling 2):
  - each card `<table>` has a `<caption class="sv-sr-only">` holding the escaped card name;
  - `aria-rowcount = getRowCount() + 1` and `aria-colcount = colNames.length`;
  - the header `<tr aria-rowindex="1">`, and data rows `aria-rowindex = i + 2` for the virtual row index `i` in
    the current (sorted, filtered) order;
  - the values are updated on every render, sort and filter.

- [ ] **Step 1: Write the failing test.** `card tables carry row counts`:
  - For `labs` (5000 rows), the AX tree has a `table` named `"labs"`.
  - `table.getAttribute('aria-rowcount') == "5001"`.
  - After scrolling the body 2000 px, the first rendered data row's `aria-rowindex` equals its virtual index + 2.
  - After a filter that leaves 12 rows, `aria-rowcount == "13"`.
- [ ] **Step 2: Run and see it fail.** Run `NOT_CRAN=true Rscript -e "devtools::test(filter = 'a11y-browser')"`.
  Expected: FAIL.
- [ ] **Step 3: Implement it, then update the docs.**
  - **`CLAUDE.md`:**
    - "Announcements: `engine.announce()` (one `.sideview-announcer` per engine). A new result or step path
      announces through it."
    - "Shortcuts: gated by `shortcutsOn()`. The `sideview.shortcuts` option is carried as `data-sv-shortcuts` /
      `options.shortcuts`."
  - **`NEWS.md`:** a line for each new feature.
  - **`MEMORY.md`:** what was verified.
- [ ] **Step 4: Run all browser tests.** Run `a11y-browser`, then `layout-browser`, singly. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat: table ARIA on canvas cards"`

---

## PR A3: the list view (`a11y/a3-listview`)

### Task 11: `view =` arguments, the `view.mode` state field and the starting view (R side)

**Files:**
- Modify: `R/sideview.R:155`, `R/widget.R:69`, `save_sideview()`, `R/module.R:55` (`sideviewUI`),
  `R/app_ui.R:394` (`sideview_ui`, `sv_ui_build`), `R/state.R`
- Test: `test-app.R`, `test-widget.R`, `test-module.R`, `test-state.R`

**Interfaces:**
- Produces:
  - `view = getOption("sideview.view", "canvas")` on `sideview()`, `sideview_widget()` and `sideviewUI()`.
    `save_sideview()` takes it through the widget. Each validates with
    `view <- match.arg(view, c("canvas", "list"))`.
  - The gadget and module containers carry `data-sv-view="<view>"`, and the widget `options$view`.
  - `R/state.R` keeps `view.mode` when it is present and valid (`"canvas"` / `"list"`), drops it otherwise, and
    never requires it.

- [ ] **Step 1: Write the failing tests.**
  - `sideview_ui(cards, view = "list")` has `data-sv-view="list"`.
  - `expect_error(sideview(mtcars, view = "grid", run = FALSE), "should be one of")`.
  - `withr::with_options(list(sideview.view = "list"), sideview_widget(mtcars))$x$options$view == "list"`.
  - `sideviewUI("a", view = "list")` carries the attribute.
  - `test-state.R`, next to the `labels_row` round trip at line 449: a state JSON with
    `"view": {"labels_row": true, "mode": "list"}` round-trips through `sv_state_from_json()` /
    `sv_state_json()` unchanged. A state without `mode` loads.
- [ ] **Step 2: Run and see them fail.** Run `app`, then `widget`, then `module`, then `state`, singly. Expected:
  FAIL.
- [ ] **Step 3: Implement it, and add roxygen `@param view` to each function.** Run `devtools::document()`.
- [ ] **Step 4: Run.** Run the same files. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat: view = argument and view.mode state field"`

### Task 12: List view shell: `setView`, hiding, toggle, Summary, skip links and focus

**Files:**
- Create: `inst/www/sv-listview.js`, which defines `global.SideviewListView`
- Modify: `R/app_ui.R:31-55` (asset files and the script list, loaded before `sideview.js`), `R/widget.R`
  (the widget dependency), `inst/www/sideview.js`, `inst/www/sideview.css`,
  `inst/htmlwidgets/sideview.js` (`options.view`)
- Test: `test-a11y-browser.R`, `test-assets.R`

**Interfaces:**
- Consumes:
  - `engine.announce()` and `engine.shortcutsOn()` / `setShortcuts()` from A2;
  - `getState()` / `applyState()` (sideview.js 5885 / 5987);
  - the Save and Open handlers.
- Produces:
  - `new SideviewListView(engine)` → `lv`, with these methods:
    - `lv.render()`: the full render;
    - `lv.renderTable(name)`: re-renders one table's section;
    - `lv.onJoinDiag(sig, d)`, `lv.onSuppCheck(d)` and `lv.onColumnProfile(d)`: the result hooks;
    - `lv.destroy()`.

    `lv.el` is the `<section class="sideview-listview" role="region" aria-label="sideview list view">`.
  - `engine.view`: `'canvas'` | `'list'`.
  - `engine.setView(mode)`:
    1. sets `hidden` and `aria-hidden="true"` on the canvas viewport, the minimap, the connector SVG and the
       hit layer (canvas mode reverses this);
    2. updates the toolbar toggle `[data-sv-view-toggle]` (`aria-pressed`, label "List view" or "Canvas view");
    3. announces `"List view"` or `"Canvas view"`;
    4. moves focus to the list's first `<h2>` (`tabindex="-1"`) or to the container.

    `setView` creates the list view lazily the first time.
  - The engine calls `this.listView && this.listView.onJoinDiag(...)` and the other hooks from its existing reply
    handlers.
  - `getState().view.mode = this.view`. `applyState` calls `setView(state.view.mode)` after the canvas restore,
    when the value is valid.
  - The starting view comes from `data-sv-view` or `options.view`.
  - The Summary section has:
    - skip links: `"Skip to tables"` (`#<ns>sv-lv-tables`), `"Skip to join"` and `"Skip to code"`;
    - `<h2>Summary</h2>`;
    - the sentence `"<n> tables, <j> join steps, <s> pipeline steps. Code is ready."`, or `"No code yet."` when
      `P.isNoCode(code)`;
    - the view toggle, Save, Open, and the shortcuts switch (`data-sv-shortcuts-switch`).

    The h2 sections are, in this order: Summary, Tables, Join, Merge SUPP, Transform, Pipeline, Code, Copilot.
    Copilot is present only when the LLM is available. Empty sections are filled by Tasks 13-15.

- [ ] **Step 1: Write the failing tests.**
  - `list view hides the canvas from the AX tree`: after `engine.setView('list')`, no non-ignored AX node lies
    inside the viewport. After `setView('canvas')`, no node of `.sideview-listview` is in the tree, and the
    canvas `transform` style equals the value before the switch.
  - `list view headings are in order`: the AX heading names at level 2 equal
    `c("Summary", "Tables", "Join", "Merge SUPP", "Transform", "Pipeline", "Code")` in the gadget without an LLM.
  - `view switch moves focus and announces`: after a press on the toggle with `sv_key(b, "Enter")`,
    `sv_focus_info(b)$tag == "H2"` and `announceLog` ends with `"List view"`.
  - `data-sv-view starts the list view`: `sideview(..., view = "list")` opens with `engine.view == "list"`.
  - The Task 9 storage test, list half: with storage throwing, `setView('list')` makes `shortcutsOn()` false.
  - `test-assets.R`: `sv_asset_version()` covers `sv-listview.js`.
- [ ] **Step 2: Run and see them fail.** Run `a11y-browser`, then `assets`. Expected: FAIL.
- [ ] **Step 3: Implement it as specified, with CSS under `.sideview-container .sideview-listview`.** The list is a
  normal-flow, scrolling column with `max-width: 72ch`, its controls are at least 24 px, and it uses tokens only.
- [ ] **Step 4: Run.** Run the same files and `node --check inst/www/sv-listview.js`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat: list view shell, view toggle, state view.mode"`

### Task 13: Tables section (columns, rows pager, Sort, Filter, Inspect)

**Files:**
- Modify: `inst/www/sv-listview.js`, `inst/www/sideview.js` (`VirtualTable`: add `cellText` and `onBlock`)
- Test: `test-a11y-browser.R`, `test-lazy-browser.R`

**Interfaces:**
- Consumes:
  - `engine.cards` (a `Map`) and `cardElByName(name)`;
  - `el._virtualTable` (`getRowCount()`, `colNames`, `colTypes`, `requestBlock(b)`);
  - the card's `col_labels`, `data-rows-basis` and CDISC tag;
  - `sortColumn` (6377), `requestColumnProfile` (5532) and `P.sayProfile`.
- Produces:
  - `VirtualTable.prototype.cellText(i, col)` → the display string the card cell would show (`"NA"` for missing),
    or `null` while the block is not loaded. This is factored out of the card's own cell render, so both share
    it.
  - `VirtualTable.prototype.onBlock(fn)`: registers `fn(blockIndex)`, called after a remote block lands, and
    returns an unsubscribe function. The list view unsubscribes in `destroy()`.
  - Each table is an `<h3 id="<ns>sv-lv-t-<index>">`, with the text
    `"<name>, <domain> domain, <rows> rows by <cols> columns, <basis>."`. `basis` is `"full table"`, or
    `"preview of the first <n> rows"` when `data-rows-basis="preview"`.
  - The columns are a `<ul>`, one `<li>` per column:
    - the item reads `"<name>, <label>, <kind word>, <n_distinct> values, <n_missing> missing"`, with the counts
      taken from the card's sparkline stats when present, and otherwise without the counts;
    - each item has the buttons `Sort <name>`, `Filter <name>` and `Inspect <name>`;
    - Inspect writes `P.sayProfile(...)` as a `<p>` per sentence into the item.

    A table with more than 30 columns puts the list inside a closed `<details><summary>Columns (<n>)</summary>`.
  - The rows are a `<table>` with `<caption>` `"<name> rows"`, `<th scope="col">` and the ARIA counts of Ruling 2.
    There are 25 rows a page, the buttons `"Previous rows"` / `"Next rows"` (disabled at the ends) and a
    `"Go to row"` `<input type="number" min=1 max=n>` with a `Go` button. A page change announces
    `"Rows <a> to <b> of <n>."` and keeps focus on the pressed control. A table with 0 rows shows `"No rows."`
    and has no pager.
  - Sort cycles through ascending, descending and none through `sortColumn`, and announces
    `"Sorted <name> by <col> ascending."`, `"... descending."` or `"Sort removed."`.
  - Filter follows Ruling 5. Its builder is wired up in Task 15; until then the button calls
    `engine.openBuilder('filter', {table, column})`, which Task 15 defines. Leave the call guarded with
    `if (engine.openBuilder)`.

- [ ] **Step 1: Write the failing tests.**
  - `list rows table matches the card`: for `labs`, `aria-rowcount == "5001"`. After Next, the first row's
    `aria-rowindex == "27"` and its cells equal `vt.cellText(25, c)` for each column, and `announceLog` ends with
    `"Rows 26 to 50 of 5,000."`. Go to row 4990 shows rows 4990 to 5000 (row index 4991).
  - `list rows follow canvas sort and filter` (Review Focus 1): sort `labs` by `value` descending and filter
    `value > 10` on the canvas. In list view, page 1 equals the first 25 rows of
    `dplyr::arrange(dplyr::filter(labs, value > 10), dplyr::desc(value))`, and `aria-rowcount` equals that
    `nrow + 1`.
  - `list view escapes names` (Review Focus 4): a gadget with `` `a<b "c" é` = data.frame(`x <y>` = 1:3) ``.
    - The h3 text contains `a<b "c" é`, and no element `<b>` exists in the list view.
    - The caption, the column item and the button names contain the raw characters.
    - `document.querySelector('[data-sv-table="' + CSS.escape(name) + '"]')` finds the section.
  - `a table with more than 30 columns starts closed`: for a 40-column fixture, `details.open === false`.
  - `Inspect writes the profile sentences`: after Inspect `patients.age`, the item's paragraphs equal
    `sv_say_profile(sv_column_profile(patients$age), "age")`.
  - In `test-lazy-browser.R`, `list paging of a lazy card asks R for windows` (Review Focus 2): a duckdb card in the
    gadget. Next and Go to row 4000 cause `sideview_rows_request` messages (count them with a JS spy on
    `Shiny.setInputValue`), and the cells equal `dplyr::collect(dplyr::slice(...))` computed in the test. R never
    calls `collect()` on the whole table; this is asserted by the existing lazy spy pattern in that file.
- [ ] **Step 2: Run and see them fail.** Run `a11y-browser`, then `lazy-browser`. Expected: FAIL.
- [ ] **Step 3: Implement it as specified.**
- [ ] **Step 4: Run.** Run the same files, `layout-browser` (the card render was refactored) and `node --check` on
  both JS files. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat: list view tables, columns and paged rows"`

### Task 14: Join and Merge SUPP sections

**Files:**
- Modify: `inst/www/sv-listview.js`
- Test: `test-a11y-browser.R`

**Interfaces:**
- Consumes:
  - `engine.joinDiagFor(stepLike)` (about line 4626), where `stepLike = {table, right, by: [{left, right}],
    rule}`;
  - `engine.addConnections(list)` (3615), with items `{fromTable, fromCol, toTable, toCol, type}`, plus the rule
    through `pipeline.setJoinRule(id, rule)` after the step exists;
  - the suggested mappings reply (`sideview_suggested_mappings`, with `group` and `kind`);
  - `requestSuppCheck` (5099) and the existing SUPP merge path;
  - `P.sayJoin`, `P.saySupp`, `P.RULE_SHAPES` and `P.ruleSlots`.
- Produces:
  - The Join form has labelled `<select>`s: left table, left column, right table, right column. "Add another key
    pair" adds a row of selects, and "Remove key pair" removes one.
  - The date rule is a `<select>` of `RULE_SHAPES` labels plus "No rule", with the slot inputs given by
    `ruleSlots(shape)`.
  - The join type `<select>` offers `JOIN_TYPES`.
  - "Check join" calls `joinDiagFor()`. On the reply (`lv.onJoinDiag(sig, d)`), it writes one `<p>` per sentence
    of `P.sayJoin(d, left, right)` into `[data-sv-join-result]` and announces the first sentence. Focus stays.
  - "Add join step" is disabled until a reply without `error` for the current form signature (`joinSig`). It calls
    `addConnections()`, then `setJoinRule`, and moves focus to the new step's item in the Pipeline section.
  - Auto Map: the button "Suggest joins" sends `request_suggested_mappings`. Each suggestion is one `<li>`
    (`"<from_table>.<from_col> to <to_table>.<to_col>, confidence <n>"`) with an "Add" button. A CDISC `group`
    adds as one `addConnections` call, so it is one undo step.
  - Merge SUPP: one `<h3>` per SUPP-tagged card, `"<SUPP> into <parent>, <n> QNAMs"`, with "Check" and "Merge".
    Check writes `P.saySupp` sentences and announces the first. A stale result announces
    `"Merge needs refreshing."`. A SUPP card with no parent present reads `"<SUPP>: parent <domain> is not on the
    canvas."` and has no buttons.
  - A reply that lands after a view switch, or while focus is elsewhere, still writes into the section found by the
    signature or card name (spec section 8).

- [ ] **Step 1: Write the failing tests.**
  - `list join check speaks the R sentence`: fill the form with `patients.patient_id` to `visits.patient_id` and
    press Check. The result paragraphs equal `sv_say_join(sv_join_diagnostics(patients, visits, "patient_id"),
    "patients", "visits")`, and `announceLog` contains the first of them.
  - `Add join step adds one step and draws its spline`: after Add, `engine.pipeline.enabledCount() == 1`, one
    `.sideview-connector-svg path` exists in the canvas, and focus is on the new Pipeline item.
  - `a failing check keeps Add disabled`: a date rule on a non-date column gives an error sentence, and Add stays
    `disabled`.
  - `CDISC group adds as one undo step`: with `sv_cdisc_cards()`, add the ADAE~AE group. `pipeline.undo()` once
    removes all of its keys.
  - `SUPP check and merge from the list`: the SUPPAE Check sentences equal `sv_say_supp(sv_supp_check(...), "AE",
    "SUPPAE")`. Merge adds a `supp` step.
  - `reply lands after a view switch`: press Check, call `setView('canvas')` before the reply, then
    `setView('list')`. The result is in the Join section.
- [ ] **Step 2: Run and see them fail.** Run `NOT_CRAN=true Rscript -e "devtools::test(filter = 'a11y-browser')"`.
  Expected: FAIL.
- [ ] **Step 3: Implement it as specified.**
- [ ] **Step 4: Run.** Run the same command, then `supp`, then `node --check`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat: list view join and SUPP sections"`

### Task 15: Transform, Pipeline, Code and Copilot through drawer pane moves

**Files:**
- Modify: `inst/www/sv-listview.js`, `inst/www/sideview.js` (`ensureDrawer`, `DRAWER_TABS` at 4181)
- Test: `test-a11y-browser.R`, `test-module.R` (rendered-button checks)

**Interfaces:**
- Consumes: the drawer's pane nodes (one per `DRAWER_TABS` entry), the delegated handlers on the container, and
  `TAB_ALIASES`.
- Produces:
  - `engine.movePanes(target)`, where `target` is `'list'` or `'drawer'`:
    - It moves the existing pane nodes with `appendChild` (never clones or re-renders them):
      - the builders (filter, arrange, mutate, recode, summarise, plus reshape where it is a builder) go to the
        Transform section, each under an `<h3>`;
      - `pipeline` goes to Pipeline;
      - the code area and its buttons go to Code;
      - `chat` goes to Copilot.
    - It records each node's original parent and next sibling, so that `'drawer'` restores the exact order.
    - It hides the drawer shell in list mode.
    - `setView` calls it.
  - `engine.openBuilder(kind, preset)`. In list view it focuses the builder's `<h3>`, applies `preset.table` /
    `preset.column` to its selects and focuses the first empty field. In canvas view it opens the drawer tab
    (Ruling 5).
  - The Pipeline items get `tabindex="-1"` and an id per step key, so focus can move to them (Task 14).
  - In module mode, and when a button is not rendered today, it stays absent. Without an LLM there is no Copilot
    section.

- [ ] **Step 1: Write the failing tests.**
  - `moved panes keep input and fire once` (Review Focus 3): on the canvas, type `"age > 5"` into the Filter
    builder's condition and leave it unsubmitted. `setView('list')`: the same input node
    (compared by a `data-test-id` set beforehand) is inside `.sideview-listview` and still holds `"age > 5"`.
    Press the builder's Add with `sv_key(b, "Enter")`: `pipeline.enabledCount()` rises by exactly 1.
    `setView('canvas')`: the node is back in the drawer at its original index.
  - `Filter from a column opens the builder preset`: Filter `patients.age` in Tables focuses the Filter builder,
    with table `patients` and column `age` selected.
  - `module list view has no code-execution buttons`: in `sv_example_app("proxy")` list view, no Insert Script,
    Run & Exit, Run in R or Run Console button exists.
  - `no Copilot without an LLM`: no heading "Copilot".
- [ ] **Step 2: Run and see them fail.** Run `a11y-browser`, then `module`. Expected: FAIL.
- [ ] **Step 3: Implement it as specified.**
- [ ] **Step 4: Run.** Run the same files, `layout-browser` and `node --check`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat: list view transform, pipeline, code and copilot via pane moves"`

### Task 16: Card changes, lost lazy link, keyboard walkthrough, list axe matrix, and the A3 docs

**Files:**
- Modify: `inst/www/sv-listview.js`, `inst/www/sideview.js` (call `listView.renderTable` from the card
  add/replace/remove handlers and from the toast `card` path)
- Modify: `NEWS.md`, `MEMORY.md`, `CLAUDE.md`
- Test: `test-a11y-browser.R`

**Interfaces:**
- Produces:
  - **Card messages:** `sideview_card_add`, `sideview_card_replace` and `sideview_card_remove` re-render that
    table's section only, and announce `"Table <name> added."`, `"Table <name> replaced."` or
    `"Table <name> removed."`.
  - **Lost link:** a `sideview_toast` with `card` re-renders the heading with the preview basis. The toast text is
    already announced (Task 8).
  - **No cards:** the Tables section reads `"No tables yet."`
  - **The `CLAUDE.md` standing rule:** "Every new feature (0.9.0 D, 0.10.0 E and later) must work in the list view
    (`inst/www/sv-listview.js`) and print as sentences in the console."
  - **The `CLAUDE.md` architecture line:** `sv-listview.js` (`SideviewListView`, owned by the engine), with
    `setView`, `movePanes` and `openBuilder`.

- [ ] **Step 1: Write the failing tests.**
  - `replacing a card re-renders only its section`: in the module (`sv_example_app("proxy")`) list view, mark the
    `visits` section node with `data-test-mark`, then replace `labs` through the proxy. The `visits` node still
    has its mark, the labs heading shows the new row count, and `announceLog` contains `"Table labs replaced."`.
  - `keyboard-only walkthrough gives the canvas code`: in list view, using only `sv_tab`, `sv_key` (Enter, Space,
    ArrowDown) and typing into focused inputs:
    1. add the join `patients.patient_id` to `visits.patient_id`;
    2. add the filter `age > 30` on `patients`;
    3. with `sv_cdisc_cards()`, merge SUPPAE into AE.

    Then `parse(text = code)` succeeds, and `code` is identical to the code from a second session that adds the
    same three steps through `engine.addConnections`, `pipeline.add` and the SUPP merge call. With shortcuts off,
    pressing `f`, `t` and `d` on a list heading changes nothing (the zoom, the drawer and the theme).
  - **axe on the list view:** the Task 2 matrix gains `view = "list"`. That is 2 views, 2 themes, 2 sizes and 3
    modes, with 0 violations outside `SV_AXE_ACCEPTED`.
  - **AX facts in the list view:** every rows table has `aria-rowcount == rows + 1`, and every control has a name
    (`sv_ax_unnamed()`).
- [ ] **Step 2: Run and see them fail.** Run `NOT_CRAN=true Rscript -e "devtools::test(filter = 'a11y-browser')"`.
  Expected: FAIL.
- [ ] **Step 3: Implement and fix.** Fix what the tests find, then update the docs (see Interfaces, and NEWS lines
  for `view =`, the list view and the shortcuts switch).
- [ ] **Step 4: Run the full suite.** Run every test file singly (`Rscript -e "devtools::test(filter = '<f>')"`
  for each file in `tests/testthat`), browser files with `NOT_CRAN=true`, then
  `Rscript -e "devtools::check()"`. Expected: 0 errors and 0 warnings. Notes as before.
- [ ] **Step 5: Verify in RStudio and commit.** Check the list view by hand in RStudio's dialog, Viewer pane and
  an external browser (CLAUDE.md verification rule), and record the results in `MEMORY.md`. Then
  `git commit -m "feat: list view card updates, keyboard walkthrough, list axe matrix"`

---

## PR A4: docs, NVDA pass and release (`a11y/a4-docs`)

### Task 17: The NVDA script and NVDA pass

**Files:**
- Create: `plans/2026-11-14-nvda-script.md`
- Modify: `MEMORY.md`, plus any fix the pass finds, in its owning file, with a test in `test-a11y-browser.R`

**Interfaces:**
- Consumes: the finished list view; NVDA 2026.2 (installed and running) with Speech Viewer (NVDA menu, then Tools,
  then Speech Viewer); computer use.

- [ ] **Step 1: Write the script.** Write 15 numbered tasks, each with the setup, the keys to press and the
  expected speech (quote the sentence the formatter gives):
  1. open the list view with the toolbar button;
  2. list headings (NVDA+F7) and find AE;
  3. jump to Tables with the skip link;
  4. read the AE column list;
  5. go to row 30 of labs and read its cells with Ctrl+Alt+arrows;
  6. Next page;
  7. Inspect AESEV;
  8. join DM to AE and hear the check;
  9. Add join step and land on the step;
  10. Undo;
  11. merge SUPPAE into AE;
  12. add a filter;
  13. copy the code;
  14. turn shortcuts off and press F in browse mode;
  15. switch back to canvas view.
- [ ] **Step 2: Run the script.** Run it with computer use in Chrome or Edge on a `viewer = "browser"` gadget,
  then once each in RStudio's dialog and Viewer pane. Copy the Speech Viewer text for each task.
- [ ] **Step 3: Record and fix.** Record each task as pass or mismatch in `MEMORY.md`. For each mismatch that is
  ours, fix it and add a test. RStudio-pane weaknesses are documented, not fixed.
- [ ] **Step 4: Re-run what changed.** Re-run the affected browser tests and the mismatched script steps.
  Expected: PASS, with the speech matching.
- [ ] **Step 5: Commit.** `git commit -m "docs: NVDA script and pass results"`

### Task 18: Article, README, NEWS, issue template and the version

**Files:**
- Create: `vignettes/articles/screen-reader.Rmd` ("Using sideview with a screen reader")
- Create: `.github/ISSUE_TEMPLATE/accessibility-feedback.yml`
- Modify: `_pkgdown.yml` (the articles menu), `README.md` (one Key Features bullet), `NEWS.md` (the 0.8.0
  heading), `DESCRIPTION` (`Version: 0.8.0`), `MEMORY.md`

- [ ] **Step 1: Write the article.** Cover:
  - `options(sideview.view = "list")`, `sideview(..., view = "list")` and `options(sideview.shortcuts = FALSE)`;
  - a reading tour by headings;
  - console sentences, `sv_describe()` and `print()` of each check;
  - the recommendation of browser mode (`viewer = "browser"`) for screen readers, and the RStudio-pane limits
    found in Task 17;
  - the honest label, verbatim.

  Code chunks are `eval = FALSE` apart from one `sv_describe()` chunk on a synthetic data frame.
- [ ] **Step 2: Write the issue template.** The template "Accessibility feedback" has required fields for the
  screen reader and its version, the browser or RStudio pane, the sideview version, what you did and what you
  heard or expected. The label is `accessibility`.
- [ ] **Step 3: Update the README, NEWS and version.**
  - **README:** add `- **Screen Reader Ready**: a list view (`view = "list"`) and plain-sentence results; checked
    with NVDA and automated WCAG tests; not yet tested by blind users.`
  - **NEWS:** gather the 0.8.0 entries under `# sideview 0.8.0`, with the honest label.
  - **DESCRIPTION:** `Version: 0.8.0`.
- [ ] **Step 4: Build and check.**
  - `pkgdown::check_pkgdown()` must be clean.
  - Build the site with `pkgdown::build_site(preview = FALSE)`, with `RSTUDIO_PANDOC` set as in CLAUDE.md.
  - Delete `docs/CLAUDE.*` / `docs/MEMORY.*` and their `sitemap.xml` / `search.json` entries.
  - `Rscript -e "devtools::check()"` must give 0 errors and 0 warnings.
  - The article renders.
- [ ] **Step 5: Commit, then ask.** `git commit -m "docs: screen-reader article, README, NEWS 0.8.0, feedback template"`.
  Then ask the user whether to push the five branches and open the PRs, in the order C, A1, A2, A3, A4.
