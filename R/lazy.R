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

#' A fresh holder for the per-session private duckdb connection
#'
#' `con` is opened on first use by [sv_lazy_con()]; `tbls` caches converted
#' arrow tables by key.
#' @return An environment with `con = NULL` and `tbls = list()`.
#' @noRd
sv_lazy_env <- function() {
  e <- new.env(parent = emptyenv())
  e$con <- NULL
  e$tbls <- list()
  e
}

#' The private duckdb connection, opened on first use
#' @param con_env An environment from [sv_lazy_env()].
#' @noRd
sv_lazy_con <- function(con_env) {
  if (is.null(con_env$con)) {
    con_env$con <- DBI::dbConnect(duckdb::duckdb())
  }
  con_env$con
}

#' Shut down the private connection (safe to call twice)
#'
#' Only the private connection is closed, never a connection the user passed in.
#' @noRd
sv_lazy_close <- function(con_env) {
  con <- con_env$con
  if (!is.null(con)) {
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
  }
  con_env$con <- NULL
  con_env$tbls <- list()
  invisible(NULL)
}

#' A duckdb tbl for a lazy source
#'
#' A duckdb tbl is returned as is. An arrow object is handed to duckdb
#' zero-copy on the private connection, and cached under `key` when given.
#' @param source A `tbl_duckdb_connection` or an Arrow table / dataset.
#' @param con_env An environment from [sv_lazy_env()].
#' @param key Optional cache key (usually the card name).
#' @noRd
sv_lazy_tbl <- function(source, con_env, key = NULL) {
  if (inherits(source, "tbl_duckdb_connection")) return(source)
  if (!is.null(key) && !is.null(con_env$tbls[[key]])) return(con_env$tbls[[key]])
  tbl <- arrow::to_duckdb(source, con = sv_lazy_con(con_env), auto_disconnect = FALSE)
  if (!is.null(key)) con_env$tbls[[key]] <- tbl
  tbl
}

#' Register a data frame on a connection under a temporary name
#' @return `list(tbl, name)`; undo with [sv_lazy_detach()].
#' @noRd
sv_lazy_attach <- function(df, con) {
  name <- paste0("sv_tmp_", paste(sample(c(0:9, letters[1:6]), 8, TRUE), collapse = ""))
  duckdb::duckdb_register(con, name, df)
  list(tbl = dplyr::tbl(con, name), name = name)
}

#' Undo [sv_lazy_attach()]
#' @noRd
sv_lazy_detach <- function(con, name) {
  try(duckdb::duckdb_unregister(con, name), silent = TRUE)
  invisible(NULL)
}

#' Undo an `arrow::to_duckdb()` on a user connection
#'
#' The table name is `dbplyr::remote_name()` of the converted tbl.
#' @noRd
sv_lazy_detach_arrow <- function(con, name) {
  try(duckdb::duckdb_unregister_arrow(con, name), silent = TRUE)
  invisible(NULL)
}
