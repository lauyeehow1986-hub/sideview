# Reach the proxy of a canvas from elsewhere in the session

Returns the same proxy `sideviewServer(id)` returned, so a canvas
started in one module can be driven from another. Inside a nested
module, `id` is relative to the calling module, as for
[`moduleServer()`](https://rdrr.io/pkg/shiny/man/moduleServer.html).

## Usage

``` r
sideviewProxy(id, session = shiny::getDefaultReactiveDomain())
```

## Arguments

- id:

  The id given to
  [`sideviewServer()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md).

- session:

  The Shiny session (default: the current one).

## Value

A `sideview_proxy`.

## Examples

``` r
if (interactive()) {
  # inside a server function:
  # sideviewProxy("review") |> sv_replace_card("labs", labs_now())
}
```
