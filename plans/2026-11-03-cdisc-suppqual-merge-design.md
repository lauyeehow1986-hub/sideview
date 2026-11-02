# sideview CDISC SUPPQUAL merge: design

- **Date:** 2026-11-03
- **Release:** sideview 0.7.0, CDISC/pharmaverse sub-project C of A-F (see `MEMORY.md`, Backlog)
- **Status:** design approved in chat, section by section; awaiting review of this written spec
- **Builds on:** `plans/2026-11-01-cdisc-awareness-design.md` (tags, SUPP detection rule 5, `parent_card`),
  `plans/2026-11-02-cdisc-join-keys-design.md` (rule rows in Auto Map, `group`/`kind`, `cdisc_notes`),
  `plans/2026-10-25-lazy-full-data-design.md` (lazy twins), `plans/2026-10-31-sideview-proxy-design.md` (module)

## 1. Problem

A SUPP-- table (`SUPPAE`, `SUPPDM`, the generic `SUPPQUAL`) holds non-standard variables as one row per
qualifier: `USUBJID`, `IDVAR` (`AESEQ`, or blank for subject level), `IDVARVAL` (the key value, always
text), `QNAM`, `QLABEL`, `QVAL`. Since 0.5.0 sideview tags it `SUPPAE` with its parent `AE`, and since 0.6.0 it
is left out of join suggestions because a plain join is wrong: it multiplies parent rows by the number of
qualifiers. The usual fix is a pivot by `QNAM` and a join on the converted `IDVARVAL`. Writing it by hand is
easy to get wrong in three places: the type of `IDVARVAL`, a QNAM that repeats for one record, and a QNAM
that clashes with a parent column. sideview should write that code and show that it is right.

## 2. What the user told us

- **Purpose:** both equally: generated code, and a visible result with a check.
- **Result view:** a merge check panel. No new card type.
- **Trigger:** a card action on the SUPP card, and Auto Map, plus a hint in the join check.
- **Code:** tidyr + dplyr.
- **A repeated QNAM for one record:** stop with an error.
- **Lazy cards:** supported. The SUPP side is collected; the parent stays lazy.
- **Approach A (approved):** the plan (key type, IDVAR levels, QNAMs) is captured when the step is added and
  written into the code, with guards in the code that stop when the data no longer fits the plan.

## 3. Goals and non-goals

**Goals**
- One click on a SUPP card adds a `supp` pipeline step to the parent's chain (one undo step) whose code
  parses and gives the same result as a hand-written merge.
- A merge check, R and JS twins plus a lazy twin, that shows counts, problems, the new columns and a preview.
- Guards in the generated code, so the code stops with a clear message instead of giving a silently wrong
  result when the data has changed.

**Non-goals**
- RELREC (later backlog item), a derived "merged" card, `metatools`/admiral helpers (sub-project D).
- Typing `QVAL` (it stays character) or carrying `QORIG`/`QEVAL` as columns.
- Validating SUPP content against an implementation guide.

## 4. User flow

### 4.1 The card button

A tagged SUPP card (class `Relationship`, domain `SUPP--` or `SUPPQUAL`) gets a **Merge into AE** button in
its header (inline SVG icon, `aria-label`, no glyph). The target list comes from the tag (§5.1).

- One target: `Merge into AE`.
- Several targets (a generic SUPPQUAL whose RDOMAIN values have cards on the canvas): `Merge into...` opens a
  small menu, one item per target (`AE`, `CM`).
- Disabled, with the reason as its title:
  - no target on the canvas: `No AE card on the canvas`;
  - a required column missing on the SUPP card: `suppae has no QNAM column` (required: `USUBJID`, `IDVAR`,
    `IDVARVAL`, `QNAM`, `QVAL`; `RDOMAIN` and `QLABEL` are optional);
  - the parent has no `USUBJID`: `ae has no USUBJID column`.
- `cdisc = FALSE`, or a cleared tag: no button.

### 4.2 Auto Map (gadget and module)

`sv_suggest_mappings()` gives one `kind = "supp"` row per SUPP card and target: `USUBJID` to `USUBJID`,
`group = "cdisc:suppae~ae"`, `confidence = 1`, reason `CDISC SUPP merge: suppae holds qualifiers for AE`. It is
drawn as a dashed `sideview-spline-suggested-cdisc` spline with the tooltip
`Suggested CDISC merge: suppae into ae (one column per QNAM). Click to merge`. A click does what the button
does; it adds no join. The widget has no Auto Map, as in 0.6.0.

### 4.3 The join check hint

`sv_cdisc_key_notes()` gives a SUPP card with its parent (either order) this note in place of
`Summarise one side first.`:

`SUPPAE has one row per qualifier: use Merge into AE on the SUPPAE card (one column per QNAM) instead of a join.`

### 4.4 Adding the step

1. The click sends `supp_check_request {id, parent, supp}` (gadget, module). The widget runs the JS check on
   its embedded rows instead.
2. The reply (`sideview_supp_check`) holds the check (§7) and its `plan`.
3. If the reply is `{error}`, a toast shows it and no step is added. Otherwise the engine adds the step
   (§6.1) to the parent's chain with `Pipeline.add` (one `change()`, one undo step), and stores the check by the
   step's key for display.
4. A step with status `error` (repeats or clashes) is still added, so the user sees the report, but its code
   would stop; the step line says so.

Pressing the button again replaces the step (same `key`, as `Pipeline.add` already does) with a fresh plan.

### 4.5 Where the check shows

- **Pipeline tab, step line:** `merge SUPPAE (3 QNAMs on AESEQ) · 14 of 14 SUPP rows matched`. Warning state:
  `· 2 orphan SUPP rows`. Error state: `· stops: AETRTEM repeats for 1 record`.
- **Discrepancy tab, top** (where the join check report sits; the latest of the two is shown):
  - counts: parent rows, SUPP rows, matched, orphaned (up to 5 samples), other-RDOMAIN rows;
  - problems: repeats, clashes, bad `IDVARVAL` values (with samples);
  - the new columns with their labels;
  - a 5-row preview of the merged parent (key columns and the new columns).
  - When the check ran on a preview (widget, or a lazy card that fell back), the panel says `Preview rows`.
- **Drift:** when a re-check (§7.4) finds that the data no longer fits the plan, the step line reads
  `Merge needs refreshing` with a **Refresh** button. Refresh re-plans and replaces the step (one undo step).

## 5. Tags and Auto Map

### 5.1 Tag fields

Rule 5 already reads the RDOMAIN values when a table has SUPPQUAL columns. The tag keeps them:

- `rdomains`: character, the distinct RDOMAIN values (empty when there is no RDOMAIN column).
- `merge_targets` (set by `sv_cdisc_resolve()`): a list of `{rdomain, card}`, one per target whose card is on
  the canvas. For a `SUPPxx` card the only target is its parent (`AE` from the name). For `SUPPQUAL` the targets
  are its `rdomains` that have a card. The parent card is the first card whose tag domain equals the RDOMAIN.

Tags are still never saved in state. The widget card meta and `sideview_cdisc_update` carry the new fields, so
module verbs (`sv_add_card()`, `sv_replace_card()`, `sv_remove_card()`) update the button.

### 5.2 `sv_suggest_mappings()`

Adds the `kind = "supp"` rows of §4.2 after the 0.6.0 rule rows. `sv_cdisc_join_keys()` is unchanged (SUPP
stays excluded from it). `cdisc = FALSE` gives no supp rows. The browser routes a `kind: "supp"` candidate to
the merge flow (§4.4) instead of `addJoinKeys`.

## 6. The step and its code

### 6.1 The step

```js
{ kind: 'supp', key: '["supp","ae","suppae"]', table: 'ae', supp: 'suppae', rdomain: 'AE',
  keys: ['STUDYID', 'USUBJID'],
  idvars: [{ idvar: 'AESEQ', type: 'double' }, { idvar: '', type: null }],
  qnams: [{ qnam: 'AETRTEM', label: 'Treatment Emergent', idvar: 'AESEQ' }] }
```

- `keys`: `STUDYID` and `USUBJID` when both tables have `STUDYID`, else `USUBJID` alone (as in 0.6.0).
- `idvars`: one entry per IDVAR level found, `''` for subject level (blank or `NA` IDVAR). `type` is the R class
  of the parent column, `integer`, `double` or `character`; a factor parent column counts as `character`.
  A parent column of any other class (logical, Date, POSIXct) makes the check an error:
  `Cannot merge on AESTDTC: its type is Date`.
- `qnams`: one entry per QNAM, in first-seen order, with its first non-blank `QLABEL` (`""` when none) and its
  IDVAR level.
- Names use each table's own spelling. Card names in code go through `ident()`.
- The merge is not row-changing (it is not in `ROW_CHANGING`), so it does not block Strict on a later join.
  `disableMissing()` disables it when the SUPP card is removed or a key or IDVAR column is gone from the parent.
  After it, the parent's known columns gain the QNAM columns.
- An older sideview skips an unknown step kind on load; the state schema stays v0.3.0.

### 6.2 The generated code (in-memory parent)

Prep statements go before the parent's chain, like `_prep` blocks. If the SUPP card has steps of its own, its
chain is composed first and `suppae_q` starts from it.

```r
suppae_q <- suppae %>%
  dplyr::filter(RDOMAIN == "AE") %>%
  dplyr::mutate(IDVAR = dplyr::coalesce(IDVAR, ""))
local({
  other <- setdiff(unique(suppae_q$IDVAR), c("AESEQ", ""))
  if (length(other)) stop("suppae has IDVAR values this merge does not handle: ",
    paste(other, collapse = ", "), ". Refresh the merge step.", call. = FALSE)
  clash <- intersect(unique(suppae_q$QNAM), names(ae))
  if (length(clash)) stop("suppae QNAMs clash with ae columns: ", paste(clash, collapse = ", "), call. = FALSE)
  both <- intersect(suppae_q$QNAM[suppae_q$IDVAR == "AESEQ"], suppae_q$QNAM[suppae_q$IDVAR == ""])
  if (length(both)) stop("suppae QNAMs are at two levels: ", paste(both, collapse = ", "), call. = FALSE)
})
suppae_aeseq <- suppae_q %>%
  dplyr::filter(IDVAR == "AESEQ") %>%
  dplyr::transmute(STUDYID, USUBJID, AESEQ = suppressWarnings(as.numeric(IDVARVAL)), QNAM, QVAL)
local({
  rep <- suppae_aeseq[duplicated(suppae_aeseq[c("STUDYID", "USUBJID", "AESEQ", "QNAM")]), ]
  if (nrow(rep)) stop("suppae repeats a QNAM for ", nrow(rep), " record(s), first: ",
    rep$USUBJID[1], " AESEQ ", rep$AESEQ[1], " ", rep$QNAM[1], call. = FALSE)
})
suppae_aeseq <- tidyr::pivot_wider(suppae_aeseq, names_from = QNAM, values_from = QVAL)
suppae_subj <- suppae_q %>%
  dplyr::filter(IDVAR == "") %>%
  dplyr::transmute(STUDYID, USUBJID, QNAM, QVAL)
# the same repeat guard as above, on STUDYID, USUBJID, QNAM
suppae_subj <- tidyr::pivot_wider(suppae_subj, names_from = QNAM, values_from = QVAL)
suppae_labels <- c(AETRTEM = "Treatment Emergent")

ae %>%
  dplyr::left_join(suppae_aeseq, by = c("STUDYID", "USUBJID", "AESEQ")) %>%
  dplyr::left_join(suppae_subj, by = c("STUDYID", "USUBJID")) %>%
  dplyr::mutate(dplyr::across(dplyr::any_of(names(suppae_labels)),
    ~ structure(.x, label = suppae_labels[[dplyr::cur_column()]])))
```

Rules:
- **Filter on RDOMAIN** only when the SUPP card has an `RDOMAIN` column.
- **Key conversion** (on the SUPP side, which is always in memory):
  - `double`: `suppressWarnings(as.numeric(IDVARVAL))`;
  - `integer`: `as.integer(dplyr::if_else(grepl("^\\s*[+-]?[0-9]+\\s*$", IDVARVAL), IDVARVAL, NA_character_))`,
    so `"1.5"` becomes `NA` instead of `1`;
  - `character`: `IDVARVAL` unchanged.
- **The repeat guard runs after conversion**, so `"01"` and `"1"` are the same record.
- **One block per IDVAR level** in the plan, named `<supp>_<idvar lower case>` and `<supp>_subj`; a level with
  no rows in the plan is not written.
- **The clash guard** compares QNAMs with every column of the parent table, keys included.
- **Labels** come from the plan and are written only where the chain is in memory (§6.3).

### 6.3 Lazy cards

- **Lazy SUPP:** `suppae_q` ends in `dplyr::collect()`, so everything after it is in memory.
- **Lazy parent (duckdb):** the joins get `copy = TRUE`.
- **Lazy parent (arrow):** the joins take `arrow::arrow_table(suppae_aeseq)`.
- **Labels:** on a lazy chain the label `mutate` goes after the chain's final `dplyr::collect()`. A lazy chain that
  is a `_prep` for another chain gets no labels.
- The guards run in memory: `names(ae)` works for duckdb and arrow tables.

## 7. The merge check

### 7.1 Functions

- **R:** `sv_supp_check(parent, supp, parent_name = "parent", supp_name = "supp", rdomain = NULL, plan = NULL,
  sample_n = 5L)` in new file `R/supp.R`, exported and documented. `rdomain` defaults to the parent's tag domain,
  then to `sub("^SUPP", "", toupper(supp_name))`.
- **JS twin:** `SideviewPipeline.suppCheck(parentRows, suppRows, opts)` in `sv-pipeline.js`, with `opts` holding
  `parentName`, `suppName`, `rdomain`, `parentTypes` (column to R class, from card meta), `plan`, `sampleN`.
- **Lazy twin:** `sv_lazy_supp_check()` in `R/lazy.R`. It collects the RDOMAIN-filtered SUPP rows. The parent
  counts come from a semi-join of the converted SUPP keys against the parent on the session connection
  (`sv_lazy_place()`), never a collect of the parent. The preview is `head(parent, 5)` merged in memory.

### 7.2 Fields

- `status`: `error` (repeats, clashes, two-level QNAMs, unsupported key type), `warning` (orphans, bad
  `IDVARVAL`, other-RDOMAIN rows in a `SUPPxx` card), `ok`.
- `plan` (§6.1, without `kind` and `key`).
- `n_parent`, `n_supp` (after the RDOMAIN filter), `n_matched`, `n_orphan`, `orphan_samples` (up to `sample_n`
  rows of `USUBJID`, `IDVAR`, `IDVARVAL`), `n_other_rdomain`.
- `repeats`: `{n, samples}`; `clashes`: character; `two_level`: character; `bad_idvarval`: `{n, samples}`.
- `columns`: `{name, label}` per QNAM; `preview`: up to 5 merged rows.
- `drift`: only with `plan =`: `{stale: TRUE|FALSE, reasons}`, e.g. `New QNAM: AEOUT`, `New IDVAR: AEGRPID`,
  `QNAM gone: AETRTEM`, `AESEQ type changed from double to character`.
- `{error}` alone when the check cannot run: `Not in suppae: QNAM`, `Not in ae: AESEQ`, `Cannot merge on ...`.

A matched SUPP row is one whose converted key finds a parent record; an orphan is one that does not (bad
`IDVARVAL` rows are orphans too). Subject-level rows match on the subject key. `n_other_rdomain` counts rows
of other RDOMAINs; it makes the status a warning only for a `SUPPxx` card, since other domains are normal in a
generic SUPPQUAL.

### 7.3 Wire

- Input `supp_check_request {id, parent, supp, plan?}`: `id` is a request id; the engine keeps the latest per
  step key and drops older replies. Clients only name cards in the store.
- Message `sideview_supp_check {id, ...check}`. In a module it carries `ns` and goes through `onMessage()`.
- The gadget and module check on full data (lazy twin for lazy cards); the widget checks its embedded rows.
- Both names are added to the CLAUDE.md inputs/messages list.

### 7.4 Re-checks

The check is requested again (with `plan =`) when the step's report is opened, after a workspace is opened,
and after a module `sv_replace_card()` of either card (which also clears the stored check). Drift only shows
the refresh state; it never edits the step by itself.

## 8. Edge cases

- **Generic SUPPQUAL with several RDOMAINs:** one merge step per chosen target; other-domain rows are counted.
- **IDVAR names a column the parent lacks** (`AEGRPID` when AE has none): check `{error}` `Not in ae: AEGRPID`.
- **A QNAM used at two IDVAR levels:** error, and the code guard stops.
- **No STUDYID** in either table: keys are `USUBJID` alone, and the code and guards use that.
- **No RDOMAIN column:** no filter; `n_other_rdomain` is `0`.
- **Two merges into one parent** (SUPPAE and a SUPPQUAL): the browser check counts the first merge's columns as
  parent columns, so a shared QNAM is a clash. The code guard checks the source table only and is noted as
  weaker in that case (dplyr would add `.x`/`.y`).
- **SEND canvas:** same rules (SUPP tags already follow the canvas standard).
- **`cdisc = FALSE`:** no button, no Auto Map supp rows, no notes. A merge step loaded from a workspace still
  composes, because the step carries its plan.
- **Widget `max_rows`:** the plan may miss IDVAR levels or QNAMs past the embedded rows; the code guards catch
  new IDVAR levels and clashes when the code runs, and the panel says `Preview rows`.
- **Lazy fallback:** a lost link or missing duckdb falls back to the preview with one `sideview_toast`, as today.

## 9. Testing

Synthetic fixtures only; `helper-cdisc.R` gains SUPP cases: AESEQ plus blank IDVAR; a character key
(`AEGRPID`); a generic SUPPQUAL with AE and CM; repeats including `"01"`/`"1"`; orphans; a clash; a two-level
QNAM; bad `IDVARVAL` (`"x"`, `"1.5"` on an integer key); a missing column; no STUDYID.

- **`tests/testthat/test-supp.R`:** every field of `sv_supp_check()`; status rules; R/JS parity on each
  fixture; counts equal dplyr; the composed code `parse()`s and its result equals a hand-built expected merge
  (values and labels); each guard's message; drift reasons.
- **`test-lazy.R`:** `sv_lazy_supp_check()` equals `sv_supp_check()` (`tolerance = 1e-12`) over duckdb and
  arrow, the parent is not collected, and the composed code on a duckdb parent and an arrow parent equals the
  in-memory result.
- **Tags:** `rdomains` and `merge_targets` for SUPPAE, SUPPQUAL with two targets, a missing parent, and module
  verbs; `sv_suggest_mappings()` supp rows and none with `cdisc = FALSE`; the join-check hint note.
- **`testServer`:** `supp_check_request` gives `sideview_supp_check`; module `ns` routing; an unknown card
  name is refused.
- **Mock DOM (`gui-test-runner.js`):** button states and titles, the menu, one undo step, re-press replaces,
  Refresh, step line states.
- **Real browser (`test-layout-browser.R`, real mouse input):** click Merge into AE; the step line and the
  Discrepancy report; accept an Auto Map supp suggestion; the header button does not overlap at 560px.
- **RStudio:** dialog, pane and external browser by hand; `devtools::test()` and `devtools::check()`; results
  recorded in `MEMORY.md`.

## 10. Files

- **New:** `R/supp.R`, `tests/testthat/test-supp.R`.
- **Modified:** `R/cdisc.R` (tag fields), `R/cdisc_keys.R` (hint note), `R/copilot.R` (supp rows),
  `R/lazy.R` (lazy twin), `R/app_server.R` (handler), `R/module.R` (re-check on replace),
  `inst/www/sv-pipeline.js` (step verbs, describe, compose prep, `suppCheck`), `inst/www/sideview.js` (button,
  menu, flow, panel), `inst/www/sideview.css`, `tests/testthat/helper-cdisc.R`, `_pkgdown.yml`
  (`sv_supp_check`), `man/`, `vignettes/articles/cdisc.Rmd` (a "Merging SUPP-- tables" section; update "What
  join keys do not do"), `README.md` (one bullet), `CLAUDE.md` (inputs/messages, tag fields), `NEWS.md` and
  `DESCRIPTION` (0.7.0), `MEMORY.md`, rebuilt `docs/`.

## 11. Risks

- **Silent truncation of keys:** handled by the integer conversion rule (§6.2) and the bad `IDVARVAL` count.
- **Plan drift:** the plan is fixed at add time; guards stop on new IDVAR levels and clashes, and new QNAMs
  simply become new columns (they are in the pivot) without labels. Re-checks show drift in the panel.
- **Large SUPP tables on a lazy card:** the filtered SUPP is collected. SUPP tables are narrow, but a very large
  one is a memory cost; the article says so.
- **Header crowding:** the button is one more header control; checked at 560px in the browser tests.
