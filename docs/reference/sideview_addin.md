# RStudio Addin for Sideview

Automatically discovers tabular datasets in the user's active
environment and launches the Sideview interactive multi-table canvas
gadget.

## Usage

``` r
sideview_addin(
  env = .GlobalEnv,
  viewer = sv_default_viewer(),
  run = interactive()
)
```

## Arguments

- env:

  Environment to search for tables, and where **Run in R** stores its
  result (defaults to `.GlobalEnv`, where RStudio addins run).

- viewer:

  Shiny viewer gadget display mode, or character shorthand (`"browser"`,
  `"dialog"`, or `"pane"`). Default is
  [`shiny::dialogViewer()`](https://rdrr.io/pkg/shiny/man/viewer.html)
  (width 1400, height 900) in RStudio,
  [`shiny::browserViewer()`](https://rdrr.io/pkg/shiny/man/viewer.html)
  in Positron (it has no dialog viewer; `"dialog"` there also opens the
  browser, with one message) and
  [`shiny::paneViewer()`](https://rdrr.io/pkg/shiny/man/viewer.html)
  elsewhere.

- run:

  Logical indicating whether to execute the gadget. Default
  [`interactive()`](https://rdrr.io/r/base/interactive.html).

## Value

Result of `sideview(...)`, invisibly when the gadget was run.
