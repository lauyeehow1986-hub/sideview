#' Universal Normalization Engine for Sideview Cards
#'
#' Converts various R table formats (data.frame, tibble, table, gt, flextable, htmlwidgets)
#' into a standardized `sideview_card` S3 object for rendering on the 2D infinite canvas.
#'
#' @param x An object to normalize (data.frame, tibble, table, gt, flextable, htmlwidget).
#' @param name Optional display name for the card.
#' @param id Optional unique identifier for the card.
#' @param ... Additional arguments passed to methods.
#'
#' @return An object of class `sideview_card`.
#' @export
sv_normalize <- function(x, name = NULL, id = NULL, ...) {
  UseMethod("sv_normalize")
}

# Internal monotonic counter for predictable, side-effect-free ID generation
.card_counter_env <- new.env(parent = emptyenv())
.card_counter_env$val <- 0L

#' Generate a unique ID for a card without perturbing .Random.seed
#' @noRd
generate_card_id <- function(prefix = "card") {
  .card_counter_env$val <- .card_counter_env$val + 1L
  sprintf("%s_%06d", prefix, .card_counter_env$val)
}

#' Create a sideview_card S3 object
#' @noRd
new_sideview_card <- function(id = NULL,
                              name = NULL,
                              type = c("grid", "html", "widget"),
                              data = NULL,
                              html_content = NULL,
                              dims = NULL,
                              col_types = NULL,
                              widget = NULL,
                              is_lazy = FALSE,
                              lazy_source = NULL,
                              source = NULL,
                              code_ref = NULL) {
  type <- match.arg(type)

  if (is.null(id) || length(id) == 0L || is.na(id[1]) || !nzchar(as.character(id[1]))) {
    id <- generate_card_id()
  } else {
    id <- as.character(id[1])
  }

  if (is.null(name) || length(name) == 0L || is.na(name[1]) || !nzchar(as.character(name[1]))) {
    name <- "Table"
  } else {
    name <- as.character(name[1])
  }

  if (!is.null(data) && is.data.frame(data)) {
    if (is.null(dims)) {
      dims <- c(nrow(data), ncol(data))
    }
    if (is.null(col_types)) {
      col_types <- vapply(data, function(col) class(col)[1], character(1))
    }
  }

  if (is.null(code_ref) || length(code_ref) == 0L || is.na(code_ref[1]) || !nzchar(as.character(code_ref[1]))) {
    code_ref <- name
  } else {
    code_ref <- as.character(code_ref[1])
  }

  structure(
    list(
      id = id,
      name = name,
      type = type,
      data = data,
      html_content = html_content,
      dims = dims,
      col_types = col_types,
      widget = widget,
      is_lazy = isTRUE(is_lazy),
      lazy_source = lazy_source,
      source = source,
      code_ref = code_ref
    ),
    class = c("sideview_card", "list")
  )
}

#' @export
sv_normalize.data.frame <- function(x, name = NULL, id = NULL, ...) {
  if (is.null(name)) name <- "Data"
  new_sideview_card(
    id = id,
    name = name,
    type = "grid",
    data = x
  )
}

#' @export
sv_normalize.table <- function(x, name = NULL, id = NULL, ...) {
  if (is.null(name)) name <- "Table"
  df <- as.data.frame(x, stringsAsFactors = FALSE)
  new_sideview_card(
    id = id,
    name = name,
    type = "grid",
    data = df
  )
}

#' @export
sv_normalize.gt_tbl <- function(x, name = NULL, id = NULL, ...) {
  if (is.null(name)) name <- "gt_Table"
  html <- if (requireNamespace("gt", quietly = TRUE)) {
    as.character(gt::as_raw_html(x))
  } else {
    stop("Package 'gt' must be installed to normalize gt_tbl objects.", call. = FALSE)
  }

  raw_data <- tryCatch(
    as.data.frame(x[["_data"]]),
    error = function(e) NULL
  )

  new_sideview_card(
    id = id,
    name = name,
    type = "html",
    data = raw_data,
    html_content = html
  )
}

#' @export
sv_normalize.flextable <- function(x, name = NULL, id = NULL, ...) {
  if (is.null(name)) name <- "flextable"
  html <- if (requireNamespace("flextable", quietly = TRUE)) {
    as.character(flextable::htmltools_value(x))
  } else {
    stop("Package 'flextable' must be installed to normalize flextable objects.", call. = FALSE)
  }

  raw_data <- tryCatch(
    as.data.frame(x[["body"]][["dataset"]]),
    error = function(e) NULL
  )

  new_sideview_card(
    id = id,
    name = name,
    type = "html",
    data = raw_data,
    html_content = html
  )
}

#' @export
sv_normalize.htmlwidget <- function(x, name = NULL, id = NULL, ...) {
  if (is.null(name)) name <- "Widget"
  new_sideview_card(
    id = id,
    name = name,
    type = "widget",
    data = NULL,
    widget = x
  )
}

#' Helper to normalize Arrow tabular and dataset objects zero-copy
#' @noRd
normalize_arrow_object <- function(x, name = NULL, id = NULL, default_name = "ArrowTable", ...) {
  if (!requireNamespace("arrow", quietly = TRUE)) {
    stop("Package 'arrow' must be installed to normalize Arrow objects.", call. = FALSE)
  }
  if (is.null(name) || !nzchar(name)) {
    name <- default_name
  }

  is_mock <- is.list(x) && !inherits(x, "ArrowObject") && !inherits(x, "R6")

  if (is_mock) {
    raw <- unclass(x)
    preview <- if (!is.null(raw$data)) {
      utils::head(as.data.frame(raw$data), 50)
    } else {
      data.frame()
    }

    col_names <- NULL
    col_types <- NULL
    if (!is.null(raw$schema)) {
      sch <- raw$schema
      if (!is.null(sch$names) && length(sch$names) > 0) {
        col_names <- sch$names
      }
      if (!is.null(sch$fields) && length(sch$fields) > 0) {
        if (is.null(col_names)) {
          col_names <- names(sch$fields)
        }
        types <- vapply(sch$fields, function(f) {
          if (is.character(f)) return(f)
          if (is.list(f) && !is.null(f$type$name)) return(as.character(f$type$name))
          if (is.list(f) && !is.null(f$type)) return(as.character(f$type))
          "character"
        }, character(1))
        if (length(types) == length(col_names)) {
          names(types) <- col_names
          col_types <- types
        }
      }
    }

    if (is.null(col_names) || length(col_names) == 0) {
      col_names <- if (is.data.frame(preview)) names(preview) else names(raw)
    }

    if (is.null(col_types) || length(col_types) == 0) {
      if (is.data.frame(preview) && ncol(preview) > 0) {
        col_types <- vapply(preview, function(col) class(col)[1], character(1))
      } else if (!is.null(col_names)) {
        col_types <- rep("character", length(col_names))
        names(col_types) <- col_names
      }
    }

    dims <- if (!is.null(raw$dims)) {
      raw$dims
    } else {
      c(nrow(preview), length(col_names))
    }

    return(new_sideview_card(
      id = id,
      name = name,
      type = "grid",
      data = preview,
      dims = dims,
      col_types = col_types,
      is_lazy = TRUE,
      lazy_source = "arrow"
    ))
  }

  # Real Arrow object (Table, RecordBatch, Dataset)
  preview <- tryCatch(as.data.frame(utils::head(x, 50)), error = function(e) data.frame())

  col_names <- NULL
  col_types <- NULL

  sch <- tryCatch(x$schema, error = function(e) NULL)
  if (!is.null(sch)) {
    s_names <- tryCatch(sch$names, error = function(e) NULL)
    if (!is.null(s_names) && length(s_names) > 0) {
      col_names <- s_names
    }
    s_fields <- tryCatch(sch$fields, error = function(e) NULL)
    if (!is.null(s_fields) && length(s_fields) > 0) {
      if (is.null(col_names)) {
        col_names <- names(s_fields)
      }
      types <- tryCatch(
        vapply(s_fields, function(f) {
          if (is.character(f)) return(f)
          if (!is.null(f$type$name)) return(f$type$name)
          if (!is.null(f$type)) return(as.character(f$type))
          "character"
        }, character(1)),
        error = function(e) NULL
      )
      if (!is.null(types) && length(types) == length(col_names)) {
        names(types) <- col_names
        col_types <- types
      }
    }
  }

  if (is.null(col_names) || length(col_names) == 0) {
    col_names <- tryCatch(names(x), error = function(e) NULL)
    if (is.null(col_names) && is.data.frame(preview)) {
      col_names <- names(preview)
    }
  }

  if (is.null(col_types) || length(col_types) == 0) {
    if (is.data.frame(preview) && ncol(preview) > 0) {
      col_types <- vapply(preview, function(col) class(col)[1], character(1))
    } else if (!is.null(col_names)) {
      col_types <- rep("character", length(col_names))
      names(col_types) <- col_names
    }
  }

  nr <- tryCatch(as.integer(nrow(x)), error = function(e) NA_integer_)
  nc <- if (!is.null(col_names)) length(col_names) else tryCatch(as.integer(ncol(x)), error = function(e) NA_integer_)
  dims <- c(nr, nc)

  new_sideview_card(
    id = id,
    name = name,
    type = "grid",
    data = preview,
    dims = dims,
    col_types = col_types,
    is_lazy = TRUE,
    lazy_source = "arrow",
    source = x
  )
}

#' @export
sv_normalize.arrow_table <- function(x, name = NULL, id = NULL, ...) {
  normalize_arrow_object(x, name = name, id = id, default_name = "ArrowTable", ...)
}

#' @export
sv_normalize.ArrowTabular <- function(x, name = NULL, id = NULL, ...) {
  normalize_arrow_object(x, name = name, id = id, default_name = "ArrowTable", ...)
}

#' @export
sv_normalize.Table <- function(x, name = NULL, id = NULL, ...) {
  normalize_arrow_object(x, name = name, id = id, default_name = "ArrowTable", ...)
}

#' @export
sv_normalize.RecordBatch <- function(x, name = NULL, id = NULL, ...) {
  normalize_arrow_object(x, name = name, id = id, default_name = "RecordBatch", ...)
}

#' @export
sv_normalize.Dataset <- function(x, name = NULL, id = NULL, ...) {
  normalize_arrow_object(x, name = name, id = id, default_name = "Dataset", ...)
}

#' @export
sv_normalize.FileSystemDataset <- function(x, name = NULL, id = NULL, ...) {
  normalize_arrow_object(x, name = name, id = id, default_name = "Dataset", ...)
}

#' @export
sv_normalize.tbl_duckdb_connection <- function(x, name = NULL, id = NULL, ...) {
  if (!requireNamespace("duckdb", quietly = TRUE)) {
    stop("Package 'duckdb' must be installed to normalize DuckDB objects.", call. = FALSE)
  }
  if (is.null(name) || !nzchar(name)) {
    name <- "DuckDB"
  }

  is_mock <- !inherits(x, "tbl_lazy") && is.list(x)

  if (is_mock) {
    raw <- unclass(x)
    preview <- if (!is.null(raw$data)) {
      utils::head(as.data.frame(raw$data), 50)
    } else {
      data.frame()
    }

    col_names <- NULL
    col_types <- NULL
    if (!is.null(raw$schema)) {
      if (is.list(raw$schema)) {
        col_types <- vapply(raw$schema, as.character, character(1))
        col_names <- names(raw$schema)
      }
    }

    if (is.null(col_names) || length(col_names) == 0) {
      col_names <- if (is.data.frame(preview)) names(preview) else names(raw)
    }

    if (is.null(col_types) || length(col_types) == 0) {
      if (is.data.frame(preview) && ncol(preview) > 0) {
        col_types <- vapply(preview, function(col) class(col)[1], character(1))
      } else if (!is.null(col_names)) {
        col_types <- rep("character", length(col_names))
        names(col_types) <- col_names
      }
    }

    dims <- if (!is.null(raw$dims)) raw$dims else c(nrow(preview), length(col_names))

    return(new_sideview_card(
      id = id,
      name = name,
      type = "grid",
      data = preview,
      dims = dims,
      col_types = col_types,
      is_lazy = TRUE,
      lazy_source = "duckdb"
    ))
  }

  # Real tbl_lazy / tbl_duckdb_connection
  preview <- tryCatch(as.data.frame(utils::head(x, 50)), error = function(e) data.frame())
  col_names <- tryCatch(colnames(x), error = function(e) NULL)
  if (is.null(col_names) && is.data.frame(preview)) {
    col_names <- names(preview)
  }

  col_types <- if (is.data.frame(preview) && ncol(preview) > 0) {
    vapply(preview, function(col) class(col)[1], character(1))
  } else if (!is.null(col_names)) {
    structure(rep("character", length(col_names)), names = col_names)
  } else {
    character(0)
  }

  nr <- tryCatch(as.numeric(dplyr::pull(dplyr::count(x))), error = function(e) NA_real_)
  nc <- if (!is.null(col_names)) length(col_names) else ncol(preview)
  dims <- c(nr, nc)

  new_sideview_card(
    id = id,
    name = name,
    type = "grid",
    data = preview,
    dims = dims,
    col_types = col_types,
    is_lazy = TRUE,
    lazy_source = "duckdb",
    source = x
  )
}

#' @export
sv_normalize.duckdb_connection <- function(x, name = NULL, id = NULL, expr = NULL, ...) {
  if (!requireNamespace("duckdb", quietly = TRUE)) {
    stop("Package 'duckdb' must be installed to normalize DuckDB objects.", call. = FALSE)
  }

  # If mock object
  is_mock <- !inherits(x, "DBIConnection") && is.list(x)
  if (is_mock) {
    raw <- unclass(x)
    if (is.null(name) || !nzchar(name)) name <- "DuckDB"
    preview <- if (!is.null(raw$data)) utils::head(as.data.frame(raw$data), 50) else data.frame()
    col_names <- if (!is.null(raw$schema)) names(raw$schema) else names(preview)
    col_types <- NULL
    if (!is.null(raw$schema) && is.list(raw$schema)) {
      col_types <- vapply(raw$schema, as.character, character(1))
    } else if (is.data.frame(preview) && ncol(preview) > 0) {
      col_types <- vapply(preview, function(col) class(col)[1], character(1))
    }
    dims <- if (!is.null(raw$dims)) raw$dims else c(nrow(preview), ncol(preview))
    return(new_sideview_card(
      id = id,
      name = name,
      type = "grid",
      data = preview,
      dims = dims,
      col_types = col_types,
      is_lazy = TRUE,
      lazy_source = "duckdb"
    ))
  }

  # Real DBI connection
  tables <- tryCatch(DBI::dbListTables(x), error = function(e) character(0))
  tbl_name <- if (!is.null(name) && nzchar(name) && name %in% tables) {
    name
  } else if (length(tables) > 0) {
    tables[1]
  } else {
    NULL
  }

  if (!is.null(tbl_name)) {
    tbl_obj <- tryCatch(dplyr::tbl(x, tbl_name), error = function(e) NULL)
    if (!is.null(tbl_obj)) {
      display_name <- if (!is.null(name) && nzchar(name)) name else tbl_name
      card <- sv_normalize(tbl_obj, name = display_name, id = id, ...)
      card$source <- tbl_obj
      card$code_ref <- sprintf('dplyr::tbl(%s, "%s")',
                               if (is.null(expr) || !nzchar(expr)) card$name else expr,
                               tbl_name)
      return(card)
    }
  }

  # Fallback for connection with no tables
  new_sideview_card(
    id = id,
    name = if (!is.null(name) && nzchar(name)) name else "DuckDB",
    type = "grid",
    data = data.frame(),
    dims = c(0L, 0L),
    col_types = character(0),
    is_lazy = TRUE,
    lazy_source = "duckdb"
  )
}

#' @export
sv_normalize.default <- function(x, name = NULL, id = NULL, ...) {
  if (is.function(x) || is.environment(x)) {
    stop(sprintf("Cannot normalize object of class '%s' to sideview card.", paste(class(x), collapse = ", ")), call. = FALSE)
  }

  df <- tryCatch(
    as.data.frame(x, stringsAsFactors = FALSE),
    error = function(e) NULL
  )

  if (!is.null(df) && is.data.frame(df)) {
    if (is.null(name)) name <- "Data"
    return(new_sideview_card(
      id = id,
      name = name,
      type = "grid",
      data = df
    ))
  }

  stop(sprintf("Cannot normalize object of class '%s' to sideview card.", paste(class(x), collapse = ", ")), call. = FALSE)
}

#' @export
print.sideview_card <- function(x, ...) {
  type_str <- if (isTRUE(x$is_lazy)) paste0(x$type, " - lazy") else x$type
  cat(sprintf("<sideview_card [%s]>\n", type_str))
  cat(sprintf("  ID:   %s\n", x$id))
  cat(sprintf("  Name: %s\n", x$name))
  if (isTRUE(x$is_lazy)) {
    cat("  Lazy: TRUE\n")
  }
  if (!is.null(x$dims)) {
    rows_str <- if (is.na(x$dims[1])) "?" else as.character(x$dims[1])
    cols_str <- if (is.na(x$dims[2])) "?" else as.character(x$dims[2])
    cat(sprintf("  Dims: %s rows x %s cols\n", rows_str, cols_str))
  }
  invisible(x)
}
