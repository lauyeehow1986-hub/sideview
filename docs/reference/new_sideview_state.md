# Create a New Sideview Canvas State Object

Constructs a structured `sideview_state` object containing canvas
transform, card configurations, table join connections, and pipeline
script state.

## Usage

``` r
new_sideview_state(
  version = "0.3.0",
  canvas = list(zoom = 1, pan_x = 0, pan_y = 0),
  cards = list(),
  connections = list(),
  pipeline = list(code = "", active_tab = "pipeline")
)
```

## Arguments

- version:

  Character string representing state schema version (default
  `"0.3.0"`).

- canvas:

  Named list containing canvas settings: `zoom` (numeric), `pan_x`
  (numeric), `pan_y` (numeric).

- cards:

  List of card state objects (each specifying `id`, `name`, `x`, `y`,
  `width`, `height`, `minimized`, `sorts` and `filters`; a sort is
  `list(col, dir)` with `dir` `"asc"` or `"desc"`, a filter is
  `list(col, op, val)`).

- connections:

  List of join connection objects (each specifying `from_table`,
  `from_col`, `to_table`, `to_col`, `join_type`).

- pipeline:

  Named list containing `code` (character), `active_tab` (character)
  and, from version 0.3.0, the pipeline `steps` and `pipe` (`"%>%"` or
  `"|>"`). Without `steps`, `code` is restored as one custom step.

## Value

An object of class `c("sideview_state", "list")`.

## Details

The canvas writes this shape when you click **Save** in the toolbar, and
`sideview(..., state = )` / `sideview_widget(..., state = )` restore it.
Cards are matched to tables by `name`.

## Examples

``` r
st <- new_sideview_state()
print(st)
#> <sideview_state v0.2.0>
#>   Cards:       0
#>   Connections: 0
#>   Canvas:      zoom = 1, pan = (0, 0)
#>   Active Tab:  pipeline
```
