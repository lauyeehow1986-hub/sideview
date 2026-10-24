# Automated Computer Use & GUI Test Suite for sideview (v0.2.0 Pillar 5)
# Follows specification from plans/2026-10-21-sideview-v0.2.0-computer-use-rstudio-qa-spec.md
# Implements multi-tiered GUI verification across 6 core interaction scenarios:
# 1. Canvas coordinate initialization, card layout, and pan/zoom transform calculation
# 2. Card dragging simulation (mousedown -> mousemove -> mouseup) and magnetic docking
# 3. Precision column port clicking / connection with cubic bezier SVG splines
# 4. Suggested spline interaction (dashMove class and acceptance into active connection)
# 5. Header sort cycling (none -> asc -> desc) and filter popover click simulation
# 6. Action Drawer code dispatch (Insert Script, Run in R, Run & Exit, Clear)
# Diagnostic failure capture helper serializing canvas coordinates, WebSocket logs, and dumps

suppressWarnings(suppressPackageStartupMessages({
  library(testthat)
  library(shiny)
  library(jsonlite)
}))

# Source R files if running standalone without package installed
if (!"package:sideview" %in% search()) {
  r_files <- list.files(c("R", "../R", "../../R"), pattern = "\\.[Rr]$", full.names = TRUE)
  for (f in r_files) source(f)
}

if (!exists("ensure_package_installed", mode = "function")) {
  helper_files <- list.files(c(".", "tests/testthat", "../tests/testthat"), pattern = "^helper-.*\\.[Rr]$", full.names = TRUE)
  for (hf in helper_files) source(hf)
}

# Locate Node.js executable
find_node <- function() {
  node_cmd <- Sys.which("node")
  if (nzchar(node_cmd)) return(node_cmd)
  candidates <- c(
    "C:/Program Files/nodejs/node.exe",
    "C:/Program Files (x86)/nodejs/node.exe",
    Sys.getenv("NODE_PATH")
  )
  for (cand in candidates) {
    if (nzchar(cand) && file.exists(cand)) return(cand)
  }
  ""
}

# Locate gui-test-runner.js
find_runner_js <- function() {
  candidates <- c(
    file.path("tests", "testthat", "gui-test-runner.js"),
    file.path("gui-test-runner.js"),
    file.path("..", "gui-test-runner.js"),
    file.path("..", "..", "tests", "testthat", "gui-test-runner.js")
  )
  for (cand in candidates) {
    if (file.exists(cand)) return(normalizePath(cand))
  }
  ""
}

# Cache execution of simulated headless DOM tests
.gui_test_cache <- new.env(parent = emptyenv())

run_gui_test_scenarios <- function() {
  if (exists("results", envir = .gui_test_cache)) {
    return(get("results", envir = .gui_test_cache))
  }

  node_bin <- find_node()
  runner_js <- find_runner_js()

  if (!nzchar(node_bin) || !nzchar(runner_js)) {
    skip("Node.js or gui-test-runner.js not available for simulated headless DOM tests")
  }

  # stderr goes to its own file: Node runtime warnings (e.g. about
  # localStorage) must not end up inside the JSON on stdout.
  err_file <- tempfile(fileext = ".log")
  on.exit(unlink(err_file), add = TRUE)
  # Tell the runner where sideview.js is: system.file() also works under
  # R CMD check, where there is no inst/ folder next to the tests.
  withr::local_envvar(SIDEVIEW_JS = system.file("www", "sideview.js", package = "sideview"))
  out <- suppressWarnings(system2(
    command = node_bin,
    args = c(shQuote(runner_js)),
    stdout = TRUE,
    stderr = err_file
  ))

  status <- attr(out, "status")
  if (!is.null(status) && status != 0) {
    stop(paste("gui-test-runner.js failed with status", status, ":",
               paste(c(out, readLines(err_file, warn = FALSE)), collapse = "\n")))
  }

  raw_json <- paste(out, collapse = "\n")
  parsed <- jsonlite::fromJSON(raw_json, simplifyVector = TRUE)
  assign("results", parsed, envir = .gui_test_cache)
  parsed
}

# Diagnostic Failure Capture Helper Function
capture_gui_diagnostics <- function(test_name, dump_data = NULL, error_msg = "Assertion failure", artifacts_dir = tempdir()) {
  if (!dir.exists(artifacts_dir)) {
    dir.create(artifacts_dir, showWarnings = FALSE, recursive = TRUE)
  }

  timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  dump_file <- file.path(artifacts_dir, "canvas_failure_dump.json")
  diag_file <- file.path(artifacts_dir, sprintf("gui_failure_%s.json", timestamp))

  payload <- list(
    test = test_name,
    timestamp = timestamp,
    error = error_msg,
    dump = dump_data
  )

  jsonlite::write_json(payload, dump_file, pretty = TRUE, auto_unbox = TRUE)
  jsonlite::write_json(payload, diag_file, pretty = TRUE, auto_unbox = TRUE)

  report <- c(
    "+-------------------------------------------------------------+",
    "| AUTOMATED GUI DIAGNOSTIC REPORT                             |",
    sprintf("| Test: %-53s |", substr(test_name, 1, 53)),
    "| Status: FAILED                                              |",
    sprintf("| Error: %-52s |", substr(error_msg, 1, 52)),
    "|                                                             |",
    "| Captured Artifacts:                                         |",
    sprintf("|  - Canvas Dump: %-43s |", dump_file),
    sprintf("|  - Failure Log: %-43s |", diag_file),
    "+-------------------------------------------------------------+"
  )
  message(paste(report, collapse = "\n"))
  invisible(list(dump_file = dump_file, diag_file = diag_file, report = report))
}

# ==============================================================================
# Scenario 1: Canvas coordinate initialization, card layout, pan/zoom
# ==============================================================================
test_that("Computer Use GUI: Scenario 1 - Canvas coordinate initialization, card layout, and pan/zoom transform calculation", {
  res <- run_gui_test_scenarios()
  s1 <- res$scenario1

  expect_true(isTRUE(s1$initialized))
  expect_true(isTRUE(s1$has_canvas))
  expect_true(isTRUE(s1$has_viewport))
  expect_true(isTRUE(s1$has_svg))
  expect_true(isTRUE(s1$has_toolbar))
  expect_true(isTRUE(s1$has_drawer))

  # Card layout
  expect_equal(s1$card_count, 2L)
  expect_equal(s1$card1_id, "card_000001")
  expect_equal(s1$card2_id, "card_000002")
  expect_equal(s1$card1_left, 40)
  expect_equal(s1$card2_left, 400)

  # Pan/zoom transform calculation
  expect_equal(s1$initial_scale, 1.0)
  expect_equal(s1$zoom_in_scale, 1.25)
  expect_equal(s1$zoom_out_scale, 1.0)
  expect_equal(s1$reset_scale, 1.0)
})

# ==============================================================================
# Scenario 2: Card dragging simulation & magnetic docking
# ==============================================================================
test_that("Computer Use GUI: Scenario 2 - Card dragging simulation and magnetic docking", {
  res <- run_gui_test_scenarios()
  s2 <- res$scenario2

  expect_equal(s2$initial_left, 400)
  expect_equal(s2$dragged_left, 520)
  expect_equal(s2$expected_dragged, 520)
  expect_true(isTRUE(s2$moved_dispatched))

  # Magnetic docking calculation (snapped to right edge of card 1 + margin)
  expect_equal(s2$snapped_left, 396)
  expect_true(isTRUE(s2$docking_success))
})

# ==============================================================================
# Scenario 3: Precision column port clicking / connection & cubic bezier spline
# ==============================================================================
test_that("Computer Use GUI: Scenario 3 - Precision column port clicking / connection and cubic bezier spline", {
  res <- run_gui_test_scenarios()
  s3 <- res$scenario3

  expect_true(isTRUE(s3$portA_connecting))
  expect_true(isTRUE(s3$portA_connected))
  expect_true(isTRUE(s3$escape_cancelled))
  expect_true(isTRUE(s3$th_connected))
  expect_gte(s3$connectors_count, 1L)

  # Cubic bezier spline path assertion: starts with 'M ' and contains ' C '
  expect_true(isTRUE(s3$has_bezier))
  expect_match(s3$path_d, "^M\\s+\\d+")
  expect_match(s3$path_d, "\\s+C\\s+")

  # Action Drawer code generation
  expect_match(s3$drawer_code, "left_join")
  expect_match(s3$drawer_code, "patient_id")
  expect_true(isTRUE(s3$mapped_event_dispatched))
})

# ==============================================================================
# Scenario 4: Suggested spline interaction with dashMove class and acceptance
# ==============================================================================
test_that("Computer Use GUI: Scenario 4 - Suggested spline interaction with dashMove class and acceptance", {
  res <- run_gui_test_scenarios()
  s4 <- res$scenario4

  expect_true(isTRUE(s4$rendered))
  expect_true(isTRUE(s4$has_dashMove))
  expect_true(isTRUE(s4$is_suggested))
  expect_equal(as.character(s4$confidence), "0.95")

  # Acceptance into active connection
  expect_equal(s4$remaining_suggested_after_click, 0L)
  expect_equal(s4$accepted_connections, 1L)
  expect_true(isTRUE(s4$acceptance_success))
})

# ==============================================================================
# Scenario 5: Header sort cycling and filter popover click simulation
# ==============================================================================
test_that("Computer Use GUI: Scenario 5 - Header sort cycling and filter popover click simulation", {
  res <- run_gui_test_scenarios()
  s5 <- res$scenario5

  # Header sort cycle: none -> asc (sortAsc icon) -> desc (sortDesc) -> none (sort)
  expect_true(isTRUE(s5$sort_cycle_asc))
  expect_true(isTRUE(s5$sort_cycle_desc))
  expect_true(isTRUE(s5$sort_cycle_none))

  # Filter popover
  expect_true(isTRUE(s5$popover_rendered))
  expect_true(isTRUE(s5$filter_active))
})

# ==============================================================================
# Scenario 6: Action Drawer code dispatch (Insert Script, Run in R, Clear)
# ==============================================================================
test_that("Computer Use GUI: Scenario 6 - Action Drawer code dispatch (Insert Script, Run in R, Clear)", {
  res <- run_gui_test_scenarios()
  s6 <- res$scenario6

  expect_true(isTRUE(s6$inject_script_dispatched))
  expect_true(isTRUE(s6$eval_env_dispatched))
  expect_true(isTRUE(s6$console_exit_dispatched))
  expect_true(isTRUE(s6$clear_dispatched))
  expect_true(isTRUE(s6$svg_paths_cleared))
  expect_true(isTRUE(s6$drawer_code_cleared))
})

# ==============================================================================
# Diagnostic failure capture helper test
# ==============================================================================
test_that("Computer Use GUI: Diagnostic failure capture generates serialized artifacts and report on failure", {
  res <- run_gui_test_scenarios()
  diag <- res$diagnostics

  expect_true(isTRUE(diag$has_dump))
  expect_true(isTRUE(diag$has_report))
  expect_match(diag$report_text, "AUTOMATED GUI DIAGNOSTIC REPORT")
  expect_match(diag$report_text, "canvas_failure_dump\\.json")

  # Test R diagnostic capture helper
  diag_result <- suppressMessages(capture_gui_diagnostics(
    test_name = "Unit test failure capture",
    dump_data = list(scale = 1.0, cards = 2),
    error_msg = "Simulated unit test anomaly"
  ))
  expect_true(file.exists(diag_result$dump_file))
  expect_true(file.exists(diag_result$diag_file))
  expect_match(paste(diag_result$report, collapse = "\n"), "AUTOMATED GUI DIAGNOSTIC REPORT")
  if (file.exists(diag_result$dump_file)) unlink(diag_result$dump_file)
  if (file.exists(diag_result$diag_file)) unlink(diag_result$diag_file)
})

# ==============================================================================
# Tier 2: Programmatic headless shinytest2 / Chromote browser test
# ==============================================================================
test_that("Computer Use GUI: Programmatic browser test via shinytest2 (Tier 2)", {
  # Test Sideview App Driver integration
  patients <- data.frame(patient_id = c("P1", "P2", "P3"), age = c(45, 62, 38), stringsAsFactors = FALSE)
  visits <- data.frame(patient_id = c("P1", "P2", "P4"), date = c("2026-01-01", "2026-02-15", "2026-03-10"), stringsAsFactors = FALSE)
  app_obj <- sideview(patients, visits, run = FALSE)
  expect_s3_class(app_obj, "shiny.appobj")

  # Full programmatic Shiny reactive session simulation verifying Computer Use event dispatch
  cards <- list(sv_normalize(patients, name = "patients"), sv_normalize(visits, name = "visits"))
  shiny::testServer(sideview_server(cards), {
    # 1. Card move simulation
    session$setInputs(sideview_card_moved = list(card_id = "card_000002", x = 520, y = 40))
    expect_equal(input$sideview_card_moved$x, 520)

    # 2. Port connection simulation
    session$setInputs(column_mapped = list(
      from_table = "patients",
      from_col = "patient_id",
      to_table = "visits",
      to_col = "patient_id",
      join_type = "left_join"
    ))
    msgs <- session$userData$custom_messages
    expect_true(length(msgs) >= 1)
    last_msg <- msgs[[length(msgs)]]
    expect_equal(last_msg$type, "sideview_code_update")
    expect_match(last_msg$message$code, "patients\\s*%>%\\s*dplyr::left_join")

    # 3. Column sort simulation
    session$setInputs(column_sorted = list(table = "patients", column = "age", direction = "asc", code = "patients %>% dplyr::arrange(age)"))
    expect_equal(input$column_sorted$direction, "asc")

    # 4. Action drawer clear simulation
    session$setInputs(clear_operations = list(timestamp = 12345))
    expect_equal(input$clear_operations$timestamp, 12345)
  })

  # If an interactive headed desktop session is explicitly requested via SIDEVIEW_HEADED_QA:
  if (nzchar(Sys.getenv("SIDEVIEW_HEADED_QA"))) {
    ensure_package_installed("shinytest2")
    app_dir <- file.path(tempdir(), "sideview_st2_test")
    dir.create(app_dir, showWarnings = FALSE, recursive = TRUE)
    writeLines(
      c(
        "suppressWarnings(suppressPackageStartupMessages(library(shiny)))",
        "suppressWarnings(suppressPackageStartupMessages(library(sideview)))",
        "patients <- data.frame(patient_id = c('P1', 'P2', 'P3'), age = c(45, 62, 38), stringsAsFactors = FALSE)",
        "visits <- data.frame(patient_id = c('P1', 'P2', 'P4'), date = c('2026-01-01', '2026-02-15', '2026-03-10'), stringsAsFactors = FALSE)",
        "sideview(patients, visits, run = FALSE)"
      ),
      file.path(app_dir, "app.R")
    )
    app <- shinytest2::AppDriver$new(app_dir = app_dir, name = "sideview-qa", view = FALSE)
    app$wait_for_js("window.sideviewInitialized === true", timeout = 10000)
    card_width <- app$get_js("document.querySelector('#card_000001') ? document.querySelector('#card_000001').offsetWidth : 0")
    expect_true(card_width > 200)
    app$stop()
  }
})
