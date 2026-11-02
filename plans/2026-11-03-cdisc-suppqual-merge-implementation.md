# CDISC SUPPQUAL Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold a SUPP-- table into its parent SDTM/SEND domain as one labelled column per QNAM. The merge is a pipeline step that is checked before it is added, and its generated code guards the assumptions it was built on.

**Architecture:**
- Tags gain `rdomains` and `merge_targets`.
- A twin check checks a SUPP table against its parent and returns a plan, counts and problems:
  - `sv_supp_check()` in R, `SideviewPipeline.suppCheck()` in JS;
  - a lazy twin, `sv_lazy_supp_check()`.
- The browser adds a typed `supp` step from that plan. `compose()` writes tidyr/dplyr code with stop() guards.
- The gadget and modules ask R through `supp_check_request` → `sideview_supp_check`; the widget checks in the browser.

**Tech Stack:** R 4.5.2, dplyr, tidyr, shiny, arrow/duckdb (Suggests), plain JS (`sv-pipeline.js`, `sideview.js`), testthat, chromote/shinytest2.

**Spec:** `plans/2026-11-03-cdisc-suppqual-merge-design.md`. Section numbers (§) below refer to it. Read the § a task names before starting it.

## Global Constraints

- Release `0.7.0`, branch `claude/cdisc-suppqual-merge`.
- Commit locally only; never push or merge.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Run R with `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"`.
- Run one test file with `Rscript -e "devtools::load_all(); testthat::test_file('tests/testthat/<file>')"`. Real-browser tests need `NOT_CRAN=true`.
- Synthetic fixtures only (`tests/testthat/helper-cdisc.R`); no real patient data.
- Exported R functions use `sv_` and roxygen. Every export goes in the `_pkgdown.yml` reference index.
- R/JS twins return the same snake_case fields. Change both together. Lazy twins equal the in-memory result with `expect_equal(tolerance = 1e-12)`; lazy tables are never collected, except the RDOMAIN-filtered SUPP rows (§6.3, §7.1).
- Generated code must `parse()`, with a test for every new generator path. It uses the pipeline's pipe (`this.pipe`, `%>%` or `|>`). Names go through `ident()` and strings through `str()` (sv-pipeline.js).
- JS:
  - escape table-derived text before `innerHTML`;
  - use `CSS.escape` in selectors;
  - register handlers only through `onMessage()`;
  - carry `ns` on new R→client messages in module mode (`send()` adds it).
- Inline SVG icons only, never emoji. CSS uses `--sv-*` tokens scoped under `.sideview-container`; every token used must be defined.
- Tags are never saved in workspace state. The schema stays v0.3.0; an older sideview skips the unknown `supp` kind.
- Only schema summaries reach the LLM. This feature sends nothing new to it.
- Every UI change is checked in a real browser (chromote, real mouse input) and in RStudio, and recorded in `MEMORY.md`.
- Keep the CLAUDE.md inputs/messages list in sync: `supp_check_request`, `sideview_supp_check`.
- Exact copy, verbatim from the spec:
  - §4.1 button labels and disabled titles;
  - §4.2 reason and tooltip;
  - §4.3 note;
  - §4.5 step lines;
  - §7.2 drift reasons and `{error}` texts.

## Review Focus

1. **`IDVARVAL` "01" and "1" on an integer key.** Both convert to 1. The check reports a repeat (status `error`) and the code's repeat guard stops, so neither value silently overwrites the other. Test: Task 2 Step 1, `repeat after conversion`.
2. **A QLABEL with `"` or `\`, or a non-syntactic QNAM** (`AE TRT`, `1FLAG`). The generated code still parses and runs, with names quoted by `ident()`/`str()`. Test: Task 5 Step 1, `odd QNAM and QLABEL parse`.
3. **`IDVAR` is NA rather than `""`.** It counts as the subject level in both twins and in the code (`coalesce(IDVAR, "")`). Test: Task 2 Step 1, `NA IDVAR is subject level`.
4. **A SUPPQUAL with no rows for the chosen RDOMAIN.** The check returns `{error: "suppqual has no rows for AE"}`, so no step is added; it does not add an empty merge. Test: Task 2 Step 1, `no rows for rdomain`.
5. **Factor `USUBJID`/`STUDYID` in the parent with character keys in SUPP.** The key counts as character. The generated code runs, and its result equals the expected data frame. Test: Task 5 Step 1, `factor keys run`.

## Files

| File | Responsibility |
|---|---|
| `R/supp.R` (new) | `sv_supp_check()`, `sv_supp_key_type()`, `sv_supp_check_json()` |
| `R/cdisc.R` | `rdomains`, `merge_targets` on tags |
| `R/card_store.R`, `R/widget.R` | carry the new tag fields on the wire and in widget meta |
| `R/lazy.R` | `sv_lazy_supp_check()` |
| `R/app_server.R` | `supp_check_request` handler |
| `R/copilot.R`, `R/cdisc_keys.R` | Auto Map supp rows; the §4.3 note |
| `inst/www/sv-pipeline.js` | `suppKeyType`, `suppCheck`, the `supp` step (verbs, describe, compose, disableMissing) |
| `inst/www/sideview.js`, `inst/www/sideview.css` | button, menu, flow, step line, report, Refresh, re-checks |
| `tests/testthat/helper-cdisc.R`, `test-supp.R` (new), `test-cdisc.R`, `test-lazy.R`, `test-pipeline.R`, `test-cdisc-keys.R`, `gui-test-runner.js`, `test-layout-browser.R` | tests |
| `vignettes/articles/cdisc.Rmd`, `README.md`, `NEWS.md`, `DESCRIPTION`, `CLAUDE.md`, `MEMORY.md`, `_pkgdown.yml`, `man/`, `docs/` | docs and release |

---

### Task 1: Tag fields `rdomains` and `merge_targets`

**Files:**
- Modify: `R/cdisc.R` (`sv_cdisc_make_tag` 210, `sv_cdisc_rule_suppqual` 190, `sv_cdisc_user_tag` 225, `sv_cdisc_resolve` 342)
- Modify: `R/card_store.R` (`sv_cdisc_wire_tag`), `R/widget.R` (card meta)
- Test: `tests/testthat/test-cdisc.R`

**Interfaces:**
- Produces: every tag has `rdomains` (character, may be empty) and `merge_targets` (a list of `list(rdomain = "AE", card = "<card id>")`, may be empty).
  - The wire form sends `rdomains` as an array and `merge_targets` as an array of `{rdomain, card}`. Both are in widget meta and `sideview_cdisc_update`.
  - A SUPPxx domain's only target is `{substring(domain, 5), parent_card}`, when `parent_card` is set.
  - A `SUPPQUAL` domain has one target per `rdomains` value that matches a card's domain, in `rdomains` order.
  - Non-SUPP tags get `character(0)` / `list()`.

- [ ] **Step 1: Write the failing tests.**
  - `supp tags carry rdomains and merge_targets`:
    - With `suppae` + `ae`: `tag$rdomains == "AE"` and `tag$merge_targets == list(list(rdomain = "AE", card = <ae id>))`.
    - With `suppae` alone: `merge_targets` is length 0.
  - `suppqual targets follow rdomains`: a fixture `suppqual` with RDOMAIN AE and CM, plus `ae`, gives one target (AE). Adding a `cm` card gives AE then CM.
  - `wire tag keeps arrays`: `jsonlite::toJSON(sv_cdisc_wire_tag(tag), auto_unbox = TRUE)` contains `"rdomains":["AE"]` and `"merge_targets":[{"rdomain":"AE","card":`.
  - `cdisc = c(x = "SUPPAE")` user tag: `rdomains` comes from the data's RDOMAIN values.
  - `SEND canvas`: with `send_dm`, `bw` and a new `suppbw` fixture, `suppbw`'s target is the `bw` card.
  - `state never holds tags`: the existing state test still passes with the new fields.
- [ ] **Step 2: Add the fixtures to `helper-cdisc.R`.**
  - Keep the existing names.
  - `suppae2`: AESEQ rows plus blank-IDVAR rows.
  - `ae_grp`: AE with a character `AEGRPID`.
  - `suppae_grp`: SUPP keyed on AEGRPID.
  - `suppqual`: AE and CM rows.
  - `cm`.
  - `supp_repeat`: IDVARVAL "01" and "1", same QNAM.
  - `supp_orphan`.
  - `supp_clash`: QNAM `AESEV`.
  - `supp_two_level`.
  - `supp_bad`: IDVARVAL `"x"` and `"1.5"`.
  - `supp_noqnam`.
  - `ae_nostudy` / `suppae_nostudy`.
  - `supp_na_idvar`.
- [ ] **Step 3: Run `test-cdisc.R`.** Expected: the new tests FAIL.
- [ ] **Step 4: Implement the fields** as described under Interfaces.
- [ ] **Step 5: Run `test-cdisc.R`, `test-module.R` and `test-widget.R`.** Expected: PASS.
- [ ] **Step 6: Commit.** Message: `feat(cdisc): rdomains and merge_targets on SUPP tags`.

### Task 2: `sv_supp_check()` (R)

**Files:**
- Create: `R/supp.R`, `tests/testthat/test-supp.R`
- Modify: `_pkgdown.yml` (CDISC section), `man/` (via `devtools::document()`)

**Interfaces:**
- Produces:
  - `sv_supp_check(parent, supp, parent_name = "parent", supp_name = "supp", rdomain = NULL, plan = NULL, sample_n = 5L)` → a list. This is exported.
  - `sv_supp_key_type(x)` → `"integer"`, `"double"`, `"character"` or `NA`. A factor counts as character; integer64 counts as double.
  - `sv_supp_check_json(chk)` → JSON text, built like `sv_join_diagnostics_json` (one-element arrays stay arrays, NA becomes null).
- The fields and `{error}` texts are in §7.2. Decisions the spec leaves open:
  - **`rdomain`:** when NULL, use the parent's `cdisc$domain` tag if `parent` is a card, else `sub("^SUPP", "", toupper(supp_name))`.
  - **RDOMAIN filter:** rows are filtered on `RDOMAIN == rdomain` only when an `RDOMAIN` column exists. `n_other_rdomain` counts the dropped rows. It makes the status `warning` only when `sub("^SUPP", "", toupper(supp_name)) == rdomain`; for a SUPPQUAL table those rows are expected.
  - **Required columns:** exact upper-case names, as listed in §4.1. Otherwise the result is `{error: "Not in <supp>: <col>"}`. A missing `USUBJID` or IDVAR column in the parent gives `{error: "Not in <parent>: <col>"}`.
  - **Empty filter:** no rows after the filter gives `{error: "<supp_name> has no rows for <rdomain>"}`.
  - **`plan`:** `list(keys, idvars = list(list(idvar, type)), qnams = list(list(qnam, label, idvar)), rdomain_col = TRUE/FALSE)`.
    - `keys` is `c("STUDYID", "USUBJID")`, kept to the columns both tables have.
    - `idvars` lists non-blank IDVARs in order of first appearance, then `""` (type NA) when present.
    - `qnams` are in order of first appearance. `label` is the first non-NA QLABEL, or NA.
    - An NA IDVAR is `""`.
  - **Unsupported key type:** gives `{error: "Cannot merge on <col>: its type is <class>"}`, never a status.
  - **Counts:**
    - `n_supp` = rows after the filter.
    - `n_matched + n_orphan + bad_idvarval$n == n_supp`.
    - A row whose IDVARVAL fails conversion (§6.2 rules) is `bad_idvarval`, not an orphan.
    - `repeats$n` = duplicated rows on (keys, idvar key, QNAM) after conversion.
    - `samples` (at most `sample_n`, here and in `orphan_samples`) hold `USUBJID, IDVAR, IDVARVAL, QNAM`.
  - **Drift:**
    - `drift$reasons` compares the given `plan` with the data, using the §7.2 texts.
    - The other fields always describe the data, and `plan` in the result is the data's plan.
    - Without `plan`, `drift = list(stale = FALSE, reasons = character(0))`.
  - **`preview`:** the first `sample_n` parent rows merged, as a data frame.

- [ ] **Step 1: Write the failing tests in `test-supp.R`.** Each test asserts exact fields:
  - **`ok on one level`:** suppae + ae gives status `ok`, `n_matched == 4`, columns `AETRTEM` labelled "Treatment Emergent", and `plan$idvars[[1]]$type == "integer"`.
  - **`two levels`:** suppae2 gives idvars `AESEQ` then `""`.
  - **`character key`:** AEGRPID has type `"character"`.
  - **`repeat after conversion`:** supp_repeat gives status `error` and `repeats$n == 1`.
  - **`orphans warn`:** supp_orphan gives `warning`, `n_orphan`, and `orphan_samples` columns.
  - **`clash`:** `clashes == "AESEV"` and status `error`.
  - **`two_level`.**
  - **`bad_idvarval`:** `"x"` on any key; `"1.5"` on an integer key but not on a double key.
  - **`missing column`:** gives `list(error = "Not in suppae: QNAM")`.
  - **`no STUDYID`:** `plan$keys == "USUBJID"`.
  - **`NA IDVAR is subject level`.**
  - **`no rows for rdomain`:** suppqual with `rdomain = "LB"` gives `error == "suppqual has no rows for LB"`.
  - **`unsupported type`:** a Date IDVAR column gives `"Cannot merge on AESTDTC: its type is Date"`.
  - **`drift`:** each of the four §7.2 reasons comes from an edited plan.
  - **`json keeps arrays`.**
- [ ] **Step 2: Run `test-supp.R`.** Expected: FAIL, `could not find function "sv_supp_check"`.
- [ ] **Step 3: Implement `R/supp.R`.** Add roxygen with a runnable example on synthetic data, and add the function to `_pkgdown.yml`.
- [ ] **Step 4: Run `test-supp.R`, then `devtools::document()` and `pkgdown::check_pkgdown()`.** Expected: PASS, no missing topics.
- [ ] **Step 5: Commit.** Message: `feat(cdisc): sv_supp_check for SUPP-- merges`.

### Task 3: JS twin `suppCheck`

**Files:**
- Modify: `inst/www/sv-pipeline.js`
- Test: `tests/testthat/test-supp.R` (parity, via `run_pipeline_js()` from `helper-node.R`)

**Interfaces:**
- Consumes: the Task 2 fields and decisions.
- Produces:
  - `SideviewPipeline.suppKeyType(colType)`:
    - `integer`, `int8`, `int16`, `int32` → `'integer'`;
    - `numeric`, `double`, `float`, `int64`, `integer64` → `'double'`;
    - `character`, `factor`, `string`, `utf8`, `large_utf8` and any `dictionary<...>` → `'character'`;
    - anything else → `null`.
  - `SideviewPipeline.suppCheck(parentRows, suppRows, opts)`. `opts`: `{parentName, suppName, rdomain, parentTypes: {col: colType}, plan, sampleN}`. It returns the Task 2 object; `preview` is an array of row objects.

- [ ] **Step 1: Write the failing parity test.**
  - `suppCheck matches sv_supp_check` runs every Task 2 fixture case.
  - It compares `jsonlite::fromJSON(sv_supp_check_json(r))` with the JS result parsed the same way, `preview` included.
  - Also `suppKeyType maps col_types`: one assertion per group above, plus `Date` → null.
- [ ] **Step 2: Run it.** Expected: FAIL, `suppCheck is not a function`.
- [ ] **Step 3: Implement both functions.** Convert keys exactly as §6.2: `Number()` for double after trim, the §6.2 integer regex, character unchanged. Missing values compare as in R.
- [ ] **Step 4: Run the test and `node --check inst/www/sv-pipeline.js`.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(pipeline): suppCheck twin of sv_supp_check`.

### Task 4: Lazy twin `sv_lazy_supp_check()`

**Files:**
- Modify: `R/lazy.R` (next to `sv_lazy_join_diagnostics`, about 1177)
- Test: `tests/testthat/test-lazy.R`

**Interfaces:**
- Consumes: `sv_supp_check()` (Task 2), `sv_lazy_place(x, y, con_env, cols_x, cols_y)`, `sv_lazy_env()`.
- Produces: `sv_lazy_supp_check(parent, supp, parent_name, supp_name, rdomain = NULL, plan = NULL, sample_n = 5L, con_env)`, with the Task 2 fields.
  - The SUPP side is filtered on RDOMAIN, then collected.
  - The parent stays lazy: key types come from `collect(head(parent, 0))`, and `n_parent` from a count.
  - Matches come from a semi-join of the collected keys placed with `sv_lazy_place()`.
  - The preview is `head(parent, sample_n)` collected and merged.

- [ ] **Step 1: Write the failing tests.**
  - `lazy supp check equals in-memory` covers four cases: parent as an arrow Table, as a duckdb tbl, with a lazy SUPP, and with both lazy. Each checks `expect_equal(lazy, sv_supp_check(collected...), tolerance = 1e-12)` on the fixtures from Task 2.
  - `lazy supp check never collects the parent` uses the guard the other lazy twins use in this file.
- [ ] **Step 2: Run `test-lazy.R`.** Expected: FAIL.
- [ ] **Step 3: Implement.** Reuse the Task 2 internals on the collected SUPP rows; don't copy them.
- [ ] **Step 4: Run `test-lazy.R` and `test-supp.R`.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(lazy): sv_lazy_supp_check`.

### Task 5: The `supp` pipeline step

**Files:**
- Modify: `inst/www/sv-pipeline.js`: `verbs` (204), `describe` (340), `disableMissing` (about 680–755), compose (819–986)
- Test: `tests/testthat/test-pipeline.R`

**Interfaces:**
- Consumes: the plan from Task 2/3.
- Produces: the step `{kind:'supp', key:'["supp",<table>,<supp>]', table, supp, rdomain, keys, idvars, qnams, rdomain_col}`, the §6.1 shape plus `rdomain_col`.
  - Ruling: `rdomain_col` decides the RDOMAIN filter (§6.2 "only when the column exists").
  - The step is added with `Pipeline.add(step, label)`. It is not in `ROW_CHANGING`.
- Rules:
  - `describe()` gives `merge SUPPAE (<n> QNAMs on <levels>)`. `<levels>` is the idvars joined with " and ", where `""` reads "subject". The supp name is upper case.
  - `disableMissing` disables the step when the SUPP card is gone, or when a key or IDVAR column is missing from the parent's known columns. After the step, the parent's known columns gain the QNAMs.
  - The prep statements (§6.2 blocks, `<supp>_q`, `<supp>_<idvar lower>`, `<supp>_subj`, `<supp>_labels`) go before the parent's chain. They start from the SUPP card's own chain when it has steps.
  - The joins and the label `mutate` go in the chain.
  - Lazy moves follow §6.3:
    - a duckdb parent's joins get `copy = TRUE`;
    - an arrow parent's joins get `arrow::arrow_table(...)`;
    - labels go after the final `collect()`, and a `_prep` chain gets none.
  - With no labels, omit `<supp>_labels` and the mutate.

- [ ] **Step 1: Write the failing tests.** Compose with `run_pipeline_js()`, `parse()` every output, then `eval()` it on the fixtures:
  - **`supp code equals hand merge`:** `suppae2` + `ae`. The result equals a hand-written tidyr/dplyr merge, labels included (`attr(x$AETRTEM, "label")`).
  - **`supp code with |>`:** the same, with the native pipe.
  - **`guards stop`:** each fails with the spec's `stop()` message:
    - adding an unknown IDVAR row after the plan;
    - a clash;
    - a two-level QNAM;
    - a repeat.
  - **`no STUDYID`, `no RDOMAIN column`, `character key`, `SUPP card with its own filter step`.**
  - **`lazy parent`:** with arrow and duckdb parents (skip if missing), the code runs and equals the in-memory result.
  - **`odd QNAM and QLABEL parse`:** QNAM `AE TRT`, QLABEL `He said "x" \ y`.
  - **`factor keys run`.**
  - **`disableMissing`:** removing the SUPP card disables the step. A later select sees the QNAM columns.
  - **`state round trip`:** `getState`/`applyState` keeps the step. Re-adding with the same key replaces it.
  - **`composes without tags`:** a loaded step still composes the same code when the cards have no tags (`cdisc = FALSE`, §8).
- [ ] **Step 2: Run `test-pipeline.R`.** Expected: the new tests FAIL.
- [ ] **Step 3: Implement the step in `sv-pipeline.js`.**
- [ ] **Step 4: Run `test-pipeline.R` and `node --check inst/www/sv-pipeline.js`.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(pipeline): supp merge step and generated code`.

### Task 6: Server, Auto Map rows and the hint note

**Files:**
- Modify: `R/app_server.R` (next to `join_diagnostics_request`, 276), `R/copilot.R` (rule rows, 111–135), `R/cdisc_keys.R` (`sv_keys_m2m_note`, 193)
- Test: `tests/testthat/test-supp.R` (testServer), `tests/testthat/test-cdisc-keys.R`

**Interfaces:**
- Consumes: `sv_supp_check`, `sv_lazy_supp_check`, `sv_supp_check_json`, and `merge_targets` (Task 1).
- Produces:
  - The input `supp_check_request {id, parent, supp, plan?}`.
  - The reply `dispatch_message("sideview_supp_check", <id + check>)`. A lazy card goes through the existing `lazy_or_preview()` fallback, with its one toast. A card that is not in the store answers `{id, error: "Not in the canvas: <name>"}`.
  - `rdomain` is the `merge_targets` entry whose `card` is the parent.
  - `sv_suggest_mappings()` appends, after the rule rows, one row per SUPP `merge_targets` entry:
    - `from_table = <supp>`, `from_col = "USUBJID"`, `to_table = <parent>`, `to_col = "USUBJID"`, `confidence = 1`;
    - `reason` and `group` as in §4.2, `kind = "supp"`.
  - Heuristic rows are not offered for those pairs.
  - In `sv_keys_m2m_note`, when one card's `merge_targets` names the other, the result is the §4.3 note, in place of every other m2m note.

- [ ] **Step 1: Write the failing tests.**
  - `server answers supp_check_request`: the reply has `id` and `status`, and a `plan` array.
  - `server supp error`: an unknown card.
  - `supp rows in suggest_mappings`: exact row; no heuristic `suppae`–`ae` row; none with `cdisc = FALSE`.
  - `supp note replaces summarise`: the exact §4.3 text, for both card orders.
- [ ] **Step 2: Run both files.** Expected: FAIL.
- [ ] **Step 3: Implement the handler, the rows and the note.**
- [ ] **Step 4: Run `test-supp.R`, `test-cdisc-keys.R`, `test-app.R` and `test-copilot.R`.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(cdisc): supp_check_request, Auto Map supp rows and join note`.

### Task 7: Browser UI

**Files:**
- Modify: `inst/www/sideview.js`:
  - card header actions (about 2877);
  - `renderCdiscBadge` (5120);
  - the suggested-group click (about 3335–3395, `renderSuggestedGroup` 3457);
  - `renderPipeline` (4507);
  - `renderJoinCheck` (4732);
  - the `onMessage` handlers (about 6433).
- Modify: `inst/www/sideview.css`
- Test: `tests/testthat/gui-test-runner.js` (mock DOM)

**Interfaces:**
- Consumes: Tasks 1, 3, 5 and 6.
- Produces:
  - **Card button:** `data-action="supp-merge"` with an inline SVG `merge` icon.
    - The §4.1 labels and disabled titles.
    - A menu (`.sideview-supp-menu`) when there are several targets.
    - Re-rendered on `sideview_cdisc_update`.
  - **`engine.requestSuppCheck(parentName, suppName, plan)`.**
    - It sends `supp_check_request` when R is there; otherwise it runs `SideviewPipeline.suppCheck` on the cards' rows.
    - `parentTypes` comes from `col_types` through `suppKeyType`.
    - It keeps the latest `id` per step key in `this.suppReq`.
  - **The `sideview_supp_check` handler.**
    - An `{error}` reply shows a toast and adds no step.
    - Otherwise the step is added (status `error` included), and `this.suppChecks[stepKey] = check`.
    - A stale `id` is ignored.
    - Before storing, the engine adds to `clashes` any QNAM of an earlier enabled `supp` step on the same parent, and then sets status `error` (§8).
  - **Step line:** the §4.5 text in `renderPipeline`.
  - **Report:**
    - The Discrepancy tab top shows whichever came last, the join check or the merge check. Track it in `this.reportFocus = {kind, id}`.
    - The report shows the counts, problems, new columns with labels, and the 5-row preview, with `Preview rows` when the check ran on a preview.
    - For drift it shows `Merge needs refreshing` and a Refresh button. Refresh replaces the step with the new plan as one undo step.
  - **Re-checks (§7.4):**
    - when the report is opened;
    - after `applyState`;
    - on `sideview_card_replace` of either card, which also clears the stored check.
  - **Auto Map:** clicking a group whose rows have `kind === 'supp'` runs the merge flow, never `addConnections()`.

- [ ] **Step 1: Write the failing mock-DOM tests.**
  - The button label and the disabled titles (all three §4.1 cases).
  - No button with `cdisc = FALSE`.
  - The menu with two targets.
  - A click sends `supp_check_request`.
  - An error reply shows a toast and adds no step.
  - A reply adds one step; a second press replaces it, and one undo removes it.
  - A stale `id` is dropped.
  - The step line text.
  - The report sections, Refresh as one undo step, and the re-check on replace.
  - A widget-mode click computes in the browser.
  - A supp group click adds no join.
  - A second merge into the same parent reports a clash.
- [ ] **Step 2: Run `node tests/testthat/gui-test-runner.js`.** Expected: the new tests FAIL.
- [ ] **Step 3: Implement the UI and CSS.** The header must still fit at 560px (`sv-narrow` hides the label and keeps the icon, with the label as `aria-label`).
- [ ] **Step 4: Run the mock-DOM tests, `node --check inst/www/sideview.js`, and `devtools::test()`.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(ui): Merge into button, merge check report and Refresh`.

### Task 8: Real-browser tests

**Files:**
- Test: `tests/testthat/test-layout-browser.R`

- [ ] **Step 1: Write the tests.** All use real mouse input (`b$Input$dispatchMouseEvent`):
  - **Gadget**, with dm, ae and suppae2:
    1. Click `Merge into AE`.
    2. The step line text appears.
    3. The code from `sideview_snapshot` parses and evaluates to the expected frame.
    4. The Discrepancy report shows the columns.
  - **Module**, with a duckdb parent: same flow.
  - **Widget**: the merge is computed in the browser.
  - **Auto Map**: clicking the supp spline adds the merge step and no join.
  - **Width**: at 1400, 1024 and 560 px, the card header buttons do not intersect the title or each other.
- [ ] **Step 2: Run with `NOT_CRAN=true`.** Expected: PASS; fix any layout failure in Task 7's files.
- [ ] **Step 3: Commit.** Message: `test(browser): SUPP merge flows`.

### Task 9: Docs, release and RStudio pass

**Files:**
- Modify:
  - `vignettes/articles/cdisc.Rmd`: a new "Merging SUPP-- tables" section, and an update to "What join keys do not do" (SUPP tables are merged, not joined).
  - `README.md`, `NEWS.md` (0.7.0), `DESCRIPTION` (`Version: 0.7.0`).
  - `CLAUDE.md` (inputs/messages list, the supp twin rule), `MEMORY.md`.
  - `docs/` (rebuilt).

- [ ] **Step 1: Write the docs.**
  - The article runs `sv_supp_check(ae, suppae)` live on its synthetic study.
  - "What it does not do":
    - exact upper-case column names;
    - the two-merge limit;
    - only the code guard stops a rerun on new data.
- [ ] **Step 2: Run `devtools::document()`, `pkgdown::check_pkgdown()`, `devtools::check()`.** Expected: 0 errors, 0 warnings.
- [ ] **Step 3: Rebuild the site.** Run `pkgdown::build_site()` with `RSTUDIO_PANDOC` set. Delete `docs/CLAUDE.*` / `docs/MEMORY.*` and their `sitemap.xml` / `search.json` entries.
- [ ] **Step 4: Run the RStudio pass by hand** (dialog, Viewer pane, external browser):
  - merge;
  - a second press;
  - undo;
  - Refresh after editing `suppae`;
  - the 560px header.

  Record what was verified, and what was not, in `MEMORY.md`.
- [ ] **Step 5: Commit.** Message: `docs: SUPPQUAL merge (0.7.0)`.
