# Describe tables as plain text

Reads each table and writes one sentence for the table and one line for
each column: its label, kind, missing and distinct counts, number ranges
and the commonest text values. It is the text twin of looking at the
cards on the canvas, for a screen reader or a console. A lazy (duckdb or
Arrow) table is never collected: only the summaries of
[`sv_column_profile()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_column_profile.md)
are read.

## Usage

``` r
sv_describe(x, ..., n_levels = 5)
```

## Arguments

- x, ...:

  Data frames, duckdb tables or Arrow tables, named or not (an unnamed
  table is named from its expression, as in
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)),
  or one list of them.

- n_levels:

  How many of the commonest values of a text column to list.

## Value

The lines, invisibly, as a character vector of class `sv_description`.
Printing it writes one line per row.

## Examples

``` r
patients <- data.frame(id = 1:4, sex = c("M", "F", "F", NA),
                       age = c(40, 51, 62, 38))
sv_describe(patients)
```
