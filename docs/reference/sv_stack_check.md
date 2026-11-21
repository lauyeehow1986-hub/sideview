# Check what stacking tables would do

Compares the columns of 2 to 8 tables and reports, column by column,
what stacking them one under another would change: types that differ
(and the type they would be cast to), values that become `NA` in a cast,
labels that differ, columns missing from some tables, and near-miss
names that differ only in case (these are never merged unless you ask
with `rename`). Nothing is rounded or truncated silently: a cast
converts a value exactly or gives `NA`, and the `NA` count says how
many.

## Usage

``` r
sv_stack_check(..., cast = NULL, rename = NULL)
```

## Arguments

- ...:

  Two or more data frames. Unnamed tables are named by their
  expressions, as
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)
  names them.

- cast:

  Optional named character vector choosing a column's type, e.g.
  `c(AGE = "chr")`. Only an offered type is allowed.

- rename:

  Optional named character vector merging a near-miss column into its
  partner, e.g. `c(Age = "AGE")`: the column `Age` is renamed `AGE` in
  every table that has it.

## Value

An object of class `sv_stack_check`: the plan (`inputs`, `id_col`,
`n_rows`, `columns`, `kept_labels`, `tz`), plus `table` (one row per
column, with its type in each input and a `Status`), `text` (summary
lines) and `code`.

## Examples

``` r
wave1 <- data.frame(AGE = c(34, 51), SEX = c("F", "M"))
wave2 <- data.frame(Age = c("29", "40"), SEX = c("M", "M"))
sv_stack_check(wave1, wave2)
#> Stack 2 tables: 4 rows, 4 columns.
#> 1 near-miss name left apart.
#>  Column wave1 wave2                      Status
#>     AGE   num     - only in wave1 (NA in wave2)
#>     SEX   chr   chr                          ok
#>     Age     -   chr   near-miss for AGE? (case)
#> dplyr::bind_rows(wave1 = wave1, wave2 = wave2, .id = "source")
sv_stack_check(wave1, wave2, rename = c(Age = "AGE"))
#> Stack 2 tables: 4 rows, 3 columns.
#> 1 column changes type.
#>  Column wave1 wave2                       Status
#>     AGE   num   chr type differs -> as.character
#>     SEX   chr   chr                           ok
#> dplyr::bind_rows(wave1 = dplyr::mutate(wave1, AGE = as.character(AGE)), wave2 = dplyr::rename(wave2, AGE = Age), .id = "source")
```
