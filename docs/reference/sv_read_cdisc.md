# Read CDISC datasets from files

Reads `.xpt`, `.sas7bdat`, Dataset-JSON (`.json`) and `.parquet` files
into a named list that can go straight into
[`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)
or
[`sideview_widget()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md).
Names are the lower-case file stems, in file order. Variable labels are
kept.

## Usage

``` r
sv_read_cdisc(path, lazy = TRUE)
```

## Arguments

- path:

  A directory (its supported files are read, not recursively) or a
  character vector of files. A file with an unsupported extension is an
  error when named, and ignored when found in a directory.

- lazy:

  When `TRUE` (the default), parquet files are opened as Arrow Datasets
  and stay on disk. When `FALSE` they are read into data frames.

## Value

A named list of data frames (and Arrow Datasets for lazy parquet). A
file that cannot be read gives a warning and is skipped.

## Details

Each format needs its package, all in `Suggests:`: haven (`.xpt`,
`.sas7bdat`), datasetjson (`.json`) and arrow (`.parquet`). Files are
only read, never run. Nothing goes over the network.

## Examples

``` r
if (FALSE) { # \dontrun{
x <- sv_read_cdisc("study/sdtm")
sideview_widget(x)
} # }
```
