# Canvas Theme

Builds a theme for
[`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)
and
[`sideview_widget()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md):
a light/dark mode plus optional overrides of the canvas design tokens
(the `--sv-*` CSS custom properties in `inst/www/sideview.css`).

## Usage

``` r
sv_theme(
  mode = c("auto", "light", "dark"),
  primary = NULL,
  font = NULL,
  font_mono = NULL,
  radius = NULL,
  ...
)
```

## Arguments

- mode:

  `"auto"` (default), `"light"` or `"dark"`. With `"auto"` the gadget
  follows the RStudio editor theme when it runs inside RStudio, and
  otherwise (and in the widget) follows the operating system's
  `prefers-color-scheme` setting. The toolbar button or the `T` key
  switches theme while the canvas is open.

- primary:

  Accent colour for buttons, selections and splines (any CSS colour that
  [`grDevices::col2rgb()`](https://rdrr.io/r/grDevices/col2rgb.html)
  understands, e.g. `"#0d6efd"`). Hover, focus and tint shades are
  derived from it.

- font, font_mono:

  Font stacks for text and code.

- radius:

  Card corner radius (CSS length, e.g. `"4px"`).

- ...:

  Further token overrides by name, e.g. `canvas_bg = "#fafafa"` sets
  `--sv-canvas-bg`. Underscores become hyphens.

## Value

An object of class `sv_theme`.

## Examples

``` r
sv_theme("dark")
#> <sv_theme> mode: dark 
sv_theme(primary = "#0f766e", radius = "4px")
#> <sv_theme> mode: auto 
#>   --sv-primary: #0f766e
#>   --sv-primary-text-light: #0e6a63
#>   --sv-primary-text-dark: #63a6a1
#>   --sv-text-inverse: #ffffff
#>   --sv-primary-hover: #0d645e
#>   --sv-primary-subtle: rgba(15, 118, 110, 0.12)
#>   --sv-primary-ring: rgba(15, 118, 110, 0.2)
#>   --sv-primary-tint: rgba(15, 118, 110, 0.12)
#>   --sv-focus-ring: #0f766e
#>   --sv-border-focus: #0f766e
#>   --sv-connector-color: #0f766e
#>   --sv-port-ring: rgba(15, 118, 110, 0.35)
#>   --sv-suggested: #0f766e
#>   --sv-suggested-hover: #0f766e
#>   --sv-suggested-glow: rgba(15, 118, 110, 0.5)
#>   --sv-radius: 4px
if (interactive()) sideview(mtcars, theme = sv_theme("dark", primary = "#f59e0b"))
```
