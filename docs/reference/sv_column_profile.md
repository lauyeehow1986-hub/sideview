# Column Profile

Summarises one column for the column inspector: counts, missingness,
distinct values, whether it could serve as a unique key, quartiles and a
histogram for numbers, the most common values for text, and data-quality
flags (stray spaces, values that differ only in case, numbers stored as
text, empty strings, extreme values).

## Usage

``` r
sv_column_profile(x, top_n = 10L, bins = 20L, column = NULL)
```

## Arguments

- x:

  A vector (a data frame column), or a lazy table (a duckdb table or an
  Arrow table / dataset) together with `column`.

- top_n:

  Number of most common values to keep.

- bins:

  Number of equal-width histogram bins for numeric columns.

- column:

  The column to profile when `x` is a lazy table. The whole table is
  profiled by the database, and the result equals the one for the same
  column held in memory. Not used for a vector.

## Value

A list with `kind` (`"numeric"`, `"character"`, `"logical"`, `"date"`,
`"datetime"` or `"other"`), `class`, `label` (the `"label"` attribute,
if any), `n`, `n_missing`, `pct_missing`, `n_distinct` (non-missing),
`unique_key`, `stats` (named list: `min`, `q1`, `median`, `q3`, `max`,
and `mean`, `sd` for numbers), `histogram` (`breaks`, `counts`), `top`
(data frame of `value`, `n`), `n_other` (distinct values not in `top`)
and `issues` (character).

## Duckdb and Arrow tables

For a duckdb table or an Arrow table, give the table as `x` and the
column name as `column`. The database profiles the whole table in a few
queries and only the summary comes back; the result equals the one for
the same column held in memory. Arrow tables are profiled through a
private duckdb connection that is closed afterwards. duckdb
ordered-factor columns report class `"factor"`.

## Examples

``` r
sv_column_profile(c(" Male", "male", "Female", NA))
#> $kind
#> [1] "character"
#> 
#> $class
#> [1] "character"
#> 
#> $label
#> NULL
#> 
#> $n
#> [1] 4
#> 
#> $n_missing
#> [1] 1
#> 
#> $pct_missing
#> [1] 0.25
#> 
#> $n_distinct
#> [1] 3
#> 
#> $unique_key
#> [1] FALSE
#> 
#> $stats
#> NULL
#> 
#> $histogram
#> NULL
#> 
#> $top
#>    value n
#> 1   Male 1
#> 2 Female 1
#> 3   male 1
#> 
#> $n_other
#> [1] 0
#> 
#> $issues
#> [1] "1 value has leading or trailing spaces."                             
#> [2] "1 value differs only in case or spacing (e.g. \" Male\" / \"male\")."
#> 
sv_column_profile(c(54, 61, 47, 999, NA))$issues
#> character(0)
```
