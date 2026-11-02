# CDISC awareness (sub-project A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** sideview recognises SDTM, SEND and ADaM tables, tags each card with its domain, shows the domain and
the variable labels on the canvas, and reads a folder of `.xpt`/`.sas7bdat`/`.json`/`.parquet` files into a
named list.

**Architecture:** All detection is in R (`R/cdisc.R`): `new_sideview_card()` tags grid cards, a canvas-level
`sv_cdisc_finalize()` applies `cdisc =` and resolves SEND/SUPP links, and the tag travels to the browser in the
card payload. The browser only draws it (badge, `th` titles, label row, inspector, search). The codebook gets a
`domain` column in both twins.

**Tech Stack:** R 4.5.2, testthat 3, shinytest2/chromote, plain JS (`inst/www`), haven / datasetjson / arrow
in `Suggests:`.

**Spec:** `plans/2026-11-01-cdisc-awareness-design.md`

## Global Constraints

- Synthetic data only: fixtures are built in code in `tests/testthat/helper-cdisc.R`. No pharmaverse data
  packages, no real patient data.
- Version `0.5.0`. New `Suggests:` entries: `haven`, `datasetjson`. Every use goes behind `requireNamespace()`.
- Exported R functions: `sv_cdisc_catalogue()`, `sv_cdisc_detect()`, `sv_read_cdisc()`. Everything else is
  internal (`@noRd`). `snake_case`, roxygen docs, and every export goes in the `_pkgdown.yml` reference index.
- `cdisc =` values: `"auto"` (default), `FALSE`, or a named character vector of domain codes. Anything else
  stops with: `` `cdisc` must be "auto", FALSE or a named character vector of domain codes. ``
- A detection failure never stops card creation: no tag, plus a message only when
  `isTRUE(getOption("sideview.debug"))`.
- Lazy tables are never collected. Detection uses `colnames()` plus at most `distinct(DOMAIN) |> head(2)` and,
  for the ADSL check only, `count(USUBJID) |> filter(n > 1L) |> head(1)`.
- Tags are not saved in workspace state. The only new state field is `view.labels_row` (boolean, default
  `false`). The state schema version stays `0.3.0`.
- CSS: new tokens `--sv-cdisc-sdtm`, `--sv-cdisc-send`, `--sv-cdisc-adam` and their `-text` pairs, defined in
  the base block, `.sv-theme-dark` and the auto-dark media block (the two dark blocks equal). Contrast ≥ 4.5:1.
  Rules are scoped under `.sideview-container`.
- JS: escape all tag and label text before `innerHTML`; `CSS.escape` in selectors; new handlers go through
  `onMessage()`; new global listeners are removed in `destroy()`. Inline SVG icons only.
- Module messages carry `ns` (through `send()` / `ctl$emit()`), queued until `sideview_ready`.
- LLM context: metadata only (domain, dataset label, variable labels), never row values.
- Every UI change is checked in a real browser (`test-layout-browser.R`) and in RStudio (dialog, pane, browser),
  and recorded in `MEMORY.md`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No push, merge or PR without
  asking the user.

## Rulings (decisions the spec left to the plan)

1. Detection runs inside `new_sideview_card()`, for `type = "grid"` only. A lazy card passes its `source` to the
   detector, and the dplyr verbs run directly on the arrow or dbplyr object, not on the session's lazy
   connection (spec §5.2 said the session connection). Lazy aggregates run only after the gate has passed
   (`STUDYID` and `USUBJID` already in the column names).
2. A new internal `sv_cdisc_finalize(cards, cdisc)` checks `cdisc`, applies `FALSE` or the overrides, then calls
   `sv_cdisc_resolve()`. It is called by `sideview()`, `sideview_widget()` (and so `save_sideview()`),
   `sideviewServer()` and the module proxy verbs.
3. `sv_normalize()` gets no `cdisc` argument: its methods do not forward `...`, so the overrides apply in
   `sv_cdisc_finalize()`. This deviates from spec §5.4, and the cost is small (a user who calls `sv_normalize()`
   directly gets `"auto"`).
4. In the widget, finalize runs on the normalised cards **before** the payload/row-cap loop, because `head()`
   drops a plain vector's `label` attribute. The payload reads labels from the tag-time data, which is
   pinned by a test.
5. Module verbs re-run finalize over the store and emit `sideview_cdisc_update` with only the tags that changed
   on *other* cards. The added or replaced card already carries its resolved tag in its own payload.
6. `sv_cdisc_resolve()` stays internal. Spec §6 names it but does not ask for an export.
7. The schema context is built in `R/llm.R` (`sv_build_schema_context()`, line 29), not `R/copilot.R` as
   spec §10 says.
8. The vignette goes in `vignettes/articles/cdisc.Rmd` (that is where this repo's articles live), so
   `R CMD check` does not need haven.
9. `sv_codebook()` gets `cdisc = "auto"` with the same values. The gadget and the module pass the canvas's own
   choice (a named vector of the tagged cards' domains, or `FALSE`).
10. Override names that match no table give one warning listing them:
    `` `cdisc` names no table: <names>. ``
11. `sv_sync_cards()` compares cards with `cdisc` removed on both sides, so a reactive that re-fires with the
    same data does not replace every card.

## Review Focus

1. **Labels lost by row capping or subsetting:** a labelled data frame larger than `max_rows` still shows its
   `th` titles and label row in the widget. Test in Task 4.
2. **Messy `DOMAIN` values** (factor, lower case `"ae"`, padded `" AE "`, some `NA`): these are compared after
   `toupper(trimws())` with `NA` dropped, and still give AE. A column that is all `NA` falls through to the
   next rule. Test in Task 2.
3. **Zero-row CDISC tables** (an empty AE shell): no error; the name or prefix rule still tags it. Test in
   Task 2 (in memory) and Task 3 (lazy).
4. **A reactive `cards =` re-firing with identical data** must not send `sideview_card_replace` for every card
   just because the tags were resolved. Test in Task 5.
5. **Evidence with one line** must reach the browser as a JSON array, not a scalar (`auto_unbox`). Test in
   Task 4. The JS also accepts a string, so it degrades safely.

---

### Task 1: Catalogue

**Files:**
- Create: `inst/extdata/cdisc_catalogue.csv`, `R/cdisc.R`, `tests/testthat/test-cdisc.R`

**Interfaces:**
- Produces: `sv_cdisc_catalogue()` returns a data frame with character columns `name, label, class, standard,
  ig_versions, keys`. It is cached in a package-level environment (`.sv_cdisc_cache`).

Rows to enter, with labels and versions hand-checked against each IG's section list:
- **SDTM** (`ig_versions` from 3.2/3.3/3.4):
  - Special-Purpose: DM CO SE SV SM.
  - Interventions: AG CM EC EX ML PR SU.
  - Events: AE CE DS DV HO MH.
  - Findings: CV DA DD EG FT IE IS LB MB MI MK MS NV OE PC PE PP QS RE RP RS SC SS TR TU UR VS.
  - Findings About: FA SR.
  - Trial Design: TA TD TE TI TM TS TV.
  - Relationship: RELREC RELSPEC SUPPQUAL.
  - Study Reference: OI.
- **SEND 3.1** (`ig_versions = 3.1`):
  - Special-Purpose: DM CO SE.
  - Interventions: EX.
  - Events: DS.
  - Findings: BG BW CL CV DD EG FW LB MA MI OM PC PM PP RE SC TF VS.
  - Trial Design: TA TE TS TX.
  - Relationship: POOLDEF RELREC SUPPQUAL.
- **ADaM 1.3:** ADSL (class ADSL), BDS, OCCDS, TTE (class = name).

`keys` holds the IG's natural keys, e.g. `STUDYID;USUBJID;AESEQ`; empty for the ADaM class rows.

- [ ] **Step 1: Write the failing tests** in `test-cdisc.R`:
  - `"the catalogue has the documented shape"`:
    - columns exactly `c("name","label","class","standard","ig_versions","keys")`;
    - no duplicated `paste(name, standard)`;
    - `standard %in% c("SDTM","SEND","ADaM")`;
    - `class` within the spec §4 list plus `ADSL/BDS/OCCDS/TTE`;
    - every `ig_versions` matches `^[0-9.]+(;[0-9.]+)*$`.
  - `"the catalogue knows the domains detection relies on"`: SDTM has AE, DM, LB, TS, SUPPQUAL; SEND has BW
    and TX with no SDTM row; ADaM has ADSL, BDS, OCCDS, TTE.
  - `"the catalogue is read once"`: `identical(sv_cdisc_catalogue(), sv_cdisc_catalogue())`, and with
    `local_mocked_bindings(read.csv = function(...) stop("re-read"), .package = "utils")` a second call still
    works.
- [ ] **Step 2:** Run `Rscript -e "devtools::test(filter = 'cdisc')"`. Expected: FAIL (`sv_cdisc_catalogue` not
  found).
- [ ] **Step 3:** Write the CSV and `sv_cdisc_catalogue()`. Use
  `utils::read.csv(system.file("extdata", "cdisc_catalogue.csv", package = "sideview"),
  colClasses = "character", na.strings = character())`.
- [ ] **Step 4:** Run the same command. Expected: PASS.
- [ ] **Step 5:** Commit `feat(cdisc): CDISC dataset catalogue`.

### Task 2: In-memory detection

**Files:**
- Modify: `R/cdisc.R`
- Create: `tests/testthat/helper-cdisc.R`
- Test: `tests/testthat/test-cdisc.R`

**Interfaces:**
- Consumes: `sv_cdisc_catalogue()`.
- Produces:
  - `sv_cdisc_detect(data, name, cdisc = "auto")` returns a tag or `NULL`. Here `cdisc` is per table:
    `"auto"`, `FALSE`, or one domain code (that gives `source = "user"` and skips the gate).
  - The tag is `list(domain, label, class, standard, parent, parent_card, evidence, source)`:
    - `parent` and `parent_card` are `NULL` unless set;
    - `evidence` is a character vector.
  - `sv_cdisc_check_arg(cdisc)` (internal) returns `cdisc` or stops with the Global Constraints message.
  - `sv_cdisc_suffixes` is the constant list from spec §5.1.3.
  - `sv_cdisc_fixtures()` (helper) returns a named list: `dm ae suppae labs ts xy adsl adlb adtte adae
    send_dm bw` plus negatives `mtcars iris ae_nostudy studyid_only keys_only`.

**Fixture columns** (4 subjects, `STUDYID = "SV-001"`):

| fixture | columns and notes |
|---|---|
| dm | `STUDYID DOMAIN="DM" USUBJID SUBJID AGE SEX ARM`. `label` attributes on `USUBJID` ("Unique Subject Identifier") and `AGE` ("Age"); data-frame `label` attribute "Demographics". |
| ae | `STUDYID DOMAIN="AE" USUBJID AESEQ AETERM AEDECOD AESEV AESTDTC` |
| suppae | `STUDYID RDOMAIN="AE" USUBJID IDVAR="AESEQ" IDVARVAL QNAM QLABEL QVAL` |
| labs | `STUDYID USUBJID LBSEQ LBTESTCD LBTEST LBORRES LBORRESU LBDTC`. No `DOMAIN`; named `labs`. |
| ts | `STUDYID DOMAIN="TS" TSSEQ TSPARMCD TSPARM TSVAL`. No `USUBJID`. |
| xy | `STUDYID DOMAIN="XY" USUBJID XYSEQ XYTESTCD` |
| adsl | `STUDYID USUBJID` (unique) `TRT01P TRT01A AGE SAFFL` |
| adlb | `STUDYID USUBJID PARAMCD PARAM AVAL AVISIT` |
| adtte | `STUDYID USUBJID PARAMCD PARAM AVAL CNSR` |
| adae | `STUDYID USUBJID AETERM AEDECOD TRTA` |
| send_dm | dm + `SPECIES` |
| bw | `STUDYID DOMAIN="BW" USUBJID BWSEQ BWTESTCD BWORRES` |
| ae_nostudy | ae without `STUDYID`, named `ae` |
| studyid_only | `STUDYID x` |
| keys_only | `STUDYID USUBJID VAL` |

**Evidence strings** (exact):
- Gate: `"STUDYID + USUBJID"` or `"STUDYID + trial-design DOMAIN TS"`.
- Rules, in order:
  1. `"DOMAIN column = AE"`
  2. `"table name = ae"`
  3. `"variable prefix LB (6 columns)"`
  4. `"ADaM structure BDS"`
  5. `"SUPPQUAL columns"` or `"SUPP name suppae"`
  6. `"custom domain XY"`
- Override: `"set by cdisc ="`.
- Conflict, one line per independent rule 1–3 result that differs from the winner: `"name cm disagrees with
  DOMAIN AE"`, `"prefix LB disagrees with DOMAIN AE"` (the format is `<rule> <value> disagrees with <winning
  rule> <code>`).

**Behaviour:**
- Rule 1 lookups use the SDTM row when one exists, otherwise the SEND row, so BW gives `standard = "SEND"`.
- The name rule upper-cases the name and drops a file extension (`ae.xpt` → `AE`).
- `label` is the data frame's `label` attribute when it is one string, otherwise the catalogue label.

- [ ] **Step 1: Write the failing tests** (each its own `test_that`):
  - `"each fixture gets its domain"`: a table of expected `domain/class/standard`:
    - DM, AE, SUPPAE: SUPPAE is `Relationship`, `parent = "AE"`.
    - `labs`: LB by prefix.
    - TS (gate via trial-design DOMAIN), XY: `Custom`.
    - ADSL: `ADSL/ADSL/ADaM`.
    - ADLB: class `BDS`, domain `"ADLB"`.
    - ADTTE: `TTE`.
    - ADAE: `OCCDS`.
    - BW: `SEND`.
  - `"negatives get no tag"`: `expect_null()` for mtcars, iris, `ae_nostudy` named `"ae"`, `studyid_only`,
    `keys_only`.
  - `"DOMAIN beats the name and records the conflict"`:
    `sv_cdisc_detect(f$ae, "cm")$evidence` contains `"name cm disagrees with DOMAIN AE"`, and the domain is AE.
  - `"labels come from the attribute, else the catalogue"`: dm → `"Demographics"`; ae → the catalogue AE label.
  - `"messy DOMAIN values still match"`: factor `c(" ae", "AE", NA)` → AE; all-`NA` `DOMAIN` on `labs` → LB by
    prefix.
  - `"zero-row tables are tagged without error"`: `f$ae[0, ]` named `"ae"` → AE.
  - `"cdisc = FALSE and a user code"`: `FALSE` → `NULL`; `cdisc = "LB"` on `keys_only` → `domain = "LB"`,
    `source = "user"`, evidence `"set by cdisc ="`; `cdisc = "QQ"` → class `"Custom"`.
  - `"bad cdisc values are refused"`: `sv_cdisc_check_arg()` errors with `"cdisc"` for `TRUE`, `1`,
    `c("AE","LB")` (unnamed) and `NA`; it accepts `"auto"`, `FALSE` and `c(a = "AE")`.
  - `"a failing detector is silent unless debugging"`: mock an internal rule to `stop("boom")`. Without the
    option it returns `NULL`, silently (through `sv_cdisc_detect_safely()`). With
    `withr::local_options(sideview.debug = TRUE)` it gives a message matching `"boom"`.
- [ ] **Step 2:** Run the filter. Expected: FAIL.
- [ ] **Step 3:** Implement in `R/cdisc.R`:
  - `sv_cdisc_detect()`;
  - `sv_cdisc_detect_safely(data, name, cdisc = "auto")` (internal, `tryCatch` → `NULL` + debug message);
  - `sv_cdisc_check_arg()`.

  Read columns through one internal `sv_cdisc_peek(data)` returning `list(cols, domain_values, usubjid_unique)`,
  so Task 3 only swaps how it is computed. `usubjid_unique` is a function, so it is only evaluated by the ADSL
  rule.
- [ ] **Step 4:** Run the filter. Expected: PASS.
- [ ] **Step 5:** Commit `feat(cdisc): detect SDTM, SEND and ADaM tables`.

### Task 3: Lazy detection

**Files:**
- Modify: `R/cdisc.R`
- Test: `tests/testthat/test-lazy.R` (new block at the end)

**Interfaces:**
- Consumes: `sv_cdisc_peek()` from Task 2.
- Produces: `sv_cdisc_peek()` handles `sv_is_lazy_input(data)`:
  - `cols` comes from `sv_lazy_names()`;
  - `domain_values` comes from `dplyr::distinct(data, DOMAIN) |> head(2) |> collect()`, only when `DOMAIN`
    exists;
  - `usubjid_unique` comes from the count query.

  Every lazy query goes through one internal `sv_cdisc_lazy_query(tbl, kind)` (`kind` is `"domain"` or
  `"adsl"`), so tests can count calls.

- [ ] **Step 1: Write the failing tests** (skip without duckdb/arrow, as the file already does):
  - `"lazy CDISC tables get the in-memory tag"`: for `ae, labs, ts, adsl, adlb, bw` written to duckdb (and to
    an Arrow Table), `sv_cdisc_detect(lazy, nm)` equals `sv_cdisc_detect(df, nm)` (`expect_equal`).
  - `"lazy detection runs at most two small queries"`: with a mocked `sv_cdisc_lazy_query` that counts and
    calls through:
    - adsl → `domain` 0 calls, `adsl` 1 call;
    - ae → `domain` 1 call, `adsl` 0 calls;
    - mtcars in duckdb → 0 calls.
  - `"a zero-row lazy table is tagged"`: `ae[0, ]` in duckdb, named `"ae"` → AE.
- [ ] **Step 2:** Run `devtools::test(filter = 'lazy')`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement the lazy branch. Use `isnan()`-safe expressions only; no `collect()` without
  `head()`.
- [ ] **Step 4:** Run the lazy and cdisc filters. Expected: PASS.
- [ ] **Step 5:** Commit `feat(cdisc): detect lazy arrow and duckdb tables`.

### Task 4: Canvas resolve, finalize and wiring

**Files:**
- Modify: `R/cdisc.R`, `R/normalize.R` (`new_sideview_card`), `R/card_store.R` (`sv_card_payload`),
  `R/sideview.R`, `R/widget.R`
- Test: `tests/testthat/test-cdisc.R`, `tests/testthat/test-widget.R`

**Interfaces:**
- Consumes: `sv_cdisc_detect_safely()`, `sv_cdisc_check_arg()`.
- Produces:
  - `new_sideview_card()` sets `card$cdisc <- sv_cdisc_detect_safely(source %||% data, name)` for grid cards,
    and keeps the label attributes it saw as `card$col_labels` (a named list) before any capping.
  - `sv_cdisc_resolve(cards)` returns cards with SEND/SDTM and `parent_card` adjusted. SEND-only codes are
    derived from the catalogue, not hard-coded.
  - `sv_cdisc_finalize(cards, cdisc)` returns cards (it applies `FALSE`/overrides with Ruling 10's warning,
    then resolves).
  - `sv_cdisc_tag_diff(old, new)` returns a named list `card_id -> tag | NULL` of the changed tags (used in
    Task 5).
  - New argument `cdisc = "auto"` after `state` in `sideview()`, `sideview_widget()` and `save_sideview()`.
  - `sv_card_payload()` emits `cdisc` with `evidence` as a list, and `col_labels` from `card$col_labels` when
    the data has none.

- [ ] **Step 1: Write the failing tests:**
  - `"a SEND-only domain flips shared domains to SEND"`: `finalize(list(dm, bw))` gives DM `standard = "SEND"`
    with the SEND catalogue label.
  - `"SPECIES flips DM to SEND"`: `send_dm` + `ae` → both SEND.
  - `"without SEND evidence domains stay SDTM"`: `dm + ae` → SDTM.
  - `"SUPP links to its parent card"`: `ae + suppae` → the SUPPAE tag `parent_card` equals the AE card id;
    `suppae` alone → `NULL`.
  - `"cdisc = FALSE strips every tag; overrides re-tag; unknown names warn"`:
    `expect_warning(finalize(cards, c(nope = "AE")), "names no table: nope")`.
  - `"only grid cards are tagged"`: an html card built from a `gt` fixture (skip if gt is missing) has a `NULL`
    `cdisc`.
  - In test-widget.R:
    - `"widget cards carry cdisc and keep labels past max_rows"`: a 20-row labelled `dm`, run through
      `sideview_widget(dm = dm, max_rows = 5)`, gives `w$x$cards[[1]]$cdisc$domain == "DM"` and
      `col_labels$USUBJID == "Unique Subject Identifier"`.
    - `"evidence is always an array"`: `jsonlite::toJSON(w$x$cards[[1]]$cdisc, auto_unbox = TRUE)` matches
      `"\"evidence\":\\["`.
    - `"cdisc is checked and passed through save_sideview"`: `sideview_widget(mtcars, cdisc = TRUE)` errors
      with `"cdisc"`; `save_sideview(dm, file = tf, cdisc = FALSE)` writes no `"cdisc":{` in the HTML.
- [ ] **Step 2:** Run the cdisc and widget filters. Expected: FAIL.
- [ ] **Step 3:** Implement. `sideview()` calls `sv_cdisc_finalize(card_list, cdisc)` before `sideview_ui()`.
  `sideview_widget()` calls it after normalising and before the payload/cap loop (Ruling 4).
- [ ] **Step 4:** Run the full suite `Rscript -e "devtools::test()"`. Expected: all pass. The existing payload,
  state and widget tests must not change.
- [ ] **Step 5:** Commit `feat(cdisc): tag cards, resolve SEND and SUPP links, cdisc = argument`.

### Task 5: Module mode

**Files:**
- Modify: `R/module.R` (`sideviewServer`, `sv_proxy_add`, `sv_proxy_replace`, `sv_proxy_remove`,
  `sv_sync_cards`)
- Test: `tests/testthat/test-module.R`

**Interfaces:**
- Consumes: `sv_cdisc_finalize()`, `sv_cdisc_tag_diff()`.
- Produces:
  - `sideviewServer(id, cards = list(), state = NULL, llm_fn = NULL, cdisc = "auto")`. It keeps `ctl$cdisc`.
  - The message `sideview_cdisc_update` carries `list(tags = <named list>)` through `ctl$emit()`, sent only when
    the diff is non-empty.
  - Proxy verbs keep the store finalized (Ruling 5). `sv_sync_cards()` follows Ruling 11.

- [ ] **Step 1: Write the failing tests** (`testServer`, with session messages captured the way the existing
  module tests capture `sideview_card_add`):
  - `"adding a SEND domain updates DM's tag"`: start with `dm`, set `sideview_ready`, then
    `sv_add_card(proxy, bw, "bw")`. The result is one `sideview_cdisc_update` whose `tags` has the DM card id
    with `standard = "SEND"`, and the `sideview_card_add` payload for bw has `cdisc$standard = "SEND"`.
  - `"removing the SEND domain flips DM back"`: then `sv_remove_card(proxy, "bw")` → an update with DM
    `standard = "SDTM"`.
  - `"no update when nothing changes"`: adding `mtcars` sends no `sideview_cdisc_update`.
  - `"updates before ready are queued"`: add bw before `sideview_ready`; the update arrives after the ready
    flush, with `ns`.
  - `"a reactive re-firing with the same data replaces nothing"`: a `reactiveVal(list(dm = dm, bw = bw))` set
    again to an identical list gives no `sideview_card_replace`.
  - `"cdisc = FALSE in a module tags nothing"`.
- [ ] **Step 2:** Run `devtools::test(filter = 'module')`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the module, cdisc and card-store filters. Expected: PASS.
- [ ] **Step 5:** Commit `feat(cdisc): module tag updates`.

### Task 6: Codebook `domain` column (twin)

**Files:**
- Modify: `R/codebook.R` (`sv_codebook`, `sv_codebook_row`), `inst/www/sv-pipeline.js` (`codebookRow`,
  `CODEBOOK_FIELDS`, `CODEBOOK_TEXT`), `inst/www/sideview.js` (the codebook export at about line 4883),
  `R/app_server.R` (`codebook_export` observer)
- Test: `tests/testthat/test-codebook.R`

**Interfaces:**
- Consumes: `sv_cdisc_detect_safely()`, `sv_cdisc_check_arg()`.
- Produces:
  - `sv_codebook(..., top_n = 5L, file = NULL, progress = NULL, cdisc = "auto")`; `domain` sits between
    `table` and `column`, and is `NA` when untagged.
  - `sv_codebook_row(table, column, position, x, top_n, n_total = NULL, domain = NA_character_)`.
  - JS: `codebookRow(..., opts)` reads `opts.domain`; `'domain'` goes after `'table'` in `CODEBOOK_FIELDS` and is
    a text field.
  - The engine passes `domain: self.cardDomain(name)` (a new helper returning the tag's domain or `null`).
  - `sv_cdisc_domains(cards)` (internal) returns a named character vector of tagged cards' domains, or `FALSE`
    when the canvas was started with `cdisc = FALSE`. The `codebook_export` observer passes it.

- [ ] **Step 1: Write the failing tests:**
  - `"codebook has a domain column after table"`: `names(sv_codebook(ae = f$ae, mtcars = mtcars))[1:3] ==
    c("table","domain","column")`; the ae rows give `"AE"`, the mtcars rows `NA`.
  - `"codebook cdisc = FALSE leaves domain empty"`.
  - Update the existing byte-equal CSV test so it feeds `domain` into the JS rows. The CSV stays identical to
    `write.csv(sv_codebook(...), row.names = FALSE, na = "")`, including one tagged table.
- [ ] **Step 2:** Run the codebook filter. Expected: FAIL.
- [ ] **Step 3:** Implement both twins.
- [ ] **Step 4:** Run the codebook filter, then `node --check inst/www/sv-pipeline.js inst/www/sideview.js`.
  Expected: PASS, and no syntax errors.
- [ ] **Step 5:** Commit `feat(cdisc): domain column in the codebook (R and JS)`.

### Task 7: Badge, header titles, inspector, search and tokens

**Files:**
- Modify: `inst/www/sideview.js`, `inst/www/sideview.css`, `tests/testthat/gui-test-runner.js` (mock DOM
  fixtures, if the new DOM needs them)
- Test: `tests/testthat/test-theme.R`, `tests/testthat/test-app.R` (or wherever the gui-runner is driven)

**Interfaces:**
- Consumes: payload `cdisc`, `col_labels` (Task 4); the `sideview_cdisc_update` message (Task 5).
- Produces:
  - `cardMeta.cdisc` and `el.dataset.cdiscDomain`.
  - `SideviewEngine.prototype.renderCdiscBadge(cardMeta)` creates or updates `span.sideview-badge-cdisc.sv-cdisc-
    <sdtm|send|adam>` in the title bar after the name. Its `title` follows spec §7: `<label> · <standard>
    <class>`, then the evidence lines, then `supplements <parent>`.
  - `setCdiscTags(tags)` applies the update message (`null` removes the badge).
  - `cardDomain(name)`.
  - Every `th[data-col-name]` with a label gets `title`.
  - `searchCards()` matches the domain and the dataset label (rank 1 when it is not a name-prefix match).
  - The inspector shows the variable label under the column name and `<domain> · <dataset label>` under the
    card title.
  - Tokens are listed in Global Constraints.

- [ ] **Step 1: Write the failing tests:**
  - test-theme.R: add pairs `c("--sv-cdisc-sdtm-text","--sv-cdisc-sdtm")`, and the same for `send` and `adam`,
    to the contrast list. The existing dark-block equality test covers the new tokens once they are added to
    both blocks.
  - The gui-runner (mock DOM):
    - a card payload with `cdisc` gets a `.sideview-badge-cdisc` whose text is `AE`;
    - an `<img onerror>` label is escaped;
    - `setCdiscTags({id: null})` removes the badge;
    - `searchCards('adverse')` returns the AE card;
    - `th[data-col-name="USUBJID"]` has `title` `"Unique Subject Identifier"`.
- [ ] **Step 2:** Run `devtools::test(filter = 'theme|app')` and the gui runner. Expected: FAIL.
- [ ] **Step 3:** Implement; register `onMessage('sideview_cdisc_update', ...)` next to `sideview_toast`.
- [ ] **Step 4:** Run the same command, `node --check inst/www/sideview.js`, and the full suite. Expected: PASS.
- [ ] **Step 5:** Commit `feat(cdisc): domain badge, label titles, inspector and search`.

### Task 8: `L` label row and `view.labels_row` state

**Files:**
- Modify: `inst/www/sideview.js` (keydown handler near line 2701, `SHORTCUTS`, `getState`, `applyState`,
  VirtualTable header height), `inst/www/sideview.css`, `R/state.R` (keep `view` through
  `sv_state_json`/`sv_state_from_json`, and in the print method if it lists fields)
- Test: `tests/testthat/test-state.R`, the gui runner

**Interfaces:**
- Produces:
  - `SideviewEngine.prototype.toggleLabelsRow(show)` returns a boolean. It adds or removes
    `tr.sv-label-row` (cells truncated by CSS `text-overflow: ellipsis`, full text in `title`) in every grid
    card's `thead`, then calls `scheduleConnectorUpdate()` and re-renders the VirtualTable.
  - `getState()` adds `view: { labels_row: <bool> }`; `applyState()` applies it when present.
  - `SHORTCUTS` gets `[['L'], 'Show or hide variable labels']`.

- [ ] **Step 1: Write the failing tests:**
  - test-state.R:
    - `"labels_row survives a JSON round trip"`: `sv_state_from_json(sv_state_json(list(version = "0.3.0",
      view = list(labels_row = TRUE))))$view$labels_row` is `TRUE`.
    - `"a state without view still loads"`.
    - `"state never carries cdisc"`: a saved gadget state built from tagged cards has no `cdisc` anywhere
      (`grepl('"cdisc"', json)` is `FALSE`).
  - The gui runner:
    - `L` on the canvas toggles `.sv-label-row`;
    - `L` typed in the AI input does not;
    - `getState().view.labels_row` follows the toggle;
    - `applyState({view: {labels_row: true}})` shows the row;
    - the `?` list contains `Show or hide variable labels`.
- [ ] **Step 2:** Run the filters and the runner. Expected: FAIL.
- [ ] **Step 3:** Implement. The key test uses `ownsKeyboard()` and `!isTypingTarget(e.target)`, like the other
  single-key shortcuts.
- [ ] **Step 4:** Run the full suite and `node --check`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(cdisc): label row toggle (L) saved in workspace state`.

### Task 9: LLM schema context

**Files:**
- Modify: `R/llm.R` (`sv_build_schema_context`)
- Test: `tests/testthat/test-llm.R`

**Interfaces:**
- Produces: for a tagged card, a line `CDISC: AE (Adverse Events), SDTM Events` after the `Table:` line. Each
  labelled column line ends with ` - label: <label>`. Untagged, unlabelled cards are unchanged.

- [ ] **Step 1: Write the failing tests:**
  - `"schema context names the domain and labels"`: the context for a tagged dm card contains `"CDISC: DM"` and
    `"label: Unique Subject Identifier"`.
  - `"schema context still has no row values"`: a sentinel value placed in `dm$ARM` (e.g. `"ZZSENTINEL"`) does
    not appear, beyond what the existing `max_categories` rule already allows. If categories are listed today,
    put the sentinel in a high-cardinality column instead.
  - `"plain data frames are unchanged"`: the mtcars context is identical to its value before the change
    (snapshot the string in the test).
- [ ] **Step 2:** Run the llm filter. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the llm and copilot filters. Expected: PASS.
- [ ] **Step 5:** Commit `feat(cdisc): domain and labels in the copilot schema context`.

### Task 10: `sv_read_cdisc()`

**Files:**
- Modify: `R/cdisc.R`, `DESCRIPTION` (Suggests `haven`, `datasetjson`)
- Test: `tests/testthat/test-cdisc.R`

**Interfaces:**
- Produces: `sv_read_cdisc(path, lazy = TRUE)` returns a named list (lower-case file stems, in file order). A
  directory is listed non-recursively.

**Error and warning messages** (exact):
- Missing package: `` Reading .xpt files needs the haven package: dm.xpt, ae.xpt. ``
- An explicitly named unsupported file: `` Unsupported file type: notes.txt. ``
- An unreadable file (a warning; the file is skipped): `` Could not read bad.xpt (<condition message>); skipped. ``
- Duplicate stems: `` Two files have the stem `ae`: ae.xpt, ae.parquet. ``
- No supported files: `` No .xpt, .sas7bdat, .json or .parquet files in <path>. ``
- A missing path: `` Not found: <path>. ``

- [ ] **Step 1: Write the failing tests:**
  - `"xpt round trip keeps labels"`: `haven::write_xpt()` dm (with labels) and ae into a
    `withr::local_tempdir()`. `sv_read_cdisc(dir)` has names `c("ae","dm")`, and
    `attr(x$dm$USUBJID, "label")` is kept. `sideview_widget(x)` tags both (skip if haven is missing).
  - `"parquet is lazy by default and eager on request"`: `arrow::write_parquet(ae, ...)`. The result inherits
    `"Dataset"` by default and is a data.frame with `lazy = FALSE`. Detection gives AE either way, and
    `sv_card_payload(sv_normalize(x$ae, "ae"))$col_labels` keeps the parquet labels (spec §8).
  - `"dataset-json is read when datasetjson is installed"`: `skip_if_not_installed("datasetjson")`; write with
    `datasetjson::dataset_json()` + `write_dataset_json()`, read it back, and get domain AE.
  - `"sas7bdat goes through haven::read_sas"`:
    `local_mocked_bindings(read_sas = function(path, ...) f$ae, .package = "haven")` on an empty `ae.sas7bdat`
    file gives `x$ae` with AE detected.
  - One test per message above, using `expect_error`/`expect_warning` with the fixed text (regex-escaped). The
    missing-package case mocks `requireNamespace` through an internal `sv_has_pkg()` wrapper.
  - `"unsupported files in a directory are ignored"`: a `notes.txt` beside `ae.xpt` gives `names == "ae"`.
- [ ] **Step 2:** Run the cdisc filter. Expected: FAIL.
- [ ] **Step 3:** Implement. Reader by extension (case-insensitive):
  - `.xpt` → `haven::read_xpt()`
  - `.sas7bdat` → `haven::read_sas()`
  - `.json` → `datasetjson::read_dataset_json()`
  - `.parquet` → `arrow::open_dataset()` / `arrow::read_parquet()`
- [ ] **Step 4:** Run the cdisc filter, then `devtools::document()`. Expected: PASS, and `man/sv_read_cdisc.Rd`
  exists.
- [ ] **Step 5:** Commit `feat(cdisc): sv_read_cdisc() for xpt, sas7bdat, Dataset-JSON and parquet`.

### Task 11: Real-browser and RStudio verification

**Files:**
- Modify: `tests/testthat/test-layout-browser.R`, `MEMORY.md`

**Interfaces:**
- Consumes: everything above; the fixtures from `helper-cdisc.R`.

- [ ] **Step 1: Write the failing browser tests** (with `NOT_CRAN=true`; gadget app built from `dm, ae,
  suppae, adsl, adlb`; real input via `b$Input$dispatchMouseEvent` / `dispatchKeyEvent`):
  - `"cdisc badge sits in the title bar without overlap"`: at each of 1400×900, 1024×700 and 560×520, every
    `.sideview-badge-cdisc` rect is inside its card header and intersects no title-bar button. The existing
    chrome-overlap assertion still passes with the badges present.
  - `"labelled headers carry titles"`: `th[data-col-name="USUBJID"]` `title` is `"Unique Subject Identifier"`.
  - `"L toggles labels and splines stay on their ports"`: connect `dm.USUBJID` to `ae.USUBJID` by a real drag,
    then press `L`. `.sv-label-row` appears, and both spline ends are within 2 px of their port centres. Press
    `L` again and the row is gone; the check holds again.
- [ ] **Step 2:** Run `NOT_CRAN=true Rscript -e "devtools::test(filter = 'layout-browser')"`. Expected: the
  new tests FAIL only on anything Tasks 7–8 missed; fix them in those files.
- [ ] **Step 3:** Run the manual RStudio pass with the same five tables in `viewer = "dialog"`, `"pane"` and
  `"browser"`. Check:
  - the badge and its tooltip;
  - the `th` tooltip;
  - `L`;
  - the Ctrl+K "adverse" search;
  - the codebook's domain column;
  - the inspector labels;
  - dark theme (T).

  Record the results under a new dated MEMORY.md heading.
- [ ] **Step 4:** Run the full suite with `NOT_CRAN=true`. Expected: all pass.
- [ ] **Step 5:** Commit `test(cdisc): real-browser checks and RStudio pass`.

### Task 12: Docs and release metadata

**Files:**
- Create: `vignettes/articles/cdisc.Rmd`
- Modify: `DESCRIPTION` (Version 0.5.0), `NEWS.md`, `_pkgdown.yml` (a "CDISC" reference section with the three
  exports; the article listed), `CLAUDE.md`, `MEMORY.md`, `README.md` (one short CDISC paragraph), `docs/`
  (rebuilt site)

**CLAUDE.md additions:**
- `sideview_cdisc_update` in the custom-message list.
- `cdisc =` on the entry points.
- A "CDISC tags" bullet: they are derived in R (`R/cdisc.R`), are never saved in state, and `domain` is a
  codebook twin column.
- `L` in the keyboard list.

- [ ] **Step 1:** Write the article. It builds the synthetic study inline (copy the fixture constructors rather
  than sourcing test helpers), shows `sideview_widget()` with badges, `cdisc =` overrides, `sv_codebook()` with
  domains and `sv_read_cdisc()` with `eval = FALSE`.
- [ ] **Step 2:** Run `Rscript -e "pkgdown::check_pkgdown()"`. Expected: no missing topics.
- [ ] **Step 3:** Run `Rscript -e "devtools::check()"`. Expected: 0 errors, 0 warnings. Notes are only the
  existing ones.
- [ ] **Step 4:** Run `pkgdown::build_site()` with `RSTUDIO_PANDOC` set, then delete `docs/CLAUDE.*`,
  `docs/MEMORY.*` and their `sitemap.xml`/`search.json` entries.
- [ ] **Step 5:** Commit `docs(cdisc): article, reference index, NEWS and 0.5.0`.
