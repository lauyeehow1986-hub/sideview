# Multi-Table 2D Infinite Canvas Interactive Gadget

Launches an interactive Shiny gadget containing an infinite 2D canvas
with mouse-wheel zoom, pan, draggable table cards, interactive column
mapping, discrepancy recoding, and LLM-assisted tidyverse code
generation.

## Usage

``` r
sideview(
  ...,
  title = "Sideview Canvas",
  viewer = if (requireNamespace("rstudioapi", quietly = TRUE) &&
    rstudioapi::isAvailable()) {
     shiny::dialogViewer("Sideview Canvas", width =
    1400, height = 900)
 } else {
     shiny::paneViewer(minHeight = 500)
 },
  theme = "auto",
  state = NULL,
  env = parent.frame(),
  run = interactive()
)
```

## Arguments

- ...:

  Arbitrary table objects (`data.frame`, `tibble`, `matrix`, `table`,
  `gt`, `flextable`, `htmlwidgets`), named or unnamed.

- title:

  Title for the gadget viewer.

- viewer:

  Shiny viewer gadget display mode (e.g.
  [`shiny::paneViewer()`](https://rdrr.io/pkg/shiny/man/viewer.html),
  [`shiny::dialogViewer()`](https://rdrr.io/pkg/shiny/man/viewer.html),
  [`shiny::browserViewer()`](https://rdrr.io/pkg/shiny/man/viewer.html)),
  or a character shorthand (`"browser"`, `"dialog"`, or `"pane"`).
  Default is
  [`shiny::dialogViewer()`](https://rdrr.io/pkg/shiny/man/viewer.html)
  (width 1400, height 900) when RStudio is available, otherwise
  [`shiny::paneViewer()`](https://rdrr.io/pkg/shiny/man/viewer.html).

- theme:

  Canvas theme: `"auto"` (default; follows the RStudio editor theme),
  `"light"`, `"dark"`, an
  [`sv_theme()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_theme.md)
  or a
  [`bslib::bs_theme()`](https://rstudio.github.io/bslib/reference/bs_theme.html).

- state:

  A saved workspace to restore: a `sideview_state` (see
  [`new_sideview_state()`](https://lauyeehow1986-hub.github.io/sideview/reference/new_sideview_state.md))
  or the path to a file written by the toolbar's **Save** button or
  [`sv_save_state()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_save_state.md).
  Card positions and sizes, zoom and pan, sorts, filters, joins and the
  pipeline come back; cards are matched to tables by name.

- env:

  Environment where **Run in R** evaluates the generated code and stores
  its result (as `sv_result` unless you name it). Defaults to the
  environment `sideview()` is called from, which is your workspace when
  you call it from the console.

- run:

  Logical; if `TRUE`, launches the interactive gadget via
  [`shiny::runGadget()`](https://rdrr.io/pkg/shiny/man/runGadget.html).
  If `FALSE`, returns the `shiny.appobj` definition without launching
  (useful for testing or embedding). Defaults to
  [`interactive()`](https://rdrr.io/r/base/interactive.html).

## Value

If `run = TRUE`, the generated code (invisibly) when you click **Done**,
or `NULL` after **Cancel** or closing the window. If `run = FALSE`,
returns a `shiny.appobj` with the normalized cards attached.

## Big tables (arrow and duckdb)

Arrow tables, datasets and queries and duckdb tables
([`dplyr::tbl()`](https://dplyr.tidyverse.org/reference/tbl.html)) go on
the canvas as cards that show a 50-row preview. When the duckdb, dbplyr
and DBI packages are installed, sorting, filtering, scrolling, the join
check, the column inspector and the codebook use the whole table: duckdb
runs them and only summaries and row windows come back into R. The table
is never collected. Without duckdb, or when the link to a table is lost,
the card says "First 50 of N rows" and the checks use the preview.

Generated code stays lazy and ends in one `collect()`. Known differences
from an in-memory card:

- "Contains" on a number matches its text. The grid filter drops a
  trailing `.0`, but in generated code duckdb writes a double as
  `"130.0"` where R writes `"130"`, and float noise or scientific
  notation can differ. The generated filter is a literal match,
  `stringr::str_detect(col, "<escaped literal>")`.

- POSIXct values at exactly midnight, and `-0`, can print differently.

- Join keys of different types compare as text, and double keys compare
  exactly.

- Arrow time-zone offsets are computed for 1900 to 2100; local times
  outside that range may be off. duckdb `TIMESTAMPTZ` columns show in
  UTC.

- Joining arrow with duckdb copies the arrow side into a duckdb
  temporary table
  ([`arrow::to_duckdb()`](https://arrow.apache.org/docs/r/reference/to_duckdb.html)
  then
  [`dplyr::compute()`](https://dplyr.tidyverse.org/reference/compute.html)),
  which costs memory; a data frame joined into duckdb is copied as
  `sideview_<table>`.

- duckdb 1.4.3 can crash when it scans an arrow factor column that
  contains `NA`. sideview decodes such columns itself, but generated
  code that calls
  [`arrow::to_duckdb()`](https://arrow.apache.org/docs/r/reference/to_duckdb.html)
  on one may hit it: convert the factor to character first.

If **Run in R** fails on a lazy pipeline, the message suggests moving
`collect()` above the step that needs R.

## Known differences

Date rules on joins (the calendar button on a join step) give the same
rows in R, in the saved widget and on duckdb/arrow cards, with these
exceptions:

- The saved widget drops fractions of a second from date-times, so a
  boundary that falls inside a second can differ from R.

- The generated duckdb code for a date-time window uses the session time
  zone when the ICU extension is loaded. With a non-UTC `TimeZone`
  setting, a boundary can move.

- Running the code in R on a mixed arrow/data-frame and duckdb chain may
  leave temporary `dbplyr_*` tables on your connection until it closes.

- sideview writes `na_matches = "never"` on every rule join (dplyr's
  default would match `NA` to `NA`).

## Keyboard and navigation

Single-key shortcuts work when the canvas has the keyboard and you are
not typing: `F` fit all cards, `0` reset zoom, `+`/`-` zoom, `M` show or
hide the minimap, `D` the drawer, `T` light/dark, `/` the AI prompt and
`?` the full list. `Ctrl+K` finds a card or column, `Ctrl+Z`/`Ctrl+Y`
undo and redo a pipeline step, and `Esc` cancels a connection or closes
a popover. Double-click a card title, a minimap rectangle or a search
result to zoom to that card.

## Options

- `sideview.session_grace`:

  Seconds the gadget waits after its last browser session closes before
  stopping (default `5`), so reloading the page does not end the app.

- `sideview.llm_backend`:

  `"ollama"` (default, or the `SIDEVIEW_LLM_BACKEND` variable) or
  `"openai"` for any OpenAI-compatible server.

- `sideview.llm_model`:

  Model name. Defaults to `SIDEVIEW_OLLAMA_MODEL` or `"llama3.2"` for
  Ollama, and `SIDEVIEW_OPENAI_MODEL` or `"gpt-4o-mini"` otherwise.
  [`sv_llm_models()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_llm_models.md)
  lists what is available.

- `sideview.llm_endpoint`:

  Base URL. Defaults to `OLLAMA_HOST` or `http://localhost:11434`, and
  `OPENAI_BASE_URL` or `https://api.openai.com/v1`.

- `sideview.llm_api_key`:

  API key for OpenAI-compatible servers (default: the `OPENAI_API_KEY`
  variable).

- `sideview.llm_think`:

  `TRUE` lets Ollama reasoning models "think" before answering. Default
  `FALSE`, so they answer promptly.

Only schema summaries (column names, types and simple profiles) are sent
to the model, never raw rows.

## Examples

``` r
if (interactive()) {
  sideview(mtcars, iris)
}
```
