# Sideview User Interface

Builds the complete 2D infinite canvas user interface for Sideview,
containing the draggable table cards, panzoom canvas, SVG connector
overlay, action drawer, and natural language AI bar with all HTML
dependencies attached.

## Usage

``` r
sideview_ui(
  cards = list(),
  title = "Sideview Canvas",
  gadget = FALSE,
  theme = "auto",
  state = NULL
)
```

## Arguments

- cards:

  A `sideview_card` object, a list of `sideview_card` objects, or
  tabular objects to be normalized.

- title:

  Display title for the application toolbar. Default is "Sideview
  Canvas".

- gadget:

  If `TRUE`, add Done and Cancel buttons to the toolbar (used by
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)).

- theme:

  `"auto"`, `"light"`, `"dark"`, an
  [`sv_theme()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_theme.md)
  or a
  [`bslib::bs_theme()`](https://rstudio.github.io/bslib/reference/bs_theme.html).
  See
  [`sv_theme()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_theme.md).

- state:

  Optional saved workspace to restore on load (see
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)).

## Value

A `shiny.tag.list` UI definition.
