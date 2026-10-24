`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

#' Create a New Sideview Canvas State Object
#'
#' Constructs a structured `sideview_state` object containing canvas transform,
#' card configurations, table join connections, and pipeline script state.
#'
#' The canvas writes this shape when you click **Save** in the toolbar, and
#' `sideview(..., state = )` / `sideview_widget(..., state = )` restore it.
#' Cards are matched to tables by `name`.
#'
#' @param version Character string representing state schema version (default `"0.3.0"`).
#' @param canvas Named list containing canvas settings: `zoom` (numeric), `pan_x` (numeric), `pan_y` (numeric).
#' @param cards List of card state objects (each specifying `id`, `name`, `x`, `y`,
#'   `width`, `height`, `minimized`, `sorts` and `filters`; a sort is
#'   `list(col, dir)` with `dir` `"asc"` or `"desc"`, a filter is `list(col, op, val)`).
#' @param connections List of join connection objects (each specifying `from_table`, `from_col`, `to_table`, `to_col`, `join_type`).
#' @param pipeline Named list containing `code` (character), `active_tab`
#'   (character) and, from version 0.3.0, the pipeline `steps` and `pipe`
#'   (`"%>%"` or `"|>"`). Without `steps`, `code` is restored as one custom step.
#'
#' @return An object of class `c("sideview_state", "list")`.
#' @export
#' @examples
#' st <- new_sideview_state()
#' print(st)
new_sideview_state <- function(version = "0.3.0",
                               canvas = list(zoom = 1, pan_x = 0, pan_y = 0),
                               cards = list(),
                               connections = list(),
                               pipeline = list(code = "", active_tab = "pipeline")) {
  state <- list(
    version = as.character(version),
    canvas = canvas,
    cards = cards,
    connections = connections,
    pipeline = pipeline
  )
  class(state) <- c("sideview_state", "list")
  state
}

#' Save Canvas State to File
#'
#' Serializes the active Sideview canvas state (cards, positions, filters, connections,
#' and pipeline code) to either `.json` or `.rds` format.
#'
#' @param state A `sideview_state` object or structured state list.
#' @param file Path to the destination file.
#' @param format Optional format specification (`"json"` or `"rds"`). If `NULL` (default),
#'   the format is inferred from the file extension (`.json` or `.rds`).
#'
#' @return Invisibly returns the path of the saved file.
#' @export
#' @examples
#' st <- new_sideview_state()
#' tf <- tempfile(fileext = ".json")
#' sv_save_state(st, tf)
#' unlink(tf)
sv_save_state <- function(state, file, format = NULL) {
  if (is.null(format)) {
    ext <- tolower(tools::file_ext(file))
    if (ext %in% c("json", "rds")) {
      format <- ext
    } else {
      stop("Cannot infer format from file extension '", ext, "'. Expected 'json' or 'rds'.", call. = FALSE)
    }
  } else {
    format <- tolower(format)
    if (!format %in% c("json", "rds")) {
      stop("Invalid format '", format, "'. Supported formats are 'json' and 'rds'.", call. = FALSE)
    }
  }

  dir_path <- dirname(file)
  if (!dir.exists(dir_path)) {
    dir.create(dir_path, recursive = TRUE, showWarnings = FALSE)
  }

  if (format == "json") {
    writeLines(sv_state_json(state, pretty = TRUE), file, useBytes = TRUE)
  } else {
    saveRDS(state, file = file)
  }

  invisible(file)
}

#' Load Canvas State from File
#'
#' Deserializes a previously saved Sideview canvas workspace from a `.json` or `.rds`
#' file and returns a `sideview_state` object. Optionally launches an interactive session.
#'
#' @param file Path to the saved state file (`.json` or `.rds`).
#' @param tables Optional named list of data frames or tables to associate with loaded cards.
#'   If `NULL`, the tables named by the saved cards are looked up in the calling
#'   environment (then every table there, as [sv_find_tables()] finds them).
#' @param launch Logical; if `TRUE` and the session is interactive, launches
#'   `sideview(tables, state = <loaded state>, ...)` so cards, zoom, joins and
#'   the pipeline come back. If non-interactive, returns the loaded state object.
#' @param format Optional format specification (`"json"` or `"rds"`). If `NULL` (default),
#'   the format is inferred from the file extension (`.json` or `.rds`).
#' @param ... Further arguments for [sideview()] when `launch = TRUE` (e.g. `viewer`).
#'
#' @return A `sideview_state` object of class `c("sideview_state", "list")`, or the gadget
#'   result if `launch = TRUE` in an interactive session.
#' @export
#' @examples
#' st <- new_sideview_state()
#' tf <- tempfile(fileext = ".json")
#' sv_save_state(st, tf)
#' loaded <- sv_load_state(tf)
#' print(loaded)
#' unlink(tf)
sv_load_state <- function(file, tables = NULL, launch = FALSE, format = NULL, ...) {
  if (!file.exists(file)) {
    stop("State file does not exist: ", file, call. = FALSE)
  }

  if (is.null(format)) {
    ext <- tolower(tools::file_ext(file))
    if (ext %in% c("json", "rds")) {
      format <- ext
    } else {
      stop("Invalid or unsupported file format: '", ext, "'. Expected 'json' or 'rds'.", call. = FALSE)
    }
  } else {
    format <- tolower(format)
    if (!format %in% c("json", "rds")) {
      stop("Invalid format '", format, "'. Supported formats are 'json' and 'rds'.", call. = FALSE)
    }
  }

  if (format == "json") {
    # simplifyVector = FALSE keeps one-element arrays (e.g. a step's conds) as
    # lists, so sv_state_json() writes them back as arrays.
    state <- jsonlite::fromJSON(file, simplifyVector = FALSE)
  } else {
    state <- readRDS(file)
  }

  if (!is.list(state)) {
    stop("Invalid state file: root object must be a list.", call. = FALSE)
  }

  class(state) <- c("sideview_state", "list")

  if (isTRUE(launch) && sv_interactive()) {
    if (is.null(tables)) tables <- sv_state_tables(state, parent.frame())
    if (length(tables) == 0) {
      stop("None of the saved tables (", paste(sv_state_card_names(state), collapse = ", "),
           ") were found. Pass them with `tables = list(...)`.", call. = FALSE)
    }
    return(sideview(tables, state = state, ...))
  }

  state
}

# interactive(), mockable in tests.
sv_interactive <- function() interactive()

sv_state_card_names <- function(state) {
  nms <- vapply(state$cards %||% list(), function(c) as.character(c$name %||% "")[1], character(1))
  unique(nms[nzchar(nms)])
}

# Tables for a saved state: the ones its cards name, found in `env` (or its
# parents); failing that, every table in `env`.
sv_state_tables <- function(state, env = parent.frame()) {
  tables <- list()
  for (nm in sv_state_card_names(state)) {
    val <- tryCatch(get(nm, envir = env, inherits = TRUE), error = function(e) NULL)
    if (is.data.frame(val) || inherits(val, c("tbl_df", "gt_tbl", "flextable", "table", "matrix", "sideview_card"))) {
      tables[[nm]] <- val
    }
  }
  if (length(tables) == 0) tables <- sv_find_tables(env)
  tables
}

#' Serialize a state to JSON text
#'
#' The one serializer for state files and for the state handed to the browser.
#' `null`/`NA` stay `null` and numbers keep full precision (card positions).
#' @noRd
sv_state_json <- function(state, pretty = FALSE) {
  as.character(jsonlite::toJSON(unclass(state), auto_unbox = TRUE, null = "null", na = "null",
                                digits = NA, pretty = pretty))
}

#' Parse JSON text (from the canvas or a file) into a sideview_state
#' @noRd
sv_state_from_json <- function(txt) {
  if (!is.character(txt) || length(txt) != 1L || !nzchar(txt)) {
    stop("Invalid state: expected JSON text.", call. = FALSE)
  }
  state <- jsonlite::fromJSON(txt, simplifyVector = FALSE)
  if (!is.list(state) || is.null(names(state))) {
    stop("Invalid state: root object must be a list.", call. = FALSE)
  }
  class(state) <- c("sideview_state", "list")
  state
}

#' Coerce the `state` argument of sideview()/sideview_widget()
#'
#' Accepts `NULL`, a `sideview_state` (or plain list) or a path to a saved file.
#' @noRd
sv_as_state <- function(state) {
  if (is.null(state)) return(NULL)
  if (is.character(state) && length(state) == 1L) return(sv_load_state(state))
  if (!is.list(state)) {
    stop("`state` must be a sideview_state, a list or the path to a saved state file.", call. = FALSE)
  }
  if (!inherits(state, "sideview_state")) class(state) <- c("sideview_state", "list")
  state
}

# Does this session have RStudio's file dialogs?
sv_has_file_dialog <- function() {
  isTRUE(tryCatch(rstudioapi::isAvailable() && rstudioapi::hasFun("selectFile"),
                  error = function(e) FALSE))
}

#' Ask where to save (or which file to open) a workspace
#'
#' RStudio file dialog when available. Without it, saving writes a new
#' `sideview-workspace*.json` in the working directory; opening needs the
#' browser file picker instead (the canvas falls back to it).
#' @return A path, or `NULL` when the dialog was cancelled.
#' @noRd
sv_choose_state_path <- function(existing = FALSE) {
  if (sv_has_file_dialog()) {
    path <- rstudioapi::selectFile(
      caption = if (existing) "Open sideview workspace" else "Save sideview workspace",
      label = if (existing) "Open" else "Save",
      path = if (existing) getwd() else file.path(getwd(), "sideview-workspace.json"),
      filter = "Sideview workspace (*.json *.rds)", existing = existing
    )
    if (is.null(path) || !nzchar(path)) return(NULL)
    if (!existing && !grepl("[.](json|rds)$", path, ignore.case = TRUE)) path <- paste0(path, ".json")
    return(path)
  }
  if (existing) stop("No file dialog in this session.", call. = FALSE)
  path <- file.path(getwd(), "sideview-workspace.json")
  i <- 1L
  while (file.exists(path)) {
    i <- i + 1L
    path <- file.path(getwd(), sprintf("sideview-workspace_%d.json", i))
  }
  path
}

#' Print Method for Sideview State Objects
#'
#' Displays a concise summary of the canvas state including version, card count,
#' and active connections.
#'
#' @param x A `sideview_state` object.
#' @param ... Unused additional arguments.
#'
#' @return Invisibly returns `x`.
#' @export
print.sideview_state <- function(x, ...) {
  version_str <- x$version %||% "0.3.0"
  n_cards <- length(x$cards)
  n_conn <- length(x$connections)

  cat(sprintf("<sideview_state v%s>\n", sub("^v", "", version_str)))
  cat(sprintf("  Cards:       %d\n", n_cards))
  cat(sprintf("  Connections: %d\n", n_conn))

  if (!is.null(x$canvas) && is.list(x$canvas)) {
    cat(sprintf("  Canvas:      zoom = %s, pan = (%s, %s)\n",
                x$canvas$zoom %||% 1,
                x$canvas$pan_x %||% 0,
                x$canvas$pan_y %||% 0))
  }

  if (!is.null(x$pipeline) && !is.null(x$pipeline$active_tab)) {
    cat(sprintf("  Active Tab:  %s\n", x$pipeline$active_tab))
  }

  invisible(x)
}
