# Suggest Foreign Key Mappings Across Canvas Cards

Evaluates pairwise heuristic column relationships across loaded
`sideview_card` objects or tabular data structures, computing a 3-part
composite confidence score based on name similarity (40%), data type
compatibility (20%), and Jaccard value overlap (40%).

## Usage

``` r
sv_suggest_mappings(cards, ..., min_confidence = 0.6, cdisc = "auto")
```

## Arguments

- cards:

  A list of `sideview_card` objects or tabular data frames.
  Alternatively, individual cards or tables can be passed via `...`.

- ...:

  Additional cards or tables passed as positional arguments.

- min_confidence:

  Minimum confidence threshold (numeric between 0 and 1) for returned
  suggestions (default `0.6`).

- cdisc:

  `"auto"` (default) or anything but `FALSE` to suggest the CDISC join
  keys (see
  [`sv_cdisc_join_keys()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_cdisc_join_keys.md))
  for pairs of tagged tables; `FALSE` keeps the heuristic suggestions
  only. Rule rows have confidence 1, come first and are never filtered
  by `min_confidence`. A pair of CDISC tables that can take part
  (tagged, with `USUBJID`) but has no rule gets no heuristic rows
  either.

## Value

A `data.frame` with columns:

- `from_table`:

  Source table or card name.

- `from_col`:

  Source column name.

- `to_table`:

  Destination table or card name.

- `to_col`:

  Destination column name.

- `confidence`:

  Composite confidence score in `[0, 1]`.

- `reason`:

  Human-readable justification describing similarity components.

- `group`:

  `NA` for heuristic rows; `"cdisc:<from>~<to>"` for the rows of one
  CDISC key (the columns of one join).

- `kind`:

  `NA` for heuristic rows; `"trace"`, `"subject"` or `"visit"`.

## Examples

``` r
df1 <- data.frame(patient_id = 1:5, age = c(20, 30, 40, 50, 60))
df2 <- data.frame(patient_id = 3:7, score = c(10, 20, 30, 40, 50))
sv_suggest_mappings(list(patients = df1, visits = df2))
#>   from_table   from_col to_table     to_col confidence
#> 1   patients patient_id   visits patient_id     0.7714
#>                                                                reason group
#> 1 Exact name match with ID suffix; identical types; 43% value overlap  <NA>
#>   kind
#> 1 <NA>
```
