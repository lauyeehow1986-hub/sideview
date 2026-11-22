#' Locate Sideview Package or Development Directory
#'
#' @param subpath Subdirectory inside `inst/` or package root (e.g. `"www"`, `"htmlwidgets"`).
#' @return Absolute path to directory if found, or empty string.
#' @noRd
find_sideview_inst_dir <- function(subpath = "www") {
  candidates <- c(
    system.file(subpath, package = "sideview"),
    file.path("inst", subpath),
    file.path("..", "inst", subpath),
    file.path("..", "..", "inst", subpath),
    file.path(".", subpath)
  )
  for (cand in candidates) {
    if (nzchar(cand) && dir.exists(cand)) {
      return(normalizePath(cand, winslash = "/"))
    }
  }
  system.file(subpath, package = "sideview")
}

#' HTML Dependencies for Sideview HTMLWidget
#'
#' The widget uses the same `sideview-core` dependency as the gadget.
#'
#' @return A list of `htmltools::htmlDependency` objects.
#' @noRd
sideview_widget_dependencies <- function() {
  www_dir <- find_sideview_inst_dir("www")
  if (!nzchar(www_dir) || !file.exists(file.path(www_dir, "sideview.js"))) return(list())
  # The binding (inst/htmlwidgets/sideview.js) is attached by htmlwidgets itself.
  list(sideview_html_dependency(www_dir))
}

#' Create a Standalone Sideview HTMLWidget
#'
#' Normalizes passed table objects (`data.frame`, `tibble`, `table`, `gt`,
#' `flextable`, `htmlwidgets`) and creates an interactive 2D infinite canvas
#' `htmlwidget` suitable for rendering in R Markdown, Quarto, Shiny, or
#' exporting via `save_sideview()`.
#'
#' @param ... Arbitrary table objects (`data.frame`, `tibble`, `table`, `gt`,
#'   `flextable`, `htmlwidgets`), named or unnamed, or a single list of tables.
#' @param width Optional widget width (e.g. \code{"100\%"}).
#' @param height Optional widget height (e.g. \code{"600px"}).
#' @param elementId Optional HTML element identifier.
#' @param options Named list of canvas options (e.g. \code{shortcuts = FALSE} to start with
#'   the single-key shortcuts off, default \code{getOption("sideview.shortcuts", TRUE)}, \code{snapToEdge},
#'   \code{access = TRUE} to start with the Accessible canvas switch on (default
#'   \code{getOption("sideview.access", FALSE)}), \code{snapThreshold}, \code{minScale}, \code{maxScale}).
#' @param theme Canvas theme: `"auto"` (default; follows the reader's
#'   `prefers-color-scheme`), `"light"`, `"dark"`, an [sv_theme()] or a
#'   `bslib::bs_theme()`.
#' @param state A saved workspace to restore (see [sideview()]): a
#'   `sideview_state` or the path to a saved state file.
#' @param cdisc CDISC awareness (see [sideview()]): `"auto"` (default), `FALSE`,
#'   or a named character vector of domain codes.
#' @param code_style Style of the generated code: `"dplyr"` (default) or `"pharmaverse"`
#'   (see [sideview()]). A workspace that records a style (`options = list(state = )`,
#'   `state =`) wins over it.
#' @param max_rows Most rows of each data-frame table to embed in the widget
#'   (default 5000). A longer table is cut to its first `max_rows` rows, its
#'   card says "First N of M rows", and one message names the tables cut. The
#'   widget has no R session behind it, so every row would travel in the HTML.
#'   Use `Inf` to embed everything. Lazy (arrow / duckdb) tables already carry
#'   only a preview and are not affected.
#' @param view Starting view: `"canvas"` (default) or `"list"`, a text-first list
#'   of the tables. Default `getOption("sideview.view", "canvas")`. A saved
#'   workspace (`options = list(state = )`) that records a view wins over this
#'   argument; a state without one leaves it as it is.
#'
#' @return An S3 object of class \code{c("sideview", "htmlwidget")}.
#' @export
#' @examples
#' if (interactive()) {
#'   sideview_widget(mtcars, iris)
#' }
sideview_widget <- function(...,
                            width = NULL,
                            height = NULL,
                            elementId = NULL,
                            options = list(),
                            theme = "auto",
                            state = NULL,
                            cdisc = "auto",
                            code_style = c("dplyr", "pharmaverse"),
                            max_rows = 5000,
                            view = getOption("sideview.view", "canvas")) {
  view <- sv_check_view(view)
  max_rows <- sv_check_max_rows(max_rows)
  cdisc <- sv_cdisc_check_arg(cdisc)
  code_style <- match.arg(code_style)
  state <- sv_as_state(state)
  dots_exprs <- as.list(substitute(list(...))[-1])
  dots_vals <- list(...)
  
  # Flatten if a single list was passed
  if (length(dots_vals) == 1 && sv_is_table_list(dots_vals[[1]])) {
    dots_vals <- dots_vals[[1]]
    if (!is.null(names(dots_vals))) {
      dots_exprs <- as.list(names(dots_vals))
    } else {
      dots_exprs <- vector("list", length(dots_vals))
    }
  }
  
  card_list <- list()
  for (i in seq_along(dots_vals)) {
    val <- dots_vals[[i]]
    if (is.null(val)) next
    
    nm <- names(dots_vals)[i]
    if (is.null(nm) || !nzchar(nm)) {
      if (i <= length(dots_exprs) && !is.null(dots_exprs[[i]])) {
        dep <- deparse(dots_exprs[[i]])[1]
        dep <- sub("^.*\\$", "", dep)
        dep <- make.names(dep)
        nm <- dep
      } else {
        nm <- paste0("Table_", i)
      }
    }
    
    card <- if (inherits(val, "sideview_card")) {
      val
    } else {
      sv_normalize_arg(val, nm, sv_expr_string(if (i <= length(dots_exprs)) dots_exprs[[i]]))
    }
    
    if (!is.null(card)) {
      if (identical(card$type, "widget") && !is.null(card$widget) && is.null(card$html_content)) {
        card$html_content <- as.character(htmltools::as.tags(card$widget))
        card$widget <- NULL
      }
      card_list[[length(card_list) + 1]] <- card
    }
  }
  card_list <- sv_cdisc_finalize(card_list, cdisc)
  card_list <- lapply(card_list, function(card) {
    card <- sv_card_payload(card)
    card <- sv_cap_card_rows(card, max_rows)
    # the double columns the browser cannot read back exactly, on the rows the widget sends
    # (always a JSON array); only the widget checks combine_supp in the browser
    if (is.data.frame(card$data)) card$col_inexact <- as.list(sv_inexact_cols(card$data))
    card
  })
  sv_announce_row_cap(card_list, max_rows)
  
  # Forward options using x payload
  theme <- sv_resolve_theme(theme)
  if (is.null(options$theme)) options$theme <- theme$mode
  if (is.null(options$view)) {
    options$view <- view
  } else {
    options$view <- sv_check_view(options$view)
  }
  options$access <- if (is.null(options$access)) {
    sv_check_access(getOption("sideview.access", FALSE))
  } else {
    sv_check_access(options$access)
  }
  options$codeStyle <- code_style
  if (is.null(options$shortcuts)) options$shortcuts <- getOption("sideview.shortcuts", TRUE)
  if (length(theme$vars)) {
    options$themeVars <- stats::setNames(theme$vars, paste0("--sv-", names(theme$vars)))
  }
  # As JSON text, so the browser gets exactly what a state file holds.
  if (!is.null(state)) options$state <- sv_state_json(state)
  x <- list(
    cards = card_list,
    options = options
  )
  
  sizingPolicy <- htmlwidgets::sizingPolicy(
    defaultWidth = "100%",
    defaultHeight = "600px",
    viewer.defaultWidth = "100%",
    viewer.defaultHeight = "100%",
    viewer.fill = TRUE,
    browser.fill = TRUE,
    knitr.figure = FALSE
  )
  
  htmlwidgets::createWidget(
    name = "sideview",
    x = x,
    width = width,
    height = height,
    package = "sideview",
    elementId = elementId,
    sizingPolicy = sizingPolicy,
    dependencies = sideview_widget_dependencies()
  )
}

#' Validate `max_rows`: one number >= 1, or `Inf`
#' @noRd
sv_check_max_rows <- function(max_rows) {
  if (!is.numeric(max_rows) || length(max_rows) != 1L || is.na(max_rows) || max_rows < 1) {
    stop("`max_rows` must be a single number of at least 1 (or Inf).", call. = FALSE)
  }
  max_rows
}

#' Cut a data-frame card to its first `max_rows` rows
#'
#' Sets `truncated` (the browser then says "First N of M rows") and keeps
#' `totalRows`. Lazy cards, already a preview, and non-data-frame cards are left alone.
#' @noRd
sv_cap_card_rows <- function(card, max_rows) {
  if (!is.data.frame(card$data) || isTRUE(card$is_lazy) || !is.finite(max_rows)) return(card)
  if (nrow(card$data) <= max_rows) return(card)
  card$data <- utils::head(card$data, max_rows)
  card$truncated <- TRUE
  card
}

#' One message naming the tables a widget cut (not while knitting)
#' @noRd
sv_announce_row_cap <- function(cards, max_rows) {
  cut <- Filter(function(c) isTRUE(c$truncated), cards)
  if (!length(cut) || isTRUE(getOption("knitr.in.progress"))) return(invisible(NULL))
  desc <- vapply(cut, function(c) {
    sprintf("%s (%s rows)", c$name %||% "table", format(c$totalRows, big.mark = ",", scientific = FALSE))
  }, character(1))
  message("sideview: showing the first ", format(max_rows, big.mark = ","), " rows of ",
          paste(desc, collapse = ", "),
          ". Raise `max_rows` (or use Inf) to embed more.")
  invisible(NULL)
}

#' Save Sideview Widget to a Standalone HTML File
#'
#' Exports a `sideview` htmlwidget or table objects to a self-contained HTML file
#' with all styles, fonts, and JavaScript embedded.
#'
#' @param widget A `sideview` htmlwidget object, or tabular data objects that can
#'   be converted to one via \code{\link{sideview_widget}}.
#' @param file Path to the output HTML file (e.g. \code{"report.html"}).
#' @param selfcontained Logical; whether to produce a standalone HTML file with
#'   all CSS and JavaScript dependencies inlined. Defaults to \code{TRUE}.
#' @param title HTML title for the output page. Default \code{"Sideview"}.
#' @param background Background color for the document body. Default \code{"white"}.
#' @param max_rows Row cap used when `widget` is table data rather than a
#'   widget (see [sideview_widget()]; default 5000). A widget you built yourself
#'   keeps the cap it was built with.
#' @param cdisc CDISC awareness when `widget` is table data (see
#'   [sideview_widget()]). A widget you built yourself keeps its own setting.
#' @param code_style `NULL` (default) keeps the widget's own style (`"dplyr"` for table data); `"dplyr"`
#'   or `"pharmaverse"` sets it (see [sideview_widget()]). A workspace the widget carries
#'   that records a style still wins in the browser.
#' @param view Starting view when `widget` is table data (see [sideview_widget()]).
#'   A widget you built yourself keeps its own.
#' @param ... Additional arguments passed to \code{htmlwidgets::saveWidget()}.
#'
#' @return The normalized path to the saved file (invisibly).
#' @export
#' @examples
#' \donttest{
#' out <- tempfile(fileext = ".html")
#' save_sideview(mtcars, file = out)
#' unlink(out)
#' }
save_sideview <- function(widget,
                          file,
                          selfcontained = TRUE,
                          title = "Sideview",
                          background = "white",
                          max_rows = 5000,
                          cdisc = "auto",
                          view = getOption("sideview.view", "canvas"),
                          code_style = NULL,
                          ...) {
  view <- sv_check_view(view)
  if (!is.null(code_style)) code_style <- match.arg(code_style, c("dplyr", "pharmaverse"))
  if (!inherits(widget, "htmlwidget")) {
    widget <- sideview_widget(widget, max_rows = max_rows, cdisc = cdisc, view = view,
                              code_style = code_style %||% "dplyr")
  } else if (!is.null(code_style)) {
    widget$x$options$codeStyle <- code_style
  }
  
  if (!grepl("\\.html?$", file, ignore.case = TRUE)) {
    file <- paste0(file, ".html")
  }
  
  # Ensure destination directory exists
  out_dir <- dirname(file)
  if (nzchar(out_dir) && !dir.exists(out_dir)) {
    dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  }
  
  htmlwidgets::saveWidget(
    widget = widget,
    file = file,
    selfcontained = selfcontained,
    title = title,
    background = background,
    ...
  )
  
  invisible(normalizePath(file, winslash = "/", mustWork = FALSE))
}

#' Shiny Output Container for Sideview Widget
#'
#' @param outputId Output variable to read from.
#' @param width,height Must be a valid CSS unit (e.g. \code{'100\%'}, \code{'600px'},
#'   \code{'auto'}) or a number, which will be coerced to a string and have \code{'px'} appended.
#'
#' @return A `shiny.tag` object representing the widget container.
#' @export
sideviewOutput <- function(outputId, width = "100%", height = "600px") {
  htmlwidgets::shinyWidgetOutput(outputId, "sideview", width, height, package = "sideview")
}

#' Shiny Render Function for Sideview Widget
#'
#' @param expr An expression that generates a \code{\link{sideview_widget}}.
#' @param env The environment in which to evaluate \code{expr}.
#' @param quoted Is \code{expr} a quoted expression (with \code{quote()})? Default \code{FALSE}.
#'
#' @return An S3 object of class \code{c("shiny.render.function", "function")}.
#' @export
renderSideview <- function(expr, env = parent.frame(), quoted = FALSE) {
  if (!quoted) {
    expr <- substitute(expr)
  }
  htmlwidgets::shinyRenderWidget(expr, sideviewOutput, env, quoted = TRUE)
}
