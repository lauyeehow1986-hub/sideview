#' Column Profile
#'
#' Summarises one column for the column inspector: counts, missingness,
#' distinct values, whether it could serve as a unique key, quartiles and a
#' histogram for numbers, the most common values for text, and data-quality
#' flags (stray spaces, values that differ only in case, numbers stored as text,
#' empty strings, extreme values).
#'
#' @param x A vector (a data frame column).
#' @param top_n Number of most common values to keep.
#' @param bins Number of equal-width histogram bins for numeric columns.
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
sv_column_profile <- function(x, top_n = 10L, bins = 20L) {
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

sv_profile_issues <- function(kind, vals, p) {
  out <- character(0)
  if (p$n > 0L && p$n_missing == p$n) return("All values are missing.")
  if (p$n_distinct == 1L && p$n > 1L) out <- c(out, "Only one distinct value.")
  if (kind == "character") {
    s <- as.character(vals)
    spaced <- sum(s != trimws(s))
    if (spaced) out <- c(out, sprintf("%s leading or trailing spaces.", n_of(spaced, "value has", "values have")))
    empty <- sum(s == "")
    if (empty) out <- c(out, sprintf("%s, not NA.", n_of(empty, "empty string", "empty strings")))
    distinct <- unique(s)
    folded <- tolower(trimws(distinct))
    groups <- split(distinct, folded)
    variants <- groups[lengths(groups) > 1L]
    variants <- variants[order(names(variants), method = "radix")]
    if (length(variants)) {
      eg <- paste0("\"", utils::head(sort(variants[[1]], method = "radix"), 3L), "\"", collapse = " / ")
      out <- c(out, sprintf("%s only in case or spacing (e.g. %s).",
                            n_of(length(variants), "value differs", "values differ"), eg))
    }
    nonblank <- trimws(s[trimws(s) != ""])
    if (length(nonblank) && all(grepl("^[-+]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?$", nonblank))) {
      out <- c(out, "All values are numbers stored as text.")
    }
  }
  if (kind == "numeric" && !is.null(p$stats)) {
    iqr <- p$stats$q3 - p$stats$q1
    if (is.finite(iqr) && iqr > 0) {
      v <- as.numeric(vals)
      far <- v[is.finite(v) & (v < p$stats$q1 - 3 * iqr | v > p$stats$q3 + 3 * iqr)]
      if (length(far)) {
        eg <- vapply(utils::head(sort(unique(far), decreasing = TRUE), 3L), format_key, character(1))
        out <- c(out, sprintf("%s beyond 3 IQR of the quartiles (e.g. %s).",
                              n_of(length(far), "value lies", "values lie"), paste(eg, collapse = ", ")))
      }
    }
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
#' @param ... Data frames, or one list of data frames. Names default to the
#'   argument expressions, as in [sideview()].
#' @param top_n Number of most common values listed in `top_values`.
#' @param file Optional path ending in `.csv` or `.xlsx` (needs the `writexl`
#'   package). The codebook is still returned, invisibly.
#'
#' @return A data frame with columns `table`, `column`, `position`, `class`,
#'   `label`, `n`, `n_missing`, `pct_missing`, `n_distinct`, `unique_key`,
#'   `min`, `q1`, `median`, `q3`, `max` (as text, so dates fit), `mean`, `sd`,
#'   `top_values` and `issues`.
#' @export
#' @examples
#' patients <- data.frame(id = 1:4, sex = c("M", "F", "f", NA), age = c(40, 51, 62, 999))
#' sv_codebook(patients)
#' visits <- data.frame(id = c(1, 1, 2, 5), sbp = c(120, 135, 128, 141))
#' out <- tempfile(fileext = ".csv")
#' sv_codebook(patients, visits, file = out)
#' unlink(out)
sv_codebook <- function(..., top_n = 5L, file = NULL) {
  tables <- list(...)
  exprs <- as.list(substitute(list(...))[-1])
  if (length(tables) == 1L && is.list(tables[[1]]) && !is.data.frame(tables[[1]])) {
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
  rows <- list()
  for (i in seq_along(tables)) {
    df <- tables[[i]]
    if (!is.data.frame(df)) stop(sprintf("`%s` is not a data frame.", nms[i]), call. = FALSE)
    for (j in seq_along(df)) {
      rows[[length(rows) + 1L]] <- sv_codebook_row(nms[i], names(df)[j], j, df[[j]], top_n)
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

sv_codebook_row <- function(table, column, position, x, top_n) {
  p <- sv_column_profile(x, top_n = top_n)
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
    n = p$n, n_missing = p$n_missing, pct_missing = round(100 * p$pct_missing, 2),
    n_distinct = p$n_distinct, unique_key = p$unique_key,
    min = stat("min"), q1 = stat("q1"), median = stat("median"), q3 = stat("q3"), max = stat("max"),
    mean = num("mean"), sd = num("sd"),
    top_values = top,
    issues = if (length(p$issues)) paste(p$issues, collapse = " ") else NA_character_,
    stringsAsFactors = FALSE
  )
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
