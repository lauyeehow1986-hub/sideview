# sideview CDISC awareness: design

- **Date:** 2026-11-01
- **Release:** sideview 0.5.0, CDISC/pharmaverse sub-project A of A-F (see `MEMORY.md`, Backlog)
- **Status:** design approved in chat, section by section; awaiting review of this written spec
- **Builds on:** `plans/2026-10-25-lazy-full-data-design.md` (lazy cards), `plans/2026-10-31-sideview-proxy-design.md`
  (module mode, card store, `onMessage()` routing)

## 1. Problem

Clinical programmers, reviewers and teachers put SDTM, ADaM and SEND datasets on the canvas, but sideview
treats them as anonymous tables. Nothing says that `ae` is the Adverse Events domain, that `adlb` is a BDS
dataset or that `suppae` supplements AE, and the SAS variable labels that haven reads (`"Reported Term for
the Adverse Event"`) are carried to the browser but never shown. Users have to read study files by hand
before they can start.

## 2. What the user told us

- **Users:** all of them: programmer QC, building ADaM, reviewers/explorers and teaching.
- **Inputs:** XPT, sas7bdat, pharmaverse/admiral output, parquet/duckdb, Dataset-JSON; ARDs and TLGs too.
  Assessed applicability: XPT, sas7bdat, in-memory data, Dataset-JSON and lazy cards are in A. ARDs and
  `rtables` are sub-project E. RTF/PDF TLG files are out of scope.
- **Roadmap (approved):**
  - **A:** CDISC awareness (this spec).
  - **B:** CDISC join keys.
  - **C:** SUPPQUAL merge.
  - **D:** admiral codegen.
  - **E:** ARD/TLG cards.
  - **F:** spec/define.xml checks.
- **Activation:** automatic but conservative, `cdisc = "auto"` by default. Non-CDISC data never changes.
- **Catalogue:** SDTMIG 3.4 plus older 3.2/3.3 domains, SEND 3.1, ADaMIG 1.3.
- **Display:** domain badge in the title bar. Variable label on header hover and in the inspector. An `L`
  toggle adds a label row.
- **Reader:** `sv_read_cdisc()` turns a folder or a set of files into a named list.
- **Approach 1:** detection in R when a card is built, plus a canvas-level resolve. The JS only displays.
  No JS twin.

## 3. Goals and non-goals

**Goals**
1. Recognise SDTM, SEND and ADaM datasets (in-memory and lazy) with no false positives on ordinary data.
2. Show the domain, the dataset label and the variable labels on the canvas, in the inspector, in Ctrl+K
   search and in the codebook.
3. Read a study folder (`.xpt`, `.sas7bdat`, Dataset-JSON `.json`, `.parquet`) in one call.
4. Leave a catalogue (`keys` column) that sub-project B can use for join-key suggestions.

**Non-goals (later sub-projects or out of scope)**
- Join-key suggestions, `--SEQ`/visit checks (B). SUPPQUAL merge code (C). admiral-style code (D).
- ARD recognition, `rtables` cards (E). define.xml / `metacore` compliance (F).
- Reading RTF or PDF outputs. Any network access. Validating controlled terminology.

## 4. Catalogue

`inst/extdata/cdisc_catalogue.csv` has one row per dataset, with these columns:

| column | meaning |
|---|---|
| `name` | Dataset code: `AE`, `ADSL`, `BW`. For ADaM classes, the class name (`BDS`, `OCCDS`, `TTE`). |
| `label` | The published dataset label, e.g. `Adverse Events`. |
| `class` | SDTM: `Special-Purpose`, `Interventions`, `Events`, `Findings`, `Findings About`, `Trial Design`, `Relationship`, `Study Reference`. ADaM: `ADSL`, `BDS`, `OCCDS`, `TTE`. |
| `standard` | `SDTM`, `SEND` or `ADaM`. |
| `ig_versions` | A `;`-separated list of the versions that include the dataset, e.g. `3.2;3.3;3.4`. |
| `keys` | The natural keys, `;`-separated, e.g. `STUDYID;USUBJID;AESEQ`. Stored for B; A does not use them. |

A SEND domain whose name matches an SDTM domain has its own row with `standard = SEND`.
`sv_cdisc_catalogue()` (exported) reads the CSV once per session (it is cached) and returns it as a data frame.

## 5. Detection: `sv_cdisc_detect(data, name, cdisc = "auto")`

`data` is a data frame or a lazy table (arrow/duckdb). It returns a tag (§5.3) or `NULL`.

### 5.1 The gate (both must hold)

1. **CDISC shape:**
   - a `STUDYID` column; and
   - either a `USUBJID` column, or a `DOMAIN` value that is a trial-design domain (`TS`, `TA`, `TE`, `TV`,
     `TI`, `TX`).
2. **A domain match**, from the first rule that applies:
   1. **`DOMAIN` column:** exactly one distinct non-missing value, and that value is in the catalogue.
   2. **Table name:** the name, upper-cased and with any file extension removed, is a catalogue `name`
      (`ae`, `adsl`).
   3. **ADaM structure for an `AD*` name** (amendment 2026-11-01, see the note below): when the name matches
      `^AD[A-Z0-9]*$` (case-insensitive) and the structure test of rule 5 confirms an ADaM class, that result is
      used here, before the variable-prefix rule, so an admiral-style `ADLB` that keeps `LBTESTCD`,
      `LBSEQ` and so on is ADaM, not SDTM `LB`. The rule 1 `DOMAIN` column still goes first. The losing
      prefix result goes into `evidence` as a disagreement (`"variable prefix LB disagrees with ADaM ADLB"`).
      When the structure does not confirm, nothing happens here and the order continues unchanged.
   4. **Variable prefix:** three or more columns start with the same two-letter catalogue domain code and
      end in one of these SDTM suffixes: `SEQ`, `TERM`, `DECOD`, `TRT`, `CAT`, `SCAT`, `SEV`, `SER`,
      `STDTC`, `ENDTC`, `DTC`, `DY`, `TESTCD`, `TEST`, `ORRES`, `ORRESU`, `STRESC`, `STRESN`, `STRESU`,
      `STAT`, `BLFL`, `DOSE`, `DOSU`. For example, `AETERM` + `AESEV` + `AESTDTC` gives AE. The list is a
      constant in `R/cdisc.R`.
   5. **ADaM structure,** when the name matches `^AD[A-Z0-9]*$` (case-insensitive) or rule 2 found an ADaM name.
      The first of these that matches wins:
      - **ADSL:** one row per `USUBJID`, plus `TRT01P` or `TRT01A`.
      - **TTE:** `PARAMCD` + `PARAM` + `AVAL` + `CNSR`.
      - **BDS:** `PARAMCD` + `PARAM` + (`AVAL` or `AVALC`).
      - **OCCDS:** a `--TERM` or `--DECOD` column, and no `PARAMCD`.

      ADaM tags use `domain` = the dataset name (`ADLB`) and `class` = the matched class.
   6. **SUPPQUAL:** the name matches `^SUPP[A-Z]{2}$`, or the columns `RDOMAIN`, `IDVAR`, `IDVARVAL`,
      `QNAM` and `QVAL` are all present. The class is `Relationship` and `parent` is the single `RDOMAIN`
      value (or the name suffix).
   7. **Custom domain:** a single `DOMAIN` value matching `^[XYZ][A-Z]$` gives class `Custom`.

*Amendment, 2026-11-01 (final branch review):* real admiral ADaM datasets (`ADLB`, `ADAE`, `ADVS`, ...)
keep SDTM-prefixed columns, and with the variable-prefix rule ahead of the ADaM structure they were tagged
SDTM. The ADaM structure check (rule 5 defines the classes) now runs at position 3, ahead of the prefix
rule, for `AD*` names only, and wins when it confirms; because it only applies to `AD*` names, it is no
longer tried again after the prefix rule. A table with a different name and SDTM-prefixed columns still
follows the prefix rule.

When two rules disagree (for example `DOMAIN = "AE"` in a table named `cm`), the rule that comes first wins
and `evidence` records the conflict (`"name cm disagrees with DOMAIN AE"`).

### 5.2 Lazy tables

The checks use the schema (`colnames`) plus at most two small aggregates. Nothing is collected beyond what
these return:
- `distinct(DOMAIN) |> head(2)`.
- For the ADSL check only: `count(USUBJID) |> filter(n > 1L) |> head(1)`.

They run on the session's lazy connection from `R/lazy.R`. A lazy table must get the same tag as the same
data in memory (a parity test, as in test-lazy.R).

### 5.3 The tag (`card$cdisc`)

A named list:
- `domain`: e.g. `"AE"`.
- `label`: the data frame's `label` attribute when it is a single string, otherwise the catalogue label.
- `class`, `standard`.
- `parent`: `NULL`, except for SUPP datasets (the parent domain code).
- `parent_card`: `NULL`, or the id of the parent card once `sv_cdisc_resolve()` (§6) finds it on the canvas.
- `evidence`: a character vector, e.g. `c("DOMAIN column = AE", "STUDYID + USUBJID")`.
- `source`: `"auto"` or `"user"`.

### 5.4 Controls

`cdisc =` is accepted by `sideview()`, `sideview_widget()`, `save_sideview()`, `sideviewServer()` and
`sv_normalize()`. Its values:
- `"auto"` (the default): detect as described above.
- `FALSE`: no tags at all.
- A named character vector, e.g. `c(my_ae = "AE", lab = "ADLB")`. Each named table gets that domain with
  `source = "user"`, and the gate is skipped. Fields come from the catalogue row, or class `Custom` if the
  code is not in it. Every other table is detected as `"auto"`.

Any other value is an error naming `cdisc`.

A failure inside detection never stops card creation. The card gets no tag, and with
`getOption("sideview.debug")` set to `TRUE` the error is shown as a message.

## 6. Canvas resolve: `sv_cdisc_resolve(cards)`

This runs after all cards are built (gadget start, widget build), and again in module mode after every
`sv_add_card()`, `sv_replace_card()` or `sv_remove_card()`. It returns the cards with these tags adjusted:

- **SEND vs SDTM:**
  - A domain whose name exists in both standards becomes `standard = SEND` (with the SEND catalogue
    label and class) when either:
    - a SEND-only domain is on the canvas (catalogue rows with `standard = SEND` and no SDTM row of the same
      name, e.g. `BW`, `MI`, `TF`); or
    - the DM card has a `SPECIES` column.
  - Otherwise it stays SDTM.
- **SUPP parent link:** a SUPP tag's `parent_card` is set to the id of the card tagged with its parent domain,
  when that card is on the canvas.

## 7. Display and data flow

- **Payload.** `sv_card_payload()` adds `cdisc` next to `col_labels`; widget JSON gets it the same way.
  - Tags are derived and are **not** saved in workspace state, so the state schema version does not change.
  - The only new state field is `view.labels_row` (boolean, default `false`). `applyState()` ignores it when
    absent, so older state files load unchanged.
- **Title-bar badge.**
  - Shows the domain code next to the card name.
  - Its colour comes from the new tokens `--sv-cdisc-sdtm`, `--sv-cdisc-send` and `--sv-cdisc-adam`, plus a
    matching `-text` token. They are defined in the base block, `.sv-theme-dark` and the auto-dark media
    block (kept equal). test-theme.R checks contrast ≥ 4.5:1.
  - The `title` reads `<label> · <standard> <class>`, followed by the evidence lines and, for SUPP,
    `supplements <parent>`.
  - All text is escaped. Icons are SVG only.
- **Header labels.** Every `th` whose column has a label gets `title = <label>`. This works for any labelled
  data frame, not only CDISC.
- **`L` toggle.**
  - Adds or removes a second header row with the labels, truncated with an ellipsis (full text in `title`).
  - It only fires when `ownsKeyboard()` holds and never while typing.
  - It is listed in the `?` dialog.
  - Splines re-anchor through `scheduleConnectorUpdate()`, and the VirtualTable recomputes its header height.
- **Column inspector.** Shows the variable label under the column name, and `<domain> · <dataset label>`
  under the card title.
- **Ctrl+K.** Search also matches the domain code and the dataset label.
- **Codebook (twin rule).**
  - `sv_codebook()` and `SideviewPipeline.codebookRow()`/`codebookCsv()` add a `domain` column after `table`
    (empty when untagged).
  - The existing `label` column holds the variable label.
  - test-codebook.R's byte-equal CSV check is updated, not removed.
- **Module mode.**
  - When a resolve changes tags, R sends `sideview_cdisc_update`, shaped `{ns, tags: {<card_id>: tag | null}}`.
  - It goes through `send()` (adds `ns`), is queued until `sideview_ready`, and is handled through
    `onMessage()`.
  - The browser redraws the badges only.
  - It is added to the message list in `CLAUDE.md`.
- **LLM copilot.** The schema summary adds the domain and the dataset/variable labels. Metadata only, never
  rows.

## 8. Reader: `sv_read_cdisc(path, lazy = TRUE)`

- `path`: a directory (its supported files, not recursive) or a character vector of files.
- Files are read by extension:

  | extension | reader | package (`Suggests:`) |
  |---|---|---|
  | `.xpt` | `haven::read_xpt()` | haven |
  | `.sas7bdat` | `haven::read_sas()` | haven |
  | `.json` | `datasetjson::read_dataset_json()` | datasetjson |
  | `.parquet` | `arrow::open_dataset()` (lazy) or `arrow::read_parquet()` when `lazy = FALSE` | arrow |

- Returns a named list. Names are the lower-case file stems.
- Lazy parquet labels come from the Arrow R metadata through the `collect(head(tbl, 0))` that lazy cards
  already run.
- **Errors:**
  - A missing package raises an error naming the package and the files that need it.
  - Unsupported extensions in a directory are ignored. An explicitly named unsupported file is an error.
  - An unreadable file gives one warning and is skipped.
  - Two files with the same stem raise an error listing both.
  - No supported files raises an error.

## 9. Testing

- **Fixtures.** `tests/testthat/helper-cdisc.R` builds a synthetic study in code. No real data, no pharmaverse
  data packages.
  - SDTM: DM, AE (with `DOMAIN`), SUPPAE, LB (detected by prefix, no `DOMAIN`), TS, and a custom XY.
  - ADaM: ADSL, ADLB (BDS), ADTTE (TTE), ADAE (OCCDS).
  - SEND: DM with `SPECIES`, BW.
  - Negatives: `mtcars`, `iris`, a table named `ae` without `STUDYID`, a `STUDYID`-only table, and a table
    with `STUDYID` + `USUBJID` but no domain evidence.
- **test-cdisc.R:**
  - Each gate rule, positive and negative.
  - Precedence and conflict evidence.
  - Labels from attributes versus the catalogue.
  - `cdisc = FALSE`, named overrides, and bad values.
  - The resolve: SEND by a SEND-only domain, SEND by `SPECIES`, the SUPP parent link.
  - The catalogue's shape: required columns, no duplicate `name` + `standard`, valid classes.
  - The reader: xpt and parquet round trips written to `tempdir()` with labels; Dataset-JSON when
    `datasetjson` is installed (`skip_if_not_installed`); sas7bdat through a mocked `haven::read_sas`
    (`local_mocked_bindings`), because haven cannot write sas7bdat; every error path.
- **Lazy parity.** The duckdb and arrow fixtures get the same tags as in memory (in test-lazy.R style).
  Aggregate counts are asserted, so the "never collected" rule is checked.
- **Payload/state.** The payload carries `cdisc`. The state JSON has no `cdisc`. `labels_row` survives a round
  trip.
- **Codebook.** The `domain` column, and the byte-equal CSV still holds.
- **Module.** `testServer`: adding a SEND BW card sends `sideview_cdisc_update`, which flips DM to SEND.
- **Real browser (`test-layout-browser.R`).** Real mouse/keyboard input via chromote:
  - The badge is visible and does not intersect the title-bar buttons.
  - `th[title]` holds the label.
  - `L` toggles the label row, and spline ends stay within 2 px of the port centres.
  - No chrome overlap at 1400×900, 1024×700 and 560×520.
- **RStudio.** A manual pass in dialog, pane and browser modes with the synthetic study, recorded in
  `MEMORY.md`.
- **Generated code.** No generator changes in A, so there are no new `parse()` tests.

## 10. Files

- **New:** `R/cdisc.R` (detect, resolve, catalogue, reader), `inst/extdata/cdisc_catalogue.csv`,
  `tests/testthat/helper-cdisc.R`, `tests/testthat/test-cdisc.R`, `vignettes/cdisc.Rmd`.
- **Changed:**
  - `R/normalize.R` (`new_sideview_card()` calls detect).
  - `R/card_store.R` (payload, resolve after store changes).
  - `R/sideview.R`, `R/widget.R`, `R/module.R`, `R/app_server.R` (`cdisc =`, resolve, `sideview_cdisc_update`).
  - `R/codebook.R`, `R/copilot.R` (schema context).
  - `inst/www/sideview.js`, `inst/www/sv-pipeline.js`, `inst/www/sideview.css`.
  - `DESCRIPTION` (Suggests: datasetjson; 0.5.0), `_pkgdown.yml`, `NEWS.md`, `CLAUDE.md`, `MEMORY.md`.

## 11. Risks

- **Prefix rule false positives.** A non-CDISC table with `STUDYID`, `USUBJID` and three `XX...` columns. The
  gate needs both key columns and a catalogue code, and the negatives pin this.
- **Catalogue accuracy.** Labels and versions are typed from the published IGs. Each row is checked once by
  hand during implementation, and the catalogue-shape test catches structural slips.
- **Lazy aggregate cost.** Two `head()`-limited queries per lazy card at load. On very large remote tables
  the ADSL uniqueness query can scan, so it only runs when the name or columns already point to ADSL.
