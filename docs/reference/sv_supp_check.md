# Check a SUPP– merge

A supplemental qualifier table (`SUPPAE`, `SUPPQUAL`, ...) holds one row
per qualifier, named by `QNAM` and tied to a parent record by `USUBJID`,
`IDVAR` and `IDVARVAL`. This checks that the rows can be folded into the
parent as one column per `QNAM`, and reports what would go wrong: rows
that match no parent record, a `QNAM` that repeats for one record, a
`QNAM` that clashes with a parent column or sits at two `IDVAR` levels,
and `IDVARVAL` values that do not convert to the type of the parent
column.

## Usage

``` r
sv_supp_check(
  parent,
  supp,
  parent_name = "parent",
  supp_name = "supp",
  rdomain = NULL,
  plan = NULL,
  sample_n = 5L
)

sv_supp_key_type(x)

sv_supp_check_json(chk)
```

## Arguments

- parent:

  The parent table: a data frame, or a sideview card (its data and CDISC
  tag are used).

- supp:

  The SUPP– table: a data frame with `USUBJID`, `IDVAR`, `IDVARVAL`,
  `QNAM` and `QVAL` (and optionally `STUDYID`, `RDOMAIN`, `QLABEL`).

- parent_name, supp_name:

  Names used in messages.

- rdomain:

  The parent domain to merge into. `NULL` uses the parent card's CDISC
  domain, else `supp_name` without its `SUPP` prefix. Rows are filtered
  on `RDOMAIN` only when `supp` has that column.

- plan:

  A plan from an earlier check. The result's `drift` says whether the
  data still fits it.

- sample_n:

  Most rows in each sample.

- x:

  A vector.

- chk:

  A result of `sv_supp_check()`.

## Value

A list with `status` (`"ok"`, `"warning"` or `"error"`), `plan`,
`n_parent`, `n_supp`, `n_matched`, `n_orphan`, `orphan_samples`,
`n_other_rdomain`, `repeats`, `clashes`, `two_level`, `bad_idvarval`,
`columns`, `preview` and `drift`; or just `list(error = )` when the
check cannot run.

`sv_supp_key_type()`: `"integer"`, `"double"`, `"character"` or `NA` (a
factor counts as character, an integer64 as double).
`sv_supp_check_json()`: the check as JSON text, one-element arrays kept
as arrays and `NA` as `null`.

## Details

`IDVARVAL` is text; it is converted to the type of the parent's `IDVAR`
column before matching (`"1.5"` does not become `1` for an integer
column). A blank or `NA` `IDVAR` means the qualifier belongs to the
subject.

## Examples

``` r
ae <- data.frame(USUBJID = c("S1", "S2"), AESEQ = 1:2, AETERM = c("Rash", "Cough"))
suppae <- data.frame(RDOMAIN = "AE", USUBJID = c("S1", "S2"), IDVAR = "AESEQ",
                     IDVARVAL = c("1", "2"), QNAM = "AETRTEM",
                     QLABEL = "Treatment Emergent", QVAL = c("Y", "N"))
chk <- sv_supp_check(ae, suppae, parent_name = "ae", supp_name = "suppae")
chk$status
#> [1] "ok"
chk$preview
#>   USUBJID AESEQ AETERM AETRTEM
#> 1      S1     1   Rash       Y
#> 2      S2     2  Cough       N
```
