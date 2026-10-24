# Codebook (Data Dictionary)

One row per column across one or more tables: type, label, missingness,
distinct values, whether the column is a unique key, range and
quartiles, mean and SD, the most common values and data-quality flags.
Write it to CSV or Excel to document a dataset or check it before
analysis.

## Usage

``` r
sv_codebook(..., top_n = 5L, file = NULL)
```

## Arguments

- ...:

  Data frames, or one list of data frames. Names default to the argument
  expressions, as in
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md).

- top_n:

  Number of most common values listed in `top_values`.

- file:

  Optional path ending in `.csv` or `.xlsx` (needs the `writexl`
  package). The codebook is still returned, invisibly.

## Value

A data frame with columns `table`, `column`, `position`, `class`,
`label`, `n`, `n_missing`, `pct_missing`, `n_distinct`, `unique_key`,
`min`, `q1`, `median`, `q3`, `max` (as text, so dates fit), `mean`,
`sd`, `top_values` and `issues`.

## Examples

``` r
patients <- data.frame(id = 1:4, sex = c("M", "F", "f", NA), age = c(40, 51, 62, 999))
sv_codebook(patients)
#>      table column position     class label n n_missing pct_missing n_distinct
#> 1 patients     id        1   integer  <NA> 4         0           0          4
#> 2 patients    sex        2 character  <NA> 4         1          25          3
#> 3 patients    age        3   numeric  <NA> 4         0           0          4
#>   unique_key  min    q1 median     q3  max  mean        sd          top_values
#> 1       TRUE    1  1.75    2.5   3.25    4   2.5   1.29099                <NA>
#> 2      FALSE <NA>  <NA>   <NA>   <NA> <NA>    NA        NA F (1); M (1); f (1)
#> 3       TRUE   40 48.25   56.5 296.25  999 288.0 474.08500                <NA>
#>                                                      issues
#> 1                                                      <NA>
#> 2 1 value differs only in case or spacing (e.g. "F" / "f").
#> 3                                                      <NA>
if (FALSE) { # \dontrun{
sv_codebook(patients, visits, file = "codebook.xlsx")
} # }
```
