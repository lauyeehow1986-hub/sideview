#' Canvas Theme
#'
#' Builds a theme for [sideview()] and [sideview_widget()]: a light/dark mode
#' plus optional overrides of the canvas design tokens (the `--sv-*` CSS
#' custom properties in `inst/www/sideview.css`).
#'
#' @param mode `"auto"` (default), `"light"` or `"dark"`. With `"auto"` the
#'   gadget follows the RStudio editor theme when it runs inside RStudio, and
#'   otherwise (and in the widget) follows the operating system's
#'   `prefers-color-scheme` setting. The toolbar button or the `T` key switches
#'   theme while the canvas is open.
#' @param primary Accent colour for buttons, selections and splines (any CSS
#'   colour that [grDevices::col2rgb()] understands, e.g. `"#0d6efd"`). Hover,
#'   focus and tint shades are derived from it.
#' @param font,font_mono Font stacks for text and code.
#' @param radius Card corner radius (CSS length, e.g. `"4px"`).
#' @param ... Further token overrides by name, e.g. `canvas_bg = "#fafafa"` sets
#'   `--sv-canvas-bg`. Underscores become hyphens.
#'
#' @return An object of class `sv_theme`.
#' @export
#' @examples
#' sv_theme("dark")
#' sv_theme(primary = "#0f766e", radius = "4px")
#' if (interactive()) sideview(mtcars, theme = sv_theme("dark", primary = "#f59e0b"))
sv_theme <- function(mode = c("auto", "light", "dark"), primary = NULL, font = NULL,
                     font_mono = NULL, radius = NULL, ...) {
  mode <- match.arg(mode)
  vars <- list(...)
  if (length(vars) && (is.null(names(vars)) || any(!nzchar(names(vars))))) {
    stop("Token overrides in `...` must be named, e.g. canvas_bg = \"#fafafa\".", call. = FALSE)
  }
  names(vars) <- gsub("_", "-", names(vars), fixed = TRUE)
  if (!is.null(primary)) vars <- utils::modifyList(sv_primary_tokens(primary), vars)
  if (!is.null(font)) vars$font <- font
  if (!is.null(font_mono)) vars$`font-mono` <- font_mono
  if (!is.null(radius)) vars$radius <- radius

  for (nm in names(vars)) {
    val <- vars[[nm]]
    if (!grepl("^[a-z0-9-]+$", nm)) {
      stop(sprintf("Invalid token name `%s`: use letters, digits and _ only.", nm), call. = FALSE)
    }
    if (!is.character(val) || length(val) != 1L || is.na(val) || grepl("[;{}<>]", val)) {
      stop(sprintf("Token `%s` must be a single CSS value without ; { } < >.", nm), call. = FALSE)
    }
  }
  structure(list(mode = mode, vars = vars), class = "sv_theme")
}

#' @export
print.sv_theme <- function(x, ...) {
  cat("<sv_theme> mode:", x$mode, "\n")
  for (nm in names(x$vars)) cat(sprintf("  --sv-%s: %s\n", nm, x$vars[[nm]]))
  invisible(x)
}

# Shades derived from one accent colour, so a custom primary also recolours
# hover, focus rings, tints and the splines consistently.
sv_primary_tokens <- function(primary) {
  rgb <- tryCatch(grDevices::col2rgb(primary)[, 1], error = function(e) NULL)
  if (is.null(rgb)) stop(sprintf("`primary` is not a colour: %s", primary), call. = FALSE)
  hex <- function(v) sprintf("#%02x%02x%02x", v[1], v[2], v[3])
  rgba <- function(a) sprintf("rgba(%d, %d, %d, %s)", rgb[1], rgb[2], rgb[3], a)
  base <- hex(rgb)
  # Labels sit on the primary colour (buttons, badges, chat bubbles): use white
  # or near-black, whichever contrasts more (always >= 4.5:1), and move the
  # hover shade away from the label so hovering never loses contrast.
  dark_text <- c(11, 18, 32)
  ratio <- function(a, b) {
    la <- sv_rel_luminance(a); lb <- sv_rel_luminance(b)
    (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }
  white_label <- ratio(c(255, 255, 255), rgb) >= ratio(dark_text, rgb)
  hover <- if (white_label) round(rgb * 0.85) else round(rgb + (255 - rgb) * 0.25)
  # Primary used as text (active buttons, links): darken it for the light theme
  # and lighten it for the dark theme until it reads on that theme's surfaces,
  # including the primary tint some of those labels sit on.
  readable_on <- function(surfaces, toward) {
    tinted <- lapply(surfaces, function(s) rgb * 0.16 + s * 0.84)
    bgs <- c(surfaces, tinted)
    for (t in seq(0, 1, by = 0.05)) {
      col <- round(rgb + (toward - rgb) * t)
      if (all(vapply(bgs, function(bg) ratio(col, bg), numeric(1)) >= 4.5)) return(hex(col))
    }
    hex(toward)
  }
  light_surfaces <- list(c(255, 255, 255), c(248, 250, 252), c(241, 245, 249))
  dark_surfaces <- list(c(23, 32, 51), c(30, 41, 59), c(11, 18, 32))
  list(
    primary = base,
    `primary-text-light` = readable_on(light_surfaces, c(0, 0, 0)),
    `primary-text-dark` = readable_on(dark_surfaces, c(255, 255, 255)),
    `text-inverse` = if (white_label) "#ffffff" else hex(dark_text),
    `primary-hover` = hex(hover),
    `primary-subtle` = rgba(0.12),
    `primary-ring` = rgba(0.2),
    `primary-tint` = rgba(0.12),
    `focus-ring` = base,
    `border-focus` = base,
    `connector-color` = base,
    `port-ring` = rgba(0.35),
    suggested = base,
    `suggested-hover` = base,
    `suggested-glow` = rgba(0.5)
  )
}

# Map a bslib::bs_theme() (including one built from _brand.yml) onto tokens.
sv_theme_from_bslib <- function(theme) {
  if (!requireNamespace("bslib", quietly = TRUE)) {
    stop("A bslib theme needs the bslib package.", call. = FALSE)
  }
  vals <- tryCatch(
    bslib::bs_get_variables(theme, c("primary", "body-bg", "font-family-base", "font-family-monospace")),
    error = function(e) NULL
  )
  ok <- function(v) !is.null(v) && length(v) == 1L && !is.na(v) && nzchar(v) && !grepl("[;{}<>$]", v)
  mode <- "auto"
  if (ok(vals[["body-bg"]])) {
    bg <- tryCatch(grDevices::col2rgb(vals[["body-bg"]])[, 1], error = function(e) NULL)
    if (!is.null(bg)) mode <- if (sv_rel_luminance(bg) < 0.4) "dark" else "light"
  }
  args <- list(mode = mode)
  if (ok(vals[["primary"]]) && !is.null(tryCatch(grDevices::col2rgb(vals[["primary"]]), error = function(e) NULL))) {
    args$primary <- vals[["primary"]]
  }
  if (ok(vals[["font-family-base"]])) args$font <- vals[["font-family-base"]]
  if (ok(vals[["font-family-monospace"]])) args$font_mono <- vals[["font-family-monospace"]]
  do.call(sv_theme, args)
}

# WCAG relative luminance of an sRGB colour given as 0-255 integers.
sv_rel_luminance <- function(rgb) {
  ch <- rgb / 255
  ch <- ifelse(ch <= 0.03928, ch / 12.92, ((ch + 0.055) / 1.055)^2.4)
  sum(c(0.2126, 0.7152, 0.0722) * ch)
}

# TRUE / FALSE for the RStudio editor theme, NA outside RStudio.
sv_rstudio_is_dark <- function() {
  if (!requireNamespace("rstudioapi", quietly = TRUE) || !rstudioapi::isAvailable()) return(NA)
  info <- tryCatch(rstudioapi::getThemeInfo(), error = function(e) NULL)
  if (is.null(info) || is.null(info$dark)) NA else isTRUE(info$dark)
}

# Normalise the `theme` argument. With rstudio = TRUE an "auto" mode is
# resolved from the RStudio editor theme when one is available.
sv_resolve_theme <- function(theme = "auto", rstudio = FALSE) {
  if (is.null(theme)) theme <- "auto"
  if (inherits(theme, "bs_theme")) theme <- sv_theme_from_bslib(theme)
  if (is.character(theme) && length(theme) == 1L) {
    theme <- sv_theme(mode = match.arg(tolower(theme), c("auto", "light", "dark")))
  }
  if (!inherits(theme, "sv_theme")) {
    stop("`theme` must be \"auto\", \"light\", \"dark\", sv_theme() or a bslib::bs_theme().", call. = FALSE)
  }
  if (isTRUE(rstudio) && identical(theme$mode, "auto")) {
    dark <- sv_rstudio_is_dark()
    if (!is.na(dark)) theme$mode <- if (dark) "dark" else "light"
  }
  theme
}

# Inline style carrying the token overrides on the container element.
sv_theme_style <- function(theme) {
  if (!length(theme$vars)) return(NULL)
  paste0(sprintf("--sv-%s: %s;", names(theme$vars), unlist(theme$vars, use.names = FALSE)), collapse = " ")
}
