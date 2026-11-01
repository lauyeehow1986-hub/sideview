# Shiny module: sideviewUI() + sideviewServer(), and a proxy to drive a canvas from R.

#' Sideview canvas as a Shiny module
#'
#' `sideviewUI()` and `sideviewServer()` put an R-backed sideview canvas into your
#' own Shiny app (several per page). Row sorting and filtering, lazy arrow/duckdb
#' cards, the join check and the column inspector all run in R, as in [sideview()].
#' Tables are added, replaced and removed from the server with the verbs
#' [sv_add_card()], [sv_replace_card()] and [sv_remove_card()]; the user's work is
#' read back with the reactives of the returned proxy.
#'
#' Code execution is off in a module (Insert Script, Run & Exit, Run in R and Run
#' Console are not rendered, and their inputs are ignored by the server). The
#' composed `$code()` is built in the browser: treat it as untrusted text to show,
#' save or review, never `eval()` it unattended.
#'
#' @param id Module id.
#' @param height CSS height of the canvas, e.g. `"600px"`.
#' @param title Text shown in the toolbar; `NULL` (the default) shows none.
#' @param theme `"auto"`, `"light"`, `"dark"`, an [sv_theme()] or a `bslib::bs_theme()`.
#' @param cards Tables for the canvas: a (named) list as [sideview()] takes, or a
#'   **reactive** returning one. A reactive is compared with the canvas by name each
#'   time it fires: new names are added, names that are gone are removed, and names
#'   still there are replaced unless the table is `identical()` to the one on the canvas.
#' @param state A saved workspace applied once after the first cards arrive: a state
#'   object, or its JSON text (a string whose first non-blank character is an opening curly brace).
#' @param llm_fn Function used for the AI bar and the copilot (as for [sideview()]).
#'   With none, the server tells the canvas to hide the AI bar and the Copilot tab.
#'   `sideviewUI()` always renders them, so they show for a moment before the first
#'   message arrives.
#' @param cdisc CDISC tagging, as for [sideview()]: `"auto"`, `FALSE`, or a named
#'   character vector of domain codes. Tags are kept current as cards come and go.
#'
#' @return `sideviewUI()` returns a `shiny.tag.list`. `sideviewServer()` returns a
#'   `sideview_proxy`: a list with the reactives `code()` (the composed code, `""`
#'   for none), `pipeline()` (the typed steps as a list), `state()` (a state object,
#'   or `NULL` before the first change) and `cards()` (the card names), plus `id`,
#'   `ns` and `session`. The values update after the user's changes settle (300 ms).
#' @examples
#' if (interactive()) {
#'   library(shiny)
#'   ui <- fluidPage(sideviewUI("cv"), verbatimTextOutput("code"))
#'   server <- function(input, output, session) {
#'     px <- sideviewServer("cv", cards = list(cars = mtcars, flowers = iris))
#'     output$code <- renderText(px$code())
#'   }
#'   shinyApp(ui, server)
#' }
#' @section One server per id:
#' Calling `sideviewServer()` twice with the same `id` in one session replaces the
#' first canvas's entry in the proxy registry: [sideviewProxy()] then reaches the
#' second. Give each canvas its own id.
#' @seealso [sideviewProxy()], [sv_add_card()]
#' @export
sideviewUI <- function(id, height = "600px", title = NULL, theme = "auto") {
  ns <- shiny::NS(id)("")
  sv_ui_build(title = title, theme = theme, ns = ns, height = height)
}

#' @rdname sideviewUI
#' @export
sideviewServer <- function(id, cards = list(), state = NULL, llm_fn = NULL, cdisc = "auto") {
  force(cards)
  force(cdisc)
  force(state)
  force(llm_fn)
  shiny::moduleServer(id, function(input, output, session) {
    initial <- if (is.function(cards)) sv_initial_cards(cards, id) else cards
    llm <- llm_fn %||% function(...) stop("No llm_fn was given to sideviewServer().", call. = FALSE)
    initial <- sv_cdisc_finalize(sv_module_cards(initial), cdisc)
    impl <- sideview_server_impl(input, output, session, initial, llm, NULL, NULL, module = TRUE)
    ctl <- impl$ctl
    ctl$forget <- impl$forget
    ctl$cdisc <- cdisc

    ns <- session$ns("")
    proxy <- structure(
      list(
        id = id, ns = ns, session = session, ctl = ctl,
        code = ctl$code_rv, pipeline = ctl$pipeline_rv,
        state = ctl$state_rv, cards = ctl$cards_rv
      ),
      class = "sideview_proxy"
    )
    sv_register_proxy(session, ns, proxy)
    if (is.null(llm_fn)) ctl$emit("sideview_llm", list(enabled = FALSE))

    if (!is.null(state)) {
      ctl$emit("sideview_state_set", list(state = sv_state_json(sv_module_state(state))))
    }
    if (is.function(cards)) {
      shiny::observe({
        raw <- cards()
        failed <- character()
        new_cards <- sv_module_cards(raw, on_drop = function(nm) failed <<- c(failed, nm))
        shiny::isolate({
          # an element that no longer normalises keeps its old card, with one warning
          kept <- intersect(failed, proxy$ctl$store$names())
          fresh <- setdiff(kept, ctl$warned_cards)
          if (length(fresh)) {
            ctl$warned_cards <- c(ctl$warned_cards, fresh)
            warning(sprintf("sideviewServer(\"%s\"): could not read card \"%s\" from `cards`; keeping the card it had",
                            id, paste(fresh, collapse = "\", \"")), call. = FALSE)
          }
          sv_sync_cards(proxy, new_cards, keep = kept)
        })
      })
    }
    proxy
  })
}

#' Reach the proxy of a canvas from elsewhere in the session
#'
#' Returns the same proxy `sideviewServer(id)` returned, so a canvas started in one
#' module can be driven from another. Inside a nested module, `id` is relative to
#' the calling module, as for `moduleServer()`.
#'
#' @param id The id given to [sideviewServer()].
#' @param session The Shiny session (default: the current one).
#' @return A `sideview_proxy`.
#' @examples
#' if (interactive()) {
#'   # inside a server function:
#'   # sv_replace_card(sideviewProxy("review"), "labs", labs_now())
#' }
#' @export
sideviewProxy <- function(id, session = shiny::getDefaultReactiveDomain()) {
  if (is.null(session)) {
    stop("sideviewProxy() needs a Shiny session: call it inside a server function", call. = FALSE)
  }
  key <- paste0(session$ns(id), "-")
  proxy <- sv_proxy_registry(session)[[key]]
  if (is.null(proxy)) {
    stop(sprintf("sideviewServer(\"%s\") has not been started in this session", id), call. = FALSE)
  }
  proxy
}

#' Add, replace or remove a card, set the workspace or highlight columns
#'
#' Verbs for a canvas started with [sideviewServer()]. Each updates the R side first
#' and then tells the browser, and returns the proxy invisibly so they pipe.
#'
#' * `sv_add_card()` adds an auto-placed card; a name already on the canvas is an error.
#' * `sv_replace_card()` keeps the card's place and size and swaps its data. Pipeline
#'   steps that name a column the new table lacks are **disabled, not deleted**, and
#'   one toast says so.
#' * `sv_remove_card()` removes a card and disables the steps that used it.
#' * `sv_set_state()` replaces layout, joins and pipeline, as the Open button does.
#' * `sv_highlight()` highlights columns of a card, as a header click would.
#'
#' @param proxy A `sideview_proxy` from [sideviewServer()] or [sideviewProxy()].
#' @param x A table: anything [sideview()] accepts.
#' @param name Card name (a single string).
#' @param state A state object or its JSON text (e.g. `proxy$state()`); text is recognised
#'   by its leading curly brace.
#' @param cols Column names (a character vector); columns not on the card are ignored.
#' @return `proxy`, invisibly.
#' @examples
#' if (interactive()) {
#'   # px <- sideviewProxy("review")
#'   # sv_replace_card(px, "labs", labs_now()); sv_highlight(px, "labs", "lab_date")
#' }
#' @seealso [sideviewServer()]
#' @export
sv_add_card <- function(proxy, x, name) {
  sv_check_proxy(proxy)
  sv_check_name(name)
  if (proxy$ctl$store$has(name)) {
    stop(sprintf("Card '%s' already exists; use sv_replace_card()", name), call. = FALSE)
  }
  sv_proxy_add(proxy, sv_make_card(x, name))
  invisible(proxy)
}

#' @rdname sv_add_card
#' @export
sv_replace_card <- function(proxy, name, x) {
  sv_check_proxy(proxy)
  sv_check_name(name)
  sv_check_known(proxy, name)
  sv_proxy_replace(proxy, sv_make_card(x, name, id = proxy$ctl$store$get(name)$id))
  invisible(proxy)
}

#' @rdname sv_add_card
#' @export
sv_remove_card <- function(proxy, name) {
  sv_check_proxy(proxy)
  sv_check_name(name)
  sv_check_known(proxy, name)
  sv_proxy_remove(proxy, name)
  invisible(proxy)
}

#' @rdname sv_add_card
#' @export
sv_set_state <- function(proxy, state) {
  sv_check_proxy(proxy)
  json <- sv_state_json(sv_module_state(state))
  proxy$ctl$emit("sideview_state_set", list(state = json))
  invisible(proxy)
}

#' @rdname sv_add_card
#' @export
sv_highlight <- function(proxy, name, cols) {
  sv_check_proxy(proxy)
  sv_check_name(name)
  if (!is.character(cols)) stop("'cols' must be a character vector", call. = FALSE)
  proxy$ctl$emit("sideview_highlight", list(name = name, cols = as.list(unname(cols))))
  invisible(proxy)
}

#' @export
print.sideview_proxy <- function(x, ...) {
  cat("<sideview_proxy> ", x$ns, " (", length(x$ctl$store$names()), " cards)\n", sep = "")
  invisible(x)
}

# ---- internals ---------------------------------------------------------------

sv_check_proxy <- function(proxy) {
  if (!inherits(proxy, "sideview_proxy")) {
    stop("'proxy' must come from sideviewServer() or sideviewProxy()", call. = FALSE)
  }
  invisible(proxy)
}

sv_check_name <- function(name) {
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("'name' must be a single string", call. = FALSE)
  }
  invisible(name)
}

sv_check_known <- function(proxy, name) {
  store <- proxy$ctl$store
  if (!store$has(name)) {
    stop(sprintf("No card '%s'. Cards: %s", name, paste(store$names(), collapse = ", ")), call. = FALSE)
  }
  invisible(name)
}

# Registry of the canvases of a session, keyed by the full input prefix ("outer-review-").
# It lives in the root session's userData, which scoped (module) sessions share.
sv_proxy_registry <- function(session) {
  reg <- session$userData$sideview
  if (is.null(reg)) {
    reg <- new.env(parent = emptyenv())
    session$userData$sideview <- reg
  }
  reg
}

sv_register_proxy <- function(session, ns, proxy) {
  reg <- sv_proxy_registry(session)
  reg[[ns]] <- proxy
  invisible(proxy)
}

# A card from whatever the user passed; `id` keeps the id of the card it replaces,
# because the browser asks R about a card by the id it first received.
sv_make_card <- function(x, name, id = NULL) {
  card <- if (inherits(x, "sideview_card")) x else sv_normalize_arg(x, name)
  card$name <- name
  if (is.null(card$code_ref) || !nzchar(card$code_ref)) card$code_ref <- name
  if (!is.null(id)) card$id <- id
  sv_prepare_card(card)
}

# An htmlwidget card is sent as its HTML; every card entering a module goes through this.
sv_prepare_card <- function(card) {
  if (identical(card$type, "widget") && !is.null(card$widget) && is.null(card$html_content)) {
    card$html_content <- as.character(htmltools::as.tags(card$widget))
    card$widget <- NULL
  }
  card
}

sv_module_cards <- function(cards, on_drop = NULL) {
  lapply(sv_normalize_cards(cards, on_drop = on_drop), sv_prepare_card)
}

# The cards a reactive `cards =` gives when the module starts. `req()` (a silent error)
# means "no cards yet"; the observer fills the store when the reactive becomes valid.
# Any other error is reported as a warning and the module starts empty.
sv_initial_cards <- function(cards, id) {
  tryCatch(
    shiny::isolate(cards()),
    shiny.silent.error = function(e) list(),
    error = function(e) {
      warning(sprintf("sideviewServer(\"%s\"): `cards` failed at start (%s); starting without cards",
                      id, conditionMessage(e)), call. = FALSE)
      list()
    }
  )
}

sv_module_state <- function(state) {
  if (is.character(state) && length(state) == 1L && grepl("^\\s*\\{", state)) {
    return(sv_state_from_json(state))
  }
  sv_as_state(state)
}

sv_proxy_add <- function(proxy, card) {
  ctl <- proxy$ctl
  ctl$store$add(card)
  tags <- sv_module_refinalize(ctl, except = card$id)
  card <- ctl$store$get(card$name)
  ctl$cards_rv(ctl$store$names())
  if (isTRUE(ctl$ready)) {
    ctl$send("sideview_card_add", list(card = sv_card_payload(card, sv_preview_rows)))
  }
  sv_emit_cdisc(ctl, tags)
  invisible(proxy)
}

sv_proxy_replace <- function(proxy, card) {
  ctl <- proxy$ctl
  old <- ctl$store$get(card$name)
  # the cached rows, order and converted table of the old data must not answer for the new
  if (!is.null(old)) ctl$forget(old$id)
  ctl$forget(card$id)
  ctl$store$replace(card$name, card)
  tags <- sv_module_refinalize(ctl, except = card$id)
  card <- ctl$store$get(card$name)
  ctl$cards_rv(ctl$store$names())
  if (isTRUE(ctl$ready)) {
    ctl$send("sideview_card_replace", list(card = sv_card_payload(card, sv_preview_rows)))
  }
  sv_emit_cdisc(ctl, tags)
  invisible(proxy)
}

sv_proxy_remove <- function(proxy, name) {
  ctl <- proxy$ctl
  old <- ctl$store$get(name)
  if (!is.null(old)) ctl$forget(old$id)
  ctl$store$remove(name)
  tags <- sv_module_refinalize(ctl)
  ctl$cards_rv(ctl$store$names())
  if (isTRUE(ctl$ready)) ctl$send("sideview_card_remove", list(name = name))
  sv_emit_cdisc(ctl, tags)
  invisible(proxy)
}

# Re-run the CDISC resolution over the store after it changed. Cards whose tag moved are
# updated in place; the tags that changed on cards other than `except` (the card that
# was just added or replaced carries its own tag in its payload) are returned.
sv_module_refinalize <- function(ctl, except = NULL) {
  old <- unname(ctl$store$all())
  if (!length(old)) return(list())
  new <- suppressWarnings(sv_cdisc_finalize(old, ctl$cdisc %||% "auto"))
  diff <- sv_cdisc_tag_diff(old, new)
  for (card in new) {
    if (card$id %in% names(diff)) ctl$store$replace(card$name, card)
  }
  diff[setdiff(names(diff), except)]
}

sv_emit_cdisc <- function(ctl, tags) {
  if (length(tags)) ctl$emit("sideview_cdisc_update", list(tags = tags))
  invisible(NULL)
}

# Tags are resolved across the canvas, so a re-firing reactive is compared without them.
sv_without_cdisc <- function(card) {
  card$cdisc <- NULL
  card
}

# A reactive `cards =`: replace what changed, add what is new, remove what is gone.
sv_sync_cards <- function(proxy, new_cards, keep = character()) {
  store <- proxy$ctl$store
  new_names <- vapply(new_cards, function(cd) cd$name, "")
  for (card in new_cards) {
    if (!store$has(card$name)) next
    old <- store$get(card$name)
    card$id <- old$id
    if (!identical(sv_without_cdisc(card), sv_without_cdisc(old))) sv_proxy_replace(proxy, card)
  }
  for (card in new_cards) {
    if (!store$has(card$name)) sv_proxy_add(proxy, card)
  }
  for (nm in setdiff(store$names(), c(new_names, keep))) sv_proxy_remove(proxy, nm)
  invisible(proxy)
}

# The control environment of one canvas: queue, ready flag, read-back reactives, and the
# observers for `sideview_ready` and `sideview_snapshot`. Called by sideview_server_impl().
sv_module_wire <- function(input, session, store, send) {
  ctl <- new.env(parent = emptyenv())
  ctl$store <- store
  ctl$send <- send
  ctl$ready <- FALSE
  ctl$queue <- list()
  ctl$warned <- FALSE
  ctl$warned_cards <- character()
  ctl$forget <- function(id) invisible(NULL)
  ctl$code_rv <- shiny::reactiveVal("")
  ctl$pipeline_rv <- shiny::reactiveVal(list())
  ctl$state_rv <- shiny::reactiveVal(NULL)
  ctl$cards_rv <- shiny::reactiveVal(store$names())

  # Messages that do not carry a card wait for the canvas to say it is there.
  ctl$emit <- function(type, message) {
    if (isTRUE(ctl$ready)) {
      send(type, message)
    } else {
      ctl$queue[[length(ctl$queue) + 1L]] <- list(type = type, message = message)
    }
    invisible(NULL)
  }

  shiny::observeEvent(input$sideview_ready, {
    for (card in store$all()) {
      send("sideview_card_add", list(card = sv_card_payload(card, sv_preview_rows)))
    }
    queued <- ctl$queue
    ctl$queue <- list()
    ctl$ready <- TRUE
    for (q in queued) send(q$type, q$message)
  }, ignoreInit = FALSE)

  # Snapshots only set the reactives: nothing is sent back, so there is no echo.
  shiny::observeEvent(input$sideview_snapshot, {
    snap <- if (ctl$warned) {
      suppressWarnings(sv_parse_snapshot(input$sideview_snapshot))
    } else {
      withCallingHandlers(
        sv_parse_snapshot(input$sideview_snapshot),
        warning = function(w) ctl$warned <- TRUE
      )
    }
    if (is.null(snap)) return()
    ctl$code_rv(snap$code)
    ctl$pipeline_rv(snap$pipeline)
    ctl$state_rv(snap$state)
  }, ignoreInit = FALSE)

  ctl
}

#' Parse and validate the snapshot the canvas sends
#'
#' Returns `list(code, pipeline, state)` or `NULL` (with a warning) when the snapshot
#' is over 1e6 bytes or its JSON does not parse. A `code` that is not one string
#' becomes `""`.
#' @noRd
sv_parse_snapshot <- function(x) {
  drop <- function(why) {
    warning("sideview: a canvas snapshot was dropped (", why, ")", call. = FALSE)
    NULL
  }
  if (!is.list(x)) return(drop("not an object"))
  bytes <- 0
  for (f in c("code", "pipeline", "state")) {
    v <- x[[f]]
    if (is.character(v)) bytes <- bytes + sum(nchar(v, type = "bytes"), na.rm = TRUE)
  }
  if (bytes > 1e6) return(drop("over 1 MB"))

  code <- x$code
  code <- if (is.character(code) && length(code) == 1L && !is.na(code) && !sv_is_no_code(code)) code else ""

  pipeline <- list()
  if (!is.null(x$pipeline)) {
    pipeline <- tryCatch({
      if (!is.character(x$pipeline) || length(x$pipeline) != 1L) stop("not text")
      out <- jsonlite::fromJSON(x$pipeline, simplifyVector = FALSE)
      if (!is.list(out)) stop("not a list")
      out
    }, error = function(e) NULL)
    if (is.null(pipeline)) return(drop("the pipeline is not valid JSON"))
  }

  state <- NULL
  if (!is.null(x$state)) {
    state <- tryCatch(sv_state_from_json(x$state), error = function(e) NULL)
    if (is.null(state)) return(drop("the state is not valid JSON"))
  }
  list(code = code, pipeline = pipeline, state = state)
}
