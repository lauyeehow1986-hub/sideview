# sideview E1: a `metatools::combine_supp()` code style for SUPP merges: design

- **Date:** 2026-11-22
- **Sub-project:** E, part 1 of 5 (order agreed 2026-11-22: E1 `combine_supp()`, E2 ADSL merges with
  `admiral::derive_vars_merged()`, then `dm`, `pointblank`, `metacore` spec check). Each part has its own spec,
  plan and PR.
- **Status:** decisions made in chat, one at a time; builder check done (2026-11-22, one question taken to the
  user: decision 6); awaiting the user's approval
- **Builds on:** `plans/2026-11-03-cdisc-suppqual-merge-design.md` (the 0.7.0 SUPP merge: step, check twins,
  guards, wire). Read it first; this spec only describes what changes.

## 1. Intent

The Merge into AE step writes tidyr + dplyr code today. Pharmaverse programmers write the same merge as
`metatools::combine_supp(ae, suppae)`. E1 lets sideview write that form, so the code reads as they would write it
and can be pasted into an admiral-style program. **This "why" is the builder's assumption, stated in chat and
not corrected by the user; it was never stated by the user.**

The one rule that governs everything below (the user's choice, approach A): **sideview writes
`combine_supp()` only when its result is the same as the dplyr code's result.** Where it would differ, the step
stays dplyr and says why. The code sideview writes always means one thing, whichever style is chosen.

## 2. What the user decided

1. **When the results would differ: option A.** The pharmaverse form is offered only when the result would
   match; otherwise it is greyed out, with the reason.
2. **Where the choice lives: one canvas-wide setting** ("Pharmaverse code"), not a per-step checkbox. E2 reuses
   the same setting for ADSL joins. A step whose result would differ stays dplyr and says why in its step line.
3. **How "same result" is decided: approach 1.** The `combine_supp()` rules are copied into the merge check (R,
   JS and lazy twins), and tests that call the real `combine_supp()` prove the copy right.
4. **Two prep lines are allowed** before the call, so ordinary `.xpt`-derived SUPP tables qualify (§5.2).
   Nothing else is written around the call to make it fit; every other difference greys the option out.
   (Guards that stop the code are not "making it fit"; see decision 6.)
5. metatools is installed on the dev machine (0.3.0, with metacore 0.3.0).
6. **The promise also holds when the code is rerun on a later data cut** (asked after the builder check,
   2026-11-22; the user took the builder's pick). The generated code gets a text-match guard (§5.3) that
   stops when any keyed SUPP row would match differently as text (`combine_supp()`) than as a number (the
   dplyr code). It runs in the session doing the work, so it also covers that session's `options(scipen)`.

## 3. Goals, non-goals, anti-goals

**Goals**
- A canvas-wide code style, `dplyr` (default) or `pharmaverse`, that the merge step honours.
- The merge check reports whether `combine_supp()` applies, and why not, in R, JS and lazy alike.
- In pharmaverse style, an eligible merge step composes to `metatools::combine_supp()` (plus at most the two
  prep lines and the guards of §5.3), and its result equals the dplyr code's result on every test fixture.
- Works on the canvas, in the list view and from the console (roadmap rule for D and E).

**Non-goals**
- ADSL joins (`admiral::derive_vars_merged()`): E2.
- A pharmaverse form for any other step (filter, join, summarise, derive, stack, compare).
- Fixing a SUPP table to suit `combine_supp()` beyond the two prep lines (no invented `QORIG`, no dropped
  columns, no added `DOMAIN`).
- metatools as a hard dependency. It goes in `Suggests:` as `metatools (>= 0.3.0)`: older versions stop on
  orphan rows and (before 0.2.0) set no labels.

**Anti-goals (a failure even if it runs)**
- Generated pharmaverse code whose result differs from what the merge check showed.
- A setting that silently changes the result of a workspace someone saved earlier.
- Greying the option out on ordinary SDTM data from `.xpt` files (blank `IDVAR`, no `QEVAL`).

## 4. Constraints

- Twin rule (CLAUDE.md): `sv_supp_check()`, `SideviewPipeline.suppCheck()` and `sv_lazy_supp_check()` gain the
  same field with the same values; `test-supp.R` and `test-lazy.R` hold them to each other.
- Generated R code must `parse()`; a test for every new generator.
- Workspace state stays schema v0.3.0: the new setting is an optional field (an older sideview ignores it).
- Module mode is an untrusted client: the setting is display and codegen only; nothing new is evaluated in R.
- No emoji or glyph icons; CSS through `--sv-*` tokens, scoped under `.sideview-container`.
- Keep CRLF in MEMORY.md, NEWS.md, DESCRIPTION, plans/*.md, CLAUDE.md, inst/www/sideview.js.

## 5. Design

### 5.1 The setting

- **R argument:** `code_style = c("dplyr", "pharmaverse")` on `sideview()`, `sideview_widget()`,
  `save_sideview()` and `sideviewServer()`; `match.arg()`; default `"dplyr"`.
- **Pipeline state:** `Pipeline` gets `style` beside `pipe` (`'dplyr' | 'pharmaverse'`), with
  `setStyle(style)` emitting a change like `setPipe()`, and `toJSON()` / `fromJSON()` carrying it
  (`{steps, pipe, style}`). A state without `style` loads as `dplyr`, so an older workspace composes exactly as
  before (anti-goal 2). A state's `style` wins over the `code_style` argument, as `pipe` already does.
- **UI:** a second select in the Pipeline tab bar, beside Pipe: `Code <select>` with `dplyr` and
  `pharmaverse`, `aria-label="Code style"`. The same bar serves the list view. Changing it is one undo step
  (as Pipe is, or is not, today: match `setPipe()`).
- E2 reads the same `style`.

### 5.2 The check field

`sv_supp_check()` and its two twins gain `combine_supp`:

```
combine_supp = { ok: TRUE|FALSE, reason: "<text>" | null, prep: { rdomain: TRUE|FALSE, idvar_na: TRUE|FALSE } }
```

- `prep$rdomain`: write `dplyr::filter(RDOMAIN == "<rdomain>")` before the call. TRUE when the SUPP card has
  rows of another RDOMAIN (always the case that matters for a generic SUPPQUAL). Without it `combine_supp()` adds
  an all-NA column per foreign QNAM to the parent and warns.
- `prep$idvar_na`: write `dplyr::mutate(IDVAR = dplyr::na_if(IDVAR, ""))`. TRUE when a subject-level row has
  `IDVAR == ""` (or whitespace only: then the prep is `dplyr::na_if(trimws(IDVAR), "")`; the builder picks one
  form that covers both and tests it). `combine_supp()` 0.3.0 fails on `IDVAR = ""` with "attempt to set an
  attribute on NULL"; `NA` works.
- The field is computed for every check, whatever the style, so the console and the step line can always say
  whether the pharmaverse form applies.

**`ok` is FALSE, with the first failing reason in this order** (texts are the user-facing copy; `<x>` are names
in each table's own spelling):

| # | Condition | `reason` |
|---|---|---|
| 1 | the check itself is `{error}` or status `error` | the check's own error / problem text |
| 2 | a card is lazy (duckdb, Arrow) | `combine_supp() needs data frames: <table> is a <duckdb/Arrow> table` |
| 3 | the check ran on preview rows (widget `max_rows`, lazy fallback) | `Checked on preview rows only` |
| 4 | SUPP columns, after the prep, are not exactly `STUDYID RDOMAIN USUBJID IDVAR IDVARVAL QNAM QLABEL QVAL QORIG` plus optional `QEVAL` | `<supp> has no QORIG column` / `<supp> has extra columns: X, Y` |
| 5 | the parent lacks `STUDYID`, `DOMAIN` or `USUBJID` | `<parent> has no DOMAIN column` |
| 6 | the SUPP chain or the parent chain has steps of its own before the merge that `combine_supp()` cannot see | builder decides whether this is a limit at all (§8); if it is: `<supp> has steps before the merge` |
| 7 | the row matching differs (below) | `IDVARVAL "01" would not match AESEQ 1 in combine_supp()` (first differing row) |
| 8 | the labels differ (below) | `AETRTEM label would be "TE two" in combine_supp(), not "TE one"` |

**Row matching (rule 7).** Our check already knows, for each SUPP row, which parent record it joins (or that it
is an orphan or a bad `IDVARVAL`). Compute the same for `combine_supp()` 0.3.0 and compare row by row; any
difference is rule 7:
- it joins on `STUDYID`, `DOMAIN` (= `RDOMAIN`) and `USUBJID`, plus the IDVAR column for keyed rows;
- for a keyed row it compares `str_trim(as.character(IDVARVAL))` with `str_trim(as.character(<parent key>))`:
  text, not numbers. `str_trim` trims Unicode whitespace (ours trims the ASCII class only). R's
  `as.character()` on a double keeps 15 significant digits and picks fixed or scientific form
  (`100000` -> `"1e+05"`, `110000` -> `"110000"`, `0.1 + 0.2` -> `"0.3"`, `1/3` -> `"0.333333333333333"`).
  **The JS twin must reproduce R's `as.character()` for doubles exactly**, pinned by a value table generated
  in R (§7). A factor key is compared by its level text; an integer key by its digits;
- `as.character()` on a double depends on `options(scipen)` (`scipen = 999` gives `"100000"`, not
  `"1e+05"`). **Both check twins assume the default `scipen = 0`**: the R twin evaluates under
  `withr::local_options(scipen = 0)` or base `op <- options(scipen = 0); on.exit(options(op))`, so R and JS
  agree whatever the user's session says. The run-time guard of §5.3 covers sessions with another setting;
- a repeated QNAM for one record gives a list column in `combine_supp()` (ours stops): our status is already
  `error`, so rule 1 covers it;
- a QNAM at two IDVAR levels is overwritten silently by `combine_supp()` (ours stops): rule 1;
- orphans and bad `IDVARVAL` rows are not merged by either: same result (`combine_supp()` warns at run time; the
  step line says so, §5.4).

**Labels (rule 8).** `combine_supp()` sets each QNAM's label to the **last** QLABEL of that QNAM in SUPP row
order, blank included, so a blank last label gives `""`; an all-`NA` QLABEL gives `NA`. Ours takes the first
non-`NA` QLABEL of each QNAM, and `suppLabels()` drops a blank one, so a blank first label gives no label. Counted as the same: no label and `""`. Otherwise the two
labels must be identical. (Builder's call to compare after the prep's RDOMAIN filter, since that is what the
call sees.)

**Column order is not compared.** "Same result" = same rows in the same order, same column set, same values and
classes, same labels (as above). Both keep the parent's row order (left joins).

**metatools installed:** the R check adds `installed: TRUE|FALSE` (metatools 0.3.0 or later is installed:
`requireNamespace()` plus `utils::packageVersion() >= "0.3.0"`; builder's call) in the gadget and module; the JS twin leaves it `null` (a saved page cannot know). It never changes
`ok`.

### 5.3 The generated code

When `style == 'pharmaverse'` and the merge check the engine holds for the step (`engine.suppChecks`, not the
step itself) has `combine_supp$ok`, `compose()` writes, in place of the dplyr block of 0.7.0 §6.2, the code
below. The engine hands the check to the pipeline the way `setJoinCheck()` does for joins. A check whose plan is
out of date (`drift.stale`) composes as dplyr. Builder's calls, from reading the code.

```r
suppae_q <- suppae %>%
  dplyr::filter(RDOMAIN == "AE") %>%                # only with prep$rdomain
  dplyr::mutate(IDVAR = dplyr::na_if(IDVAR, ""))    # only with prep$idvar_na
local({
  # the 0.7.0 guards that combine_supp() does not do itself:
  # IDVAR values the plan does not handle; QNAMs at two levels; a repeated QNAM for one record
  # (on STUDYID, USUBJID, IDVAR, trimmed IDVARVAL, QNAM). No clash guard: combine_supp() stops on a clash.
  # Text-match guard (user decision 6), one per keyed IDVAR level whose parent key is numeric:
  # for the SUPP rows of that level, the parent record found by text
  #   stringr::str_trim(as.character(IDVARVAL)) == stringr::str_trim(as.character(<key>))
  # must be the parent record found by the dplyr code's numeric conversion (the 0.7.0 key conversion);
  # otherwise stop("IDVARVAL \"01\" matches AESEQ 1 as a number but not as text in combine_supp(); ",
  #                "use the dplyr code style for this merge").
})
ae %>%
  metatools::combine_supp(suppae_q)
```

- With neither prep line and no SUPP chain, `suppae_q` is not written and the call takes `suppae` directly
  (builder's call whether the guards then read `suppae` directly).
- The text-match guard is written only for levels whose parent key is numeric (integer or double); character
  and factor keys are compared as text by both styles. It uses `stringr::str_trim()` (metatools imports
  stringr, so it is installed wherever the call can run), to trim exactly as `combine_supp()` does. Its exact
  form is the builder's; it must `parse()`, run on data frames, and stop on the rule-7 fixtures when the check
  is bypassed (§7). It runs in the user's session with the user's `scipen`, which is the point.
- `combine_supp()` labels the columns itself: no `<supp>_labels` vector, no label `mutate`.
- The guards are kept on purpose (builder's proposal, see §9): the plan is fixed when the step is added, and
  without them a changed SUPP table could give a list column or an overwritten QNAM with only a warning.
- The step stays one `{kind: 'supp', ...}` step; the style is not stored on the step. Switching the style
  recomposes every merge step, and an ineligible step keeps writing dplyr.
- The pipe in the chain follows `pipe` (`%>%` or `|>`).

### 5.4 Where it shows

- **Step line (Pipeline tab, list view):** in pharmaverse style, an eligible step adds `· combine_supp()`; an
  ineligible one adds `· dplyr: <reason>`. When R says `installed: FALSE`: `· needs metatools 0.3.0 or later to run`. When the
  check counted orphans or bad `IDVARVAL` rows: the existing warning text, plus `(combine_supp() warns)`.
- **Merge check panel (Discrepancy tab):** one line, `combine_supp(): yes` or `combine_supp(): no, <reason>`,
  shown in both styles.
- **Console:** `print.sv_supp_check()` prints the same line; `sv_supp_check_json()` carries the field.
- In dplyr style nothing else changes.

### 5.5 Re-checks and drift

No new triggers: the field rides on the existing check and its re-checks (0.7.0 §7.4). A re-check that turns
`ok` from TRUE to FALSE recomposes the step as dplyr, and the step line gives the new reason.

## 6. Edge cases

- `cdisc = FALSE`: no Merge into button, but a merge step loaded from a workspace still composes; its stored
  check decides eligibility; with no stored check yet it composes as dplyr until the re-check arrives.
- A workspace saved in pharmaverse style and opened by an older sideview: `style` is ignored, dplyr code.
- Two merges into one parent (SUPPAE and SUPPQUAL): each step is decided on its own; a QNAM made by an earlier
  merge is already a clash (status `error`, rule 1).
- Widget: the JS twin decides; with `max_rows` cutting rows, rule 3.
- SEND canvas: same rules.

## 7. Testing

Synthetic fixtures only; extend `helper-cdisc.R` with the probe cases of 2026-11-22: blank and `NA` IDVAR at
subject level, a generic SUPPQUAL with AE and CM rows, keys `"01"`, `" 1 "`, `"1.0"`, a non-breaking space,
`AESEQ` 100000 / 110000 / 0.1 + 0.2, integer, factor and character keys, no `QORIG`, no `QEVAL`, an extra SUPP
column, a parent without `DOMAIN` or `STUDYID`, labels (first vs last, blank last, all blank, all `NA`), orphans,
repeats, two levels, a clash.

- **Equivalence (`test-supp.R`, `skip_if_not_installed("metatools")`):** for every fixture where the field says
  `ok`, the composed pharmaverse code runs and equals the composed dplyr code's result (rows, order, column set,
  values, classes, labels with `""` = none; column order ignored). For every fixture where it says not ok, show
  that the real `combine_supp()` (after the prep) errors or differs. This proves both directions of the copied
  rules.
- **Later data cut (decision 6):** compose pharmaverse code on an eligible fixture, then run it on a changed
  SUPP table with `IDVARVAL "01"` for `AESEQ` 1, and on the eligible one under `options(scipen = 999)` with
  `AESEQ` 100000: the text-match guard stops with its message where text and numeric matching differ, and
  passes (same result as dplyr) where they agree. The checks themselves give the same field under any `scipen`.
- **Twins:** the `combine_supp` field is equal across R and JS on every fixture, and lazy twin gives rule 2.
- **`as.character()` table:** a test generates R's `as.character()` for a fixed set of doubles (integers around
  1e5, 1e15, 1e16, fractions, 1/3, 0.1 + 0.2, negatives, 1e-4, 1e-5) and the JS helper must give the same text.
- **Codegen:** pharmaverse code `parse()`s with and without each prep line, with `%>%` and `|>`.
- **State:** `style` round-trips; a state without it loads as dplyr; `code_style =` argument and state precedence.
- **`testServer`:** the reply carries the field and `installed`.
- **Mock DOM:** the select, recompose on change, step line texts, one undo step.
- **Real browser:** switch the style and see the code drawer change; the select does not crowd the bar at 560px.
- **RStudio:** dialog, Viewer pane and external browser by hand, recorded in MEMORY.md only after the user
  reports them.

## 8. Left to the builder

- Rule 6: whether steps on the SUPP or parent chain before the merge block the pharmaverse form. The 0.7.0 code
  already composes the SUPP chain first and runs the merge on the parent's chain at that step, so
  `combine_supp()` may simply take the chain's value; if the check runs on the original cards, the same
  limitation `strictApplies()` handles for Strict applies here. Decide from the code, write the reason text if
  needed, and test it.
- The exact prep form for whitespace-only `IDVAR`.
- Where the as.character helper lives in `sv-pipeline.js` and its name.
- Whether to bump the version (0.11.0) in this PR or with E2.

## 9. Calls made by the builder (for the user to check)

- metatools goes in `Suggests:`; when it is missing the option stays available and the step line says it is
  needed to run.
- Column order is not compared; a missing label and `""` count as the same.
- On preview rows the option is greyed out (rule 3), since the full data was not checked. A saved widget page
  whose tables all fit under `max_rows` holds every row, so it is eligible like the gadget. (An earlier draft
  said every widget page was greyed out; that was wrong.)
- The 0.7.0 guards for new IDVAR levels, two-level QNAMs and repeats stay in the pharmaverse code.
- The text-match guard (decision 6) is in that guard block, uses `stringr::str_trim()`, and is written only for
  numeric keys.
- Both checks assume `scipen = 0`; the guard covers other settings at run time.
- metatools `(>= 0.3.0)`; `installed` is FALSE for an older version.
- When metatools is installed but older than 0.3.0, the step line says `needs metatools 0.3.0 or later to run`.
- The setting is called "Code" in the bar with values `dplyr` / `pharmaverse`; the R argument is `code_style`.

## 10. Files

- **Modified:** `R/supp.R` (field, print), `R/lazy.R` (lazy twin: rule 2), `R/sideview.R`, `R/widget.R`,
  `R/module.R`, `R/app_ui.R` / `R/app_server.R` (argument, `installed`), `R/state.R` (docs for `style`),
  `inst/www/sv-pipeline.js` (`style`, `setStyle`, `suppCheck` field, as.character helper, compose path),
  `inst/www/sideview.js` (select, step line, panel line), `inst/www/sideview.css`, `DESCRIPTION` (Suggests:
  metatools), `tests/testthat/helper-cdisc.R`, `test-supp.R`, `test-lazy.R`, `test-state.R`, the GUI and
  browser tests, `vignettes/articles/cdisc.Rmd` (a "Pharmaverse code" paragraph), `README.md` (one bullet),
  `CLAUDE.md` (the `combine_supp` field, `style` in pipeline state), `NEWS.md`, `MEMORY.md`, `man/`, `docs/`.

## 11. Risks

- **metatools changes its rules.** The equivalence tests run against the installed version and fail when a
  rule changes; the copied rules name 0.3.0.
- **R's `as.character()` for doubles in JS.** Easy to get almost right. The value table test is the guard; if
  the JS cannot match R for a value, the rule must say not ok rather than guess.
- **Rarely eligible in practice.** If real data often fails rules 4 or 5 (extra columns, no `QORIG`), the option
  will often be greyed out. That is the user's choice (A); the reasons make it visible.
