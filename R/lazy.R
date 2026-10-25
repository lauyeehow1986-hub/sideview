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

#' A duckdb tbl for a lazy source
#'
#' A duckdb tbl is returned as is. An arrow object is handed to duckdb on the
#' private connection, zero-copy except for its dictionary columns (decoded by
#' `sv_lazy_decode_dictionaries()`), and cached under `key` when given. The time
#' zones of its timestamp columns, which duckdb does not keep, travel with the
#' tbl as its `sv_tz` attribute (see `sv_lazy_zones()`).
#' @param source A `tbl_duckdb_connection` or an Arrow table / dataset.
#' @param con_env An environment from `sv_lazy_env()`.
#' @param key Optional cache key (usually the card name).
#' @noRd
sv_lazy_tbl <- function(source, con_env, key = NULL) {
  if (inherits(source, "tbl_duckdb_connection")) return(source)
  if (!is.null(key) && !is.null(con_env$tbls[[key]])) return(con_env$tbls[[key]])
  tbl <- arrow::to_duckdb(sv_lazy_decode_dictionaries(source),
                          con = sv_lazy_con(con_env), auto_disconnect = FALSE)
  tbl <- sv_lazy_with_zones(tbl, sv_lazy_zones(source))
  if (!is.null(key)) con_env$tbls[[key]] <- tbl
  tbl
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
#' The zone recorded for it, else UTC: duckdb hands instants back as UTC, and a
#' duckdb TIMESTAMPTZ has no stored zone.
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
#' @noRd
sv_lazy_tz_text_expr <- function(sym, tz, range = NULL) {
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
  full <- rlang::expr(strftime(make_timestamp(!!us + !!off), "%Y-%m-%d %H:%M:%S.%f"))
  # trailing zeros and the bare dot of the fraction go, then a time of 00:00:00 (R shows the date alone)
  rlang::expr(regexp_replace(rtrim(rtrim(!!full, "0"), "."), " 00:00:00$", ""))
}

#' Compare a POSIXct column with a typed value, as R does
#'
#' R reads a string compared with a POSIXct with `as.POSIXct()` (the session
#' zone) and compares instants; a string it cannot read raises an error, which
#' the in-memory window turns into "no rows". The column is compared as exact
#' microseconds since the epoch.
#' @noRd
sv_lazy_tz_cmp_expr <- function(sym, op, value) {
  t <- tryCatch(as.POSIXct(value), error = function(e) NULL)
  if (is.null(t) || length(t) != 1L || is.na(t)) return(rlang::expr(FALSE))
  lit <- sv_lazy_bigint(round(as.numeric(t) * 1e6))
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
#' @return A language object for `dplyr::filter()`.
#' @noRd
sv_lazy_filter_expr <- function(col, op, value, numeric = FALSE, kind = NULL, tz = NULL, tz_range = NULL) {
  kind <- kind %||% (if (isTRUE(numeric)) "other" else "character")
  double <- identical(kind, "double")
  value <- as.character(value)
  num_ok <- isTRUE(numeric) && !is.na(suppressWarnings(as.numeric(value)))
  sym <- rlang::sym(col)
  if (!is.null(tz) && op != "contains") {
    if (!op %in% c("equals", "not_equals", "gt", "gte", "lt", "lte")) stop("Unknown filter operator: ", op)
    return(sv_lazy_tz_cmp_expr(sym, op, value))
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
#' bytewise (as `arrange()` does), `NA` sorts last in both directions, and
#' ties keep the table's own row order. Only the requested window is collected.
#' @param tbl A duckdb tbl (see `sv_lazy_tbl()`).
#' @inheritParams sv_rows_window
#' @return The same list as `sv_rows_window()`.
#' @noRd
sv_lazy_rows_window <- function(tbl, req, order_cache = NULL) {
  # read before any verb: dplyr drops the attribute
  zones <- attr(tbl, "sv_tz")
  spec_key <- paste(
    unlist(req$sort %||% list()), "|", unlist(req$filter %||% list()),
    collapse = "\u001f"
  )
  # 0 rows: the column classes and names, nothing else
  zero <- dplyr::collect(utils::head(tbl, 0L))
  cols <- names(zero)
  # The zone of each POSIXct column: the one Arrow had, else UTC (duckdb hands
  # back UTC instants, and a TIMESTAMPTZ of a duckdb table has no stored zone).
  zone_of <- function(col) {
    if (inherits(zero[[col]], "POSIXct")) sv_lazy_zone_for(zones, col) else NULL
  }

  keep <- NULL
  filter <- req$filter
  if (!is.null(filter) && !is.null(filter$col) && filter$col %in% cols) {
    keep <- sv_lazy_filter_expr(
      filter$col, filter$op %||% "equals", filter$val %||% "",
      numeric = is.numeric(zero[[filter$col]]),
      kind = sv_lazy_kind(zero[[filter$col]]),
      tz = zone_of(filter$col),
      tz_range = if (identical(filter$op %||% "equals", "contains") && !is.null(zone_of(filter$col))) {
        sv_lazy_us_range(tbl, filter$col)
      }
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
      rlang::expr(is.na(!!sym) | isnan(!!sym))
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
  # show each instant in its own zone, as the in-memory window does
  for (cn in cols) {
    tz <- zone_of(cn)
    if (!is.null(tz)) attr(win[[cn]], "tzone") <- tz
  }

  list(
    offset = offset,
    total = total,
    row_ids = as.integer(win$.sv_row - 1L),
    columns = lapply(win[cols], sv_format_cells)
  )
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
  any_na <- Reduce(function(a, b) rlang::expr((!!a) | (!!b)),
                   lapply(rlang::syms(sv_lazy_key_names(nk)), function(s) rlang::expr(is.na(!!s))))
  r <- dplyr::collect(dplyr::summarise(
    side, n = n(), na = sum(if_else(!!any_na, 1, 0), na.rm = TRUE)
  ))
  list(n = as.numeric(r$n), na = if (is.na(r$na)) 0 else as.numeric(r$na))
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
  if (!nrow(keys)) return(character(0))
  # a POSIXct key is shown in its own zone, as the in-memory check does
  for (i in seq_len(nk)) {
    if (!is.null(tzs) && !is.na(tzs[i]) && inherits(keys[[i]], "POSIXct")) attr(keys[[i]], "tzone") <- tzs[[i]]
  }
  sv_join_decode(sv_join_keys(keys))
}

#' Join check over the whole tables, run by duckdb
#'
#' The twin of [sv_join_diagnostics()]: the same reply for the same data. The
#' tables are placed on one connection (see `sv_lazy_place()`); the counts come
#' back as one aggregate row, plus at most `sample_n` unmatched keys per side.
#' Whatever was added to a user's connection is removed again, also on error.
#' @inheritParams sv_join_diagnostics
#' @param con_env An environment from `sv_lazy_env()` holding the private
#'   connection (used when neither side is a duckdb table). When omitted, a
#'   private connection is opened for this call and closed again.
#' @return An `sv_join_diagnostics` object.
#' @noRd
sv_lazy_join_diagnostics <- function(x, y, by, sample_n = 5L, x_name = "x", y_name = "y",
                                     con_env = sv_lazy_env()) {
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

  placed <- sv_lazy_place(x, y, con_env, cols_x = by_x, cols_y = by_y)
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
    hints = list()
  )

  # Fixes that would match more rows, each measured on its own against the raw keys.
  # Only character keys change, so a join without one has nothing to fix.
  if ((core$matched_x < n_x || core$matched_y < n_y) &&
      any(c(kind_x, kind_y) == "character")) {
    labels <- c(trim = "trimming whitespace", case = "ignoring case", zeros = "dropping leading zeros")
    for (nm in names(labels)) {
      alt <- sv_lazy_join_scalars(side_x(nm), side_y(nm), nk)
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
  arrow_type <- NULL
  if (!inherits(tbl, "tbl_lazy")) {
    # an Arrow object: only this column goes to duckdb, and it is unregistered after.
    # The field type is read from the schema first (no scan): duckdb gets a decoded
    # dictionary as text and a timestamp without its zone, so the class (factor /
    # ordered) and the time zone are only known here.
    arrow_type <- sv_lazy_arrow_type(tbl, column)
    tbl <- sv_lazy_tbl(dplyr::select(tbl, dplyr::all_of(column)), con_env)
    name <- dbplyr::remote_name(tbl)
    on.exit(sv_lazy_detach_arrow(sv_lazy_con(con_env), name), add = TRUE, after = FALSE)
  }

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
    class = sv_lazy_class(zero, arrow_type),
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
    # Zone: an Arrow timestamp keeps its zone in the schema, but duckdb hands the
    # instants back as UTC, so they are re-tagged before formatting (the instant is
    # unchanged, the clock time is the one R shows). A duckdb TIMESTAMPTZ has no
    # stored zone and is shown as UTC; a table written to duckdb from a non-UTC
    # POSIXct arrives as UTC instants already.
    tz <- sv_lazy_arrow_tz(arrow_type)
    if (!is.null(tz) && inherits(rows$.sv_v, "POSIXct")) attr(rows$.sv_v, "tzone") <- tz
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
  out
}

#' The Arrow field type of a column, read from the schema (no scan)
#'
#' Works for a Table, a Dataset and a query on either. `NULL` when it cannot be
#' read.
#' @noRd
sv_lazy_arrow_type <- function(x, column) {
  tryCatch(arrow::schema(x)$GetFieldByName(column)$type, error = function(e) NULL)
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
#' @noRd
sv_lazy_class <- function(zero, arrow_type = NULL) {
  if (!is.null(arrow_type) && inherits(arrow_type, "DictionaryType")) {
    return(if (isTRUE(arrow_type$ordered)) "ordered" else "factor")
  }
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
utils::globalVariables(c(".sv_row", ".sv_rank", ".sv_na", ".sv_key", "row_number", "if_else", "case_when", "contains", "desc", "cast", "nx", "ny", "fx", "fy", "trim", "regexp_replace", "regexp_full_match", "quantile_cont", "isfinite", "isnan", "isinf", "n", "rtrim", "sd", "lower", "epoch_us", "make_timestamp", "strftime", ".sv_v", ".sv_t", ".sv_f", ".sv_k", ".sv_n", ".sv_bin", ".sv_rn", ".sv_rk"))
