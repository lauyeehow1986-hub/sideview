#' Locate Sideview Web Assets Directory
#'
#' @return Absolute path to the web assets directory.
#' @noRd
find_sideview_www <- function() {
  candidates <- c(
    system.file("www", package = "sideview"),
    file.path("inst", "www"),
    file.path("..", "inst", "www"),
    file.path("..", "..", "inst", "www"),
    file.path(".", "www")
  )
  for (cand in candidates) {
    if (nzchar(cand) && dir.exists(cand)) {
      return(normalizePath(cand))
    }
  }
  system.file("www", package = "sideview")
}

#' Version String for the Bundled Web Assets
#'
#' The dependency version is part of the asset URL, so it must change whenever
#' the files do; otherwise browsers keep serving cached JS/CSS after an
#' upgrade. Package version plus a short fingerprint of the file contents.
#'
#' @param www_dir Directory holding the assets.
#' @param files Asset file names.
#' @return A version string such as `"0.2.0.1234567"`.
#' @noRd
sv_asset_version <- function(www_dir, files = c("sideview.js", "sideview.css", "sv-panzoom.js", "sv-pipeline.js")) {
  pkg <- tryCatch(as.character(utils::packageVersion("sideview")), error = function(e) "0.0.0")
  paths <- file.path(www_dir, files)
  paths <- paths[file.exists(paths)]
  if (!length(paths)) return(pkg)
  sums <- unname(tools::md5sum(paths))
  fp <- sum(strtoi(substr(sums, 1, 6), 16L)) %% 1e7
  paste0(pkg, ".", format(fp, scientific = FALSE))
}

#' HTML Dependency for Sideview Assets
#'
#' The single `sideview-core` dependency (pan/zoom helper, engine, styles) is
#' shared by the gadget and the htmlwidget so a page never loads two copies.
#'
#' @param www_dir Directory holding the assets.
#' @return An `htmltools::htmlDependency` object.
#' @noRd
sideview_html_dependency <- function(www_dir = find_sideview_www()) {
  htmltools::htmlDependency(
    name = "sideview-core",
    version = sv_asset_version(www_dir),
    src = c(file = www_dir),
    stylesheet = "sideview.css",
    script = c("sv-panzoom.js", "sv-pipeline.js", "sideview.js")
  )
}

#' Generate Column Header Profiling Tags
#'
#' Computes sparkline histograms for numeric columns, top category frequency
#' for categorical/factor columns, and missingness badges.
#'
#' @param col_vals A vector of column values.
#' @return A `shiny.tag` or `NULL` representing the header profiling summary.
#' @noRd
render_col_profiling <- function(col_vals) {
  if (is.null(col_vals) || length(col_vals) == 0L) return(NULL)
  
  n_total <- length(col_vals)
  na_cnt <- sum(is.na(col_vals))
  
  # 1. Missingness indicator (.sideview-na-badge)
  na_badge <- NULL
  if (na_cnt > 0L && n_total > 0L) {
    pct <- round(na_cnt / n_total * 100, 1)
    badge_cls <- if (pct > 50) "sideview-na-badge is-high" else "sideview-na-badge"
    badge_text <- if (pct == 0) "<0.1% NA" else paste0(pct, "% NA")
    title_pct <- if (pct == 0) "<0.1%" else sprintf("%.1f%%", pct)
    na_badge <- htmltools::tags$span(
      class = badge_cls,
      title = sprintf("%d missing values (%s)", na_cnt, title_pct),
      badge_text
    )
  }
  
  # 2. Distribution indicator
  profile_indicator <- NULL
  if (is.numeric(col_vals)) {
    valid_vals <- col_vals[!is.na(col_vals) & is.finite(col_vals)]
    n_valid <- length(valid_vals)
    
    counts <- integer(5L)
    svg_title <- "No valid values (n=0)"
    if (n_valid > 0L) {
      min_val <- min(valid_vals)
      max_val <- max(valid_vals)
      svg_title <- sprintf("Range: [%s, %s] (n=%d)", format(min_val, digits = 3), format(max_val, digits = 3), n_valid)
      if (min_val == max_val) {
        counts[3L] <- n_valid
      } else {
        breaks <- seq(min_val, max_val, length.out = 6L)
        binned <- cut(valid_vals, breaks = breaks, include.lowest = TRUE)
        tab <- as.vector(table(binned))
        counts[seq_along(tab)] <- tab
      }
    }
    
    max_c <- max(counts)
    rect_tags <- lapply(seq_len(5L), function(i) {
      cnt <- counts[i]
      h <- if (max_c > 0L && cnt > 0L) max(1L, round((cnt / max_c) * 12L)) else 0L
      y <- 13L - h
      x <- (i - 1L) * 10L
      htmltools::tag("rect", list(
        x = x,
        y = y,
        width = 8L,
        height = h,
        rx = 1L
      ))
    })
    
    profile_indicator <- htmltools::tag(
      "svg",
      list(
        class = "sideview-sparkline",
        title = svg_title,
        viewBox = "0 0 50 14",
        width = "50",
        height = "14",
        rect_tags
      )
    )
  } else if (is.character(col_vals) || is.factor(col_vals) || is.logical(col_vals)) {
    valid_vals <- col_vals[!is.na(col_vals)]
    n_valid <- length(valid_vals)
    
    if (n_valid > 0L) {
      is_sampled <- n_valid > 25000L
      tab_vals <- if (is_sampled) valid_vals[sample.int(n_valid, 25000L)] else valid_vals
      n_tab <- length(tab_vals)
      tbl <- sort(table(as.character(tab_vals)), decreasing = TRUE)
      top_val <- names(tbl)[1L]
      top_cnt <- as.integer(tbl[1L])
      top_pct <- round(top_cnt / n_tab * 100)
      n_unique <- length(tbl)
      
      display_label <- if (nzchar(top_val)) {
        if (nchar(top_val) > 7L) paste0(substr(top_val, 1L, 6L), "\u2026") else top_val
      } else {
        '""'
      }
      
      title_str <- if (is_sampled) {
        sprintf("Top: %s (~%d%%, sampled %d/%d) | ~%d distinct", top_val, top_pct, top_cnt, n_tab, n_unique)
      } else {
        sprintf("Top: %s (%d%%, %d/%d) | %d distinct", top_val, top_pct, top_cnt, n_valid, n_unique)
      }
      
      profile_indicator <- htmltools::tags$span(
        class = "sideview-cat-profile",
        title = title_str,
        htmltools::tags$span(
          class = "sideview-cat-bar",
          style = sprintf("width: %d%%;", max(5L, min(100L, as.integer(top_pct))))
        ),
        htmltools::tags$span(
          class = "sideview-cat-label",
          sprintf("%d%% %s", top_pct, display_label)
        )
      )
    } else {
      profile_indicator <- htmltools::tags$span(
        class = "sideview-cat-profile",
        title = "All values missing",
        htmltools::tags$span(class = "sideview-cat-bar", style = "width: 0%;")
      )
    }
  }
  
  if (is.null(profile_indicator) && is.null(na_badge)) {
    return(NULL)
  }
  
  htmltools::tags$div(
    class = "col-header-profile",
    profile_indicator,
    na_badge
  )
}

#' Render a Single Card to Shiny HTML Tags
#'
#' @param card A `sideview_card` object.
#' @param index Integer index of the card on the canvas.
#' @return A `shiny.tag` element.
#' @noRd
render_card_tag <- function(card, index = 1L) {
  card_id <- card$id %||% paste0("card_", index)
  card_name <- card$name %||% paste0("Table_", index)
  card_type <- card$type %||% "grid"
  
  initial_x <- if (!is.null(card$x)) card$x else 40 + (index - 1) * 360
  initial_y <- if (!is.null(card$y)) card$y else 60 + ((index - 1) %% 2) * 50
  
  dims_text <- if (!is.null(card$dims) && length(card$dims) >= 2) {
    paste0(card$dims[1], " \u00d7 ", card$dims[2])
  } else {
    ""
  }
  
  # Header
  header_tag <- htmltools::tags$div(
    class = "sideview-card-header",
    htmltools::tags$div(
      class = "sideview-card-title-group",
      htmltools::tags$span(class = "sideview-card-title", card_name),
      htmltools::tags$span(class = "sideview-badge sideview-badge-type", card_type),
      if (nzchar(dims_text)) htmltools::tags$span(class = "sideview-badge", dims_text)
    ),
    htmltools::tags$div(
      class = "sideview-card-actions",
      htmltools::tags$button(
        class = "sideview-icon-btn",
        `data-action` = "maximize-card",
        title = "Maximize card",
        `aria-label` = "Maximize card",
        `data-sv-icon` = "maximize"
      ),
      htmltools::tags$button(
        class = "sideview-icon-btn",
        `data-action` = "sync-scroll",
        title = "Synchronize vertical & horizontal scrolling",
        `aria-label` = "Synchronize scrolling",
        `data-sv-icon` = "link"
      ),
      htmltools::tags$button(
        class = "sideview-icon-btn",
        `data-action` = "minimize-card",
        title = "Collapse card",
        `aria-label` = "Collapse card",
        `data-sv-icon` = "minus"
      )
    )
  )
  
  # Body
  body_content <- NULL
  if (card_type == "grid" && !is.null(card$data) && is.data.frame(card$data)) {
    df <- card$data
    col_names <- colnames(df)
    col_types <- card$col_types %||% character(0)
    
    # Table header
    th_tags <- lapply(col_names, function(col) {
      c_type <- col_types[col] %||% ""
      col_vals <- df[[col]]
      profile_summary <- render_col_profiling(col_vals)
      
      htmltools::tags$th(
        `data-col-name` = col,
        `data-col-type` = if (is.numeric(col_vals)) "numeric" else if (nzchar(c_type) && !is.na(c_type)) c_type else NULL,
        title = if (nzchar(c_type)) sprintf("%s (%s)", col, c_type) else col,
        htmltools::tags$div(
          class = "col-header-wrap",
          htmltools::tags$div(
            class = "col-header-left",
            htmltools::tags$span(class = "sideview-col-name", col),
            if (!is.null(c_type) && !is.na(c_type) && nzchar(c_type)) {
              htmltools::tags$span(class = "sideview-col-type", paste0("(", c_type, ")"), title = paste0("Type: ", c_type))
            }
          ),
          htmltools::tags$div(
            class = "col-header-tools",
            htmltools::tags$button(class = "sideview-th-btn sideview-sort-btn", `data-action` = "sort-col", `data-col-name` = col, title = "Sort column (Asc / Desc / Reset)", `aria-label` = paste("Sort", col), `data-sv-icon` = "sort"),
            htmltools::tags$button(class = "sideview-th-btn sideview-filter-btn", `data-action` = "filter-col", `data-col-name` = col, title = "Filter column", `aria-label` = paste("Filter", col), `data-sv-icon` = "filter"),
            htmltools::tags$button(class = "sideview-th-btn sideview-inspect-btn", `data-action` = "inspect-col", `data-col-name` = col, title = "Inspect column", `aria-label` = paste("Inspect", col), `data-sv-icon` = "inspect"),
            htmltools::tags$span(class = "sideview-col-port", `data-col-name` = col, title = "Connect to map field")
          ),
          profile_summary
        ),
        htmltools::tags$span(class = "sideview-col-resizer", title = "Drag to resize column width")
      )
    })
    # Table rows (virtualized preview up to 500 rows)
    max_preview <- min(nrow(df), 500L)
    row_tags <- vector("list", max_preview)
    for (r in seq_len(max_preview)) {
      td_tags <- lapply(col_names, function(col) {
        val <- df[[col]][r]
        val_str <- if (is.null(val) || length(val) == 0L) {
          ""
        } else if (is.list(val) || length(val) > 1L) {
          "[list]"
        } else if (is.na(val)) {
          "NA"
        } else {
          as.character(val)
        }
        is_num <- is.numeric(df[[col]])
        htmltools::tags$td(
          class = if (is_num) "is-number" else NULL,
          val_str
        )
      })
      row_tags[[r]] <- htmltools::tags$tr(td_tags)
    }
    
    body_content <- htmltools::tags$table(
      class = "sideview-table",
      htmltools::tags$thead(htmltools::tags$tr(th_tags)),
      htmltools::tags$tbody(row_tags)
    )
  } else if (!is.null(card$widget)) {
    body_content <- htmltools::as.tags(card$widget)
  } else if (!is.null(card$html_content) && nzchar(card$html_content)) {
    body_content <- htmltools::HTML(card$html_content)
  } else {
    body_content <- htmltools::tags$div(
      class = "sideview-placeholder",
      paste("No preview available for", card_name)
    )
  }
  
  body_tag <- htmltools::tags$div(class = "sideview-card-body", body_content)
  
  htmltools::tags$div(
    class = "sideview-card panzoom-exclude",
    id = card_id,
    `data-card-id` = card_id,
    `data-card-name` = card_name,
    `data-total-rows` = if (is.data.frame(card$data)) nrow(card$data) else NULL,
    # No saved position: the engine flows these cards into a grid on load.
    `data-auto-place` = if (is.null(card$x) && is.null(card$y)) "true" else NULL,
    style = sprintf("left: %dpx; top: %dpx;", as.integer(initial_x), as.integer(initial_y)),
    header_tag,
    body_tag
  )
}

#' Sideview User Interface
#'
#' Builds the complete 2D infinite canvas user interface for Sideview,
#' containing the draggable table cards, panzoom canvas, SVG connector overlay,
#' action drawer, and natural language AI bar with all HTML dependencies attached.
#'
#' @param cards A `sideview_card` object, a list of `sideview_card` objects,
#'   or tabular objects to be normalized.
#' @param title Display title for the application toolbar. Default is "Sideview Canvas".
#' @param gadget If `TRUE`, add Done and Cancel buttons to the toolbar (used by `sideview()`).
#' @param theme `"auto"`, `"light"`, `"dark"`, an [sv_theme()] or a
#'   `bslib::bs_theme()`. See [sv_theme()].
#'
#' @return A `shiny.tag.list` UI definition.
#' @export
sideview_ui <- function(cards = list(), title = "Sideview Canvas", gadget = FALSE, theme = "auto") {
  # Normalize input into a list of sideview_cards
  if (is.null(cards)) {
    card_list <- list()
  } else if (inherits(cards, "sideview_card") || is.data.frame(cards) ||
             inherits(cards, c("gt_tbl", "flextable", "table"))) {
    card_list <- list(cards)
  } else if (is.list(cards)) {
    card_list <- cards
  } else {
    card_list <- list(cards)
  }
  
  normalized_cards <- list()
  for (i in seq_along(card_list)) {
    c_item <- card_list[[i]]
    if (inherits(c_item, "sideview_card")) {
      normalized_cards[[length(normalized_cards) + 1]] <- c_item
    } else {
      nm <- names(card_list)[i]
      if (is.null(nm) || !nzchar(nm)) {
        nm <- paste0("Table_", i)
      }
      norm <- tryCatch(sv_normalize(c_item, name = nm), error = function(e) NULL)
      if (!is.null(norm)) {
        normalized_cards[[length(normalized_cards) + 1]] <- norm
      }
    }
  }
  
  # Render all card tags
  rendered_cards <- lapply(seq_along(normalized_cards), function(idx) {
    render_card_tag(normalized_cards[[idx]], index = idx)
  })
  
  # Toolbar
  toolbar_tag <- htmltools::tags$div(
    class = "sideview-toolbar",
    htmltools::tags$span(class = "sideview-brand", title),
    htmltools::tags$span(class = "sideview-toolbar-divider"),
    htmltools::tags$button(class = "sideview-btn", `data-action` = "zoom-in", title = "Zoom in (+)", `aria-label` = "Zoom in", "+"),
    htmltools::tags$button(class = "sideview-btn", `data-action` = "zoom-out", title = "Zoom out (-)", `aria-label` = "Zoom out", "-"),
    htmltools::tags$button(class = "sideview-btn", `data-action` = "zoom-reset", title = "Reset view to 100% (0)", `aria-label` = "Reset zoom", "100%"),
    htmltools::tags$button(class = "sideview-btn", `data-action` = "fit-all", title = "Fit all cards in view (F)", "Fit"),
    htmltools::tags$button(class = "sideview-btn", `data-action` = "arrange-cards", title = "Arrange cards in a grid", "Arrange"),
    htmltools::tags$span(class = "sideview-toolbar-divider"),
    htmltools::tags$button(class = "sideview-btn active", `data-action` = "toggle-snap", title = "Snap to Edge", "Snap"),
    htmltools::tags$button(class = "sideview-btn", `data-action` = "toggle-drawer", title = "Show or hide the drawer (D)", "Drawer"),
    htmltools::tags$button(class = "sideview-btn", `data-action` = "toggle-fullscreen", title = "Toggle Fullscreen Canvas", `aria-label` = "Toggle fullscreen canvas", sv_icon_slot("fullscreen"), " Fullscreen"),
    if (isTRUE(gadget)) htmltools::tagList(
      htmltools::tags$span(class = "sideview-toolbar-divider"),
      htmltools::tags$button(class = "sideview-btn", `data-action` = "gadget-cancel",
                             title = "Close without returning code", "Cancel"),
      htmltools::tags$button(class = "sideview-btn sideview-btn-primary", `data-action` = "gadget-done",
                             title = "Close and return the generated code to R", "Done")
    )
  )
  
  # Swatch palette
  palette_tag <- htmltools::tags$div(
    class = "sideview-palette",
    role = "group",
    `aria-label` = "Highlight colour",
    htmltools::tags$span(class = "sideview-palette-label", "Highlight:"),
    lapply(c("blue", "green", "amber", "rose", "purple"), function(col) {
      label <- paste("Highlight", col)
      htmltools::tags$button(type = "button", class = paste0("sideview-swatch sideview-swatch-", col),
                             `data-color` = col, title = label, `aria-label` = label, `aria-pressed` = "false")
    }),
    htmltools::tags$button(type = "button", class = "sideview-swatch sideview-swatch-clear", `data-color` = "clear",
                           title = "Clear highlight", `aria-label` = "Clear highlight", `aria-pressed` = "false",
                           `data-sv-icon` = "close")
  )
  
  # Canvas & Viewport with SVG overlay
  canvas_tag <- htmltools::tags$div(
    class = "sideview-canvas",
    htmltools::tags$div(
      class = "sideview-viewport",
      htmltools::tags$svg(
        class = "sideview-connector-svg",
        width = "100%",
        height = "100%"
      ),
      rendered_cards
    )
  )
  
  # Action drawer
  drawer_tag <- htmltools::tags$div(
    class = "sideview-drawer collapsed",
    htmltools::tags$div(
      class = "sideview-drawer-header",
      htmltools::tags$span(class = "sideview-drawer-title", "Tidyverse Operations"),
      htmltools::tags$button(class = "sideview-icon-btn", `data-action` = "close-drawer", title = "Close drawer", `aria-label` = "Close drawer", `data-sv-icon` = "close")
    ),
    # sideview.js rebuilds this tab strip and fills the builder panes
    # (ensureDrawer), so keep the ids in sync with DRAWER_TABS there.
    htmltools::tags$div(
      class = "sideview-drawer-tabs",
      role = "tablist",
      lapply(seq_along(sv_drawer_tabs), function(i) {
        htmltools::tags$button(
          type = "button",
          class = if (i == 1) "sideview-drawer-tab active" else "sideview-drawer-tab",
          `data-tab` = names(sv_drawer_tabs)[i],
          role = "tab",
          sv_drawer_tabs[[i]]
        )
      })
    ),
    htmltools::tags$div(
      class = "sideview-drawer-content",
      htmltools::tags$div(
        class = "sideview-tab-pane sideview-pipeline-pane",
        `data-pane` = "pipeline",
        # No whitespace inside <pre>: htmltools' indentation would show as code.
        htmltools::tags$pre(
          class = "sideview-code-block",
          .noWS = c("after-begin", "before-end"),
          htmltools::tags$code(class = "sideview-code-text", "# Connect two columns to generate pipeline code")
        )
      ),
      # Builder panes are filled in by sideview.js from the cards on the canvas.
      lapply(c("filter", "arrange", "mutate", "recode", "summarise"), function(id) {
        htmltools::tags$div(
          class = paste0("sideview-tab-pane sideview-builder-pane sideview-", id, "-pane"),
          `data-pane` = id,
          style = "display: none;"
        )
      }),
      htmltools::tags$div(
        class = "sideview-tab-pane sideview-discrepancy-pane",
        `data-pane` = "discrepancy",
        style = "display: none;",
        htmltools::tags$div(class = "sideview-joincheck", `aria-live` = "polite"),
        htmltools::tags$div(
          class = "sideview-discrepancy-content",
          htmltools::tags$p(class = "sideview-drawer-desc", "Connect columns between two tables to inspect discrepancies.")
        )
      ),
      htmltools::tags$div(
        class = "sideview-tab-pane sideview-chat-pane",
        `data-pane` = "chat",
        style = "display: none;",
        htmltools::tags$div(
          class = "sideview-chat-messages",
          htmltools::tags$div(
            class = "sideview-chat-bubble sideview-chat-assistant",
            htmltools::tags$div(class = "sideview-chat-bubble-text", "Hello! I am your AI Copilot. Ask me questions about your tables, request tidyverse code, or refine an existing pipeline.")
          )
        ),
        htmltools::tags$div(
          class = "sideview-chat-input-wrap",
          htmltools::tags$input(
            type = "text",
            id = "sideview-chat-input",
            class = "sideview-chat-input",
            placeholder = "Ask Copilot... (e.g. filter rows where age > 30)"
          ),
          htmltools::tags$button(
            id = "sideview-chat-send",
            class = "sideview-btn sideview-btn-primary sideview-chat-send",
            "Send"
          )
        )
      )
    ),
    htmltools::tags$div(
      class = "sideview-drawer-actions",
      htmltools::tags$button(class = "sideview-btn sideview-btn-primary", `data-action` = "inject-script", `data-r-only` = NA, title = "Insert code into active RStudio script", "Insert Script"),
      htmltools::tags$button(class = "sideview-btn", `data-action` = "send-console-exit", `data-r-only` = NA, title = "Send code to RStudio console and exit gadget to execute immediately", "Run & Exit"),
      htmltools::tags$button(class = "sideview-btn", `data-action` = "eval-env", `data-r-only` = NA, title = "Execute code immediately in active R session environment", "Run in R"),
      htmltools::tags$button(class = "sideview-btn", `data-action` = "send-console", `data-r-only` = NA, title = "Queue code to RStudio console (executes when gadget closes)", "Run Console"),
      htmltools::tags$button(class = "sideview-btn", `data-action` = "copy-code", "Copy"),
      htmltools::tags$button(class = "sideview-btn sideview-btn-danger", `data-action` = "clear-operation", title = "Clear current operations, connector lines, and generated code", "Clear"),
      htmltools::tags$label(
        class = "sideview-autoclear-wrap",
        title = "Automatically clear operations after inserting into script or copying",
        htmltools::tags$input(type = "checkbox", class = "sideview-autoclear-toggle"),
        htmltools::tags$span("Auto-clear")
      )
    )
  )
  
  # Floating AI bar
  ai_bar_tag <- htmltools::tags$div(
    class = "sideview-ai-bar",
    htmltools::tags$span(class = "sideview-ai-icon", `aria-hidden` = "true", `data-sv-icon` = "sparkles"),
    htmltools::tags$input(type = "text", class = "sideview-ai-input", placeholder = "Ask AI: e.g., join patients and labs on ID, impute missing values..."),
    htmltools::tags$button(class = "sideview-ai-send", `data-action` = "send-ai", "Send")
  )
  
  # Client bootstrap script
  init_script <- htmltools::tags$script(htmltools::HTML("
    (function() {
      function start() {
        if (typeof initSideview === 'function') {
          document.documentElement.classList.add('sv-standalone');
          initSideview('.sideview-container');
          window.sideviewInitialized = true;
        }
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
      } else {
        start();
      }
    })();
  "))
  
  # Complete container
  theme <- sv_resolve_theme(theme)
  container_tag <- htmltools::tags$div(
    class = paste0("sideview-container sv-standalone sv-theme-", theme$mode),
    `data-sv-theme` = theme$mode,
    style = sv_theme_style(theme),
    canvas_tag,
    htmltools::tags$div(class = "sideview-topbar", toolbar_tag, palette_tag),
    drawer_tag,
    ai_bar_tag,
    init_script
  )
  
  htmltools::tagList(
    sideview_html_dependency(),
    container_tag
  )
}

# Placeholder for an inline SVG icon. The engine (sideview.js icon()/
# hydrateIcons()) fills every empty [data-sv-icon] element on start-up, so the
# icon set lives in one place and no emoji/Unicode glyphs reach the page.
sv_icon_slot <- function(name) {
  htmltools::tags$span(class = "sv-icon-slot", `aria-hidden` = "true", `data-sv-icon` = name)
}

# Drawer tabs, in order (id = label). Mirrors DRAWER_TABS in sideview.js.
sv_drawer_tabs <- c(
  pipeline = "Pipeline",
  filter = "Filter",
  arrange = "Arrange",
  mutate = "Mutate",
  recode = "Recode",
  summarise = "Summarise",
  inspect = "Inspect",
  discrepancy = "Discrepancy",
  chat = "Copilot"
)
