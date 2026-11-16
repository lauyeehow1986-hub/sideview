# Rows That Have No Partner in a Join

Returns the rows of one table that a join check counts as unmatched, so
the number on the join step can be opened as a table. With no `rule` the
keys are compared as
[`dplyr::anti_join()`](https://dplyr.tidyverse.org/reference/filter-joins.html)
compares them (`NA` matches `NA`), and the rows are
`anti_join(x, y, by)`. With a date `rule` a missing key matches nothing
(`na_matches = "never"`); `what = "unmatched"` gives the rows whose key
has no partner at all, and `what = "outside_window"` the rows that have
a key partner but no pair the rule keeps. The two together are the rows
the join check counts as unmatched under the rule.

## Usage

``` r
sv_unmatched(
  x,
  y,
  by,
  rule = NULL,
  side = c("x", "y"),
  what = c("unmatched", "outside_window")
)
```

## Arguments

- x, y:

  Tables: data frames, or duckdb or Arrow tables (these stay lazy).

- by:

  Join columns, as in
  [`sv_join_diagnostics()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_join_diagnostics.md).

- rule:

  Optional date rule, as in
  [`sv_join_diagnostics()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_join_diagnostics.md).

- side:

  `"x"` for the rows of `x`, `"y"` for the rows of `y`.

- what:

  `"unmatched"` or `"outside_window"` (needs a `rule`).

## Value

The rows of the chosen table, with its columns and row order.

## Details

The canvas builds the same rows from its join-check button, and
generates code that rebuilds them.

## Examples

``` r
ae <- data.frame(USUBJID = c("a", "b", NA, "z"), aeterm = c("x", "y", "z", "w"))
dm <- data.frame(USUBJID = c("a", "b", "c"))
sv_unmatched(ae, dm, "USUBJID")
#>   USUBJID aeterm
#> 1    <NA>      z
#> 2       z      w
```
