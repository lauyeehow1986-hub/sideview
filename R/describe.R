#' Describe tables as plain text
#'
#' Reads each table and writes one sentence for the table and one line for each
#' column: its label, kind, missing and distinct counts, number ranges and the
#' commonest text values. It is the text twin of looking at the cards on the
#' canvas, for a screen reader or a console. A lazy (duckdb or Arrow) table is
#' never collected: only the summaries of [sv_column_profile()] are read.
#'
#' @param x,... Data frames, duckdb tables or Arrow tables, named or not (an
#'   unnamed table is named from its expression, as in [sideview()]), or one
#'   list of them.
#' @param n_levels How many of the commonest values of a text column to list.
#' @return The lines, invisibly, as a character vector of class
#'   `sv_description`. Printing it writes one line per row.
#' @export
#' @examples
#' patients <- data.frame(id = 1:4, sex = c("M", "F", "F", NA),
#'                        age = c(40, 51, 62, 38))
#' sv_describe(patients)
sv_describe <- function(x, ..., n_levels = 5) {
  if (missing(x)) {
    vals <- list(...)
    exprs <- as.list(substitute(list(...))[-1])
  } else {
    vals <- list(x, ...)
    exprs <- as.list(substitute(list(x, ...))[-1])
  }
  if (length(vals) == 1L && sv_is_table_list(vals[[1]])) {
    vals <- vals[[1]]
    exprs <- as.list(names(vals) %||% character())
  }
  n_levels <- max(0L, as.integer(n_levels))
  con_env <- sv_lazy_env()
  on.exit(sv_lazy_close(con_env), add = TRUE)
  out <- character()
  for (i in seq_along(vals)) {
    val <- vals[[i]]
    nm <- names(vals)[i]
    if (is.null(nm) || is.na(nm) || !nzchar(nm)) {
      nm <- if (i <= length(exprs) && !is.null(exprs[[i]])) {
        make.names(sub("^.*\\$", "", deparse(exprs[[i]])[1]))
      } else {
        paste0("Table_", i)
      }
    }
    out <- c(out, sv_describe_one(val, nm, n_levels, con_env))
  }
  invisible(structure(out, class = "sv_description"))
}

#' @export
print.sv_description <- function(x, ...) {
  cat(unclass(x), sep = "\n")
  invisible(x)
}

# The lines of one table: its sentence, then one line per column.
sv_describe_one <- function(val, name, n_levels, con_env) {
  card <- if (inherits(val, "sideview_card")) val else sv_normalize_arg(val, name)
  if (!identical(card$type, "grid")) {
    stop("`", name, "` is not a table.", call. = FALSE)
  }
  src <- if (!is.null(card$source)) card$source else card$data
  lazy <- sv_is_lazy_input(src)
  cols <- if (lazy) sv_lazy_names(src) else names(src)
  name <- card$name
  rows <- card$dims[1] %||% NROW(src)
  top_n <- max(n_levels, 1L)
  profs <- lapply(seq_along(cols), function(j) {
    if (lazy) {
      sv_lazy_column_profile(src, cols[j], top_n = top_n, con_env = con_env)
    } else {
      sv_column_profile(src[[j]], top_n = top_n)
    }
  })
  k <- sum(vapply(profs, function(p) p$n_missing > 0, logical(1)))
  dom <- card$cdisc$domain
  head <- paste0(name, ", ",
                 if (!is.null(dom) && !is.na(dom) && nzchar(dom)) paste0(dom, " domain, "),
                 sv_say_num(rows), if (rows == 1) " row" else " rows", " by ",
                 sv_say_num(length(cols)), if (length(cols) == 1L) " column" else " columns", ", ",
                 if (k == 0) "no columns have" else if (k == 1) "1 column has" else paste0(sv_say_num(k), " columns have"),
                 " missing values.")
  lines <- vapply(seq_along(cols), function(j) sv_describe_column(cols[j], profs[[j]], n_levels), "")
  c(head, if (length(lines)) paste0("  ", lines))
}

# One column line, without the indent.
sv_describe_column <- function(name, p, n_levels) {
  lab <- p$label
  nl <- if (is.character(lab) && length(lab) == 1L && !is.na(lab) && nzchar(lab)) paste0(name, ", ", lab) else name
  word <- switch(p$kind, numeric = "number", character = "text", logical = "true or false",
                 date = "date", datetime = "date-time", p$class %||% "other")
  s <- paste0(nl, ", ", word, ": ", sv_say_num(p$n_missing), " missing, ", sv_say_num(p$n_distinct), " distinct")
  st <- p$stats
  if (p$kind == "numeric" && !is.null(st)) {
    s <- paste0(s, ", min ", sv_say_num(st$min), ", median ", sv_say_num(st$median), ", max ", sv_say_num(st$max))
  }
  top <- p$top
  if (p$kind == "character" && NROW(top) > 0L && n_levels > 0L) {
    sh <- utils::head(seq_len(nrow(top)), n_levels)
    s <- paste0(s, ", top ", paste0(vapply(top$value[sh], sv_say_value, ""), " (",
                                    vapply(top$n[sh], sv_say_num, ""), ")", collapse = ", "))
  }
  paste0(s, ".")
}
