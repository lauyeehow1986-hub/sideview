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
#> Error in sv_codebook(patients): could not find function "sv_codebook"
if (FALSE) { # \dontrun{
sv_codebook(patients, visits, file = "codebook.xlsx")
} # }
```
