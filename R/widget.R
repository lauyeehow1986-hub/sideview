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
#' Gathers dependencies for Panzoom and the Sideview core CSS/JS.
#'
#' @return A list of `htmltools::htmlDependency` objects.
#' @noRd
sideview_widget_dependencies <- function() {
  www_dir <- find_sideview_inst_dir("www")
  
  deps <- list()
  
  # Panzoom dependency
  if (nzchar(www_dir) && file.exists(file.path(www_dir, "panzoom.min.js"))) {
    deps[[length(deps) + 1]] <- htmltools::htmlDependency(
      name = "panzoom",
      version = "4.5.1",
      src = c(file = www_dir),
      script = "panzoom.min.js"
    )
  }
  
  # Sideview core assets dependency
  if (nzchar(www_dir) && file.exists(file.path(www_dir, "sideview.js"))) {
    deps[[length(deps) + 1]] <- htmltools::htmlDependency(
      name = "sideview-assets",
      version = "0.1.0",
      src = c(file = www_dir),
      stylesheet = "sideview.css",
      script = "sideview.js"
    )
  }
  
  # The binding (inst/htmlwidgets/sideview.js) is attached by htmlwidgets itself;
  # adding it here as well loaded it twice.

  deps
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
#' @param options Named list of canvas options (e.g. \code{snapToEdge},
#'   \code{snapThreshold}, \code{minScale}, \code{maxScale}).
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
                            options = list()) {
  dots_exprs <- as.list(substitute(list(...))[-1])
  dots_vals <- list(...)
  
  # Flatten if a single list was passed
  if (length(dots_vals) == 1 && is.list(dots_vals[[1]]) &&
      !is.data.frame(dots_vals[[1]]) && !inherits(dots_vals[[1]], "sideview_card")) {
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
      sv_normalize(val, name = nm)
    }
    
    if (!is.null(card)) {
      if (identical(card$type, "widget") && !is.null(card$widget) && is.null(card$html_content)) {
        card$html_content <- as.character(htmltools::as.tags(card$widget))
        card$widget <- NULL
      }
      if (!is.null(card$col_types) && is.character(card$col_types)) {
        card$col_types <- as.list(card$col_types)
      }
      card_list[[length(card_list) + 1]] <- card
    }
  }
  
  # Forward options using x payload
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
#' @param ... Additional arguments passed to \code{htmlwidgets::saveWidget()}.
#'
#' @return The normalized path to the saved file (invisibly).
#' @export
#' @examples
#' \dontrun{
#' save_sideview(mtcars, file = "cars_sideview.html")
#' }
save_sideview <- function(widget,
                          file,
                          selfcontained = TRUE,
                          title = "Sideview",
                          background = "white",
                          ...) {
  if (!inherits(widget, "htmlwidget")) {
    widget <- sideview_widget(widget)
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
