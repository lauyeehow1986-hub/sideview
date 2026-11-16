# Derived rows: the rows behind a join-check or SUPP-check count, as a table. The console
# (sv_unmatched()) and the canvas card builder both call sv_derive_rows(), so the rows agree.

sv_derive_ops <- c("unmatched", "outside_window", "supp_orphans", "supp_bad_idvarval")

# `by` as a list of {x, y} column pairs: from a character vector (as dplyr takes it) or already a list.
sv_derive_by_pairs <- function(by) {
  if (is.character(by)) {
    if (!length(by)) stop("`by` must name at least one key column.", call. = FALSE)
    by_x <- if (is.null(names(by))) by else ifelse(nzchar(names(by)), names(by), by)
    return(lapply(seq_along(by), function(i) list(x = unname(by_x[i]), y = unname(by[i]))))
  }
  if (!is.list(by) || !length(by)) stop("`by` must name at least one key column.", call. = FALSE)
  lapply(by, function(p) list(x = as.character(p$x), y = as.character(p$y)))
}

sv_derive_rows <- function(op, tables, args) {
  if (!op %in% sv_derive_ops) stop(sprintf("Unknown derive op: %s", op), call. = FALSE)
  if (op %in% c("supp_orphans", "supp_bad_idvarval")) return(sv_derive_supp_rows(op, tables, args))
  if (length(tables) != 2L) stop("A derived table needs two input tables.", call. = FALSE)
  if (any(vapply(tables, sv_is_lazy_input, logical(1)))) {
    if (!sv_has_duckdb()) stop("Unmatched rows of a duckdb or Arrow table need duckdb.", call. = FALSE)
    nms <- names(tables)
    args$op <- op
    if (length(nms) >= 2L && nzchar(nms[1L]) && is.null(args$x_name)) args$x_name <- nms[1L]
    if (length(nms) >= 2L && nzchar(nms[2L]) && is.null(args$y_name)) args$y_name <- nms[2L]
    con_env <- if (is.null(args$con_env)) sv_lazy_env() else args$con_env
    return(sv_lazy_unmatched(tables[[1L]], tables[[2L]], args, con_env))
  }
  if (!all(vapply(tables, is.data.frame, logical(1)))) stop("Input tables must be data frames.", call. = FALSE)
  x <- tables[[1L]]
  y <- tables[[2L]]
  nms <- names(tables)
  x_name <- if (length(nms) >= 1L && nzchar(nms[1L])) nms[1L] else "x"
  y_name <- if (length(nms) >= 2L && nzchar(nms[2L])) nms[2L] else "y"
  pairs <- sv_derive_by_pairs(args$by)
  by_x <- vapply(pairs, function(p) p$x, "")
  by_y <- vapply(pairs, function(p) p$y, "")
  miss_x <- setdiff(by_x, names(x))
  miss_y <- setdiff(by_y, names(y))
  if (length(miss_x)) stop(sprintf("Not in %s: %s", x_name, paste(miss_x, collapse = ", ")), call. = FALSE)
  if (length(miss_y)) stop(sprintf("Not in %s: %s", y_name, paste(miss_y, collapse = ", ")), call. = FALSE)
  issues <- sv_join_type_issues(x, y, by_x, by_y, x_name, y_name)
  if (length(issues)) stop(paste(issues, collapse = " "), call. = FALSE)
  side <- if (identical(args$side, "y")) "y" else "x"
  rule <- args$rule
  if (identical(op, "outside_window") && is.null(rule)) stop("outside_window needs a date rule.", call. = FALSE)
  if (!is.null(rule)) {
    problem <- sv_join_rule_problem(rule, vapply(x, sv_key_kind, character(1)),
                                    vapply(y, sv_key_kind, character(1)))
    if (!is.null(problem)) stop(problem, call. = FALSE)
    rule <- sv_join_rule_normalize(rule)
  }
  keep <- if (side == "x") x else y

  if (is.null(rule)) {
    # na_matches = "na": a missing key matches a missing key, as in a default dplyr join
    out <- if (side == "x") {
      dplyr::anti_join(x, y, by = stats::setNames(by_y, by_x), na_matches = "na")
    } else {
      dplyr::anti_join(y, x, by = stats::setNames(by_x, by_y), na_matches = "na")
    }
    return(out)
  }

  # na_matches = "never": a missing key matches nothing. A row with no key partner is `unmatched`;
  # a row with a key partner but no pair the rule keeps is `outside_window`.
  kx <- sv_join_keys(x[by_x])
  ky <- sv_join_keys(y[by_y])
  na_x <- sv_join_any_na(x[by_x])
  na_y <- sv_join_any_na(y[by_y])
  pr <- sv_join_rule_pairs(x, y, by_x, by_y, rule)
  if (side == "x") {
    has_key <- !na_x & kx %in% ky[!na_y]
    paired <- seq_len(nrow(x)) %in% pr$.rx
  } else {
    has_key <- !na_y & ky %in% kx[!na_x]
    paired <- seq_len(nrow(y)) %in% pr$.ry
  }
  rows <- if (identical(op, "unmatched")) !has_key else has_key & !paired
  out <- keep[rows, , drop = FALSE]
  rownames(out) <- NULL
  out
}

# A syntactic card name for a derived table (decision 3: an explicit `name` is used as it is).
sv_derive_name <- function(op, inputs, args, taken, name = NULL) {
  if (!is.null(name)) {
    nm <- make.names(name)
    if (nm %in% taken) stop(sprintf("A table named %s is already on the canvas.", nm), call. = FALSE)
    return(nm)
  }
  kept_i <- if (identical(args$side, "y")) 2L else 1L
  supp <- if (!is.null(args$supp)) args$supp else inputs[length(inputs)]
  base <- switch(op,
    unmatched = paste0(inputs[kept_i], "_unmatched_", inputs[3L - kept_i]),
    outside_window = paste0(inputs[kept_i], "_outside_window"),
    supp_orphans = paste0(supp, "_orphans"),
    supp_bad_idvarval = paste0(supp, "_bad_idvarval"),
    stop(sprintf("Unknown derive op: %s", op), call. = FALSE))
  base <- make.names(base)
  nm <- base
  i <- 2L
  while (nm %in% taken) {
    nm <- make.names(paste0(base, "_", i))
    i <- i + 1L
  }
  nm
}

#' Rows That Have No Partner in a Join
#'
#' Returns the rows of one table that a join check counts as unmatched, so the
#' number on the join step can be opened as a table. With no `rule` the keys are
#' compared as [dplyr::anti_join()] compares them (`NA` matches `NA`), and the rows
#' are `anti_join(x, y, by)`. With a date `rule` a missing key matches nothing
#' (`na_matches = "never"`); `what = "unmatched"` gives the rows whose key has no
#' partner at all, and `what = "outside_window"` the rows that have a key partner
#' but no pair the rule keeps. The two together are the rows the join check
#' counts as unmatched under the rule.
#'
#' The canvas builds the same rows from its join-check button, and generates code
#' that rebuilds them.
#'
#' @param x,y Tables: data frames, or duckdb or Arrow tables (these stay lazy).
#' @param by Join columns, as in [sv_join_diagnostics()].
#' @param rule Optional date rule, as in [sv_join_diagnostics()].
#' @param side `"x"` for the rows of `x`, `"y"` for the rows of `y`.
#' @param what `"unmatched"` or `"outside_window"` (needs a `rule`).
#' @return The rows of the chosen table, with its columns and row order.
#' @export
#' @examples
#' ae <- data.frame(USUBJID = c("a", "b", NA, "z"), aeterm = c("x", "y", "z", "w"))
#' dm <- data.frame(USUBJID = c("a", "b", "c"))
#' sv_unmatched(ae, dm, "USUBJID")
sv_unmatched <- function(x, y, by, rule = NULL, side = c("x", "y"),
                         what = c("unmatched", "outside_window")) {
  side <- match.arg(side)
  what <- match.arg(what)
  if (identical(what, "outside_window") && is.null(rule)) stop("outside_window needs a date rule.", call. = FALSE)
  sv_derive_rows(what, list(x = x, y = y), list(by = sv_derive_by_pairs(by), rule = rule, side = side))
}

# The SUPP rows behind the check's orphan or bad-IDVARVAL count, in SUPP row order (decision 7: always a
# data frame). The SUPP side and the match are the check's own steps (sv_supp_side(), sv_supp_convert_side(),
# sv_supp_match_df()), so the rows agree with its counts. The parent is never collected in full: it is
# filtered to the subjects the SUPP rows name, reduced to the distinct key and level columns, then collected.
sv_derive_supp_rows <- function(op, tables, args) {
  if (length(tables) != 2L) stop("A derived table needs two input tables.", call. = FALSE)
  parent <- tables[[1L]]
  supp <- tables[[2L]]
  plan <- args$plan
  rdomain <- args$rdomain
  if (is.null(plan) || is.null(rdomain)) stop("A SUPP derived table needs a plan and an RDOMAIN.", call. = FALSE)
  rows <- sv_lazy_supp_rows(supp, rdomain, all_cols = TRUE)
  s <- rows$data
  if (!is.data.frame(s)) s <- as.data.frame(s, stringsAsFactors = FALSE)
  side <- sv_supp_side(s, "SUPP", rdomain)
  if (!is.null(side$error)) stop(side$error, call. = FALSE)
  keys <- as.character(unlist(plan$keys))
  types <- character(0)
  for (l in plan$idvars) {
    if (nzchar(l$idvar)) types[l$idvar] <- as.character(l$type)
  }
  ivs <- side$levels[nzchar(side$levels)]
  if (length(setdiff(ivs, names(types)))) {
    stop("The SUPP table has an IDVAR the plan does not know: check it again.", call. = FALSE)
  }
  pcols <- unique(c(keys, ivs))
  miss <- setdiff(pcols, sv_lazy_names(parent))
  if (length(miss)) stop(sprintf("Not in the parent: %s", paste(miss, collapse = ", ")), call. = FALSE)
  if (is.data.frame(parent)) {
    p <- parent[pcols]
  } else {
    q <- dplyr::select(parent, dplyr::all_of(pcols))
    subj <- unique(as.character(side$supp$USUBJID))
    u <- rlang::sym("USUBJID")
    if (anyNA(subj)) {
      q <- dplyr::filter(q, !!u %in% !!subj[!is.na(subj)] | is.na(!!u))
    } else {
      q <- dplyr::filter(q, !!u %in% !!subj)
    }
    p <- as.data.frame(dplyr::collect(dplyr::distinct(q)), stringsAsFactors = FALSE)
  }
  conv <- sv_supp_convert_side(side, types, keys)
  matched <- sv_supp_match_df(side, conv, p, keys)
  keep <- if (identical(op, "supp_orphans")) !matched & !conv$bad else conv$bad
  out <- side$supp[keep, , drop = FALSE]
  rownames(out) <- NULL
  out
}

#' Rows of a SUPP Table That the Merge Check Counts as Orphans or Bad
#'
#' Returns the `SUPP--` rows behind a count of [sv_supp_check()]: the orphan rows
#' (`what = "orphans"`, `n_orphan`), which convert but find no parent record, or the
#' rows whose `IDVARVAL` does not convert to the type of the parent column
#' (`what = "bad_idvarval"`, `bad_idvarval$n`). The rows are the `SUPP--` columns,
#' in the order of the table, after the `RDOMAIN` filter. A duckdb or Arrow parent
#' stays lazy: only the rows of the subjects the `SUPP--` table names are read.
#'
#' @param parent The parent table: a data frame, or a duckdb or Arrow table.
#' @param supp The `SUPP--` table: a data frame, or a duckdb or Arrow table.
#' @param rdomain The parent domain, as in [sv_supp_check()]. `NULL` uses the
#'   `RDOMAIN` of the first row of an in-memory `supp`.
#' @param what `"orphans"` or `"bad_idvarval"`.
#' @return A data frame with the columns of `supp`.
#' @export
#' @examples
#' ae <- data.frame(USUBJID = c("S1", "S2"), AESEQ = 1:2)
#' suppae <- data.frame(RDOMAIN = "AE", USUBJID = c("S1", "S2", "S2"), IDVAR = "AESEQ",
#'                      IDVARVAL = c("1", "9", "x"), QNAM = "AETRTEM", QVAL = "Y")
#' sv_supp_orphans(ae, suppae)
#' sv_supp_orphans(ae, suppae, what = "bad_idvarval")
sv_supp_orphans <- function(parent, supp, rdomain = NULL, what = c("orphans", "bad_idvarval")) {
  what <- match.arg(what)
  if (is.null(rdomain)) {
    first <- if (is.data.frame(supp) && "RDOMAIN" %in% names(supp)) {
      as.character(supp$RDOMAIN[!is.na(supp$RDOMAIN)][1L])
    } else NA_character_
    if (is.na(first)) stop("Give `rdomain`: the SUPP table does not name one.", call. = FALSE)
    rdomain <- first
  }
  chk <- if (any(vapply(list(parent, supp), sv_is_lazy_input, logical(1)))) {
    sv_lazy_supp_check(parent, supp, "parent", "supp", rdomain = rdomain)
  } else {
    sv_supp_check(parent, supp, "parent", "supp", rdomain = rdomain)
  }
  if (!is.null(chk$error)) stop(chk$error, call. = FALSE)
  sv_derive_rows(if (what == "orphans") "supp_orphans" else "supp_bad_idvarval",
                 list(parent = parent, supp = supp), list(plan = chk$plan, rdomain = rdomain))
}

# The derived-card buttons for a join check `d` (decision 1: R offers them, offers with n == 0 are dropped).
# The counts are the rows the derived card will hold: with a rule, `unmatched` is the rows with no key
# partner and `outside_window` the rows the rule dropped. A key-type clash (decision 2) offers nothing.
sv_derive_offers_join <- function(d, x_name, y_name, by, rule = NULL) {
  if (!is.list(d) || !is.null(d$error) || length(d$type_issues)) return(list())
  dropped_x <- if (is.null(rule)) 0 else d$rule_dropped_x %||% 0
  dropped_y <- if (is.null(rule)) 0 else d$rule_dropped_y %||% 0
  n_un <- c(x = d$n_x - d$matched_x - dropped_x, y = d$n_y - d$matched_y - dropped_y)
  names_of <- c(x = x_name, y = y_name)
  other <- c(x = y_name, y = x_name)
  make <- function(op, side, n, label) {
    list(op = op, inputs = c(x_name, y_name),
         args = list(by = sv_derive_by_pairs(by), rule = rule, side = side), n = as.integer(n), label = label)
  }
  out <- list()
  for (side in c("x", "y")) {
    out[[length(out) + 1L]] <- make("unmatched", side, n_un[[side]],
      sprintf("%s rows with no match in %s (%d)", names_of[[side]], other[[side]], as.integer(n_un[[side]])))
  }
  if (!is.null(rule)) {
    n_ow <- c(x = dropped_x, y = dropped_y)
    for (side in c("x", "y")) {
      out[[length(out) + 1L]] <- make("outside_window", side, n_ow[[side]],
        sprintf("%s rows outside the date window (%d)", names_of[[side]], as.integer(n_ow[[side]])))
    }
  }
  Filter(function(o) o$n > 0L, out)
}

# The derived-card buttons for a SUPP check. The plan is left out (decision 8): R recomputes it.
sv_derive_offers_supp <- function(chk, parent_name, supp_name, rdomain) {
  if (!is.list(chk) || !is.null(chk$error)) return(list())
  mk <- function(op, n, label) {
    list(op = op, inputs = c(parent_name, supp_name), args = list(rdomain = rdomain),
         n = as.integer(n), label = label)
  }
  out <- list(
    mk("supp_orphans", chk$n_orphan %||% 0L,
       sprintf("%s rows with no parent row (%d)", supp_name, as.integer(chk$n_orphan %||% 0L))),
    mk("supp_bad_idvarval", chk$bad_idvarval$n %||% 0L,
       sprintf("%s rows with an unreadable IDVARVAL (%d)", supp_name, as.integer(chk$bad_idvarval$n %||% 0L)))
  )
  Filter(function(o) o$n > 0L, out)
}
