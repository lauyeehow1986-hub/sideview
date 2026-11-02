# CDISC Join Keys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto Map suggests CDISC composite join keys (subject, ADaM-to-SDTM trace, visit) as one-click multi-key joins, and the join check explains many-to-many results and repeating natural keys.

**Architecture:** A rule engine in R (`R/cdisc_keys.R`) reads each card's `card$cdisc` tag and column names only. `sv_suggest_mappings()` uses it for pairs of tagged cards and keeps the heuristic for every other pair. The browser draws one dashed spline per key with a shared group id and accepts the group as one pipeline change. Key-check notes are computed in the R `join_diagnostics_request` handler and shown in the join-check panel; the diagnostics twins are untouched.

**Tech Stack:** R (testthat, shiny `testServer`), vanilla JS (`inst/www/sideview.js`, `sv-pipeline.js`, run under Node in tests), chromote real-browser tests.

**Spec:** `plans/2026-11-02-cdisc-join-keys-design.md` (read it first; section numbers below refer to it).

## Global Constraints

- Release **0.6.0** (`DESCRIPTION`, `NEWS.md`); branch `claude/cdisc-join-keys`. Commit locally only; ask before pushing.
- Synthetic data only, never real patient data. Extend `tests/testthat/helper-cdisc.R`.
- `sv_` prefix, `snake_case`, roxygen for exports; every export is in the `_pkgdown.yml` reference index.
- Rule rows: `confidence = 1`; the tooltip says "CDISC rule", never a percentage (§5.2).
- Column names match case-insensitively; output uses each table's own spelling (§4).
- Rules read tags and column names only: no row scan, lazy cards never collected (§3).
- Gadget and module only: the htmlwidget gets nothing. `sv_join_diagnostics()`, `sv_lazy_join_diagnostics()` and JS `joinDiagnostics()` are not changed (§6).
- CSS uses existing `--sv-*` tokens only; icons/text no emoji; JS escapes table-derived text before `innerHTML`; generated R code must `parse()`.
- Every UI change is verified in a real browser; record it in `MEMORY.md` (CLAUDE.md verification rule). Keep the CLAUDE.md inputs/messages list in sync.
- Run R as `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"`. Single file: `Rscript -e "devtools::load_all(); testthat::test_file('tests/testthat/<file>')"`. Real-browser tests need `NOT_CRAN=true`.
- Commit trailer: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A pair of tagged cards with no rule (e.g. `lb` with `vs`, `ae` with `suppae`, two DM cards) gets **no** suggestion and no heuristic noise (Task 2).
2. A card whose tag the user cleared or `cdisc = FALSE` behaves exactly as 0.5.0 Auto Map (Task 2).
3. A group with a missing column port is dropped whole, never partially offered (Task 4).
4. A group where some keys are already connected merges into the existing join, in the existing direction (Tasks 3, 4).
5. Mixed-case or lazy tables give the same keys, in their own spelling (Task 1).

## File structure

| File | Responsibility |
|---|---|
| `R/cdisc_keys.R` (new) | `sv_cdisc_join_keys()` (export), `sv_cdisc_key_notes()` (internal) |
| `R/copilot.R` | `sv_suggest_mappings(cdisc =)`, `group`/`kind` columns |
| `R/app_server.R` | pass session `cdisc`; add `cdisc_notes` to the join-check reply |
| `inst/www/sv-pipeline.js` | `Pipeline.addJoinKeys()` |
| `inst/www/sideview.js`, `sideview.css` | grouped suggested splines; notes in the join-check panel |
| `tests/testthat/helper-cdisc.R` | fixtures `lb`, `vs`, `sv`, `adae_seq` |
| `tests/testthat/test-cdisc-keys.R` (new) | R rules, notes, server tests |
| `tests/testthat/test-pipeline.R` | `addJoinKeys` |
| `tests/testthat/test-layout-browser.R` | real-browser tests (CDISC section near line 1979) |

---

### Task 1: Rule engine `sv_cdisc_join_keys()`

**Files:**
- Create: `R/cdisc_keys.R`, `tests/testthat/test-cdisc-keys.R`
- Modify: `tests/testthat/helper-cdisc.R` (fixtures), `NAMESPACE` (via `devtools::document()`), `_pkgdown.yml` (reference index, next to `sv_cdisc_catalogue`)

**Interfaces:**
- Produces: `sv_cdisc_join_keys(cards)` → data frame, one row per suggested pair, columns `from_table` (chr), `to_table` (chr), `from_cols` (list of chr), `to_cols` (list of chr), `kind` (`"trace"|"subject"|"visit"`), `reason` (chr); zero rows (same columns) when fewer than two eligible cards. `cards` = list of `sideview_card` after `sv_cdisc_resolve()`.
- Produces internal helpers later tasks use: `sv_keys_colnames(card)` → the card's real column names (source for lazy cards, else data); `sv_keys_pair_rule(cx, cy)` → the single row (list with `left`, `right`, `from_cols`, `to_cols`, `kind`, `reason`) for an ordered pair of cards or `NULL`.
- Consumes: `card$cdisc` fields `domain`, `class`, `standard`; `sv_cdisc_card_cols()`-style lazy name access (`sv_lazy_names()` for lazy sources, see `R/cdisc.R:sv_cdisc_card_cols`).

- [ ] **Step 1: Add fixtures to `sv_cdisc_fixtures()`** — `lb` (STUDYID, DOMAIN="LB", USUBJID, LBSEQ, LBTESTCD, VISITNUM), `vs` (DOMAIN="VS", VSSEQ, VSTESTCD, VISITNUM), `sv` (DOMAIN="SV", USUBJID, VISITNUM, VISIT), `adae_seq` (the existing `adae_pfx` already has `AESEQ`; reuse it as the ADaM-with-AESEQ table, named `adae` on the canvas), `adsl_nostudy` (adsl without STUDYID), `dm_upper_lower` (dm with lowercase names). Use the same `sid`/`usub` vectors so joins match. Add helper `sv_cdisc_cards(tables)` → `sv_cdisc_finalize(sv_normalize_cards(tables))` (confirm `sv_normalize_cards` takes a named list and names cards from it).
- [ ] **Step 2: Write failing tests** in `test-cdisc-keys.R`, each using `sv_cdisc_cards()`:
  - `"trace: adae joins ae by STUDYID, USUBJID, AESEQ"`: `adae_pfx`+`ae` → one row, `from_table "adae"`, `to_table "ae"`, `from_cols[[1]]` = `to_cols[[1]]` = `c("STUDYID","USUBJID","AESEQ")`, `kind "trace"`.
  - `"trace beats subject"`: with `dm`, `ae`, `adae_pfx`, the pair adae/ae is `trace`.
  - `"subject: ae to dm, adlb to adsl"`: kinds `subject`, `from_table "ae"`, `to_table "dm"`; ADaM `adlb` goes to `adsl` (hub preference) even when `dm` is present, and `ae` goes to `adsl` when `dm` is absent; with both hubs present adsl→dm is `subject` (left adsl, right dm); `ae` with `adsl` while `dm` exists gives no row.
  - `"visit: lb joins sv by STUDYID, USUBJID, VISITNUM"`; `"lb with vs gives nothing"`.
  - `"excluded"`: `suppae`, a RELREC-like card, and `ts` never appear; a cleared tag (`cards[[i]]$cdisc <- NULL`) takes no part; two DM-kind cards give nothing.
  - `"no STUDYID: USUBJID alone"`: `adsl_nostudy` + `adlb` → keys `USUBJID`; `reason` contains `no STUDYID`.
  - `"column spelling"`: lowercase-named dm/ae give keys in lowercase spelling per side (`from_cols`/`to_cols` may differ per side).
  - `"lazy card"`: a duckdb-backed card (follow the lazy fixtures in `test-lazy.R`) gives the same keys as the data frame and `card$source` is not collected.
  - `"empty"`: one card → zero-row frame with the six columns.
- [ ] **Step 3: Run to verify they fail** (`sv_cdisc_join_keys` not defined).
- [ ] **Step 4: Implement `sv_cdisc_join_keys(cards)` and the two helpers** in `R/cdisc_keys.R` per §4.1–4.4. Algorithm for an unordered pair: try trace (ADaM non-ADSL + SDTM/SEND domain `D`, both have `<D>SEQ`), then subject (one hub, other subject-keyed; hub choice per §4.3.2: for each non-hub card compute its preferred hub on the canvas and only emit if the other card *is* that hub; hub-with-hub: ADSL left, DM right), then visit (`SV` + `VISITNUM`). Subject key per §4.2 (`STUDYID` only if both cards have it). Roxygen with `@export`, `@return`, a runnable example on the fixtures-free data (`dm`/`ae` built inline).
- [ ] **Step 5: `devtools::document()`; add `sv_cdisc_join_keys` to `_pkgdown.yml`; run `test-cdisc-keys.R` → PASS.**
- [ ] **Step 6: Commit** `feat(cdisc): sv_cdisc_join_keys rule engine`.

---

### Task 2: Auto Map uses the rules (`sv_suggest_mappings`, server)

**Files:**
- Modify: `R/copilot.R`, `R/app_server.R` (handler at `request_suggested_mappings`), `tests/testthat/test-cdisc-keys.R`, `tests/testthat/test-app.R` (existing suggestion test stays green)

**Interfaces:**
- Consumes: `sv_cdisc_join_keys(cards)` (Task 1).
- Produces: `sv_suggest_mappings(cards, ..., min_confidence = 0.6, cdisc = "auto")`; result and `.empty_mappings_result()` gain `group` (chr, `NA` for heuristic rows, else `"cdisc:<from>~<to>"`) and `kind` (chr or `NA`). Rule rows: one row per key pair (`from_col`/`to_col` paired by position), `confidence = 1`, rule `reason`, sorted first, never filtered by `min_confidence`. Wire candidates carry `group` and `kind` (NA → JSON null).

- [ ] **Step 1: Write failing tests**: (a) `dm, ae, adsl, adae_pfx` → rule rows only for tagged pairs; no row has `from_col == "DOMAIN"` or a lone `STUDYID` between tagged cards; group sizes: adae~ae 3, ae~dm 2; rule rows precede heuristic rows. (b) `cdisc = FALSE` and a card with its tag set to `NULL` give exactly the 0.5.0 result: compare with the same call on plain data frames (columns minus `group`/`kind`, `expect_equal`). (c) `lb` + `vs` + `ts` untagged-pair rows come only from the heuristic (`group` all `NA`). (d) `.empty_mappings_result()` has both columns. (e) `testServer(sideview_server(cards))`: after `request_suggested_mappings` the last `sideview_suggested_mappings` message's candidates include `group` and `kind` for rule rows; with `sideview_server(cards, cdisc = FALSE)` no candidate has a non-NA `group` (confirm the actual argument name by reading `sideview_server`'s signature).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** in `copilot.R`: after building `valid_cards`, when `!identical(cdisc, FALSE)` get rule rows from `sv_cdisc_join_keys(valid_cards)`; skip the heuristic loop for pairs (by card index) that appear in the rule frame **or** where both cards are tagged and eligible-but-ruleless (use a helper `sv_keys_eligible(card)` from Task 1's file: tagged, not SUPP/RELREC, has `USUBJID`; export it to the package namespace internally); expand rule rows to one row per key pair; bind rule rows first; add `group`/`kind`. Data-frame inputs are tagged by `sv_normalize()`; `cdisc = FALSE` skips rules and clears nothing else. `app_server.R`: pass the session's `cdisc` into `sv_suggest_mappings()`.
- [ ] **Step 4: Run `test-cdisc-keys.R`, `test-app.R`, `test-copilot*.R` → PASS.**
- [ ] **Step 5: Commit** `feat(cdisc): Auto Map suggests CDISC keys for tagged pairs`.

---

### Task 3: `Pipeline.addJoinKeys()` (one undo step)

**Files:**
- Modify: `inst/www/sv-pipeline.js` (next to `addJoinKey`, line ~531), `tests/testthat/test-pipeline.R`

**Interfaces:**
- Produces: `Pipeline.prototype.addJoinKeys(left, right, pairs, type)` where `pairs` = `[{left, right}, ...]`; one `change('join', ...)`; creates the join step `{kind:'join', key, table:left, right, type, by:pairs}` or appends only missing pairs to the existing step for `joinKey(left, right)`; also if the *reverse* join `joinKey(right, left)` exists, appends the pairs swapped to that step (keeps its direction). Returns nothing. A no-op (all pairs present) leaves history alone.

- [ ] **Step 1: Write failing tests** (style of `run_pipeline_js`): three pairs added → `steps.length == 1`, `by.length == 3`, `undo()` → `steps.length == 0` in one call; a second call with overlapping pairs adds only the missing one and creates no second step; with an existing `ae→adae` join, adding `adae→ae` pairs merges into it (swapped), `steps.length == 1`, direction `table == 'ae'`; the composed code `parse()`s (`expect_parses`); evaluated on the fixtures (`ae`, `adae_pfx`) via `dplyr` its row count equals `dplyr::left_join(adae, ae, by = c("STUDYID","USUBJID","AESEQ"))`.
- [ ] **Step 2: Run → FAIL.** **Step 3: Implement.** **Step 4: Run `test-pipeline.R` → PASS; `node --check inst/www/sv-pipeline.js`.**
- [ ] **Step 5: Commit** `feat(pipeline): addJoinKeys adds a key set as one undo step`.

---

### Task 4: Grouped suggested splines on the canvas

**Files:**
- Modify: `inst/www/sideview.js` (`renderSuggestedSplines` ~3305, `addConnection` ~3425, add `addConnections`), `inst/www/sideview.css` (after `.sideview-spline-suggested.is-hover`), `CLAUDE.md` (message list: candidate fields `group`, `kind`)

**Interfaces:**
- Consumes: candidates with `group`/`kind` (Task 2), `Pipeline.addJoinKeys` (Task 3).
- Produces: `SideviewEngine.prototype.addConnections(list)` — draws every connector of `list` (each item shaped like `addConnection`'s `connData`), calls `pipeline.addJoinKeys` once, sends one `column_mapped` per key. Suggested paths for a group share `dataset.group`, class `sideview-spline-suggested-cdisc`; heuristic candidates unchanged.

- [ ] **Step 1: Implement per §5.2.** In `renderSuggestedSplines`, partition candidates by `group`. For each group: skip pairs already connected; if no keys remain draw nothing; resolve every port with `findPortElement`, and if any is missing `console.warn` and drop the whole group; direction = an existing join in the opposite direction if present (swap tables/cols), else as given. Draw one path per key, all with `data-group`; hover on any member toggles `is-hover` on all; the SVG `<title>` reads `Suggested CDISC join: <from> to <to> by <cols> (<kind label>). Click to accept` with kind labels `ADaM to SDTM trace`, `subject key`, `visit key`. A click on any member removes all the group's paths and `suggestedConnections` entries, calls `addConnections`, shows one toast `Accepted CDISC join: <from> to <to> by <cols>`. Remember `console.warn` for unknown ports uses the existing style (`warnNoCard`-like).
- [ ] **Step 2: CSS**: `.sideview-spline-suggested-cdisc { stroke-width: 3px; }` and `.is-hover` inherits; tokens only. Add a `title` mention in `?` dialog is not needed (no new shortcut).
- [ ] **Step 3: `node --check inst/www/sideview.js`; run `test-layout-browser.R` CDISC section and `test-lazy-browser.R` Auto Map test (`NOT_CRAN=true`) to confirm heuristic splines still work.**
- [ ] **Step 4: Update the CLAUDE.md list; commit** `feat(cdisc): grouped CDISC suggestion splines accepted as one join`.

(The new real-browser assertions are Task 7.)

---

### Task 5: Key-check notes `sv_cdisc_key_notes()` and the reply field

**Files:**
- Modify: `R/cdisc_keys.R`, `R/app_server.R` (`join_diagnostics_request` handler, line ~326), `tests/testthat/test-cdisc-keys.R`

**Interfaces:**
- Produces: `sv_cdisc_key_notes(cx, cy, by_x, by_y, diag)` → chr vector (possibly empty). `cx`,`cy` = the two cards; `by_x`/`by_y` = key column names; `diag` = the diagnostics list (`relationship`, `dup_keys_x`, `dup_keys_y`). Reply field `cdisc_notes` (chr vector, `[]` when none).
- Consumes: `sv_keys_pair_rule()` (Task 1), the catalogue `keys` column via `sv_cdisc_row_std()`.

- [ ] **Step 1: Write failing tests** with exact texts from §6:
  - note 1: `ae` x `adae_pfx` by `USUBJID`, relationship `many-to-many` → `"Add STUDYID, AESEQ: the CDISC key for adae and ae is STUDYID, USUBJID, AESEQ."` (missing keys listed in rule order).
  - note 2 findings: `lb` x `vs` many-to-many → `"LB and VS both have many records per subject and visit: filter each to one test (LBTESTCD, VSTESTCD) or summarise before joining."`; a pair with no Findings class → `"Add VISITNUM or a --SEQ key, or summarise one side first."` naming only keys present in both; none present → `"Summarise one side first."`.
  - note 3: `ae` with a duplicated AESEQ joined by `STUDYID, USUBJID, AESEQ`, `dup_keys_x = 3` → `"STUDYID, USUBJID, AESEQ should identify one AE record, but 3 keys repeat: check for duplicate records."`; `dm` with a repeated subject; ADSL joined by its subject key with dups; an ADaM non-ADSL card gets no note 3.
  - no notes: relationship `one-to-one` with no dups; untagged or cleared card; `diag` containing `error`; an unequal key set for note 3.
  - `testServer`: `join_diagnostics_request` for dm→ae by `USUBJID` has `cdisc_notes`; none for `sideview_server(cards, cdisc = FALSE)` and none when the reply is an error.
- [ ] **Step 2: Run → FAIL. Step 3: Implement the helper (names in each table's own spelling) and the handler (compute after `result` is built, skip on `result$error`; handler already has the cards `cx`, `cy`; the session `cdisc` setting is in scope as `cdisc`). Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(cdisc): key-check notes in the join check reply`.

---

### Task 6: Show the notes in the join-check panel

**Files:**
- Modify: `inst/www/sideview.js` (join-check render, ~4585, after the `warnings` list), `inst/www/sideview.css`, `CLAUDE.md` (join-diagnostics paragraph: `cdisc_notes` is an R-only reply field)

**Interfaces:**
- Consumes: `d.cdisc_notes` (array of strings, absent in the widget).

- [ ] **Step 1: Implement**: when `d.cdisc_notes && d.cdisc_notes.length`, render `<p class="sideview-joincheck-cdisc-title">CDISC</p>` and the existing `list()` helper (escaped) with class `sideview-joincheck-cdisc`, placed directly after the warnings list. CSS under `.sideview-container`, existing tokens, matching the warnings list spacing.
- [ ] **Step 2: `node --check`; the existing join-check browser tests still pass.**
- [ ] **Step 3: Commit** `feat(cdisc): show CDISC key notes under the join check warnings`.

---

### Task 7: Real-browser tests

**Files:**
- Modify: `tests/testthat/test-layout-browser.R` (CDISC section from line ~1979; follow `sv_cdisc_page()` and the real-mouse pattern used for splines in this file)

- [ ] **Step 1: Add tests** (real input via `Input.dispatchMouseEvent`; `skip_if_no_browser()`; page shows `dm`, `ae`, `adsl`, `adae` from the fixtures):
  - Auto Map draws grouped paths: `adae~ae` has 3 paths and `ae~dm` 2, all with the shared `data-group`; hovering one member sets `is-hover` on every member of its group.
  - One click on one member → exactly one join step with the right `by`, the group's paths gone, one `Accepted CDISC join` toast, and one undo (`Ctrl+Z`) removes the join.
  - A group with a missing port is not drawn (rename a column header out of view or card removed → no group paths, `console.warn` seen).
  - Join check: connect `ae`→`lb` by `USUBJID` only (use `lb` fixture) → the panel shows the `CDISC` heading and the Findings or `Add ...` note text.
  - With `sideview(..., cdisc = FALSE)` Auto Map draws no CDISC-class paths.
- [ ] **Step 2: Run with `NOT_CRAN=true`** (`Rscript -e "Sys.setenv(NOT_CRAN='true'); devtools::load_all(); testthat::test_file('tests/testthat/test-layout-browser.R', reporter='summary')"`) → PASS; fix real defects found (do not weaken assertions).
- [ ] **Step 3: Commit** `test(cdisc): real-browser checks for CDISC join suggestions and notes`.

---

### Task 8: Docs, release 0.6.0 and verification

**Files:**
- Modify: `DESCRIPTION` (Version 0.6.0), `NEWS.md` (new top section `# sideview 0.6.0`, "CDISC join keys": Auto Map rules, grouped splines, key-check notes, `sv_cdisc_join_keys()`, limits), `vignettes/articles/cdisc.Rmd` (new "Join keys" section incl. the limits from §10; confirm the article path with `ls vignettes/articles`), `MEMORY.md` (log entry with test counts and browser/RStudio results; move sub-project B out of the Backlog), `docs/` (rebuilt site)

- [ ] **Step 1: Update version, NEWS, article; `devtools::document()`; `pkgdown::check_pkgdown()` clean.**
- [ ] **Step 2: Full suite** `Rscript -e "Sys.setenv(NOT_CRAN='true'); devtools::test()"`: 0 failed (the known 1 skipped is fine); then `devtools::check()`: no new warnings or errors beyond the known Windows NULL NOTE.
- [ ] **Step 3: RStudio pass (computer use)**: launch the gadget in dialog, pane and external-browser viewers with `dm, ae, adsl, adae_pfx, lb`; Auto Map → grouped splines → accept → one undo; join check on `ae`×`lb` by `USUBJID` shows notes; record results and the one-RStudio-instance gotcha in `MEMORY.md`.
- [ ] **Step 4: Rebuild the site (`pkgdown::build_site()` with `RSTUDIO_PANDOC` set, drop `docs/CLAUDE.*`/`docs/MEMORY.*` and their `sitemap.xml`/`search.json` entries per CLAUDE.md).**
- [ ] **Step 5: Commit** `docs(cdisc): 0.6.0 notes, article, site and verification log`. Do not push; ask first.
