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
#' @section Duckdb and Arrow tables:
#' When `x` or `y` is a duckdb table or an Arrow table, the check runs inside
#' duckdb on the whole table and only the counts come back into R; the result
#' equals the one for the same data held in memory. If the tables are on two
#' different duckdb connections the check does not run. Arrow tables are
#' handed to duckdb with `arrow::to_duckdb()`, and a data frame is registered
#' temporarily; both are removed afterwards. Known differences from the
#' in-memory check: keys of different types are compared as text, double keys
#' are compared exactly, and an in-memory POSIXct key is compared as text where
#' a database key is compared as an instant.
#'
#' @param x,y Tables to join (`x` is the left table): data frames, or duckdb
#'   tables and Arrow tables, which are checked in full without loading them into R.
#' @param by Join columns: a character vector as in [dplyr::left_join()], where
#'   names are columns of `x` and values columns of `y`
#'   (`c("id", "site" = "site_code")`). Unnamed entries use the same name on
#'   both sides.
#' @param sample_n Number of unmatched keys to list for each side.
#' @param x_name,y_name Table names used in messages.
#' @param rule Optional date rule for the join, a list with the fields of a join
#'   step's rule: `shape` (`"between"`, `"window"`, `"before"`, `"after"` or
#'   `"overlaps"`) and its columns (`xCol`, `yCol`, `yFrom`, `yTo`, `xFrom`, `xTo`), a
#'   window's whole-number `from` and `to` (days, -3650 to 3650) and, for
#'   `"before"`/`"after"`, `inclusive`. The check then counts the rows the rule
#'   keeps, with `na_matches = "never"`: under a rule a missing key matches
#'   nothing. A rule that does not hold (see the message) is an error. Only for
#'   data frames.
#'
#' @return An object of class `sv_join_diagnostics`: a list with `by`
#'   (data frame of `x`/`y` columns), `n_x`, `n_y`, `distinct_x`, `distinct_y`,
#'   `distinct_matched`, `matched_x`, `matched_y` (rows with a partner),
#'   `match_rate_x`, `match_rate_y`, `na_x`, `na_y` (rows with a missing key),
#'   `dup_keys_x`, `dup_keys_y` (keys that occur more than once),
#'   `relationship`, `rows` (named list of row counts per join type),
#'   `unmatched_x`, `unmatched_y` (sample keys), `type_issues`, `hints` (list
#'   of `fix`, `label`, `extra_x`, `extra_y`), `strict_args`, `warnings` and
#'   `status` (`"ok"`, `"warn"` or `"error"`).
#'
#'   `strict_args` is a named list with an entry per join type (`left_join`,
#'   `inner_join`, `right_join`, `full_join`) holding the arguments a Strict
#'   join writes (`relationship`, and `unmatched = "error"` when every row of
#'   the checked side has a partner); an entry is absent when Strict would write
#'   nothing for that type (no matches; right and full joins under a nearest-match
#'   rule). With a `rule` the result also has `rule`, `rule_kind` (the kind of the
#'   rule's first `x` column), `rule_dropped_x` and `rule_dropped_y` (rows that have a
#'   key partner but no pair that satisfies the rule), and `rows$right_join` /
#'   `rows$full_join` are `NA` under a nearest-match rule.
#' @export
#' @examples
#' patients <- data.frame(id = c(1, 2, 3, 4), age = c(40, 51, 62, 33))
#' visits <- data.frame(id = c(1, 1, 2, 5), visit = 1:4)
#' sv_join_diagnostics(patients, visits, by = "id")
sv_join_diagnostics <- function(x, y, by, sample_n = 5L, x_name = "x", y_name = "y", rule = NULL) {
  if (sv_is_lazy_input(x) || sv_is_lazy_input(y)) {
    return(sv_lazy_join_diagnostics(x, y, by, sample_n = sample_n, x_name = x_name, y_name = y_name))
  }
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

  nearest <- FALSE
  if (!is.null(rule)) {
    problem <- sv_join_rule_problem(rule, vapply(x, sv_key_kind, character(1)),
                                    vapply(y, sv_key_kind, character(1)))
    if (!is.null(problem)) stop(problem, call. = FALSE)
    rule <- sv_join_rule_normalize(rule)
    nearest <- rule$shape %in% c("before", "after")
    pairs <- sv_join_rule_pairs(x, y, by_x, by_y, rule)
    rc <- sv_join_rule_counts(pairs, nrow(x), nrow(y), core, nearest)
    # rows with a key partner (a missing key has none) but no rule pair
    has_x <- !sv_join_any_na(x[by_x]) & kx %in% ky[!sv_join_any_na(y[by_y])]
    has_y <- !sv_join_any_na(y[by_y]) & ky %in% kx[!sv_join_any_na(x[by_x])]
    rule_dropped_x <- sum(has_x) - rc$matched_x
    rule_dropped_y <- sum(has_y) - rc$matched_y
    core$unmatched_x <- unique(kx[rc$unmatched_rows_x])
    core$unmatched_y <- unique(ky[rc$unmatched_rows_y])
    for (f in c("matched_x", "matched_y", "relationship", "rows")) core[[f]] <- rc[[f]]
  }

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
  out$strict_args <- sv_join_strict_args(core, nrow(x), nrow(y), rule)
  if (!is.null(rule)) {
    out$rule <- rule
    out$rule_kind <- sv_key_kind(x[[rule[[sv_rule_slots(rule$shape)[1L]]]]])
    out$rule_dropped_x <- rule_dropped_x
    out$rule_dropped_y <- rule_dropped_y
  }

  # Fixes that would match more rows, each measured on its own against the raw keys.
  if (core$matched_x < nrow(x) || core$matched_y < nrow(y)) {
    fixes <- list(
      trim = list(label = "trimming whitespace", fn = function(v) trimws(v)),
      case = list(label = "ignoring case", fn = function(v) tolower(v)),
      zeros = list(label = "dropping leading zeros", fn = function(v) sub("^0+(?=[0-9])", "", v, perl = TRUE))
    )
    for (nm in names(fixes)) {
      if (is.null(rule)) {
        fx <- sv_join_keys(x[by_x], fixes[[nm]]$fn)
        fy <- sv_join_keys(y[by_y], fixes[[nm]]$fn)
        alt <- sv_join_counts(fx, fy)
      } else {
        alt_pairs <- sv_join_rule_pairs(x, y, by_x, by_y, rule, fn = fixes[[nm]]$fn)
        alt <- list(matched_x = length(unique(alt_pairs$.rx)), matched_y = length(unique(alt_pairs$.ry)))
      }
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
  if (!is.null(x$rule)) {
    cat("  rule: ", sv_join_rule_label(x$rule, x$rule_kind), "
", sep = "")
    cat(sprintf("  dropped by the rule: %s x rows, %s y rows
", fmt_n(x$rule_dropped_x), fmt_n(x$rule_dropped_y)))
  }
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
  hit_y <- uy %in% ux
  core <- sv_join_counts_from(
    list(
      distinct_x = length(ux), distinct_y = length(uy), distinct_matched = sum(hit),
      matched_x = sum(cx[hit]), matched_y = sum(cy[hit_y]),
      dup_keys_x = sum(cx > 1), dup_keys_y = sum(cy > 1),
      many_x = any(cx[hit] > 1), many_y = any(cy_for_x[hit] > 1),
      inner = sum(as.numeric(cx[hit]) * cy_for_x[hit])
    ),
    n_x = length(kx), n_y = length(ky)
  )
  core$unmatched_x <- ux[!hit]
  core$unmatched_y <- uy[!hit_y]
  core
}

# The join arithmetic, from a few scalars. Shared by the in-memory check (which
# gets them from per-key counts in R) and the lazy check (which gets them from
# one SQL aggregate), so both give the same numbers.
#   distinct_x/y      distinct keys in each table
#   distinct_matched  distinct keys present in both
#   matched_x/y       rows whose key is in the other table
#   dup_keys_x/y      keys that occur more than once
#   many_x/y          some matched key repeats in x / in y
#   inner             rows an inner join returns
sv_join_counts_from <- function(s, n_x, n_y) {
  relationship <- if (!s$distinct_matched) {
    "no matches"
  } else if (s$many_x && s$many_y) {
    "many-to-many"
  } else if (s$many_y) {
    "one-to-many"
  } else if (s$many_x) {
    "many-to-one"
  } else {
    "one-to-one"
  }
  list(
    distinct_x = s$distinct_x, distinct_y = s$distinct_y, distinct_matched = s$distinct_matched,
    matched_x = s$matched_x, matched_y = s$matched_y,
    dup_keys_x = s$dup_keys_x, dup_keys_y = s$dup_keys_y,
    relationship = relationship,
    rows = list(
      left_join = s$inner + (n_x - s$matched_x),
      inner_join = s$inner,
      full_join = s$inner + (n_x - s$matched_x) + (n_y - s$matched_y),
      right_join = s$inner + (n_y - s$matched_y),
      semi_join = s$matched_x,
      anti_join = n_x - s$matched_x
    )
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
    how <- if (is.null(d$rule)) {
      "dplyr matches NA to NA by default (na_matches = \"na\")."
    } else {
      "with a date rule they match nothing (na_matches = \"never\")."
    }
    w <- c(w, sprintf("Missing keys (%s in %s, %s in %s): %s",
                      fmt_n(d$na_x), x_name, fmt_n(d$na_y), y_name, how))
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
  # a nearest match has no right/full row count
  d$rows <- d$rows[!vapply(d$rows, is.na, logical(1))]
  d$strict_args <- if (length(d$strict_args)) d$strict_args else structure(list(), names = character(0))
  d
}
