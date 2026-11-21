# Stack tables

Puts 2 to 8 tables one under another, with `bind_rows()` and the type
decisions of
[`sv_stack_check()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_stack_check.md):
a column whose type differs is cast to the type the check shows (or the
one you chose), a value that cannot be cast becomes `NA`, and nothing is
rounded silently. A column `source` (or `source_2`, ... when taken)
holds each row's table name. Columns appear in order of first
appearance; labels are kept (the first table's label for a column, else
the first label met).

## Usage

``` r
sv_stack(..., check = NULL)
```

## Arguments

- ...:

  Two or more data frames, named or not (an unnamed table is named by
  its expression).

- check:

  A
  [`sv_stack_check()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_stack_check.md)
  made for the same tables, holding the fixes (casts and renames) to
  apply. When `NULL`, the check is made with no fixes.

## Value

A data frame with exactly the sum of the inputs' rows.

## Examples

``` r
wave1 <- data.frame(AGE = c(34, 51), SEX = c("F", "M"))
wave2 <- data.frame(AGE = c("29", "40"), SEX = c("M", "M"))
sv_stack(wave1, wave2)
#>   source AGE SEX
#> 1  wave1  34   F
#> 2  wave1  51   M
#> 3  wave2  29   M
#> 4  wave2  40   M
```
