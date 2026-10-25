# Generate tidyverse Code for Automatic Discrepancy Cleaning and Crosswalks

Inspects discrepancy detection output or pairwise column discrepancies
(exact matches, fuzzy near-matches, and missing levels), automatically
synthesizing clean recoding rules using
[`dplyr::case_when()`](https://dplyr.tidyverse.org/reference/case-and-replace-when.html).
Handles casing differences, leading/trailing whitespace discrepancies,
and fuzzy string distance variations (Levenshtein distance \<= 2).

## Usage

``` r
sv_auto_clean_rules(
  discrepancy_result,
  df_name = "df",
  col = "status",
  default = col,
  pipe = FALSE
)

sv_code_auto_clean(
  discrepancy_result,
  df_name = "df",
  col = "status",
  default = col,
  pipe = FALSE
)
```

## Arguments

- discrepancy_result:

  A discrepancy result list (such as returned by
  [`sv_detect_discrepancies()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_detect_discrepancies.md))
  or an object containing `fuzzy_matches`, `only_in_x`, `only_in_y`, and
  `exact_matches`.

- df_name:

  Name of the data frame to mutate. Defaults to `"df"`. Can be `NULL`
  for piped or standalone expressions.

- col:

  Column name being recoded. Defaults to `"status"`. If `NULL`, attempts
  to extract from `discrepancy_result$from_col` or defaults to
  `"status"`.

- default:

  Fallback value for unmatched records. If equal to `col`, preserves
  unmatched records via `.default = <col>`. Set to `NULL` to omit the
  default clause.

- pipe:

  Logical; if TRUE, emits piped syntax `df %>% dplyr::mutate(...)`.

## Value

A character string of tidyverse code, or `NULL` if no discrepancies
require cleaning.

## Examples

``` r
disc <- sv_detect_discrepancies(c("male", "Female"), c("Male", "Female"))
sv_auto_clean_rules(disc, df_name = "patients", col = "gender")
#> [1] "dplyr::mutate(patients, gender = dplyr::case_when(\n    gender == \"male\" ~ \"Male\",\n    .default = gender\n  ))"
```
