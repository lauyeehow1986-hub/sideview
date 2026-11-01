# CDISC dataset catalogue

The SDTM, SEND and ADaM datasets that sideview recognises, read once per
session from a file shipped with the package.

## Usage

``` r
sv_cdisc_catalogue()
```

## Value

A data frame of character columns: `name` (dataset code, or the ADaM
class name), `label` (published dataset label), `class`, `standard`
(`"SDTM"`, `"SEND"` or `"ADaM"`), `ig_versions` (`;`-separated
implementation guide versions) and `keys` (`;`-separated natural keys).

## Examples

``` r
head(sv_cdisc_catalogue())
#>   name                      label           class standard ig_versions
#> 1   DM               Demographics Special-Purpose     SDTM 3.2;3.3;3.4
#> 2   CO                   Comments Special-Purpose     SDTM 3.2;3.3;3.4
#> 3   SE           Subject Elements Special-Purpose     SDTM 3.2;3.3;3.4
#> 4   SV             Subject Visits Special-Purpose     SDTM 3.2;3.3;3.4
#> 5   SM Subject Disease Milestones Special-Purpose     SDTM 3.2;3.3;3.4
#> 6   AG           Procedure Agents   Interventions     SDTM 3.2;3.3;3.4
#>                           keys
#> 1              STUDYID;USUBJID
#> 2        STUDYID;USUBJID;COSEQ
#> 3 STUDYID;USUBJID;ETCD;SESTDTC
#> 4     STUDYID;USUBJID;VISITNUM
#> 5         STUDYID;USUBJID;MIDS
#> 6        STUDYID;USUBJID;AGSEQ
```
