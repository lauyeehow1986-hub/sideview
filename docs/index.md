# sideview: Explore and Join Many Tables on a Zoomable Canvas

`sideview` puts **many tables side by side on a pan-and-zoom canvas**,
so you can compare them, **connect columns to build joins**, check those
joins before you run them, and take away **reproducible `tidyverse`
code**. It runs as an **RStudio gadget** or as an **htmlwidget** you can
save to HTML or embed in Quarto and R Markdown.

![The sideview canvas: four tables side by side, with a minimap, toolbar
and AI bar](reference/figures/overview.png)

**[Take the visual
tour](https://lauyeehow1986-hub.github.io/sideview/articles/tour.html)**
to see every feature in a screenshot.

![CDISC tables on the canvas: DM, AE, SUPPAE and ADSL cards with domain
badges, and a Merge into AE button on the SUPPAE
card](reference/figures/cdisc-canvas.png)

## Installation

Install from CRAN:

[`install.packages`](https://rdrr.io/r/utils/install.packages.html)`(``"sideview"``)`

Or get the newest version from r-universe (binaries for Windows and
macOS):

[`install.packages`](https://rdrr.io/r/utils/install.packages.html)`(``"sideview"``, repos ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"https://lauyeehow1986-hub.r-universe.dev"``, ``"https://cloud.r-project.org"``)``)`

Or install the development version from GitHub:

`# install.packages("remotes")`` ``remotes``::`[`install_github`](https://remotes.r-lib.org/reference/install_github.html)`(``"lauyeehow1986-hub/sideview"``)`

## Key Features

- **Many Tables at Once**: `data.frame`, `tibble`, `table`, `matrix`,
  `gt`, `flextable`, `arrow` tables and datasets, and `duckdb`
  connections each become a card on one canvas. Tables of 100,000+ rows
  scroll smoothly.
- **Canvas Navigation**: Wheel zoom (15%–350%), pan, drag and snap
  cards, **Fit** and **Arrange**, a minimap, `Ctrl+K` to find a card or
  column, and double-click a card title to zoom to it.
- **Screen Reader Ready**: a list view (`view = "list"`) and
  plain-sentence results; checked with automated WCAG tests (axe) and
  real-browser keyboard tests; the NVDA script was run once in Edge with
  NVDA 2026.2 (all 15 tasks as written; the RStudio dialog and Viewer
  pane were not covered); not yet tested by blind users. See the [screen
  reader
  article](https://lauyeehow1986-hub.github.io/sideview/articles/screen-reader.html).
- **Visual Joins**:
  - Draw a spline between two columns to generate `dplyr` joins,
    including multi-key joins.
  - [`sv_suggest_mappings()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_suggest_mappings.md)
    proposes likely keys from name, type and value overlap.
  - **Join diagnostics**
    ([`sv_join_diagnostics()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_join_diagnostics.md))
    show match rates both ways, unmatched keys, 1:1 / 1:m / m:m
    relationships, rows per join type, and NA, spacing or case problems
    in keys.
- **CDISC Awareness**: SDTM, SEND and ADaM tables get a domain badge
  (`DM`, `AE`, `ADSL`, …) and variable labels, and
  [`sv_read_cdisc()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_read_cdisc.md)
  reads `.xpt`, `.sas7bdat`, Dataset-JSON and parquet files. See the
  [CDISC
  article](https://lauyeehow1986-hub.github.io/sideview/articles/cdisc.html).
  Auto Map suggests CDISC join keys, and a **Merge into AE** button
  folds a `SUPPAE` (or `SUPPQUAL`) table into its parent with a merge
  check. It is for awareness, not conformance checking.
- **Date-Window Joins**: Click the calendar on a join step to join on a
  date rule (a window of days, between, nearest before or after,
  overlaps). The join check shows the rows the rule dropped, and
  **Strict** adds dplyr’s `relationship` and `unmatched` checks.
- **Rows Behind the Counts**: A join check or a SUPP check offers
  buttons that open the unmatched, outside-the-window, orphan or
  bad-`IDVARVAL` rows as a card of their own, with code that rebuilds
  them
  ([`sv_unmatched()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_unmatched.md),
  [`sv_supp_orphans()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_supp_orphans.md)
  in the console). Works with lazy `arrow` and `duckdb` tables and in
  the list view.
- **Stack Tables**:
  [`sv_stack_check()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_stack_check.md)
  /
  [`sv_stack()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_stack.md)
  and the Stack tab line up columns, flag type, label and near-miss
  differences, and open the stacked table as a card.
- **Compare Data Cuts**:
  [`sv_compare()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_compare.md)
  and the Compare tab count rows added, removed and changed by key, list
  type changes, and open each set of rows as a card
- **Composable Pipeline**: Every sort, filter, join, rename, recode,
  mutate, reshape or summarise becomes a step you can toggle, reorder or
  delete, with undo/redo and a `%>%` / `|>` choice. Sorts and filters
  run on the full data in R, not just the rows on screen.
- **Data Quality**:
  - Header sparklines and missingness badges.
  - Category discrepancy detection with auto-clean rules
    ([`sv_detect_discrepancies()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_detect_discrepancies.md),
    [`sv_auto_clean_rules()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_auto_clean_rules.md)).
  - A column inspector
    ([`sv_column_profile()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_column_profile.md)).
  - A data dictionary export
    ([`sv_codebook()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_codebook.md),
    CSV or XLSX).
- **Into Your Script**: Insert the generated code at the cursor in
  RStudio, send it to the console, or run it and keep the result.
- **Save and Reopen Workspaces**: Card positions, zoom, joins and the
  pipeline (`sideview(..., state = "canvas.json")`,
  [`sv_save_state()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_save_state.md),
  [`sv_load_state()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_load_state.md)).
- **AI Copilot**: Ask a local **Ollama** model or any
  **OpenAI-compatible** endpoint for tidyverse code. Only schema
  summaries are sent, **never raw rows**.
- **Themes and Keyboard**: Light, dark or automatic (follows RStudio),
  [`sv_theme()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_theme.md)
  or a
  [`bslib::bs_theme()`](https://rstudio.github.io/bslib/reference/bs_theme.html).
  Press `?` on the canvas for every shortcut.

## Quick Start

[`library`](https://rdrr.io/r/base/library.html)`(`[`sideview`](https://lauyeehow1986-hub.github.io/sideview/)`)`` `` ``patients`` ``<-`` `[`data.frame`](https://rdrr.io/r/base/data.frame.html)`(`` `` patient_id ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"P01"``, ``"P02"``, ``"P03"``, ``"P04"``)``,`` `` age ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``45``, ``52``, ``38``, ``61``)``,`` `` sex ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"Male"``, ``"Female"``, ``"M"``, ``"Fem"``)`` ``)`` ``visits`` ``<-`` `[`data.frame`](https://rdrr.io/r/base/data.frame.html)`(`` `` patient_id ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"P01"``, ``"P02"``, ``"P03"``, ``"P05"``)``,`` `` systolic_bp ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``120``, ``140``, ``115``, ``130``)`` ``)`` `` ``# 1. Open the canvas (RStudio dialog by default; also viewer = "pane" or "browser")`` ``if`` ``(`[`interactive`](https://rdrr.io/r/base/interactive.html)`(``)``)`` ``{`` `` `[`sideview`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)`(``patients``, ``visits``)`` ``}`` `` ``# 2. Check a join before you run it`` `[`sv_join_diagnostics`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_join_diagnostics.md)`(``patients``, ``visits``, by ``=`` ``"patient_id"``,`` `` x_name ``=`` ``"patients"``, y_name ``=`` ``"visits"``)`` `` ``# 3. Build a data dictionary across tables`` `[`sv_codebook`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_codebook.md)`(``patients``, ``visits``)`` `` ``# 4. Share the canvas as a standalone HTML file`` `[`save_sideview`](https://lauyeehow1986-hub.github.io/sideview/reference/save_sideview.md)`(`[`sideview_widget`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md)`(``patients``, ``visits``)``, file ``=`` ``"study_overview.html"``)`

To embed the canvas in Quarto or R Markdown, put
`sideview_widget(patients, visits, height = "650px")` in a chunk.

## In your own Shiny app

[`sideviewUI()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md)
and
[`sideviewServer()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md)
put an R-backed canvas into any Shiny app, several per page. Sorting,
filtering, lazy arrow/duckdb tables, the join check and the column
inspector run in R, as in the gadget. The server adds, replaces and
removes tables through a proxy and reads back what the user built:

[`library`](https://rdrr.io/r/base/library.html)`(`[`shiny`](https://shiny.posit.co/)`)`` `[`library`](https://rdrr.io/r/base/library.html)`(`[`sideview`](https://lauyeehow1986-hub.github.io/sideview/)`)`` `` ``ui`` ``<-`` `[`fluidPage`](https://rdrr.io/pkg/shiny/man/fluidPage.html)`(`` `` `[`actionButton`](https://rdrr.io/pkg/shiny/man/actionButton.html)`(``"refresh"``, ``"Refresh labs"``)``,`` `` `[`sideviewUI`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md)`(``"review"``, height ``=`` ``"560px"``)``,`` `` `[`verbatimTextOutput`](https://rdrr.io/pkg/shiny/man/textOutput.html)`(``"code"``)`` ``)`` ``server`` ``<-`` ``function``(``input``, ``output``, ``session``)`` ``{`` `` ``px`` ``<-`` `[`sideviewServer`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md)`(``"review"``, cards ``=`` `[`list`](https://rdrr.io/r/base/list.html)`(``visits ``=`` ``visits``, labs ``=`` ``labs_now``(``)``)``)`` `` `[`observeEvent`](https://rdrr.io/pkg/shiny/man/observeEvent.html)`(``input``$``refresh``, ``{`` `` ``px`` ``<-`` `[`sideviewProxy`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewProxy.md)`(``"review"``)`` `` `[`sv_replace_card`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md)`(``px``, ``"labs"``, ``labs_now``(``)``)`` `` `[`sv_highlight`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md)`(``px``, ``"labs"``, ``"lab_date"``)`` `` ``}``)`` `` ``output``$``code`` ``<-`` `[`renderText`](https://rdrr.io/pkg/shiny/man/renderPrint.html)`(``px``$``code``(``)``)`` ``}`` `[`shinyApp`](https://rdrr.io/pkg/shiny/man/shinyApp.html)`(``ui``, ``server``)`

A replace keeps the card where it is; steps that name a column the new
table lacks are disabled, not deleted, and one toast says so.
`px$code()`, `px$pipeline()`, `px$state()` and `px$cards()` are
reactives. Insert Script, Run & Exit, Run in R and Run Console are off
in a module, because any visitor to a deployed app could forge the code
they would run. `$code()` is composed in the browser: treat it as
untrusted text to show, save or review, and never
[`eval()`](https://rdrr.io/r/base/eval.html) it unattended. A complete
app with two canvases is in
`system.file("examples/proxy", package = "sideview")`.

`sideview` is a research and education tool for exploring and preparing
data. It is not medical device software and is not intended for clinical
decisions.
