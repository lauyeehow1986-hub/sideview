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

#' Decode the dictionary columns of an Arrow object before duckdb sees it
#'
#' duckdb (1.4.3) must never scan an Arrow dictionary column (an R factor) that
#' has NULLs. Its arrow scan points every NULL row at the slot one past the end
#' of the dictionary, which it marks invalid but never allocates, and its
#' vector loops load that slot before checking validity. That heap over-read
#' segfaults R whenever the dictionary buffer happens to end at an uncommitted
#' page (in about half of the runs of the 3000-scan parity grid in test-lazy.R).
#'
#' Each dictionary column is cast to its value type, so a factor becomes a
#' string, which is what duckdb returns for it anyway. The cast is a lazy Arrow
#' query, run batch by batch in each scan, so nothing is materialised and a
#' Dataset stays on disk. An object with no dictionary column is returned as is.
#' @param source An Arrow Table, RecordBatch, Dataset or query.
#' @return `source`, or an `arrow_dplyr_query` with the same column names.
#' @noRd
sv_lazy_decode_dictionaries <- function(source) {
  fields <- arrow::schema(source)$fields
  dict <- Filter(function(f) inherits(f$type, "DictionaryType"), fields)
  if (length(dict) == 0L) return(source)
  casts <- lapply(dict, function(f) rlang::expr(cast(!!rlang::sym(f$name), !!f$type$value_type)))
  names(casts) <- vapply(dict, function(f) f$name, character(1))
  # arrow's mutate() builds a 0-row data frame of the schema to resolve `.by`, and
  # warns that a non-string dictionary becomes factor levels there; it is not data
  withCallingHandlers(
    dplyr::mutate(source, !!!casts),
    warning = function(w) {
      if (grepl("Coercing dictionary values", conditionMessage(w), fixed = TRUE)) {
        invokeRestart("muffleWarning")
      }
    }
  )
}

#' A duckdb tbl for a lazy source
#'
#' A duckdb tbl is returned as is. An arrow object is handed to duckdb on the
#' private connection, zero-copy except for its dictionary columns (decoded by
#' [sv_lazy_decode_dictionaries()]), and cached under `key` when given.
#' @param source A `tbl_duckdb_connection` or an Arrow table / dataset.
#' @param con_env An environment from [sv_lazy_env()].
#' @param key Optional cache key (usually the card name).
#' @noRd
sv_lazy_tbl <- function(source, con_env, key = NULL) {
  if (inherits(source, "tbl_duckdb_connection")) return(source)
  if (!is.null(key) && !is.null(con_env$tbls[[key]])) return(con_env$tbls[[key]])
  tbl <- arrow::to_duckdb(sv_lazy_decode_dictionaries(source),
                          con = sv_lazy_con(con_env), auto_disconnect = FALSE)
  if (!is.null(key)) con_env$tbls[[key]] <- tbl
  tbl
}

# Counts temporary table names; unique within a process, so within a connection.
sv_lazy_counter <- new.env(parent = emptyenv())
sv_lazy_counter$n <- 0L

#' Register a data frame on a connection under a temporary name
#' @return `list(tbl, name)`; undo with [sv_lazy_detach()].
#' @noRd
sv_lazy_attach <- function(df, con) {
  # a counter, not sample(): the user's set.seed() stream must not move
  sv_lazy_counter$n <- sv_lazy_counter$n + 1L
  name <- sprintf("sv_tmp_%08x", sv_lazy_counter$n)
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

#' The kind of an R column, for the text it should be matched as
#'
#' `"character"`, `"logical"`, `"double"` (a plain double, which can hold NaN
#' and Inf; a Date or POSIXct is not one) or `"other"` (integer, Date, factor...).
#' @param x A column, typically from a 0-row `collect()`.
#' @noRd
sv_lazy_kind <- function(x) {
  if (is.character(x)) "character"
  else if (is.logical(x)) "logical"
  else if (identical(class(x), "numeric")) "double"
  else "other"
}

#' A column as the text R would give it, for `contains` filters
#'
#' R's `grepl()` matches `as.character(col)`, so the database has to produce
#' the same text. A character column is used as is; a logical is `"TRUE"` /
#' `"FALSE"` (duckdb says `true`); a plain double drops a trailing `.0`
#' (duckdb says `130.0`) and spells `NaN`, `Inf` and `-Inf` as R does; any other
#' column (integer, Date, factor / enum) is cast to text, which agrees with R.
#'
#' Known deviation: for doubles R uses 15 significant digits and switches to
#' scientific notation, so float noise (`0.1 + 0.2` is `"0.3"` in R and
#' `"0.30000000000000004"` here) and values like `1e+05` (R) versus `100000`
#' differ. Whole numbers and ordinary decimals agree.
#' @param sym A column symbol.
#' @param kind From [sv_lazy_kind()].
#' @noRd
sv_lazy_text_expr <- function(sym, kind) {
  switch(kind,
    character = sym,
    logical = rlang::expr(if_else(!!sym, "TRUE", "FALSE")),
    double = rlang::expr(case_when(
      is.nan(!!sym) ~ "NaN",
      is.infinite(!!sym) & !!sym > 0 ~ "Inf",
      is.infinite(!!sym) ~ "-Inf",
      .default = stringr::str_replace(as.character(!!sym), "\\.0$", "")
    )),
    rlang::expr(as.character(!!sym))
  )
}

#' Filter expression for a lazy table
#'
#' The twin of [sv_filter_condition()], but as a language object built from
#' symbols and values (never by parsing text), so it translates to SQL. The
#' literal rule is the same: a numeric column compared with a number is
#' written as a number, otherwise as a string. `contains` is a fixed
#' (non-regex) match on the column's text as R writes it, see [sv_lazy_text_expr()].
#' @inheritParams sv_filter_condition
#' @param kind The column's kind, from [sv_lazy_kind()]; when `NULL`, `"other"`
#'   for a numeric column and `"character"` otherwise.
#' @return A language object for `dplyr::filter()`.
#' @noRd
sv_lazy_filter_expr <- function(col, op, value, numeric = FALSE, kind = NULL) {
  kind <- kind %||% (if (isTRUE(numeric)) "other" else "character")
  double <- identical(kind, "double")
  value <- as.character(value)
  num_ok <- isTRUE(numeric) && !is.na(suppressWarnings(as.numeric(value)))
  sym <- rlang::sym(col)
  # a numeric column with a non-numeric value compares as text, as R would
  lhs <- if (isTRUE(numeric) && !num_ok) rlang::expr(as.character(!!sym)) else sym
  lit <- if (num_ok) as.numeric(format(as.numeric(value), digits = 15)) else value
  # NaN is "not a number" to R (the comparison is NA, the row is dropped) but the
  # largest number to duckdb, so comparisons on doubles skip it explicitly.
  cmp <- function(e) if (isTRUE(numeric) && double) rlang::expr(!is.nan(!!sym) & !!e) else e
  switch(op,
    contains = {
      target <- sv_lazy_text_expr(sym, kind)
      # not str_detect(fixed()): dbplyr turns that into a REGEXP, so "." matches everything
      rlang::expr(contains(!!target, !!value))
    },
    equals = cmp(rlang::expr(!!lhs == !!lit)),
    not_equals = cmp(rlang::expr(!!lhs != !!lit)),
    gt = cmp(rlang::expr(!!lhs > !!lit)),
    gte = cmp(rlang::expr(!!lhs >= !!lit)),
    lt = cmp(rlang::expr(!!lhs < !!lit)),
    lte = cmp(rlang::expr(!!lhs <= !!lit)),
    stop("Unknown filter operator: ", op)
  )
}

#' Answer a row-window request from the whole lazy table
#'
#' The twin of [sv_rows_window()]: the same request, the same reply, the same
#' clamping, but sorted, filtered and paged by the database. Strings sort
#' bytewise (as `arrange()` does), `NA` sorts last in both directions, and
#' ties keep the table's own row order. Only the requested window is collected.
#' @param tbl A duckdb tbl (see [sv_lazy_tbl()]).
#' @inheritParams sv_rows_window
#' @return The same list as [sv_rows_window()].
#' @noRd
sv_lazy_rows_window <- function(tbl, req, order_cache = NULL) {
  spec_key <- paste(
    unlist(req$sort %||% list()), "|", unlist(req$filter %||% list()),
    collapse = "\u001f"
  )
  # 0 rows: the column classes and names, nothing else
  zero <- dplyr::collect(utils::head(tbl, 0L))
  cols <- names(zero)

  keep <- NULL
  filter <- req$filter
  if (!is.null(filter) && !is.null(filter$col) && filter$col %in% cols) {
    keep <- sv_lazy_filter_expr(
      filter$col, filter$op %||% "equals", filter$val %||% "",
      numeric = is.numeric(zero[[filter$col]]),
      kind = sv_lazy_kind(zero[[filter$col]])
    )
  }
  sort <- req$sort
  has_sort <- !is.null(sort) && !is.null(sort$col) && sort$col %in% cols &&
    (sort$dir %||% "none") %in% c("asc", "desc")

  # row ids assume duckdb's default preserve_insertion_order = true (ROW_NUMBER() OVER ()
  # then numbers rows in table order)
  numbered <- dplyr::mutate(tbl, .sv_row = row_number())
  if (!is.null(keep)) numbered <- dplyr::filter(numbered, !!keep)

  total <- NULL
  if (!is.null(order_cache) && identical(order_cache$key, spec_key)) total <- order_cache$total
  if (is.null(total)) {
    total <- as.integer(dplyr::pull(dplyr::count(numbered), "n"))
    if (!is.null(order_cache)) {
      order_cache$key <- spec_key
      order_cache$total <- total
    }
  }

  # Sorting: dbplyr's window_order() takes bare columns only, so two helper
  # columns carry the rules of dplyr::arrange() whatever the database's own
  # defaults are: missing values (and NaN, which R treats as missing) go last in
  # both directions, and the key is NULL for them so they tie by row order.
  keys <- list()
  if (has_sort) {
    sym <- rlang::sym(sort$col)
    # plain doubles only: a Date or POSIXct is a double in R, but has no NaN
    is_missing <- if (sv_lazy_kind(zero[[sort$col]]) == "double") {
      rlang::expr(is.na(!!sym) | is.nan(!!sym))
    } else {
      rlang::expr(is.na(!!sym))
    }
    numbered <- dplyr::mutate(
      numbered,
      .sv_na = !!is_missing,
      .sv_key = if_else(.sv_na, NA, !!sym)
    )
    key <- rlang::sym(".sv_key")
    keys <- list(
      rlang::sym(".sv_na"),
      if (identical(sort$dir, "desc")) rlang::expr(desc(!!key)) else key
    )
  }

  offset <- max(0L, as.integer(req$offset %||% 0L))
  limit <- max(1L, min(2000L, as.integer(req$limit %||% 200L)))

  if (total <= offset) {
    win <- zero
    win$.sv_row <- integer(0)
  } else {
    ranked <- dbplyr::window_order(numbered, !!!keys, .sv_row)
    ranked <- dplyr::mutate(ranked, .sv_rank = row_number())
    ranked <- dplyr::filter(ranked, .sv_rank > !!offset, .sv_rank <= !!(offset + limit))
    ranked <- dplyr::arrange(ranked, .sv_rank)
    win <- dplyr::collect(ranked)
  }

  list(
    offset = offset,
    total = total,
    row_ids = as.integer(win$.sv_row - 1L),
    columns = lapply(win[cols], sv_format_cells)
  )
}

# Names that only exist inside the SQL translation of the verbs above.
utils::globalVariables(c(".sv_row", ".sv_rank", ".sv_na", ".sv_key", "row_number", "if_else", "case_when", "contains", "desc", "cast"))
