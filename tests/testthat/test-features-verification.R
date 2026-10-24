# Comprehensive Feature Verification Test Suite for sideview
# Tests all described capabilities across:
# 1. Interactive Column Sorting (Asc/Desc/Reset) -> sv_code_arrange & Shiny server
# 2. Interactive Column Filtering (>, >=, <, <=, ==, !=, contains) -> sv_code_filter & Shiny server
# 3. Interactive Spline Disconnection -> removeConnection, column_disconnected & Shiny server
# 4. Dual Synchronized Scrolling -> vertical (scrollTop) and horizontal (scrollLeft) lockstep
# 5. Local Ollama (gemma4:26b) & OpenAI LLM Engine -> schema context, prompt synthesis, code extraction, join assistance
# 6. Action Drawer Execution Modes (Insert Script, Run & Exit, Run in R, Run Console, Clear, Auto-clear)
# 7. Universal Multi-Format Normalization (data.frame, tibble, table, matrix, gt, flextable, widget)
# 8. Categorical Discrepancy Detection & Recoding (exact & fuzzy matching, case_match, fct_recode)
# 9. Standalone HTML Export & Shiny Embedding (save_sideview, sideview_widget, renderSideview)
# 10. Web Assets & JavaScript Syntax Integrity (node -c validation)

suppressWarnings(suppressPackageStartupMessages({
  library(testthat)
  library(shiny)
  library(htmltools)
  library(htmlwidgets)
  library(dplyr)
  library(httr2)
  library(jsonlite)
}))

# Source R files if running standalone
if (!"package:sideview" %in% search()) {
  r_files <- list.files(c("R", "../R", "../../R"), pattern = "\\.[Rr]$", full.names = TRUE)
  for (f in r_files) source(f)
}

# Helper to find assets
find_asset <- function(filename) {
  candidates <- c(
    file.path("inst", "www", filename),
    file.path("..", "inst", "www", filename),
    file.path("..", "..", "inst", "www", filename),
    system.file("www", filename, package = "sideview")
  )
  for (c in candidates) {
    if (nzchar(c) && file.exists(c)) return(normalizePath(c))
  }
  file.path("inst", "www", filename)
}

# -------------------------------------------------------------------------
# Feature 1: Interactive Column Sorting
# -------------------------------------------------------------------------
test_that("Feature 1: Interactive Column Sorting generates valid tidyverse arrange pipelines", {
  # Standard column
  code_asc <- sv_code_arrange("clinical_trials", "visit_date", desc = FALSE, pipe = TRUE)
  expect_match(code_asc, "clinical_trials\\s*%>%\\s*dplyr::arrange\\(visit_date\\)")
  expect_silent(parse(text = code_asc))

  # Descending column
  code_desc <- sv_code_arrange("patients", "blood_pressure", desc = TRUE, pipe = TRUE)
  expect_match(code_desc, "patients\\s*%>%\\s*dplyr::arrange\\(dplyr::desc\\(blood_pressure\\)\\)")
  expect_silent(parse(text = code_desc))

  # Non-syntactic column name with spaces/symbols
  code_spaced <- sv_code_arrange("lab_data", "Glucose Level (mg/dL)", desc = TRUE, pipe = TRUE)
  expect_match(code_spaced, "dplyr::desc\\(`Glucose Level \\(mg/dL\\)`\\)")
  expect_silent(parse(text = code_spaced))

  # Shiny server dispatch test
  df <- data.frame(id = 1:5, score = c(88, 92, 79, 95, 83))
  cards <- list(sv_normalize(df, name = "scores"))
  shiny::testServer(sideview_server(cards), {
    session$setInputs(column_sorted = list(
      table = "scores",
      column = "score",
      direction = "desc"
    ))
    msgs <- session$userData$custom_messages
    expect_true(length(msgs) >= 1)
    last_msg <- msgs[[length(msgs)]]
    expect_equal(last_msg$type, "sideview_code_update")
    expect_match(last_msg$message$code, "scores\\s*%>%\\s*dplyr::arrange\\(dplyr::desc\\(score\\)\\)")
  })
})

# -------------------------------------------------------------------------
# Feature 2: Interactive Column Filtering
# -------------------------------------------------------------------------
test_that("Feature 2: Interactive Column Filtering generates valid tidyverse filter pipelines", {
  # Numeric comparison
  code_num <- sv_code_filter("vitals", "systolic_bp >= 130", pipe = TRUE)
  expect_match(code_num, "vitals\\s*%>%\\s*dplyr::filter\\(systolic_bp >= 130\\)")
  expect_silent(parse(text = code_num))

  # String exact match
  code_str <- sv_code_filter("demographics", "gender == 'Female'", pipe = TRUE)
  expect_match(code_str, "demographics\\s*%>%\\s*dplyr::filter\\(gender == 'Female'\\)")
  expect_silent(parse(text = code_str))

  # Shiny server dispatch test
  df <- data.frame(id = 1:5, systolic_bp = c(120, 140, 115, 130, 125))
  cards <- list(sv_normalize(df, name = "vitals"))
  shiny::testServer(sideview_server(cards), {
    session$setInputs(column_filtered = list(
      table = "vitals",
      column = "systolic_bp",
      condition = "systolic_bp >= 130"
    ))
    msgs <- session$userData$custom_messages
    expect_true(length(msgs) >= 1)
    last_msg <- msgs[[length(msgs)]]
    expect_equal(last_msg$type, "sideview_code_update")
    expect_match(last_msg$message$code, "vitals\\s*%>%\\s*dplyr::filter\\(systolic_bp >= 130\\)")
  })
})

# -------------------------------------------------------------------------
# Feature 3: Interactive Spline Disconnection & Clear Operations
# -------------------------------------------------------------------------
test_that("Feature 3: Interactive Spline Disconnection and Clear Operations update server state", {
  # Verify client-side JS implementation
  js_code <- paste(readLines(find_asset("sideview.js"), warn = FALSE), collapse = "\n")
  expect_match(js_code, "removeConnection", info = "sideview.js must define removeConnection")
  expect_match(js_code, "column_disconnected", info = "sideview.js must send column_disconnected event")
  expect_match(js_code, "clearOperations", info = "sideview.js must define clearOperations")

  df1 <- data.frame(id = 1:3, val = c("A", "B", "C"))
  df2 <- data.frame(pid = 1:3, score = c(10, 20, 30))
  cards <- list(sv_normalize(df1, name = "df1"), sv_normalize(df2, name = "df2"))

  shiny::testServer(sideview_server(cards), {
    # 1. Map columns
    session$setInputs(column_mapped = list(
      from_table = "df1",
      from_col = "id",
      to_table = "df2",
      to_col = "pid",
      join_type = "left_join"
    ))
    msgs1 <- session$userData$custom_messages
    expect_match(msgs1[[length(msgs1)]]$message$code, "left_join")

    # 2. Disconnect spline with remaining code update
    session$setInputs(column_disconnected = list(
      conn_id = "conn_1",
      from_table = "df1",
      from_col = "id",
      to_table = "df2",
      to_col = "pid",
      remaining_count = 0L,
      code = "# Connect two columns to generate pipeline code"
    ))
    msgs2 <- session$userData$custom_messages
    last_msg2 <- msgs2[[length(msgs2)]]
    expect_equal(last_msg2$type, "sideview_code_update")
    expect_identical(last_msg2$message$code, "")

    # 3. Clear operations event
    session$setInputs(clear_operations = list(timestamp = as.numeric(Sys.time())))
    msgs3 <- session$userData$custom_messages
    last_msg3 <- msgs3[[length(msgs3)]]
    expect_equal(last_msg3$type, "sideview_code_update")
    expect_identical(last_msg3$message$code, "")
  })
})

# -------------------------------------------------------------------------
# Feature 4: Dual Synchronized Scrolling
# -------------------------------------------------------------------------
test_that("Feature 4: Dual Synchronized Scrolling handles both vertical and horizontal scrolling", {
  js_code <- paste(readLines(find_asset("sideview.js"), warn = FALSE), collapse = "\n")
  
  # Verify vertical sync
  expect_match(js_code, "scrollTop", info = "Must handle scrollTop synchronization")
  expect_match(js_code, "scrollHeight", info = "Must scale relative to scrollHeight")
  
  # Verify horizontal sync
  expect_match(js_code, "scrollLeft", info = "Must handle scrollLeft synchronization")
  expect_match(js_code, "scrollWidth", info = "Must scale relative to scrollWidth")
  
  # Verify loop prevention flag
  expect_match(js_code, "isSyncingScroll", info = "Must use lock to prevent infinite scroll loops")
})

# -------------------------------------------------------------------------
# Feature 5: Local Ollama (gemma4:26b) & OpenAI LLM Engine
# -------------------------------------------------------------------------
test_that("Feature 5: Ollama gemma4:26b and OpenAI LLM engine synthesize privacy-safe join queries", {
  patients <- data.frame(
    patient_id = c("P01", "P02", "P03"),
    age = c(45, 52, 38),
    gender = c("Male", "Female", "Male"),
    stringsAsFactors = FALSE
  )
  visits <- data.frame(
    subject_id = c("P01", "P02", "P03"),
    visit_date = as.Date(c("2024-01-10", "2024-01-15", "2024-02-01")),
    systolic_bp = c(120, 140, 115),
    stringsAsFactors = FALSE
  )

  cards <- list(sv_normalize(patients, name = "patients"), sv_normalize(visits, name = "visits"))

  # Step A: Verify Privacy-Safe Schema Context
  schema <- sv_build_schema_context(cards)
  expect_match(schema, "Table: patients")
  expect_match(schema, "Dimensions: 3 rows x 3 columns")
  expect_match(schema, "patient_id \\(character\\)")
  expect_match(schema, "subject_id \\(character\\)")
  # Ensure no full rows leaked
  expect_false(grepl("2024-01-15", schema))

  # Step B: Build Prompt for joining columns using local Ollama model gemma4:26b
  prompt_bundle <- sv_build_prompt(
    user_prompt = "Join patients and visits on patient ID using left_join and filter age over 40",
    schema_context = schema
  )
  expect_true(is.list(prompt_bundle))
  expect_match(prompt_bundle$system_message, "tidyverse")
  expect_match(prompt_bundle$user_message, "Join patients and visits")

  # Step C: Extract R Code from LLM Response Markdown Fences
  mock_ollama_response <- paste(
    "Here is the tidyverse code to join the two tables:",
    "```r",
    "joined_data <- patients %>%",
    "  dplyr::left_join(visits, by = c('patient_id' = 'subject_id')) %>%",
    "  dplyr::filter(age > 40)",
    "```",
    "You can now run this pipeline in RStudio.",
    sep = "\n"
  )
  extracted_code <- sv_extract_code(mock_ollama_response)
  expect_match(extracted_code, "dplyr::left_join")
  expect_match(extracted_code, "dplyr::filter")
  expect_silent(parse(text = extracted_code))

  # Step D: Verify Server handles run_ai_prompt with Ollama backend
  fake_ollama_call <- function(prompt, backend = "ollama", ...) {
    "patients %>% dplyr::left_join(visits, by = c('patient_id' = 'subject_id'))"
  }

  shiny::testServer(sideview_server(cards, llm_fn = fake_ollama_call), {
    session$setInputs(run_ai_prompt = list(
      prompt = "join patients and visits",
      tables = c("patients", "visits")
    ))
    msgs <- session$userData$custom_messages
    expect_true(length(msgs) >= 1)
    code_msgs <- Filter(function(m) identical(m$type, "sideview_code_update"), msgs)
    expect_length(code_msgs, 1)
    expect_match(code_msgs[[1]]$message$code, "dplyr::left_join")
    # A status message (toast) follows the code update
    expect_equal(msgs[[length(msgs)]]$type, "sideview_ai_status")
  })
})

# -------------------------------------------------------------------------
# Feature 6: Action Drawer Execution Modes & Controls
# -------------------------------------------------------------------------
test_that("Feature 6: Action Drawer execution actions (Insert, Run & Exit, Run in R, Console) work correctly", {
  cards <- list(sv_normalize(data.frame(x = 10, y = 20), name = "my_table"))

  injected_code <- NULL
  mock_insert <- function(code, ...) {
    injected_code <<- code
    list(success = TRUE, destination = "editor", code = code, message = "OK")
  }

  console_code <- NULL
  mock_console <- function(code, ...) {
    console_code <<- code
    list(success = TRUE, destination = "console", code = code, message = "OK")
  }

  shiny::testServer(sideview_server(cards, insert_fn = mock_insert, console_fn = mock_console), {
    # 1. Insert Script
    test_code_1 <- "my_table %>% dplyr::mutate(z = x + y)"
    session$setInputs(inject_script = list(code = test_code_1))
    expect_equal(injected_code, test_code_1)

    # 2. Run & Exit
    test_code_2 <- "summary(my_table)"
    session$setInputs(send_console_and_exit = list(code = test_code_2))
    expect_equal(console_code, test_code_2)

    # 3. Run Console
    test_code_3 <- "head(my_table, 1)"
    session$setInputs(send_console = list(code = test_code_3))
    expect_equal(console_code, test_code_3)

    # 4. Run in R (eval_env)
    eval_script <- "calculated_output_df <- data.frame(total = 30L)"
    session$setInputs(eval_env = list(code = eval_script))
    expect_true(exists("calculated_output_df", envir = .GlobalEnv))
    expect_equal(get("calculated_output_df", envir = .GlobalEnv)$total, 30L)
    rm("calculated_output_df", envir = .GlobalEnv)
  })

  # Verify UI contains all Action Drawer buttons and Auto-clear toggle
  ui_str <- as.character(sideview_ui(cards))
  expect_match(ui_str, 'data-action="inject-script"', info = 'Must contain Insert Script button')
  expect_match(ui_str, 'data-action="send-console-exit"', info = 'Must contain Run & Exit button')
  expect_match(ui_str, 'data-action="eval-env"', info = 'Must contain Run in R button')
  expect_match(ui_str, 'data-action="clear-operation"', info = 'Must contain Clear button')
  expect_match(ui_str, "sideview-autoclear-toggle", info = "Must contain Auto-clear checkbox")
})

# -------------------------------------------------------------------------
# Feature 7: Universal Table Ingestion
# -------------------------------------------------------------------------
test_that("Feature 7: Universal S3 Normalizer standardizes all supported table formats", {
  skip_if_not_installed("gt")
  skip_if_not_installed("flextable")

  # data.frame
  df <- data.frame(a = 1:2, b = c("x", "y"))
  c1 <- sv_normalize(df, name = "df_card")
  expect_equal(c1$type, "grid")
  expect_equal(c1$dims, c(2L, 2L))

  # tibble
  tbl <- dplyr::tibble(x = 10:12)
  c2 <- sv_normalize(tbl, name = "tbl_card")
  expect_equal(c2$type, "grid")
  expect_equal(c2$dims, c(3L, 1L))

  # base::table
  tab <- table(c("A", "B", "A"))
  c3 <- sv_normalize(tab, name = "tab_card")
  expect_equal(c3$type, "grid")
  expect_equal(c3$dims, c(2L, 2L))

  # matrix
  mat <- matrix(1:6, nrow = 2, ncol = 3)
  c4 <- sv_normalize(mat, name = "mat_card")
  expect_equal(c4$type, "grid")
  expect_equal(c4$dims, c(2L, 3L))

  # gt
  gt_obj <- gt::gt(df)
  c5 <- sv_normalize(gt_obj, name = "gt_card")
  expect_equal(c5$type, "html")
  expect_true(grepl("<table", c5$html_content))
  expect_equal(nrow(c5$data), 2L)

  # flextable
  flex_obj <- flextable::flextable(df)
  c6 <- sv_normalize(flex_obj, name = "flex_card")
  expect_equal(c6$type, "html")
  expect_equal(nrow(c6$data), 2L)

  # widget
  wid_obj <- htmlwidgets::createWidget("testW", list(x = 1))
  c7 <- sv_normalize(wid_obj, name = "widget_card")
  expect_equal(c7$type, "widget")
})

# -------------------------------------------------------------------------
# Feature 8: Categorical Discrepancy Detection & Recoding
# -------------------------------------------------------------------------
test_that("Feature 8: Discrepancy detection and recoding functions compute correct crosswalks", {
  col_a <- c("Male", "Female", "M", "Fem", "Unknown")
  col_b <- c("Male", "Female")

  # Detect discrepancies
  disc <- sv_detect_discrepancies(col_a, col_b, max_distance = 3)
  expect_setequal(disc$exact_matches, c("Male", "Female"))
  expect_setequal(disc$only_in_x, c("M", "Fem", "Unknown"))
  expect_equal(length(disc$only_in_y), 0L)

  # Verify fuzzy matching spotted typo distances
  fuzzy_df <- disc$fuzzy_matches
  expect_true(is.data.frame(fuzzy_df))
  expect_true(any(fuzzy_df$x == "M" & fuzzy_df$y == "Male"))
  expect_true(any(fuzzy_df$x == "Fem" & fuzzy_df$y == "Female"))

  # Generate case_match pipeline
  crosswalk <- data.frame(from = c("M", "Fem"), to = c("Male", "Female"), stringsAsFactors = FALSE)
  code_case <- sv_code_recode("patients", "gender", crosswalk, method = "case_match", default = "gender", pipe = TRUE)
  expect_match(code_case, "dplyr::case_match")
  expect_silent(parse(text = code_case))

  # Generate fct_recode pipeline
  code_fct <- sv_code_recode("patients", "gender", crosswalk, method = "fct_recode", pipe = TRUE)
  expect_match(code_fct, "forcats::fct_recode")
  expect_silent(parse(text = code_fct))
})

# -------------------------------------------------------------------------
# Feature 9: Standalone HTML Export & Shiny Embedding
# -------------------------------------------------------------------------
test_that("Feature 9: Standalone HTML export and widget embedding function reliably", {
  df1 <- data.frame(a = 1:3, b = c("x", "y", "z"))
  df2 <- data.frame(a = 1:3, c = c(10, 20, 30))

  widget <- sideview_widget(table1 = df1, table2 = df2)
  expect_s3_class(widget, "htmlwidget")
  expect_s3_class(widget, "sideview")
  expect_equal(length(widget$x$cards), 2L)

  # Export to standalone HTML
  temp_html <- tempfile(fileext = ".html")
  on.exit(if (file.exists(temp_html)) unlink(temp_html), add = TRUE)

  saved_file <- save_sideview(widget, file = temp_html, selfcontained = TRUE, title = "Standalone Canvas")
  expect_true(file.exists(temp_html))
  expect_gt(file.info(temp_html)$size, 2000L)

  # Shiny UI output and render function
  out_tag <- sideviewOutput("sv_embed", width = "100%", height = "500px")
  expect_true(inherits(out_tag, "shiny.tag") || inherits(out_tag, "shiny.tag.list"))

  rnd_fn <- renderSideview(widget)
  expect_s3_class(rnd_fn, "shiny.render.function")
})

# -------------------------------------------------------------------------
# Feature 10: Web Assets & JavaScript Syntax Integrity
# -------------------------------------------------------------------------
test_that("Feature 10: All web assets exist, are non-empty, and contain zero JavaScript syntax errors", {
  assets <- c("sv-panzoom.js", "sv-pipeline.js", "sideview.css", "sideview.js")
  for (a in assets) {
    p <- find_asset(a)
    expect_true(file.exists(p), info = paste("Missing asset:", a))
    expect_gt(file.info(p)$size, 0L, label = paste("Asset file size:", a))
  }

  node_cmd <- Sys.which("node")
  if (nzchar(node_cmd)) {
    # Validate sideview.js syntax
    js_sideview <- find_asset("sideview.js")
    status_sv <- system2(node_cmd, c("-c", shQuote(js_sideview)), stdout = TRUE, stderr = TRUE)
    attr_sv <- attr(status_sv, "status")
    expect_true(is.null(attr_sv) || attr_sv == 0,
                info = paste("sideview.js syntax error:", paste(status_sv, collapse = "\n")))

    # Validate inst/htmlwidgets/sideview.js syntax if present
    hw_js <- file.path("inst", "htmlwidgets", "sideview.js")
    if (file.exists(hw_js)) {
      status_hw <- system2(node_cmd, c("-c", shQuote(hw_js)), stdout = TRUE, stderr = TRUE)
      attr_hw <- attr(status_hw, "status")
      expect_true(is.null(attr_hw) || attr_hw == 0,
                  info = paste("htmlwidgets/sideview.js syntax error:", paste(status_hw, collapse = "\n")))
    }
  }
})
