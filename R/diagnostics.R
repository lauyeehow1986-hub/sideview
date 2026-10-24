#' Join Diagnostics
#'
#' Checks a join before you run it: how many rows match in each direction, the
#' key relationship (one-to-one, one-to-many, many-to-many), how many rows each
#' join type returns, missing and duplicated keys, a sample of unmatched keys,
#' and fixes that would match more rows, each measured on its own (trimming
#' whitespace, ignoring case, dropping leading zeros). Keys are compared the way `dplyr` joins compare
#' them by default, so `NA` matches `NA`.
#'
#' The canvas runs this whenever two columns are connected and shows the result
#' on the join step and in the Discrepancy tab.
#'
#' @param x,y Data frames to join (`x` is the left table).
#' @param by Join columns: a character vector as in [dplyr::left_join()], where
#'   names are columns of `x` and values columns of `y`
#'   (`c("id", "site" = "site_code")`). Unnamed entries use the same name on
#'   both sides.
#' @param sample_n Number of unmatched keys to list for each side.
#' @param x_name,y_name Table names used in messages.
#'
#' @return An object of class `sv_join_diagnostics`: a list with `by`
#'   (data frame of `x`/`y` columns), `n_x`, `n_y`, `distinct_x`, `distinct_y`,
#'   `distinct_matched`, `matched_x`, `matched_y` (rows with a partner),
#'   `match_rate_x`, `match_rate_y`, `na_x`, `na_y` (rows with a missing key),
#'   `dup_keys_x`, `dup_keys_y` (keys that occur more than once),
#'   `relationship`, `rows` (named list of row counts per join type),
#'   `unmatched_x`, `unmatched_y` (sample keys), `type_issues`, `hints` (list
#'   of `fix`, `label`, `extra_x`, `extra_y`), `warnings` and `status`
#'   (`"ok"`, `"warn"` or `"error"`).
#' @export
#' @examples
#' patients <- data.frame(id = c(1, 2, 3, 4), age = c(40, 51, 62, 33))
#' visits <- data.frame(id = c(1, 1, 2, 5), visit = 1:4)
#' sv_join_diagnostics(patients, visits, by = "id")
sv_join_diagnostics <- function(x, y, by, sample_n = 5L, x_name = "x", y_name = "y") {
  if (!is.data.frame(x) || !is.data.frame(y)) stop("`x` and `y` must be data frames.", call. = FALSE)
  if (!is.character(by) || !length(by)) stop("`by` must name at least one key column.", call. = FALSE)
  by_x <- if (is.null(names(by))) by else ifelse(nzchar(names(by)), names(by), by)
  by_y <- unname(by)
  miss_x <- setdiff(by_x, names(x))
  miss_y <- setdiff(by_y, names(y))
  if (length(miss_x)) stop(sprintf("Not in %s: %s", x_name, paste(miss_x, collapse = ", ")), call. = FALSE)
  if (length(miss_y)) stop(sprintf("Not in %s: %s", y_name, paste(miss_y, collapse = ", ")), call. = FALSE)

  kx <- sv_join_keys(x[by_x])
  ky <- sv_join_keys(y[by_y])
  core <- sv_join_counts(kx, ky)

  out <- list(
    by = data.frame(x = by_x, y = by_y, stringsAsFactors = FALSE),
    n_x = nrow(x), n_y = nrow(y),
    distinct_x = core$distinct_x, distinct_y = core$distinct_y,
    distinct_matched = core$distinct_matched,
    matched_x = core$matched_x, matched_y = core$matched_y,
    match_rate_x = if (nrow(x)) core$matched_x / nrow(x) else 0,
    match_rate_y = if (nrow(y)) core$matched_y / nrow(y) else 0,
    na_x = sum(sv_join_any_na(x[by_x])), na_y = sum(sv_join_any_na(y[by_y])),
    dup_keys_x = core$dup_keys_x, dup_keys_y = core$dup_keys_y,
    relationship = core$relationship,
    rows = core$rows,
    unmatched_x = sv_join_decode(utils::head(core$unmatched_x, sample_n)),
    unmatched_y = sv_join_decode(utils::head(core$unmatched_y, sample_n)),
    type_issues = sv_join_type_issues(x, y, by_x, by_y, x_name, y_name),
    hints = list()
  )

  # Fixes that would match more rows, each measured on its own against the raw keys.
  if (core$matched_x < nrow(x) || core$matched_y < nrow(y)) {
    fixes <- list(
      trim = list(label = "trimming whitespace", fn = function(v) trimws(v)),
      case = list(label = "ignoring case", fn = function(v) tolower(v)),
      zeros = list(label = "dropping leading zeros", fn = function(v) sub("^0+(?=[0-9])", "", v, perl = TRUE))
    )
    for (nm in names(fixes)) {
      fx <- sv_join_keys(x[by_x], fixes[[nm]]$fn)
      fy <- sv_join_keys(y[by_y], fixes[[nm]]$fn)
      alt <- sv_join_counts(fx, fy)
      extra_x <- alt$matched_x - core$matched_x
      extra_y <- alt$matched_y - core$matched_y
      if (extra_x > 0 || extra_y > 0) {
        out$hints[[length(out$hints) + 1L]] <- list(
          fix = nm, label = fixes[[nm]]$label, extra_x = extra_x, extra_y = extra_y
        )
      }
    }
  }

  out$warnings <- sv_join_warnings(out, x_name, y_name)
  out$status <- if (length(out$type_issues)) "error" else if (length(out$warnings)) "warn" else "ok"
  structure(out, class = "sv_join_diagnostics")
}

#' @export
print.sv_join_diagnostics <- function(x, ...) {
  by <- ifelse(x$by$x == x$by$y, x$by$x, paste0(x$by$x, " = ", x$by$y))
  pct <- function(p) sprintf("%.1f%%", 100 * p)
  cat("<sv_join_diagnostics> by ", paste(by, collapse = ", "), "\n", sep = "")
  cat(sprintf("  relationship: %s\n", x$relationship))
  cat(sprintf("  x rows matched: %s of %s (%s)\n", fmt_n(x$matched_x), fmt_n(x$n_x), pct(x$match_rate_x)))
  cat(sprintf("  y rows matched: %s of %s (%s)\n", fmt_n(x$matched_y), fmt_n(x$n_y), pct(x$match_rate_y)))
  cat("  rows after join:", paste(sprintf("%s %s", sub("_join$", "", names(x$rows)),
                                           vapply(x$rows, fmt_n, character(1))), collapse = " | "), "\n")
  if (length(x$unmatched_x)) cat("  unmatched in x:", paste(x$unmatched_x, collapse = "; "), "\n")
  if (length(x$unmatched_y)) cat("  unmatched in y:", paste(x$unmatched_y, collapse = "; "), "\n")
  for (h in x$hints) {
    gain <- c(if (h$extra_x > 0) paste(fmt_n(h$extra_x), "more x rows"),
              if (h$extra_y > 0) paste(fmt_n(h$extra_y), "more y rows"))
    cat(sprintf("  hint: %s would match %s\n", h$label, paste(gain, collapse = " and ")))
  }
  for (w in c(x$type_issues, x$warnings)) cat("  ! ", w, "\n", sep = "")
  invisible(x)
}

fmt_n <- function(n) format(n, big.mark = ",", scientific = FALSE, trim = TRUE)

# One string per row: key parts as text, NA kept distinct from the text "NA".
sv_join_keys <- function(df, fn = NULL) {
  parts <- lapply(df, function(v) {
    s <- if (is.factor(v)) as.character(v) else if (is.character(v)) v else format_key(v)
    na <- is.na(v)
    if (!is.null(fn) && (is.character(v) || is.factor(v))) s <- fn(s)
    s[na] <- "\u0001NA"
    s
  })
  if (length(parts) == 1L) return(parts[[1]])
  do.call(paste, c(parts, sep = "\u001f"))
}

# Numbers as R prints them in full (1e+06 would not match "1000000").
format_key <- function(v) {
  if (is.numeric(v)) {
    out <- format(v, scientific = FALSE, trim = TRUE, digits = 15)
    # format() pads to a common number of decimals; drop trailing zeros per value.
    out <- ifelse(grepl("\\.", out), sub("\\.?0+$", "", out), out)
    return(out)
  }
  as.character(v)
}

sv_join_decode <- function(keys) {
  if (!length(keys)) return(character(0))
  keys <- gsub("\u0001NA", "NA", keys, fixed = TRUE)
  gsub("\u001f", ", ", keys, fixed = TRUE)
}

sv_join_any_na <- function(df) {
  Reduce(`|`, lapply(df, is.na), FALSE)
}

sv_join_counts <- function(kx, ky) {
  ux <- unique(kx)
  uy <- unique(ky)
  cx <- tabulate(match(kx, ux), length(ux))
  cy <- tabulate(match(ky, uy), length(uy))
  in_y <- match(ux, uy)
  hit <- !is.na(in_y)
  cy_for_x <- integer(length(ux))
  cy_for_x[hit] <- cy[in_y[hit]]
  inner <- sum(as.numeric(cx[hit]) * cy_for_x[hit])
  matched_x <- sum(cx[hit])
  hit_y <- uy %in% ux
  matched_y <- sum(cy[hit_y])
  many_x <- any(cx[hit] > 1)
  many_y <- any(cy_for_x[hit] > 1)
  relationship <- if (!any(hit)) {
    "no matches"
  } else if (many_x && many_y) {
    "many-to-many"
  } else if (many_y) {
    "one-to-many"
  } else if (many_x) {
    "many-to-one"
  } else {
    "one-to-one"
  }
  n_x <- length(kx)
  n_y <- length(ky)
  list(
    distinct_x = length(ux), distinct_y = length(uy), distinct_matched = sum(hit),
    matched_x = matched_x, matched_y = matched_y,
    dup_keys_x = sum(cx > 1), dup_keys_y = sum(cy > 1),
    relationship = relationship,
    rows = list(
      left_join = inner + (n_x - matched_x),
      inner_join = inner,
      full_join = inner + (n_x - matched_x) + (n_y - matched_y),
      right_join = inner + (n_y - matched_y),
      semi_join = matched_x,
      anti_join = n_x - matched_x
    ),
    unmatched_x = ux[!hit],
    unmatched_y = uy[!hit_y]
  )
}

sv_key_kind <- function(v) {
  if (is.factor(v) || is.character(v)) return("character")
  if (inherits(v, "Date")) return("Date")
  if (inherits(v, "POSIXt")) return("date-time")
  if (is.logical(v)) return("logical")
  if (is.numeric(v)) return("numeric")
  class(v)[1]
}

sv_join_type_issues <- function(x, y, by_x, by_y, x_name, y_name) {
  out <- character(0)
  for (i in seq_along(by_x)) {
    kx <- sv_key_kind(x[[by_x[i]]])
    ky <- sv_key_kind(y[[by_y[i]]])
    if (!identical(kx, ky)) {
      col <- if (by_x[i] == by_y[i]) by_x[i] else paste0(by_x[i], " / ", by_y[i])
      out <- c(out, sprintf(
        "%s is %s in %s but %s in %s: dplyr will refuse this join until both sides have the same type.",
        col, kx, x_name, ky, y_name
      ))
    }
  }
  out
}

sv_join_warnings <- function(d, x_name, y_name) {
  w <- character(0)
  if (identical(d$relationship, "many-to-many")) {
    w <- c(w, sprintf(
      "Many-to-many: keys repeat in both tables, so a left join gives %s rows from %s %s rows.",
      fmt_n(d$rows$left_join), fmt_n(d$n_x), x_name
    ))
  }
  if (identical(d$relationship, "no matches") && d$n_x && d$n_y) {
    w <- c(w, sprintf("No %s key matches any %s key.", x_name, y_name))
  } else if (d$n_x && d$match_rate_x < 0.5) {
    w <- c(w, sprintf("Only %.0f%% of %s rows have a match in %s.", 100 * d$match_rate_x, x_name, y_name))
  }
  if (d$na_x || d$na_y) {
    w <- c(w, sprintf(
      "Missing keys (%s in %s, %s in %s): dplyr matches NA to NA by default (na_matches = \"na\").",
      fmt_n(d$na_x), x_name, fmt_n(d$na_y), y_name
    ))
  }
  w
}

# Plain lists for the browser (Shiny serialises data frames column-wise).
sv_join_diagnostics_json <- function(d) {
  d <- unclass(d)
  d$by <- lapply(seq_len(nrow(d$by)), function(i) list(left = d$by$x[i], right = d$by$y[i]))
  d$unmatched_x <- as.list(d$unmatched_x)
  d$unmatched_y <- as.list(d$unmatched_y)
  d$type_issues <- as.list(d$type_issues)
  d$warnings <- as.list(d$warnings)
  d
}
