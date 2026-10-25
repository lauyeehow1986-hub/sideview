# Generate tidyverse Code for Categorical Recoding and Discrepancy Crosswalks

Generate tidyverse Code for Categorical Recoding and Discrepancy
Crosswalks

## Usage

``` r
sv_code_recode(
  df_name,
  col,
  crosswalk,
  default = NULL,
  method = c("case_when", "case_match", "fct_recode"),
  pipe = FALSE,
  lazy = FALSE
)
```

## Arguments

- df_name:

  Name of the data frame.

- col:

  Column name to recode.

- crosswalk:

  Mapping between source and target values. Can be:

  - A data.frame with source values in column 1 and target values in
    column 2.

  - A named character vector (names = source values, values = target
    values).

  - A named list where names are target values and elements are vectors
    of source values.

- default:

  Fallback value for unmatched records. If NULL, omitted. If equal to
  `col`, emits unquoted column name `.default = <col>`.

- method:

  Recoding function: "case_when" (dplyr, the default), "case_match"
  (dplyr; deprecated in dplyr 1.2.0, kept for older pipelines) or
  "fct_recode" (forcats).

- pipe:

  Logical; if TRUE, uses pipe syntax `df %>% dplyr::mutate(...)`.

- lazy:

  Logical; TRUE for a table that lives in arrow or duckdb. `case_when()`
  then closes with a `TRUE ~ <col>` arm instead of `.default = <col>`,
  which arrow cannot take.

## Value

A character string of R code.
