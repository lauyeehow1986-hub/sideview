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
#' @param con_env An environment from [sv_lazy_env()].
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
        tbl
      },
      df = {
        if (!is.null(cols)) src <- src[unique(cols)]
        a <- sv_lazy_attach(as.data.frame(src), con)
        undo[[length(undo) + 1L]] <<- function() sv_lazy_detach(con, a$name)
        a$tbl
      }
    )
  }
  tx <- one(x, origin[1], cols_x)
  ty <- one(y, origin[2], cols_y)
  ok <- TRUE
  list(x = tx, y = ty, cleanup = cleanup)
}

#' Names of the key columns made by [sv_lazy_join_side()]
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
#' @param kinds [sv_lazy_kind()] of each key column.
#' @param text,chr Logical per key: compare as text, is a character key.
#' @param fix `NULL`, `"trim"`, `"case"` or `"zeros"`.
#' @param row Add `.sv_row`, the row number in table order.
#' @noRd
sv_lazy_join_side <- function(tbl, cols, kinds, text, chr, fix = NULL, row = FALSE) {
  kn <- sv_lazy_key_names(length(cols))
  if (row) tbl <- dplyr::mutate(tbl, .sv_row = row_number())
  step1 <- Map(function(col, kind) {
    s <- rlang::sym(col)
    if (identical(kind, "double")) rlang::expr(if_else(is.nan(!!s), NA, !!s)) else s
  }, cols, kinds)
  names(step1) <- kn
  tbl <- dplyr::mutate(tbl, !!!step1)
  step2 <- list()
  for (i in seq_along(cols)) {
    k <- rlang::sym(kn[i])
    e <- k
    if (text[i]) e <- sv_lazy_text_expr(k, kinds[i])
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
#' @return The list [sv_join_counts_from()] takes.
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
#' @noRd
sv_lazy_join_sample <- function(sx, sy, nk, side, n) {
  kn <- sv_lazy_key_names(nk)
  j <- sv_lazy_join_keys(sx, sy, nk, first = side)
  j <- if (identical(side, "x")) {
    dplyr::arrange(dplyr::filter(j, is.na(ny)), fx)
  } else {
    dplyr::arrange(dplyr::filter(j, is.na(nx)), fy)
  }
  keys <- dplyr::collect(utils::head(dplyr::select(j, dplyr::all_of(kn)), n))
  if (!nrow(keys)) return(character(0))
  sv_join_decode(sv_join_keys(keys))
}

#' Join check over the whole tables, run by duckdb
#'
#' The twin of [sv_join_diagnostics()]: the same reply for the same data. The
#' tables are placed on one connection (see [sv_lazy_place()]); the counts come
#' back as one aggregate row, plus at most `sample_n` unmatched keys per side.
#' Whatever was added to a user's connection is removed again, also on error.
#' @inheritParams sv_join_diagnostics
#' @param con_env An environment from [sv_lazy_env()] holding the private
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
  side_x <- function(fix = NULL, row = FALSE) {
    sv_lazy_join_side(placed$x, by_x, lazy_x, text, kind_x == "character", fix, row)
  }
  side_y <- function(fix = NULL, row = FALSE) {
    sv_lazy_join_side(placed$y, by_y, lazy_y, text, kind_y == "character", fix, row)
  }

  cnt_x <- sv_lazy_join_side_counts(side_x(), nk)
  cnt_y <- sv_lazy_join_side_counts(side_y(), nk)
  n_x <- cnt_x$n
  n_y <- cnt_y$n
  s <- sv_lazy_join_scalars(side_x(), side_y(), nk)
  core <- sv_join_counts_from(s, n_x, n_y)

  n_show <- max(0L, as.integer(sample_n))
  unmatched_x <- if (n_show && s$distinct_x > s$distinct_matched) {
    sv_lazy_join_sample(side_x(row = TRUE), side_y(), nk, "x", n_show)
  } else {
    character(0)
  }
  unmatched_y <- if (n_show && s$distinct_y > s$distinct_matched) {
    sv_lazy_join_sample(side_x(), side_y(row = TRUE), nk, "y", n_show)
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

# Names that only exist inside the SQL translation of the verbs above.
utils::globalVariables(c(".sv_row", ".sv_rank", ".sv_na", ".sv_key", "row_number", "if_else", "case_when", "contains", "desc", "cast", "nx", "ny", "fx", "fy", "trim", "regexp_replace"))
