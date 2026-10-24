# Design tokens, dark theme and contrast. These read inst/www/sideview.css
# directly, so a token that is used but never defined, or a text colour that
# drops below WCAG AA, fails here rather than in a screenshot.

sv_css_text <- function() {
  path <- system.file("www", "sideview.css", package = "sideview")
  if (!nzchar(path)) path <- testthat::test_path("..", "..", "inst", "www", "sideview.css")
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

# Declarations of the first block whose selector line matches `selector` exactly.
sv_css_block <- function(css, selector) {
  lines <- strsplit(css, "\n", fixed = TRUE)[[1]]
  start <- which(trimws(lines) == paste0(selector, " {"))[1]
  if (is.na(start)) return(NULL)
  end <- start + which(trimws(lines[(start + 1):length(lines)]) == "}")[1]
  body <- lines[(start + 1):(end - 1)]
  body <- body[grepl("^\\s*--sv-[a-z0-9-]+\\s*:", body)]
  vals <- trimws(sub(";\\s*$", "", sub("^[^:]+:", "", body)))
  stats::setNames(vals, trimws(sub(":.*$", "", body)))
}

sv_parse_colour <- function(x) {
  x <- trimws(x)
  # var(--sv-override, fallback): the stylesheet default is the fallback.
  if (grepl("^var\\(", x)) x <- trimws(sub("\\)$", "", sub("^var\\([^,]+,", "", x)))
  if (grepl("^rgba?\\(", x)) {
    n <- as.numeric(strsplit(gsub("rgba?\\(|\\)|\\s", "", x), ",")[[1]])
    return(c(n[1:3], if (length(n) > 3) n[4] else 1))
  }
  c(grDevices::col2rgb(x)[, 1], 1)
}

# Composite a possibly translucent colour over an opaque background.
sv_flatten <- function(fg, bg) {
  a <- fg[4]
  c(fg[1:3] * a + bg[1:3] * (1 - a), 1)
}

sv_contrast <- function(fg, bg, under) {
  bgc <- sv_parse_colour(bg)
  if (bgc[4] < 1) bgc <- sv_flatten(bgc, sv_parse_colour(under))
  fgc <- sv_parse_colour(fg)
  if (fgc[4] < 1) fgc <- sv_flatten(fgc, bgc)
  l1 <- sideview:::sv_rel_luminance(fgc[1:3])
  l2 <- sideview:::sv_rel_luminance(bgc[1:3])
  (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

test_that("every --sv-* token used in CSS and JS is defined on the container", {
  css <- sv_css_text()
  light <- sv_css_block(css, ".sideview-container")
  expect_gt(length(light), 50)

  js_path <- system.file("www", "sideview.js", package = "sideview")
  if (!nzchar(js_path)) js_path <- testthat::test_path("..", "..", "inst", "www", "sideview.js")
  js <- paste(readLines(js_path, warn = FALSE), collapse = "\n")

  used <- unique(unlist(regmatches(c(css, js), gregexpr("var\\(--sv-[a-z0-9-]+", c(css, js)))))
  used <- sub("^var\\(", "", used)
  # Layout sizes measured at runtime by sideview.js; every use has a fallback.
  # sv_theme() overrides that are only read through var(name, fallback).
  runtime <- c("--sv-topbar-h", "--sv-aibar-h", "--sv-primary-text-light", "--sv-primary-text-dark")
  missing <- setdiff(used, c(names(light), runtime))
  expect_identical(missing, character(0))
})

test_that("dark tokens override light ones only, and auto mirrors dark", {
  css <- sv_css_text()
  light <- sv_css_block(css, ".sideview-container")
  dark <- sv_css_block(css, ".sideview-container.sv-theme-dark")
  auto <- sv_css_block(css, ".sideview-container.sv-theme-auto")
  expect_gt(length(dark), 40)
  expect_identical(setdiff(names(dark), names(light)), character(0))
  expect_identical(auto, dark)
  expect_match(css, "@media (prefers-color-scheme: dark)", fixed = TRUE)
})

test_that("CSS rules use tokens rather than hard-coded colours", {
  css <- sv_css_text()
  lines <- strsplit(css, "\n", fixed = TRUE)[[1]]
  decl <- lines[grepl(":", lines) & grepl(";\\s*$", lines) & !grepl("^\\s*--sv-", lines)]
  decl <- sub("/\\*.*\\*/", "", decl)
  values <- sub("^[^:]*:", "", decl)
  hard <- decl[grepl("#[0-9a-fA-F]{3,8}\\b|rgba?\\(|(^|[\\s,])(white|black)\\s*(;|$|!)", values, perl = TRUE)]
  expect_identical(trimws(hard), character(0))
})

test_that("text colours meet WCAG AA (4.5:1) in light and dark themes", {
  css <- sv_css_text()
  light <- sv_css_block(css, ".sideview-container")
  dark <- c(sv_css_block(css, ".sideview-container.sv-theme-dark"))
  dark <- c(dark, light[setdiff(names(light), names(dark))])

  pairs <- list(
    c("--sv-text", "--sv-surface"),
    c("--sv-text", "--sv-canvas-bg"),
    c("--sv-text", "--sv-th-bg"),
    c("--sv-text", "--sv-row-hover"),
    c("--sv-text-muted", "--sv-surface"),
    c("--sv-text-muted", "--sv-surface-secondary"),
    c("--sv-text-muted", "--sv-th-bg"),
    c("--sv-text-inverse", "--sv-primary"),
    c("--sv-text-inverse", "--sv-primary-hover"),
    c("--sv-primary-text", "--sv-surface"),
    c("--sv-primary-text", "--sv-primary-subtle"),
    c("--sv-primary-text", "--sv-surface-secondary"),
    c("--sv-danger-text", "--sv-surface"),
    c("--sv-success-btn-text", "--sv-success-btn-bg"),
    c("--sv-success-btn-text", "--sv-success-btn-hover"),
    c("--sv-badge-type-text", "--sv-badge-type-bg"),
    c("--sv-cat-text", "--sv-cat-bg"),
    c("--sv-na-text", "--sv-na-bg"),
    c("--sv-na-high-text", "--sv-na-high-bg"),
    c("--sv-code-text", "--sv-code-bg"),
    c("--sv-tooltip-text", "--sv-tooltip-bg")
  )
  for (theme in list(list(name = "light", t = light), list(name = "dark", t = dark))) {
    for (p in pairs) {
      ratio <- sv_contrast(theme$t[[p[1]]], theme$t[[p[2]]], under = theme$t[["--sv-surface"]])
      expect_true(ratio >= 4.5, label = sprintf("%s: %s on %s = %.2f", theme$name, p[1], p[2], ratio))
    }
  }
})

test_that("sv_theme() validates modes and token overrides", {
  th <- sv_theme("dark", primary = "#0f766e", radius = "4px", canvas_bg = "#fafafa")
  expect_s3_class(th, "sv_theme")
  expect_identical(th$mode, "dark")
  expect_identical(th$vars$primary, "#0f766e")
  expect_identical(th$vars$`canvas-bg`, "#fafafa")
  expect_identical(th$vars$radius, "4px")
  expect_match(th$vars$`primary-ring`, "^rgba\\(15, 118, 110, 0.2\\)$")
  expect_output(print(th), "--sv-primary: #0f766e")

  expect_error(sv_theme("sepia"))
  expect_error(sv_theme(primary = "not-a-colour"), "not a colour")
  expect_error(sv_theme(canvas_bg = "red; background: url(x)"), "single CSS value")
  expect_error(sv_theme(canvas_bg = c("red", "blue")), "single CSS value")
  expect_error(sv_theme("light", "#fff"), NA) # positional primary is allowed
  expect_error(do.call(sv_theme, list("light", NULL, NULL, NULL, NULL, "#fff")), "must be named")
})

test_that("a custom primary gets a legible label colour on base and hover", {
  for (col in c("#f59e0b", "#0f766e", "#fde047", "#1e3a8a", "#ef4444", "#22c55e")) {
    v <- sv_theme(primary = col)$vars
    for (bg in c(v$primary, v$`primary-hover`)) {
      ratio <- sv_contrast(v$`text-inverse`, bg, under = "#ffffff")
      expect_true(ratio >= 4.5, label = sprintf("%s on %s = %.2f", v$`text-inverse`, bg, ratio))
    }
  }
  expect_identical(sv_theme(primary = "#f59e0b")$vars$`text-inverse`, "#0b1220")
  for (col in c("#f59e0b", "#fde047", "#1e3a8a", "#0f766e")) {
    v <- sv_theme(primary = col)$vars
    for (bg in c("#ffffff", "#f1f5f9", "rgba(0, 0, 0, 0)")) {
      expect_true(sv_contrast(v$`primary-text-light`, bg, under = "#ffffff") >= 4.5, label = paste(col, "light text"))
    }
    for (bg in c("#172033", "#1e293b", "#0b1220")) {
      expect_true(sv_contrast(v$`primary-text-dark`, bg, under = "#172033") >= 4.5, label = paste(col, "dark text"))
    }
  }
  expect_identical(sv_theme(primary = "#1e3a8a")$vars$`text-inverse`, "#ffffff")
})

test_that("sv_resolve_theme() accepts strings, sv_theme and bslib themes", {
  expect_identical(sideview:::sv_resolve_theme(NULL)$mode, "auto")
  expect_identical(sideview:::sv_resolve_theme("DARK")$mode, "dark")
  expect_identical(sideview:::sv_resolve_theme(sv_theme("light"))$mode, "light")
  expect_error(sideview:::sv_resolve_theme(42), "must be")
  # Outside RStudio an auto theme stays auto and is left to prefers-color-scheme.
  local_mocked_bindings(sv_rstudio_is_dark = function() NA, .package = "sideview")
  expect_identical(sideview:::sv_resolve_theme("auto", rstudio = TRUE)$mode, "auto")
  local_mocked_bindings(sv_rstudio_is_dark = function() TRUE, .package = "sideview")
  expect_identical(sideview:::sv_resolve_theme("auto", rstudio = TRUE)$mode, "dark")
  expect_identical(sideview:::sv_resolve_theme("light", rstudio = TRUE)$mode, "light")

  skip_if_not_installed("bslib")
  bs <- bslib::bs_theme(bg = "#111111", fg = "#eeeeee", primary = "#f59e0b")
  th <- sideview:::sv_resolve_theme(bs)
  expect_identical(th$mode, "dark")
  expect_identical(th$vars$primary, "#f59e0b")
  light_bs <- sideview:::sv_resolve_theme(bslib::bs_theme(primary = "#0d6efd"))
  expect_identical(light_bs$mode, "light")
})

test_that("sideview_ui() and sideview_widget() carry the theme", {
  html <- as.character(sideview_ui(list(a = data.frame(x = 1)), theme = sv_theme("dark", primary = "#0f766e")))
  expect_match(html, "sideview-container sv-standalone sv-theme-dark", fixed = TRUE)
  expect_match(html, 'data-sv-theme="dark"', fixed = TRUE)
  expect_match(html, "--sv-primary: #0f766e;", fixed = TRUE)

  default_html <- as.character(sideview_ui(list(a = data.frame(x = 1))))
  expect_match(default_html, "sv-theme-auto", fixed = TRUE)
  # Swatches are real buttons with accessible names and pressed state.
  expect_match(default_html, '<button type="button" class="sideview-swatch sideview-swatch-blue"', fixed = TRUE)
  expect_match(default_html, 'aria-label="Highlight blue" aria-pressed="false"', fixed = TRUE)
  expect_match(default_html, 'role="group" aria-label="Highlight colour"', fixed = TRUE)
  expect_match(default_html, 'aria-label="Zoom in"', fixed = TRUE)

  w <- sideview_widget(a = data.frame(x = 1), theme = sv_theme("light", radius = "2px"))
  expect_identical(w$x$options$theme, "light")
  expect_identical(w$x$options$themeVars$`--sv-radius`, "2px")
  w2 <- sideview_widget(a = data.frame(x = 1))
  expect_identical(w2$x$options$theme, "auto")
  expect_null(w2$x$options$themeVars)
  # An explicit options$theme wins over the argument.
  w3 <- sideview_widget(a = data.frame(x = 1), options = list(theme = "dark"))
  expect_identical(w3$x$options$theme, "dark")
})
