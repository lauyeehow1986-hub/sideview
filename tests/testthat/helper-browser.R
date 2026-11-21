# Real-browser test helpers (chromote + callr).
# The mock-DOM GUI suite cannot see layout; these helpers run the actual
# gadget in a background R process and drive it with headless Chrome.

skip_if_no_browser <- function() {
  testthat::skip_on_cran()
  for (pkg in c("chromote", "callr", "pkgload")) {
    if (!requireNamespace(pkg, quietly = TRUE)) testthat::skip(paste(pkg, "not installed"))
  }
  chrome <- tryCatch(chromote::find_chrome(), error = function(e) NULL)
  if (is.null(chrome) || !nzchar(chrome)) testthat::skip("Chrome not found")
  invisible(TRUE)
}

# The source tree when testing from it (devtools::test()), or "" under
# R CMD check, where the tests run against the installed package.
sv_pkg_root <- function() {
  root <- normalizePath(testthat::test_path("..", ".."), winslash = "/", mustWork = TRUE)
  if (file.exists(file.path(root, "DESCRIPTION")) && dir.exists(file.path(root, "inst"))) root else ""
}

# Synthetic fixture (no real data). Keep in sync with the QA checklist.
sv_fixture_code <- '
set.seed(42)
n_pat <- 200
patients <- data.frame(
  patient_id = sprintf("P%05d", seq_len(n_pat)),
  sex = sample(c("Male", "Female", "male", "F", NA), n_pat, TRUE),
  age = round(rnorm(n_pat, 55, 15)),
  site = sample(c("North", "South", "East", "West"), n_pat, TRUE),
  stringsAsFactors = FALSE
)
visits <- data.frame(
  visit_id = seq_len(600),
  pid = sample(c(patients$patient_id, " P00001", "p00002", "P99999"), 600, TRUE),
  sbp = round(rnorm(600, 130, 18)),
  stringsAsFactors = FALSE
)
labs <- data.frame(
  patient_id = sample(patients$patient_id, 5000, TRUE),
  test = sample(c("HbA1c", "LDL", "eGFR", "CRP"), 5000, TRUE),
  value = round(rlnorm(5000, 1.5, 0.6), 2),
  stringsAsFactors = FALSE
)
'

# Start the gadget app in a background R process; returns list(proc, url).
sv_start_app <- function(app_expr = "sideview(patients, visits, labs, run = FALSE)", app_file = NULL) {
  port <- httpuv::randomPort()
  proc <- callr::r_bg(
    function(root, fixture, app_expr, app_file, port) {
      if (nzchar(root)) {
        suppressMessages(pkgload::load_all(root, quiet = TRUE, export_all = FALSE))
      } else {
        suppressMessages(library(sideview))
      }
      eval(parse(text = fixture), envir = globalenv())
      if (!is.null(app_file)) {
        return(shiny::runApp(dirname(app_file), port = port, launch.browser = FALSE))
      }
      app <- eval(parse(text = app_expr), envir = globalenv())
      shiny::runApp(app, port = port, launch.browser = FALSE)
    },
    args = list(root = sv_pkg_root(), fixture = sv_fixture_code, app_expr = app_expr,
                app_file = app_file, port = port),
    stdout = "|", stderr = "|"
  )
  url <- sprintf("http://127.0.0.1:%d", port)
  ok <- FALSE
  for (i in 1:480) {  # up to ~2 min: a cold R start is slow under load
    if (!proc$is_alive()) break
    con <- url(url)
    ok <- tryCatch(length(readLines(con, n = 1, warn = FALSE)) > 0,
                   warning = function(w) FALSE, error = function(e) FALSE)  # not listening yet
    try(close(con), silent = TRUE)
    if (isTRUE(ok)) break
    Sys.sleep(0.25)
  }
  if (!isTRUE(ok)) {
    err <- tryCatch(proc$read_all_error(), error = function(e) "")
    proc$kill()
    stop("sideview test app failed to start: ", err)
  }
  list(proc = proc, url = url)
}

# Generous protocol timeouts. chromote's default is 10 s per command or awaited
# event, which a loaded machine (full test suite, R CMD check, parallel Chrome)
# overruns: "timed out waiting for Page.loadEventFired". One place to tune it.
sv_browser_timeout <- function() as.numeric(Sys.getenv("SIDEVIEW_BROWSER_TIMEOUT", "90"))

# Navigate and wait for the load event, retrying once (a slow first paint under
# load is the usual cause; a second attempt almost always succeeds).
sv_navigate <- function(b, url, attempts = 2) {
  err <- NULL
  for (i in seq_len(attempts)) {
    ok <- tryCatch({
      b$Page$navigate(url, wait_ = FALSE)
      b$Page$loadEventFired(timeout_ = sv_browser_timeout())
      TRUE
    }, error = function(e) { err <<- e; FALSE })
    if (ok) return(invisible(TRUE))
  }
  stop(err)
}

# Poll a JS condition until true or `timeout` seconds pass (no fixed sleeps).
sv_wait_js <- function(b, expr, timeout = 30, interval = 0.1) {
  deadline <- Sys.time() + timeout
  repeat {
    ok <- isTRUE(tryCatch(sv_js(b, expr), error = function(e) FALSE))
    if (ok || Sys.time() > deadline) return(ok)
    Sys.sleep(interval)
  }
}

# Open a headless Chrome tab at a given viewport size and wait for the engine.
sv_open_page <- function(url, width = 1400, height = 900, wait_for = "window.sideviewInitialized === true") {
  b <- NULL
  for (i in 1:2) {
    b <- tryCatch(chromote::ChromoteSession$new(width = width, height = height),
                  error = function(e) if (i == 2) stop(e) else NULL)
    if (!is.null(b)) break
  }
  b$default_timeout <- sv_browser_timeout()
  b$Runtime$enable()
  errors <- character()
  b$Runtime$exceptionThrown(callback_ = function(msg) {
    errors <<- c(errors, msg$exceptionDetails$exception$description %||% msg$exceptionDetails$text)
  }, wait_ = FALSE)
  sv_navigate(b, url)
  ready <- sv_wait_js(b, wait_for, timeout = 60)
  attr(b, "sv_errors") <- function() errors
  attr(b, "sv_ready") <- ready
  b
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# Evaluate JS (expression or async IIFE) and return its value.
sv_js <- function(b, expr) {
  res <- b$Runtime$evaluate(expr, returnByValue = TRUE, awaitPromise = TRUE)
  if (!is.null(res$exceptionDetails)) {
    stop("JS error: ", res$exceptionDetails$exception$description %||% res$exceptionDetails$text)
  }
  res$result$value
}

sv_set_viewport <- function(b, width, height) {
  b$Emulation$setDeviceMetricsOverride(width = width, height = height, deviceScaleFactor = 1, mobile = FALSE)
  Sys.sleep(0.4)
}

# JS snippet: find a card element by table name.
sv_card_js <- function(name) {
  sprintf("[...document.querySelectorAll('.sideview-card')].find(c => c.getAttribute('data-card-name') === '%s' || (c.querySelector('.sideview-card-title')||{}).textContent === '%s')", name, name)
}

# The example app (inst/examples/<name>/app.R): from the source tree, or the installed package.
sv_example_app <- function(name = "proxy") {
  root <- sv_pkg_root()
  path <- if (nzchar(root)) file.path(root, "inst", "examples", name, "app.R") else
    system.file("examples", name, "app.R", package = "sideview")
  if (!nzchar(path) || !file.exists(path)) stop("example app not found: ", name, call. = FALSE)
  normalizePath(path, winslash = "/")
}


# ---- the Stack drawer tab (D2): shared by the layout and a11y browser tests ----

sv_stk_wave1 <- "data.frame(id = 1:3, age = c(34, 51, 62), Race = c('A', 'B', 'C'), stringsAsFactors = FALSE)"
sv_stk_wave2 <- "data.frame(id = 4:5, age = c('45', 'n/a'), RACE = c('A', 'B'), stringsAsFactors = FALSE)"
sv_stk_app <- paste0(
  "local({ wave1 <- ", sv_stk_wave1, "; wave2 <- ", sv_stk_wave2, ";",
  "sideview(wave1, wave2, run = FALSE) })")
# Rows of the stack of both fixtures: the sum the new card's badge must show.
sv_stk_total_rows <- function() nrow(eval(parse(text = sv_stk_wave1))) + nrow(eval(parse(text = sv_stk_wave2)))

# Real mouse click on the centre of the first element matching `sel`.
sv_stk_click <- function(b, sel) {
  q <- as.character(jsonlite::toJSON(sel, auto_unbox = TRUE))
  ok <- sv_wait_js(b, sprintf("(() => { const x = document.querySelector(%s); if (!x || x.disabled) return false;
    x.scrollIntoView({block: 'center'}); const r = x.getBoundingClientRect();
    const h = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    return !!h && (h === x || x.contains(h) || (!!h.closest('label') && h.closest('label').contains(x))); })()", q), timeout = 30)
  testthat::expect_true(ok, info = sel)
  pt <- sv_js(b, sprintf("(() => { const r = document.querySelector(%s).getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()", q))
  for (type in c("mousePressed", "mouseReleased")) {
    b$Input$dispatchMouseEvent(type = type, x = pt$x, y = pt$y, button = "left", clickCount = 1)
  }
}

sv_stk_open_tab <- function(b) {
  sv_js(b, "document.querySelector('.sideview-drawer').classList.remove('collapsed'); true")
  # the drawer fades in over 200 ms: a click in that time can miss
  testthat::expect_true(sv_wait_js(b, "getComputedStyle(document.querySelector('.sideview-drawer')).opacity === '1' && document.querySelector('.sideview-drawer').getAnimations().length === 0", timeout = 30))
  sv_stk_click(b, ".sideview-drawer-tab[data-tab=stack]")
  testthat::expect_true(sv_wait_js(b, "!!document.querySelector('[data-pane=stack] [data-stack-pick]')", timeout = 30))
}

sv_stk_pick_check <- function(b) {
  sv_stk_click(b, "[data-stack-pick=wave2]")
  sv_stk_click(b, "[data-stack-pick=wave1]")
  sv_stk_click(b, "[data-stack-action=check]")
  testthat::expect_true(sv_wait_js(b, "!!document.querySelector('.sideview-stack-table')", timeout = 60))
}


# ---- the Compare drawer tab (D3): shared by the layout and a11y browser tests ----

# Two synthetic cuts of an AE table. By USUBJID + AESEQ: S4 is added, S3 removed, (S1, 1) changed in AESEV.
# Without AESEQ the key USUBJID repeats (S1 has two rows). The AE tag lets R suggest USUBJID + AESEQ.
sv_cmp_cut1 <- "data.frame(USUBJID = c('S1', 'S1', 'S2', 'S3'), AESEQ = c(1L, 2L, 1L, 1L), AESEV = c('MILD', 'MILD', 'SEVERE', 'MILD'), stringsAsFactors = FALSE)"
sv_cmp_cut2 <- "data.frame(USUBJID = c('S1', 'S1', 'S2', 'S4'), AESEQ = c(1L, 2L, 1L, 1L), AESEV = c('MODERATE', 'MILD', 'SEVERE', 'MILD'), stringsAsFactors = FALSE)"
sv_cmp_app <- paste0(
  "local({ cut1 <- ", sv_cmp_cut1, "; cut2 <- ", sv_cmp_cut2, ";",
  "sideview(cut1, cut2, cdisc = c(cut1 = 'AE', cut2 = 'AE'), run = FALSE) })")

sv_cmp_open_tab <- function(b) {
  sv_js(b, "document.querySelector('.sideview-drawer').classList.remove('collapsed'); true")
  testthat::expect_true(sv_wait_js(b, "getComputedStyle(document.querySelector('.sideview-drawer')).opacity === '1' && document.querySelector('.sideview-drawer').getAnimations().length === 0", timeout = 30))
  sv_stk_click(b, ".sideview-drawer-tab[data-tab=compare]")
  testthat::expect_true(sv_wait_js(b, "!!document.querySelector('[data-pane=compare] [data-compare-select]')", timeout = 30))
}

# Pick the two versions through their selects (a native select popup takes no synthetic mouse), then press Check.
sv_cmp_pick_check <- function(b, old = "cut1", new = "cut2") {
  for (side in c("old", "new")) {
    v <- if (side == "old") old else new
    sv_js(b, sprintf("(() => { const s = document.querySelector('[data-compare-select=%s]'); s.focus(); s.value = %s; s.dispatchEvent(new Event('change', {bubbles: true})); return true; })()",
                     side, as.character(jsonlite::toJSON(v, auto_unbox = TRUE))))
  }
  sv_stk_click(b, "[data-compare-action=check]")
  testthat::expect_true(sv_wait_js(b, "!!document.querySelector('[data-compare-result] .sideview-compare-text')", timeout = 60))
}

sv_cmp_text <- function(b) {
  paste(unlist(sv_js(b, "[...document.querySelectorAll('.sideview-compare-text li')].map(x => x.textContent)")), collapse = " | ")
}

sv_cmp_eng <- "document.querySelector('.sideview-container')._sideviewInstance"
