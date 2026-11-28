# Create a Standalone Sideview HTMLWidget

Normalizes passed table objects (`data.frame`, `tibble`, `table`, `gt`,
`flextable`, `htmlwidgets`) and creates an interactive 2D infinite
canvas `htmlwidget` suitable for rendering in R Markdown, Quarto, Shiny,
or exporting via
[`save_sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/save_sideview.md).

## Usage

``` r
sideview_widget(
  ...,
  width = NULL,
  height = NULL,
  elementId = NULL,
  options = list(),
  theme = "auto",
  state = NULL,
  cdisc = "auto",
  code_style = c("dplyr", "pharmaverse"),
  max_rows = 5000,
  view = getOption("sideview.view", "canvas")
)
```

## Arguments

- ...:

  Arbitrary table objects (`data.frame`, `tibble`, `table`, `gt`,
  `flextable`, `htmlwidgets`), named or unnamed, or a single list of
  tables.

- width:

  Optional widget width (e.g. `"100%"`).

- height:

  Optional widget height (e.g. `"600px"`).

- elementId:

  Optional HTML element identifier.

- options:

  Named list of canvas options (e.g. `shortcuts = FALSE` to start with
  the single-key shortcuts off, default
  `getOption("sideview.shortcuts", TRUE)`, `snapToEdge`, `access = TRUE`
  to start with the Accessible canvas switch on (default
  `getOption("sideview.access", FALSE)`), `snapThreshold`, `minScale`,
  `maxScale`).

- theme:

  Canvas theme: `"auto"` (default; follows the reader's
  `prefers-color-scheme`), `"light"`, `"dark"`, an
  [`sv_theme()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_theme.md)
  or a
  [`bslib::bs_theme()`](https://rstudio.github.io/bslib/reference/bs_theme.html).

- state:

  A saved workspace to restore (see
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)):
  a `sideview_state` or the path to a saved state file.

- cdisc:

  CDISC awareness (see
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)):
  `"auto"` (default), `FALSE`, or a named character vector of domain
  codes.

- code_style:

  Style of the generated code: `"dplyr"` (default) or `"pharmaverse"`
  (see
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)).
  A workspace state, with or without a recorded style, sets the style,
  and one without a style loads as `"dplyr"`: `code_style` is only the
  starting style when no `state` is applied.

- max_rows:

  Most rows of each data-frame table to embed in the widget (default
  5000). A longer table is cut to its first `max_rows` rows, its card
  says "First N of M rows", and one message names the tables cut. The
  widget has no R session behind it, so every row would travel in the
  HTML. Use `Inf` to embed everything. Lazy (arrow / duckdb) tables
  already carry only a preview and are not affected.

- view:

  Starting view: `"canvas"` (default) or `"list"`, a text-first list of
  the tables. Default `getOption("sideview.view", "canvas")`. A saved
  workspace (`options = list(state = )`) that records a view wins over
  this argument; a state without one leaves it as it is.

## Value

An S3 object of class `c("sideview", "htmlwidget")`.

## Examples

``` r
if (interactive()) {
  sideview_widget(mtcars, iris)
}
```
