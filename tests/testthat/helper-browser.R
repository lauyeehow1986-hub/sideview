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
sv_start_app <- function(app_expr = "sideview(patients, visits, labs, run = FALSE)") {
  port <- httpuv::randomPort()
  proc <- callr::r_bg(
    function(root, fixture, app_expr, port) {
      if (nzchar(root)) {
        suppressMessages(pkgload::load_all(root, quiet = TRUE, export_all = FALSE))
      } else {
        suppressMessages(library(sideview))
      }
      eval(parse(text = fixture), envir = globalenv())
      app <- eval(parse(text = app_expr), envir = globalenv())
      shiny::runApp(app, port = port, launch.browser = FALSE)
    },
    args = list(root = sv_pkg_root(), fixture = sv_fixture_code, app_expr = app_expr, port = port),
    stdout = "|", stderr = "|"
  )
  url <- sprintf("http://127.0.0.1:%d", port)
  ok <- FALSE
  for (i in 1:120) {
    if (!proc$is_alive()) break
    ok <- tryCatch({
      con <- url(url); on.exit(try(close(con), silent = TRUE), add = TRUE)
      length(readLines(con, n = 1, warn = FALSE)) > 0
    }, error = function(e) FALSE)
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

# Open a headless Chrome tab at a given viewport size and wait for the engine.
sv_open_page <- function(url, width = 1400, height = 900, wait_for = "window.sideviewInitialized === true") {
  b <- chromote::ChromoteSession$new(width = width, height = height)
  b$Runtime$enable()
  errors <- character()
  b$Runtime$exceptionThrown(callback_ = function(msg) {
    errors <<- c(errors, msg$exceptionDetails$exception$description %||% msg$exceptionDetails$text)
  }, wait_ = FALSE)
  b$Page$navigate(url, wait_ = FALSE)
  b$Page$loadEventFired()
  ready <- FALSE
  for (i in 1:60) {
    ready <- isTRUE(sv_js(b, wait_for))
    if (ready) break
    Sys.sleep(0.25)
  }
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
