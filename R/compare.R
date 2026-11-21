# Compare two cuts of a table by key (D3). sv_compare_plan() decides what is compared, sv_compare_rows() gives
# the added, removed and changed rows, and sv_compare() is the exported check. The row steps are the ones the
# generated code writes (dplyr only): a key repeated in either version leaves all its rows out of every count.

# The text of a column's values, as a changed value or a text key is written: D2's cast to chr, a date-time in
# its own zone, a factor by its labels. A missing value (NA or NaN) is NA_character_, never "NaN".
sv_compare_text <- function(x) {
  ty <- as.character(sv_stack_type(x))
  zone <- if (identical(ty, "dttm")) attr(x, "tzone")[1] %||% "" else NULL
  out <- as.character(sv_stack_cast(x, ty, "chr", zone))
  out[is.na(x)] <- NA_character_
  out
}

# The suggested key of two versions (decision 2). Two cards with the same CDISC domain use that domain's
# natural key kept to the columns in both; otherwise the shared columns sv_suggest_mappings() would pair with
# themselves (confidence 0.6 or more), in new's column order; otherwise character(0). `old` and `new` are data
# frames; the tags are the cards' `cdisc` lists.
sv_compare_key <- function(old, new, old_tag = NULL, new_tag = NULL) {
  shared <- intersect(names(new), names(old))
  if (!length(shared)) return(character(0))
  if (!is.null(old_tag) && !is.null(new_tag) && !is.null(new_tag$domain) &&
      identical(old_tag$domain, new_tag$domain) && identical(old_tag$standard, new_tag$standard)) {
    nat <- sv_keys_natural(list(cdisc = new_tag))
    if (length(nat)) {
      keep <- vapply(nat, function(k) {
        hit <- shared[toupper(shared) == toupper(k)]
        if (length(hit)) hit[1L] else NA_character_
      }, "")
      keep <- unname(keep[!is.na(keep)])
      if (length(keep)) return(keep)
    }
  }
  if (!nrow(old) || !nrow(new)) return(character(0))
  m <- tryCatch(suppressWarnings(sv_suggest_mappings(
    stats::setNames(list(old, new), c("old", "new")), min_confidence = 0.6, cdisc = FALSE)),
    error = function(e) NULL)
  if (is.null(m) || !nrow(m)) return(character(0))
  same <- unique(m$from_col[m$from_col == m$to_col])
  cand <- shared[shared %in% same]
  cand <- cand[!vapply(cand, function(cn) sv_stack_is_list(old[[cn]]) || sv_stack_is_list(new[[cn]]), NA)]
  # a key must identify rows: the first candidate with no repeated value in either version (NA is a value),
  # else all candidates together if their combinations are unique in both, else none
  for (cn in cand) if (!anyDuplicated(old[[cn]]) && !anyDuplicated(new[[cn]])) return(cn)
  if (length(cand) && !anyDuplicated(old[cand]) && !anyDuplicated(new[cand])) return(cand)
  character(0)
}

# The plan of a compare (decision 5): a plain list. `old` and `new` are data frames, duckdb tables or Arrow tables;
# a lazy input goes to sv_lazy_compare_plan(), the same plan from 0 rows (`con_env` is the session connection it may
# use). It refuses what decision 3 lists.
sv_compare_plan <- function(old, new, by, old_name = "old", new_name = "new", con_env = NULL) {
  by <- sv_compare_by(by, old_name, new_name)
  if (sv_is_lazy_input(old) || sv_is_lazy_input(new)) {
    return(sv_lazy_compare_plan(old, new, by, con_env, old_name, new_name))
  }
  sv_compare_plan_core(old, new, by, old_name, new_name)
}

# The names and the key of a compare, checked (decision 3): `by` without repeats.
sv_compare_by <- function(by, old_name, new_name) {
  if (identical(old_name, new_name)) stop("Pick two different tables.", call. = FALSE)
  if (!is.character(by) || !length(by) || anyNA(by) || any(!nzchar(by))) stop("Pick the key columns.", call. = FALSE)
  by <- unique(by)
  if (length(by) > sv_derive_max_pairs) {
    stop(sprintf("A derived table takes at most %d key pairs.", sv_derive_max_pairs), call. = FALSE)
  }
  by
}

# The plan from `old` and `new`: data frames, or 0-row samples of them (types, zones and factor levels are all it
# reads). A key's `tz_text_*` is NA here; sv_compare_add_tz_text() fills it for a lazy plan.
sv_compare_plan_core <- function(old, new, by, old_name, new_name) {
  tabs <- stats::setNames(list(old, new), c(old_name, new_name))
  for (k in by) {
    for (nm in names(tabs)) {
      if (!k %in% names(tabs[[nm]])) stop(sprintf("Not in %s: %s", nm, k), call. = FALSE)
      if (sv_stack_is_list(tabs[[nm]][[k]])) {
        stop(sprintf("Column %s in %s is a list column; it cannot be a key.", k, nm), call. = FALSE)
      }
    }
  }
  zone <- function(x) if (inherits(x, "POSIXct")) attr(x, "tzone")[1] %||% "" else NA_character_
  keys <- lapply(by, function(k) {
    zo <- old[[k]]; zn <- new[[k]]
    ko <- sv_key_kind(zo); kn <- sv_key_kind(zn)
    list(name = k, kind_old = ko, kind_new = kn, text = !identical(ko, kn),
         from_old = sv_stack_tname(zo), from_new = sv_stack_tname(zn), zone_old = zone(zo), zone_new = zone(zn),
         tz_text_old = NA_character_, tz_text_new = NA_character_)
  })
  compared <- list()
  type_changed <- list()
  for (nm in setdiff(intersect(names(new), names(old)), by)) {
    o <- old[[nm]]; n <- new[[nm]]
    lst <- sv_stack_is_list(o) || sv_stack_is_list(n)
    to <- sv_stack_tname(o); tn <- sv_stack_tname(n)
    if (!lst && identical(sv_key_kind(o), sv_key_kind(n))) {
      compared[[length(compared) + 1L]] <- list(
        name = nm, kind = sv_key_kind(n), from_old = to, from_new = tn,
        zone_old = zone(o), zone_new = zone(n), tz_text_old = NA_character_, tz_text_new = NA_character_)
    } else if (!identical(to, tn)) {
      type_changed[[length(type_changed) + 1L]] <- list(column = nm, old = to, new = tn)
    }
  }
  list(by = by, keys = keys, compared = compared, type_changed = type_changed,
       only_old = setdiff(names(old), names(new)), only_new = setdiff(names(new), names(old)),
       lazy = FALSE)
}

# One side with its text key columns (.sv_k<i>, decision 8) added; `by` is the join names.
sv_compare_joinable <- function(x, plan) {
  by <- plan$by
  for (i in seq_along(plan$keys)) {
    if (isTRUE(plan$keys[[i]]$text)) {
      nm <- paste0(".sv_k", i)
      x[[nm]] <- sv_compare_text(x[[plan$keys[[i]]$name]])
      by[i] <- nm
    }
  }
  list(data = x, by = by)
}

# Rows where the value changed (decision 9): missing in one only, or different; NA and NaN in both are the same.
sv_compare_changed <- function(a, b) {
  if (is.factor(a) || is.factor(b)) { a <- as.character(a); b <- as.character(b) }
  na_a <- is.na(a); na_b <- is.na(b)
  !(na_a & na_b) & (na_a | na_b | a != b)
}

# The rows of a compare under `plan`: list(added, removed, changed, summary), all in memory.
sv_compare_rows <- function(old, new, plan) {
  by <- plan$by
  jo <- sv_compare_joinable(old, plan); jn <- sv_compare_joinable(new, plan)
  o <- jo$data; n <- jn$data; jb <- jo$by
  extra <- setdiff(names(o), names(old))
  uniq <- function(x) dplyr::filter(x, dplyr::n() == 1L, .by = dplyr::all_of(jb))
  clean <- function(x) x[setdiff(names(x), extra)]
  added <- clean(dplyr::anti_join(uniq(n), o, by = jb, na_matches = "na"))
  removed <- clean(dplyr::anti_join(uniq(o), n, by = jb, na_matches = "na"))
  both <- dplyr::inner_join(uniq(o), uniq(n), by = jb, suffix = c(".old", ".new"), na_matches = "na")

  nms <- vapply(plan$compared, function(cc) cc$name, "")
  ch <- stats::setNames(lapply(plan$compared, function(cc) {
    sv_compare_changed(both[[paste0(cc$name, ".old")]], both[[paste0(cc$name, ".new")]])
  }), nms)
  key_src <- vapply(plan$keys, function(k) if (isTRUE(k$text)) paste0(k$name, ".new") else k$name, "")
  piece <- function(rows, nm) {
    f <- both[rows, , drop = FALSE]
    out <- f[key_src]
    names(out) <- by
    out$column <- rep(nm, nrow(f))
    if (is.na(nm)) {
      out$old <- rep(NA_character_, nrow(f)); out$new <- rep(NA_character_, nrow(f))
    } else {
      out$old <- sv_compare_text(f[[paste0(nm, ".old")]])
      out$new <- sv_compare_text(f[[paste0(nm, ".new")]])
    }
    out
  }
  changed <- if (length(nms)) {
    dplyr::bind_rows(lapply(nms, function(nm) piece(ch[[nm]], nm)))
  } else piece(rep(FALSE, nrow(both)), NA_character_)
  changed <- dplyr::arrange(changed, dplyr::across(dplyr::all_of(by)))

  any_ch <- Reduce(`|`, ch, rep(FALSE, nrow(both)))
  per_column <- stats::setNames(vapply(ch, function(v) as.integer(sum(v)), 1L, USE.NAMES = FALSE), nms)
  n_changed <- as.integer(sum(any_ch))

  # keys that repeat in either version, in order of first appearance in old, then new
  dups <- function(x) dplyr::distinct(dplyr::filter(x[jb], dplyr::n() > 1L, .by = dplyr::all_of(jb)))
  rep_keys <- dplyr::distinct(dplyr::bind_rows(dups(o), dups(n)))
  rows_in <- function(x) nrow(dplyr::semi_join(x, rep_keys, by = jb, na_matches = "na"))
  sample <- lapply(seq_len(min(5L, nrow(rep_keys))), function(r) {
    stats::setNames(lapply(seq_along(by), function(i) {
      v <- rep_keys[[jb[i]]][r]
      if (is.factor(v)) as.character(v) else v
    }), by)
  })

  summary <- list(
    by = by, n_old = nrow(old), n_new = nrow(new),
    added = nrow(added), removed = nrow(removed), changed = n_changed,
    same = nrow(both) - n_changed,
    repeated_keys = nrow(rep_keys), repeated_rows_old = rows_in(o), repeated_rows_new = rows_in(n),
    repeated_sample = sample,
    compared = nms, type_changed = plan$type_changed, only_old = plan$only_old, only_new = plan$only_new,
    per_column = per_column, changed_values = nrow(changed))
  list(added = added, removed = removed, changed = changed, summary = summary)
}

# The summary of sv_compare_rows() with the table names, the text and the Open labels (decision 6).
sv_compare_finish <- function(summary, old_name, new_name) {
  s <- c(list(old_name = old_name, new_name = new_name), summary)
  s$text <- sv_say_compare_text(s)
  s$open <- sv_say_compare_open(s)
  s
}

# The R code that rebuilds one compare card (decision 9): `list(code, kind)`. `refs` are the R references of old and
# new, `kinds` is NA, "duckdb" or "arrow" per input, `op` is "compare_added", "compare_removed" or
# "compare_changed". The in-memory form is one expression of dplyr calls: no pipe, no helper, no sideview function.
# The lazy form (either kind not NA) puts both inputs on one duckdb connection as D2's lazy stack code does
# (sv_lazy_place_code()), writes the casts and conditions sv_lazy_compare() runs, printed, joins the pieces of
# `_changed` with nested union_all() and has no arrange() (a lazy card has no order). Its kind is "duckdb".
sv_compare_code <- function(plan, refs, kinds, op) {
  if (!op %in% c("compare_added", "compare_removed", "compare_changed")) {
    stop(sprintf("Unknown compare op: %s", op), call. = FALSE)
  }
  lazy <- any(!is.na(kinds))
  kind <- if (lazy) "duckdb" else NA_character_
  q <- function(s) encodeString(s, quote = "\"")
  cv <- function(v) paste0("c(", paste(q(v), collapse = ", "), ")")
  by <- plan$by
  # the text of a column (D2's cast to chr, a missing value NA, as sv_compare_text() does); `cn` is the plain name
  text <- function(cn, from, zone) {
    if (is.null(zone) || isTRUE(is.na(zone))) zone <- ""
    if (lazy) return(sv_stack_show(sv_compare_lazy_text(cn, from, zone)))
    x <- sv_escape_ident(cn)
    paste0("replace(", sv_stack_cast_code(x, from, "chr", zone), ", is.na(", x, "), NA_character_)")
  }
  if (lazy) {
    duck <- which(!is.na(kinds) & kinds == "duckdb")
    duck_ref <- if (length(duck)) refs[duck[1L]] else NULL
    refs <- vapply(1:2, function(i) {
      sv_lazy_place_code(refs[i], kinds[i], duck_ref, paste0("sideview_", refs[i], "_", i), keep_views = TRUE)
    }, "")
  }
  jb <- by
  side <- function(i, ref) {
    sets <- character()
    for (j in seq_along(plan$keys)) {
      k <- plan$keys[[j]]
      if (!isTRUE(k$text)) next
      nm <- paste0(".sv_k", j)
      jb[j] <<- nm
      sets <- c(sets, paste0(nm, " = ", text(k$name,
        if (i == 1L) k$from_old else k$from_new, if (i == 1L) k$zone_old else k$zone_new)))
    }
    if (length(sets)) paste0("dplyr::mutate(", ref, ", ", paste(sets, collapse = ", "), ")") else ref
  }
  o <- side(1L, refs[1L]); n <- side(2L, refs[2L])
  extra <- jb[jb != by]
  drop <- function(x) {
    if (!length(extra)) return(x)
    paste0("dplyr::select(", x, ", -c(", paste(extra, collapse = ", "), "))")
  }
  uniq <- function(x) paste0("dplyr::filter(", x, ", dplyr::n() == 1L, .by = ", cv(jb), ")")
  if (identical(op, "compare_added")) {
    code <- drop(paste0("dplyr::anti_join(", uniq(n), ", ", o, ", by = ", cv(jb), ", na_matches = \"na\")"))
    return(list(code = code, kind = kind))
  }
  if (identical(op, "compare_removed")) {
    code <- drop(paste0("dplyr::anti_join(", uniq(o), ", ", n, ", by = ", cv(jb), ", na_matches = \"na\")"))
    return(list(code = code, kind = kind))
  }
  join <- paste0("dplyr::inner_join(", uniq(o), ", ", uniq(n), ", by = ", cv(jb),
                 ", suffix = c(\".old\", \".new\"), na_matches = \"na\")")
  keys <- vapply(seq_along(by), function(j) {
    id <- sv_escape_ident(by[j])
    if (isTRUE(plan$keys[[j]]$text)) paste0(id, " = ", sv_escape_ident(paste0(by[j], ".new"))) else id
  }, "")
  body <- if (!length(plan$compared)) {
    na <- if (lazy) sv_stack_show(sv_stack_lazy_na("chr")) else "NA_character_"
    paste0("dplyr::transmute(dplyr::filter(.sv_both, FALSE), ", paste(keys, collapse = ", "),
           ", column = ", na, ", old = ", na, ", new = ", na, ")")
  } else {
    pieces <- vapply(plan$compared, function(cc) {
      an <- paste0(cc$name, ".old"); bn <- paste0(cc$name, ".new")
      cond <- if (lazy) sv_stack_show(sv_compare_lazy_cond(cc)) else {
        a <- sv_escape_ident(an); b <- sv_escape_ident(bn)
        ca <- a; cb <- b
        if (cc$kind %in% "character") { ca <- paste0("as.character(", a, ")"); cb <- paste0("as.character(", b, ")") }
        paste0("!(is.na(", a, ") & is.na(", b, ")) & (is.na(", a, ") | is.na(", b, ") | ", ca, " != ", cb, ")")
      }
      paste0("dplyr::transmute(dplyr::filter(.sv_both, ", cond, "), ", paste(keys, collapse = ", "),
             ", column = ", q(cc$name), ", old = ", text(an, cc$from_old, cc$zone_old),
             ", new = ", text(bn, cc$from_new, cc$zone_new), ")")
    }, "")
    if (lazy) {
      Reduce(function(a, b) paste0("dplyr::union_all(", a, ", ", b, ")"), pieces, right = TRUE)
    } else {
      paste0("dplyr::arrange(dplyr::bind_rows(", paste(pieces, collapse = ", "), "), ",
             paste(sv_escape_ident(by), collapse = ", "), ")")
    }
  }
  code <- paste0("local({
  .sv_both <- ", join, "
  ", body, "
})")
  list(code = code, kind = kind)
}

#' Compare two versions of a table by key
#'
#' Compares two cuts of the same table row by row. Rows are matched on the key columns
#' (`NA` matches `NA`) and reported as added (only in `new`), removed (only in `old`),
#' changed (matched, with a different value in a column) or the same. A key that repeats in
#' either version leaves all its rows, in both versions, out of every count and table; the
#' summary reports it as a warning with up to 5 sample keys.
#'
#' Compared columns are those in both versions with the same type kind, so an integer column
#' equals a double column of the same values and a factor equals a character column. A column
#' whose kind differs is listed in `type_changed`, not compared. Key columns are not compared.
#' Equality is exact; `NA` and `NaN` in both versions are the same, and one of them against a
#' value is a change. Key columns of differing kinds are matched as text.
#'
#' The `changed` table has the key columns, then `column`, `old` and `new` (the values as text,
#' missing values `NA`), ordered by key and then by the column's position in `new`.
#'
#' When either version is a duckdb or Arrow table, both are compared on one duckdb connection
#' and nothing is collected: the counts come from queries, and `added`, `removed` and `changed`
#' are lazy duckdb tables (in no particular order). Number text can then differ from R's
#' (`"100000"` for `"1e+05"`).
#'
#' @param old,new Data frames, duckdb tables or Arrow tables: the earlier and the later
#'   version. Unnamed tables are named by their expressions, as [sideview()] names them.
#' @param by Names of the key columns, the same in both versions (1 to 20). `NULL` suggests a
#'   key: the first shared column (same name, similar values) with no repeated value in either version, else
#'   the shared columns together when their combinations are unique, else an error asks for the key. For a
#'   duckdb or Arrow table the suggestion reads the first 50 rows of each version.
#' @return An object of class `sv_compare`: `old_name`, `new_name`, `by`, the row counts `n_old`,
#'   `n_new`, `n_added`, `n_removed`, `n_changed`, `same`, the repeated-key counts, `per_column` (changed
#'   rows per compared column), `text` (summary lines) and `open` (button labels), plus the tables
#'   `added`, `removed` and `changed`, and `code`.
#' @export
#' @examples
#' cut1 <- data.frame(id = 1:4, sev = c("MILD", "MILD", "SEVERE", "MILD"))
#' cut2 <- data.frame(id = 2:5, sev = c("MILD", "MODERATE", "SEVERE", "MILD"))
#' sv_compare(cut1, cut2, by = "id")
sv_compare <- function(old, new, by = NULL) {
  named <- sv_stack_dots(list(old, new), list(substitute(old), substitute(new)))
  old_name <- names(named$tables)[1L]; new_name <- names(named$tables)[2L]
  ok <- function(x) is.data.frame(x) || sv_is_lazy_input(x)
  if (!ok(old) || !ok(new)) {
    stop("Both versions must be data frames, duckdb tables or Arrow tables.", call. = FALSE)
  }
  if (identical(old_name, new_name)) stop("Pick two different tables.", call. = FALSE)
  lazy <- sv_is_lazy_input(old) || sv_is_lazy_input(new)
  if (lazy && !sv_has_duckdb()) stop("Comparing a duckdb or Arrow table needs duckdb.", call. = FALSE)
  if (is.null(by)) {
    # a lazy version suggests its key from its first 50 rows (a suggestion only: repeats are still counted)
    peek <- function(x) {
      if (!sv_is_lazy_input(x)) return(x)
      as.data.frame(dplyr::collect(utils::head(x, 50L)), stringsAsFactors = FALSE)
    }
    by <- sv_compare_key(peek(old), peek(new))
  }
  refs <- named$refs
  if (lazy) {
    # lazy in, lazy out: one duckdb connection, the counts from queries, the three tables never collected
    con_env <- sv_lazy_env()
    plan <- sv_compare_plan(old, new, by, old_name, new_name, con_env)
    summary <- sv_lazy_compare(old, new, plan, con_env)
    tabs <- lapply(c(added = "compare_added", removed = "compare_removed", changed = "compare_changed"),
                   function(op) sv_lazy_compare(old, new, plan, con_env, op))
    kinds <- vapply(list(old, new), function(x) if (sv_is_lazy_input(x)) sv_lazy_origin(x) else NA_character_, "")
  } else {
    plan <- sv_compare_plan(old, new, by, old_name, new_name)
    rows <- sv_compare_rows(old, new, plan)
    summary <- rows$summary
    tabs <- rows[c("added", "removed", "changed")]
    kinds <- c(NA_character_, NA_character_)
  }
  s <- sv_compare_finish(summary, old_name, new_name)
  # `added`, `removed` and `changed` are the tables here, so their counts are `n_added` etc.
  s[c("n_added", "n_removed", "n_changed")] <- s[c("added", "removed", "changed")]
  s[c("added", "removed", "changed")] <- unname(tabs)
  s$code <- list(
    added = sv_compare_code(plan, refs, kinds, "compare_added")$code,
    removed = sv_compare_code(plan, refs, kinds, "compare_removed")$code,
    changed = sv_compare_code(plan, refs, kinds, "compare_changed")$code)
  structure(s, class = "sv_compare")
}

#' @export
print.sv_compare <- function(x, ...) {
  cat(x$text, sep = "\n")
  rows <- function(n) paste0(sv_say_num(n), if (n == 1) " row" else " rows")
  # the counts, not nrow(): a lazy table has no row count in R
  cat("added: ", rows(x$n_added), "\n", sep = "")
  cat("removed: ", rows(x$n_removed), "\n", sep = "")
  cat("changed: ", rows(x$changed_values), "\n", sep = "")
  invisible(x)
}
