# CDISC join keys

Suggests how tagged CDISC tables join: ADaM records trace back to their
SDTM records by `STUDYID`, `USUBJID` and `<DOMAIN>SEQ`; subject-level
tables join to the demographics hub (DM, or ADSL for ADaM tables) by
`STUDYID` and `USUBJID`; visit-level tables join to SV by the subject
key and `VISITNUM`. Column names match whatever their case; each side
keeps its own spelling. Only tags and column names are read, so Arrow
and duckdb tables are not collected.

## Usage

``` r
sv_cdisc_join_keys(cards)
```

## Arguments

- cards:

  A list of `sideview_card` objects whose CDISC tags are final (the
  cards a canvas holds).

## Value

A data frame with one row per suggested pair and the columns
`from_table` and `to_table` (card names, left and right), `from_cols`
and `to_cols` (list columns of character vectors, paired by position),
`kind` (`"trace"`, `"subject"` or `"visit"`) and `reason`. It has zero
rows when fewer than two cards can take part.

## Examples

``` r
dm <- data.frame(STUDYID = "S1", DOMAIN = "DM", USUBJID = c("S1-1", "S1-2"),
                 SUBJID = c("1", "2"), AGE = c(40, 50), SEX = c("F", "M"))
ae <- data.frame(STUDYID = "S1", DOMAIN = "AE", USUBJID = c("S1-1", "S1-2"),
                 AESEQ = 1:2, AETERM = c("Headache", "Rash"),
                 AEDECOD = c("HEADACHE", "RASH"))
cards <- sideview:::sv_normalize_cards(list(dm = dm, ae = ae))
cards <- sideview:::sv_cdisc_finalize(cards)
sv_cdisc_join_keys(cards)
#>   from_table to_table        from_cols          to_cols    kind
#> 1         ae       dm STUDYID, USUBJID STUDYID, USUBJID subject
#>                                          reason
#> 1 CDISC subject key: DM has one row per subject
```
