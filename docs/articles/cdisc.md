# CDISC datasets

sideview recognises tables that look like **SDTM**, **SEND** or **ADaM**
datasets and marks them with a badge. This is for awareness: it helps
you see what each card is. It does not check a dataset against an
implementation guide, and a table that does not look like CDISC data is
left alone.

Everything below uses a small synthetic study built in the page (no real
patients).

## A synthetic study

`usub`` ``<-`` `[`paste0`](https://rdrr.io/r/base/paste.html)`(``"SV-001-"``, `[`sprintf`](https://rdrr.io/r/base/sprintf.html)`(``"%03d"``, ``1``:``4``)``)`` ``sid`` ``<-`` ``"SV-001"`` `` ``dm`` ``<-`` `[`data.frame`](https://rdrr.io/r/base/data.frame.html)`(``STUDYID ``=`` ``sid``, DOMAIN ``=`` ``"DM"``, USUBJID ``=`` ``usub``, SUBJID ``=`` `[`sprintf`](https://rdrr.io/r/base/sprintf.html)`(``"%03d"``, ``1``:``4``)``,`` `` AGE ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``34``, ``51``, ``62``, ``45``)``, SEX ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"F"``, ``"M"``, ``"F"``, ``"M"``)``,`` `` ARM ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"A"``, ``"B"``, ``"A"``, ``"B"``)``, stringsAsFactors ``=`` ``FALSE``)`` `[`attr`](https://rdrr.io/r/base/attr.html)`(``dm``$``USUBJID``, ``"label"``)`` ``<-`` ``"Unique Subject Identifier"`` `[`attr`](https://rdrr.io/r/base/attr.html)`(``dm``$``AGE``, ``"label"``)`` ``<-`` ``"Age"`` `[`attr`](https://rdrr.io/r/base/attr.html)`(``dm``, ``"label"``)`` ``<-`` ``"Demographics"`` `` ``ae`` ``<-`` `[`data.frame`](https://rdrr.io/r/base/data.frame.html)`(``STUDYID ``=`` ``sid``, DOMAIN ``=`` ``"AE"``, USUBJID ``=`` ``usub``, AESEQ ``=`` ``1``:``4``,`` `` AETERM ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"Headache"``, ``"Nausea"``, ``"Rash"``, ``"Cough"``)``,`` `` AESEV ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"MILD"``, ``"MODERATE"``, ``"MILD"``, ``"SEVERE"``)``,`` `` stringsAsFactors ``=`` ``FALSE``)`` `` ``suppae`` ``<-`` `[`data.frame`](https://rdrr.io/r/base/data.frame.html)`(``STUDYID ``=`` ``sid``, RDOMAIN ``=`` ``"AE"``, USUBJID ``=`` ``usub``, IDVAR ``=`` ``"AESEQ"``,`` `` IDVARVAL ``=`` `[`as.character`](https://rdrr.io/r/base/character.html)`(``1``:``4``)``, QNAM ``=`` ``"AETRTEM"``,`` `` QLABEL ``=`` ``"Treatment Emergent"``, QVAL ``=`` ``"Y"``, stringsAsFactors ``=`` ``FALSE``)`` `` ``adsl`` ``<-`` `[`data.frame`](https://rdrr.io/r/base/data.frame.html)`(``STUDYID ``=`` ``sid``, USUBJID ``=`` ``usub``, TRT01P ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"A"``, ``"B"``, ``"A"``, ``"B"``)``,`` `` TRT01A ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"A"``, ``"B"``, ``"A"``, ``"B"``)``, AGE ``=`` ``dm``$``AGE``, SAFFL ``=`` ``"Y"``,`` `` stringsAsFactors ``=`` ``FALSE``)`

## Badges

[`sideview_widget`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md)`(``dm ``=`` ``dm``, ae ``=`` ``ae``, suppae ``=`` ``suppae``, adsl ``=`` ``adsl``)`

Each recognised card gets a badge after its name: `DM`, `AE`, `SUPPAE`
and `ADSL` here. Hover over a badge for the dataset label, the standard
and class, and the evidence used (for example “DOMAIN column = DM” or
“STUDYID + USUBJID”). `SUPPAE` also says which parent it supplements.
Column headers show a variable’s label as a tooltip, `L` shows a row of
labels under the headers (it is saved with the workspace, as
`view.labels_row`), and `Ctrl+K` finds a card by its domain or dataset
label.

The tags are worked out in R when the canvas is built. They are never
saved in a workspace file; they are worked out again when it is opened.

## Overrides with `cdisc =`

`cdisc` is `"auto"` by default. Turn it off with `FALSE`, or name the
domain of a table that sideview cannot tell on its own:

[`sideview_widget`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md)`(``my_events ``=`` ``ae``, cdisc ``=`` ``FALSE``)`` `[`sideview_widget`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md)`(``my_events ``=`` ``ae``[``, ``-``2``]``, cdisc ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``my_events ``=`` ``"AE"``)``)`

The same argument is on
[`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md),
[`save_sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/save_sideview.md),
[`sideviewServer()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md)
and
[`sv_codebook()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_codebook.md).
In a Shiny module the badges follow
[`sv_add_card()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md),
[`sv_replace_card()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md)
and
[`sv_remove_card()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md).

## Domains in the codebook

[`sv_codebook()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_codebook.md)
gets a `domain` column, and the widget’s CSV download matches it.

`cb`` ``<-`` `[`sv_codebook`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_codebook.md)`(``dm ``=`` ``dm``, ae ``=`` ``ae``, adsl ``=`` ``adsl``)`` `[`unique`](https://rdrr.io/r/base/unique.html)`(``cb``[``, `[`c`](https://rdrr.io/r/base/c.html)`(``"table"``, ``"domain"``)``]``)`` ``#> table domain`` ``#> 1 dm DM`` ``#> 8 ae AE`` ``#> 14 adsl ADSL`

With `cdisc = FALSE` the column is `NA`.

## The catalogue

`cdisc_cat`` ``<-`` `[`sv_cdisc_catalogue`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_cdisc_catalogue.md)`(``)`` `[`head`](https://rdrr.io/r/utils/head.html)`(``cdisc_cat``[``, ``1``:`[`min`](https://rdrr.io/r/base/Extremes.html)`(``5``, `[`ncol`](https://rdrr.io/r/base/nrow.html)`(``cdisc_cat``)``)``]``)`` ``#> name label class standard ig_versions`` ``#> 1 DM Demographics Special-Purpose SDTM 3.2;3.3;3.4`` ``#> 2 CO Comments Special-Purpose SDTM 3.2;3.3;3.4`` ``#> 3 SE Subject Elements Special-Purpose SDTM 3.2;3.3;3.4`` ``#> 4 SV Subject Visits Special-Purpose SDTM 3.2;3.3;3.4`` ``#> 5 SM Subject Disease Milestones Special-Purpose SDTM 3.2;3.3;3.4`` ``#> 6 AG Procedure Agents Interventions SDTM 3.2;3.3;3.4`

The catalogue lists the datasets sideview knows. Its `ig_versions`
column (implementation guide versions) is approximate. It exists so
badges can say what a table is, not to validate it.

## Reading CDISC files

[`sv_read_cdisc()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_read_cdisc.md)
reads a folder, or a set of files, of `.xpt`, `.sas7bdat`, Dataset-JSON
(`.json`) and `.parquet` into a named list, keeping variable labels.
Names are the lower-case file stems. It needs the package for each
format (haven, datasetjson, arrow), and it never uses the network.

`study`` ``<-`` `[`sv_read_cdisc`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_read_cdisc.md)`(``"study/sdtm"``)`` `[`sideview_widget`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md)`(``study``)`

Parquet files stay on disk as Arrow Datasets unless you pass
`lazy = FALSE`.

## Join keys

Tagged tables join on known keys. With the tables above on the canvas,
**Auto Map** (gadget or Shiny module) suggests them as dashed splines,
drawn as one group per join:

[`sideview`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)`(``dm ``=`` ``dm``, ae ``=`` ``ae``, adsl ``=`` ``adsl``)`

| Pair | Keys | Kind |
|----|----|----|
| `adae` to `ae` | `STUDYID`, `USUBJID`, `AESEQ` | ADaM to SDTM trace |
| `ae` to `dm`, `adlb` to `adsl` | `STUDYID`, `USUBJID` | subject level (the hub is the lookup) |
| `lb` to `sv` | `STUDYID`, `USUBJID`, `VISITNUM` | visit level |

An SDTM or SEND table links to `DM`; an ADaM table links to `ADSL` (the
other hub is used when the preferred one is not on the canvas). Hover
one spline and the whole group lights up. A click accepts all of it as
one `left_join`, and one undo takes it back. A partial key set is never
offered. Without a `STUDYID` column the subject key is `USUBJID` alone,
and the suggestion’s reason says so.

The rules are also available as a function, and
[`sv_suggest_mappings()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_suggest_mappings.md)
returns them first, with `group` and `kind` columns:

[`sv_suggest_mappings`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_suggest_mappings.md)`(`[`list`](https://rdrr.io/r/base/list.html)`(``dm ``=`` ``dm``, ae ``=`` ``ae``, adsl ``=`` ``adsl``)``)``[``, `[`c`](https://rdrr.io/r/base/c.html)`(``"from_table"``, ``"to_table"``, ``"from_col"``, ``"to_col"``, ``"kind"``)``]`` ``#> from_table to_table from_col to_col kind`` ``#> 1 ae dm STUDYID STUDYID subject`` ``#> 2 ae dm USUBJID USUBJID subject`` ``#> 3 adsl dm STUDYID STUDYID subject`` ``#> 4 adsl dm USUBJID USUBJID subject`

### Key checks

Open the join check on a join between two tagged tables and a **CDISC**
list appears below the usual warnings. It names a key the join lacks
(`Add AESEQ: the CDISC key for adae and ae is STUDYID, USUBJID, AESEQ.`),
explains a many-to-many join with no rule (two Findings tables such as
`LB` and `VS` should be filtered to one test, or summarised, first) and
warns when a natural key repeats. The notes use the catalogue and the
counts already in the check, so they cost no extra pass over the data,
and they work for arrow and duckdb cards too. They do not change what
Strict writes.

### What join keys do not do

- `SUPP--` and `RELREC` tables, and tables without `USUBJID` (`TS`,
  `TA`, `TE`), are not suggested.
- Sponsor sequence names other than `<D>SEQ` are not traced; those pairs
  get the subject rule.
- Findings with findings (`LB` with `VS`) get a note, not a suggestion.
- The widget has no Auto Map rules and no notes; they are worked out in
  R, in the gadget and in modules.
- `cdisc = FALSE` turns both off.

## What it does not do

- The `ig_versions` in the catalogue are approximate, and nothing is
  validated against an implementation guide.
- A table named `AD...` (`ADLB`, `ADAE`, `ADVS`) is tagged ADaM when its
  columns confirm an ADaM structure, even if it keeps SDTM-prefixed
  columns such as `LBTESTCD`; the tooltip records the prefix as a
  disagreement. With any other name, SDTM-prefixed columns still give an
  SDTM tag.
- Column names are matched whatever their case (`STUDYID`, `studyid`),
  but a `STUDYID` column is still required.
- `cdisc = FALSE` shows no tags, but lazy (arrow / duckdb) cards still
  run detection when they are built. A named `cdisc =` vector with
  several lazy cards gets slower with each verb.
- Dataset-JSON reading was checked against `datasetjson` 0.4.1; if a
  file’s structure differs, it is skipped with a warning.
- The Copilot gets column labels and a domain line as schema text, never
  row data.
- The label row is placed from one measurement of the header height, so
  it could sit off if a header grows taller later.
- The interface was checked in headless Chrome, not yet in RStudio’s
  dialog or Viewer pane (see the log for the release).
