# Codebook (Data Dictionary)

One row per column across one or more tables: type, label, missingness,
distinct values, whether the column is a unique key, range and
quartiles, mean and SD, the most common values and data-quality flags.
Write it to CSV or Excel to document a dataset or check it before
analysis.

## Usage

``` r
sv_codebook(..., top_n = 5L, file = NULL, progress = NULL)
```

## Arguments

- ...:

  Data frames, duckdb tables or Arrow tables, or one list of them. Names
  default to the argument expressions, as in
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md).
  A duckdb or Arrow table is profiled in full inside the database; it is
  never collected.

- top_n:

  Number of most common values listed in `top_values`.

- file:

  Optional path ending in `.csv` or `.xlsx` (needs the `writexl`
  package). The codebook is still returned, invisibly.

- progress:

  Optional `function(table, j, n_cols)`, called before each column is
  profiled.

## Value

A data frame with columns `table`, `column`, `position`, `class`,
`label`, `n`, `rows_profiled`, `n_missing`, `pct_missing`, `n_distinct`,
`unique_key`, `min`, `q1`, `median`, `q3`, `max` (as text, so dates
fit), `mean`, `sd`, `top_values` and `issues`. `rows_profiled` is the
number of rows the profile used; it equals `n` except for a preview of a
larger table.

## Duckdb and Arrow tables

Each column of a duckdb or Arrow table is profiled in full by duckdb,
one column at a time, so `n` and `rows_profiled` are the table's row
count, and a very wide table takes longer rather than more memory; use
`progress` to report on it. In the gadget, a card that only has a
preview (duckdb is not installed, or the link to the table was lost) is
profiled from its first 50 rows: `n` is still the true row count,
`rows_profiled` is 50, and the other columns describe those rows.

## Examples

``` r
patients <- data.frame(id = 1:4, sex = c("M", "F", "f", NA), age = c(40, 51, 62, 999))
sv_codebook(patients)
#>      table column position     class label n rows_profiled n_missing
#> 1 patients     id        1   integer  <NA> 4             4         0
#> 2 patients    sex        2 character  <NA> 4             4         1
#> 3 patients    age        3   numeric  <NA> 4             4         0
#>   pct_missing n_distinct unique_key  min    q1 median     q3  max  mean
#> 1           0          4       TRUE    1  1.75    2.5   3.25    4   2.5
#> 2          25          3      FALSE <NA>  <NA>   <NA>   <NA> <NA>    NA
#> 3           0          4       TRUE   40 48.25   56.5 296.25  999 288.0
#>          sd          top_values
#> 1   1.29099                <NA>
#> 2        NA F (1); M (1); f (1)
#> 3 474.08500                <NA>
#>                                                      issues
#> 1                                                      <NA>
#> 2 1 value differs only in case or spacing (e.g. "F" / "f").
#> 3                                                      <NA>
visits <- data.frame(id = c(1, 1, 2, 5), sbp = c(120, 135, 128, 141))
out <- tempfile(fileext = ".csv")
sv_codebook(patients, visits, file = out)
unlink(out)
```
