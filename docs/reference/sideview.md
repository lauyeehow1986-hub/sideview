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
