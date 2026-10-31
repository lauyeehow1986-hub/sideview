# Date rules on joins, in memory: the R twin of the rule logic in inst/www/sv-pipeline.js.
# sv_join_rule_problem() and sv_join_rule_label() give the same strings as
# SideviewPipeline.ruleProblem() / ruleLabel(); keep them together.

sv_rule_shapes <- c("between", "window", "before", "after", "overlaps")

sv_rule_slots <- function(shape) {
  switch(shape,
    between = c("xCol", "yFrom", "yTo"),
    window = c("xCol", "yCol"),
    before = c("xCol", "yCol"),
    after = c("xCol", "yCol"),
    overlaps = c("xFrom", "xTo", "yFrom", "yTo"),
    character(0))
}

# Which table each slot belongs to ("x" slots start with x).
sv_rule_slot_side <- function(slot) if (startsWith(slot, "x")) "x" else "y"

# A whole number from a number or a numeric string; NULL for anything else.
sv_whole_number <- function(v) {
  if (is.numeric(v) && length(v) == 1L) {
    return(if (is.finite(v) && floor(v) == v) as.numeric(v) else NULL)
  }
  if (is.character(v) && length(v) == 1L && grepl("^\\s*[-+]?[0-9]+\\s*$", v)) return(as.numeric(trimws(v)))
  NULL
}

sv_rule_kind_of <- function(kinds, col) {
  if (is.null(kinds) || is.null(names(kinds)) || !col %in% names(kinds)) return(NA_character_)
  as.character(kinds[[col]])
}

# The first problem with a date rule, or NULL. `kinds_x` / `kinds_y` map column to kind
# (the names sv_key_kind() gives); `type` is the join type.
sv_join_rule_problem <- function(rule, kinds_x, kinds_y, type = "left_join") {
  if (!is.list(rule) || !isTRUE(rule$shape %in% sv_rule_shapes)) return("Unknown date rule.")
  slots <- sv_rule_slots(rule$shape)
  for (s in slots) {
    v <- rule[[s]]
    if (!is.character(v) || length(v) != 1L || is.na(v) || !nzchar(v)) return("Pick a column for every slot.")
  }
  cols <- vapply(slots, function(s) rule[[s]], character(1))
  kinds <- vapply(slots, function(s) {
    sv_rule_kind_of(if (sv_rule_slot_side(s) == "x") kinds_x else kinds_y, rule[[s]])
  }, character(1))
  for (i in seq_along(cols)) {
    if (is.na(kinds[i]) || !kinds[i] %in% c("Date", "date-time", "numeric")) {
      return(paste0(cols[i], " is not a date, date-time or number."))
    }
  }
  for (i in seq_along(cols)[-1L]) {
    if (kinds[i] != kinds[1L]) {
      return(paste0(cols[1L], " is ", kinds[1L], " but ", cols[i], " is ", kinds[i],
                    ": both sides of a date rule need the same kind."))
    }
  }
  if (rule$shape == "window") {
    from <- sv_whole_number(rule$from)
    to <- sv_whole_number(rule$to)
    if (is.null(from) || is.null(to) || abs(from) > 3650 || abs(to) > 3650) {
      return("Window bounds must be whole numbers from -3650 to 3650.")
    }
    if (from > to) return("The window start must not be after its end.")
  }
  if (rule$shape %in% c("before", "after") && type %in% c("right_join", "full_join")) {
    return("A nearest-match rule works with left, inner, semi and anti joins only.")
  }
  NULL
}

sv_signed_offset <- function(n) {
  n <- as.numeric(n)
  if (n > 0) paste0("+", format(n, scientific = FALSE, trim = TRUE)) else format(n, scientific = FALSE, trim = TRUE)
}

# The rule as words. `kind_x` decides "days" or the column's own unit.
sv_join_rule_label <- function(rule, kind_x) {
  if (is.null(rule)) return("")
  strict <- identical(rule$inclusive, FALSE)
  switch(rule$shape,
    window = paste0(rule$yCol, " within ", sv_signed_offset(rule$from), "..", sv_signed_offset(rule$to),
                    if (identical(kind_x, "numeric")) "" else " days", " of ", rule$xCol),
    before = paste0("last ", rule$yCol, if (strict) " before " else " on or before ", rule$xCol),
    after = paste0("first ", rule$yCol, if (strict) " after " else " on or after ", rule$xCol),
    between = paste0(rule$xCol, " between ", rule$yFrom, " and ", rule$yTo),
    overlaps = paste0(rule$xFrom, "..", rule$xTo, " overlaps ", rule$yFrom, "..", rule$yTo),
    "")
}

# A rule as the check keeps it: shape and slots, window bounds as numbers, inclusive as a boolean.
sv_join_rule_normalize <- function(rule) {
  out <- list(shape = rule$shape)
  for (s in sv_rule_slots(rule$shape)) out[[s]] <- rule[[s]]
  if (rule$shape == "window") {
    out$from <- sv_whole_number(rule$from)
    out$to <- sv_whole_number(rule$to)
  }
  if (rule$shape %in% c("before", "after")) out$inclusive <- !identical(rule$inclusive, FALSE)
  out
}

# The row pairs (.rx, .ry) a rule joins. Keys are one string per row, NA when any part is NA;
# under a rule a missing key matches nothing (na_matches = "never").
sv_join_rule_pairs <- function(x, y, by_x, by_y, rule, fn = NULL) {
  key <- function(df, by) {
    k <- sv_join_keys(df[by], fn)
    k[sv_join_any_na(df[by])] <- NA_character_
    k
  }
  tx <- data.frame(.sv_k = key(x, by_x), .sv_rx = seq_len(nrow(x)), stringsAsFactors = FALSE)
  ty <- data.frame(.sv_k = key(y, by_y), .sv_ry = seq_len(nrow(y)), stringsAsFactors = FALSE)
  put <- function(tab, nm, v) {
    tab[[nm]] <- v
    tab
  }
  shape <- rule$shape
  strict <- identical(rule$inclusive, FALSE)
  by <- switch(shape,
    between = {
      tx <- put(tx, ".sv_xa", x[[rule$xCol]])
      ty <- put(put(ty, ".sv_ya", y[[rule$yFrom]]), ".sv_yb", y[[rule$yTo]])
      dplyr::join_by(.sv_k, between(.sv_xa, .sv_ya, .sv_yb))
    },
    overlaps = {
      tx <- put(put(tx, ".sv_xa", x[[rule$xFrom]]), ".sv_xb", x[[rule$xTo]])
      ty <- put(put(ty, ".sv_ya", y[[rule$yFrom]]), ".sv_yb", y[[rule$yTo]])
      dplyr::join_by(.sv_k, overlaps(.sv_xa, .sv_xb, .sv_ya, .sv_yb))
    },
    window = {
      xv <- x[[rule$xCol]]
      unit <- if (inherits(xv, "POSIXt")) 86400 else 1
      tx <- put(put(tx, ".sv_xa", xv + as.numeric(rule$from) * unit), ".sv_xb", xv + as.numeric(rule$to) * unit)
      ty <- put(ty, ".sv_ya", y[[rule$yCol]])
      dplyr::join_by(.sv_k, between(y$.sv_ya, x$.sv_xa, x$.sv_xb))
    },
    before = {
      tx <- put(tx, ".sv_xa", x[[rule$xCol]])
      ty <- put(ty, ".sv_ya", y[[rule$yCol]])
      if (strict) dplyr::join_by(.sv_k, closest(.sv_xa > .sv_ya)) else dplyr::join_by(.sv_k, closest(.sv_xa >= .sv_ya))
    },
    after = {
      tx <- put(tx, ".sv_xa", x[[rule$xCol]])
      ty <- put(ty, ".sv_ya", y[[rule$yCol]])
      if (strict) dplyr::join_by(.sv_k, closest(.sv_xa < .sv_ya)) else dplyr::join_by(.sv_k, closest(.sv_xa <= .sv_ya))
    }
  )
  pairs <- dplyr::inner_join(tx, ty, by = by, na_matches = "never", relationship = "many-to-many")
  data.frame(.rx = pairs$.sv_rx, .ry = pairs$.sv_ry)
}

# The core numbers (as sv_join_counts_from() gives them) of a rule join, from its row pairs.
sv_join_rule_counts <- function(pairs, n_x, n_y, key_core, nearest) {
  px <- tabulate(pairs$.rx, n_x)
  py <- tabulate(pairs$.ry, n_y)
  core <- sv_join_rule_core(
    list(matched_x = sum(px > 0L), matched_y = sum(py > 0L),
         many_x = any(py > 1L), many_y = any(px > 1L), inner = nrow(pairs)),
    n_x, n_y, key_core, nearest
  )
  core$unmatched_rows_x <- which(px == 0L)
  core$unmatched_rows_y <- which(py == 0L)
  core
}

# The core numbers of a rule join from the scalars of its pairs: rows with a pair (`matched_x/y`),
# some y row with several x rows (`many_x`) or the reverse (`many_y`), and the pair count (`inner`).
# The distinct / duplicate key counts stay those of the keys (`key_core`). Shared by the in-memory
# check and the duckdb one (sv_lazy_rule_scalars()).
sv_join_rule_core <- function(s, n_x, n_y, key_core, nearest) {
  core <- sv_join_counts_from(
    list(
      distinct_x = key_core$distinct_x, distinct_y = key_core$distinct_y,
      distinct_matched = s$inner > 0,
      matched_x = s$matched_x, matched_y = s$matched_y,
      dup_keys_x = key_core$dup_keys_x, dup_keys_y = key_core$dup_keys_y,
      many_x = s$many_x, many_y = s$many_y,
      inner = s$inner
    ),
    n_x = n_x, n_y = n_y
  )
  core$distinct_matched <- key_core$distinct_matched
  if (nearest) core$rows[c("right_join", "full_join")] <- list(NA_real_, NA_real_)
  core$rows <- lapply(core$rows, as.numeric)
  core
}

# What Strict writes into a join, per join type (Ruling R2): an entry is absent when it would
# write nothing. `unmatched = "error"` only when every row of the checked side has a partner.
sv_join_strict_args <- function(core, n_x, n_y, rule = NULL) {
  out <- list()
  if (identical(core$relationship, "no matches")) return(out)
  nearest <- !is.null(rule) && rule$shape %in% c("before", "after")
  all_x <- core$matched_x == n_x
  all_y <- core$matched_y == n_y
  for (type in c("left_join", "inner_join", "right_join", "full_join")) {
    if (nearest && type %in% c("right_join", "full_join")) next
    args <- list(relationship = core$relationship)
    unmatched <- switch(type, left_join = all_y, right_join = all_x, inner_join = all_x && all_y, FALSE)
    if (unmatched) args$unmatched <- "error"
    out[[type]] <- args
  }
  out
}

utils::globalVariables(c(".sv_k", ".sv_rx", ".sv_ry", ".sv_xa", ".sv_xb", ".sv_ya", ".sv_yb",
                         "between", "overlaps", "closest"))
