# sideview E1: `combine_supp()` code style — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A canvas-wide "Code" setting (`dplyr` / `pharmaverse`) under which an eligible Merge into step composes to `metatools::combine_supp()`, with the eligibility decided by twin checks in R, JS and lazy R.

**Architecture:** The three SUPP check twins gain a `combine_supp = {ok, reason, prep}` field (R and JS copy the metatools 0.3.0 rules; lazy says no). The engine hands each step's field to the pipeline (`setSuppCheck()`, like `setJoinCheck()`); `Pipeline.style` decides the form, and `compose()` writes the pharmaverse block only when the field, the drift state and the chain rule (`combineSuppApplies()`) all allow it. The R arguments, the state field and the UI select only carry `style`.

**Tech Stack:** R 4.5.2 (testthat 3, shiny `testServer`, chromote), plain JS (`sv-pipeline.js` pure, `sideview.js` engine), metatools 0.3.0 (Suggests, tests only).

**Spec:** `plans/2026-11-22-e1-combine-supp-design.md` (builds on `plans/2026-11-03-cdisc-suppqual-merge-design.md`). Read both.

## Global Constraints

- The rule: **sideview writes `combine_supp()` only when its result equals the dplyr code's result**; otherwise the step stays dplyr and says why.
- `code_style = c("dplyr", "pharmaverse")`, `match.arg()`, default `"dplyr"`, on `sideview()`, `sideview_widget()`, `save_sideview()`, `sideviewServer()`.
- Pipeline state `{steps, pipe, style}`; a state without `style` loads as `dplyr`; a state's `style` wins over `code_style`. Schema stays v0.3.0.
- Field: `combine_supp = { ok, reason (string | null), prep: { rdomain, idvar_na } }`; R adds `installed` (metatools >= 0.3.0: `requireNamespace()` and `utils::packageVersion("metatools") >= "0.3.0"`) in the gadget and module handler only; JS sends `installed: null`. `installed` never changes `ok`.
- Both check twins evaluate R's `as.character()` as under `scipen = 0` (R: `op <- options(scipen = 0); on.exit(options(op))`).
- `Suggests: metatools (>= 0.3.0)`. Tests that call it use `skip_if_not_installed("metatools", "0.3.0")`.
- Twin rule: `sv_supp_check()`, `SideviewPipeline.suppCheck()`, `sv_lazy_supp_check()` give equal `combine_supp` fields; `test-supp.R` / `test-lazy.R` hold them to each other.
- Generated R code must `parse()`; a test for every new generator, with `%>%` and `|>`.
- Module mode is untrusted: the setting is display and codegen only; nothing new is evaluated in R.
- No emoji or glyph icons; CSS through `--sv-*` tokens under `.sideview-container`.
- CRLF in MEMORY.md, NEWS.md, DESCRIPTION, CLAUDE.md, plans/*.md, inst/www/sideview.js (convert with node, check for bare LF, strip BOM). Never commit `tests/testthat/_problems/` or `testthat-problems.rds`.
- Synthetic data only. Commit on `e/combine-supp`; never push or merge without the user's ask. Trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Rscript: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"`; run single files with `devtools::test(filter = "supp")`.

### User-facing copy (exact)

| Where | Text |
|---|---|
| rule 1 (status `error`) | `The merge stops: ` + parts joined by `; `: `<n> repeated QNAM record` / `records`, `<A, B> already in <parent>`, `<A, B> on two IDVAR levels` (this order) |
| rule 1 (`{error}`) | the error text itself |
| rule 2 | `combine_supp() needs data frames: <table> is a duckdb table` / `... is an Arrow table` |
| rule 3 | `Checked on preview rows only` |
| rule 4 | `<supp> has no <COL> column` (first missing of `STUDYID RDOMAIN USUBJID IDVAR IDVARVAL QNAM QLABEL QVAL QORIG`) / `<supp> has extra columns: X, Y` (SUPP column order; `QEVAL` is allowed) |
| rule 5 | `<parent> has no <COL> column` (first missing of `STUDYID DOMAIN USUBJID`) |
| rule 6 | `<supp> has steps before the merge` / `<parent> has steps before the merge that combine_supp() cannot check` |
| rule 7 | `IDVARVAL "<v>" would not match <IDVAR> <k> in combine_supp()` / `IDVARVAL "<v>" would match <IDVAR> <k> in combine_supp()` / `IDVARVAL "<v>" would match a different <parent> record in combine_supp()`; a subject-level row: `<USUBJID> would not match in combine_supp()` (DOMAIN differs) |
| rule 8 | `<QNAM> label would be "<theirs>" in combine_supp(), not "<ours>"`; a missing label prints as `none` without quotes |
| drift | `Merge needs refreshing` |
| step line | `· combine_supp()` / `· dplyr: <reason>` / `· needs metatools 0.3.0 or later to run`; orphans or bad IDVARVAL add ` (combine_supp() warns)` after the existing warning text |
| panel / print | `combine_supp(): yes` / `combine_supp(): no, <reason>` |
| guard | `IDVARVAL "<v>" matches <IDVAR> <k> as a number but not as text in combine_supp(); use the dplyr code style for this merge` and the mirror `... as text but not as a number ...` |
| UI | `Code <select>` with options `dplyr`, `pharmaverse`, `aria-label="Code style"` |

`<v>` is the raw IDVARVAL; `<k>` is the parent key as R's `as.character()` (scipen 0) gives it.

### Rulings made while planning (spec §8 / §9 left these to the builder)

- **Rule 6 lives in the pipeline, not the check:** `Pipeline.combineSuppApplies(step)` → `{ok, reason}`, asked by `compose()` and the step line, like `strictApplies()`. Not ok when the SUPP card has any enabled step of its own, or the parent's chain has an enabled step before the merge whose kind is not `filter`, `sort` or `supp` (row subsets and reorders keep both styles equal; the guards read the original parent, so they can only stop more often). The step line shows the check's reason first, then rule 6 (a small change from the spec's ordering, where rule 6 comes before 7 and 8).
- **`{error}` results stay `{error}` on the wire.** Readers turn them into `{ok: false, reason: error}` through `combineSuppOf(d)` (engine) / `sv_supp_combine_of(chk)` (R print).
- **Whitespace-only IDVAR prep:** always one form, `dplyr::mutate(IDVAR = dplyr::na_if(trimws(IDVAR), ""))`. It is written when any row's IDVAR is `""` or ASCII whitespace only. `prep$idvar_na` is TRUE in exactly that case.
- **Unicode trim:** `str_trim` trims the Unicode White_Space set. The twins use one explicit class, `[\t\n\x0b\f\r \x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}]`: R `sv_str_trim_ws` (perl), JS `STR_TRIM_WS`. That is neither JS `trim()` (which trims `\uFEFF` and not `\u0085`) nor stringr.
- **JS `as.character`:** `SideviewPipeline.rAsCharacter(x)`. Take the smallest number of significant digits, at most 15, that reproduces the value at 15-digit precision. Use the fixed form when its width is ≤ the scientific width, else the scientific form (mantissa, `e`, sign, exponent of at least 2 digits). `NA`/null gives null; also `Inf`, `-Inf`, `NaN`; `-0` gives `"0"`. If a value cannot be matched, rule 7 says not ok (spec §11).
- **Module plumbing:** `sideviewServer(code_style =)` emits a new message, `sideview_code_style` `{style}`, before `sideview_state_set`, so a state's style still wins. Gadget: `sideview_ui(code_style =)` → container `data-sv-code-style`. Widget: `options$codeStyle`. `save_sideview(code_style = NULL)`: NULL keeps the widget's own; otherwise `match.arg` and it is set.
- **Version:** bump to 0.11.0 in this PR (E2 adds to the same NEWS heading).
- **`setStyle` is not undoable**, matching `setPipe()` (spec §5.1 "match `setPipe()`").

## Review Focus

1. **`widenSuppClashes()` adds a clash after the twin said ok.** Expected: the field turns `{ok: false}` with the rule-1 text; the step composes dplyr. Test in Task 6.
2. **A re-check flips `ok` from TRUE to FALSE** (e.g. the SUPP card is replaced with one carrying `"01"`). Expected: the step recomposes as dplyr in the same render and the line gives the new reason. Test in Task 6.
3. **A SUPPQUAL holding AE and CM rows, with its last AE QLABEL blank.** Expected: the labels are compared after the RDOMAIN filter, so a blank last AE label is rule 8 even when CM rows follow. Test in Task 1.
4. **Session `options(scipen = 999)` while the check runs.** Expected: the field is identical to `scipen = 0`, and the user's option is restored afterwards. Test in Task 1.
5. **A workspace saved in pharmaverse style, opened with `code_style = "dplyr"`.** Expected: it stays pharmaverse (the state wins), and the Code select shows it. Test in Task 5.

---

### Task 1: R check field `combine_supp`

**Files:**
- Modify: `R/supp.R` (new `sv_supp_combine()`, `sv_supp_combine_of()`, `sv_str_trim_ws`, `sv_r_chr()`; called from `sv_supp_check_df()`; JSON)
- Modify: `R/say.R` (`sv_say_supp()` appends the `combine_supp():` line)
- Modify: `tests/testthat/helper-cdisc.R` (fixtures `fx$cs_*`)
- Modify: `DESCRIPTION` (Suggests `metatools (>= 0.3.0)`)
- Test: `tests/testthat/test-supp.R`

**Interfaces:**
- Produces: `sv_supp_combine(parent, supp, side, conv, matched, keys, parent_name, supp_name)` returns `list(ok, reason, prep = list(rdomain, idvar_na))`. It is internal and computes rules 4, 5, 7 and 8, plus rule 1 for status `error`. `sv_supp_check_df()` stores the result as `$combine_supp` on every non-error result.
- Produces: `sv_supp_combine_stop_reason(chk, parent_name)` returns the rule-1 text. `sv_supp_combine_of(chk)` returns the field, or `{ok: FALSE, reason: chk$error, prep: both FALSE}` for an error.
- Produces: `sv_r_chr(x)` returns `as.character(x)` under `scipen = 0`. `sv_str_trim(x)` trims with `sv_str_trim_ws`.
- Produces: the fixtures `fx$cs_*` (names below), which Tasks 3, 4 and 6 reuse.

- [ ] **Step 1: Add fixtures to `sv_cdisc_fixtures()`**. Each one is a parent (`STUDYID`, `DOMAIN = "AE"`, `USUBJID`, `AESEQ`, `AETERM`) and SUPP pair, as lists `list(parent, supp)`:
  - `cs_ok`: the usual case. The `.xpt` shape: `IDVAR ""` at subject level, no `QEVAL`.
  - `cs_na_idvar`: subject level with `IDVAR = NA`.
  - `cs_suppqual`: rows for AE and for CM.
  - `cs_suppqual_blank_last`: the same, but the last AE `QLABEL` is `""`.
  - Bad keys:
    - `cs_key01`: `IDVARVAL "01"`.
    - `cs_key_sp`: `" 1 "`.
    - `cs_key_dec`: `"1.0"`.
    - `cs_key_nbsp`: `"1\u00a0"`.
    - `cs_key_nel`: `"1\u0085"`.
  - Numeric keys:
    - `cs_1e5`: `AESEQ` 100000, with `"100000"`.
    - `cs_1e5_sci`: `AESEQ` 100000, with `"1e+05"`.
    - `cs_110000`: `AESEQ` 110000.
    - `cs_frac`: `AESEQ` `0.1 + 0.2`, with `"0.3"`.
  - Key types:
    - `cs_int`: integer `AESEQ`.
    - `cs_fac`: factor `AEGRPID`.
    - `cs_chr`: character `AEGRPID`.
  - Columns:
    - `cs_no_qorig`: SUPP without `QORIG`.
    - `cs_qeval`: SUPP with `QEVAL`.
    - `cs_extra`: an extra SUPP column `EXTRA`.
    - `cs_no_domain`: the parent has no `DOMAIN`.
    - `cs_no_studyid`: the parent has no `STUDYID`.
  - Labels:
    - `cs_lab_two`: `"TE one"`, then `"TE two"`.
    - `cs_lab_blank_last`: the last label is `""`.
    - `cs_lab_all_blank`: every label is `""`.
    - `cs_lab_all_na`: every label is `NA`.
  - Merge outcomes:
    - `cs_orphan`
    - `cs_repeat`
    - `cs_two_level`
    - `cs_clash`
    - `cs_domain_lower`: the parent `DOMAIN` is `"ae"`.

- [ ] **Step 2: Write the failing tests** in `test-supp.R`:

```r
cs <- function(name, ...) { f <- fx[[name]]; chk(f[[2]], parent = f[[1]], ...)$combine_supp }
test_that("combine_supp field: eligible cases and prep", {
  expect_true(cs("cs_ok")$ok); expect_null(cs("cs_ok")$reason)
  expect_true(cs("cs_ok")$prep$idvar_na); expect_false(cs("cs_ok")$prep$rdomain)
  expect_false(cs("cs_na_idvar")$prep$idvar_na)
  q <- chk(fx$cs_suppqual[[2]], parent = fx$cs_suppqual[[1]], sn = "suppqual", rdomain = "AE")$combine_supp
  expect_true(q$ok); expect_true(q$prep$rdomain)
  for (n in c("cs_qeval", "cs_int", "cs_fac", "cs_chr", "cs_1e5_sci", "cs_110000", "cs_orphan",
              "cs_lab_all_blank", "cs_lab_all_na")) expect_true(cs(n)$ok, info = n)
})
test_that("combine_supp field: reasons, in rule order", {
  expect_equal(cs("cs_no_qorig")$reason, "suppae has no QORIG column")
  expect_equal(cs("cs_extra")$reason, "suppae has extra columns: EXTRA")
  expect_equal(cs("cs_no_domain")$reason, "ae has no DOMAIN column")
  expect_equal(cs("cs_key01")$reason, 'IDVARVAL "01" would not match AESEQ 1 in combine_supp()')
  expect_equal(cs("cs_1e5")$reason, 'IDVARVAL "100000" would not match AESEQ 1e+05 in combine_supp()')
  expect_equal(cs("cs_key_nbsp")$reason, 'IDVARVAL "1\u00a0" would match AESEQ 1 in combine_supp()')
  expect_match(cs("cs_frac")$reason, "would not match AESEQ 0.3")
  expect_equal(cs("cs_lab_two")$reason, 'AETRTEM label would be "TE two" in combine_supp(), not "TE one"')
  expect_equal(cs("cs_lab_blank_last")$reason, 'AETRTEM label would be none in combine_supp(), not "Treatment Emergent"')
  expect_match(cs("cs_clash")$reason, "^The merge stops: AETRTEM already in ae$")
  expect_match(cs("cs_repeat")$reason, "^The merge stops: 1 repeated QNAM record$")
  expect_match(cs("cs_domain_lower")$reason, "would not match in combine_supp\\(\\)$")
})
test_that("combine_supp field ignores the session's scipen and restores it", {
  withr::local_options(scipen = 999)
  expect_equal(cs("cs_1e5")$reason, 'IDVARVAL "100000" would not match AESEQ 1e+05 in combine_supp()')
  expect_equal(getOption("scipen"), 999)
})
test_that("blank last AE label in a SUPPQUAL counts after the RDOMAIN filter", { ... })  # Review Focus 3
test_that("sv_str_trim matches stringr::str_trim", {
  skip_if_not_installed("stringr")
  x <- paste0(c(" ", "\t", "\u00a0", "\u0085", "\u3000", "\ufeff", "\u2028"), "1", " ")
  expect_identical(sideview:::sv_str_trim(x), stringr::str_trim(x))
})
test_that("print and JSON carry the line and the field", {
  expect_match(paste(capture.output(print(chk(fx$cs_key01[[2]], parent = fx$cs_key01[[1]]))), collapse = "\n"),
               'combine_supp\\(\\): no, IDVARVAL "01"')
  j <- jsonlite::fromJSON(sv_supp_check_json(chk(fx$cs_ok[[2]], parent = fx$cs_ok[[1]])), simplifyVector = FALSE)
  expect_equal(j$combine_supp, list(ok = TRUE, reason = NULL, prep = list(rdomain = FALSE, idvar_na = TRUE)))
})
test_that("not-ok fixtures: the real combine_supp() errors or differs", {
  skip_if_not_installed("metatools", "0.3.0")
  # for each not-ok fixture except the rule-1 ones: apply the prep, call metatools::combine_supp(),
  # and expect an error, or a result that differs (supp_same_result(), below) from the
  # 0.7.0 dplyr code composed with supp_compose() and run with supp_run()
})
```

  Put `supp_same_result(a, b)` in `helper-cdisc.R`. Two results are the same when they have the same rows in the same order, the same column set (order ignored), the same values and classes, and the same `label` attribute per column (`NULL`, `NA` and `""` all mean none). Move `supp_compose()` / `supp_run()` from `test-pipeline.R` to `helper-cdisc.R` so both files share them.

- [ ] **Step 3: Run them.** Run: `Rscript -e "devtools::test(filter = 'supp')"`. Expected: the new tests FAIL (`combine_supp` is NULL).
- [ ] **Step 4: Implement.**
  - **Rule 7, per SUPP row (after the prep's RDOMAIN filter).** Rule 7 is decided by comparing two parent row sets for each row.
    - **Ours:** the `matched` record that `sv_supp_match_df()` already found.
    - **Theirs:** the parent rows where `STUDYID` and `USUBJID` are equal (NA matches NA) and `DOMAIN == RDOMAIN`. A keyed row also needs `sv_str_trim(sv_r_chr(IDVARVAL)) == sv_str_trim(sv_r_chr(<key>))`, with a factor compared by its level text.
    - The first row whose two sets differ gives the reason.
  - **Rule 8:** take the last QLABEL per QNAM in row order, over the filtered rows. Normalise NA and `""` to none, then compare with the plan's label.
  - **`installed`:** do not set it here.
- [ ] **Step 5: Run them again.** Expected: all `supp` tests PASS (the existing tests and parity are unchanged, because the JS twin is not compared on this field until Task 3).
- [ ] **Step 6: Commit.** Message: `feat: combine_supp field on the R SUPP check`

### Task 2: Lazy twin and server handler

**Files:**
- Modify: `R/lazy.R` (`sv_lazy_supp_check()`)
- Modify: `R/app_server.R` (`supp_check_request` handler)
- Test: `tests/testthat/test-lazy.R`, `tests/testthat/test-supp.R` (server tests)

**Interfaces:**
- Consumes: `sv_supp_combine_stop_reason()` from Task 1.
- Produces: `sv_lazy_supp_check()` results carry `combine_supp = list(ok = FALSE, reason = "combine_supp() needs data frames: <table> is a duckdb table" | "... is an Arrow table", prep = list(rdomain = <as R>, idvar_na = <as R>))`. The table named is the parent if it is lazy, else the SUPP card. The `prep` flags take the values the in-memory twin would give.
- Produces: the handler's reply includes `combine_supp`, plus `combine_supp$installed` (TRUE/FALSE). When either card `isTRUE(card$is_lazy)`, the handler sets rule 2's `ok`/`reason` even when `lazy_or_preview()` fell back to the preview.

- [ ] **Step 1: Write the failing tests.**
  - `test-lazy.R`: over the duckdb and arrow fixtures of `cs_ok`, `combine_supp$ok` is FALSE and `reason` equals the rule-2 text. `prep` equals `sv_supp_check()`'s `prep` with `tolerance = 1e-12` (the existing twin pattern).
  - `test-supp.R`, `server answers supp_check_request`: extend it so `testServer` sees `reply$combine_supp$ok`, `reply$combine_supp$installed` is logical, and `installed` equals `requireNamespace("metatools", quietly = TRUE) && utils::packageVersion("metatools") >= "0.3.0"`.
  - A lazy card whose link is lost (the preview fallback) still gets rule 2.
- [ ] **Step 2: Run them.** Run `filter = 'lazy|supp'`. Expected: FAIL.
- [ ] **Step 3: Implement both.**
- [ ] **Step 4: Run them again.** Expected: PASS. Also run `filter = 'module'`, which must stay green.
- [ ] **Step 5: Commit.** Message: `feat: combine_supp on the lazy SUPP check and the server reply`

### Task 3: JS twin

**Files:**
- Modify: `inst/www/sv-pipeline.js` (`suppCheck()` field, `rAsCharacter`, `STR_TRIM_WS`, `strTrim`, `combineSuppStopReason`)
- Test: `tests/testthat/test-supp.R`

**Interfaces:**
- Produces: `SideviewPipeline.rAsCharacter(x: number|null) -> string|null` and `SideviewPipeline.strTrim(s) -> string`.
- Produces: `SideviewPipeline.combineSuppStopReason(d, parentName) -> string`, the rule-1 text, which the engine also uses in Task 6.
- Produces: `suppCheck(parent, supp, opts)` takes two new options:
  - `opts.lazy = {name, kind: 'duckdb'|'arrow'} | null` (rule 2);
  - `opts.preview = true|false` (rule 3).

  It returns `combine_supp` with `installed: null`.

- [ ] **Step 1: Write the failing tests.**
  - Extend `supp_parity()` so the R check carries `installed`-less `combine_supp` and the JS output is compared with `installed` dropped. Add every `fx$cs_*` fixture to the `cases` list of `suppCheck matches sv_supp_check`.
  - New test `rAsCharacter matches R's as.character for doubles`:

```r
vals <- c(1, 99999, 100000, 110000, 123456, 1e15, 1e15 + 2, 1e16, 123456789012345678, 0.1, 0.1 + 0.2,
          1/3, 2/3, -1/3, -100000, 1e-4, 1e-5, 0.0001234, 1.5e-300, 1.7976931348623157e308, 5e-324,
          -0, 3.14159265358979, 1234.5678, 1e5 + 0.1, Inf, -Inf, NaN, NA)
want <- local({ op <- options(scipen = 0); on.exit(options(op)); as.character(vals) })
got <- run_pipeline_js(sprintf("out = %s.map(P.rAsCharacter);",
  jsonlite::toJSON(as.list(vals), digits = NA, na = "null", auto_unbox = TRUE)))
expect_identical(vapply(got, function(x) if (is.null(x)) NA_character_ else x, ""), want)
```
  `jsonlite` writes `Inf`/`NaN` as strings or nulls, so send those three as the strings `"Inf"`, `"-Inf"` and `"NaN"`, and have `rAsCharacter` accept them.
  - `strTrim` against `stringr::str_trim` uses the same vector as in Task 1.
  - `opts.lazy` gives the rule-2 text, and `opts.preview` gives `Checked on preview rows only`.
- [ ] **Step 2: Run them.** Run `filter = 'supp'`. Expected: the parity and value-table tests FAIL.
- [ ] **Step 3: Implement**, following the "JS `as.character`" ruling and the copy table.
- [ ] **Step 4: Run them again**, plus `node --check inst/www/sv-pipeline.js`. Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: combine_supp field on the JS SUPP check, with R's as.character for doubles`

### Task 4: Pipeline style and the pharmaverse compose

**Files:**
- Modify: `inst/www/sv-pipeline.js` (`Pipeline` constructor `opts.style`, `setStyle`, `toJSON`/`load`, `setSuppCheck`, `combineSuppApplies`, compose path, new `suppCombinePrep()`)
- Test: `tests/testthat/test-pipeline.R`, `tests/testthat/test-supp.R` (equivalence)

**Interfaces:**
- Consumes: `combine_supp` from Tasks 1 and 3; `combineSuppStopReason()`.
- Produces:
  - `pipeline.style` is `'dplyr' | 'pharmaverse'`.
  - `setStyle(style)` emits `'style'` and pushes no undo.
  - `toJSON()` gives `{steps, pipe, style}`.
  - `load(obj)` sets the style from `obj.style` when present.
  - `setSuppCheck(key, field|null)` stores into `this.suppCombine` and emits `'checks'` only on a change. The stored value is not state (never saved, no undo).
  - `combineSuppApplies(step) -> {ok, reason}` (rule 6).
  - `combineSuppFor(step) -> {ok, reason, rule}`: the effective decision that `compose()` and the engine both use. It is ok only when `style === 'pharmaverse'`, a field is stored and ok, and `combineSuppApplies(step).ok`.
- Generated code shape: spec §5.3. Details:
  - `<supp>_q <- <src> %>% dplyr::filter(RDOMAIN == "AE") %>% dplyr::mutate(IDVAR = dplyr::na_if(trimws(IDVAR), ""))`. Write each prep line only when its flag is set. Write no `_q` at all when there is neither a flag nor a SUPP chain; the guards and the call then read `<supp>` directly.
  - The `local({ ... })` guard block keeps the 0.7.0 IDVAR-level, two-level and repeat checks, reworded to read `<supp>_q` and with no clash guard. It adds one text-match guard per numeric level:
    - "by number" uses `suppKeyConv()` and the double overflow rule, then matches values with `sprintf("%.17g", ...)` key strings, so it does not depend on scipen;
    - "by text" uses `stringr::str_trim(as.character(...))`;
    - each also matches `STUDYID`, `USUBJID` and `DOMAIN == RDOMAIN`, with NA matching NA;
    - the first row whose matched parent record differs stops with the guard copy.
  - Then `<parent chain> %>% metatools::combine_supp(<supp>_q)`, with no label vector and no label mutate.

- [ ] **Step 1: Write the failing tests.**
  - In `test-pipeline.R`, extend `supp_compose()` with `style = "dplyr"` and `combine = NULL`. They add `p.setStyle(style)` and `p.setSuppCheck(p.steps[0].key, combine)` after the add.
  - `pharmaverse code parses with and without each prep line, %>% and |>`: four flag combinations × two pipes; use `expect_parses()`, `expect_match(code, "metatools::combine_supp\\(")` and `expect_no_match(code, "_labels")`.
  - `dplyr style, a not-ok field, a missing field, or drift compose the 0.7.0 code`: `identical()` to the composed code with no style set.
  - `combineSuppApplies`:
    - a filter, then a merge, is ok;
    - a mutate, then a merge, gives the parent reason;
    - a step on `suppae` gives the SUPP reason;
    - a disabled mutate is ok.
  - `style round-trips through toJSON/load; a state without style is dplyr`.
  - In `test-supp.R`, `pharmaverse code equals the dplyr code on every ok fixture` (`skip_if_not_installed("metatools", "0.3.0")`): for each `fx$cs_*` whose field is ok, run both composed codes with `supp_run()` and check them with `supp_same_result()`.
  - `text-match guard on a later data cut`:
    - compose on `cs_ok`, then run on `cs_key01`'s SUPP: `supp_stop()` equals `IDVARVAL "01" matches AESEQ 1 as a number but not as text in combine_supp(); use the dplyr code style for this merge`;
    - compose on `cs_1e5_sci`, then run under `withr::local_options(scipen = 999)`: it stops with the guard text;
    - the same under `scipen = 0`: it runs and equals the dplyr result.
- [ ] **Step 2: Run them.** Run `filter = 'pipeline|supp'`. Expected: FAIL (`setStyle` is not a function).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them again.** Expected: PASS. Run `node --check`.
- [ ] **Step 5: Commit.** Message: `feat: pharmaverse code style composes combine_supp() for eligible merges`

### Task 5: R arguments, module message, state

**Files:**
- Modify:
  - `R/sideview.R`
  - `R/app_ui.R` (`sideview_ui(code_style =)` → `data-sv-code-style`)
  - `R/widget.R` (`sideview_widget(code_style =)` → `options$codeStyle`; `save_sideview(code_style = NULL)`)
  - `R/module.R` (`sideviewServer(code_style =)` emits `sideview_code_style` before `sideview_state_set`)
  - `R/state.R` (roxygen: `style`)
  - `inst/www/sideview.js`:
    - engine init: `style = options.codeStyle || data-sv-code-style || 'dplyr'`, passed to `new Pipeline({style})`;
    - an `onMessage('sideview_code_style')` handler;
    - `applyState` passes `style` into `pipeline.load`;
    - `getState` gets it through `toJSON`.
- Test: `tests/testthat/test-state.R`, `test-widget.R`, `test-module.R`, `test-sideview*.R` (whichever holds `sideview_ui` tests)

**Interfaces:**
- Consumes: `Pipeline` `style` from Task 4.
- Produces: the message `sideview_code_style` `{style, ns}`.

- [ ] **Step 1: Write the failing tests.**
  - `match.arg` error on `code_style = "base"` for all four entry points.
  - `sideview_ui(code_style = "pharmaverse")` HTML has `data-sv-code-style="pharmaverse"`.
  - `sideview_widget(mtcars, code_style = "pharmaverse")$x$options$codeStyle == "pharmaverse"`.
  - `save_sideview(w, f)` keeps the widget's style.
  - Module `testServer`: the emitted messages contain `sideview_code_style` before `sideview_state_set`.
  - `test-state.R`: `sv_state_json()` round-trips `pipeline$style`; a v0.3.0 state without it loads and its JSON has no `style` added by R.
  - Review Focus 5, in the mock DOM (`gui-test-runner.js`): an engine with `codeStyle: 'dplyr'` and `options.state` carrying `style: 'pharmaverse'` ends with `pipeline.style === 'pharmaverse'`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them again.** Run `filter = 'state|widget|module|ui'` and the GUI runner. Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: code_style argument, module message and pipeline state field`

### Task 6: UI: Code select, step line, panel line

**Files:**
- Modify: `inst/www/sideview.js`:
  - the pipeline bar gets `<label class="sideview-code-choice">Code <select class="sideview-code-select" aria-label="Code style">`, synced next to `pipeSel` and handled in the `change` listener with `setStyle`;
  - `combineSuppOf(d)`;
  - `setSuppCheck` is called wherever `suppChecks[key]` is set, deleted or refreshed, with the drift-stale and `{error}` cases mapped to not ok;
  - `widenSuppClashes()` sets `d.combine_supp = {ok: false, reason: P.combineSuppStopReason(d, table), prep: d.combine_supp.prep}` when it adds a clash;
  - `suppDiagState()` / `suppLineText()` get the step-line suffix;
  - the Discrepancy merge panel gets the `combine_supp():` line;
  - the widget `localSuppCheck()` passes `opts.lazy` and `opts.preview` (from `rowsBasis` / the `preview` flag at the existing call).
- Modify: `inst/www/sideview.css` (`.sideview-code-choice`, the same tokens as `.sideview-pipe-choice`; wraps in `sv-narrow`)
- Test: `tests/testthat/gui-test-runner.js`, `tests/testthat/test-layout-browser.R`

**Interfaces:**
- Consumes: `setStyle`, `setSuppCheck` and `combineSuppFor` (Task 4); `combineSuppStopReason` (Task 3); the reply fields (Task 2).

- [ ] **Step 1: Write the failing mock-DOM tests.**
  - The select exists with both options.
  - Changing it calls `setStyle` and the code drawer shows `metatools::combine_supp(`.
  - Changing it adds no undo entry.
  - Step line texts for:
    - ok: `· combine_supp()`;
    - not ok: `· dplyr: <reason>`;
    - `installed: false`: `· needs metatools 0.3.0 or later to run`;
    - orphans: `(combine_supp() warns)`.
  - Panel line in both styles.
  - Review Focus 1: a clash added by `widenSuppClashes` flips the field and the code back to dplyr.
  - Review Focus 2: a re-check reply with `ok: false` recomposes to dplyr in that render.
- [ ] **Step 2: Run them.** Run `node tests/testthat/gui-test-runner.js`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them again.** Expected: PASS. Run `node --check inst/www/sideview.js`.
- [ ] **Step 5: Write and run the real-browser tests**, with `NOT_CRAN=true`, `filter = 'layout-browser'`. Expected: PASS.
  - In `test-layout-browser.R`, switch Code to pharmaverse in a gadget with `fx$cs_ok`, and check that the drawer code contains `metatools::combine_supp(`.
  - At 560×520, the pipeline bar's select, buttons and count do not intersect, and the bar does not overflow horizontally.
- [ ] **Step 6: Commit.** Message: `feat: Code select, combine_supp step and panel lines`

### Task 7: Docs, version, tracking

**Files:**
- Modify: `DESCRIPTION` (Version 0.11.0), `NEWS.md` (`# sideview 0.11.0`: Pharmaverse code), `CLAUDE.md`, `vignettes/articles/cdisc.Rmd`, `README.md`, `MEMORY.md`, `man/`, `docs/`
- Update in `CLAUDE.md`:
  - add the `sideview_code_style` message;
  - document the `combine_supp` field, plus `installed`, on the `sideview_supp_check` line;
  - add a "Pharmaverse code (0.11.0)" bullet covering the twin rule, `combineSuppApplies` and `style` in pipeline state.
- Vignette: a "Pharmaverse code" paragraph with one example of the generated code.
- README: one Key Features bullet.

- [ ] **Step 1: Generate the docs.** Run `devtools::document()`, then `pkgdown::check_pkgdown()`. Expected: clean.
- [ ] **Step 2: Run the full suite.** Run `devtools::test()` and `devtools::check()`. Expected: 0 errors, 0 warnings, and failures 0.
- [ ] **Step 3: Rebuild the site.** Run `pkgdown::build_site(preview = FALSE)`, then delete `docs/CLAUDE.*` / `docs/MEMORY.*` and their sitemap and search entries.
- [ ] **Step 4: Update `MEMORY.md`.** Add a change-log entry, and mark the E1 row "built, awaiting RStudio check". Record only the automated checks; the RStudio checks are recorded after the user reports them.
- [ ] **Step 5: Check line endings.** Convert to CRLF and check for bare LF in every CRLF file touched.
- [ ] **Step 6: Commit.** Message: `docs: pharmaverse code style (0.11.0)`

## Self-review

- **Spec coverage:**
  - §5.1 → Tasks 4 and 5, with the UI in Task 6.
  - §5.2 rules → Tasks 1 (rules 1, 4, 5, 7, 8 and prep), 2 (rule 2, `installed`), 3 (rules 2 and 3 in JS) and 4 (rule 6).
  - §5.3 → Task 4.
  - §5.4 → Task 6, plus print in Task 1.
  - §5.5 → Task 6 (Review Focus 2).
  - §6 edges:
    - `cdisc = FALSE` with a loaded step and no check → `combineSuppFor` with no field is dplyr (Task 4).
    - Two merges → each is keyed on its own step (Task 4).
    - Widget `max_rows` → rule 3 (Tasks 3 and 6).
  - §7 → the tests in Tasks 1-6.
  - §8 → the rulings above.
- **Types:** these names are used the same way in every task:
  - `combine_supp {ok, reason, prep{rdomain, idvar_na}, installed?}`
  - `setSuppCheck(key, field)`
  - `combineSuppFor(step)`
  - `combineSuppApplies(step)`
  - `combineSuppStopReason(d, parentName)`
  - `rAsCharacter`, `strTrim`
  - `sideview_code_style`, `codeStyle`, `data-sv-code-style`
- **Open risk:** the JS `as.character` for values near 15-digit boundaries. The value table is the guard, and any mismatch falls back to not ok.
