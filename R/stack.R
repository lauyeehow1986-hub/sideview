# Stacking tables: the column check. sv_stack_check() compares the columns of 2 to 8 tables and says
# what stacking them would do (types that change, values that become NA, near-miss names, labels).
# sv_stack_plan() is the plan the check, the stacked rows and the generated code all read.

sv_stack_known <- c("lgl", "int", "num", "chr", "fct", "date", "dttm")
sv_stack_rank <- c(lgl = 1L, int = 2L, num = 3L, chr = 4L)

# The type name of a column (decision 1). `other` carries the class in attr(, "class1").
sv_stack_type <- function(x) {
  if (inherits(x, "integer64")) return("num")
  if (is.factor(x)) return("fct")
  if (inherits(x, "POSIXct")) return("dttm")
  if (inherits(x, "Date")) return("date")
  if (is.null(attr(x, "class"))) {
    if (is.logical(x)) return("lgl")
    if (is.integer(x)) return("int")
    if (is.double(x)) return("num")
    if (is.character(x)) return("chr")
  }
  structure("other", class1 = class(x)[1])
}

# The type as the column table shows it: an `other` column is named by its class.
sv_stack_tname <- function(x) {
  t <- sv_stack_type(x)
  if (identical(as.character(t), "other")) attr(t, "class1") else as.character(t)
}

sv_stack_is_list <- function(x) is.list(x) && !inherits(x, c("POSIXlt", "integer64"))

sv_stack_dbl <- function(x) {
  if (inherits(x, "integer64") && requireNamespace("bit64", quietly = TRUE)) return(bit64::as.double.integer64(x))
  suppressWarnings(as.numeric(unclass(x)))
}

# The in-memory cast table (decision 3): every cast converts a value exactly or gives NA.
sv_stack_cast <- function(x, from, to, zone = NULL) {
  if (identical(from, to)) return(x)
  ws_num <- function(v, re) {
    ok <- grepl(re, v, perl = TRUE)
    suppressWarnings(as.numeric(ifelse(ok, v, NA_character_)))
  }
  switch(to,
    lgl = if (from == "chr") {
      ifelse(x == "TRUE", TRUE, ifelse(x == "FALSE", FALSE, NA))
    } else {
      v <- sv_stack_dbl(x)
      ifelse(v %in% c(0, 1), v == 1, NA)
    },
    int = {
      v <- if (from == "chr") ws_num(x, sv_supp_int_re) else sv_stack_dbl(x)
      ok <- !is.na(v) & v == trunc(v) & abs(v) <= 2147483647
      v[!ok] <- NA_real_
      as.integer(v)
    },
    num = {
      v <- if (from == "chr") ws_num(x, sv_supp_dbl_re) else sv_stack_dbl(x)
      if (from == "chr") v[is.na(v) | abs(v) > sv_supp_dbl_max] <- NA_real_
      v
    },
    chr = switch(from,
      dttm = format(x, "%Y-%m-%d %H:%M:%S", tz = zone %||% attr(x, "tzone")[1] %||% ""),
      num = as.character(sv_stack_dbl(x)),
      as.character(x)),
    date = if (from == "dttm") as.Date(x, tz = "UTC") else {
      v <- x
      v[!grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", v)] <- NA_character_
      as.Date(v, format = "%Y-%m-%d")
    },
    dttm = as.POSIXct(x, tz = zone %||% "UTC"),
    fct = if (from == "fct") x else factor(as.character(x)),
    stop(sprintf("Cannot cast to %s.", to), call. = FALSE))
}

# Can a value of type `from` be cast to `to` (decision 3)?
sv_stack_reach <- function(to, from_types) {
  all(vapply(from_types, function(f) {
    f == to || switch(to,
      lgl = f %in% c("int", "num", "chr"),
      int = f %in% c("lgl", "num", "chr"),
      num = f %in% c("lgl", "int", "chr"),
      chr = TRUE,
      date = f %in% c("dttm", "chr"),
      dttm = f == "date",
      FALSE)
  }, NA))
}

# The default target of a column from its present inputs (decision 2).
sv_stack_default <- function(xs, ty) {
  u <- unique(ty)
  if (length(u) == 1L) {
    if (u != "fct") return(u)
    ords <- vapply(xs, is.ordered, NA)
    if (!any(ords)) return("fct")
    if (all(ords) && length(unique(lapply(xs, levels))) == 1L) return("fct")
    return("chr")
  }
  if (any(!u %in% sv_stack_known) || "fct" %in% u) return("chr")
  if (all(u %in% c("date", "dttm"))) return("dttm")
  if (any(u %in% c("date", "dttm"))) return("chr")
  names(sv_stack_rank)[max(sv_stack_rank[u])]
}

# Case-insensitive near-miss partners: for each name, the first spelling of its lower-case form
# when that is a different name. A group that clashes inside one input is left alone.
sv_stack_near <- function(name_list) {
  all <- unique(unlist(name_list, use.names = FALSE))
  low <- tolower(all)
  clash <- unique(unlist(lapply(name_list, function(n) tolower(n)[duplicated(tolower(n))])))
  first <- all[match(low, low)]
  out <- ifelse(low %in% clash | first == all, NA_character_, first)
  stats::setNames(out, all)
}

sv_stack_fix_cols <- function(fixes, action) {
  keep <- vapply(fixes, function(f) identical(f$action, action), NA)
  fixes[keep]
}

sv_stack_plan <- function(tables, fixes = list()) {
  inputs <- names(tables)
  n_in <- length(inputs)
  for (nm in inputs) {
    for (cn in names(tables[[nm]])) {
      if (sv_stack_is_list(tables[[nm]][[cn]])) {
        stop(sprintf("Column %s in %s is a list column; it cannot be stacked.", cn, nm), call. = FALSE)
      }
    }
  }
  fixes <- fixes %||% list()
  acts <- vapply(fixes, function(f) f$action %||% "", "")
  if (any(!acts %in% c("cast", "rename", "keep"))) {
    stop(sprintf("Unknown stack fix: %s", acts[!acts %in% c("cast", "rename", "keep")][1]), call. = FALSE)
  }
  name_list <- lapply(tables, names)
  if (length(fixes) > length(unique(unlist(name_list, use.names = FALSE)))) {
    stop("Too many fixes.", call. = FALSE)
  }

  # renames first: they merge a near-miss column into its partner
  renamed <- list()
  near0 <- sv_stack_near(name_list)
  for (f in sv_stack_fix_cols(fixes, "rename")) {
    col <- f$column
    to <- f$to
    if (!col %in% names(near0) || !to %in% names(near0) || identical(col, to) ||
        tolower(col) != tolower(to) || (is.na(near0[[col]]) && is.na(near0[[to]]))) {
      stop(sprintf("%s is not a near-miss of %s.", col, to), call. = FALSE)
    }
    for (i in seq_len(n_in)) {
      nms <- names(tables[[i]])
      if (col %in% nms) {
        if (to %in% nms) stop(sprintf("%s is not a near-miss of %s.", col, to), call. = FALSE)
        names(tables[[i]])[nms == col] <- to
        renamed[[to]] <- c(renamed[[to]], stats::setNames(col, inputs[i]))
      }
    }
  }
  name_list <- lapply(tables, names)
  all_names <- unique(unlist(name_list, use.names = FALSE))
  near <- sv_stack_near(name_list)

  casts <- sv_stack_fix_cols(fixes, "cast")
  for (f in casts) {
    if (!f$column %in% all_names) stop(sprintf("Not in the stack: %s", f$column), call. = FALSE)
  }

  id_col <- "source"
  k <- 2L
  while (id_col %in% all_names) {
    id_col <- paste0("source_", k)
    k <- k + 1L
  }

  plan <- list(inputs = inputs, id_col = id_col,
               n_rows = sum(vapply(tables, nrow, 1L)),
               columns = list(), kept_labels = character(), tz = list())
  for (cn in all_names) {
    xs <- lapply(tables, function(t) if (cn %in% names(t)) t[[cn]] else NULL)
    present <- !vapply(xs, is.null, NA)
    types <- vapply(xs, function(x) if (is.null(x)) NA_character_ else sv_stack_tname(x), "")
    px <- xs[present]
    pt <- types[present]
    default <- sv_stack_default(px, pt)
    cand <- unique(c(default, "chr", pt))
    cand <- cand[vapply(cand, function(t) t == default || (t != "fct" && sv_stack_reach(t, pt)), NA)]
    target <- default
    fix <- Filter(function(f) identical(f$column, cn), casts)
    if (length(fix)) {
      target <- fix[[length(fix)]]$to
      if (!target %in% cand) stop(sprintf("%s cannot be cast to %s.", cn, target), call. = FALSE)
    }
    zones <- vapply(xs, function(x) {
      if (inherits(x, "POSIXct")) (attr(x, "tzone")[1] %||% "") else NA_character_
    }, "")
    labels <- vapply(xs, function(x) {
      l <- attr(x, "label")
      if (is.character(l) && length(l) == 1L && !is.na(l) && nzchar(l)) l else NA_character_
    }, "")
    kept_zone <- zones[!is.na(zones)][1]
    cast <- ifelse(is.na(types) | types == target, NA_character_, target)
    na <- vapply(seq_len(n_in), function(i) {
      if (!present[i]) return(NA_integer_)
      if (is.na(cast[i])) return(0L)
      v <- sv_stack_cast(xs[[i]], types[i], target, if (is.na(zones[i])) NULL else zones[i])
      sum(is.na(v) & !is.na(xs[[i]]))
    }, 1L)
    col <- list(name = cn, types = unname(types), labels = unname(labels), zones = unname(zones),
                target = target, targets = cand, cast = unname(cast),
                rename_from = unname(vapply(inputs, function(nm) renamed[[cn]][nm] %||% NA_character_, "")),
                near_miss_of = unname(near[[cn]]), na = unname(na), status = character())
    if (target == "fct") {
      lv <- lapply(px, levels)
      col$levels <- unique(unlist(lv, use.names = FALSE))
      col$levels_differ <- length(unique(lv)) > 1L
    }
    if (!is.na(kept_zone)) plan$tz[[cn]] <- kept_zone
    if (!all(is.na(labels))) plan$kept_labels[[cn]] <- labels[!is.na(labels)][1]
    plan$columns[[length(plan$columns) + 1L]] <- col
  }
  for (i in seq_along(plan$columns)) {
    plan$columns[[i]]$status <- sv_say_stack_status(plan$columns[[i]], plan)
  }
  plan
}

#' Check what stacking tables would do
#'
#' Compares the columns of 2 to 8 tables and reports, column by column, what stacking them one
#' under another would change: types that differ (and the type they would be cast to), values that
#' become `NA` in a cast, labels that differ, columns missing from some tables, and near-miss names
#' that differ only in case (these are never merged unless you ask with `rename`). Nothing is
#' rounded or truncated silently: a cast converts a value exactly or gives `NA`, and the `NA` count
#' says how many.
#'
#' @param ... Two or more data frames. Unnamed tables are named by their expressions, as
#'   [sideview()] names them.
#' @param cast Optional named character vector choosing a column's type, e.g. `c(AGE = "chr")`.
#'   Only an offered type is allowed.
#' @param rename Optional named character vector merging a near-miss column into its partner, e.g.
#'   `c(Age = "AGE")`: the column `Age` is renamed `AGE` in every table that has it.
#' @return An object of class `sv_stack_check`: the plan (`inputs`, `id_col`, `n_rows`,
#'   `columns`, `kept_labels`, `tz`), plus `table` (one row per column, with its type in each input
#'   and a `Status`), `text` (summary lines) and `code`.
#' @export
#' @examples
#' wave1 <- data.frame(AGE = c(34, 51), SEX = c("F", "M"))
#' wave2 <- data.frame(Age = c("29", "40"), SEX = c("M", "M"))
#' sv_stack_check(wave1, wave2)
#' sv_stack_check(wave1, wave2, rename = c(Age = "AGE"))
sv_stack_check <- function(..., cast = NULL, rename = NULL) {
  dots <- list(...)
  exprs <- as.list(substitute(list(...)))[-1]
  if (length(dots) == 1L && sv_is_table_list(dots[[1]])) {
    dots <- dots[[1]]
    exprs <- as.list(names(dots))
  }
  nms <- names(dots) %||% rep("", length(dots))
  for (i in seq_along(dots)) {
    if (!nzchar(nms[i])) {
      nms[i] <- make.names(sub("^.*\\$", "", deparse(exprs[[i]])[1]))
    }
  }
  names(dots) <- nms
  if (length(dots) < 2L || length(dots) > 8L) stop("Stack 2 to 8 tables.", call. = FALSE)
  if (anyDuplicated(nms)) stop("Each table needs its own name.", call. = FALSE)
  if (!all(vapply(dots, is.data.frame, NA))) stop("Every table must be a data frame.", call. = FALSE)
  fixes <- c(
    lapply(seq_along(cast), function(i) list(column = names(cast)[i], action = "cast", to = unname(cast[[i]]))),
    lapply(seq_along(rename), function(i) list(column = names(rename)[i], action = "rename", to = unname(rename[[i]]))))
  plan <- sv_stack_plan(dots, fixes)
  tab <- data.frame(Column = vapply(plan$columns, function(c) c$name, ""), stringsAsFactors = FALSE)
  for (i in seq_along(plan$inputs)) {
    tab[[plan$inputs[i]]] <- vapply(plan$columns, function(c) if (is.na(c$types[i])) "-" else c$types[i], "")
  }
  tab$Status <- vapply(plan$columns, function(c) paste(c$status, collapse = "; "), "")
  plan$table <- tab
  plan$text <- sv_say_stack_text(plan)
  plan$code <- ""
  structure(plan, class = "sv_stack_check")
}

#' @export
print.sv_stack_check <- function(x, ...) {
  cat(x$text, sep = "\n")
  print(x$table, row.names = FALSE)
  if (nzchar(x$code %||% "")) cat(x$code, "\n", sep = "")
  invisible(x)
}
