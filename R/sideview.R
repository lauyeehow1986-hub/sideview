#' Find Tabular Data Objects in an Environment
#'
#' Scans an environment for tabular objects, including `data.frame`, `tibble`,
#' `matrix`, `table`, `gt`, `flextable`, and `sideview_card` objects.
#'
#' @param env Environment to scan (defaults to `parent.frame()`).
#'
#' @return A named list of tabular objects found in the environment.
#' @export
sv_find_tables <- function(env = parent.frame()) {
  if (is.null(env) || !is.environment(env)) {
    return(list())
  }
  
  obj_names <- ls(envir = env, all.names = FALSE)
  tables <- list()
  
  for (nm in obj_names) {
    val <- tryCatch(get(nm, envir = env), error = function(e) NULL)
    if (is.null(val)) next
    
    is_tabular <- is.data.frame(val) ||
      inherits(val, c("tbl_df", "gt_tbl", "flextable", "table", "matrix", "sideview_card"))
    
    if (is_tabular) {
      tables[[nm]] <- val
    }
  }
  
  tables
}

#' Multi-Table 2D Infinite Canvas Interactive Gadget
#'
#' Launches an interactive Shiny gadget containing an infinite 2D canvas with
#' mouse-wheel zoom, pan, draggable table cards, interactive column mapping,
#' discrepancy recoding, and LLM-assisted tidyverse code generation.
#'
#' @param ... Arbitrary table objects (`data.frame`, `tibble`, `matrix`,
#'   `table`, `gt`, `flextable`, `htmlwidgets`), named or unnamed.
#' @param title Title for the gadget viewer.
#' @param viewer Shiny viewer gadget display mode (e.g. `shiny::paneViewer()`,
#'   `shiny::dialogViewer()`, `shiny::browserViewer()`), or a character shorthand
#'   (`"browser"`, `"dialog"`, or `"pane"`). Default is `shiny::dialogViewer()`
#'   (width 1400, height 900) when RStudio is available, otherwise `shiny::paneViewer()`.
#' @param theme Canvas theme: `"auto"` (default; follows the RStudio editor
#'   theme), `"light"`, `"dark"`, an [sv_theme()] or a `bslib::bs_theme()`.
#' @param state A saved workspace to restore: a `sideview_state` (see
#'   [new_sideview_state()]) or the path to a file written by the toolbar's
#'   **Save** button or [sv_save_state()]. Card positions and sizes, zoom and
#'   pan, sorts, filters, joins and the pipeline come back; cards are matched
#'   to tables by name.
#' @param env Environment where **Run in R** evaluates the generated code and
#'   stores its result (as `sv_result` unless you name it). Defaults to the
#'   environment `sideview()` is called from, which is your workspace when you
#'   call it from the console.
#' @param run Logical; if `TRUE`, launches the interactive gadget via
#'   `shiny::runGadget()`. If `FALSE`, returns the `shiny.appobj` definition
#'   without launching (useful for testing or embedding). Defaults to `interactive()`.
#'
#' @return If `run = TRUE`, the generated code (invisibly) when you click
#'   **Done**, or `NULL` after **Cancel** or closing the window.
#'   If `run = FALSE`, returns a `shiny.appobj` with the normalized cards attached.
#'
#' @section Big tables (arrow and duckdb):
#' Arrow tables, datasets and queries and duckdb tables (`dplyr::tbl()`) go on
#' the canvas as cards that show a 50-row preview. When the duckdb, dbplyr and
#' DBI packages are installed, sorting, filtering, scrolling, the join check,
#' the column inspector and the codebook use the whole table: duckdb runs them
#' and only summaries and row windows come back into R. The table is never
#' collected. Without duckdb, or when the link to a table is lost, the card
#' says "First 50 of N rows" and the checks use the preview.
#'
#' Generated code stays lazy and ends in one `collect()`. Known differences
#' from an in-memory card:
#' \itemize{
#'   \item "Contains" on a number matches its text. The grid filter drops a
#'     trailing `.0`, but in generated code duckdb writes a double as
#'     `"130.0"` where R writes `"130"`, and float noise or scientific
#'     notation can differ. The generated filter is a literal match,
#'     `stringr::str_detect(col, "<escaped literal>")`.
#'   \item POSIXct values at exactly midnight, and `-0`, can print differently.
#'   \item Join keys of different types compare as text, and double keys
#'     compare exactly.
#'   \item Arrow time-zone offsets are computed for 1900 to 2100; local times
#'     outside that range may be off. duckdb `TIMESTAMPTZ` columns show in UTC.
#'   \item Joining arrow with duckdb copies the arrow side into a duckdb
#'     temporary table (`arrow::to_duckdb()` then `dplyr::compute()`), which
#'     costs memory; a data frame joined into duckdb is copied as
#'     `sideview_<table>`.
#'   \item duckdb 1.4.3 can crash when it scans an arrow factor column that
#'     contains `NA`. sideview decodes such columns itself, but generated code
#'     that calls `arrow::to_duckdb()` on one may hit it: convert the factor to
#'     character first.
#' }
#' If **Run in R** fails on a lazy pipeline, the message suggests moving
#' `collect()` above the step that needs R.
#'
#' @section Keyboard and navigation:
#' Single-key shortcuts work when the canvas has the keyboard and you are not
#' typing: `F` fit all cards, `0` reset zoom, `+`/`-` zoom, `M` show or hide
#' the minimap, `D` the drawer, `T` light/dark, `/` the AI prompt and `?` the
#' full list. `Ctrl+K` finds a card or column, `Ctrl+Z`/`Ctrl+Y` undo and
#' redo a pipeline step, and `Esc` cancels a connection or closes a popover.
#' Double-click a card title, a minimap rectangle or a search result to zoom
#' to that card.
#'
#' @section Options:
#' \describe{
#'   \item{`sideview.session_grace`}{Seconds the gadget waits after its last
#'     browser session closes before stopping (default `5`), so reloading the
#'     page does not end the app.}
#'   \item{`sideview.llm_backend`}{`"ollama"` (default, or the
#'     `SIDEVIEW_LLM_BACKEND` variable) or `"openai"` for any
#'     OpenAI-compatible server.}
#'   \item{`sideview.llm_model`}{Model name. Defaults to `SIDEVIEW_OLLAMA_MODEL`
#'     or `"llama3.2"` for Ollama, and `SIDEVIEW_OPENAI_MODEL` or
#'     `"gpt-4o-mini"` otherwise. [sv_llm_models()] lists what is available.}
#'   \item{`sideview.llm_endpoint`}{Base URL. Defaults to `OLLAMA_HOST` or
#'     `http://localhost:11434`, and `OPENAI_BASE_URL` or
#'     `https://api.openai.com/v1`.}
#'   \item{`sideview.llm_api_key`}{API key for OpenAI-compatible servers
#'     (default: the `OPENAI_API_KEY` variable).}
#'   \item{`sideview.llm_think`}{`TRUE` lets Ollama reasoning models "think"
#'     before answering. Default `FALSE`, so they answer promptly.}
#' }
#' Only schema summaries (column names, types and simple profiles) are sent to
#' the model, never raw rows.
#' @export
#' @examples
#' if (interactive()) {
#'   sideview(mtcars, iris)
#' }
sideview <- function(...,
                     title = "Sideview Canvas",
                     viewer = if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
                       shiny::dialogViewer("Sideview Canvas", width = 1400, height = 900)
                     } else {
                       shiny::paneViewer(minHeight = 500)
                     },
                     theme = "auto",
                     state = NULL,
                     env = parent.frame(),
                     run = interactive()) {
  force(env) # parent.frame() is lazy: resolve it before sideview() returns
  state <- sv_as_state(state)
  # Normalize character shorthand for viewer ("browser", "dialog", "pane")
  if (is.character(viewer) && length(viewer) == 1L) {
    v_type <- match.arg(tolower(viewer), c("browser", "dialog", "pane"))
    viewer <- switch(
      v_type,
      "browser" = shiny::browserViewer(),
      "dialog"  = shiny::dialogViewer(title, width = 1400, height = 900),
      "pane"    = shiny::paneViewer(minHeight = 500)
    )
  }

  # Capture expressions and evaluate items
  dots_exprs <- as.list(substitute(list(...))[-1])
  dots_vals <- list(...)
  
  # Flatten if a single list was passed
  if (length(dots_vals) == 1 && sv_is_table_list(dots_vals[[1]])) {
    dots_vals <- dots_vals[[1]]
    dots_exprs <- as.list(names(dots_vals))
  }
  
  card_list <- list()
  for (i in seq_along(dots_vals)) {
    val <- dots_vals[[i]]
    if (is.null(val)) next
    
    # Determine table name
    nm <- names(dots_vals)[i]
    if (is.null(nm) || !nzchar(nm)) {
      if (i <= length(dots_exprs)) {
        dep <- deparse(dots_exprs[[i]])[1]
        # Clean expression to a simple identifier if possible
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
      tryCatch(sv_normalize_arg(val, nm, sv_expr_string(if (i <= length(dots_exprs)) dots_exprs[[i]])),
               error = function(e) NULL)
    }
    
    if (!is.null(card)) {
      card_list[[length(card_list) + 1]] <- card
    }
  }
  
  # Build Shiny application object
  ui <- sideview_ui(card_list, title = title, gadget = TRUE,
                    theme = sv_resolve_theme(theme, rstudio = TRUE), state = state)
  server <- sideview_server(card_list, gadget = TRUE, run_env = env)
  app <- shiny::shinyApp(ui = ui, server = server)
  
  # Attach cards metadata
  attr(app, "cards") <- card_list
  app$cards <- card_list
  
  if (isTRUE(run)) {
    # Cancel and window close are handled by the server (they return NULL
    # quietly instead of raising Shiny's "User cancel" error).
    shiny::runGadget(app, viewer = viewer, stopOnCancel = FALSE)
  } else {
    app
  }
}

#' RStudio Addin for Sideview
#'
#' Automatically discovers tabular datasets in the user's active environment
#' and launches the Sideview interactive multi-table canvas gadget.
#'
#' @param env Environment to search for tables, and where **Run in R** stores
#'   its result (defaults to `.GlobalEnv`, where RStudio addins run).
#' @param viewer Shiny viewer gadget display mode, or character shorthand
#'   (`"browser"`, `"dialog"`, or `"pane"`). Default is `shiny::dialogViewer()`
#'   (width 1400, height 900) when RStudio is available, otherwise `shiny::paneViewer()`.
#' @param run Logical indicating whether to execute the gadget. Default `interactive()`.
#'
#' @return Result of `sideview(...)`, invisibly when the gadget was run.
#' @export
sideview_addin <- function(env = .GlobalEnv,
                           viewer = if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
                             shiny::dialogViewer("Sideview Canvas", width = 1400, height = 900)
                           } else {
                             shiny::paneViewer(minHeight = 500)
                           },
                           run = interactive()) {
  # Normalize character shorthand for viewer ("browser", "dialog", "pane")
  if (is.character(viewer) && length(viewer) == 1L) {
    v_type <- match.arg(tolower(viewer), c("browser", "dialog", "pane"))
    viewer <- switch(
      v_type,
      "browser" = shiny::browserViewer(),
      "dialog"  = shiny::dialogViewer("Sideview Canvas", width = 1400, height = 900),
      "pane"    = shiny::paneViewer(minHeight = 500)
    )
  }

  tables <- sv_find_tables(env)
  
  if (length(tables) == 0) {
    # If no tables found in environment, provide sample datasets
    message("Sideview Addin: No tabular objects found in environment; loading sample data (mtcars, iris).")
    tables <- list(
      mtcars = datasets::mtcars,
      iris = datasets::iris
    )
  }
  
  res <- sideview(tables, title = "Sideview Canvas", viewer = viewer, env = env, run = run)
  # RStudio calls the addin at top level: don't print NULL (Cancel) or the code
  # it already inserted. Without `run` the Shiny app object is returned visibly.
  if (isTRUE(run)) invisible(res) else res
}
