# Join Diagnostics

Checks a join before you run it: how many rows match in each direction,
the key relationship (one-to-one, one-to-many, many-to-many), how many
rows each join type returns, missing and duplicated keys, a sample of
unmatched keys, and fixes that would match more rows, each measured on
its own (trimming whitespace, ignoring case, dropping leading zeros).
Keys are compared the way `dplyr` joins compare them by default, so `NA`
matches `NA`.

## Usage

``` r
sv_join_diagnostics(x, y, by, sample_n = 5L, x_name = "x", y_name = "y")
```

## Arguments

- x, y:

  Data frames to join (`x` is the left table).

- by:

  Join columns: a character vector as in
  [`dplyr::left_join()`](https://dplyr.tidyverse.org/reference/mutate-joins.html),
  where names are columns of `x` and values columns of `y`
  (`c("id", "site" = "site_code")`). Unnamed entries use the same name
  on both sides.

- sample_n:

  Number of unmatched keys to list for each side.

- x_name, y_name:

  Table names used in messages.

## Value

An object of class `sv_join_diagnostics`: a list with `by` (data frame
of `x`/`y` columns), `n_x`, `n_y`, `distinct_x`, `distinct_y`,
`distinct_matched`, `matched_x`, `matched_y` (rows with a partner),
`match_rate_x`, `match_rate_y`, `na_x`, `na_y` (rows with a missing
key), `dup_keys_x`, `dup_keys_y` (keys that occur more than once),
`relationship`, `rows` (named list of row counts per join type),
`unmatched_x`, `unmatched_y` (sample keys), `type_issues`, `hints` (list
of `fix`, `label`, `extra_x`, `extra_y`), `warnings` and `status`
(`"ok"`, `"warn"` or `"error"`).

## Details

The canvas runs this whenever two columns are connected and shows the
result on the join step and in the Discrepancy tab.

## Examples

``` r
patients <- data.frame(id = c(1, 2, 3, 4), age = c(40, 51, 62, 33))
visits <- data.frame(id = c(1, 1, 2, 5), visit = 1:4)
sv_join_diagnostics(patients, visits, by = "id")
#> <sv_join_diagnostics> by id
#>   relationship: one-to-many
#>   x rows matched: 2 of 4 (50.0%)
#>   y rows matched: 3 of 4 (75.0%)
#>   rows after join: left 5 | inner 3 | full 6 | right 4 | semi 2 | anti 2 
#>   unmatched in x: 3; 4 
#>   unmatched in y: 5 
```
