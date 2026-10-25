#' Column Profile
#'
#' Summarises one column for the column inspector: counts, missingness,
#' distinct values, whether it could serve as a unique key, quartiles and a
#' histogram for numbers, the most common values for text, and data-quality
#' flags (stray spaces, values that differ only in case, numbers stored as text,
#' empty strings, extreme values).
#'
#' @param x A vector (a data frame column), or a lazy table (a duckdb table or an
#'   Arrow table / dataset) together with `column`.
#' @param top_n Number of most common values to keep.
#' @param bins Number of equal-width histogram bins for numeric columns.
#' @param column The column to profile when `x` is a lazy table. The whole table
#'   is profiled by the database, and the result equals the one for the same
#'   column held in memory. Not used for a vector.
#'
#' @return A list with `kind` (`"numeric"`, `"character"`, `"logical"`,
#'   `"date"`, `"datetime"` or `"other"`), `class`, `label` (the `"label"`
#'   attribute, if any), `n`, `n_missing`, `pct_missing`, `n_distinct`
#'   (non-missing), `unique_key`, `stats` (named list: `min`, `q1`, `median`,
#'   `q3`, `max`, and `mean`, `sd` for numbers), `histogram` (`breaks`,
#'   `counts`), `top` (data frame of `value`, `n`), `n_other` (distinct values
#'   not in `top`) and `issues` (character).
#' @export
#' @examples
#' sv_column_profile(c(" Male", "male", "Female", NA))
#' sv_column_profile(c(54, 61, 47, 999, NA))$issues
sv_column_profile <- function(x, top_n = 10L, bins = 20L, column = NULL) {
  if (sv_is_lazy_input(x)) {
    if (is.null(column)) stop("Give `column` for a lazy table.", call. = FALSE)
    return(sv_lazy_column_profile(x, column, top_n = top_n, bins = bins))
  }
  kind <- sv_profile_kind(x)
  label <- attr(x, "label", exact = TRUE)
  n <- length(x)
  miss <- is.na(x)
  vals <- x[!miss]
  if (kind == "numeric") {
    # Distinct numbers, not their text: formatting is only needed for the few shown.
    u <- sort(unique(as.numeric(vals)))
    counts <- tabulate(match(as.numeric(vals), u), length(u))
    values <- u
  } else {
    keys <- if (kind == "logical") ifelse(vals, "TRUE", "FALSE") else as.character(vals)
    tab <- table(keys, useNA = "no")
    counts <- as.integer(tab)
    values <- names(tab)
  }
  n_distinct <- length(values)

  out <- list(
    kind = kind,
    class = class(x)[1],
    label = if (is.character(label) && length(label) == 1L) label else NULL,
    n = n,
    n_missing = sum(miss),
    pct_missing = if (n) sum(miss) / n else 0,
    n_distinct = n_distinct,
    unique_key = n > 0L && !any(miss) && n_distinct == n,
    stats = NULL,
    histogram = NULL,
    top = data.frame(value = character(0), n = integer(0), stringsAsFactors = FALSE),
    n_other = 0L,
    issues = character(0)
  )

  if (kind == "numeric" && length(vals)) {
    v <- as.numeric(vals)
    v <- v[is.finite(v)]
    if (length(v)) {
      q <- stats::quantile(v, c(0, 0.25, 0.5, 0.75, 1), names = FALSE, type = 7)
      out$stats <- list(min = q[1], q1 = q[2], median = q[3], q3 = q[4], max = q[5],
                        mean = mean(v), sd = if (length(v) > 1L) stats::sd(v) else NA_real_)
      out$histogram <- sv_histogram(v, bins)
    }
  } else if (kind %in% c("date", "datetime") && length(vals)) {
    s <- sort(vals)
    pick <- function(p) s[max(1L, ceiling(length(s) * p))]
    fmt <- function(v) format(v)
    out$stats <- list(min = fmt(s[1]), q1 = fmt(pick(0.25)), median = fmt(pick(0.5)),
                      q3 = fmt(pick(0.75)), max = fmt(s[length(s)]))
  }

  # A unique key has no common values worth listing.
  show_top <- kind %in% c("character", "logical", "other") || (kind == "numeric" && n_distinct <= top_n)
  if (show_top && n_distinct && !out$unique_key) {
    ord <- order(-counts, values, method = "radix")
    keep <- utils::head(ord, top_n)
    shown <- values[keep]
    if (is.numeric(shown)) shown <- vapply(shown, format_key, character(1))
    out$top <- data.frame(value = shown, n = counts[keep], stringsAsFactors = FALSE)
    out$n_other <- n_distinct - length(keep)
  }

  out$issues <- sv_profile_issues(kind, vals, out)
  out
}

# Coarse kind of a column, shared by the inspector and the codebook.
sv_profile_kind <- function(x) {
  if (inherits(x, "Date")) return("date")
  if (inherits(x, "POSIXt")) return("datetime")
  if (is.factor(x) || is.character(x)) return("character")
  if (is.logical(x)) return("logical")
  if (is.numeric(x)) return("numeric")
  "other"
}

# Equal-width bins from min to max; the last bin includes max.
sv_histogram <- function(v, bins) {
  lo <- min(v)
  hi <- max(v)
  if (lo == hi) return(list(breaks = c(lo, hi), counts = length(v)))
  width <- (hi - lo) / bins
  idx <- pmin(floor((v - lo) / width), bins - 1) + 1
  list(breaks = lo + width * (0:bins), counts = tabulate(idx, nbins = bins))
}

n_of <- function(n, one, many) paste(fmt_n(n), if (n == 1) one else many)

# Whitespace R's trimws() strips; the lazy twin trims the same set in SQL.
sv_trim_chars <- " \t\r\n"

# A whole value that reads as a number (the "numbers stored as text" flag).
sv_numeric_text_regex <- "^[-+]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?$"

#' The data-quality flags of a column, as text
#'
#' Two steps so that the in-memory and the lazy (database) profile share the
#' wording: `sv_issue_counts()` counts what is wrong in the values, and
#' `sv_format_issues()` turns the counts into sentences.
#' @noRd
sv_profile_issues <- function(kind, vals, p) {
  sv_format_issues(p, sv_issue_counts(kind, vals, p))
}

#' What is wrong with the non-missing values of a column
#'
#' @param kind From `sv_profile_kind()`.
#' @param vals The non-missing values.
#' @param p The profile built so far (needs `stats` for numbers).
#' @return A list: `spaced`, `empty`, `variants_n` (integer), `variants_eg`
#'   (character, up to 3), `numeric_text` (logical), `far_n` (integer) and
#'   `far_eg` (numeric, up to 3, descending).
#' @noRd
sv_issue_counts <- function(kind, vals, p) {
  out <- list(spaced = 0L, empty = 0L, variants_n = 0L, variants_eg = character(0),
              numeric_text = FALSE, far_n = 0L, far_eg = numeric(0))
  if (kind == "character") {
    s <- as.character(vals)
    out$spaced <- sum(s != trimws(s))
    out$empty <- sum(s == "")
    distinct <- unique(s)
    folded <- tolower(trimws(distinct))
    groups <- split(distinct, folded)
    variants <- groups[lengths(groups) > 1L]
    variants <- variants[order(names(variants), method = "radix")]
    out$variants_n <- length(variants)
    if (length(variants)) {
      out$variants_eg <- utils::head(sort(variants[[1]], method = "radix"), 3L)
    }
    nonblank <- trimws(s[trimws(s) != ""])
    out$numeric_text <- length(nonblank) > 0L && all(grepl(sv_numeric_text_regex, nonblank))
  }
  if (kind == "numeric" && !is.null(p$stats)) {
    iqr <- p$stats$q3 - p$stats$q1
    if (is.finite(iqr) && iqr > 0) {
      v <- as.numeric(vals)
      far <- v[is.finite(v) & (v < p$stats$q1 - 3 * iqr | v > p$stats$q3 + 3 * iqr)]
      out$far_n <- length(far)
      out$far_eg <- utils::head(sort(unique(far), decreasing = TRUE), 3L)
    }
  }
  out
}

#' The sentences for the counts of `sv_issue_counts()`
#' @param p The profile built so far (`n`, `n_missing`, `n_distinct`).
#' @param counts From `sv_issue_counts()` or its lazy twin.
#' @return A character vector.
#' @noRd
sv_format_issues <- function(p, counts) {
  out <- character(0)
  if (p$n > 0L && p$n_missing == p$n) return("All values are missing.")
  if (p$n_distinct == 1L && p$n > 1L) out <- c(out, "Only one distinct value.")
  if (counts$spaced) {
    out <- c(out, sprintf("%s leading or trailing spaces.", n_of(counts$spaced, "value has", "values have")))
  }
  if (counts$empty) {
    out <- c(out, sprintf("%s, not NA.", n_of(counts$empty, "empty string", "empty strings")))
  }
  if (counts$variants_n) {
    eg <- paste0("\"", counts$variants_eg, "\"", collapse = " / ")
    out <- c(out, sprintf("%s only in case or spacing (e.g. %s).",
                          n_of(counts$variants_n, "value differs", "values differ"), eg))
  }
  if (isTRUE(counts$numeric_text)) out <- c(out, "All values are numbers stored as text.")
  if (counts$far_n) {
    eg <- vapply(counts$far_eg, format_key, character(1))
    out <- c(out, sprintf("%s beyond 3 IQR of the quartiles (e.g. %s).",
                          n_of(counts$far_n, "value lies", "values lie"), paste(eg, collapse = ", ")))
  }
  out
}

#' Codebook (Data Dictionary)
#'
#' One row per column across one or more tables: type, label, missingness,
#' distinct values, whether the column is a unique key, range and quartiles,
#' mean and SD, the most common values and data-quality flags. Write it to CSV
#' or Excel to document a dataset or check it before analysis.
#'
#' @param ... Data frames, duckdb tables or Arrow tables, or one list of them.
#'   Names default to the argument expressions, as in [sideview()]. A duckdb or
#'   Arrow table is profiled in full inside the database; it is never collected.
#' @param top_n Number of most common values listed in `top_values`.
#' @param file Optional path ending in `.csv` or `.xlsx` (needs the `writexl`
#'   package). The codebook is still returned, invisibly.
#' @param progress Optional `function(table, j, n_cols)`, called before each
#'   column is profiled.
#'
#' @return A data frame with columns `table`, `column`, `position`, `class`,
#'   `label`, `n`, `rows_profiled`, `n_missing`, `pct_missing`, `n_distinct`,
#'   `unique_key`, `min`, `q1`, `median`, `q3`, `max` (as text, so dates fit),
#'   `mean`, `sd`, `top_values` and `issues`. `rows_profiled` is the number of
#'   rows the profile used; it equals `n` except for a preview of a larger table.
#' @export
#' @examples
#' patients <- data.frame(id = 1:4, sex = c("M", "F", "f", NA), age = c(40, 51, 62, 999))
#' sv_codebook(patients)
#' visits <- data.frame(id = c(1, 1, 2, 5), sbp = c(120, 135, 128, 141))
#' out <- tempfile(fileext = ".csv")
#' sv_codebook(patients, visits, file = out)
#' unlink(out)
sv_codebook <- function(..., top_n = 5L, file = NULL, progress = NULL) {
  tables <- list(...)
  exprs <- as.list(substitute(list(...))[-1])
  if (length(tables) == 1L && sv_is_table_list(tables[[1]])) {
    tables <- tables[[1]]
    exprs <- list()
  }
  if (!length(tables)) stop("Give at least one data frame.", call. = FALSE)
  nms <- names(tables) %||% rep("", length(tables))
  for (i in seq_along(tables)) {
    if (!nzchar(nms[i])) {
      nms[i] <- if (i <= length(exprs) && is.name(exprs[[i]])) as.character(exprs[[i]]) else paste0("table_", i)
    }
  }
  # check every input before the first (possibly slow) profile
  for (i in seq_along(tables)) {
    tb <- tables[[i]]
    if (!is.data.frame(tb) && !sv_is_lazy_input(tb) && !inherits(tb, "sv_preview_table")) {
      stop(sprintf("`%s` is not a data frame or lazy table.", nms[i]), call. = FALSE)
    }
  }
  # one private connection serves every lazy table, and is closed on the way out
  con_env <- sv_lazy_env()
  on.exit(sv_lazy_close(con_env), add = TRUE)
  rows <- list()
  for (i in seq_along(tables)) {
    tb <- tables[[i]]
    n_total <- NULL
    if (inherits(tb, "sv_preview_table")) {
      n_total <- tb$n_total
      tb <- tb$data
    }
    lazy <- sv_is_lazy_input(tb)
    cols <- if (lazy) sv_lazy_names(tb) else names(tb)
    for (j in seq_along(cols)) {
      if (is.function(progress)) progress(nms[i], j, length(cols))
      x <- if (lazy) list(tbl = tb, column = cols[j], con_env = con_env) else tb[[j]]
      rows[[length(rows) + 1L]] <- sv_codebook_row(nms[i], cols[j], j, x, top_n, n_total = n_total)
    }
  }
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  if (!is.null(file)) {
    sv_write_codebook(out, file)
    return(invisible(out))
  }
  out
}

# `x` is a column vector, or list(tbl, column, con_env) for a lazy table. `n_total` is the
# true row count of a table profiled from a preview: `n` reports it, `rows_profiled` the rows used.
sv_codebook_row <- function(table, column, position, x, top_n, n_total = NULL) {
  p <- if (is.list(x) && !is.data.frame(x) && sv_is_lazy_input(x$tbl)) {
    sv_lazy_column_profile(x$tbl, x$column, top_n = top_n, con_env = x$con_env %||% sv_lazy_env())
  } else {
    sv_column_profile(x, top_n = top_n)
  }
  stat <- function(k) {
    v <- p$stats[[k]]
    if (is.null(v) || (is.numeric(v) && !is.finite(v))) return(NA_character_)
    if (is.numeric(v)) return(format_key(signif(v, 6)))
    as.character(v)
  }
  num <- function(k) {
    v <- p$stats[[k]]
    if (is.numeric(v) && is.finite(v)) signif(v, 6) else NA_real_
  }
  top <- if (nrow(p$top)) {
    s <- paste0(p$top$value, " (", p$top$n, ")", collapse = "; ")
    if (p$n_other > 0L) paste0(s, "; +", p$n_other, " more") else s
  } else NA_character_
  data.frame(
    table = table, column = column, position = position, class = p$class,
    label = p$label %||% NA_character_,
    n = n_total %||% p$n, rows_profiled = p$n,
    n_missing = p$n_missing, pct_missing = round(100 * p$pct_missing, 2),
    n_distinct = p$n_distinct, unique_key = p$unique_key,
    min = stat("min"), q1 = stat("q1"), median = stat("median"), q3 = stat("q3"), max = stat("max"),
    mean = num("mean"), sd = num("sd"),
    top_values = top,
    issues = if (length(p$issues)) paste(p$issues, collapse = " ") else NA_character_,
    stringsAsFactors = FALSE
  )
}

#' A table profiled from a preview, with its true size
#'
#' The gadget uses this for a lazy card whose source it can no longer reach:
#' the codebook profiles the preview rows and reports `n_total` as `n`.
#' @noRd
sv_preview_table <- function(df, n_total) {
  structure(list(data = df, n_total = n_total), class = "sv_preview_table")
}

sv_write_codebook <- function(cb, file) {
  if (grepl("\\.xlsx$", file, ignore.case = TRUE)) {
    if (!requireNamespace("writexl", quietly = TRUE)) {
      stop("Writing .xlsx needs the writexl package: install.packages(\"writexl\"), or use a .csv path.",
           call. = FALSE)
    }
    writexl::write_xlsx(list(codebook = cb), file)
  } else if (grepl("\\.csv$", file, ignore.case = TRUE)) {
    utils::write.csv(cb, file, row.names = FALSE, na = "")
  } else {
    stop("`file` must end in .csv or .xlsx.", call. = FALSE)
  }
  invisible(file)
}

# Profile as plain lists for Shiny (data frames would serialise column-wise).
sv_column_profile_json <- function(p) {
  p$top <- lapply(seq_len(nrow(p$top)), function(i) list(value = p$top$value[i], n = p$top$n[i]))
  p$issues <- as.list(p$issues)
  if (!is.null(p$histogram)) p$histogram <- lapply(p$histogram, as.list)
  p
}

# Where the gadget's "Export codebook" writes: an RStudio save dialog when there is
# one, else a new file in the working directory. NULL when the user cancels.
sv_choose_codebook_path <- function() {
  if (rstudioapi::isAvailable() && rstudioapi::hasFun("selectFile")) {
    path <- rstudioapi::selectFile(
      caption = "Save codebook", label = "Save", path = file.path(getwd(), "codebook.csv"),
      filter = "Codebook (*.csv *.xlsx)", existing = FALSE
    )
    if (is.null(path) || !nzchar(path)) return(NULL)
    if (!grepl("\\.(csv|xlsx)$", path, ignore.case = TRUE)) path <- paste0(path, ".csv")
    return(path)
  }
  path <- file.path(getwd(), "codebook.csv")
  i <- 1L
  while (file.exists(path)) {
    i <- i + 1L
    path <- file.path(getwd(), sprintf("codebook_%d.csv", i))
  }
  path
}
