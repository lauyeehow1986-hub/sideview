# Save Sideview Widget to a Standalone HTML File

Exports a `sideview` htmlwidget or table objects to a self-contained
HTML file with all styles, fonts, and JavaScript embedded.

## Usage

``` r
save_sideview(
  widget,
  file,
  selfcontained = TRUE,
  title = "Sideview",
  background = "white",
  ...
)
```

## Arguments

- widget:

  A `sideview` htmlwidget object, or tabular data objects that can be
  converted to one via
  [`sideview_widget`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md).

- file:

  Path to the output HTML file (e.g. `"report.html"`).

- selfcontained:

  Logical; whether to produce a standalone HTML file with all CSS and
  JavaScript dependencies inlined. Defaults to `TRUE`.

- title:

  HTML title for the output page. Default `"Sideview"`.

- background:

  Background color for the document body. Default `"white"`.

- ...:

  Additional arguments passed to
  [`htmlwidgets::saveWidget()`](https://rdrr.io/pkg/htmlwidgets/man/saveWidget.html).

## Value

The normalized path to the saved file (invisibly).

## Examples

``` r
# \donttest{
out <- tempfile(fileext = ".html")
save_sideview(mtcars, file = out)
unlink(out)
# }
```
