# Server-side row windows for cards larger than the HTML preview.
#
# The gadget only ships the first 500 rows of each table to the browser, so
# sorting and filtering in the browser alone would be silently wrong for larger
# tables. Instead the client asks for a window of rows under a sort/filter spec
# and these helpers answer from the full data frame, with dplyr semantics.

# Quote a string as an R string literal.
sv_r_string <- function(x) {
  x <- gsub("\\", "\\\\", x, fixed = TRUE)
  x <- gsub("\"", "\\\"", x, fixed = TRUE)
  x <- gsub("\n", "\\n", x, fixed = TRUE)
  paste0("\"", x, "\"")
}

#' Build an R filter condition for one column
#'
#' @param col Column name.
#' @param op One of `"contains"`, `"equals"`, `"not_equals"`, `"gt"`, `"gte"`,
#'   `"lt"`, `"lte"`.
#' @param value Value typed by the user (character).
#' @param numeric Logical; whether the column is numeric. Comparison values for
#'   numeric columns are written as numbers, otherwise as strings.
#' @return A single character string, e.g. `"age > 50"`.
#' @noRd
sv_filter_condition <- function(col, op, value, numeric = FALSE) {
  esc_col <- sv_escape_ident(col)
  value <- as.character(value)
  num_ok <- isTRUE(numeric) && !is.na(suppressWarnings(as.numeric(value)))
  lit <- if (num_ok) format(as.numeric(value), digits = 15) else sv_r_string(value)
  switch(op,
    contains = sprintf("grepl(%s, %s, fixed = TRUE)", sv_r_string(value), esc_col),
    equals = sprintf("%s == %s", esc_col, lit),
    not_equals = sprintf("%s != %s", esc_col, lit),
    gt = sprintf("%s > %s", esc_col, lit),
    gte = sprintf("%s >= %s", esc_col, lit),
    lt = sprintf("%s < %s", esc_col, lit),
    lte = sprintf("%s <= %s", esc_col, lit),
    stop("Unknown filter operator: ", op)
  )
}

# Row order (1-based indices into df) for a sort/filter spec.
# `sort` is list(col, dir) with dir "asc"/"desc"; `filter` is list(col, op, val).
sv_rows_order <- function(df, sort = NULL, filter = NULL) {
  idx <- seq_len(nrow(df))
  if (!is.null(filter) && !is.null(filter$col) && filter$col %in% names(df)) {
    cond <- sv_filter_condition(
      filter$col, filter$op %||% "equals", filter$val %||% "",
      numeric = is.numeric(df[[filter$col]])
    )
    keep <- tryCatch(
      eval(parse(text = cond)[[1]], envir = df, enclos = baseenv()),
      error = function(e) rep(FALSE, nrow(df))
    )
    keep <- rep_len(as.logical(keep), nrow(df))
    idx <- which(!is.na(keep) & keep)
  }
  if (!is.null(sort) && !is.null(sort$col) && sort$col %in% names(df) &&
      (sort$dir %||% "none") %in% c("asc", "desc")) {
    x <- df[[sort$col]][idx]
    if (is.list(x)) x <- vapply(x, function(v) paste(format(v), collapse = ","), character(1))
    # dplyr::arrange(): C-locale strings, NAs last in both directions, stable ties.
    o <- order(x, decreasing = identical(sort$dir, "desc"), na.last = TRUE, method = "radix")
    idx <- idx[o]
  }
  idx
}

# Format a column slice the same way render_card_tag() formats preview cells.
sv_format_cells <- function(x) {
  if (is.list(x)) {
    return(vapply(x, function(v) {
      if (is.null(v) || length(v) == 0L) "" else if (length(v) > 1L || is.list(v)) "[list]" else as.character(v)
    }, character(1)))
  }
  out <- as.character(x)
  out[is.na(x)] <- NA_character_
  out
}

#' Answer a row-window request from the full data
#'
#' @param df The card's full data frame.
#' @param req List with `offset` (0-based), `limit`, optional `sort` and `filter`.
#' @param order_cache Optional environment used to memoise the row order per spec.
#' @return A list with `offset`, `total`, `row_ids` (0-based) and `columns`
#'   (named list of character vectors, `NA` for missing).
#' @noRd
sv_rows_window <- function(df, req, order_cache = NULL) {
  spec_key <- paste(
    unlist(req$sort %||% list()), "|", unlist(req$filter %||% list()),
    collapse = "\u001f"
  )
  idx <- NULL
  if (!is.null(order_cache) && identical(order_cache$key, spec_key)) idx <- order_cache$idx
  if (is.null(idx)) {
    idx <- sv_rows_order(df, sort = req$sort, filter = req$filter)
    if (!is.null(order_cache)) {
      order_cache$key <- spec_key
      order_cache$idx <- idx
    }
  }
  offset <- max(0L, as.integer(req$offset %||% 0L))
  limit <- max(1L, min(2000L, as.integer(req$limit %||% 200L)))
  win <- idx[seq.int(offset + 1L, length.out = max(0L, min(limit, length(idx) - offset)))]
  win <- win[!is.na(win)]
  cols <- lapply(df, function(col) sv_format_cells(col[win]))
  list(
    offset = offset,
    total = length(idx),
    row_ids = as.integer(win - 1L),
    columns = cols
  )
}
