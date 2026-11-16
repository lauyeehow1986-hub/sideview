# Rows of a SUPP Table That the Merge Check Counts as Orphans or Bad

Returns the `SUPP--` rows behind a count of
[`sv_supp_check()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_supp_check.md):
the orphan rows (`what = "orphans"`, `n_orphan`), which convert but find
no parent record, or the rows whose `IDVARVAL` does not convert to the
type of the parent column (`what = "bad_idvarval"`, `bad_idvarval$n`).
The rows are the `SUPP--` columns, in the order of the table, after the
`RDOMAIN` filter. A duckdb or Arrow parent stays lazy: only the rows of
the subjects the `SUPP--` table names are read.

## Usage

``` r
sv_supp_orphans(
  parent,
  supp,
  rdomain = NULL,
  what = c("orphans", "bad_idvarval")
)
```

## Arguments

- parent:

  The parent table: a data frame, or a duckdb or Arrow table.

- supp:

  The `SUPP--` table: a data frame, or a duckdb or Arrow table.

- rdomain:

  The parent domain, as in
  [`sv_supp_check()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_supp_check.md).
  `NULL` uses the `RDOMAIN` of the first row of an in-memory `supp`.

- what:

  `"orphans"` or `"bad_idvarval"`.

## Value

A data frame with the columns of `supp`.

## Examples

``` r
ae <- data.frame(USUBJID = c("S1", "S2"), AESEQ = 1:2)
suppae <- data.frame(RDOMAIN = "AE", USUBJID = c("S1", "S2", "S2"), IDVAR = "AESEQ",
                     IDVARVAL = c("1", "9", "x"), QNAM = "AETRTEM", QVAL = "Y")
sv_supp_orphans(ae, suppae)
#>   RDOMAIN USUBJID IDVAR IDVARVAL    QNAM QVAL
#> 1      AE      S2 AESEQ        9 AETRTEM    Y
sv_supp_orphans(ae, suppae, what = "bad_idvarval")
#>   RDOMAIN USUBJID IDVAR IDVARVAL    QNAM QVAL
#> 1      AE      S2 AESEQ        x AETRTEM    Y
```
