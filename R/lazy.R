# Lazy (arrow / duckdb) cards.
#
# A lazy card keeps the R object it was made from in `card$source`, so later
# code can summarise the whole table without collecting it. `source` is an R
# object (an Arrow table, a dbplyr tbl): it is scrubbed before a card is
# serialised and must never reach the browser, a state file or an attribute.

#' Is duckdb available for whole-table work?
#'
#' `FALSE` when the `sideview.use_duckdb` option is `FALSE` (the switch the
#' browser tests use in a background process), or when duckdb, dbplyr or DBI
#' is not installed.
#' @return A single logical.
#' @noRd
sv_has_duckdb <- function() {
  isTRUE(getOption("sideview.use_duckdb", TRUE)) &&
    requireNamespace("duckdb", quietly = TRUE) &&
    requireNamespace("dbplyr", quietly = TRUE) &&
    requireNamespace("DBI", quietly = TRUE)
}

#' Can this card be worked on in full (not only its preview rows)?
#' @param card A `sideview_card`.
#' @return A single logical.
#' @noRd
sv_card_is_lazy <- function(card) {
  if (is.null(card$source) || !sv_has_duckdb()) return(FALSE)
  if (identical(card$lazy_source, "arrow") && !requireNamespace("arrow", quietly = TRUE)) {
    return(FALSE)
  }
  TRUE
}

#' Is `x` a list of tables (to be flattened) rather than one table object?
#'
#' A dbplyr tbl and the list mocks of lazy tables are lists too, but each is one table.
#' @noRd
sv_is_table_list <- function(x) {
  is.list(x) && !is.data.frame(x) &&
    !inherits(x, c("sideview_card", "tbl_lazy", "tbl_duckdb_connection", "duckdb_connection"))
}

#' Deparse the expression a caller passed for a table
#' @noRd
sv_expr_string <- function(e) {
  if (is.null(e)) return(NULL)
  if (is.character(e)) return(e[1])
  paste(deparse(e, width.cutoff = 500L), collapse = " ")
}

#' Normalise one `...` argument of sideview()/sideview_widget()
#'
#' A whole duckdb connection also gets the argument expression, which becomes
#' the `dplyr::tbl(<expr>, "<table>")` code reference.
#' @noRd
sv_normalize_arg <- function(val, nm, expr = NULL) {
  if (inherits(val, "duckdb_connection") && !is.null(expr)) {
    sv_normalize(val, name = nm, expr = expr)
  } else {
    sv_normalize(val, name = nm)
  }
}
