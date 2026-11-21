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
  if (inherits(card$source, "sv_derived_source")) return(TRUE)
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
    !inherits(x, c("sideview_card", "tbl_lazy", "tbl_duckdb_connection", "duckdb_connection",
                  "sv_preview_table"))
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
#' `con` is opened on first use by `sv_lazy_con()`; `tbls` caches converted
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
#' @param con_env An environment from `sv_lazy_env()`.
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

# A row count as an integer, or a double past .Machine$integer.max (as count() does)
sv_lazy_count <- function(n) {
  n <- as.double(n)
  if (is.na(n) || n <= .Machine$integer.max) as.integer(n) else n
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

#' The Arrow tables registered on a duckdb connection (names; empty when unknown)
#' @noRd
sv_lazy_arrow_views <- function(con) {
  tryCatch(as.character(duckdb::duckdb_list_arrow(con)), error = function(e) character())
}

#' Let go of the Arrow tables a cached lazy table registered on the session connection
#'
#' A user's own duckdb table carries no such names and is left alone. Never fails.
#' @noRd
sv_lazy_release <- function(tbl, con_env) {
  cleanup <- attr(tbl, "sv_cleanup", exact = TRUE)
  if (is.function(cleanup)) tryCatch(cleanup(), error = function(e) NULL)
  views <- attr(tbl, "sv_arrow_views", exact = TRUE)
  if (length(views) && !is.null(con_env$con)) {
    for (nm in views) {
      tryCatch(duckdb::duckdb_unregister_arrow(con_env$con, nm), error = function(e) NULL)
    }
  }
  invisible(NULL)
}

#' A duckdb tbl for a lazy source
#'
#' A duckdb tbl is returned as is. An arrow object is handed to duckdb on the
#' private connection, zero-copy except for its dictionary columns (decoded by
#' `sv_lazy_decode_dictionaries()`), and cached under `key` when given. What
#' duckdb does not keep travels with the tbl as attributes: the time zones of
#' its timestamp columns as `sv_tz` (see `sv_lazy_zones()`), and the factor
#' columns, with their levels, as `sv_factors` (see `sv_lazy_factors()`).
#' @param source A `tbl_duckdb_connection` or an Arrow table / dataset.
#' @param con_env An environment from `sv_lazy_env()`.
#' @param key Optional cache key (usually the card name).
#' @param levels Read the levels of the factor columns too (for sorting and
#'   comparing them by level). `FALSE` records only which columns are factors.
#' @noRd
sv_lazy_tbl <- function(source, con_env, key = NULL, levels = TRUE) {
  if (inherits(source, "tbl_duckdb_connection")) return(source)
  if (!is.null(key) && !is.null(con_env$tbls[[key]])) return(con_env$tbls[[key]])
  if (inherits(source, "sv_derived_source")) return(sv_lazy_derived_tbl(source, con_env, key))
  con <- sv_lazy_con(con_env)
  was <- sv_lazy_arrow_views(con)
  tbl <- arrow::to_duckdb(sv_lazy_decode_dictionaries(source), con = con, auto_disconnect = FALSE)
  tbl <- sv_lazy_with_zones(tbl, sv_lazy_zones(source))
  factors <- sv_lazy_factors(source, levels = levels)
  if (length(factors)) attr(tbl, "sv_factors") <- factors
  # what this conversion registered on the connection, so a cached table can let it go
  attr(tbl, "sv_arrow_views") <- setdiff(sv_lazy_arrow_views(con), was)
  if (!is.null(key)) con_env$tbls[[key]] <- tbl
  tbl
}

#' The factor (dictionary) columns of an Arrow source
#'
#' duckdb gets a dictionary column decoded to its values, so what made it a
#' factor is kept here: whether it is ordered (from the schema, no scan) and its
#' levels, in the order `as.data.frame()` gives them (the dictionaries of the
#' chunks, in order, without repeats). A Table or RecordBatch holds its
#' dictionaries; a Dataset or a query is read batch by batch for them, the
#' values staying in Arrow.
#' @param source An Arrow Table, RecordBatch, Dataset or query.
#' @param levels Read the levels (else `levels` is `NULL`).
#' @return A named list, one `list(ordered, levels)` per dictionary column;
#'   empty when there is none.
#' @noRd
sv_lazy_factors <- function(source, levels = TRUE) {
  fields <- tryCatch(arrow::schema(source)$fields, error = function(e) list())
  dict <- Filter(function(f) inherits(f$type, "DictionaryType"), fields)
  if (!length(dict)) return(list())
  nms <- vapply(dict, function(f) f$name, "")
  lv <- if (isTRUE(levels)) tryCatch(sv_lazy_dictionary_levels(source, nms), error = function(e) NULL)
  out <- lapply(seq_along(dict), function(i) {
    list(ordered = isTRUE(dict[[i]]$type$ordered), levels = lv[[nms[i]]])
  })
  names(out) <- nms
  out
}

#' The levels of dictionary columns, without decoding them
#' @noRd
sv_lazy_dictionary_levels <- function(source, cols) {
  lv <- stats::setNames(vector("list", length(cols)), cols)
  add <- function(cn, arr) {
    v <- arr$dictionary()$as_vector()
    lv[[cn]] <<- if (is.null(lv[[cn]])) v else unique(c(lv[[cn]], v))
  }
  if (inherits(source, "ArrowTabular")) {
    for (cn in cols) {
      a <- source[[cn]]
      for (ch in if (inherits(a, "ChunkedArray")) a$chunks else list(a)) add(cn, ch)
    }
  } else {
    reader <- arrow::Scanner$create(dplyr::select(source, dplyr::all_of(cols)))$ToRecordBatchReader()
    while (!is.null(b <- reader$read_next_batch())) for (cn in cols) add(cn, b[[cn]])
  }
  lv
}

#' The factor information of one column of a lazy tbl
#'
#' From the `sv_factors` attribute (an Arrow dictionary), else from the 0-row
#' sample (a duckdb ENUM comes back as a factor; it has no order).
#' @param factors The `sv_factors` attribute, or `NULL`.
#' @param col Column name.
#' @param zero_col The column of a 0-row `collect()`.
#' @return `list(ordered, levels)` or `NULL` for a column that is not a factor.
#' @noRd
sv_lazy_factor_of <- function(factors, col, zero_col) {
  if (!is.null(factors[[col]])) return(factors[[col]])
  if (is.factor(zero_col)) return(list(ordered = is.ordered(zero_col), levels = levels(zero_col)))
  NULL
}

#' The level number of a factor column, as an expression (`NULL` for no level)
#' @noRd
sv_lazy_level_expr <- function(sym, lv) {
  branches <- lapply(seq_along(lv), function(i) rlang::expr(!!sym == !!lv[[i]] ~ !!i))
  rlang::expr(case_when(!!!branches))
}

# Counts temporary table names; unique within a process, so within a connection.
sv_lazy_counter <- new.env(parent = emptyenv())
sv_lazy_counter$n <- 0L

#' Register a data frame on a connection under a temporary name
#' @return `list(tbl, name)`; undo with `sv_lazy_detach()`.
#' @noRd
sv_lazy_attach <- function(df, con) {
  # a counter, not sample(): the user's set.seed() stream must not move
  sv_lazy_counter$n <- sv_lazy_counter$n + 1L
  name <- sprintf("sv_tmp_%08x", sv_lazy_counter$n)
  duckdb::duckdb_register(con, name, df)
  list(tbl = dplyr::tbl(con, name), name = name)
}

#' Undo `sv_lazy_attach()`
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

#' Time zones of the timestamp columns of a source
#'
#' duckdb keeps the instant of a timestamp but not its zone, so the zones are
#' read where they are stored: the Arrow schema (no scan), or the `tzone`
#' attribute of a data frame column (the session zone when it is empty). Only
#' columns with a zone are listed.
#' @param source An Arrow Table / Dataset / query, or a data frame.
#' @return A named character vector, possibly empty.
#' @noRd
sv_lazy_zones <- function(source) {
  z <- if (is.data.frame(source)) {
    vapply(source, function(v) {
      if (!inherits(v, "POSIXct")) return(NA_character_)
      tz <- attr(v, "tzone")[1]
      if (is.null(tz) || is.na(tz) || !nzchar(tz)) tz <- Sys.timezone()
      if (is.null(tz) || is.na(tz)) NA_character_ else tz
    }, "")
  } else {
    fields <- tryCatch(arrow::schema(source)$fields, error = function(e) list())
    out <- vapply(fields, function(f) sv_lazy_arrow_tz(f$type) %||% NA_character_, "")
    names(out) <- vapply(fields, function(f) f$name, "")
    out
  }
  if (!length(z)) return(character(0))
  z[!is.na(z) & nzchar(z)]
}

#' A tbl with its zones attached (as the `sv_tz` attribute)
#' @noRd
sv_lazy_with_zones <- function(tbl, zones) {
  if (length(zones)) attr(tbl, "sv_tz") <- zones
  tbl
}

#' The zone to show a POSIXct column in
#'
#' The zone recorded for it (from the Arrow schema, see `sv_lazy_zones()`), else
#' UTC: duckdb hands instants back as UTC, and without the ICU extension (which an
#' air-gapped duckdb build lacks) it cannot tell us another zone.
#' @noRd
sv_lazy_zone_for <- function(zones, col) {
  tz <- if (length(zones) && col %in% names(zones)) unname(zones[col])[1] else NA_character_
  if (is.na(tz)) "UTC" else tz
}

sv_lazy_tz_cache <- new.env(parent = emptyenv())

#' UTC offsets of a time zone over 1900-2100, from R
#'
#' duckdb's own zone conversion is the ICU extension, which an air-gapped build
#' does not have, so the offsets come from R's time zone database: the instants
#' (seconds since the epoch) at which the offset changes, found by bisection from
#' a 14-day grid, and the offset in force before each of them.
#' @param tz An Olson name.
#' @return `list(starts, offsets)`: `offsets` has one more element than `starts`;
#'   `offsets[i]` applies before `starts[i]`, the last one after the last start.
#' @noRd
sv_lazy_tz_segments <- function(tz) {
  hit <- sv_lazy_tz_cache[[tz]]
  if (!is.null(hit)) return(hit)
  off <- function(t) {
    local <- format(as.POSIXct(t, origin = "1970-01-01", tz = "UTC"), "%Y-%m-%d %H:%M:%S", tz = tz)
    as.numeric(as.POSIXct(local, tz = "UTC")) - t
  }
  grid <- seq(-2208988800, 4102444800, by = 14 * 86400)
  o <- off(grid)
  chg <- which(diff(o) != 0)
  lo <- grid[chg]
  hi <- grid[chg + 1L]
  before <- o[chg]
  while (length(lo) && any(hi - lo > 1)) {
    mid <- floor((lo + hi) / 2)
    same <- off(mid) == before
    lo[same] <- mid[same]
    hi[!same] <- mid[!same]
  }
  out <- list(starts = hi, offsets = c(o[1L], o[chg + 1L]))
  assign(tz, out, envir = sv_lazy_tz_cache)
  out
}

#' Smallest and largest instant of a timestamp column, in microseconds
#'
#' One aggregate over the column; `NULL` when there is no value or it cannot be read.
#' @noRd
sv_lazy_us_range <- function(tbl, col) {
  sym <- rlang::sym(col)
  r <- tryCatch(
    dplyr::collect(dplyr::summarise(tbl, lo = min(epoch_us(!!sym), na.rm = TRUE),
                                    hi = max(epoch_us(!!sym), na.rm = TRUE))),
    error = function(e) NULL
  )
  if (is.null(r) || nrow(r) != 1L) return(NULL)
  out <- c(as.numeric(r$lo), as.numeric(r$hi))
  if (all(is.finite(out))) out else NULL
}

# an integer as a BIGINT literal (a plain number would be a DOUBLE)
sv_lazy_bigint <- function(x) dplyr::sql(sprintf("CAST(%.0f AS BIGINT)", x))

#' A timestamp column as the wall-clock text R gives it, in SQL
#'
#' Equal to `as.character()` of the POSIXct in zone `tz`: `"2024-03-01 08:30:00"`,
#' the date alone at midnight, and fractional seconds without trailing zeros. The
#' instant (`epoch_us`, exact microseconds) is moved by the zone's offset, taken
#' from a tree of comparisons with the zone's transitions
#' (`sv_lazy_tz_segments()`), and formatted. `NULL` stays `NULL`.
#' @param sym A column symbol.
#' @param tz An Olson name.
#' @param range Optional `c(min, max)` of the column in microseconds; the offsets
#'   the data cannot reach are then left out of the expression, which is much
#'   cheaper to evaluate for a zone with daylight saving time.
#' @param seconds `TRUE` for the stack's text, `format(x, "%Y-%m-%d %H:%M:%S")`: always the time, whole
#'   seconds (the fraction is cut).
#' @noRd
sv_lazy_tz_text_expr <- function(sym, tz, range = NULL, seconds = FALSE) {
  seg <- sv_lazy_tz_segments(tz)
  if (!is.null(range) && length(seg$starts) && all(is.finite(range))) {
    # only the transitions the data can reach
    first <- sum(seg$starts <= range[1] / 1e6) + 1L
    last <- sum(seg$starts <= range[2] / 1e6) + 1L
    seg <- list(starts = if (last > first) seg$starts[first:(last - 1L)] else numeric(0),
                offsets = seg$offsets[first:last])
  }
  us <- rlang::expr(epoch_us(!!sym))
  # a balanced tree of comparisons, so a row costs log2(transitions) of them
  pick <- function(i, j) {
    if (i == j) return(sv_lazy_bigint(seg$offsets[i] * 1e6))
    m <- (i + j) %/% 2L
    rlang::expr(if_else(!!us < !!sv_lazy_bigint(seg$starts[m] * 1e6), !!pick(i, m), !!pick(m + 1L, j)))
  }
  off <- pick(1L, length(seg$offsets))
  if (isTRUE(seconds)) return(rlang::expr(strftime(make_timestamp(!!us + !!off), "%Y-%m-%d %H:%M:%S")))
  full <- rlang::expr(strftime(make_timestamp(!!us + !!off), "%Y-%m-%d %H:%M:%S.%f"))
  # trailing zeros and the bare dot of the fraction go, then a time of 00:00:00 (R shows the date alone)
  rlang::expr(regexp_replace(rtrim(rtrim(!!full, "0"), "."), " 00:00:00$", ""))
}

#' Compare a POSIXct column with a typed value, as R does
#'
#' R reads a string compared with a POSIXct with `as.POSIXct()` (the session
#' zone) and compares instants; a string it cannot read raises an error, which
#' the in-memory window turns into "no rows". The column is compared as
#' microseconds since the epoch, against a DOUBLE: DuckDB 2.0 rewrites
#' `epoch_us(col) > <BIGINT>` into a timestamp range that it pushes into an
#' arrow scan, which then matches no rows. A DOUBLE is not rewritten, and it is
#' exact for every instant within about 285 years of 1970 (|us| < 2^53).
#' @noRd
sv_lazy_tz_cmp_expr <- function(sym, op, value) {
  t <- tryCatch(as.POSIXct(value), error = function(e) NULL)
  if (is.null(t) || length(t) != 1L || is.na(t)) return(rlang::expr(FALSE))
  lit <- dplyr::sql(sprintf("CAST(%.0f AS DOUBLE)", round(as.numeric(t) * 1e6)))
  us <- rlang::expr(epoch_us(!!sym))
  switch(op,
    equals = rlang::expr(!!us == !!lit),
    not_equals = rlang::expr(!!us != !!lit),
    gt = rlang::expr(!!us > !!lit),
    gte = rlang::expr(!!us >= !!lit),
    lt = rlang::expr(!!us < !!lit),
    lte = rlang::expr(!!us <= !!lit)
  )
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
#' A POSIXct column (`tz` given) is the wall-clock text of its zone, see
#' `sv_lazy_tz_text_expr()`.
#' @param sym A column symbol.
#' @param kind From `sv_lazy_kind()`.
#' @param tz Time zone of a POSIXct column, or `NULL`.
#' @param tz_range Optional `c(min, max)` of the column in microseconds, see
#'   `sv_lazy_tz_text_expr()`.
#' @noRd
sv_lazy_text_expr <- function(sym, kind, tz = NULL, tz_range = NULL) {
  if (!is.null(tz)) return(sv_lazy_tz_text_expr(sym, tz, tz_range))
  switch(kind,
    character = sym,
    logical = rlang::expr(if_else(!!sym, "TRUE", "FALSE")),
    double = rlang::expr(case_when(
      isnan(!!sym) ~ "NaN",
      isinf(!!sym) & !!sym > 0 ~ "Inf",
      isinf(!!sym) ~ "-Inf",
      .default = stringr::str_replace(as.character(!!sym), "\\.0$", "")
    )),
    rlang::expr(as.character(!!sym))
  )
}

#' Filter expression for a lazy table
#'
#' The twin of `sv_filter_condition()`, but as a language object built from
#' symbols and values (never by parsing text), so it translates to SQL. The
#' literal rule is the same: a numeric column compared with a number is
#' written as a number, otherwise as a string. `contains` is a fixed
#' (non-regex) match on the column's text as R writes it, see `sv_lazy_text_expr()`.
#' @inheritParams sv_filter_condition
#' @param kind The column's kind, from `sv_lazy_kind()`; when `NULL`, `"other"`
#'   for a numeric column and `"character"` otherwise.
#' @param tz The time zone of a POSIXct column, else `NULL`. `contains` then
#'   matches the wall-clock text of that zone, and the other operators compare the
#'   instant with the value read by `as.POSIXct()`, as R does.
#' @param tz_range Optional `c(min, max)` of the column in microseconds.
#' @param date Is the column a Date? R reads the value with `as.Date()`; a value
#'   it cannot read matches nothing, whatever the operator.
#' @param fct For a factor column, `list(ordered, levels)` (see
#'   `sv_lazy_factor_of()`). R compares a factor by level only when it is ordered;
#'   `>` and the like on an unordered factor match nothing.
#' @return A language object for `dplyr::filter()`.
#' @noRd
sv_lazy_filter_expr <- function(col, op, value, numeric = FALSE, kind = NULL, tz = NULL, tz_range = NULL,
                                date = FALSE, fct = NULL) {
  kind <- kind %||% (if (isTRUE(numeric)) "other" else "character")
  double <- identical(kind, "double")
  value <- as.character(value)
  num_ok <- isTRUE(numeric) && !is.na(suppressWarnings(as.numeric(value)))
  sym <- rlang::sym(col)
  ops <- c("equals", "not_equals", "gt", "gte", "lt", "lte")
  if (op != "contains" && !op %in% ops) stop("Unknown filter operator: ", op)
  if (!is.null(tz) && op != "contains") {
    return(sv_lazy_tz_cmp_expr(sym, op, value))
  }
  rel <- function(lhs, rhs) {
    switch(op,
      equals = rlang::expr(!!lhs == !!rhs), not_equals = rlang::expr(!!lhs != !!rhs),
      gt = rlang::expr(!!lhs > !!rhs), gte = rlang::expr(!!lhs >= !!rhs),
      lt = rlang::expr(!!lhs < !!rhs), lte = rlang::expr(!!lhs <= !!rhs)
    )
  }
  if (isTRUE(date) && op != "contains") {
    # R compares a Date with as.Date(value): an error or NA there keeps no row
    d <- tryCatch(as.Date(value), error = function(e) NULL)
    if (is.null(d) || length(d) != 1L || is.na(d)) return(rlang::expr(FALSE))
    return(rel(sym, rlang::expr(as.Date(!!format(d, "%Y-%m-%d")))))
  }
  if (identical(kind, "logical") && op != "contains") {
    # R compares a logical with a string as the text "TRUE" / "FALSE" (duckdb would
    # cast "yes" or "t" to TRUE)
    return(rel(sv_lazy_text_expr(sym, "logical"), value))
  }
  if (!is.null(fct) && op %in% c("gt", "gte", "lt", "lte")) {
    if (!isTRUE(fct$ordered) || is.null(fct$levels)) return(rlang::expr(FALSE))
    pos <- match(value, as.character(fct$levels))
    if (is.na(pos)) return(rlang::expr(FALSE))
    return(rel(sv_lazy_level_expr(sym, fct$levels), pos))
  }
  # a numeric column with a non-numeric value compares as text, as R would
  lhs <- if (isTRUE(numeric) && !num_ok) rlang::expr(as.character(!!sym)) else sym
  lit <- if (num_ok) as.numeric(format(as.numeric(value), digits = 15)) else value
  # NaN is "not a number" to R (the comparison is NA, the row is dropped) but the
  # largest number to duckdb, so comparisons on doubles skip it explicitly.
  cmp <- function(e) if (isTRUE(numeric) && double) rlang::expr(!isnan(!!sym) & !!e) else e
  switch(op,
    contains = {
      target <- sv_lazy_text_expr(sym, kind, tz, tz_range)
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
#' The twin of `sv_rows_window()`: the same request, the same reply, the same
#' clamping, but sorted, filtered and paged by the database. Strings sort
#' bytewise (as `arrange()` does), a factor by its levels, `NA` sorts last in
#' both directions, and ties keep the table's own row order. Only the requested
#' window is collected.
#'
#' Each request reads only what its window needs: with no sort and no filter the
#' scan stops after the window (`LIMIT`); a sorted window is a top-N
#' (`ORDER BY ... LIMIT ... OFFSET`), which duckdb runs with a heap rather than a
#' full sort; a filtered one is paged with `LIMIT ... OFFSET`. The row count is
#' taken once per filter and kept in `order_cache`.
#' @param tbl A duckdb tbl (see `sv_lazy_tbl()`).
#' @inheritParams sv_rows_window
#' @return The same list as `sv_rows_window()`.
#' @noRd
sv_lazy_rows_window <- function(tbl, req, order_cache = NULL) {
  # read before any verb: dplyr drops the attributes
  zones <- attr(tbl, "sv_tz")
  factors <- attr(tbl, "sv_factors")
  # the row count depends on the filter only, so a new sort reuses it
  count_key <- paste(unlist(req$filter %||% list()), collapse = "\u001f")
  # 0 rows: the column classes and names, nothing else
  zero <- dplyr::collect(utils::head(tbl, 0L))
  cols <- names(zero)
  # The zone of each POSIXct column: the one Arrow had, else UTC (see sv_lazy_zone_for()).
  zone_of <- function(col) {
    if (inherits(zero[[col]], "POSIXct")) sv_lazy_zone_for(zones, col) else NULL
  }

  keep <- NULL
  filter <- req$filter
  if (!is.null(filter) && !is.null(filter$col) && filter$col %in% cols) {
    fcol <- zero[[filter$col]]
    keep <- sv_lazy_filter_expr(
      filter$col, filter$op %||% "equals", filter$val %||% "",
      numeric = is.numeric(fcol),
      kind = sv_lazy_kind(fcol),
      tz = zone_of(filter$col),
      tz_range = if (identical(filter$op %||% "equals", "contains") && !is.null(zone_of(filter$col))) {
        sv_lazy_us_range(tbl, filter$col)
      },
      date = inherits(fcol, "Date"),
      fct = sv_lazy_factor_of(factors, filter$col, fcol)
    )
  }
  sort <- req$sort
  has_sort <- !is.null(sort) && !is.null(sort$col) && sort$col %in% cols &&
    (sort$dir %||% "none") %in% c("asc", "desc")

  total <- NULL
  if (!is.null(order_cache) && identical(order_cache$key, count_key)) total <- order_cache$total
  if (is.null(total)) {
    counted <- if (is.null(keep)) tbl else dplyr::filter(tbl, !!keep)
    # a double past the integer range, as count() gives
    total <- sv_lazy_count(dplyr::pull(dplyr::count(counted), "n"))
    if (!is.null(order_cache)) {
      order_cache$key <- count_key
      order_cache$total <- total
    }
  }

  offset <- sv_lazy_count(max(0, floor(as.numeric(req$offset %||% 0L))))
  limit <- max(1L, min(2000L, as.integer(req$limit %||% 200L)))

  if (total <= offset) {
    win <- zero
    win$.sv_row <- integer(0)
  } else if (is.null(keep) && !has_sort) {
    # rows offset + 1 to offset + limit in table order: the scan stops after them
    first <- dplyr::mutate(utils::head(tbl, as.numeric(offset) + limit), .sv_row = row_number())
    win <- dplyr::collect(dplyr::filter(first, .sv_row > !!offset))
  } else {
    # row ids assume duckdb's default preserve_insertion_order = true (ROW_NUMBER() OVER ()
    # then numbers rows in table order, and a filter keeps that order)
    numbered <- dplyr::mutate(tbl, .sv_row = row_number())
    if (!is.null(keep)) numbered <- dplyr::filter(numbered, !!keep)
    q <- function(x) as.character(DBI::dbQuoteIdentifier(dbplyr::remote_con(tbl), x))
    # table order (a top-N on the row number, which also keeps a filtered window stable)
    order <- q(".sv_row")
    if (has_sort) {
      # Two helper columns carry the rules of dplyr::arrange() whatever the
      # database's own defaults are: missing values (and NaN, which R treats as
      # missing) go last in both directions, and the key is NULL for them so they
      # tie by row order. A factor sorts by its levels, as order() does.
      sym <- rlang::sym(sort$col)
      scol <- zero[[sort$col]]
      # plain doubles only: a Date or POSIXct is a double in R, but has no NaN
      is_missing <- if (sv_lazy_kind(scol) == "double") {
        rlang::expr(is.na(!!sym) | isnan(!!sym))
      } else {
        rlang::expr(is.na(!!sym))
      }
      fct <- sv_lazy_factor_of(factors, sort$col, scol)
      # levels already in byte order sort the same as the text (no CASE needed)
      by_level <- !is.null(fct) && length(fct$levels) &&
        !identical(as.character(fct$levels), base::sort(as.character(fct$levels), method = "radix"))
      key <- if (by_level) sv_lazy_level_expr(sym, fct$levels) else sym
      numbered <- dplyr::mutate(numbered, .sv_na = !!is_missing, .sv_key = if_else(.sv_na, NA, !!key))
      order <- c(q(".sv_na"), paste(q(".sv_key"), if (identical(sort$dir, "desc")) "DESC" else "ASC"),
                 order)
    }
    win <- sv_lazy_slice(numbered, offset, limit, order)
  }
  # show each instant in its own zone, as the in-memory window does
  for (cn in cols) {
    tz <- zone_of(cn)
    if (!is.null(tz)) attr(win[[cn]], "tzone") <- tz
  }

  ids <- as.numeric(win$.sv_row) - 1
  list(
    offset = offset,
    total = total,
    row_ids = if (all(ids <= .Machine$integer.max)) as.integer(ids) else ids,
    columns = lapply(win[cols], sv_format_cells)
  )
}

#' Rows `offset + 1` to `offset + limit` of a lazy query, collected
#'
#' `LIMIT ... OFFSET` (dbplyr has no offset verb) on the query as dbplyr renders
#' it, sorted by `order` (SQL expressions) when given: with an order, duckdb runs a
#' top-N, which keeps a heap of `offset + limit` rows instead of sorting the table.
#' @param q A lazy duckdb query.
#' @param offset,limit Numbers of rows.
#' @param order Character vector of `ORDER BY` terms, possibly empty.
#' @noRd
sv_lazy_slice <- function(q, offset, limit, order = character(0)) {
  con <- dbplyr::remote_con(q)
  sql <- paste0(
    "SELECT * FROM (", dbplyr::sql_render(q), ") AS sv_w",
    if (length(order)) paste0(" ORDER BY ", paste(order, collapse = ", ")),
    sprintf(" LIMIT %.0f OFFSET %.0f", limit, offset)
  )
  dplyr::collect(dplyr::tbl(con, dplyr::sql(sql)))
}

#' Is this a table the join check should run on in the database?
#'
#' A dbplyr tbl, or anything Arrow can hand to duckdb. A data frame is not.
#' @param x Any object.
#' @return A single logical.
#' @noRd
sv_is_lazy_input <- function(x) {
  inherits(x, c("tbl_lazy", "ArrowTabular", "Dataset", "arrow_dplyr_query"))
}

#' `"duckdb"`, `"arrow"` or `"df"`
#' @noRd
sv_lazy_origin <- function(x) {
  if (inherits(x, "tbl_lazy")) {
    "duckdb"
  } else if (sv_is_lazy_input(x)) {
    "arrow"
  } else if (is.data.frame(x)) {
    "df"
  } else {
    stop("`x` and `y` must be data frames, duckdb tables or Arrow tables.", call. = FALSE)
  }
}

#' Column names of a table of any origin, without reading it
#' @noRd
sv_lazy_names <- function(x) {
  if (inherits(x, "tbl_lazy")) dplyr::tbl_vars(x) else names(x)
}

#' Put two tables on one duckdb connection for a join check
#'
#' Follows the placement table of the design (section 4.4): the check runs on
#' the connection of a duckdb side; with two duckdb sides on different
#' connections it does not run; with no duckdb side it runs on the private
#' connection of `con_env`. An Arrow side is handed over with `to_duckdb()`
#' (dictionary columns decoded first), a data frame is registered under a
#' temporary name. Only the columns in `cols_x` / `cols_y` are handed over, when
#' given. Whatever was added to the connection is removed by `cleanup()`,
#' which is also run here if placing the second table fails.
#' @param x,y Data frames, duckdb tbls or Arrow objects.
#' @param con_env An environment from `sv_lazy_env()`.
#' @param cols_x,cols_y Optional key columns of `x` / `y`.
#' @return `list(x, y, cleanup)`: two tbls on one connection, and a function that
#'   undoes the placement (safe to call twice).
#' @noRd
sv_lazy_place <- function(x, y, con_env, cols_x = NULL, cols_y = NULL) {
  origin <- c(sv_lazy_origin(x), sv_lazy_origin(y))
  for (src in list(x, y)) {
    if (inherits(src, "tbl_lazy") && !inherits(src, "tbl_duckdb_connection")) {
      rlang::abort("The join check needs duckdb tables; this table is on another database.",
                   class = "sv_lazy_not_duckdb")
    }
  }
  duck <- which(origin == "duckdb")
  if (length(duck) == 2L && !identical(dbplyr::remote_con(x), dbplyr::remote_con(y))) {
    rlang::abort("These tables are on different duckdb connections; join check unavailable.",
                 class = "sv_lazy_cross_con")
  }
  con <- if (length(duck)) dbplyr::remote_con(list(x, y)[[duck[1]]]) else sv_lazy_con(con_env)

  undo <- list()
  cleanup <- function() {
    todo <- rev(undo)
    undo <<- list()
    for (f in todo) f()
    invisible(NULL)
  }
  ok <- FALSE
  on.exit(if (!ok) cleanup(), add = TRUE)

  one <- function(src, kind, cols) {
    switch(kind,
      duckdb = src,
      arrow = {
        if (!is.null(cols)) src <- dplyr::select(src, dplyr::all_of(unique(cols)))
        tbl <- arrow::to_duckdb(sv_lazy_decode_dictionaries(src), con = con, auto_disconnect = FALSE)
        name <- dbplyr::remote_name(tbl)
        undo[[length(undo) + 1L]] <<- function() sv_lazy_detach_arrow(con, name)
        sv_lazy_with_zones(tbl, sv_lazy_zones(src))
      },
      df = {
        if (!is.null(cols)) src <- src[unique(cols)]
        a <- sv_lazy_attach(as.data.frame(src), con)
        undo[[length(undo) + 1L]] <<- function() sv_lazy_detach(con, a$name)
        sv_lazy_with_zones(a$tbl, sv_lazy_zones(src))
      }
    )
  }
  tx <- one(x, origin[1], cols_x)
  ty <- one(y, origin[2], cols_y)
  ok <- TRUE
  list(x = tx, y = ty, cleanup = cleanup)
}

#' Names of the key columns made by `sv_lazy_join_side()`
#' @noRd
sv_lazy_key_names <- function(n) paste0(".sv_k", seq_len(n))

#' The text fix a join hint applies to a key, as an expression
#' @noRd
sv_lazy_fix_expr <- function(fix, e) {
  txt <- rlang::expr(as.character(!!e))
  switch(fix,
    # duckdb's trim() strips spaces only; R's trimws() strips [ \t\r\n]
    trim = rlang::expr(trim(!!txt, !!" \t\r\n")),
    case = rlang::expr(tolower(!!txt)),
    zeros = rlang::expr(regexp_replace(!!txt, "^0+([0-9])", "\\1")),
    stop("Unknown fix: ", fix)
  )
}

#' One side of a join check, with its key columns made comparable
#'
#' Adds `.sv_k1`, `.sv_k2`, ... (and `.sv_row` when `row` is true). A key is the
#' column itself, with NaN turned into NULL because R counts NaN as missing and
#' duckdb sorts it as a number. When the two sides differ in type, a key is
#' compared as the text R would give it (`text`). A `fix` is applied to the
#' character keys (`chr`) only, as the in-memory hints do.
#' @param tbl A duckdb tbl.
#' @param cols Key column names.
#' @param kinds `sv_lazy_kind()` of each key column.
#' @param text,chr Logical per key: compare as text, is a character key.
#' @param fix `NULL`, `"trim"`, `"case"` or `"zeros"`.
#' @param row Add `.sv_row`, the row number in table order.
#' @param tzs Time zone of each key (`NA` for a key that is not a POSIXct), used
#'   when the key is compared as text.
#' @noRd
sv_lazy_join_side <- function(tbl, cols, kinds, text, chr, fix = NULL, row = FALSE, tzs = NULL) {
  kn <- sv_lazy_key_names(length(cols))
  if (row) tbl <- dplyr::mutate(tbl, .sv_row = row_number())
  step1 <- Map(function(col, kind) {
    s <- rlang::sym(col)
    if (identical(kind, "double")) rlang::expr(if_else(isnan(!!s), NA, !!s)) else s
  }, cols, kinds)
  names(step1) <- kn
  tbl <- dplyr::mutate(tbl, !!!step1)
  step2 <- list()
  for (i in seq_along(cols)) {
    k <- rlang::sym(kn[i])
    e <- k
    if (text[i]) e <- sv_lazy_text_expr(k, kinds[i], if (is.null(tzs) || is.na(tzs[i])) NULL else tzs[[i]])
    if (!is.null(fix) && chr[i]) e <- sv_lazy_fix_expr(fix, e)
    if (!identical(e, k)) step2[[kn[i]]] <- e
  }
  if (length(step2)) tbl <- dplyr::mutate(tbl, !!!step2)
  tbl
}

#' Both sides joined key by key, one row per distinct key
#'
#' `nx` / `ny` are the rows each side has for the key (NULL when it has none);
#' `fx` / `fy` the first row of that side, when it is named in `first`. `NA` matches `NA`
#' (`IS NOT DISTINCT FROM`), as in the in-memory check.
#' @noRd
sv_lazy_join_keys <- function(sx, sy, nk, first = NULL) {
  kn <- sv_lazy_key_names(nk)
  ks <- rlang::syms(kn)
  per_side <- function(side, n, f, which) {
    aggs <- list(rlang::expr(n()))
    names(aggs) <- n
    if (which %in% first) aggs[[f]] <- rlang::expr(min(.sv_row, na.rm = TRUE))
    dplyr::summarise(dplyr::group_by(side, !!!ks), !!!aggs, .groups = "drop")
  }
  dplyr::full_join(per_side(sx, "nx", "fx", "x"), per_side(sy, "ny", "fy", "y"), by = kn, na_matches = "na")
}

#' The scalars of the join arithmetic, from one SQL aggregate
#'
#' Never collects the per-key counts: they can be as large as the tables.
#' @return The list `sv_join_counts_from()` takes.
#' @noRd
sv_lazy_join_scalars <- function(sx, sy, nk) {
  j <- sv_lazy_join_keys(sx, sy, nk)
  agg <- dplyr::summarise(
    j,
    distinct_x = sum(if_else(is.na(nx), 0, 1), na.rm = TRUE),
    distinct_y = sum(if_else(is.na(ny), 0, 1), na.rm = TRUE),
    distinct_matched = sum(if_else(is.na(nx) | is.na(ny), 0, 1), na.rm = TRUE),
    matched_x = sum(if_else(is.na(ny), 0, nx), na.rm = TRUE),
    matched_y = sum(if_else(is.na(nx), 0, ny), na.rm = TRUE),
    dup_keys_x = sum(if_else(nx > 1, 1, 0), na.rm = TRUE),
    dup_keys_y = sum(if_else(ny > 1, 1, 0), na.rm = TRUE),
    many_x = sum(if_else(nx > 1 & !is.na(ny), 1, 0), na.rm = TRUE),
    many_y = sum(if_else(ny > 1 & !is.na(nx), 1, 0), na.rm = TRUE),
    inner = sum(if_else(is.na(nx) | is.na(ny), 0, as.double(nx) * as.double(ny)), na.rm = TRUE)
  )
  r <- dplyr::collect(agg)
  # an empty join sums to NULL
  num <- function(v) if (length(v) == 0L || is.na(v)) 0 else as.numeric(v)
  count <- function(v) {
    v <- num(v)
    if (v <= .Machine$integer.max) as.integer(v) else v
  }
  list(
    distinct_x = count(r$distinct_x), distinct_y = count(r$distinct_y),
    distinct_matched = count(r$distinct_matched),
    matched_x = count(r$matched_x), matched_y = count(r$matched_y),
    dup_keys_x = count(r$dup_keys_x), dup_keys_y = count(r$dup_keys_y),
    many_x = num(r$many_x) > 0, many_y = num(r$many_y) > 0,
    inner = num(r$inner)
  )
}

#' Row count and rows with a missing key, for one side
#' @noRd
sv_lazy_join_side_counts <- function(side, nk) {
  any_na <- sv_lazy_any_na_expr(nk)
  r <- dplyr::collect(dplyr::summarise(
    side, n = n(), na = sum(if_else(!!any_na, 1, 0), na.rm = TRUE)
  ))
  list(n = as.numeric(r$n), na = if (is.na(r$na)) 0 else as.numeric(r$na))
}

#' Is any key part missing? (an expression over `.sv_k1`, `.sv_k2`, ...)
#' @noRd
sv_lazy_any_na_expr <- function(nk) {
  Reduce(function(a, b) rlang::expr((!!a) | (!!b)),
         lapply(rlang::syms(sv_lazy_key_names(nk)), function(s) rlang::expr(is.na(!!s))))
}

#' Collected keys as the check shows them
#'
#' A POSIXct key is shown in its own zone, as the in-memory check does.
#' @param keys A data frame of the key columns.
#' @param tzs Time zone of each key, `NA` if it has none.
#' @noRd
sv_lazy_decode_keys <- function(keys, tzs = NULL) {
  if (!nrow(keys)) return(character(0))
  for (i in seq_along(keys)) {
    if (!is.null(tzs) && !is.na(tzs[i]) && inherits(keys[[i]], "POSIXct")) attr(keys[[i]], "tzone") <- tzs[[i]]
  }
  sv_join_decode(sv_join_keys(keys))
}

#' Up to `n` keys of one side that the other side lacks, as the check shows them
#'
#' In order of first appearance (`LIMIT n`, ordered by the first row), which is
#' the order `unique()` gives in R. `sx` / `sy` need `.sv_row` on the sampled side.
#' @param tzs Time zone of each key of the sampled side, `NA` if it has none.
#' @noRd
sv_lazy_join_sample <- function(sx, sy, nk, side, n, tzs = NULL) {
  kn <- sv_lazy_key_names(nk)
  j <- sv_lazy_join_keys(sx, sy, nk, first = side)
  j <- if (identical(side, "x")) {
    dplyr::arrange(dplyr::filter(j, is.na(ny)), fx)
  } else {
    dplyr::arrange(dplyr::filter(j, is.na(nx)), fy)
  }
  keys <- dplyr::collect(utils::head(dplyr::select(j, dplyr::all_of(kn)), n))
  sv_lazy_decode_keys(keys, tzs)
}

#' One side of a rule check: keys, row tag and the rule's columns of that side
#'
#' The twin of the columns `sv_join_rule_pairs()` puts on its two tables. `x`
#' gets `.sv_rx` and `.sv_xa` (with `.sv_xb` for an overlap or a window, whose
#' bounds are the window's ends), `y` gets `.sv_ry` and `.sv_ya` (with `.sv_yb`
#' for between and overlaps). A date-time becomes the `TIMESTAMP` of its UTC
#' instant, `make_timestamp(epoch_us(col))`, so a duckdb table and an Arrow table
#' (`TIMESTAMPTZ`) compare as instants whatever the session `TimeZone` (a plain
#' cast of a `TIMESTAMPTZ` uses that zone once the ICU extension is loaded). A
#' window adds whole days to it (`days()`; `TIMESTAMPTZ - INTERVAL` has no
#' binding without ICU) and integer days to a Date (`DATE - DECIMAL` has none
#' either). A plain double has NaN made NULL, as R counts it missing.
#' @param side From `sv_lazy_join_side(row = TRUE)`.
#' @param rule A normalised, valid rule.
#' @param which `"x"` or `"y"`.
#' @param kind The rule's kind: `"Date"`, `"date-time"` or `"numeric"`.
#' @param dbl Named logical: which rule columns of this side are plain doubles.
#' @param nk Number of key columns.
#' @param all_cols Keep every column of `side` (derived rows) and add the rule's, with no row tag.
#' @noRd
sv_lazy_rule_side <- function(side, rule, which, kind, dbl, nk, all_cols = FALSE) {
  val <- function(col) {
    s <- rlang::sym(col)
    if (identical(kind, "date-time")) {
      rlang::expr(make_timestamp(epoch_us(!!s)))
    } else if (isTRUE(dbl[col])) {
      rlang::expr(if_else(isnan(!!s), NA, !!s))
    } else {
      s
    }
  }
  shift <- function(col, n) {
    v <- val(col)
    if (n == 0) return(v)
    amount <- switch(kind,
      Date = as.integer(abs(n)),
      `date-time` = rlang::expr(days(!!as.integer(abs(n)))),
      sv_lazy_lit(abs(n)))
    if (n < 0) rlang::expr(!!v - !!amount) else rlang::expr(!!v + !!amount)
  }
  cols <- if (identical(which, "x")) {
    switch(rule$shape,
      overlaps = list(.sv_xa = val(rule$xFrom), .sv_xb = val(rule$xTo)),
      window = list(.sv_xa = shift(rule$xCol, rule$from), .sv_xb = shift(rule$xCol, rule$to)),
      list(.sv_xa = val(rule$xCol)))
  } else {
    switch(rule$shape,
      between = ,
      overlaps = list(.sv_ya = val(rule$yFrom), .sv_yb = val(rule$yTo)),
      list(.sv_ya = val(rule$yCol)))
  }
  side <- dplyr::mutate(side, !!!cols)
  if (all_cols) return(side)
  row <- stats::setNames(".sv_row", if (identical(which, "x")) ".sv_rx" else ".sv_ry")
  dplyr::select(side, dplyr::all_of(c(sv_lazy_key_names(nk), row, names(cols))))
}

#' The `join_by()` of a rule: equal keys plus the rule's conditions
#'
#' The conditions are the ones `join_by()` expands `between()`, `overlaps()` and
#' the window into; before/after is the bare inequality (the nearest match is
#' picked afterwards). `first = "y"` writes them for a join with the y side as
#' the left table (`anti_join(y, x, ...)`).
#' @noRd
sv_lazy_rule_by <- function(nk, rule, first = "x") {
  keys <- lapply(rlang::syms(sv_lazy_key_names(nk)), function(k) rlang::expr(!!k == !!k))
  strict <- identical(rule$inclusive, FALSE)
  # each condition as (x column, operator, y column)
  conds <- switch(rule$shape,
    between = list(c(".sv_xa", ">=", ".sv_ya"), c(".sv_xa", "<=", ".sv_yb")),
    overlaps = list(c(".sv_xa", "<=", ".sv_yb"), c(".sv_xb", ">=", ".sv_ya")),
    window = list(c(".sv_xa", "<=", ".sv_ya"), c(".sv_xb", ">=", ".sv_ya")),
    before = list(c(".sv_xa", if (strict) ">" else ">=", ".sv_ya")),
    after = list(c(".sv_xa", if (strict) "<" else "<=", ".sv_ya")))
  flip <- c(">=" = "<=", "<=" = ">=", ">" = "<", "<" = ">")
  conds <- lapply(conds, function(cnd) {
    if (identical(first, "x")) {
      rlang::call2(cnd[2], rlang::sym(cnd[1]), rlang::sym(cnd[3]))
    } else {
      rlang::call2(flip[[cnd[2]]], rlang::sym(cnd[3]), rlang::sym(cnd[1]))
    }
  })
  rlang::inject(dplyr::join_by(!!!c(keys, conds)))
}

#' The row pairs a date rule joins, as a lazy tbl of `(.rx, .ry)`
#'
#' The twin of `sv_join_rule_pairs()`, run by duckdb. The keys are joined with
#' `na_matches = "never"` (a missing key, or a missing date, matches nothing).
#' dbplyr has no `closest()`, so a nearest match joins on the inequality and
#' keeps, per x row, the y rows at the latest (before) or earliest (after) date:
#' all of them on a tie, as `closest()` does.
#'
#' The row tags are `ROW_NUMBER() OVER ()`, which numbers a derived table (a
#' join, say) in a different order each time a query evaluates it. Use `.rx` /
#' `.ry` only within the query that builds the pairs (counts, as in
#' `sv_lazy_rule_scalars()`); never match them against tags of another
#' evaluation (`sv_lazy_rule_lone()` finds the rows without a pair without them).
#' @param side_x,side_y From `sv_lazy_rule_side()`.
#' @param nk Number of key columns.
#' @param rule A normalised, valid rule.
#' @noRd
sv_lazy_rule_pairs <- function(side_x, side_y, nk, rule) {
  p <- dplyr::inner_join(side_x, side_y, by = sv_lazy_rule_by(nk, rule), na_matches = "never")
  if (rule$shape %in% c("before", "after")) {
    p <- dplyr::ungroup(dplyr::filter(dplyr::group_by(p, .sv_rx), .sv_ya == !!sv_lazy_rule_near(rule)))
  }
  dplyr::select(p, .rx = .sv_rx, .ry = .sv_ry)
}

#' The nearest y date of a before / after rule, as an aggregate of `.sv_ya`
#' @noRd
sv_lazy_rule_near <- function(rule) {
  if (rule$shape == "before") rlang::expr(max(.sv_ya, na.rm = TRUE)) else rlang::expr(min(.sv_ya, na.rm = TRUE))
}

#' The scalars `sv_join_rule_core()` takes, from one aggregate over the pairs
#' @param pairs From `sv_lazy_rule_pairs()`.
#' @noRd
sv_lazy_rule_scalars <- function(pairs) {
  counted <- dplyr::group_by(pairs, .rx)
  counted <- dplyr::mutate(counted, .sv_cx = n())
  counted <- dplyr::mutate(dplyr::group_by(dplyr::ungroup(counted), .ry), .sv_cy = n())
  r <- dplyr::collect(dplyr::summarise(
    dplyr::ungroup(counted),
    matched_x = n_distinct(.rx), matched_y = n_distinct(.ry),
    max_cx = max(.sv_cx, na.rm = TRUE), max_cy = max(.sv_cy, na.rm = TRUE),
    inner = n()
  ))
  list(
    matched_x = sv_lazy_count(sv_lazy_num0(r$matched_x)), matched_y = sv_lazy_count(sv_lazy_num0(r$matched_y)),
    # an x row with several pairs makes y the "many" side, and the reverse
    many_x = sv_lazy_num0(r$max_cy) > 1, many_y = sv_lazy_num0(r$max_cx) > 1,
    inner = sv_lazy_num0(r$inner)
  )
}

#' The rows of one side that a date rule pairs with nothing, as a lazy tbl
#'
#' Found by the rule's own conditions, not by row tags, so it holds for any
#' lazy source (see `sv_lazy_rule_pairs()`). An x row has a pair when some y
#' row meets the conditions; for before / after that is also when it has a
#' nearest one. A y row of a between / overlaps / window rule likewise. A y row
#' of a before / after rule has a pair when its date is the nearest date of
#' some x row with its key.
#' @param side_x,side_y From `sv_lazy_rule_side()`.
#' @param which `"x"` or `"y"`.
#' @noRd
sv_lazy_rule_lone <- function(side_x, side_y, nk, rule, which) {
  if (identical(which, "x")) {
    return(dplyr::anti_join(side_x, side_y, by = sv_lazy_rule_by(nk, rule, "x"), na_matches = "never"))
  }
  if (!rule$shape %in% c("before", "after")) {
    return(dplyr::anti_join(side_y, side_x, by = sv_lazy_rule_by(nk, rule, "y"), na_matches = "never"))
  }
  kn <- rlang::syms(sv_lazy_key_names(nk))
  p <- dplyr::inner_join(side_x, side_y, by = sv_lazy_rule_by(nk, rule), na_matches = "never")
  near <- dplyr::summarise(dplyr::group_by(p, .sv_rx, !!!kn), .sv_near = !!sv_lazy_rule_near(rule), .groups = "drop")
  near <- dplyr::distinct(dplyr::select(near, !!!kn, .sv_near))
  keys <- lapply(kn, function(k) rlang::expr(!!k == !!k))
  by <- rlang::inject(dplyr::join_by(!!!c(keys, rlang::exprs(.sv_ya == .sv_near))))
  dplyr::anti_join(side_y, near, by = by, na_matches = "never")
}

#' Up to `n` keys of the rows of one side without a rule pair, in order of first row
#'
#' The row tag only orders the sample, within this one query.
#' @param lone From `sv_lazy_rule_lone()`.
#' @param row Its row tag: `".sv_rx"` or `".sv_ry"`.
#' @param tzs Time zone of each key, `NA` if it has none.
#' @noRd
sv_lazy_rule_sample <- function(lone, nk, row, n, tzs = NULL) {
  kn <- sv_lazy_key_names(nk)
  first <- dplyr::summarise(dplyr::group_by(lone, !!!rlang::syms(kn)), .sv_first = min(!!rlang::sym(row), na.rm = TRUE),
                            .groups = "drop")
  # LIMIT right after ORDER BY (a select in between would drop the order); sorted again in R
  keys <- dplyr::collect(utils::head(dplyr::arrange(first, .sv_first), n))
  keys <- as.data.frame(keys)[order(keys$.sv_first), kn, drop = FALSE]
  sv_lazy_decode_keys(keys, tzs)
}


#' The R classes of some columns of a table of any origin, from 0 rows
#'
#' Columns that are not in the table are left out.
#' @noRd
sv_lazy_zero <- function(x, cols) {
  cols <- intersect(unique(cols), sv_lazy_names(x))
  if (is.data.frame(x)) return(x[0L, cols, drop = FALSE])
  if (!length(cols)) return(data.frame())
  dplyr::collect(utils::head(dplyr::select(x, dplyr::all_of(cols)), 0L))
}

#' Join check over the whole tables, run by duckdb
#'
#' The twin of [sv_join_diagnostics()]: the same reply for the same data. The
#' tables are placed on one connection (see `sv_lazy_place()`); the counts come
#' back as one aggregate row, plus at most `sample_n` unmatched keys per side.
#' Whatever was added to a user's connection is removed again, also on error.
#'
#' With a `rule`, the row pairs are joined in duckdb (`sv_lazy_rule_pairs()`)
#' and only one aggregate over them, plus the unmatched samples, come back.
#' @inheritParams sv_join_diagnostics
#' @param con_env An environment from `sv_lazy_env()` holding the private
#'   connection (used when neither side is a duckdb table). When omitted, a
#'   private connection is opened for this call and closed again.
#' @param rule Optional date rule, as for [sv_join_diagnostics()]; checked with
#'   `sv_join_rule_problem()` before anything is placed.
#' @return An `sv_join_diagnostics` object.
#' @noRd
sv_lazy_join_diagnostics <- function(x, y, by, sample_n = 5L, x_name = "x", y_name = "y",
                                     con_env = sv_lazy_env(), rule = NULL) {
  own_env <- missing(con_env)
  force(con_env)
  if (own_env) on.exit(sv_lazy_close(con_env), add = TRUE)
  if (!is.character(by) || !length(by)) stop("`by` must name at least one key column.", call. = FALSE)
  by_x <- if (is.null(names(by))) by else ifelse(nzchar(names(by)), names(by), by)
  by_y <- unname(by)
  miss_x <- setdiff(by_x, sv_lazy_names(x))
  miss_y <- setdiff(by_y, sv_lazy_names(y))
  if (length(miss_x)) stop(sprintf("Not in %s: %s", x_name, paste(miss_x, collapse = ", ")), call. = FALSE)
  if (length(miss_y)) stop(sprintf("Not in %s: %s", y_name, paste(miss_y, collapse = ", ")), call. = FALSE)

  rule_x <- rule_y <- character(0)
  if (!is.null(rule)) {
    # the rule's columns and kinds, from 0 rows (nothing placed yet)
    rs <- sv_lazy_rule_prepare(x, y, rule)
    rule <- rs$rule
    rule_x <- rs$rule_x
    rule_y <- rs$rule_y
    rule_kind <- rs$rule_kind
    dbl_x <- rs$dbl_x
    dbl_y <- rs$dbl_y
  }

  placed <- sv_lazy_place(x, y, con_env, cols_x = c(by_x, rule_x), cols_y = c(by_y, rule_y))
  on.exit(placed$cleanup(), add = TRUE, after = FALSE)

  # the R classes of the key columns, from 0 rows
  zx <- dplyr::collect(utils::head(dplyr::select(placed$x, dplyr::all_of(unique(by_x))), 0L))
  zy <- dplyr::collect(utils::head(dplyr::select(placed$y, dplyr::all_of(unique(by_y))), 0L))
  type_issues <- sv_join_type_issues(zx, zy, by_x, by_y, x_name, y_name)
  kind_x <- vapply(by_x, function(cn) sv_key_kind(zx[[cn]]), "")
  kind_y <- vapply(by_y, function(cn) sv_key_kind(zy[[cn]]), "")
  # keys of different types are compared as text, the way the in-memory check does
  text <- kind_x != kind_y
  lazy_x <- vapply(by_x, function(cn) sv_lazy_kind(zx[[cn]]), "")
  lazy_y <- vapply(by_y, function(cn) sv_lazy_kind(zy[[cn]]), "")
  nk <- length(by_x)
  # zone of each POSIXct key (UTC when the table kept none), NA for other keys
  key_tzs <- function(tbl, z, by) {
    vapply(by, function(cn) {
      if (inherits(z[[cn]], "POSIXct")) sv_lazy_zone_for(attr(tbl, "sv_tz"), cn) else NA_character_
    }, "", USE.NAMES = FALSE)
  }
  tz_x <- key_tzs(placed$x, zx, by_x)
  tz_y <- key_tzs(placed$y, zy, by_y)
  side_x <- function(fix = NULL, row = FALSE) {
    sv_lazy_join_side(placed$x, by_x, lazy_x, text, kind_x == "character", fix, row, tz_x)
  }
  side_y <- function(fix = NULL, row = FALSE) {
    sv_lazy_join_side(placed$y, by_y, lazy_y, text, kind_y == "character", fix, row, tz_y)
  }

  cnt_x <- sv_lazy_join_side_counts(side_x(), nk)
  cnt_y <- sv_lazy_join_side_counts(side_y(), nk)
  n_x <- cnt_x$n
  n_y <- cnt_y$n
  s <- sv_lazy_join_scalars(side_x(), side_y(), nk)
  core <- sv_join_counts_from(s, n_x, n_y)
  n_show <- max(0L, as.integer(sample_n))

  if (is.null(rule)) {
    unmatched_x <- if (n_show && s$distinct_x > s$distinct_matched) {
      sv_lazy_join_sample(side_x(row = TRUE), side_y(), nk, "x", n_show, tz_x)
    } else {
      character(0)
    }
    unmatched_y <- if (n_show && s$distinct_y > s$distinct_matched) {
      sv_lazy_join_sample(side_x(), side_y(row = TRUE), nk, "y", n_show, tz_y)
    } else {
      character(0)
    }
  } else {
    rule_sides <- function(fix = NULL) {
      list(x = sv_lazy_rule_side(side_x(fix, row = TRUE), rule, "x", rule_kind, dbl_x, nk),
           y = sv_lazy_rule_side(side_y(fix, row = TRUE), rule, "y", rule_kind, dbl_y, nk))
    }
    pairs_for <- function(fix = NULL) {
      rs <- rule_sides(fix)
      sv_lazy_rule_pairs(rs$x, rs$y, nk, rule)
    }
    core <- sv_join_rule_core(sv_lazy_rule_scalars(pairs_for()), n_x, n_y, core,
                              rule$shape %in% c("before", "after"))
    # rows with a key partner (a missing key has none) but no rule pair
    no_na <- function(side) dplyr::filter(side, !(!!sv_lazy_any_na_expr(nk)))
    partner <- sv_lazy_join_scalars(no_na(side_x()), no_na(side_y()), nk)
    rule_dropped_x <- partner$matched_x - core$matched_x
    rule_dropped_y <- partner$matched_y - core$matched_y
    # the samples find their rows by the rule itself: row tags never cross queries (sv_lazy_rule_pairs())
    rs <- rule_sides()
    unmatched_x <- if (n_show && core$matched_x < n_x) {
      sv_lazy_rule_sample(sv_lazy_rule_lone(rs$x, rs$y, nk, rule, "x"), nk, ".sv_rx", n_show, tz_x)
    } else {
      character(0)
    }
    unmatched_y <- if (n_show && core$matched_y < n_y) {
      sv_lazy_rule_sample(sv_lazy_rule_lone(rs$x, rs$y, nk, rule, "y"), nk, ".sv_ry", n_show, tz_y)
    } else {
      character(0)
    }
  }

  out <- list(
    by = data.frame(x = by_x, y = by_y, stringsAsFactors = FALSE),
    n_x = sv_lazy_count(n_x), n_y = sv_lazy_count(n_y),
    distinct_x = core$distinct_x, distinct_y = core$distinct_y,
    distinct_matched = core$distinct_matched,
    matched_x = core$matched_x, matched_y = core$matched_y,
    match_rate_x = if (n_x) core$matched_x / n_x else 0,
    match_rate_y = if (n_y) core$matched_y / n_y else 0,
    na_x = sv_lazy_count(cnt_x$na), na_y = sv_lazy_count(cnt_y$na),
    dup_keys_x = core$dup_keys_x, dup_keys_y = core$dup_keys_y,
    relationship = core$relationship,
    rows = core$rows,
    unmatched_x = unmatched_x,
    unmatched_y = unmatched_y,
    type_issues = type_issues,
    hints = list(),
    x_name = x_name, y_name = y_name
  )
  out$strict_args <- sv_join_strict_args(core, n_x, n_y, rule)
  if (!is.null(rule)) {
    out$rule <- rule
    out$rule_kind <- rule_kind
    out$rule_dropped_x <- rule_dropped_x
    out$rule_dropped_y <- rule_dropped_y
  }

  # Fixes that would match more rows, each measured on its own against the raw keys
  # (with the rule applied, when there is one). Only character keys change, so a join
  # without one has nothing to fix.
  if ((core$matched_x < n_x || core$matched_y < n_y) &&
      any(c(kind_x, kind_y) == "character")) {
    labels <- c(trim = "trimming whitespace", case = "ignoring case", zeros = "dropping leading zeros")
    for (nm in names(labels)) {
      alt <- if (is.null(rule)) {
        sv_lazy_join_scalars(side_x(nm), side_y(nm), nk)
      } else {
        sv_lazy_rule_scalars(pairs_for(nm))
      }
      extra_x <- alt$matched_x - core$matched_x
      extra_y <- alt$matched_y - core$matched_y
      if (extra_x > 0 || extra_y > 0) {
        out$hints[[length(out$hints) + 1L]] <- list(
          fix = nm, label = unname(labels[nm]), extra_x = extra_x, extra_y = extra_y
        )
      }
    }
  }

  out$warnings <- sv_join_warnings(out, x_name, y_name)
  out$status <- if (length(out$type_issues)) "error" else if (length(out$warnings)) "warn" else "ok"
  structure(out, class = "sv_join_diagnostics")
}

#' The SUPP rows of one parent domain, collected
#'
#' A data frame is returned as is. A lazy SUPP table is filtered on `RDOMAIN` (when it has
#' that column) before it is collected, and only the columns the check reads come back; the
#' number of rows the filter dropped is counted by the database.
#' @param all_cols Keep every column of a lazy SUPP, in its order (derived rows), not just those the check reads.
#' @return `list(data, n_other)`; `n_other` is `NULL` for a data frame (the shared SUPP-side
#'   step counts it).
#' @noRd
sv_lazy_supp_rows <- function(supp, rdomain, all_cols = FALSE) {
  if (is.data.frame(supp)) return(list(data = supp, n_other = NULL))
  want <- c("STUDYID", "RDOMAIN", "USUBJID", "IDVAR", "IDVARVAL", "QNAM", "QLABEL", "QVAL")
  have <- if (all_cols) as.character(sv_lazy_names(supp)) else intersect(want, sv_lazy_names(supp))
  q <- dplyr::select(supp, dplyr::all_of(have))
  n_other <- 0L
  if ("RDOMAIN" %in% have) {
    total <- dplyr::collect(dplyr::summarise(q, n = dplyr::n()))$n
    rd <- rlang::sym("RDOMAIN")
    q <- dplyr::filter(q, !is.na(!!rd) & !!rd == !!rdomain)
  }
  data <- as.data.frame(dplyr::collect(q), stringsAsFactors = FALSE)
  if ("RDOMAIN" %in% have) n_other <- sv_lazy_count(total - nrow(data))
  list(data = data, n_other = n_other)
}

#' Which SUPP rows find a parent record, by a semi-join in duckdb
#'
#' The parent stays lazy. The SUPP key text (and the converted `IDVARVAL`) is handed to the
#' parent's connection (`sv_lazy_place()`), one level at a time is semi-joined, and only the
#' ids of the SUPP rows that matched come back. Key text and `NA` are treated as
#' `sv_supp_match_df()` does: a missing key is the text `"NA"`; numeric keys are compared as
#' numbers (the in-memory path compares their text, which agrees for ordinary values).
#' @noRd
sv_lazy_supp_match <- function(parent, side, conv, keys, types, con_env) {
  matched <- rep(FALSE, side$n_supp)
  kn <- sv_lazy_key_names(length(keys))
  rows <- which(!conv$bad)
  if (!length(rows)) return(matched)
  ykeys <- lapply(keys, function(k) {
    x <- sv_supp_key_chr(side$supp[[k]])[rows]
    x[is.na(x)] <- "NA"
    x
  })
  names(ykeys) <- kn
  lvl <- match(side$idvar[rows], side$levels)
  numeric_lvl <- vapply(side$levels, function(iv) nzchar(iv) && !identical(types[[iv]], "character"),
                        logical(1))
  y <- data.frame(ykeys, stringsAsFactors = FALSE)
  y$.sv_lvl <- lvl
  y$.sv_rid <- rows
  # full precision: conv$val is 15-digit text, which can miss a float32 key widened to double
  y$.sv_vn <- ifelse(numeric_lvl[lvl], conv$num[rows], NA_real_)
  y$.sv_vc <- ifelse(!numeric_lvl[lvl], conv$val[rows], NA_character_)
  ivs <- side$levels[nzchar(side$levels)]
  placed <- sv_lazy_place(parent, y, con_env, cols_x = c(keys, ivs))
  on.exit(placed$cleanup(), add = TRUE)

  txt <- function(k) rlang::expr(coalesce(as.character(!!rlang::sym(k)), "NA"))
  for (i in seq_along(side$levels)) {
    iv <- side$levels[i]
    yl <- dplyr::filter(placed$y, !!rlang::sym(".sv_lvl") == !!i)
    exprs <- stats::setNames(lapply(keys, txt), kn)
    by <- stats::setNames(kn, kn)
    if (nzchar(iv)) {
      if (numeric_lvl[i]) {
        exprs[[".sv_v"]] <- rlang::sym(iv)
        by <- c(by, .sv_vn = ".sv_v")
      } else {
        exprs[[".sv_v"]] <- txt(iv)
        by <- c(by, .sv_vc = ".sv_v")
      }
    }
    px <- dplyr::transmute(placed$x, !!!exprs)
    hit <- dplyr::collect(dplyr::select(dplyr::semi_join(yl, px, by = by), dplyr::all_of(".sv_rid")))
    matched[hit$.sv_rid] <- TRUE
  }
  matched
}

#' An Arrow int64 / uint64 IDVAR key is a double key
#'
#' Arrow collects int64 to an R integer when every value fits and to integer64 when one does
#' not, so 0 rows always say "integer" and the key type would depend on the data. It is a
#' double key, as an integer64 in memory (`sv_supp_key_type()`) and duckdb's BIGINT (which
#' collects to double) are, so `IDVARVAL` past the integer range converts.
#' @noRd
sv_lazy_supp_wide_int <- function(x, types) {
  ivs <- names(types)[types == "integer"]
  if (!length(ivs) || !inherits(x, c("ArrowTabular", "Dataset", "arrow_dplyr_query"))) return(types)
  sch <- tryCatch(arrow::as_arrow_table(utils::head(dplyr::select(x, dplyr::all_of(ivs)), 0L))$schema,
                  error = function(e) NULL)
  if (is.null(sch)) return(types)
  for (iv in ivs) {
    if (sch[[iv]]$type$ToString() %in% c("int64", "uint64")) types[iv] <- "double"
  }
  types
}

#' SUPP merge check over a lazy parent and/or SUPP table
#'
#' The twin of [sv_supp_check()]: the same reply for the same data. Every SUPP-side step is
#' the one `sv_supp_check_df()` uses (`sv_supp_side()`, `sv_supp_types()`,
#' `sv_supp_convert_side()`, `sv_supp_finish()`); only the parent-side facts are computed
#' here without collecting the parent: the key types from 0 rows, `n_parent` from a count,
#' the matches by a semi-join (`sv_lazy_supp_match()`) and the preview from `head()`.
#' A lazy SUPP is filtered on `RDOMAIN` and then collected, as the check is per SUPP row.
#' @param parent,supp Data frames, duckdb tables or Arrow objects.
#' @param con_env An environment from `sv_lazy_env()`; when omitted a private connection is
#'   opened for this call and closed again.
#' @inheritParams sv_supp_check
#' @noRd
sv_lazy_supp_check <- function(parent, supp, parent_name = "parent", supp_name = "supp",
                               rdomain = NULL, plan = NULL, sample_n = 5L,
                               con_env = sv_lazy_env()) {
  own_env <- missing(con_env)
  force(con_env)
  if (own_env) on.exit(sv_lazy_close(con_env), add = TRUE)
  sample_n <- as.integer(sample_n)
  from_name <- sub("^SUPP", "", toupper(supp_name))
  if (is.null(rdomain)) rdomain <- from_name

  supp_cols <- sv_lazy_names(supp)
  classify <- function(chk) sv_supp_classify(chk, parent_name, supp_name)
  err <- sv_supp_cols_error(supp_cols, supp_name)
  if (!is.null(err)) return(classify(err))
  parent_names <- sv_lazy_names(parent)
  if (!"USUBJID" %in% parent_names) return(classify(list(error = paste0("Not in ", parent_name, ": USUBJID"))))

  rows <- sv_lazy_supp_rows(supp, rdomain)
  side <- sv_supp_side(rows$data, supp_name, rdomain)
  if (!is.null(side$error)) return(classify(side))
  if (!is.null(rows$n_other)) side$n_other <- rows$n_other

  levels_ <- side$levels[nzchar(side$levels)]
  keys <- intersect(c("STUDYID", "USUBJID"), intersect(parent_names, supp_cols))
  types <- sv_supp_types(side$levels, sv_lazy_zero(parent, c(levels_, keys)), parent_name)
  if (is.list(types)) return(classify(types))
  types <- sv_lazy_supp_wide_int(parent, types)
  conv <- sv_supp_convert_side(side, types, keys)

  matched <- if (is.data.frame(parent)) {
    sv_supp_match_df(side, conv, parent, keys)
  } else {
    sv_lazy_supp_match(parent, side, conv, keys, types, con_env)
  }
  if (is.data.frame(parent)) {
    n_parent <- nrow(parent)
    pv <- utils::head(parent, sample_n)
  } else {
    n_parent <- sv_lazy_count(dplyr::collect(dplyr::summarise(parent, n = dplyr::n()))$n)
    pv <- as.data.frame(dplyr::collect(utils::head(parent, sample_n)), stringsAsFactors = FALSE)
  }
  classify(sv_supp_finish(side, conv, matched, types, keys, parent_names, n_parent, pv, plan, sample_n,
                          from_name == rdomain))
}

#' A double as an exact SQL literal
#'
#' dbplyr writes a double with 15 significant digits, which would move a value
#' by an ulp. 17 digits in scientific notation round-trip and duckdb reads them
#' as DOUBLE (a plain `0.3` would be a DECIMAL).
#' @param x A finite number.
#' @noRd
sv_lazy_lit <- function(x) dplyr::sql(sprintf("(%.17e)", x))

# a SQL aggregate that is NULL on no rows, as a plain number
sv_lazy_num0 <- function(v) if (length(v) == 0L || is.na(v)) 0 else as.numeric(v)

#' The one column to profile, as `.sv_v`
#'
#' Missing is NULL; for a plain double NaN is made NULL too, because R counts
#' NaN as missing and duckdb sorts it as a number. A factor / enum is text.
#' @param tbl A duckdb tbl.
#' @param column Column name.
#' @param zero A 0-row `collect()` of the column, for its R class.
#' @noRd
sv_lazy_profile_base <- function(tbl, column, zero) {
  b <- dplyr::select(tbl, .sv_v = dplyr::all_of(column))
  v <- rlang::sym(".sv_v")
  if (is.factor(zero)) {
    b <- dplyr::mutate(b, .sv_v = as.character(!!v))
  } else if (identical(sv_lazy_kind(zero), "double")) {
    b <- dplyr::mutate(b, .sv_v = if_else(isnan(!!v), NA, !!v))
  }
  b
}

#' The text key a value is counted under, as in the in-memory profile
#' @noRd
sv_lazy_key_expr <- function(kind) {
  v <- rlang::sym(".sv_v")
  if (kind == "logical") sv_lazy_text_expr(v, "logical") else if (kind == "character") v else
    rlang::expr(as.character(!!v))
}

#' Counts behind the data-quality flags of one column, from the database
#'
#' The twin of `sv_issue_counts()`: same names, same types. The texts come
#' from `sv_format_issues()`.
#' @param tbl A duckdb tbl holding `column`.
#' @param column Column name.
#' @param kind From `sv_profile_kind()`.
#' @param p The profile built so far (`n`, `n_missing` and, for numbers, `stats`).
#' @param base For internal use: the result of `sv_lazy_profile_base()`.
#' @noRd
sv_lazy_issue_counts <- function(tbl, column, kind, p, base = NULL) {
  out <- list(spaced = 0L, empty = 0L, variants_n = 0L, variants_eg = character(0),
              numeric_text = FALSE, far_n = 0L, far_eg = numeric(0))
  if (p$n == 0L || p$n_missing == p$n) return(out)
  if (is.null(base)) {
    zero <- dplyr::collect(utils::head(dplyr::select(tbl, dplyr::all_of(column)), 0L))[[1]]
    base <- sv_lazy_profile_base(tbl, column, zero)
  }
  v <- rlang::sym(".sv_v")
  present <- dplyr::filter(base, !is.na(!!v))

  if (kind == "character") {
    # duckdb's trim() strips spaces only; R's trimws() strips [ \t\r\n]
    trimmed <- rlang::expr(trim(!!v, !!sv_trim_chars))
    t <- rlang::sym(".sv_t")
    r <- dplyr::collect(dplyr::summarise(
      dplyr::mutate(present, .sv_t = !!trimmed),
      spaced = sum(if_else(!!v != !!t, 1, 0), na.rm = TRUE),
      empty = sum(if_else(!!v == "", 1, 0), na.rm = TRUE),
      nonblank = sum(if_else(!!t != "", 1, 0), na.rm = TRUE),
      numtext = sum(if_else(!!t != "" & regexp_full_match(!!t, !!sv_numeric_text_regex), 1, 0),
                    na.rm = TRUE)
    ))
    out$spaced <- sv_lazy_count(sv_lazy_num0(r$spaced))
    out$empty <- sv_lazy_count(sv_lazy_num0(r$empty))
    nonblank <- sv_lazy_num0(r$nonblank)
    out$numeric_text <- nonblank > 0 && sv_lazy_num0(r$numtext) == nonblank

    # values that differ only in case or spacing: groups of distinct values
    # Caveat: duckdb's lower() and R's tolower() can fold non-ASCII letters
    # differently (a locale or Unicode-version matter), so variant groups of
    # non-ASCII text may rarely differ from the in-memory count.
    folded <- dplyr::mutate(dplyr::distinct(present), .sv_f = lower(trim(!!v, !!sv_trim_chars)))
    f <- rlang::sym(".sv_f")
    groups <- dplyr::filter(
      dplyr::summarise(dplyr::group_by(folded, !!f), .sv_k = n(), .groups = "drop"),
      .sv_k > 1
    )
    g <- dplyr::collect(dplyr::summarise(groups, variants_n = n(), first = min(!!f, na.rm = TRUE)))
    nvar <- sv_lazy_num0(g$variants_n)
    if (nvar > 0) {
      out$variants_n <- sv_lazy_count(nvar)
      first <- g$first
      eg <- sv_lazy_first(dplyr::filter(folded, !!f == !!first), list(v), 3L)
      out$variants_eg <- as.character(eg[[".sv_v"]])
    }
  }

  if (kind == "numeric" && !is.null(p$stats)) {
    iqr <- p$stats$q3 - p$stats$q1
    if (is.finite(iqr) && iqr > 0) {
      fin <- sv_lazy_finite(present, sv_lazy_is_double(base))
      lo <- sv_lazy_lit(p$stats$q1 - 3 * iqr)
      hi <- sv_lazy_lit(p$stats$q3 + 3 * iqr)
      far <- dplyr::filter(fin, !!v < !!lo | !!v > !!hi)
      nfar <- sv_lazy_num0(dplyr::collect(dplyr::summarise(far, n = n()))$n)
      if (nfar > 0) {
        out$far_n <- sv_lazy_count(nfar)
        eg <- sv_lazy_first(dplyr::distinct(far), list(rlang::expr(desc(!!v))), 3L)
        out$far_eg <- as.numeric(eg[[".sv_v"]])
      }
    }
  }
  out
}

#' The first `k` rows of a lazy tbl in the order of `keys`, collected
#'
#' A window rank, not `arrange()` + `head()`: duckdb turns the latter into a
#' top-N whose dynamic filter an Arrow scan of an integer or text column
#' rejects ("Dynamic Filter not supported yet"). Ties keep no order, so `keys`
#' must be unique per row.
#' @param keys A list of symbols or `desc()` calls.
#' @noRd
sv_lazy_first <- function(tbl, keys, k) {
  ranked <- dplyr::mutate(dbplyr::window_order(tbl, !!!keys), .sv_rk = row_number())
  dplyr::collect(dplyr::arrange(dplyr::filter(ranked, .sv_rk <= !!as.integer(k)), .sv_rk))
}

# is the profiled column a plain double (it can hold Inf and NaN)?
sv_lazy_is_double <- function(base) {
  identical(sv_lazy_kind(dplyr::collect(utils::head(base, 0L))[[1]]), "double")
}

# rows with a finite value; an integer column has no Inf to drop
sv_lazy_finite <- function(present, is_double) {
  if (is_double) dplyr::filter(present, isfinite(.sv_v)) else present
}

#' Column inspector over the whole lazy table, run by duckdb
#'
#' The twin of `sv_column_profile()`: the same list for the same data. Each
#' step is an aggregate or a bounded result (`top_n` values, a histogram, up to
#' five order statistics, up to three examples), so the column is never
#' collected. Quartiles are `quantile_cont()`, which is R's `type = 7`. A date or
#' date-time takes the order statistic at `ceiling(n * p)`, as the in-memory
#' profile does. The issue texts are built from counts by `sv_format_issues()`.
#' @param tbl A duckdb tbl, or an Arrow table / dataset (handed to duckdb on the
#'   private connection of `con_env`, and removed again).
#' @param column Name of the column to profile.
#' @inheritParams sv_column_profile
#' @param con_env An environment from `sv_lazy_env()`. When omitted, a private
#'   connection is opened for this call and closed again.
#' @return The list `sv_column_profile()` returns (`label` is `NULL`).
#' @noRd
sv_lazy_column_profile <- function(tbl, column, top_n = 10L, bins = 20L, con_env = sv_lazy_env()) {
  own_env <- missing(con_env)
  force(con_env)
  if (own_env) on.exit(sv_lazy_close(con_env), add = TRUE)
  if (!is.character(column) || length(column) != 1L || is.na(column)) {
    stop("`column` must be one column name.", call. = FALSE)
  }
  if (!column %in% sv_lazy_names(tbl)) stop(sprintf("Not in table: %s", column), call. = FALSE)
  if (inherits(tbl, "tbl_lazy") && !inherits(tbl, "tbl_duckdb_connection")) {
    rlang::abort("The column inspector needs a duckdb table; this table is on another database.",
                 class = "sv_lazy_not_duckdb")
  }
  if (!inherits(tbl, "tbl_lazy")) {
    # an Arrow object: only this column goes to duckdb, and it is unregistered after
    # (the levels are not needed here, so no dictionary is read)
    tbl <- sv_lazy_tbl(dplyr::select(tbl, dplyr::all_of(column)), con_env, levels = FALSE)
    name <- dbplyr::remote_name(tbl)
    on.exit(sv_lazy_detach_arrow(sv_lazy_con(con_env), name), add = TRUE, after = FALSE)
  }
  # read before any verb: dplyr drops the attributes. duckdb gets a decoded
  # dictionary as text and a timestamp without its zone, so the class (factor /
  # ordered) and the zone come from what sv_lazy_tbl() recorded from the Arrow schema.
  zones <- attr(tbl, "sv_tz")
  factors <- attr(tbl, "sv_factors")

  top_n <- as.integer(top_n)
  bins <- as.integer(bins)
  zero <- dplyr::collect(utils::head(dplyr::select(tbl, dplyr::all_of(column)), 0L))[[1]]
  kind <- sv_profile_kind(zero)
  base <- sv_lazy_profile_base(tbl, column, zero)
  v <- rlang::sym(".sv_v")
  present <- dplyr::filter(base, !is.na(!!v))

  r <- dplyr::collect(dplyr::summarise(
    base,
    n = n(),
    n_missing = sum(if_else(is.na(!!v), 1, 0), na.rm = TRUE),
    n_distinct = n_distinct(!!v, na.rm = TRUE)
  ))
  n_all <- sv_lazy_num0(r$n)
  n_miss <- sv_lazy_num0(r$n_missing)
  n_present <- n_all - n_miss
  n_distinct <- sv_lazy_num0(r$n_distinct)
  n <- sv_lazy_count(n_all)

  out <- list(
    kind = kind,
    class = sv_lazy_class(zero, factors[[column]]),
    label = NULL,
    n = n,
    n_missing = sv_lazy_count(n_miss),
    pct_missing = if (n_all > 0) n_miss / n_all else 0,
    n_distinct = sv_lazy_count(n_distinct),
    unique_key = n_all > 0 && n_miss == 0 && n_distinct == n_all,
    stats = NULL,
    histogram = NULL,
    top = data.frame(value = character(0), n = integer(0), stringsAsFactors = FALSE),
    n_other = 0L,
    issues = character(0)
  )

  if (kind == "numeric" && n_present > 0) {
    fin <- sv_lazy_finite(present, identical(sv_lazy_kind(zero), "double"))
    moments <- function(with_sd) {
      sd_expr <- if (with_sd) rlang::expr(sd(!!v, na.rm = TRUE)) else NA_real_
      dplyr::collect(dplyr::summarise(
        fin,
        n = n(),
        q0 = quantile_cont(!!v, 0), q1 = quantile_cont(!!v, 0.25), q2 = quantile_cont(!!v, 0.5),
        q3 = quantile_cont(!!v, 0.75), q4 = quantile_cont(!!v, 1),
        mean = mean(!!v, na.rm = TRUE),
        sd = !!sd_expr
      ))
    }
    # duckdb's STDDEV_SAMP raises "out of range" where R returns Inf (the sum of
    # squares overflows), so a failure falls back to the scaled computation.
    s <- tryCatch(moments(TRUE), error = function(e) NULL)
    if (is.null(s)) {
      s <- moments(FALSE)
      s$sd <- sv_lazy_sd_scaled(fin, s$q0, s$q4)
    }
    n_fin <- sv_lazy_num0(s$n)
    if (n_fin > 0) {
      out$stats <- list(
        min = s$q0, q1 = s$q1, median = s$q2, q3 = s$q3, max = s$q4,
        mean = s$mean, sd = if (n_fin > 1) s$sd else NA_real_
      )
      out$histogram <- sv_lazy_histogram(fin, s$q0, s$q4, n_fin, bins)
    }
  } else if (kind %in% c("date", "datetime") && n_present > 0) {
    # the order statistic at ceiling(n * p), the way sv_column_profile() picks it
    pos <- pmax(1, ceiling(n_present * c(0.25, 0.5, 0.75)))
    want <- sort(unique(c(1, pos, n_present)))
    want <- if (all(want <= .Machine$integer.max)) as.integer(want) else want
    ranked <- dplyr::mutate(dbplyr::window_order(present, !!v), .sv_rn = row_number())
    rows <- dplyr::collect(dplyr::select(dplyr::filter(ranked, .sv_rn %in% !!want), !!v, .sv_rn))
    # Zone: duckdb hands the instants back as UTC, so they are re-tagged with the
    # zone recorded from the Arrow schema before formatting (the instant is
    # unchanged, the clock time is the one R shows). Without that record (a duckdb
    # table) the zone is UTC: duckdb here has no ICU extension, so it cannot tell
    # another zone.
    if (inherits(rows$.sv_v, "POSIXct")) attr(rows$.sv_v, "tzone") <- sv_lazy_zone_for(zones, column)
    pick <- function(p) format(rows$.sv_v[match(p, rows$.sv_rn)])
    out$stats <- list(min = pick(1), q1 = pick(pos[1]), median = pick(pos[2]),
                      q3 = pick(pos[3]), max = pick(n_present))
  }

  # A unique key has no common values worth listing.
  show_top <- kind %in% c("character", "logical", "other") || (kind == "numeric" && n_distinct <= top_n)
  if (show_top && n_distinct > 0 && !out$unique_key) {
    if (kind == "numeric") {
      tab <- sv_lazy_first(
        dplyr::summarise(dplyr::group_by(present, !!v), .sv_n = n(), .groups = "drop"),
        list(rlang::expr(desc(.sv_n)), v), top_n)
      shown <- vapply(as.numeric(tab[[".sv_v"]]), format_key, character(1))
    } else {
      keyed <- dplyr::mutate(present, .sv_k = !!sv_lazy_key_expr(kind))
      k <- rlang::sym(".sv_k")
      tab <- sv_lazy_first(
        dplyr::summarise(dplyr::group_by(keyed, !!k), .sv_n = n(), .groups = "drop"),
        list(rlang::expr(desc(.sv_n)), k), top_n)
      shown <- as.character(tab[[".sv_k"]])
    }
    out$top <- data.frame(value = shown, n = as.integer(tab$.sv_n), stringsAsFactors = FALSE)
    out$n_other <- sv_lazy_count(n_distinct - nrow(tab))
  }

  counts <- sv_lazy_issue_counts(tbl, column, kind, out, base = base)
  out$issues <- sv_format_issues(out, counts)
  sv_profile_classify(out, column)
}

#' The time zone of an Arrow timestamp type, or `NULL` when it has none
#' @noRd
sv_lazy_arrow_tz <- function(type) {
  if (is.null(type) || !inherits(type, "Timestamp")) return(NULL)
  tz <- tryCatch(type$timezone(), error = function(e) "")
  if (is.character(tz) && length(tz) == 1L && !is.na(tz) && nzchar(tz)) tz else NULL
}

#' The class `sv_column_profile()` reports for a lazy column
#'
#' The first class of the zero-row sample, except that an Arrow dictionary is
#' "ordered" or "factor" as in memory (the sample of the decoded column says
#' "character"). A duckdb ENUM has no order, so an ordered factor in duckdb is
#' reported as "factor", which is also what `collect()` gives for it.
#' @param fct The column's entry of the `sv_factors` attribute (see
#'   `sv_lazy_tbl()`), or `NULL`.
#' @noRd
sv_lazy_class <- function(zero, fct = NULL) {
  if (!is.null(fct)) return(if (isTRUE(fct$ordered)) "ordered" else "factor")
  class(zero)[1]
}

#' Sample standard deviation without overflow
#'
#' Used when the database's own `STDDEV_SAMP` fails. The values are divided by the
#' largest absolute one, so that no square overflows, and the result is scaled
#' back. R computes the variance first, so a variance beyond the double range is
#' `Inf` and so is the standard deviation (`sd(c(1e-300, 1e300, 5, 6, 7))`).
#' `NA` when even the scaled computation fails.
#' @param fin The finite values, as a tbl with `.sv_v`.
#' @param lo,hi Their minimum and maximum.
#' @noRd
sv_lazy_sd_scaled <- function(fin, lo, hi) {
  scale <- max(abs(lo), abs(hi))
  if (!is.finite(scale)) return(NA_real_)
  if (scale == 0) return(0)
  v <- rlang::sym(".sv_v")
  r <- tryCatch(
    dplyr::collect(dplyr::summarise(fin, sd = sd(!!v / !!sv_lazy_lit(scale), na.rm = TRUE))),
    error = function(e) NULL
  )
  if (is.null(r) || length(r$sd) != 1L || is.na(r$sd)) return(NA_real_)
  out <- r$sd * scale
  if (is.finite(out) && is.infinite(out^2)) Inf else out
}

#' The histogram of `sv_histogram()`, binned by the database
#'
#' `lo` and `hi` are the minimum and maximum of the finite values. The bin of a
#' value is `floor((v - lo) / width)` with the last bin closed, computed in SQL
#' from exact literals so that it equals R's.
#' @param fin The finite values, as a tbl with `.sv_v`.
#' @param n_fin How many there are.
#' @noRd
sv_lazy_histogram <- function(fin, lo, hi, n_fin, bins) {
  if (lo == hi) return(list(breaks = c(lo, hi), counts = sv_lazy_count(n_fin)))
  width <- (hi - lo) / bins
  v <- rlang::sym(".sv_v")
  binned <- dplyr::mutate(
    fin, .sv_bin = pmin(floor((!!v - !!sv_lazy_lit(lo)) / !!sv_lazy_lit(width)), !!as.numeric(bins - 1L), na.rm = TRUE)
  )
  tab <- dplyr::collect(dplyr::summarise(dplyr::group_by(binned, .sv_bin), n = n(), .groups = "drop"))
  counts <- integer(bins)
  idx <- as.integer(tab$.sv_bin) + 1L
  counts[idx] <- as.integer(tab$n)
  list(breaks = lo + width * (0:bins), counts = counts)
}

# Names that only exist inside the SQL translation of the verbs above.
utils::globalVariables(c(".sv_row", ".sv_rank", ".sv_na", ".sv_key", "row_number", "if_else", "case_when", "contains", "desc", "cast", "nx", "ny", "fx", "fy", "trim", "regexp_replace", "regexp_matches", "regexp_full_match", "quantile_cont", "isfinite", "isnan", "isinf", "n", "rtrim", "sd", "lower", "epoch_us", "make_timestamp", "strftime", ".sv_v", ".sv_t", ".sv_f", ".sv_k", ".sv_n", ".sv_bin", ".sv_rn", ".sv_rk", ".rx", ".ry", ".sv_cx", ".sv_cy", ".sv_first", ".sv_near", "n_distinct", "days", "USUBJID", "upper", "coalesce"))

#' The one place CDISC detection queries a lazy table
#'
#' Small queries only, never a full collect. `"domain"` gives up to two distinct
#' non-empty values of `DOMAIN`, `"rdomain"` up to 1000 of `RDOMAIN` (character); `"adsl"`
#' gives whether `USUBJID` is unique (one aggregate row; NA counts once, as
#' `anyDuplicated()` does). Tests mock this function to count the calls.
#' @param tbl A duckdb tbl or Arrow object.
#' @param kind `"domain"`, `"rdomain"` or `"adsl"`.
#' @param col The table's actual column name for the variable (any case); default the upper-case name.
#' @noRd
sv_cdisc_lazy_query <- function(tbl, kind, col = NULL) {
  if (kind %in% c("domain", "rdomain")) {
    if (is.null(col)) col <- if (kind == "domain") "DOMAIN" else "RDOMAIN"
    sym <- rlang::sym(col)
    # Normalise in the query (as the in-memory clean() does) before distinct, so
    # case and whitespace variants cannot use up the two slots.
    # trimws() strips [ \t\r\n]; duckdb's trim() needs the set spelled out, and
    # Arrow has no trim(x, chars) but does have gsub().
    txt <- rlang::expr(as.character(!!sym))
    norm <- if (inherits(tbl, "tbl_lazy")) {
      rlang::expr(upper(trim(!!txt, !!" \t\r\n")))
    } else {
      rlang::expr(toupper(gsub("^[ \t\r\n]+|[ \t\r\n]+$", "", !!txt)))
    }
    # DOMAIN rules only ask whether there is one value, so two are enough; a SUPPQUAL's tag
    # lists every RDOMAIN (they are the merge targets), as the in-memory peek does. The cap
    # only bounds a column that is not really RDOMAIN.
    res <- tbl |>
      dplyr::mutate(.sv_v = !!norm) |>
      dplyr::filter(!is.na(.sv_v), .sv_v != "") |>
      dplyr::distinct(.sv_v) |>
      dplyr::arrange(.sv_v) |>
      utils::head(if (kind == "domain") 2L else 1000L) |>
      dplyr::collect()
    return(as.character(res[[".sv_v"]]))
  }
  if (is.null(col)) col <- "USUBJID"
  usym <- rlang::sym(col)
  res <- tbl |>
    dplyr::summarise(n = dplyr::n(),
                     d = dplyr::n_distinct(!!usym, na.rm = TRUE),
                     nn = sum(as.integer(is.na(!!usym)), na.rm = TRUE)) |>
    dplyr::collect()
  n <- as.numeric(res$n); nn <- as.numeric(res$nn); d <- as.numeric(res$d)
  # sum()/n_distinct() over zero rows can be NULL: that is no rows, so unique
  n[is.na(n)] <- 0; nn[is.na(nn)] <- 0; d[is.na(d)] <- 0
  nn <= 1 && d == n - nn
}

# ---- derived cards: unmatched / outside_window rows as a lazy tbl (D1) ----

#' The rule's columns and kinds, read from 0 rows (nothing placed yet)
#'
#' The same steps `sv_lazy_join_diagnostics()` takes before it places the tables.
#' @return `list(rule, rule_x, rule_y, rule_kind, dbl_x, dbl_y)`; stops on a bad rule.
#' @noRd
sv_lazy_rule_prepare <- function(x, y, rule) {
  slot_cols <- function(side) {
    if (!is.list(rule) || !isTRUE(rule$shape %in% sv_rule_shapes)) return(character(0))
    v <- unlist(lapply(sv_rule_slots(rule$shape), function(s) {
      if (sv_rule_slot_side(s) == side && is.character(rule[[s]]) && length(rule[[s]]) == 1L) rule[[s]]
    }))
    as.character(unique(v[!is.na(v)]))
  }
  zx_rule <- sv_lazy_zero(x, slot_cols("x"))
  zy_rule <- sv_lazy_zero(y, slot_cols("y"))
  problem <- sv_join_rule_problem(rule, vapply(zx_rule, sv_key_kind, character(1)),
                                  vapply(zy_rule, sv_key_kind, character(1)))
  if (!is.null(problem)) stop(problem, call. = FALSE)
  rule <- sv_join_rule_normalize(rule)
  is_dbl <- function(z) vapply(z, function(v) identical(sv_lazy_kind(v), "double"), logical(1))
  list(rule = rule, rule_x = slot_cols("x"), rule_y = slot_cols("y"),
       rule_kind = sv_key_kind(zx_rule[[rule[[sv_rule_slots(rule$shape)[1L]]]]]),
       dbl_x = is_dbl(zx_rule), dbl_y = is_dbl(zy_rule))
}

#' Unmatched rows, or rows outside the date window, of one side, as a duckdb tbl
#'
#' The twin of the in-memory branch of `sv_derive_rows()`: the same dplyr
#' expressions over tables placed on one connection (`sv_lazy_place()`), nothing
#' collected. With no rule the rows are `anti_join(x, y, na_matches = "na")`; with a
#' rule a missing key matches nothing: `unmatched` rows have no key partner, and
#' `outside_window` rows have one but no pair the rule keeps. The rows without a
#' rule pair are found by the rule's own conditions on narrow tables
#' (`sv_lazy_rule_lone()`), then matched back to the full rows by the values they were
#' found on, so no row tag crosses a query. The result has the kept side's columns and
#' carries its `sv_tz` / `sv_factors`, and `sv_cleanup` (undoes the placement; run by
#' `sv_lazy_release()`).
#' @param x,y Data frames, duckdb tbls or Arrow objects.
#' @param args `list(op, by, rule, side, x_name, y_name)`; `op` is `"unmatched"` (default)
#'   or `"outside_window"`, `by` as for `sv_derive_by_pairs()`.
#' @param con_env An environment from `sv_lazy_env()`.
#' @noRd
sv_lazy_unmatched <- function(x, y, args, con_env) {
  op <- if (identical(args$op, "outside_window")) "outside_window" else "unmatched"
  side <- if (identical(args$side, "y")) "y" else "x"
  x_name <- args$x_name %||% "x"
  y_name <- args$y_name %||% "y"
  pairs <- sv_derive_by_pairs(args$by)
  by_x <- vapply(pairs, function(p) p$x, "")
  by_y <- vapply(pairs, function(p) p$y, "")
  miss_x <- setdiff(by_x, sv_lazy_names(x))
  miss_y <- setdiff(by_y, sv_lazy_names(y))
  if (length(miss_x)) stop(sprintf("Not in %s: %s", x_name, paste(miss_x, collapse = ", ")), call. = FALSE)
  if (length(miss_y)) stop(sprintf("Not in %s: %s", y_name, paste(miss_y, collapse = ", ")), call. = FALSE)
  rule <- args$rule
  if (identical(op, "outside_window") && is.null(rule)) stop("outside_window needs a date rule.", call. = FALSE)
  rs <- NULL
  if (!is.null(rule)) {
    rs <- sv_lazy_rule_prepare(x, y, rule)
    rule <- rs$rule
  }
  src <- if (side == "x") x else y
  factors <- attr(src, "sv_factors", exact = TRUE)
  if (is.null(factors) && identical(sv_lazy_origin(src), "arrow")) factors <- sv_lazy_factors(src)

  placed <- sv_lazy_place(x, y, con_env)
  ok <- FALSE
  on.exit(if (!ok) placed$cleanup(), add = TRUE)
  kept <- placed[[side]]
  cols_keep <- as.character(sv_lazy_names(kept))

  zx <- dplyr::collect(utils::head(dplyr::select(placed$x, dplyr::all_of(unique(by_x))), 0L))
  zy <- dplyr::collect(utils::head(dplyr::select(placed$y, dplyr::all_of(unique(by_y))), 0L))
  issues <- sv_join_type_issues(zx, zy, by_x, by_y, x_name, y_name)
  if (length(issues)) stop(paste(issues, collapse = " "), call. = FALSE)

  if (is.null(rule)) {
    # na_matches = "na": a missing key matches a missing key, as in a default dplyr join
    out <- if (side == "x") {
      dplyr::anti_join(placed$x, placed$y, by = stats::setNames(by_y, by_x), na_matches = "na")
    } else {
      dplyr::anti_join(placed$y, placed$x, by = stats::setNames(by_x, by_y), na_matches = "na")
    }
  } else {
    nk <- length(by_x)
    kn <- sv_lazy_key_names(nk)
    kind_x <- vapply(by_x, function(cn) sv_key_kind(zx[[cn]]), "")
    kind_y <- vapply(by_y, function(cn) sv_key_kind(zy[[cn]]), "")
    text <- kind_x != kind_y
    lazy_x <- vapply(by_x, function(cn) sv_lazy_kind(zx[[cn]]), "")
    lazy_y <- vapply(by_y, function(cn) sv_lazy_kind(zy[[cn]]), "")
    tz_of <- function(tbl, z, by) {
      vapply(by, function(cn) {
        if (inherits(z[[cn]], "POSIXct")) sv_lazy_zone_for(attr(tbl, "sv_tz"), cn) else NA_character_
      }, "", USE.NAMES = FALSE)
    }
    tz_x <- tz_of(placed$x, zx, by_x)
    tz_y <- tz_of(placed$y, zy, by_y)
    side_x <- function(row = FALSE) {
      sv_lazy_join_side(placed$x, by_x, lazy_x, text, kind_x == "character", NULL, row, tz_x)
    }
    side_y <- function(row = FALSE) {
      sv_lazy_join_side(placed$y, by_y, lazy_y, text, kind_y == "character", NULL, row, tz_y)
    }
    keyed <- if (side == "x") side_x() else side_y()
    other_keys <- dplyr::select(if (side == "x") side_y() else side_x(), dplyr::all_of(kn))
    if (identical(op, "unmatched")) {
      out <- dplyr::anti_join(keyed, other_keys, by = kn, na_matches = "never")
    } else {
      nx <- sv_lazy_rule_side(side_x(row = TRUE), rule, "x", rs$rule_kind, rs$dbl_x, nk)
      ny <- sv_lazy_rule_side(side_y(row = TRUE), rule, "y", rs$rule_kind, rs$dbl_y, nk)
      lone <- sv_lazy_rule_lone(nx, ny, nk, rule, side)
      vals <- intersect(as.character(sv_lazy_names(lone)), c(".sv_xa", ".sv_xb", ".sv_ya", ".sv_yb"))
      lone <- dplyr::distinct(dplyr::select(lone, dplyr::all_of(c(kn, vals))))
      wide <- sv_lazy_rule_side(keyed, rule, side, rs$rule_kind,
                                if (side == "x") rs$dbl_x else rs$dbl_y, nk, all_cols = TRUE)
      by <- stats::setNames(c(kn, vals), c(kn, vals))
      out <- dplyr::semi_join(wide, lone, by = by, na_matches = "na")
      out <- dplyr::semi_join(out, other_keys, by = kn, na_matches = "never")
    }
  }
  out <- dplyr::select(out, dplyr::all_of(cols_keep))
  tz <- attr(kept, "sv_tz", exact = TRUE)
  if (length(tz)) attr(out, "sv_tz") <- tz
  if (length(factors)) attr(out, "sv_factors") <- factors
  attr(out, "sv_cleanup") <- placed$cleanup
  ok <- TRUE
  out
}

#' The recipe of a derived card: how to build its rows from the input cards
#'
#' A derived lazy card keeps no table. Its `source` is this recipe, and
#' `sv_lazy_tbl()` builds the rows on the session connection from the inputs.
#' @param op `"unmatched"` or `"outside_window"`.
#' @param args `list(by, rule, side)`.
#' @param inputs A named list of the input card objects (x first, y second).
#' @noRd
sv_derived_source <- function(op, args, inputs) {
  structure(list(op = op, args = args, inputs = inputs), class = "sv_derived_source")
}

#' Build the lazy tbl of a derived recipe and cache it under `key`
#' @noRd
sv_lazy_derived_tbl <- function(source, con_env, key = NULL) {
  inputs <- source$inputs
  if (identical(source$op, "stack")) {
    # N inputs, read as sv_derive_clean_stack() read them, one duckdb union_all (see sv_lazy_stack())
    tabs <- sv_stack_card_tables(unname(inputs), names(inputs), con_env)
    tbl <- sv_lazy_stack(tabs, source$args$plan, con_env)
    if (!is.null(key)) con_env$tbls[[key]] <- tbl
    return(tbl)
  }
  if (source$op %in% c("compare_added", "compare_removed", "compare_changed")) {
    # old and new, read as sv_compare_clean() read them, compared on one duckdb connection (see sv_lazy_compare())
    tabs <- sv_stack_card_tables(unname(inputs), names(inputs), con_env)
    tbl <- sv_lazy_compare(tabs[[1L]], tabs[[2L]], source$args$plan, con_env, source$op)
    if (!is.null(key)) con_env$tbls[[key]] <- tbl
    return(tbl)
  }
  tbls <- lapply(inputs, function(card) {
    if (sv_card_is_lazy(card)) sv_lazy_tbl(card$source, con_env, card$id) else card$data
  })
  nms <- names(inputs)
  args <- source$args
  args$op <- source$op
  if (length(nms) >= 2L) {
    if (is.null(args$x_name) && nzchar(nms[1L])) args$x_name <- nms[1L]
    if (is.null(args$y_name) && nzchar(nms[2L])) args$y_name <- nms[2L]
  }
  tbl <- sv_lazy_unmatched(tbls[[1L]], tbls[[2L]], args, con_env)
  if (!is.null(key)) con_env$tbls[[key]] <- tbl
  tbl
}

# ---- D2: stacking lazy tables (duckdb / Arrow) as one union_all ----

#' Put N tables on one duckdb connection for a stack
#'
#' `sv_lazy_place()`'s rules for any number of inputs: a duckdb input stays where it is, all of them must
#' be on one connection (else `sv_lazy_cross_con`), a table on another database is refused
#' (`sv_lazy_not_duckdb`), and with no duckdb input the private connection of `con_env` is used. An Arrow
#' input is handed over with `to_duckdb()` (dictionary columns decoded first), a data frame is registered
#' under a temporary name. Nothing is collected. `cleanup()` removes whatever was added to the connection;
#' it also runs here if placing a later table fails.
#' @param tables A named list of data frames, duckdb tbls or Arrow objects.
#' @param con_env An environment from `sv_lazy_env()`.
#' @param what What the tables are placed for, as the messages name it: `"stack"` or `"compare"`.
#' @return `list(tbls, con, cleanup)`: the tbls (same names), the shared connection, an undo function.
#' @noRd
sv_lazy_place_n <- function(tables, con_env, what = "stack") {
  origin <- vapply(tables, sv_lazy_origin, "")
  for (src in tables) {
    if (inherits(src, "tbl_lazy") && !inherits(src, "tbl_duckdb_connection")) {
      rlang::abort(sprintf("The %s needs duckdb tables; this table is on another database.", what),
                   class = "sv_lazy_not_duckdb")
    }
  }
  duck <- which(origin == "duckdb")
  cons <- lapply(tables[duck], dbplyr::remote_con)
  if (length(cons) > 1L && !all(vapply(cons[-1L], function(cn) identical(cn, cons[[1L]]), NA))) {
    rlang::abort(sprintf("These tables are on different duckdb connections; %s unavailable.", what),
                 class = "sv_lazy_cross_con")
  }
  con <- if (length(duck)) cons[[1L]] else sv_lazy_con(con_env)

  undo <- list()
  cleanup <- function() {
    todo <- rev(undo)
    undo <<- list()
    for (f in todo) f()
    invisible(NULL)
  }
  ok <- FALSE
  on.exit(if (!ok) cleanup(), add = TRUE)

  tbls <- lapply(seq_along(tables), function(i) {
    src <- tables[[i]]
    switch(origin[[i]],
      duckdb = src,
      arrow = {
        tbl <- arrow::to_duckdb(sv_lazy_decode_dictionaries(src), con = con, auto_disconnect = FALSE)
        name <- dbplyr::remote_name(tbl)
        undo[[length(undo) + 1L]] <<- function() sv_lazy_detach_arrow(con, name)
        sv_lazy_with_zones(tbl, sv_lazy_zones(src))
      },
      df = {
        a <- sv_lazy_attach(as.data.frame(src), con)
        undo[[length(undo) + 1L]] <<- function() sv_lazy_detach(con, a$name)
        sv_lazy_with_zones(a$tbl, sv_lazy_zones(src))
      })
  })
  names(tbls) <- names(tables)
  ok <- TRUE
  list(tbls = tbls, con = con, cleanup = cleanup)
}

# A SQL fragment as an R call, so that an expression holding it prints as code that runs
sv_stack_sql <- function(text) rlang::call2(quote(dbplyr::sql), text)

# An expression as one line of code
sv_stack_show <- function(e) paste(rlang::expr_deparse(e, width = Inf), collapse = " ")

# An identifier quoted for SQL, the way DBI::dbQuoteIdentifier() does
sv_stack_qid <- function(name) paste0("\"", gsub("\"", "\"\"", name, fixed = TRUE), "\"")

# Raw SQL objects inside an expression (from the tz helpers) as dbplyr::sql() calls
sv_stack_sql_calls <- function(e) {
  if (inherits(e, "sql")) return(sv_stack_sql(as.character(e)))
  if (is.call(e)) return(as.call(lapply(as.list(e), sv_stack_sql_calls)))
  e
}

# Which casts can give NA from a value (the others never do, so the NA count needs no query)
sv_stack_cast_can_na <- function(from, to) {
  switch(to,
    lgl = from %in% c("int", "num", "chr"),
    int = from %in% c("num", "chr"),
    num = identical(from, "chr"),
    date = identical(from, "chr"),
    FALSE)
}

# The zone a dttm column is written in: its own, else the session's
sv_stack_zone <- function(zone) {
  if (length(zone) && !is.na(zone) && nzchar(zone)) return(zone)
  tz <- tryCatch(Sys.timezone(), error = function(e) NA_character_)
  if (is.na(tz) || !nzchar(tz)) "UTC" else tz
}

#' One lazy cast as an expression (decision 3's table, in SQL)
#'
#' The lazy twin of `sv_stack_cast()`: a value converts exactly or gives `NA`. Written once, as a language
#' object that `sv_lazy_stack()` evaluates inside `mutate()` and that `sv_stack_code()` prints as code
#' (`rlang::expr_deparse()`). Where dbplyr has no exact translation the SQL is a `dbplyr::sql()` call:
#' `as.numeric()` is NUMERIC (DECIMAL(18,3)) there and a plain `CAST` errors on bad text, so text is read
#' with `TRY_CAST` behind the same regular expression and range guard as in R. NaN is missing, so it is
#' kept out of every guard with `isnan()` (duckdb says `NaN = NaN`).
#' @param cn The column name as the table has it.
#' @param from,to Type names (decision 1).
#' @param zone The zone of a `dttm` column that becomes text.
#' @noRd
sv_stack_lazy_cast <- function(cn, from, to, zone = "") {
  x <- rlang::sym(cn)
  q <- sv_stack_qid(cn)
  dbl <- sv_stack_sql(sprintf("TRY_CAST(%s AS DOUBLE)", q))
  matches <- function(re) rlang::expr(regexp_matches(!!x, !!re))
  switch(to,
    lgl = if (from == "chr") {
      rlang::expr(dplyr::case_when(!!x == "TRUE" ~ TRUE, !!x == "FALSE" ~ FALSE, .default = NA))
    } else {
      rlang::expr(dplyr::case_when(!!x == 0 ~ FALSE, !!x == 1 ~ TRUE, .default = NA))
    },
    int = switch(from,
      lgl = rlang::expr(as.integer(!!x)),
      chr = rlang::expr(dplyr::if_else(
        !!matches(sv_supp_int_re) & abs(!!dbl) <= 2147483647,
        !!sv_stack_sql(sprintf("TRY_CAST(TRY_CAST(%s AS DOUBLE) AS INTEGER)", q)), NA)),
      rlang::expr(dplyr::if_else(
        !isnan(!!x) & !!x == floor(!!x) & abs(!!x) <= 2147483647,
        !!sv_stack_sql(sprintf("TRY_CAST(%s AS INTEGER)", q)), NA))),
    num = if (from == "chr") {
      rlang::expr(dplyr::if_else(!!matches(sv_supp_dbl_re) & abs(!!dbl) <= 1e308, !!dbl, NA))
    } else sv_stack_sql(sprintf("CAST(%s AS DOUBLE)", q)),
    chr = switch(from,
      lgl = sv_lazy_text_expr(x, "logical"),
      num = sv_lazy_text_expr(x, "double"),
      dttm = sv_stack_sql_calls(sv_lazy_tz_text_expr(x, sv_stack_zone(zone), seconds = TRUE)),
      rlang::expr(as.character(!!x))),
    date = if (from == "dttm") {
      # the UTC date, as in memory; CAST(TIMESTAMPTZ AS DATE) needs ICU, epoch_us() does not
      sv_stack_sql(sprintf("CAST(make_timestamp(epoch_us(%s)) AS DATE)", q))
    } else {
      rlang::expr(dplyr::if_else(regexp_matches(!!x, "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"),
                                 !!sv_stack_sql(sprintf("TRY_CAST(%s AS DATE)", q)), NA))
    },
    dttm = sv_stack_sql(sprintf("CAST(%s AS TIMESTAMP)", q)),
    stop(sprintf("Cannot cast to %s.", to), call. = FALSE))
}

# A missing column, typed so that the union reads it as the target type
sv_stack_lazy_na <- function(target) {
  sv_stack_sql(sprintf("CAST(NULL AS %s)", switch(target, lgl = "BOOLEAN", int = "INTEGER", num = "DOUBLE",
                                                  date = "DATE", dttm = "TIMESTAMP", "VARCHAR")))
}

#' What one input of a lazy stack needs: renames, columns to set, columns in stack order
#' @return `list(rename, sets, cols)`; `rename` maps a new name to the old one, `sets` is a named list of
#'   expressions (the id column first), `cols` the columns, in stack order.
#' @noRd
sv_stack_lazy_parts <- function(plan, i) {
  rename <- list()
  sets <- list()
  sets[[plan$id_col]] <- plan$inputs[i]
  for (col in plan$columns) {
    from <- col$rename_from[i]
    if (!is.na(from)) rename[[col$name]] <- from
    type <- col$types[i]
    if (is.na(type)) {
      sets[[col$name]] <- sv_stack_lazy_na(col$target)
    } else if (!is.na(col$cast[i])) {
      sets[[col$name]] <- sv_stack_lazy_cast(col$name, type, col$target, col$zones[i])
    } else if (identical(type, "fct")) {
      # a dictionary / enum input: as text, so inputs with different levels union
      sets[[col$name]] <- rlang::expr(as.character(!!rlang::sym(col$name)))
    }
  }
  list(rename = rename, sets = sets, cols = c(plan$id_col, vapply(plan$columns, function(c) c$name, "")))
}

# Apply `sv_stack_lazy_parts()` to a tbl
sv_stack_lazy_apply <- function(tbl, parts) {
  if (length(parts$rename)) {
    tbl <- dplyr::rename(tbl, !!!lapply(parts$rename, rlang::sym))
  }
  tbl <- dplyr::mutate(tbl, !!!parts$sets)
  dplyr::select(tbl, dplyr::all_of(parts$cols))
}

# A 0-row data frame of an input: its types as R sees them, with the factor levels, zones and labels put back
sv_lazy_stack_sample <- function(src, tbl) {
  z <- as.data.frame(dplyr::collect(utils::head(tbl, 0L)), stringsAsFactors = FALSE)
  factors <- attr(src, "sv_factors", exact = TRUE)
  if (is.null(factors) && identical(sv_lazy_origin(src), "arrow")) factors <- sv_lazy_factors(src)
  for (cn in intersect(names(factors), names(z))) {
    f <- factors[[cn]]
    z[[cn]] <- factor(character(0), levels = f$levels %||% character(0), ordered = isTRUE(f$ordered))
  }
  zones <- attr(tbl, "sv_tz", exact = TRUE) %||% attr(src, "sv_tz", exact = TRUE)
  for (cn in names(z)) {
    if (inherits(z[[cn]], "POSIXct")) attr(z[[cn]], "tzone") <- sv_lazy_zone_for(zones, cn)
  }
  # an Arrow table keeps a column's label in its R metadata; a duckdb table has none
  if (inherits(src, "ArrowTabular")) {
    lab <- tryCatch(as.data.frame(utils::head(src, 0L)), error = function(e) NULL)
    for (cn in intersect(names(lab), names(z))) {
      l <- attr(lab[[cn]], "label")
      if (!is.null(l)) attr(z[[cn]], "label") <- l
    }
  }
  z
}

# A 0-row sample of a data frame, with its labels (`[` drops them)
sv_stack_zero_df <- function(df) {
  z <- df[0L, , drop = FALSE]
  for (cn in names(df)) {
    l <- attr(df[[cn]], "label")
    if (!is.null(l)) attr(z[[cn]], "label") <- l
  }
  z
}

#' The plan of a stack with a lazy input
#'
#' The twin of `sv_stack_plan()` for any mix of data frames, duckdb tables and Arrow tables: the same
#' return value. Types, zones, factor levels and labels come from 0 rows (`head(0)`) and the Arrow schema;
#' the row count and the NA counts of the casts come from one aggregated query per lazy input, run on one
#' connection (`sv_lazy_place_n()`). Nothing is collected. A data frame input counts in R.
#' @inheritParams sv_stack_plan
#' @param con_env An environment from `sv_lazy_env()`; when omitted a private connection is opened for this
#'   call and closed again.
#' @noRd
sv_lazy_stack_plan <- function(tables, fixes = list(), id_col = NULL, con_env = NULL) {
  if (is.null(con_env)) {
    con_env <- sv_lazy_env()
    on.exit(sv_lazy_close(con_env), add = TRUE)
  }
  inputs <- names(tables)
  is_lazy <- vapply(tables, sv_is_lazy_input, NA)
  placed <- sv_lazy_place_n(tables[is_lazy], con_env)
  on.exit(placed$cleanup(), add = TRUE, after = FALSE)
  samples <- lapply(inputs, function(nm) {
    if (is_lazy[[nm]]) sv_lazy_stack_sample(tables[[nm]], placed$tbls[[nm]]) else sv_stack_zero_df(tables[[nm]])
  })
  names(samples) <- inputs
  counts <- rep(0, length(inputs))
  na_fun <- function(reqs) {
    out <- integer(length(reqs))
    for (i in seq_along(inputs)) {
      mine <- which(vapply(reqs, function(r) r$i == i, NA))
      if (!is_lazy[[i]]) {
        counts[i] <<- nrow(tables[[i]])
        for (k in mine) {
          r <- reqs[[k]]
          x <- tables[[i]][[r$src]]
          v <- sv_stack_cast(x, r$from, r$to, r$zone)
          out[k] <- sum(is.na(v) & !is.na(x))
        }
        next
      }
      sums <- list()
      for (k in mine) {
        r <- reqs[[k]]
        if (!sv_stack_cast_can_na(r$from, r$to)) next
        x <- rlang::sym(r$src)
        cond <- rlang::expr(is.na(!!sv_stack_lazy_cast(r$src, r$from, r$to, r$zone)) & !is.na(!!x))
        if (identical(r$from, "num")) cond <- rlang::expr(!!cond & !isnan(!!x))
        sums[[paste0("na", k)]] <- rlang::expr(sum(dplyr::if_else(!!cond, 1L, 0L), na.rm = TRUE))
      }
      res <- dplyr::collect(dplyr::summarise(placed$tbls[[inputs[i]]], .sv_n = dplyr::n(), !!!sums))
      counts[i] <<- as.numeric(res$.sv_n[1L])
      for (nm in names(sums)) {
        v <- as.integer(res[[nm]][1L])
        out[as.integer(sub("^na", "", nm))] <- if (is.na(v)) 0L else v
      }
    }
    out
  }
  plan <- sv_stack_plan_core(samples, inputs, fixes, id_col, na_fun, function() sv_lazy_count(sum(counts)))
  plan <- sv_stack_add_tz_text(plan)
  clash <- sv_stack_case_clash(plan)
  if (length(clash)) plan$case_clash <- clash
  plan
}

# The text of every dttm-to-chr cast (the zone's offset tree is long), so the browser writes the same lazy code without
# rebuilding the tree: `tz_text[i]` is input i's cast of this column, NA where it has none. Pure R: an in-memory plan of
# lazy cards (the lost-link preview) gets it too, so the browser can always write the lazy code.
sv_stack_add_tz_text <- function(plan) {
  inputs <- plan$inputs
  for (k in seq_along(plan$columns)) {
    col <- plan$columns[[k]]
    tt <- rep(NA_character_, length(inputs))
    for (i in seq_along(inputs)) {
      if (!is.na(col$types[i]) && !is.na(col$cast[i]) && identical(col$types[i], "dttm") && identical(col$cast[i], "chr")) {
        tt[i] <- sv_stack_show(sv_stack_lazy_cast(col$name, "dttm", "chr", col$zones[i]))
      }
    }
    if (any(!is.na(tt))) plan$columns[[k]]$tz_text <- tt
  }
  plan
}

# The names of a lazy stack that differ only in case (`AGE` and `Age` left apart): duckdb reads them as one name and
# would rename one to `Age_1`, so a lazy stack refuses them. Empty when there are none.
sv_stack_case_clash <- function(plan) {
  nms <- c(plan$id_col, vapply(plan$columns, function(c) c$name, ""))
  low <- tolower(nms)
  nms[low %in% low[duplicated(low)]]
}

#' The stack of lazy tables, as one duckdb `union_all()`
#'
#' Every input is placed on one connection (`sv_lazy_place_n()`), given the id column, its casts and typed
#' NAs for the columns it lacks (`sv_stack_lazy_parts()`), put in stack order, and the inputs are joined by
#' nested `union_all()`. Nothing is collected. The result carries the zones (`sv_tz`: the first zone kept for
#' each time column), the factor columns with their union of levels (`sv_factors`) and `sv_cleanup`, which
#' undoes the placement (`sv_lazy_release()` runs it).
#' @param tables A named list of data frames, duckdb tbls or Arrow objects, in plan order.
#' @param plan From `sv_stack_plan()` / `sv_lazy_stack_plan()`.
#' @param con_env An environment from `sv_lazy_env()`.
#' @noRd
sv_lazy_stack <- function(tables, plan, con_env) {
  if (!identical(names(tables), plan$inputs)) stop("The plan was made for other tables.", call. = FALSE)
  clash <- sv_stack_case_clash(plan)
  if (length(clash)) stop(sv_say_stack_case_clash(clash), call. = FALSE)
  placed <- sv_lazy_place_n(tables, con_env)
  ok <- FALSE
  on.exit(if (!ok) placed$cleanup(), add = TRUE)
  parts <- lapply(seq_along(tables), function(i) {
    sv_stack_lazy_apply(placed$tbls[[i]], sv_stack_lazy_parts(plan, i))
  })
  out <- Reduce(function(a, b) dplyr::union_all(a, b), parts, right = TRUE)
  tz <- vapply(names(plan$tz), function(cn) sv_stack_zone(plan$tz[[cn]]), "")
  if (length(tz)) attr(out, "sv_tz") <- tz
  factors <- list()
  for (col in plan$columns) {
    if (!identical(col$target, "fct")) next
    factors[[col$name]] <- list(ordered = isTRUE(col$ordered), levels = col$levels)
  }
  if (length(factors)) attr(out, "sv_factors") <- factors
  attr(out, "sv_cleanup") <- placed$cleanup
  ok <- TRUE
  out
}

# ---- D3: comparing two versions of a lazy table (duckdb / Arrow) by key ----

#' The code that puts one input of a lazy stack or compare on the shared duckdb connection
#'
#' A duckdb input stays as it is; an Arrow input is moved with `to_duckdb()` (`compute()` makes a real table on a
#' duckdb input's connection, as a view can be collected before the query runs); a data frame is copied in with
#' `copy_to()` under `name` or, with no duckdb input, made an Arrow table first.
#'
#' `keep_views = TRUE` (the compare) writes `auto_disconnect = FALSE` where an Arrow table is registered on arrow's
#' own duckdb connection: arrow ties the view to the tbl's `src`, and a join keeps only x's, so y's view would be
#' unregistered when R collects the garbage before the query runs.
#' @param ref The input's R reference.
#' @param kind `NA` (a data frame), `"duckdb"` or `"arrow"`.
#' @param duck_ref The reference of the first duckdb input, or `NULL`.
#' @param name The `copy_to()` table name.
#' @param keep_views Keep the Arrow views registered (see above).
#' @noRd
sv_lazy_place_code <- function(ref, kind, duck_ref, name, keep_views = FALSE) {
  keep <- if (keep_views) ", auto_disconnect = FALSE" else ""
  if (is.na(kind)) {
    if (is.null(duck_ref)) return(paste0("arrow::to_duckdb(arrow::arrow_table(", ref, ")", keep, ")"))
    return(paste0("dplyr::copy_to(dbplyr::remote_con(", duck_ref, "), ", ref, ", name = ",
                  encodeString(name, quote = "\""), ", overwrite = TRUE)"))
  }
  if (identical(kind, "arrow")) {
    if (is.null(duck_ref)) return(paste0("arrow::to_duckdb(", ref, keep, ")"))
    return(paste0("dplyr::compute(arrow::to_duckdb(", ref, ", con = dbplyr::remote_con(", duck_ref, ")))"))
  }
  ref
}

#' The text of a column's values in a lazy compare, as an expression
#'
#' D2's lazy cast to text (`sv_stack_lazy_cast()`), with a NaN as `NA` (the cast would write `"NaN"`): the lazy twin
#' of `sv_compare_text()`. A date-time is written in `zone` (else the session's).
#' @param cn The column name as the table has it.
#' @param from Its type name.
#' @param zone Its zone, or `NA` / `NULL`.
#' @noRd
sv_compare_lazy_text <- function(cn, from, zone = "") {
  if (is.null(zone) || isTRUE(is.na(zone))) zone <- ""
  e <- sv_stack_lazy_cast(cn, from, "chr", zone)
  if (identical(from, "num")) e <- rlang::expr(dplyr::if_else(isnan(!!rlang::sym(cn)), NA_character_, !!e))
  e
}

# A missing value of a column, lazily: NA, or NaN for a double (duckdb says NaN is not NULL)
sv_compare_lazy_missing <- function(cn, from) {
  x <- rlang::sym(cn)
  if (identical(from, "num")) rlang::expr((is.na(!!x) | isnan(!!x))) else rlang::expr(is.na(!!x))
}

#' The lazy condition of a changed value (decision 9) for one compared column, as an expression
#'
#' The twin of `sv_compare_changed()`: missing in one only, or different; missing in both is the same. A
#' character-kind column (a factor or text) is compared as text, so an enum and a string agree.
#' @param cc One entry of the plan's `compared`.
#' @noRd
sv_compare_lazy_cond <- function(cc) {
  an <- paste0(cc$name, ".old")
  bn <- paste0(cc$name, ".new")
  ma <- sv_compare_lazy_missing(an, cc$from_old)
  mb <- sv_compare_lazy_missing(bn, cc$from_new)
  ca <- rlang::sym(an)
  cb <- rlang::sym(bn)
  if (cc$kind %in% "character") {
    ca <- rlang::call2("as.character", ca)
    cb <- rlang::call2("as.character", cb)
  }
  both <- rlang::call2("(", rlang::call2("&", ma, mb))
  differ <- rlang::call2("(", rlang::call2("|", rlang::call2("|", ma, mb), rlang::call2("!=", ca, cb)))
  rlang::call2("&", rlang::call2("!", both), differ)
}

# The text of every date-time text cast of a lazy compare (the zone's offset tree is long), so the browser writes the
# same lazy code without rebuilding it: a compared column's `tz_text_old` / `tz_text_new`, and a text key's.
sv_compare_add_tz_text <- function(plan) {
  tt <- function(cn, from, zone) {
    if (!identical(from, "dttm")) return(NA_character_)
    sv_stack_show(sv_compare_lazy_text(cn, "dttm", zone))
  }
  for (k in seq_along(plan$compared)) {
    cc <- plan$compared[[k]]
    plan$compared[[k]]$tz_text_old <- tt(paste0(cc$name, ".old"), cc$from_old, cc$zone_old)
    plan$compared[[k]]$tz_text_new <- tt(paste0(cc$name, ".new"), cc$from_new, cc$zone_new)
  }
  for (k in seq_along(plan$keys)) {
    ky <- plan$keys[[k]]
    if (!isTRUE(ky$text)) next
    plan$keys[[k]]$tz_text_old <- tt(ky$name, ky$from_old, ky$zone_old)
    plan$keys[[k]]$tz_text_new <- tt(ky$name, ky$from_new, ky$zone_new)
  }
  plan
}

#' The plan of a compare with a lazy version
#'
#' The twin of `sv_compare_plan()` for any mix of a data frame, a duckdb table and an Arrow table: the same return
#' value, with `lazy = TRUE` and the `tz_text_*` of every date-time text cast. Types, zones and factor levels come
#' from 0 rows of each lazy input, placed on one duckdb connection (`sv_lazy_place_n()`). Nothing is collected.
#' @param con_env An environment from `sv_lazy_env()`; when `NULL` a private connection is opened for this call.
#' @noRd
sv_lazy_compare_plan <- function(old, new, by, con_env = NULL, old_name = "old", new_name = "new") {
  by <- sv_compare_by(by, old_name, new_name)
  if (is.null(con_env)) {
    con_env <- sv_lazy_env()
    on.exit(sv_lazy_close(con_env), add = TRUE)
  }
  tables <- list(old = old, new = new)
  is_lazy <- vapply(tables, sv_is_lazy_input, NA)
  placed <- sv_lazy_place_n(tables[is_lazy], con_env, what = "compare")
  on.exit(placed$cleanup(), add = TRUE, after = FALSE)
  samples <- lapply(names(tables), function(nm) {
    if (is_lazy[[nm]]) sv_lazy_stack_sample(tables[[nm]], placed$tbls[[nm]]) else sv_stack_zero_df(tables[[nm]])
  })
  plan <- sv_compare_plan_core(samples[[1L]], samples[[2L]], by, old_name, new_name)
  plan$lazy <- TRUE
  sv_compare_add_tz_text(plan)
}

#' A lazy compare: the summary from queries, or one card as a duckdb tbl
#'
#' The twin of `sv_compare_rows()`. Both versions are placed on one duckdb connection (`sv_lazy_place_n()`), given
#' their text key columns, kept to the keys that do not repeat (`n() == 1` by key) and joined with
#' `na_matches = "na"`: the steps `sv_compare_code()` writes. With `op = NULL` the summary has exactly the fields of
#' `sv_compare_rows()$summary`, every count from a query; only the up to 5 repeated keys of the sample are read.
#' With an op the card is returned as a duckdb tbl (in no order) carrying `sv_tz`, `sv_factors` and `sv_cleanup`.
#' Nothing is collected.
#' @param old,new Data frames, duckdb tbls or Arrow objects.
#' @param plan From `sv_compare_plan()`.
#' @param con_env An environment from `sv_lazy_env()`.
#' @param op `NULL`, `"compare_added"`, `"compare_removed"` or `"compare_changed"`.
#' @noRd
sv_lazy_compare <- function(old, new, plan, con_env, op = NULL) {
  if (!is.null(op) && !op %in% c("compare_added", "compare_removed", "compare_changed")) {
    stop(sprintf("Unknown compare op: %s", op), call. = FALSE)
  }
  tables <- list(old = old, new = new)
  placed <- sv_lazy_place_n(tables, con_env, what = "compare")
  keep <- FALSE
  on.exit(if (!keep) placed$cleanup(), add = TRUE)
  by <- plan$by
  jb <- by
  for (j in seq_along(plan$keys)) if (isTRUE(plan$keys[[j]]$text)) jb[j] <- paste0(".sv_k", j)
  extra <- jb[jb != by]
  side <- function(i) {
    sets <- list()
    for (j in seq_along(plan$keys)) {
      k <- plan$keys[[j]]
      if (!isTRUE(k$text)) next
      sets[[jb[j]]] <- if (i == 1L) {
        sv_compare_lazy_text(k$name, k$from_old, k$zone_old)
      } else {
        sv_compare_lazy_text(k$name, k$from_new, k$zone_new)
      }
    }
    if (length(sets)) dplyr::mutate(placed$tbls[[i]], !!!sets) else placed$tbls[[i]]
  }
  o <- side(1L)
  n <- side(2L)
  uniq <- function(x) dplyr::filter(x, dplyr::n() == 1L, .by = dplyr::all_of(jb))
  drop <- function(x) if (length(extra)) dplyr::select(x, -dplyr::all_of(extra)) else x
  added <- function() drop(dplyr::anti_join(uniq(n), o, by = jb, na_matches = "na"))
  removed <- function() drop(dplyr::anti_join(uniq(o), n, by = jb, na_matches = "na"))
  both <- function() dplyr::inner_join(uniq(o), uniq(n), by = jb, suffix = c(".old", ".new"), na_matches = "na")
  conds <- lapply(plan$compared, sv_compare_lazy_cond)
  nms <- vapply(plan$compared, function(cc) cc$name, "")

  # a card carries the zones and factor levels of the side its columns come from
  finish <- function(out, from, cols_from = NULL) {
    src <- tables[[from]]
    tz <- attr(placed$tbls[[from]], "sv_tz", exact = TRUE)
    factors <- attr(src, "sv_factors", exact = TRUE)
    if (is.null(factors) && identical(sv_lazy_origin(src), "arrow")) factors <- sv_lazy_factors(src)
    cols <- cols_from %||% as.character(sv_lazy_names(out))
    tz <- tz[intersect(names(tz), cols)]
    factors <- factors[intersect(names(factors), cols)]
    if (length(tz)) attr(out, "sv_tz") <- tz
    if (length(factors)) attr(out, "sv_factors") <- factors
    attr(out, "sv_cleanup") <- placed$cleanup
    keep <<- TRUE
    out
  }
  if (identical(op, "compare_added")) return(finish(added(), "new"))
  if (identical(op, "compare_removed")) return(finish(removed(), "old"))
  if (identical(op, "compare_changed")) {
    is_text <- vapply(plan$keys, function(k) isTRUE(k$text), NA)
    keys <- lapply(seq_along(by), function(j) rlang::sym(if (is_text[j]) paste0(by[j], ".new") else by[j]))
    names(keys) <- by
    b <- both()
    pieces <- if (!length(nms)) {
      na <- sv_stack_lazy_na("chr")
      list(dplyr::transmute(dplyr::filter(b, FALSE), !!!keys, column = !!na, old = !!na, new = !!na))
    } else {
      lapply(seq_along(nms), function(k) {
        cc <- plan$compared[[k]]
        dplyr::transmute(dplyr::filter(b, !!conds[[k]]), !!!keys, column = !!cc$name,
                         old = !!sv_compare_lazy_text(paste0(cc$name, ".old"), cc$from_old, cc$zone_old),
                         new = !!sv_compare_lazy_text(paste0(cc$name, ".new"), cc$from_new, cc$zone_new))
      })
    }
    out <- Reduce(function(a, b) dplyr::union_all(a, b), pieces, right = TRUE)
    # a plain key holds old's values (the join keeps x's key); a text key is new's text and has no zone or levels
    return(finish(out, "old", by[!is_text]))
  }

  # the summary: one query per count; nothing is collected but the counts and up to 5 repeated keys
  count <- function(x) {
    v <- dplyr::collect(dplyr::summarise(x, .sv_n = dplyr::n()))$.sv_n
    sv_lazy_count(if (length(v) && !is.na(v[1L])) v[1L] else 0)
  }
  one <- function(cond) rlang::expr(sum(dplyr::if_else(!!cond, 1L, 0L), na.rm = TRUE))
  sums <- list(.sv_n = rlang::expr(dplyr::n()))
  if (length(conds)) sums$.sv_ch <- one(Reduce(function(a, b) rlang::call2("|", a, b), conds))
  for (k in seq_along(conds)) sums[[paste0(".sv_c", k)]] <- one(conds[[k]])
  res <- dplyr::collect(dplyr::summarise(both(), !!!sums))
  num <- function(nm) {
    v <- res[[nm]]
    if (is.null(v) || !length(v) || is.na(v[1L])) 0L else sv_lazy_count(v[1L])
  }
  n_both <- num(".sv_n")
  n_changed <- if (length(conds)) num(".sv_ch") else 0L
  per_column <- stats::setNames(vapply(seq_along(conds), function(k) as.integer(num(paste0(".sv_c", k))), 1L), nms)

  # keys that repeat in either version
  dups <- function(x) {
    dplyr::distinct(dplyr::filter(dplyr::select(x, dplyr::all_of(jb)), dplyr::n() > 1L, .by = dplyr::all_of(jb)))
  }
  rep_keys <- dplyr::union(dups(o), dups(n))
  rows_in <- function(x) count(dplyr::semi_join(x, rep_keys, by = jb, na_matches = "na"))
  n_rep <- count(rep_keys)
  sample <- list()
  if (n_rep > 0) {
    got <- as.data.frame(dplyr::collect(utils::head(dplyr::arrange(rep_keys, !!!rlang::syms(jb)), 5L)),
                         stringsAsFactors = FALSE)
    zones <- attr(placed$tbls$old, "sv_tz", exact = TRUE)
    sample <- lapply(seq_len(nrow(got)), function(r) {
      stats::setNames(lapply(seq_along(by), function(j) {
        v <- got[[jb[j]]][r]
        if (is.factor(v)) v <- as.character(v)
        if (inherits(v, "POSIXct")) attr(v, "tzone") <- sv_lazy_zone_for(zones, by[j])
        v
      }), by)
    })
  }
  list(
    by = by, n_old = count(placed$tbls$old), n_new = count(placed$tbls$new),
    added = count(added()), removed = count(removed()), changed = n_changed,
    same = n_both - n_changed,
    repeated_keys = n_rep, repeated_rows_old = rows_in(o), repeated_rows_new = rows_in(n),
    repeated_sample = sample,
    compared = nms, type_changed = plan$type_changed, only_old = plan$only_old, only_new = plan$only_new,
    per_column = per_column, changed_values = sum(per_column))
}
