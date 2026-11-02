# Sideview canvas as a Shiny module

`sideviewUI()` and `sideviewServer()` put an R-backed sideview canvas
into your own Shiny app (several per page). Row sorting and filtering,
lazy arrow/duckdb cards, the join check and the column inspector all run
in R, as in
[`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md).
Tables are added, replaced and removed from the server with the verbs
[`sv_add_card()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md),
[`sv_replace_card()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md)
and
[`sv_remove_card()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md);
the user's work is read back with the reactives of the returned proxy.

## Usage

``` r
sideviewUI(id, height = "600px", title = NULL, theme = "auto")

sideviewServer(id, cards = list(), state = NULL, llm_fn = NULL, cdisc = "auto")
```

## Arguments

- id:

  Module id.

- height:

  CSS height of the canvas, e.g. `"600px"`.

- title:

  Text shown in the toolbar; `NULL` (the default) shows none.

- theme:

  `"auto"`, `"light"`, `"dark"`, an
  [`sv_theme()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_theme.md)
  or a
  [`bslib::bs_theme()`](https://rstudio.github.io/bslib/reference/bs_theme.html).

- cards:

  Tables for the canvas: a (named) list as
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)
  takes, or a **reactive** returning one. A reactive is compared with
  the canvas by name each time it fires: new names are added, names that
  are gone are removed, and names still there are replaced unless the
  table is [`identical()`](https://rdrr.io/r/base/identical.html) to the
  one on the canvas.

- state:

  A saved workspace applied once after the first cards arrive: a state
  object, or its JSON text (a string whose first non-blank character is
  an opening curly brace).

- llm_fn:

  Function used for the AI bar and the copilot (as for
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)).
  With none, the server tells the canvas to hide the AI bar and the
  Copilot tab. `sideviewUI()` always renders them, so they show for a
  moment before the first message arrives.

- cdisc:

  CDISC tagging, as for
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md):
  `"auto"`, `FALSE`, or a named character vector of domain codes. Tags
  are kept current as cards come and go.

## Value

`sideviewUI()` returns a `shiny.tag.list`. `sideviewServer()` returns a
`sideview_proxy`: a list with the reactives
[`code()`](https://rstudio.github.io/htmltools/reference/builder.html)
(the composed code, `""` for none), `pipeline()` (the typed steps as a
list), `state()` (a state object, or `NULL` before the first change) and
`cards()` (the card names), plus `id`, `ns` and `session`. The values
update after the user's changes settle (300 ms).

## Details

Code execution is off in a module (Insert Script, Run & Exit, Run in R
and Run Console are not rendered, and their inputs are ignored by the
server). The composed `$code()` is built in the browser: treat it as
untrusted text to show, save or review, never
[`eval()`](https://rdrr.io/r/base/eval.html) it unattended.

## One server per id

Calling `sideviewServer()` twice with the same `id` in one session
replaces the first canvas's entry in the proxy registry:
[`sideviewProxy()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewProxy.md)
then reaches the second. Give each canvas its own id.

## See also

[`sideviewProxy()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewProxy.md),
[`sv_add_card()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md)

## Examples

``` r
if (interactive()) {
  library(shiny)
  ui <- fluidPage(sideviewUI("cv"), verbatimTextOutput("code"))
  server <- function(input, output, session) {
    px <- sideviewServer("cv", cards = list(cars = mtcars, flowers = iris))
    output$code <- renderText(px$code())
  }
  shinyApp(ui, server)
}
```
