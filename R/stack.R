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
      # dttm to chr formats each input in its own time zone (the lazy twin must match)
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

# The plan of a stack. A lazy (duckdb / Arrow) input goes to sv_lazy_stack_plan(), the same plan from 0 rows
# and one aggregated query per input; `con_env` is the session connection it may use.
sv_stack_plan <- function(tables, fixes = list(), id_col = NULL, con_env = NULL) {
  if (any(vapply(tables, sv_is_lazy_input, NA))) return(sv_lazy_stack_plan(tables, fixes, id_col, con_env))
  na_fun <- function(reqs) {
    vapply(reqs, function(r) {
      v <- sv_stack_cast(r$x, r$from, r$to, r$zone)
      as.integer(sum(is.na(v) & !is.na(r$x)))
    }, 1L)
  }
  sv_stack_plan_core(tables, names(tables), fixes, id_col, na_fun, function() sum(vapply(tables, nrow, 1L)))
}

# The plan from `tables`: the inputs themselves, or 0-row samples of them (types, labels, zones and factor
# levels are all it reads). `na_fun(reqs)` gives the NA count of each cast cell `list(i, src, from, to, zone, x)`
# (`src` is the column's name in input `i` before any rename), `n_rows_fun()` the row count.
sv_stack_plan_core <- function(tables, inputs, fixes, id_col, na_fun, n_rows_fun) {
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

  if (is.null(id_col)) {
    id_col <- "source"
    k <- 2L
    while (id_col %in% all_names) {
      id_col <- paste0("source_", k)
      k <- k + 1L
    }
  } else if (id_col %in% all_names) {
    stop(sprintf("%s is a column of the stack.", id_col), call. = FALSE)
  }

  plan <- list(inputs = inputs, id_col = id_col,
               n_rows = NA_integer_,
               columns = list(), kept_labels = list(), tz = list())
  reqs <- list()
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
    kept_zone <- unname(zones[!is.na(zones)][1])
    cast <- ifelse(is.na(types) | types == target, NA_character_, target)
    rename_from <- unname(vapply(inputs, function(nm) renamed[[cn]][nm] %||% NA_character_, ""))
    na <- ifelse(present, 0L, NA_integer_)
    for (i in which(present & !is.na(cast))) {
      reqs[[length(reqs) + 1L]] <- list(
        i = i, ci = length(plan$columns) + 1L, src = if (is.na(rename_from[i])) cn else rename_from[i],
        from = unname(types[i]), to = target, zone = if (is.na(zones[i])) NULL else zones[i], x = xs[[i]])
    }
    col <- list(name = cn, types = unname(types), labels = unname(labels), zones = unname(zones),
                target = target, targets = cand, cast = unname(cast),
                rename_from = rename_from,
                near_miss_of = unname(near[[cn]]), na = unname(na), status = character())
    if (target == "fct") {
      lv <- lapply(px, levels)
      col$levels <- unique(unlist(lv, use.names = FALSE))
      col$levels_differ <- length(unique(lv)) > 1L
      col$ordered <- length(px) > 0L && all(vapply(px, is.ordered, NA))
    }
    if (!is.na(kept_zone)) plan$tz[[cn]] <- kept_zone
    if (!all(is.na(labels))) plan$kept_labels[[cn]] <- unname(labels[!is.na(labels)][1])
    plan$columns[[length(plan$columns) + 1L]] <- col
  }
  vals <- na_fun(reqs)
  for (k in seq_along(reqs)) plan$columns[[reqs[[k]]$ci]]$na[reqs[[k]]$i] <- vals[k]
  plan$n_rows <- n_rows_fun()
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
#' that differ only in case (these are never merged unless you ask with `rename`). A value a cast
#' cannot convert becomes `NA`, and the `NA` count says how many. Some casts change values without
#' an `NA`: a date-time cast to text drops fractional seconds, a number cast to text keeps 15
#' significant digits, and an `integer64` column that is cast is read as a double first (digits
#' beyond 2^53 are lost). A date-time cast to a date is its UTC date; a date cast to a date-time is
#' midnight UTC, shown in the zone the stack keeps.
#'
#' With a duckdb or Arrow table the check needs duckdb, and runs there: duckdb reads two names
#' that differ only in case as one, so such a pair must be merged with `rename` (the check says
#' so, and [sv_stack()] refuses it). duckdb tables carry no labels; Arrow tables do.
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
  named <- sv_stack_dots(list(...), as.list(substitute(list(...)))[-1])
  dots <- named$tables
  nms <- names(dots)
  refs <- named$refs
  for (arg in c("cast", "rename")) {
    v <- get(arg)
    if (!is.null(v) && (!is.character(v) || anyNA(v) || is.null(names(v)) || any(!nzchar(names(v))))) {
      stop(sprintf("`%s` must be a named character vector, e.g. c(AGE = \"chr\").", arg), call. = FALSE)
    }
  }
  if (length(dots) < 2L || length(dots) > 8L) stop("Stack 2 to 8 tables.", call. = FALSE)
  if (anyDuplicated(nms)) stop("Each table needs its own name.", call. = FALSE)
  if (!all(vapply(dots, function(t) is.data.frame(t) || sv_is_lazy_input(t), NA))) {
    stop("Every table must be a data frame, a duckdb table or an Arrow table.", call. = FALSE)
  }
  kinds <- vapply(dots, function(t) if (is.data.frame(t)) NA_character_ else sv_lazy_origin(t), "", USE.NAMES = FALSE)
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
  plan$code <- sv_stack_code(plan, refs, kinds)$code
  structure(plan, class = "sv_stack_check")
}

#' @export
print.sv_stack_check <- function(x, ...) {
  cat(x$text, sep = "\n")
  print(x$table, row.names = FALSE)
  if (nzchar(x$code %||% "")) cat(x$code, "\n", sep = "")
  invisible(x)
}

# ---- stacked rows and the code that rebuilds them ----

# The named tables and their code references from the `...` of sv_stack_check()/sv_stack(): an
# unnamed table is named by its expression (as sideview() names it) and that expression is its ref.
sv_stack_dots <- function(dots, exprs) {
  refs <- NULL
  if (length(dots) == 1L && sv_is_table_list(dots[[1]])) {
    dots <- dots[[1]]
    refs <- unname(sv_escape_ident(names(dots)))
    exprs <- as.list(names(dots))
  }
  nms <- names(dots) %||% rep("", length(dots))
  if (is.null(refs)) refs <- vapply(exprs, function(e) paste(deparse(e, backtick = TRUE), collapse = " "), "")
  for (i in seq_along(dots)) {
    if (!nzchar(nms[i])) {
      nms[i] <- make.names(sub("^.*\\$", "", deparse(exprs[[i]])[1]))
    }
  }
  names(dots) <- nms
  list(tables = dots, refs = unname(refs))
}

# The stacked data frame of `tables` (named, in plan order) under `plan`: renames, casts, bind_rows(.id =)
# and the kept labels (bind_rows() drops them).
sv_stack_rows <- function(tables, plan) {
  inputs <- plan$inputs
  if (!identical(names(tables), inputs)) stop("The plan was made for other tables.", call. = FALSE)
  parts <- lapply(seq_along(inputs), function(i) {
    d <- tables[[i]]
    for (col in plan$columns) {
      from <- col$rename_from[i]
      if (!is.na(from)) names(d)[names(d) == from] <- col$name
    }
    for (col in plan$columns) {
      if (is.na(col$cast[i])) next
      zone <- if (identical(col$target, "dttm")) plan$tz[[col$name]] else col$zones[i]
      if (length(zone) && is.na(zone)) zone <- NULL
      d[[col$name]] <- sv_stack_cast(d[[col$name]], col$types[i], col$target, zone)
    }
    d
  })
  names(parts) <- inputs
  out <- do.call(dplyr::bind_rows, c(parts, list(.id = plan$id_col)))
  for (cn in names(plan$kept_labels)) attr(out[[cn]], "label") <- plan$kept_labels[[cn]]
  out
}

# The in-memory code for one cast (the twin of sv_stack_cast(); dplyr and base R only). `x` is the
# column as written in the code, `zone` the zone a dttm is shown in. Task 4's JS twin writes the same text.
sv_stack_cast_code <- function(x, from, to, zone = "") {
  q <- function(s) encodeString(s, quote = "\"")
  num_of_chr <- function(re) {
    paste0("suppressWarnings(as.numeric(replace(", x, ", !grepl(", q(re), ", ", x, ", perl = TRUE), NA)))")
  }
  whole <- function(v) {
    paste0("(function(v) as.integer(ifelse(!is.na(v) & v == trunc(v) & abs(v) <= 2147483647, v, NA)))(", v, ")")
  }
  switch(to,
    lgl = if (from == "chr") {
      paste0("ifelse(", x, " == \"TRUE\", TRUE, ifelse(", x, " == \"FALSE\", FALSE, NA))")
    } else {
      paste0("ifelse(as.numeric(", x, ") %in% c(0, 1), as.numeric(", x, ") == 1, NA)")
    },
    int = if (from == "lgl") paste0("as.integer(", x, ")")
          else if (from == "chr") whole(num_of_chr(sv_supp_int_re))
          else whole(paste0("as.numeric(", x, ")")),
    num = if (from == "chr") {
      paste0("(function(v) replace(v, abs(v) > 1e308, NA))(", num_of_chr(sv_supp_dbl_re), ")")
    } else paste0("as.numeric(", x, ")"),
    chr = if (from == "dttm") {
      # each input is formatted in its own time zone, as sv_stack_cast() does
      paste0("format(", x, ", \"%Y-%m-%d %H:%M:%S\", tz = ", q(zone), ")")
    } else paste0("as.character(", x, ")"),
    date = if (from == "dttm") paste0("as.Date(", x, ", tz = \"UTC\")") else {
      paste0("as.Date(replace(", x, ", !grepl(", q("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"), ", ", x,
             "), NA), format = \"%Y-%m-%d\")")
    },
    dttm = paste0("as.POSIXct(", x, ", tz = ", q(zone), ")"),
    fct = paste0("factor(as.character(", x, "))"),
    stop(sprintf("Cannot cast to %s.", to), call. = FALSE))
}

# The code that rebuilds the stack (decision 9): `list(code, kind)`. `refs` is the R reference of each
# input, `kinds` is NA, "duckdb" or "arrow" per input. The in-memory form is one expression with no pipe:
# nested bind_rows(), a mutate() per cast input, rename() inside the argument, and a label mutate() on top.
sv_stack_code <- function(plan, refs, kinds) {
  q <- function(s) encodeString(s, quote = "\"")
  if (any(!is.na(kinds))) return(sv_stack_code_lazy(plan, refs, kinds))
  args <- vapply(seq_along(plan$inputs), function(i) {
    ref <- refs[i]
    ren <- Filter(function(col) !is.na(col$rename_from[i]), plan$columns)
    if (length(ren)) {
      pairs <- vapply(ren, function(col) paste0(sv_escape_ident(col$name), " = ", sv_escape_ident(col$rename_from[i])), "")
      ref <- paste0("dplyr::rename(", ref, ", ", paste(pairs, collapse = ", "), ")")
    }
    cst <- Filter(function(col) !is.na(col$cast[i]), plan$columns)
    if (length(cst)) {
      sets <- vapply(cst, function(col) {
        zone <- if (identical(col$target, "dttm")) plan$tz[[col$name]] else col$zones[i]
        if (!length(zone) || is.na(zone)) zone <- if (identical(col$target, "dttm")) "UTC" else ""
        paste0(sv_escape_ident(col$name), " = ",
               sv_stack_cast_code(sv_escape_ident(col$name), col$types[i], col$target, zone))
      }, "")
      ref <- paste0("dplyr::mutate(", ref, ", ", paste(sets, collapse = ", "), ")")
    }
    paste0(sv_escape_ident(plan$inputs[i]), " = ", ref)
  }, "")
  code <- paste0("dplyr::bind_rows(", paste(args, collapse = ", "), ", .id = ", q(plan$id_col), ")")
  if (length(plan$kept_labels)) {
    sets <- vapply(names(plan$kept_labels), function(cn) {
      id <- sv_escape_ident(cn)
      paste0(id, " = structure(", id, ", label = ", q(plan$kept_labels[[cn]]), ")")
    }, "")
    code <- paste0("dplyr::mutate(", code, ", ", paste(sets, collapse = ", "), ")")
  }
  list(code = code, kind = NA_character_)
}

# The lazy form of the code (decision 9): every input goes onto one duckdb connection, is given the id column,
# its casts and typed NAs for the columns it lacks, is put in stack order, and the inputs are joined by nested
# union_all(). A duckdb input stays where it is; an Arrow input is moved with to_duckdb() (compute() makes a
# real table, as a view can be collected before the query runs); a data frame is copied in with copy_to() or,
# with no duckdb input, made an Arrow table first. The casts are the expressions sv_lazy_stack() runs, printed.
# No labels are written: a lazy card carries them from the plan. `kind` is always "duckdb".
sv_stack_code_lazy <- function(plan, refs, kinds) {
  q <- function(s) encodeString(s, quote = "\"")
  duck <- which(!is.na(kinds) & kinds == "duckdb")
  duck_ref <- if (length(duck)) refs[duck[1L]] else NULL
  show <- sv_stack_show
  parts <- vapply(seq_along(plan$inputs), function(i) {
    ref <- refs[i]
    placed <- if (is.na(kinds[i])) {
      if (is.null(duck_ref)) paste0("arrow::to_duckdb(arrow::arrow_table(", ref, "))")
      else paste0("dplyr::copy_to(dbplyr::remote_con(", duck_ref, "), ", ref, ", name = ",
                  q(paste0("sideview_", plan$inputs[i], "_", i)), ", overwrite = TRUE)")
    } else if (kinds[i] == "arrow") {
      if (is.null(duck_ref)) paste0("arrow::to_duckdb(", ref, ")")
      else paste0("dplyr::compute(arrow::to_duckdb(", ref, ", con = dbplyr::remote_con(", duck_ref, ")))")
    } else ref
    p <- sv_stack_lazy_parts(plan, i)
    if (length(p$rename)) {
      pairs <- vapply(names(p$rename), function(n) paste0(sv_escape_ident(n), " = ", sv_escape_ident(p$rename[[n]])), "")
      placed <- paste0("dplyr::rename(", placed, ", ", paste(pairs, collapse = ", "), ")")
    }
    sets <- vapply(names(p$sets), function(n) {
      e <- p$sets[[n]]
      paste0(sv_escape_ident(n), " = ", if (is.character(e)) q(e) else show(e))
    }, "")
    cols <- paste0("c(", paste(q(p$cols), collapse = ", "), ")")
    paste0("dplyr::select(dplyr::mutate(", placed, ", ", paste(sets, collapse = ", "), "), dplyr::all_of(", cols, "))")
  }, "")
  code <- Reduce(function(a, b) paste0("dplyr::union_all(", a, ", ", b, ")"), parts, right = TRUE)
  list(code = code, kind = "duckdb")
}

# TRUE when a data-frame input no longer has the columns (names and types) the check saw, or when the
# inputs are all data frames and their row count is not the check's. Lazy inputs are not read (that would
# be a query each): only their table names are compared, by the caller.
sv_stack_check_stale <- function(tables, check) {
  for (i in seq_along(tables)) {
    t <- tables[[i]]
    if (!is.data.frame(t)) next
    had <- Filter(function(col) !is.na(col$types[i]), check$columns)
    want <- stats::setNames(vapply(had, function(col) col$types[i], ""),
                            vapply(had, function(col) if (is.na(col$rename_from[i])) col$name else col$rename_from[i], ""))
    now <- vapply(t, sv_stack_tname, "")
    if (!setequal(names(now), names(want)) || !identical(unname(now[names(want)]), unname(want))) return(TRUE)
  }
  all_df <- all(vapply(tables, is.data.frame, NA))
  all_df && !is.na(check$n_rows %||% NA) && sum(vapply(tables, nrow, 1L)) != check$n_rows
}

#' Stack tables
#'
#' Puts 2 to 8 tables one under another, with `bind_rows()` and the type decisions of
#' [sv_stack_check()]: a column whose type differs is cast to the type the check shows (or the one
#' you chose), and a value that cannot be cast becomes `NA` (see [sv_stack_check()] for the casts
#' that change a value without an `NA`). A column `source` (or `source_2`, ... when taken) holds
#' each row's table name. Columns appear in order of first appearance; labels are kept (the first
#' table's label for a column, else the first label met).
#'
#' @param ... Two or more data frames, duckdb tables or Arrow tables, named or not (an unnamed
#'   table is named by its expression).
#' @param check A [sv_stack_check()] made for the same tables, holding the fixes (casts and renames)
#'   to apply. When `NULL`, the check is made with no fixes. A check made for other tables is
#'   refused, and so is one made before a data frame's columns, types or row count changed (a duckdb
#'   or Arrow table is not read again for this: only its name is compared).
#' @return A data frame with exactly the sum of the inputs' rows; a lazy duckdb table (never
#'   collected) when an input is a duckdb or Arrow table.
#' @export
#' @examples
#' wave1 <- data.frame(AGE = c(34, 51), SEX = c("F", "M"))
#' wave2 <- data.frame(AGE = c("29", "40"), SEX = c("M", "M"))
#' sv_stack(wave1, wave2)
sv_stack <- function(..., check = NULL) {
  named <- sv_stack_dots(list(...), as.list(substitute(list(...)))[-1])
  tables <- named$tables
  if (is.null(check)) check <- sv_stack_check(...)
  if (!inherits(check, "sv_stack_check") || !identical(check$inputs, names(tables))) {
    stop("`check` was made for other tables.", call. = FALSE)
  }
  if (!all(vapply(tables, function(t) is.data.frame(t) || sv_is_lazy_input(t), NA))) {
    stop("Every table must be a data frame, a duckdb table or an Arrow table.", call. = FALSE)
  }
  if (sv_stack_check_stale(tables, check)) {
    stop("`check` was made for other data: the tables have changed since. Run sv_stack_check() again.", call. = FALSE)
  }
  # a duckdb or Arrow input gives a lazy table: one union_all on a duckdb connection, never collected
  if (any(vapply(tables, sv_is_lazy_input, NA))) return(sv_lazy_stack(tables, check, sv_lazy_env()))
  sv_stack_rows(tables, check)
}
