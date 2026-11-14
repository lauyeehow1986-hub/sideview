# Accessibility test helpers: the Chrome accessibility tree, real keyboard input,
# and the three page modes (gadget, widget, module). Build on helper-browser.R.

# The full AX tree as a data frame.
sv_ax_tree <- function(b) {
  b$Accessibility$enable()
  nodes <- b$Accessibility$getFullAXTree()$nodes
  val <- function(x) {
    v <- x$value
    if (is.null(v)) "" else as.character(v)
  }
  prop <- function(n, name) {
    for (p in n$properties) if (identical(p$name, name)) return(p$value$value)
    NULL
  }
  rows <- lapply(nodes, function(n) {
    lvl <- prop(n, "level")
    foc <- prop(n, "focusable")
    data.frame(
      role = val(n$role),
      name = val(n$name),
      ignored = isTRUE(n$ignored),
      backend_id = as.integer(n$backendDOMNodeId %||% NA_integer_),
      level = if (is.null(lvl)) NA_integer_ else as.integer(lvl),
      focusable = isTRUE(foc),
      stringsAsFactors = FALSE
    )
  })
  if (!length(rows)) {
    return(data.frame(role = character(), name = character(), ignored = logical(),
                      backend_id = integer(), level = integer(), focusable = logical()))
  }
  do.call(rbind, rows)
}

sv_ax_named_roles <- c("button", "textbox", "combobox", "checkbox", "switch",
                       "spinbutton", "searchbox", "listbox", "slider")

# Interactive nodes that expose no accessible name.
sv_ax_unnamed <- function(tree) {
  tree[tree$role %in% sv_ax_named_roles & !tree$ignored & tree$name == "", , drop = FALSE]
}

# One key press (keyDown then keyUp). Modifiers: Alt 1, Ctrl 2, Meta 4, Shift 8.
sv_key <- function(b, key, code = key, modifiers = 0L, text = NULL) {
  down <- list(type = if (is.null(text)) "rawKeyDown" else "keyDown", key = key, code = code,
               modifiers = as.integer(modifiers))
  if (!is.null(text)) down$text <- text
  vk <- c(Tab = 9L, Enter = 13L, Escape = 27L, " " = 32L, ArrowLeft = 37L, ArrowUp = 38L,
          ArrowRight = 39L, ArrowDown = 40L, Home = 36L, End = 35L)
  if (key %in% names(vk)) down$windowsVirtualKeyCode <- unname(vk[key])
  do.call(b$Input$dispatchKeyEvent, down)
  up <- down
  up$type <- "keyUp"
  up$text <- NULL
  do.call(b$Input$dispatchKeyEvent, up)
  invisible(b)
}

sv_tab <- function(b, n = 1L, shift = FALSE) {
  for (i in seq_len(n)) sv_key(b, "Tab", modifiers = if (shift) 8L else 0L)
  invisible(b)
}

# What holds focus: tag, role, name (aria-label, else text) and classes.
sv_focus_info <- function(b) {
  r <- sv_js(b, "(() => { const e = document.activeElement || {};
    const txt = (e.textContent || '').replace(new RegExp('[ ' + String.fromCharCode(9, 10, 13) + ']+', 'g'), ' ').trim();
    return { tag: (e.tagName || '').toLowerCase(), role: (e.getAttribute && e.getAttribute('role')) || '',
             name: (e.getAttribute && (e.getAttribute('aria-label') || e.getAttribute('title'))) || txt,
             classes: typeof e.className === 'string' ? e.className : '' }; })()")
  lapply(r, function(x) if (is.null(x)) "" else x)
}

# Save a widget built from an expression (fixture tables in scope) and return its file URL.
sv_widget_url <- function(widget_expr) {
  env <- new.env(parent = globalenv())
  eval(parse(text = sv_fixture_code), envir = env)
  w <- eval(parse(text = widget_expr), envir = env)
  tmp <- tempfile(fileext = ".html")
  suppressMessages(save_sideview(w, tmp, selfcontained = FALSE))
  paste0("file:///", normalizePath(tmp, winslash = "/"))
}

# Page specs for the three modes; each `open(theme, width, height)` returns a ready session.
# The caller closes the session (b$close()).
sv_a11y_pages <- function() {
  open_app <- function(app_expr, ready) {
    force(app_expr)
    function(theme = "light", width = 1360, height = 820) {
      expr <- sprintf(app_expr, theme)
      app <- sv_start_app(expr)
      b <- sv_open_page(app$url, width, height, wait_for = ready)
      attr(b, "sv_app") <- app
      b
    }
  }
  ready_cards <- "document.querySelectorAll('.sideview-card').length >= 2 && !!document.querySelector('.sideview-container')._sideviewInstance"
  module_expr <- paste0(
    "shiny::shinyApp(",
    "shiny::fluidPage(sideview::sideviewUI('m', height = '780px', theme = '%s')),",
    "function(input, output, session) sideview::sideviewServer('m', cards = list(",
    "patients = patients, visits = visits, labs = labs)))")
  list(
    gadget = list(open = open_app("sideview(patients, visits, labs, theme = '%s', run = FALSE)", ready_cards)),
    widget = list(open = function(theme = "light", width = 1360, height = 820) {
      url <- sv_widget_url(sprintf("sideview_widget(patients, visits, labs, theme = '%s')", theme))
      sv_open_page(url, width, height, wait_for = ready_cards)
    }),
    module = list(open = open_app(module_expr, ready_cards))
  )
}
