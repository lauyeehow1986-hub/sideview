# Derived rows: the rows behind a join-check or SUPP-check count, as a table. The console
# (sv_unmatched()) and the canvas card builder both call sv_derive_rows(), so the rows agree.

sv_derive_ops <- c("unmatched", "outside_window", "supp_orphans", "supp_bad_idvarval", "stack",
                   "compare_added", "compare_removed", "compare_changed")

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
  if (identical(op, "stack")) {
    if (any(vapply(tables, sv_is_lazy_input, logical(1)))) {
      if (!sv_has_duckdb()) stop("Stacking a duckdb or Arrow table needs duckdb.", call. = FALSE)
      con_env <- if (is.null(args$con_env)) sv_lazy_env() else args$con_env
      plan <- args$plan %||% sv_stack_plan(tables, args$fixes, args$id_col, con_env)
      return(sv_lazy_stack(tables, plan, con_env))
    }
    plan <- args$plan %||% sv_stack_plan(tables, args$fixes, args$id_col)
    return(sv_stack_rows(tables, plan))
  }
  if (op %in% c("compare_added", "compare_removed", "compare_changed")) {
    if (length(tables) != 2L) stop("A derived table needs two input tables.", call. = FALSE)
    if (any(vapply(tables, sv_is_lazy_input, logical(1)))) {
      if (!sv_has_duckdb()) stop("Comparing a duckdb or Arrow table needs duckdb.", call. = FALSE)
      con_env <- if (is.null(args$con_env)) sv_lazy_env() else args$con_env
      plan <- args$plan %||% sv_compare_plan(tables[[1L]], tables[[2L]], args$by, names(tables)[1L],
                                             names(tables)[2L], con_env)
      return(sv_lazy_compare(tables[[1L]], tables[[2L]], plan, con_env, op))
    }
    plan <- args$plan %||% sv_compare_plan(tables[[1L]], tables[[2L]], args$by, names(tables)[1L], names(tables)[2L])
    return(sv_compare_rows(tables[[1L]], tables[[2L]], plan)[[sub("^compare_", "", op)]])
  }
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
  if (identical(op, "stack")) {
    base <- make.names(paste0(inputs[1L], "_stacked"))
    nm <- base
    i <- 2L
    while (nm %in% taken) {
      nm <- make.names(paste0(base, "_", i))
      i <- i + 1L
    }
    return(nm)
  }
  kept_i <- if (identical(args$side, "y")) 2L else 1L
  supp <- if (!is.null(args$supp)) args$supp else inputs[length(inputs)]
  base <- switch(op,
    unmatched = paste0(inputs[kept_i], "_unmatched_", inputs[3L - kept_i]),
    outside_window = paste0(inputs[kept_i], "_outside_window"),
    supp_orphans = paste0(supp, "_orphans"),
    supp_bad_idvarval = paste0(supp, "_bad_idvarval"),
    compare_removed = paste0(inputs[1L], "_removed"),
    compare_added = paste0(inputs[2L], "_added"),
    compare_changed = paste0(inputs[2L], "_changed"),
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
    # duckdb cannot push a filter down into an Arrow scan: keep the narrow key columns first
    if (length(attr(parent, "sv_arrow_views", exact = TRUE))) {
      # the copy is only needed to build these rows (the SUPP card is in memory): drop it afterwards
      tmp <- paste0("sv_supp_keys_", paste(sample(c(letters, 0:9), 12, replace = TRUE), collapse = ""))
      tcon <- dbplyr::remote_con(parent)
      q <- dplyr::compute(q, name = tmp, temporary = TRUE)
      on.exit(try(DBI::dbRemoveTable(tcon, tmp), silent = TRUE), add = TRUE)
    }
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
      sv_say_derive_offer("unmatched", as.integer(n_un[[side]]), names_of[[side]], other[[side]]))
  }
  if (!is.null(rule)) {
    n_ow <- c(x = dropped_x, y = dropped_y)
    for (side in c("x", "y")) {
      out[[length(out) + 1L]] <- make("outside_window", side, n_ow[[side]],
        sv_say_derive_offer("outside_window", as.integer(n_ow[[side]]), names_of[[side]], other[[side]]))
    }
  }
  Filter(function(o) o$n > 0L, out)
}

# The derived-card buttons for a SUPP check. The plan is left out (decision 8): R recomputes it.
sv_derive_offers_supp <- function(chk, parent_name, supp_name, rdomain) {
  if (!is.list(chk) || !is.null(chk$error)) return(list())
  mk <- function(op, n, label) {
    list(op = op, inputs = c(parent_name, supp_name), args = if (is.null(rdomain)) list() else list(rdomain = rdomain),
         n = as.integer(n), label = label)
  }
  out <- list(
    mk("supp_orphans", chk$n_orphan %||% 0L,
       sv_say_derive_offer("supp_orphans", as.integer(chk$n_orphan %||% 0L), supp_name, parent_name)),
    mk("supp_bad_idvarval", chk$bad_idvarval$n %||% 0L,
       sv_say_derive_offer("supp_bad_idvarval", as.integer(chk$bad_idvarval$n %||% 0L), supp_name, parent_name))
  )
  Filter(function(o) o$n > 0L, out)
}


# ---- derive_request: validation and the card builder (module mode is an untrusted client) ----
#
# The client names an op, two cards of the store and a few columns. Nothing it sends is evaluated:
# inputs are looked up in the store by name, columns are compared with the tables' own names, and
# only the allowlisted args are read (anything else is dropped).

sv_derive_max_pairs <- 20L

# A field of a client list, by exact name (`$` would take a partial match).
sv_field <- function(x, name) if (is.list(x)) x[[name, exact = TRUE]] else NULL

# One string from a client value (a scalar, or a one-element list); NULL for anything else.
sv_derive_scalar <- function(v, max_chars = 500L) {
  if (is.list(v)) v <- unlist(v, use.names = FALSE)
  if (!is.character(v) || length(v) != 1L || is.na(v) || !nzchar(v) || nchar(v) > max_chars) return(NULL)
  v
}

# A 0-row sample of a card's table: the column names and types, with no data read. A lazy card is asked
# through its duckdb tbl (so an Arrow int64 is judged as duckdb sees it); anything else from its preview.
sv_derive_zero <- function(card, con_env = NULL) {
  if (!is.null(con_env) && sv_card_is_lazy(card)) {
    z <- tryCatch(
      as.data.frame(dplyr::collect(utils::head(sv_lazy_tbl(card$source, con_env, card$id), 0L)),
                    stringsAsFactors = FALSE),
      error = function(e) NULL)
    if (!is.null(z)) return(z)
  }
  card$data[0L, , drop = FALSE]
}

# `by` as the client sent it (a list of {x, y}, or a data frame of them) -> list of list(x, y), or stop.
sv_derive_clean_by <- function(by) {
  if (is.data.frame(by)) by <- lapply(seq_len(nrow(by)), function(i) as.list(by[i, , drop = FALSE]))
  if (!is.list(by) || !length(by)) stop("Pick at least one key column pair.", call. = FALSE)
  if (length(by) > sv_derive_max_pairs) {
    stop(sprintf("A derived table takes at most %d key pairs.", sv_derive_max_pairs), call. = FALSE)
  }
  lapply(by, function(p) {
    px <- sv_derive_scalar(sv_field(p, "x"))
    py <- sv_derive_scalar(sv_field(p, "y"))
    if (is.null(px) || is.null(py)) stop("Each key pair needs a column of each table.", call. = FALSE)
    list(x = px, y = py)
  })
}

# The table each input card of a stack is read as: the whole duckdb tbl of a lazy card `card_full` calls whole (an
# Arrow card through its cached tbl on the session connection, unless the user's own duckdb tbl is an input: it is
# then handed over on that connection), else the card's rows in memory. With no `con_env` every card is in memory.
sv_stack_card_tables <- function(cards, inputs, con_env, card_full = sv_card_is_lazy) {
  full <- if (is.null(con_env) || !sv_has_duckdb()) rep(FALSE, length(cards)) else vapply(cards, card_full, NA)
  user_duck <- any(full & vapply(cards, function(cd) inherits(cd$source, "tbl_duckdb_connection"), NA))
  tabs <- lapply(seq_along(cards), function(i) {
    cd <- cards[[i]]
    if (!full[i]) return(cd$data)
    if (inherits(cd$source, "tbl_duckdb_connection")) return(cd$source)
    if (user_duck && !inherits(cd$source, "sv_derived_source")) return(cd$source)
    sv_lazy_tbl(cd$source, con_env, cd$id)
  })
  stats::setNames(tabs, inputs)
}

# The one cleaner of a stack's tables and fixes, for the check request and the derive request alike. `tables` are
# store names (2 to 8, each once), `fixes` the client's list (each has exactly column, action and to; to may be
# missing for keep; at most 500). The plan is run here so a bad fix is refused with its message. A lazy card that
# `card_full` says is whole is read through its duckdb tbl (the plan then comes from 0 rows and one query per input,
# see sv_lazy_stack_plan()); every other card by its rows in memory. Returns `list(inputs, cards, fixes, id_col, plan)`.
sv_stack_clean <- function(tables, fixes, store, id_col = NULL, con_env = NULL, card_full = sv_card_is_lazy) {
  if (is.list(tables)) tables <- unlist(tables, use.names = FALSE)
  if (!is.character(tables) || anyNA(tables)) stop("A stack needs 2 to 8 tables.", call. = FALSE)
  if (length(tables) < 2L || length(tables) > 8L) stop("A stack needs 2 to 8 tables.", call. = FALSE)
  if (anyDuplicated(tables)) stop("A table can be stacked only once.", call. = FALSE)
  inputs <- unname(tables)
  for (nm in inputs) {
    if (!store$has(nm)) stop(sprintf("Not in the canvas: %s", substr(nm, 1L, 100L)), call. = FALSE)
  }
  cards <- lapply(inputs, store$get)
  if (!all(vapply(cards, function(cd) is.data.frame(cd$data), NA))) {
    stop("A derived table needs tables as inputs.", call. = FALSE)
  }
  fixes_in <- fixes
  if (is.data.frame(fixes_in)) fixes_in <- lapply(seq_len(nrow(fixes_in)), function(i) as.list(fixes_in[i, , drop = FALSE]))
  if (is.null(fixes_in)) fixes_in <- list()
  if (!is.list(fixes_in)) stop("Fixes must be a list.", call. = FALSE)
  if (length(fixes_in) > 500L) stop("Too many fixes.", call. = FALSE)
  fixes <- lapply(unname(fixes_in), function(f) {
    bad <- !is.list(f) || !all(c("column", "action") %in% names(f)) ||
      length(setdiff(names(f), c("column", "action", "to"))) > 0L
    if (bad) stop("Each fix has a column, an action and a target.", call. = FALSE)
    col <- sv_derive_scalar(sv_field(f, "column"), 200L)
    act <- sv_derive_scalar(sv_field(f, "action"), 20L)
    to <- sv_field(f, "to")
    if (!is.null(to)) to <- sv_derive_scalar(to, 200L)
    if (is.null(col) || is.null(act) || !act %in% c("cast", "rename", "keep") ||
        (is.null(to) && !identical(act, "keep")) ||
        (!is.null(sv_field(f, "to")) && is.null(to))) {
      stop("Each fix has a column, an action and a target.", call. = FALSE)
    }
    list(column = col, action = act, to = to)
  })
  if (!is.null(id_col)) {
    id_col <- sv_derive_scalar(id_col, 200L)
    if (is.null(id_col)) stop("The id column must be one non-empty string.", call. = FALSE)
    for (i in seq_along(inputs)) {
      if (id_col %in% names(cards[[i]]$data)) stop(sprintf("%s is a column of %s.", id_col, inputs[i]), call. = FALSE)
    }
  }
  # a whole duckdb or Arrow table is never stacked from its 50-row preview without a word (as sv_derive_rows() says)
  if (!sv_has_duckdb() && any(vapply(cards, card_full, NA))) {
    stop("Stacking a duckdb or Arrow table needs duckdb.", call. = FALSE)
  }
  tabs <- sv_stack_card_tables(cards, inputs, con_env, card_full)
  plan <- sv_stack_plan(tabs, fixes, id_col, con_env)
  # the browser writes lazy code for a lazy card even when the plan came from its preview (a lost link)
  if (sv_has_duckdb() && any(vapply(cards, sv_card_is_lazy, NA))) plan <- sv_stack_add_tz_text(plan)
  list(inputs = inputs, cards = cards, fixes = fixes, id_col = id_col, plan = plan)
}

# The stack derive request: `fixes` and `id_col` are the only args read (see sv_stack_clean()).
sv_derive_clean_stack <- function(req, inputs, store, con_env = NULL, card_full = sv_card_is_lazy) {
  name <- sv_field(req, "name")
  if (!is.null(name)) {
    name <- sv_derive_scalar(name, 200L)
    if (is.null(name)) stop("The table name must be one non-empty string.", call. = FALSE)
  }
  raw <- sv_field(req, "args")
  if (!is.list(raw)) raw <- list()
  cl <- sv_stack_clean(inputs, sv_field(raw, "fixes"), store, sv_field(raw, "id_col"), con_env, card_full)
  args <- list(fixes = cl$fixes, plan = cl$plan)
  if (!is.null(cl$id_col)) args$id_col <- cl$id_col
  list(op = "stack", inputs = cl$inputs, args = args, name = name)
}

# The one cleaner of a compare's inputs and key, for the check request and the derive request alike. `old` and
# `new` are store names, `by` the key columns (a character vector or a list of strings, 1 to 20, the same in both
# versions). Only store cards are named, so a forged name is refused with its message and nothing is read outside the
# store. Returns `list(inputs, cards, by, plan)`; the plan is made here so a bad key is refused with its message.
sv_compare_clean <- function(old, new, by, store, con_env = NULL, card_full = sv_card_is_lazy) {
  one <- function(v) {
    nm <- sv_derive_scalar(v, 200L)
    if (is.null(nm)) stop("A comparison needs two tables.", call. = FALSE)
    nm
  }
  inputs <- c(one(old), one(new))
  if (is.list(by)) {
    if (!all(vapply(by, function(b) !is.null(sv_derive_scalar(b, 500L)), NA))) {
      stop("Pick the key columns.", call. = FALSE)
    }
    by <- unlist(by, use.names = FALSE)
  }
  if (is.null(by)) by <- character(0)
  if (!is.character(by) || anyNA(by) || any(!nzchar(by)) || any(nchar(by) > 500L)) {
    stop("Pick the key columns.", call. = FALSE)
  }
  for (nm in inputs) {
    if (!store$has(nm)) stop(sprintf("Not in the canvas: %s", substr(nm, 1L, 100L)), call. = FALSE)
  }
  if (identical(inputs[1L], inputs[2L])) stop("Pick two different tables.", call. = FALSE)
  cards <- lapply(inputs, store$get)
  if (!all(vapply(cards, function(cd) is.data.frame(cd$data), NA))) {
    stop("A derived table needs tables as inputs.", call. = FALSE)
  }
  by <- unique(unname(by))
  if (!length(by)) stop("Pick the key columns.", call. = FALSE)
  if (length(by) > sv_derive_max_pairs) {
    stop(sprintf("A derived table takes at most %d key pairs.", sv_derive_max_pairs), call. = FALSE)
  }
  # a whole duckdb or Arrow table is never compared from its 50-row preview without a word (as for a stack)
  if (!sv_has_duckdb() && any(vapply(cards, card_full, NA))) {
    stop("Comparing a duckdb or Arrow table needs duckdb.", call. = FALSE)
  }
  tabs <- unname(sv_stack_card_tables(cards, inputs, con_env, card_full))
  plan <- sv_compare_plan(tabs[[1L]], tabs[[2L]], by, inputs[1L], inputs[2L], con_env)
  # the browser writes lazy code for a lazy card even when the plan came from its preview (a lost link)
  if (sv_has_duckdb() && any(vapply(cards, sv_card_is_lazy, NA))) plan <- sv_compare_add_tz_text(plan)
  list(inputs = inputs, cards = cards, by = by, plan = plan)
}

# The compare derive request: `by` is the only arg read (see sv_compare_clean()); any other field is dropped.
sv_derive_clean_compare <- function(req, op, inputs, store, con_env = NULL, card_full = sv_card_is_lazy) {
  if (length(inputs) != 2L) stop("A derived table needs two input tables.", call. = FALSE)
  name <- sv_field(req, "name")
  if (!is.null(name)) {
    name <- sv_derive_scalar(name, 200L)
    if (is.null(name)) stop("The table name must be one non-empty string.", call. = FALSE)
  }
  raw <- sv_field(req, "args")
  if (!is.list(raw)) raw <- list()
  cl <- sv_compare_clean(inputs[1L], inputs[2L], sv_field(raw, "by"), store, con_env, card_full)
  list(op = op, inputs = cl$inputs, args = list(by = cl$by, plan = cl$plan), name = name)
}

# Check a request against the store and return the clean request, `list(op, inputs, args, name)`
# (stops with a message on anything wrong). `args` holds only what the op reads. `con_env`, when given,
# lets a lazy input answer its column types from a 0-row query.
sv_derive_clean <- function(req, store, con_env = NULL, card_full = sv_card_is_lazy) {
  if (!is.list(req)) stop("Not a derive request.", call. = FALSE)
  op <- sv_derive_scalar(sv_field(req, "op"), 40L)
  if (is.null(op) || !op %in% sv_derive_ops) stop("Unknown derive op.", call. = FALSE)
  inputs <- sv_field(req, "inputs")
  if (is.list(inputs)) inputs <- unlist(inputs, use.names = FALSE)
  if (!is.character(inputs) || anyNA(inputs)) stop("A derived table needs two input tables.", call. = FALSE)
  if (identical(op, "stack")) return(sv_derive_clean_stack(req, unname(inputs), store, con_env, card_full))
  if (op %in% c("compare_added", "compare_removed", "compare_changed")) {
    return(sv_derive_clean_compare(req, op, unname(inputs), store, con_env, card_full))
  }
  if (length(inputs) != 2L) stop("A derived table needs two input tables.", call. = FALSE)
  inputs <- unname(inputs)
  for (nm in inputs) {
    if (!store$has(nm)) stop(sprintf("Not in the canvas: %s", substr(nm, 1L, 100L)), call. = FALSE)
  }
  cx <- store$get(inputs[1L])
  cy <- store$get(inputs[2L])
  if (!is.data.frame(cx$data) || !is.data.frame(cy$data)) stop("A derived table needs tables as inputs.", call. = FALSE)
  name <- sv_field(req, "name")
  if (!is.null(name)) {
    name <- sv_derive_scalar(name, 200L)
    if (is.null(name)) stop("The table name must be one non-empty string.", call. = FALSE)
  }
  raw <- sv_field(req, "args")
  if (!is.list(raw)) raw <- list()

  if (op %in% c("supp_orphans", "supp_bad_idvarval")) {
    args <- list()
    rd <- sv_field(raw, "rdomain")
    if (!is.null(rd)) {
      rd <- sv_derive_scalar(rd, 8L)
      if (is.null(rd) || !grepl("^[A-Z][A-Z0-9]{0,7}$", rd)) stop("Not a valid RDOMAIN.", call. = FALSE)
      args$rdomain <- rd
    }
    return(list(op = op, inputs = inputs, args = args, name = name))
  }

  side <- sv_derive_scalar(sv_field(raw, "side"), 1L)
  if (is.null(side) || !side %in% c("x", "y")) stop("`side` must be \"x\" or \"y\".", call. = FALSE)
  pairs <- sv_derive_clean_by(sv_field(raw, "by"))
  by_x <- vapply(pairs, function(p) p$x, "")
  by_y <- vapply(pairs, function(p) p$y, "")
  zx <- sv_derive_zero(cx, con_env)
  zy <- sv_derive_zero(cy, con_env)
  miss_x <- setdiff(by_x, names(zx))
  miss_y <- setdiff(by_y, names(zy))
  if (length(miss_x)) stop(sprintf("Not in %s: %s", inputs[1L], paste(substr(miss_x, 1L, 100L), collapse = ", ")), call. = FALSE)
  if (length(miss_y)) stop(sprintf("Not in %s: %s", inputs[2L], paste(substr(miss_y, 1L, 100L), collapse = ", ")), call. = FALSE)
  issues <- sv_join_type_issues(zx, zy, by_x, by_y, inputs[1L], inputs[2L])
  if (length(issues)) stop(paste(issues, collapse = " "), call. = FALSE)
  args <- list(by = pairs, side = side)
  rule_in <- sv_field(raw, "rule")
  if (!is.null(rule_in)) {
    if (!is.list(rule_in)) stop("Unknown date rule.", call. = FALSE)
    rule <- sv_rule_from_shiny(rule_in)
    problem <- sv_join_rule_problem(rule, vapply(zx, sv_key_kind, character(1)),
                                    vapply(zy, sv_key_kind, character(1)))
    if (!is.null(problem)) stop(problem, call. = FALSE)
    args$rule <- sv_join_rule_normalize(rule)
  } else if (identical(op, "outside_window")) {
    stop("outside_window needs a date rule.", call. = FALSE)
  }
  list(op = op, inputs = inputs, args = args, name = name)
}

# NULL when the request is fine, else the message of the first problem (decision 2 and 3 included).
# The one validation path: the card builder runs the same sv_derive_clean().
# `card_full` is the server's (a card whose link was lost is read from its preview, as the check was).
sv_derive_validate <- function(req, store, con_env = NULL, card_full = sv_card_is_lazy) {
  sv_derive_check(req, store, con_env, card_full)$problem
}

# The validation and its clean request: `list(problem, clean)`, `problem` NULL when the request is fine. The
# derive_request handler hands `clean` to sv_derive_card(), so a stack's plan (one query per lazy input) runs once.
sv_derive_check <- function(req, store, con_env = NULL, card_full = sv_card_is_lazy) {
  tryCatch({
    clean <- sv_derive_clean(req, store, con_env, card_full)
    if (!is.null(clean$name)) sv_derive_name(clean$op, clean$inputs, clean$args, store$names(), clean$name)
    list(problem = NULL, clean = clean)
  }, error = function(e) list(problem = conditionMessage(e), clean = NULL))
}

# The RDOMAIN and the tables a SUPP check runs on, for the merge check and the derived SUPP cards alike (so
# a derived card's rows and the offer's count come from one decision). The RDOMAIN is the client's hint
# where the SUPP card allows it, else the SUPP card's merge target for this parent, else NULL (the check then
# reads it from the SUPP name). `lazy_sides()` gives the whole-table sides: an Arrow card goes through its
# cached duckdb tbl on the session connection unless the other side is the user's own duckdb tbl.
sv_supp_inputs <- function(cp, cs, hint, card_full, con_env) {
  rdomain <- sv_supp_rdomain_hint(cs, hint)
  if (is.null(rdomain)) {
    for (tg in cs$cdisc$merge_targets) {
      if (identical(tg$card, cp$id)) { rdomain <- tg$rdomain; break }
    }
  }
  side <- function(card, other) {
    if (!card_full(card)) return(card$data)
    if (inherits(card$source, "tbl_duckdb_connection")) return(card$source)
    if (card_full(other) && inherits(other$source, "tbl_duckdb_connection")) return(card$source)
    sv_lazy_tbl(card$source, con_env, card$id)
  }
  list(rdomain = rdomain, lazy_sides = function() list(parent = side(cp, cs), supp = side(cs, cp)))
}

# Build the card of a valid request and return it (the caller adds it to the store). `lazy_or_preview`
# and `card_full` are the server's own: the whole table is used when every lazy input still answers, else
# the preview rows (the same basis the check's counts, and so the offer, were computed on).
# `cdisc = FALSE` leaves the card untagged.
sv_derive_card <- function(req, store, con_env, lazy_or_preview = NULL, card_full = sv_card_is_lazy,
                           cdisc = "auto", clean = NULL) {
  # `clean`: the request as sv_derive_check() cleaned it, on this store, a moment ago (else it is cleaned here)
  if (is.null(clean)) clean <- sv_derive_clean(req, store, con_env, card_full)
  op <- clean$op
  inputs <- clean$inputs
  args <- clean$args
  if (is.null(lazy_or_preview)) {
    lazy_or_preview <- function(card, f_lazy, f_preview) {
      if (any(vapply(card, card_full, logical(1)))) f_lazy() else f_preview()
    }
  }
  # A lazy card keeps a recipe, not rows: its tbl is built on the session connection from the input cards
  # (cached under the card's id), its row count and its first 50 rows are all that is read.
  lazy_card <- function(src, derived, nm) {
    id <- generate_card_id()
    ok <- FALSE
    on.exit(if (!ok) {
      # a failed build leaves nothing on the connection and nothing cached under the card id
      if (!is.null(con_env$tbls[[id]])) {
        sv_lazy_release(con_env$tbls[[id]], con_env)
        con_env$tbls[[id]] <- NULL
      }
    })
    tbl <- sv_lazy_tbl(src, con_env, id)
    n <- sv_lazy_count(dplyr::pull(dplyr::count(tbl), "n"))
    prev <- as.data.frame(dplyr::collect(utils::head(tbl, 50L)), stringsAsFactors = FALSE)
    card <- new_sideview_card(id = id, name = nm, type = "grid", data = prev,
                              dims = c(n, ncol(prev)), is_lazy = TRUE, lazy_source = "duckdb",
                              source = src, derived = derived)
    ok <- TRUE
    card
  }
  if (identical(op, "stack")) {
    cards <- lapply(inputs, store$get)
    nm <- sv_derive_name(op, inputs, args, store$names(), clean$name)
    plan <- args$plan
    derived <- list(op = op, inputs = inputs,
                    args = list(fixes = args$fixes, id_col = plan$id_col, plan = plan))
    in_memory <- function() {
      rows <- sv_stack_rows(stats::setNames(lapply(cards, function(cd) cd$data), inputs), plan)
      new_sideview_card(name = nm, type = "grid", data = rows, derived = derived)
    }
    lazy <- function() lazy_card(sv_derived_source(op, derived$args, stats::setNames(cards, inputs)), derived, nm)
    card <- if (!is.null(con_env) && sv_has_duckdb()) lazy_or_preview(cards, lazy, in_memory) else in_memory()
    if (length(plan$kept_labels)) card$col_labels <- as.list(plan$kept_labels)
    tags <- lapply(cards, function(cd) cd$cdisc)
    doms <- vapply(tags, function(t) if (is.null(t) || is.null(t$domain)) NA_character_ else as.character(t$domain), "")
    same <- !anyNA(doms) && length(unique(doms)) == 1L
    card$cdisc <- if (isFALSE(cdisc) || !same) NULL else tags[[1L]]
    return(card)
  }
  if (op %in% c("compare_added", "compare_removed", "compare_changed")) {
    cx <- store$get(inputs[1L])
    cy <- store$get(inputs[2L])
    nm <- sv_derive_name(op, inputs, args, store$names(), clean$name)
    derived <- list(op = op, inputs = inputs, args = list(by = args$by, plan = args$plan))
    in_memory <- function() {
      rows <- sv_compare_rows(cx$data, cy$data, args$plan)[[sub("^compare_", "", op)]]
      new_sideview_card(name = nm, type = "grid", data = rows, derived = derived)
    }
    # a lazy compare card keeps its recipe (sv_lazy_compare() on the session connection), not rows
    lazy <- function() {
      lazy_card(sv_derived_source(op, derived$args, stats::setNames(list(cx, cy), inputs)), derived, nm)
    }
    card <- if (!is.null(con_env) && sv_has_duckdb()) lazy_or_preview(list(cx, cy), lazy, in_memory) else in_memory()
    src <- switch(op, compare_removed = cx, compare_added = cy, NULL)
    if (!is.null(src)) {
      lab <- src$col_labels[intersect(names(src$col_labels), names(card$data))]
      if (length(lab)) card$col_labels <- lab
      card$cdisc <- if (isFALSE(cdisc)) NULL else src$cdisc
    }
    return(card)
  }
  cx <- store$get(inputs[1L])
  cy <- store$get(inputs[2L])
  cards <- list(cx, cy)
  nm <- sv_derive_name(op, inputs, args, store$names(), clean$name)
  is_supp <- op %in% c("supp_orphans", "supp_bad_idvarval")
  tag_from <- if (is_supp) cy else if (identical(args$side, "y")) cy else cx
  finish <- function(card) {
    card$cdisc <- if (isFALSE(cdisc)) NULL else tag_from$cdisc
    card
  }

  if (is_supp) {
    # decision 8: the plan is R's.
    si <- sv_supp_inputs(cx, cy, args$rdomain, card_full, con_env)
    rdomain <- si$rdomain
    run <- function(parent, supp) {
      chk <- if (any(vapply(list(parent, supp), sv_is_lazy_input, logical(1)))) {
        sv_lazy_supp_check(parent, supp, inputs[1L], inputs[2L], rdomain = rdomain, con_env = con_env)
      } else {
        sv_supp_check(parent, supp, inputs[1L], inputs[2L], rdomain = rdomain)
      }
      if (!is.null(chk$error)) stop(chk$error, call. = FALSE)
      rd <- if (is.null(rdomain)) sub("^SUPP", "", toupper(inputs[2L])) else rdomain
      out <- sv_derive_rows(op, list(parent = parent, supp = supp), list(plan = chk$plan, rdomain = rd))
      list(rows = out, args = list(rdomain = rd, plan = chk$plan))
    }
    res <- lazy_or_preview(cards,
      function() {
        s <- si$lazy_sides()
        run(s$parent, s$supp)
      },
      function() run(cx$data, cy$data))
    # decision 7: a SUPP card is in memory, the rows collected after the RDOMAIN filter
    return(finish(new_sideview_card(
      name = nm, type = "grid", data = res$rows,
      derived = list(op = op, inputs = inputs, args = res$args))))
  }

  derived <- list(op = op, inputs = inputs, args = args)
  in_memory <- function() {
    rows <- sv_derive_rows(op, stats::setNames(list(cx$data, cy$data), inputs), args)
    new_sideview_card(name = nm, type = "grid", data = rows, derived = derived)
  }
  # the recipe keeps the input cards; the rows are built on the session connection when asked for
  lazy <- function() lazy_card(sv_derived_source(op, args, stats::setNames(list(cx, cy), inputs)), derived, nm)
  finish(lazy_or_preview(cards, lazy, in_memory))
}

# ---- derived cards follow their inputs (remove, replace, state) ----

# The derived cards that read `name`, directly or through another derived card, in dependency order (a card
# comes after every card it reads). Read from each card's `derived$inputs`; there is no separate graph.
sv_derive_dependants <- function(store, name) {
  out <- character()
  repeat {
    reach <- c(name, out)
    added <- FALSE
    for (nm in setdiff(store$names(), reach)) {
      d <- store$get(nm)$derived
      if (!is.null(d) && any(as.character(unlist(d$inputs)) %in% reach)) {
        out <- c(out, nm)
        reach <- c(reach, nm)
        added <- TRUE
      }
    }
    if (!added) break
  }
  out
}

# The request a stored derived card was built from: the same shape the browser sends, so the rebuild goes
# through sv_derive_clean() like any request.
sv_derive_request_of <- function(card) {
  d <- card$derived
  list(op = d$op, inputs = as.list(as.character(unlist(d$inputs))), args = d$args, name = card$name)
}

# A builder for callers with no session: whole lazy tables need the session connection, so the rows come
# from the preview of each input.
sv_derive_preview_builder <- function(cdisc = "auto") {
  function(req, store) {
    sv_derive_card(req, store, NULL, lazy_or_preview = function(card, f_lazy, f_preview) f_preview(),
                   cdisc = cdisc)
  }
}

# Rebuild a derived card from its recipe under its own name. The store it is built against has no card of that
# name (so the name is free), and nothing in `store` changes. Stops if an input or a column is gone.
sv_derive_rebuild <- function(card, store, build) {
  others <- unname(Filter(function(cd) !identical(cd$name, card$name), store$all()))
  build(sv_derive_request_of(card), sv_card_store(others))
}

# A state whose stack steps carry the plans of the cards built from it. The data may have changed since the state
# was saved and the browser writes a stack's code from its step's plan, so the step takes the plan R just made.
# Only stack steps: a SUPP or join step keeps its saved args (its card refits when R replaces it).
sv_derive_state_refresh <- function(state, cards) {
  steps <- if (is.list(state)) sv_field(sv_field(state, "pipeline"), "steps") else NULL
  if (!is.list(steps) || !length(steps)) return(state)
  made <- list()
  for (cd in cards) if (identical(cd$derived$op, "stack")) made[[cd$name]] <- cd$derived$args
  for (k in seq_along(steps)) {
    st <- steps[[k]]
    if (!is.list(st) || !identical(sv_field(st, "kind"), "derive") || !identical(sv_field(st, "op"), "stack")) next
    tbl <- sv_derive_scalar(sv_field(st, "table"), 200L)
    if (is.null(tbl) || is.null(made[[tbl]])) next
    state$pipeline$steps[[k]]$args <- made[[tbl]]
  }
  state
}

# `cards` with the derived cards of a saved state appended. The state's pipeline holds the derive steps
# `{kind, key, table, op, inputs, args}`; each is rebuilt through the validating builder (state from a file is
# as untrusted as a browser message), under the exact name `table`, once its inputs are present. A step that
# cannot be built is skipped: its browser step waits. With `skip_lazy`, a step that reads a lazy card is
# skipped too (its rows would come from previews): the session builds it later on whole tables. `build(req, store)` defaults to the preview builder.
sv_derive_from_state <- function(cards, state, build = NULL, skip_lazy = FALSE) {
  steps <- if (is.list(state)) sv_field(sv_field(state, "pipeline"), "steps") else NULL
  if (!is.list(steps) || !length(steps)) return(cards)
  if (is.null(build)) build <- sv_derive_preview_builder()
  store <- sv_card_store(cards)
  for (step in steps) {
    if (!is.list(step) || !identical(sv_field(step, "kind"), "derive")) next
    tbl <- sv_derive_scalar(sv_field(step, "table"), 200L)
    if (is.null(tbl) || store$has(tbl)) next
    if (isTRUE(skip_lazy)) {
      ins <- as.character(unlist(sv_field(step, "inputs")))
      if (any(vapply(ins, function(nm) store$has(nm) && sv_card_is_lazy(store$get(nm)), TRUE))) next
    }
    req <- list(op = sv_field(step, "op"), inputs = sv_field(step, "inputs"),
                args = sv_field(step, "args"), name = tbl)
    card <- tryCatch({
      build(req, store)
    }, error = function(e) NULL)
    if (is.null(card) || !identical(card$name, tbl)) next
    store$add(card)
    cards[[length(cards) + 1L]] <- card
  }
  cards
}
