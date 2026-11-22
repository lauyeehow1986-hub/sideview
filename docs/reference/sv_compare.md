# Compare two versions of a table by key

Compares two cuts of the same table row by row. Rows are matched on the
key columns (`NA` matches `NA`) and reported as added (only in `new`),
removed (only in `old`), changed (matched, with a different value in a
column) or the same. A key that repeats in either version leaves all its
rows, in both versions, out of every count and table; the summary
reports it as a warning with up to 5 sample keys, the first in sorted
order.

## Usage

``` r
sv_compare(old, new, by = NULL)
```

## Arguments

- old, new:

  Data frames, duckdb tables or Arrow tables: the earlier and the later
  version. Unnamed tables are named by their expressions, as
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)
  names them.

- by:

  Names of the key columns, the same in both versions (1 to 20). `NULL`
  suggests a key: the first shared column (same name, similar values)
  with no repeated value in either version, else the shared columns
  together when their combinations are unique, else an error asks for
  the key. For a duckdb or Arrow table the suggestion reads the first 50
  rows of each version.

## Value

An object of class `sv_compare`: `old_name`, `new_name`, `by`, the row
counts `n_old`, `n_new`, `n_added`, `n_removed`, `n_changed`, `same`,
the repeated-key counts, `per_column` (changed rows per compared
column), `text` (summary lines) and `open` (button labels), plus the
tables `added`, `removed` and `changed`, and `code`.

## Details

Compared columns are those in both versions with the same type kind, so
an integer column equals a double column of the same values and a factor
equals a character column. A column whose kind differs is listed in
`type_changed`, not compared. Key columns are not compared. Equality is
exact; `NA` and `NaN` in both versions are the same, and one of them
against a value is a change. Key columns of differing kinds are matched
as text.

The `changed` table has the key columns, then `column`, `old` and `new`
(the values as text, missing values `NA`), ordered by key and then by
the column's position in `new`.

When either version is a duckdb or Arrow table, both are compared on one
duckdb connection and nothing is collected: the counts come from
queries, and `added`, `removed` and `changed` are lazy duckdb tables (in
no particular order). Number text can then differ from R's (`"100000"`
for `"1e+05"`).

## Examples

``` r
cut1 <- data.frame(id = 1:4, sev = c("MILD", "MILD", "SEVERE", "MILD"))
cut2 <- data.frame(id = 2:5, sev = c("MILD", "MODERATE", "SEVERE", "MILD"))
sv_compare(cut1, cut2, by = "id")
#> cut1 -> cut2, key id
#> Rows:    4 -> 4   added 1 · removed 1 · changed 2 · same 1
#> Columns: added none · removed none · type changed none
#> Changed values by column:  sev 2
#> added: 1 row
#> removed: 1 row
#> changed values: 2
```
