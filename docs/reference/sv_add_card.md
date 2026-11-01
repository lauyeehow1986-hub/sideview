# Add, replace or remove a card, set the workspace or highlight columns

Verbs for a canvas started with
[`sideviewServer()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md).
Each updates the R side first and then tells the browser, and returns
the proxy invisibly so they pipe.

## Usage

``` r
sv_add_card(proxy, x, name)

sv_replace_card(proxy, name, x)

sv_remove_card(proxy, name)

sv_set_state(proxy, state)

sv_highlight(proxy, name, cols)
```

## Arguments

- proxy:

  A `sideview_proxy` from
  [`sideviewServer()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md)
  or
  [`sideviewProxy()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewProxy.md).

- x:

  A table: anything
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)
  accepts.

- name:

  Card name (a single string).

- state:

  A state object or its JSON text (e.g. `proxy$state()`); text is
  recognised by its leading curly brace.

- cols:

  Column names (a character vector); columns not on the card are
  ignored.

## Value

`proxy`, invisibly.

## Details

- `sv_add_card()` adds an auto-placed card; a name already on the canvas
  is an error.

- `sv_replace_card()` keeps the card's place and size and swaps its
  data. Pipeline steps that name a column the new table lacks are
  **disabled, not deleted**, and one toast says so.

- `sv_remove_card()` removes a card and disables the steps that used it.

- `sv_set_state()` replaces layout, joins and pipeline, as the Open
  button does.

- `sv_highlight()` highlights columns of a card, as a header click
  would.

## See also

[`sideviewServer()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md)

## Examples

``` r
if (interactive()) {
  # px <- sideviewProxy("review")
  # sv_replace_card(px, "labs", labs_now()); sv_highlight(px, "labs", "lab_date")
}
```
