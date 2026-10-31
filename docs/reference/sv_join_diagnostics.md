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
sv_join_diagnostics(
  x,
  y,
  by,
  sample_n = 5L,
  x_name = "x",
  y_name = "y",
  rule = NULL
)
```

## Arguments

- x, y:

  Tables to join (`x` is the left table): data frames, or duckdb tables
  and Arrow tables, which are checked in full without loading them into
  R.

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

- rule:

  Optional date rule for the join, a list with the fields of a join
  step's rule: `shape` (`"between"`, `"window"`, `"before"`, `"after"`
  or `"overlaps"`) and its columns (`xCol`, `yCol`, `yFrom`, `yTo`,
  `xFrom`, `xTo`), a window's whole-number `from` and `to` (days, -3650
  to 3650) and, for `"before"`/`"after"`, `inclusive`. The check then
  counts the rows the rule keeps, with `na_matches = "never"`: under a
  rule a missing key matches nothing. A rule that does not hold (see the
  message) is an error.

## Value

An object of class `sv_join_diagnostics`: a list with `by` (data frame
of `x`/`y` columns), `n_x`, `n_y`, `distinct_x`, `distinct_y`,
`distinct_matched`, `matched_x`, `matched_y` (rows with a partner),
`match_rate_x`, `match_rate_y`, `na_x`, `na_y` (rows with a missing
key), `dup_keys_x`, `dup_keys_y` (keys that occur more than once),
`relationship`, `rows` (named list of row counts per join type),
`unmatched_x`, `unmatched_y` (sample keys), `type_issues`, `hints` (list
of `fix`, `label`, `extra_x`, `extra_y`), `strict_args`, `warnings` and
`status` (`"ok"`, `"warn"` or `"error"`).

`strict_args` is a named list with an entry per join type (`left_join`,
`inner_join`, `right_join`, `full_join`) holding the arguments a Strict
join writes (`relationship`, and `unmatched = "error"` when every row of
the checked side has a partner); an entry is absent when Strict would
write nothing for that type (no matches; right and full joins under a
nearest-match rule). With a `rule` the result also has `rule`,
`rule_kind` (the kind of the rule's first `x` column), `rule_dropped_x`
and `rule_dropped_y` (rows that have a key partner but no pair that
satisfies the rule), and `rows$right_join` / `rows$full_join` are `NA`
under a nearest-match rule.

## Details

The canvas runs this whenever two columns are connected and shows the
result on the join step and in the Discrepancy tab.

## Duckdb and Arrow tables

When `x` or `y` is a duckdb table or an Arrow table, the check runs
inside duckdb on the whole table and only the counts come back into R;
the result equals the one for the same data held in memory. If the
tables are on two different duckdb connections the check does not run.
Arrow tables are handed to duckdb with
[`arrow::to_duckdb()`](https://arrow.apache.org/docs/r/reference/to_duckdb.html),
and a data frame is registered temporarily; both are removed afterwards.
Known differences from the in-memory check: keys of different types are
compared as text, double keys are compared exactly, and an in-memory
POSIXct key is compared as text where a database key is compared as an
instant. A date rule runs in duckdb too; its date-time columns are
compared as UTC instants (taken with `epoch_us()`, so the session
`TimeZone` and the ICU extension play no part), and a date-time window
adds whole days of 24 hours, as the in-memory check does.

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
