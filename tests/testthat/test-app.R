# Suppress startup package build warnings
suppressWarnings(suppressPackageStartupMessages(library(shiny)))

# Source R files if running standalone without package installed
if (!"package:sideview" %in% search()) {
  r_files <- list.files(c("R", "../R", "../../R"), pattern = "\\.[Rr]$", full.names = TRUE)
  for (f in r_files) source(f)
}

test_that("sideview_ui returns shiny.tag.list with proper dependencies and structure", {
  df1 <- data.frame(id = 1:3, name = c("Alice", "Bob", "Charlie"), stringsAsFactors = FALSE)
  df2 <- data.frame(patient_id = c(1, 2, 4), score = c(95, 80, 70), stringsAsFactors = FALSE)
  
  card1 <- sv_normalize(df1, name = "users")
  card2 <- sv_normalize(df2, name = "scores")
  
  # Also include an HTML card and a widget card
  html_card <- structure(
    list(
      id = "card_gt",
      name = "gt_summary",
      type = "html",
      data = df1,
      html_content = "<div class='gt-table-rendered'><table><tr><td>gt</td></tr></table></div>",
      dims = c(3L, 2L),
      col_types = c(id = "integer", name = "character")
    ),
    class = "sideview_card"
  )
  
  widget_card <- structure(
    list(
      id = "card_widget",
      name = "dt_table",
      type = "widget",
      data = df1,
      html_content = "<div class='htmlwidget-container'><span>widget</span></div>",
      dims = c(3L, 2L),
      col_types = c(id = "integer", name = "character")
    ),
    class = "sideview_card"
  )

  cards <- list(card1, card2, html_card, widget_card)
  ui <- sideview_ui(cards)
  
  # Must return a shiny.tag.list
  expect_s3_class(ui, "shiny.tag.list")
  
  # HTML dependencies
  deps <- htmltools::findDependencies(ui)
  dep_names <- vapply(deps, function(d) d$name, character(1))
  expect_true("sideview-core" %in% dep_names)
  
  sv_dep <- deps[[which(dep_names == "sideview-core")[1]]]
  expect_equal(sv_dep$stylesheet, "sideview.css")
  expect_equal(sv_dep$script, c("sv-panzoom.js", "sv-pipeline.js", "sideview.js"))
  
  # Render UI to character to verify required DOM elements
  html_rendered <- as.character(ui)
  
  # Container, toolbar, palette, canvas, viewport, SVG overlay
  expect_match(html_rendered, "sideview-container")
  expect_match(html_rendered, "sideview-toolbar")
  expect_match(html_rendered, "sideview-palette")
  expect_match(html_rendered, "sideview-canvas")
  expect_match(html_rendered, "sideview-viewport")
  expect_match(html_rendered, "sideview-connector-svg")
  
  # Action drawer and AI bar
  expect_match(html_rendered, "sideview-drawer")
  expect_match(html_rendered, "sideview-ai-bar")
  
  # Cards and elements
  expect_match(html_rendered, "sideview-card")
  expect_match(html_rendered, "sideview-card-header")
  expect_match(html_rendered, "sideview-col-port")
  expect_match(html_rendered, "sideview-table")
  
  # Renders grid cards
  expect_match(html_rendered, "users")
  expect_match(html_rendered, "scores")
  expect_match(html_rendered, "Alice")
  expect_match(html_rendered, "patient_id")
  
  # Renders HTML and widget card content
  expect_match(html_rendered, "gt-table-rendered")
  expect_match(html_rendered, "htmlwidget-container")
})

test_that("sideview_ui works with raw data.frames or single card", {
  df <- data.frame(a = 1:2, b = c("x", "y"))
  ui_raw <- sideview_ui(df)
  expect_s3_class(ui_raw, "shiny.tag.list")
  expect_match(as.character(ui_raw), "sideview-card")
  
  ui_empty <- sideview_ui(list())
  expect_s3_class(ui_empty, "shiny.tag.list")
  expect_match(as.character(ui_empty), "sideview-container")
})

test_that("sideview_server handles column_mapped input event and dispatches code", {
  df1 <- data.frame(id = 1:3, val1 = c("A", "B", "C"), stringsAsFactors = FALSE)
  df2 <- data.frame(patient_id = 1:3, val2 = c(10, 20, 30), stringsAsFactors = FALSE)
  cards <- list(sv_normalize(df1, name = "df1"), sv_normalize(df2, name = "df2"))

  shiny::testServer(sideview_server(cards), {
    # Trigger column_mapped with different column names
    session$setInputs(column_mapped = list(
      from_table = "df1",
      from_col = "id",
      to_table = "df2",
      to_col = "patient_id",
      join_type = "left_join"
    ))
    
    # Verify code was generated and stored/dispatched
    custom_msgs <- session$userData$custom_messages
    expect_true(length(custom_msgs) >= 1)
    
    last_msg <- custom_msgs[[length(custom_msgs)]]
    expect_equal(last_msg$type, "sideview_code_update")
    expect_match(last_msg$message$code, "df1\\s*%>%\\s*dplyr::left_join\\(df2,\\s*by = c\\(\"id\" = \"patient_id\"\\)\\)")
  })
})

test_that("sideview_server handles column_mapped with multi-key join (from_cols)", {
  df1 <- data.frame(site = 1:2, id = 1:2)
  df2 <- data.frame(site = 1:2, id = 1:2)
  cards <- list(sv_normalize(df1, name = "t1"), sv_normalize(df2, name = "t2"))

  shiny::testServer(sideview_server(cards), {
    session$setInputs(column_mapped = list(
      from_table = "t1",
      from_cols = c("site", "id"),
      to_table = "t2",
      to_cols = c("site", "id"),
      join_type = "inner_join"
    ))

    custom_msgs <- session$userData$custom_messages
    expect_true(length(custom_msgs) >= 1)
    last_msg <- custom_msgs[[length(custom_msgs)]]
    expect_equal(last_msg$type, "sideview_code_update")
    expect_match(last_msg$message$code, 't1\\s*%>%\\s*dplyr::inner_join\\(t2,\\s*by = c\\("site", "id"\\)\\)')
  })
})

test_that("sideview_server handles column_mapped with chained pipeline (joins = list(...))", {
  df1 <- data.frame(id = 1:2, site = 1:2)
  df2 <- data.frame(id = 1:2, hosp = 1:2)
  df3 <- data.frame(hosp = 1:2, dept = 1:2)
  cards <- list(sv_normalize(df1, name = "t1"), sv_normalize(df2, name = "t2"), sv_normalize(df3, name = "t3"))

  shiny::testServer(sideview_server(cards), {
    session$setInputs(column_mapped = list(
      joins = list(
        list(
          from_table = "t1",
          to_table = "t2",
          from_cols = c("id", "site"),
          to_cols = c("id", "hosp"),
          join_type = "left"
        ),
        list(
          from_table = "t2",
          to_table = "t3",
          from_col = "hosp",
          to_col = "hosp",
          join_type = "inner"
        )
      )
    ))

    custom_msgs <- session$userData$custom_messages
    expect_true(length(custom_msgs) >= 1)
    last_msg <- custom_msgs[[length(custom_msgs)]]
    expect_equal(last_msg$type, "sideview_code_update")
    code <- last_msg$message$code
    expect_match(code, 't1\\s*%>%\\s*dplyr::left_join\\(t2,\\s*by = c\\("id" = "id", "site" = "hosp"\\)\\)')
    expect_match(code, '%>%\\s*dplyr::inner_join\\(t3,\\s*by = "hosp"\\)')
  })
})

test_that("sideview_server handles column_renamed input event", {
  df1 <- data.frame(old_name = 1:3, stringsAsFactors = FALSE)
  cards <- list(sv_normalize(df1, name = "df1"))

  shiny::testServer(sideview_server(cards), {
    session$setInputs(column_renamed = list(
      table = "df1",
      old_col = "old_name",
      new_col = "new_name"
    ))
    
    custom_msgs <- session$userData$custom_messages
    expect_true(length(custom_msgs) >= 1)
    
    last_msg <- custom_msgs[[length(custom_msgs)]]
    expect_equal(last_msg$type, "sideview_code_update")
    expect_match(last_msg$message$code, "df1\\s*%>%\\s*dplyr::rename\\(new_name = old_name\\)")
  })
})

test_that("sideview_server handles column_sorted and column_filtered events", {
  df <- data.frame(id = 1:5, score = c(88, 92, 79, 95, 83))
  cards <- list(sv_normalize(df, name = "scores"))
  
  shiny::testServer(sideview_server(cards), {
    # Test column_sorted
    session$setInputs(column_sorted = list(
      table = "scores",
      column = "score",
      direction = "desc"
    ))
    msgs <- session$userData$custom_messages
    last_msg <- msgs[[length(msgs)]]
    expect_equal(last_msg$type, "sideview_code_update")
    expect_match(last_msg$message$code, "scores\\s*%>%.*dplyr::arrange\\(dplyr::desc\\(score\\)\\)")
    
    # Test column_filtered
    session$setInputs(column_filtered = list(
      table = "scores",
      column = "score",
      condition = "score >= 90"
    ))
    msgs2 <- session$userData$custom_messages
    last_msg2 <- msgs2[[length(msgs2)]]
    expect_equal(last_msg2$type, "sideview_code_update")
    expect_match(last_msg2$message$code, "scores\\s*%>%.*dplyr::filter\\(score >= 90\\)")
  })
})

test_that("sideview_server handles discrepancy_check input event", {
  df1 <- data.frame(status = c("Completed", "In Prog", "Cancelled", "Unknown"), stringsAsFactors = FALSE)
  df2 <- data.frame(state = c("Completed", "InProg", "Canceled", "Missing"), stringsAsFactors = FALSE)
  cards <- list(sv_normalize(df1, name = "t1"), sv_normalize(df2, name = "t2"))

  shiny::testServer(sideview_server(cards), {
    session$setInputs(discrepancy_check = list(
      table1 = "t1",
      col1 = "status",
      table2 = "t2",
      col2 = "state"
    ))
    
    custom_msgs <- session$userData$custom_messages
    expect_true(length(custom_msgs) >= 1)
    
    disc_msgs <- Filter(function(m) m$type == "sideview_discrepancies", custom_msgs)
    expect_true(length(disc_msgs) >= 1)
    
    msg_data <- disc_msgs[[length(disc_msgs)]]$message
    expect_equal(msg_data$from_table, "t1")
    expect_equal(msg_data$to_table, "t2")
    expect_true("fuzzy_matches" %in% names(msg_data))
    expect_true("only_in_x" %in% names(msg_data))
    expect_true("only_in_y" %in% names(msg_data))
    
    # In Prog and InProg have distance 1; Cancelled and Canceled have distance 1
    f_df <- as.data.frame(msg_data$fuzzy_matches)
    expect_true(nrow(f_df) >= 1)
    expect_true(any(f_df$x == "In Prog" & f_df$y == "InProg"))
  })
})

test_that("sideview_server handles run_ai_prompt event invoking sv_call_llm", {
  df1 <- data.frame(id = 1:3, age = c(25, 30, 35))
  cards <- list(sv_normalize(df1, name = "patients"))

  fake_llm <- function(prompt, backend = "ollama", ...) {
    "patients %>% dplyr::filter(age > 28)"
  }

  shiny::testServer(sideview_server(cards, llm_fn = fake_llm), {
    session$setInputs(run_ai_prompt = list(
      prompt = "filter patients older than 28",
      tables = c("patients")
    ))
    
    custom_msgs <- session$userData$custom_messages
    expect_true(length(custom_msgs) >= 1)
    
    ai_msgs <- Filter(function(m) m$type == "sideview_code_update", custom_msgs)
    expect_true(length(ai_msgs) >= 1)
    
    last_ai_msg <- ai_msgs[[length(ai_msgs)]]
    expect_match(last_ai_msg$message$code, "patients\\s*%>%\\s*dplyr::filter\\(age > 28\\)")
  })
})

test_that("sideview_server handles inject_script and send_console events", {
  cards <- list(sv_normalize(data.frame(x = 1), name = "df"))

  injected_code <- NULL
  fake_insert <- function(code, ...) {
    injected_code <<- code
    list(success = TRUE, destination = "editor", code = code, message = "OK")
  }

  console_code <- NULL
  fake_console <- function(code, ...) {
    console_code <<- code
    list(success = TRUE, destination = "console", code = code, message = "OK")
  }

  run_env <- new.env()
  shiny::testServer(sideview_server(cards, insert_fn = fake_insert, console_fn = fake_console,
                                    run_env = run_env), {
    # Test inject_script
    session$setInputs(inject_script = list(code = "df %>% dplyr::mutate(y = x * 2)"))
    expect_equal(injected_code, "df %>% dplyr::mutate(y = x * 2)")
    
    # Test send_console
    session$setInputs(send_console = list(code = "summary(df)"))
    expect_equal(console_code, "summary(df)")
    
    # Test send_console_and_exit
    session$setInputs(send_console_and_exit = list(code = "print(df)"))
    expect_equal(console_code, "print(df)")
    
    # Test eval_env
    session$setInputs(eval_env = list(code = "test_var_sv <- 42; data.frame(a = test_var_sv)"))
    expect_equal(get("test_var_sv", envir = run_env), 42)
    expect_false(exists("test_var_sv", envir = globalenv(), inherits = FALSE))
  })
})

test_that("sideview normalizes multiple table objects and sideview_addin finds data.frames", {
  df1 <- data.frame(a = 1:2)
  df2 <- data.frame(b = 3:4)
  mat <- matrix(1:4, nrow = 2)

  # sideview(...) in non-interactive/run=FALSE mode
  app <- sideview(table1 = df1, table2 = df2, table3 = mat, run = FALSE)
  expect_s3_class(app, "shiny.appobj")
  
  cards <- attr(app, "cards") %||% app$cards
  expect_true(is.list(cards))
  expect_equal(length(cards), 3)
  expect_equal(cards[[1]]$name, "table1")
  expect_equal(cards[[2]]$name, "table2")
  expect_equal(cards[[3]]$name, "table3")
  
  # Test sideview_addin environment scanning
  test_env <- new.env(parent = emptyenv())
  test_env$df_a <- data.frame(x = 1:5)
  test_env$df_b <- dplyr::tibble(y = c("a", "b"))
  test_env$not_a_df <- "hello world"
  test_env$num_vec <- 1:100
  
  found_tables <- sv_find_tables(test_env)
  expect_equal(length(found_tables), 2)
  expect_true(all(c("df_a", "df_b") %in% names(found_tables)))
  expect_false("not_a_df" %in% names(found_tables))
  expect_false("num_vec" %in% names(found_tables))
  
  # sideview_addin with run=FALSE returns appobj
  addin_app <- sideview_addin(env = test_env, run = FALSE)
  expect_s3_class(addin_app, "shiny.appobj")
  addin_cards <- attr(addin_app, "cards") %||% addin_app$cards
  expect_equal(length(addin_cards), 2)

  # Test collision-free handling of datasets named 'title', 'viewer', 'run'
  collision_env <- new.env(parent = emptyenv())
  collision_env$title <- data.frame(id = 1:2)
  collision_env$run <- data.frame(val = 3:4)
  collision_app <- sideview_addin(env = collision_env, run = FALSE)
  c_cards <- attr(collision_app, "cards") %||% collision_app$cards
  expect_equal(length(c_cards), 2)
  expect_true(all(c("title", "run") %in% vapply(c_cards, function(c) c$name, character(1))))
})

test_that("sideview_ui renders custom title and real htmlwidget objects", {
  custom_ui <- sideview_ui(list(), title = "Clinical Trial 101")
  ui_str <- as.character(custom_ui)
  expect_true(grepl("Clinical Trial 101", ui_str))

  # Real htmlwidget card
  skip_if_not_installed("htmlwidgets")
  widget <- htmlwidgets::createWidget("testWidget", list(x = 1), width = 200, height = 200)
  card_w <- sv_normalize(widget, name = "my_w")
  w_ui <- sideview_ui(card_w)
  expect_true(grepl("testWidget", as.character(w_ui)))
})

test_that("sideview_server gracefully ignores incomplete discrepancy_check events", {
  cards <- list(sv_normalize(data.frame(x = 1), name = "df"))
  shiny::testServer(sideview_server(cards), {
    # Incomplete inputs should not crash or throw errors
    session$setInputs(discrepancy_check = list(table1 = "df"))
    session$setInputs(discrepancy_check = list())
    session$setInputs(discrepancy_check = NULL)
    expect_true(TRUE)
  })
})

test_that("inst/rstudio/addins.dcf exists and is a valid DCF file", {
  find_dcf <- function() {
    candidates <- c(
      file.path("inst", "rstudio", "addins.dcf"),
      file.path("..", "inst", "rstudio", "addins.dcf"),
      file.path("..", "..", "inst", "rstudio", "addins.dcf"),
      system.file("rstudio", "addins.dcf", package = "sideview")
    )
    for (c in candidates) {
      if (nzchar(c) && file.exists(c)) return(normalizePath(c))
    }
    file.path("inst", "rstudio", "addins.dcf")
  }

  dcf_path <- find_dcf()
  expect_true(file.exists(dcf_path), info = paste("addins.dcf missing at:", dcf_path))
  
  dcf <- read.dcf(dcf_path)
  expect_true(nrow(dcf) >= 1)
  expect_true("Name" %in% colnames(dcf))
  expect_true("Binding" %in% colnames(dcf))
  expect_true("Description" %in% colnames(dcf))
  
  # Check binding value
  expect_true("sideview_addin" %in% dcf[, "Binding"])
  expect_true(all(nchar(dcf[, "Name"]) > 0))
  expect_true(all(nchar(dcf[, "Description"]) > 0))
})

test_that("sideview_ui safely handles data frames with list-columns", {
  df_nested <- data.frame(id = 1:2, label = c("A", "B"))
  df_nested$nested_vec <- list(c(10, 20), c(30, 40))
  card <- sv_normalize(df_nested, name = "nested")
  expect_silent({
    ui <- sideview_ui(card)
    ui_str <- as.character(ui)
  })
  expect_match(ui_str, "\\[list\\]")
})

test_that("sideview_server handles non-syntactic column names in sorting and filtering", {
  df <- data.frame(id = 1:3, check.names = FALSE)
  df[["Patient Age (years)"]] <- c(45, 52, 38)
  card <- sv_normalize(df, name = "clinical")
  shiny::testServer(sideview_server(list(card)), {
    session$setInputs(column_sorted = list(
      table = "clinical",
      column = "Patient Age (years)",
      direction = "desc"
    ))
    msgs <- session$userData$custom_messages
    expect_match(msgs[[length(msgs)]]$message$code, "dplyr::desc\\(`Patient Age \\(years\\)`\\)")
  })
})

test_that("render_card_tag generates header sparklines, categorical profiles, and missingness badges", {
  df <- data.frame(
    num_col = c(10, 20, 25, 30, 100),
    num_na = c(1, 2, NA, 4, 5), # 1 NA out of 5 = 20%
    char_col = c("apple", "banana", "apple", "cherry", "apple"),
    factor_col = factor(c("low", "med", "low", "high", "low")),
    clean_num = c(1, 2, 3, 4, 5), # 0% NA
    stringsAsFactors = FALSE
  )
  card <- sv_normalize(df, name = "profiling_test")
  tag <- render_card_tag(card)
  html_str <- as.character(tag)
  
  # 1. Numeric columns have inline SVG sparkline with 5 rect elements
  expect_match(html_str, '<svg class="sideview-sparkline"[^>]*viewBox="0 0 50 14"')
  expect_match(html_str, '<rect[^>]*width="8"')
  
  # 2. Categorical distribution indicator for character and factor columns
  expect_match(html_str, 'class="sideview-cat-profile"')
  expect_match(html_str, 'class="sideview-cat-bar"')
  
  # 3. Missingness indicator when column contains NA
  expect_match(html_str, 'class="sideview-na-badge"')
  expect_match(html_str, '20% NA')
  
  # 4. Clean column (0% NA) omits missingness badge
  clean_df <- data.frame(x = 1:5, y = c("a", "b", "c", "d", "e"))
  clean_card <- sv_normalize(clean_df, name = "clean_test")
  clean_html <- as.character(render_card_tag(clean_card))
  expect_false(grepl("sideview-na-badge", clean_html))
  
  # 5. Safe handling of 0-row tables
  zero_row_df <- data.frame(a = numeric(0), b = character(0))
  zero_card <- sv_normalize(zero_row_df, name = "zero_test")
  expect_silent({
    zero_html <- as.character(render_card_tag(zero_card))
  })
  expect_match(zero_html, 'sideview-card')
  
  # 6. Safe handling of all-NA columns
  all_na_df <- data.frame(
    all_na_num = c(NA_real_, NA_real_, NA_real_),
    all_na_char = c(NA_character_, NA_character_, NA_character_)
  )
  all_na_card <- sv_normalize(all_na_df, name = "all_na_test")
  expect_silent({
    all_na_html <- as.character(render_card_tag(all_na_card))
  })
  expect_match(all_na_html, '<svg class="sideview-sparkline"')
  expect_match(all_na_html, '100% NA')
  
  # 7. Safe handling of zero-variance numeric column (all values identical)
  zero_var_df <- data.frame(identical_num = c(42, 42, 42, 42))
  zero_var_card <- sv_normalize(zero_var_df, name = "zero_var_test")
  expect_silent({
    zero_var_html <- as.character(render_card_tag(zero_var_card))
  })
  expect_match(zero_var_html, '<svg class="sideview-sparkline"')
})


test_that("sideview_server handles request_suggested_mappings and apply_auto_clean events", {
  df1 <- data.frame(patient_id = 1:5, gender = c("male", "Female", "male", "Female", "male"), stringsAsFactors = FALSE)
  df2 <- data.frame(patient_id = 1:5, gender = c("Male", "Female", "Male", "Female", "Male"), stringsAsFactors = FALSE)
  cards <- list(sv_normalize(df1, name = "t1"), sv_normalize(df2, name = "t2"))

  shiny::testServer(sideview_server(cards), {
    # 1. Test request_suggested_mappings
    session$setInputs(request_suggested_mappings = list(min_confidence = 0.60))
    msgs <- session$userData$custom_messages
    suggest_msgs <- Filter(function(m) m$type == "sideview_suggested_mappings", msgs)
    expect_gt(length(suggest_msgs), 0)
    expect_true(is.list(suggest_msgs[[length(suggest_msgs)]]$message$candidates))

    # 2. Test apply_auto_clean
    disc <- sv_detect_discrepancies(df1$gender, df2$gender)
    session$setInputs(apply_auto_clean = list(
      discrepancy = disc,
      table = "t1",
      col = "gender"
    ))
    code_msgs <- Filter(function(m) m$type == "sideview_code_update", session$userData$custom_messages)
    expect_gt(length(code_msgs), 0)
    last_code <- code_msgs[[length(code_msgs)]]$message$code
    expect_true(grepl("dplyr::case_when", last_code))
    expect_true(grepl('"male"\\s*~\\s*"Male"', last_code))
  })
})


test_that("sideview_ui includes Action Drawer Copilot Chat tab and messages UI", {
  df <- data.frame(id = 1:3, name = c("A", "B", "C"))
  ui <- sideview_ui(df)
  html_rendered <- as.character(ui)

  expect_match(html_rendered, "sideview-chat-messages")
  expect_match(html_rendered, "sideview-chat-input")
  expect_match(html_rendered, "sideview-chat-send")
  expect_match(html_rendered, "sideview-drawer-tab")
  expect_match(html_rendered, 'data-tab="chat"')
})

test_that("sideview_server handles send_copilot_chat multi-turn conversational events", {
  df1 <- data.frame(patient_id = 1:3, age = c(25, 30, 35))
  df2 <- data.frame(patient_id = 1:3, test_val = c(100, 200, 150))
  cards <- list(sv_normalize(df1, name = "patients"), sv_normalize(df2, name = "labs"))

  captured_prompts <- list()
  fake_copilot_llm <- function(prompt, backend = "ollama", ...) {
    captured_prompts[[length(captured_prompts) + 1L]] <<- prompt
    if (length(captured_prompts) == 1L) {
      "Here is the join:\n```r\npatients %>% dplyr::left_join(labs, by = 'patient_id')\n```"
    } else {
      "Here is the filtered pipeline:\n```r\npatients %>% dplyr::left_join(labs, by = 'patient_id') %>% dplyr::filter(test_val > 120)\n```"
    }
  }

  shiny::testServer(sideview_server(cards, llm_fn = fake_copilot_llm), {
    # Turn 1: user initiates chat
    session$setInputs(send_copilot_chat = list(
      message = "Join patients and labs on patient_id",
      current_code = ""
    ))

    # Check copilot history was initialized and appended
    history1 <- session$userData$copilot_history
    expect_type(history1, "list")
    expect_equal(length(history1), 2L)
    expect_equal(history1[[1]]$role, "user")
    expect_equal(history1[[1]]$content, "Join patients and labs on patient_id")
    expect_equal(history1[[2]]$role, "assistant")
    expect_true(grepl("left_join", history1[[2]]$content))

    # Verify custom messages dispatched
    msgs <- session$userData$custom_messages
    reply_msgs <- Filter(function(m) m$type == "sideview_copilot_reply", msgs)
    expect_equal(length(reply_msgs), 1L)
    expect_true(grepl("left_join", reply_msgs[[1]]$message$code))

    code_msgs <- Filter(function(m) m$type == "sideview_code_update", msgs)
    expect_gte(length(code_msgs), 1L)
    expect_true(grepl("left_join", code_msgs[[length(code_msgs)]]$message$code))

    # Turn 2: multi-turn follow up instruction
    session$setInputs(send_copilot_chat = list(
      message = "Now filter for test_val > 120",
      current_code = "patients %>% dplyr::left_join(labs, by = 'patient_id')"
    ))

    history2 <- session$userData$copilot_history
    expect_equal(length(history2), 4L)
    expect_equal(history2[[3]]$role, "user")
    expect_equal(history2[[3]]$content, "Now filter for test_val > 120")
    expect_equal(history2[[4]]$role, "assistant")
    expect_true(grepl("filter\\(test_val > 120\\)", history2[[4]]$content))

    # Verify captured prompt in turn 2 contained previous history and active code
    expect_equal(length(captured_prompts), 2L)
    p2 <- captured_prompts[[2]]
    expect_true(grepl("left_join", p2$user_message) || grepl("left_join", p2$prompt))
    expect_true(grepl("Current active pipeline code", p2$user_message) || grepl("Current active pipeline code", p2$prompt))

    msgs2 <- session$userData$custom_messages
    reply_msgs2 <- Filter(function(m) m$type == "sideview_copilot_reply", msgs2)
    expect_equal(length(reply_msgs2), 2L)
    expect_true(grepl("filter\\(test_val > 120\\)", reply_msgs2[[2]]$message$code))
  })
})

test_that("send_copilot_chat with conversational reply (no code fences) does not dispatch sideview_code_update", {
  df1 <- data.frame(id = 1:3, val = c(10, 20, 30))
  cards <- list(sv_normalize(df1, name = "t1"))

  fake_chat_llm <- function(prompt, ...) {
    "Hello! I am Sideview Copilot. What transformation would you like to perform on table t1?"
  }

  shiny::testServer(sideview_server(cards, llm_fn = fake_chat_llm), {
    session$setInputs(send_copilot_chat = list(
      message = "Hello Copilot",
      current_code = "t1 %>% dplyr::filter(val > 10)"
    ))

    msgs <- session$userData$custom_messages
    reply_msgs <- Filter(function(m) m$type == "sideview_copilot_reply", msgs)
    expect_equal(length(reply_msgs), 1L)
    expect_equal(reply_msgs[[1]]$message$code, "")
    expect_match(reply_msgs[[1]]$message$text, "Hello! I am Sideview Copilot")

    # Verify sideview_code_update was NOT dispatched so canvas pipeline is preserved
    code_update_msgs <- Filter(function(m) m$type == "sideview_code_update", msgs)
    expect_equal(length(code_update_msgs), 0L)
  })
})

test_that("send_copilot_chat caps session copilot_history at sliding window limit (20 turns)", {
  df1 <- data.frame(id = 1:3)
  cards <- list(sv_normalize(df1, name = "t1"))

  turn_count <- 0L
  fake_chat_llm <- function(prompt, ...) {
    turn_count <<- turn_count + 1L
    paste0("Assistant reply turn ", turn_count)
  }

  shiny::testServer(sideview_server(cards, llm_fn = fake_chat_llm), {
    # Simulate 15 user-assistant exchanges (30 turns total)
    for (i in seq_len(15)) {
      session$setInputs(send_copilot_chat = list(
        message = paste("User message", i),
        current_code = ""
      ))
    }

    history <- session$userData$copilot_history
    expect_equal(length(history), 20L)
    # The last turn should be assistant reply turn 15
    expect_equal(history[[20L]]$role, "assistant")
    expect_equal(history[[20L]]$content, "Assistant reply turn 15")
    # The second to last turn should be user message 15
    expect_equal(history[[19L]]$role, "user")
    expect_equal(history[[19L]]$content, "User message 15")
    # The first element in history should be user message 6 (10 pairs retained: turns 6 through 15)
    expect_equal(history[[1L]]$role, "user")
    expect_equal(history[[1L]]$content, "User message 6")
  })
})

test_that("render_card_tag uses SVG icon placeholders, never emoji or glyphs", {
  df <- data.frame(patient_id = 1:5, heart_rate = c(72, 80, 68, 90, 75))
  card <- sv_normalize(df, name = "vitals")
  rendered <- as.character(render_card_tag(card))

  # Icons are data-sv-icon placeholders that sideview.js fills with inline SVG
  expect_match(rendered, "data-sv-icon=\"sort\"", fixed = TRUE)
  expect_match(rendered, "data-sv-icon=\"filter\"", fixed = TRUE)
  expect_match(rendered, "aria-label=\"Sort heart_rate\"", fixed = TRUE)

  # No glyph entities and no raw non-ASCII characters inside any button
  expect_false(grepl("&#x21C5;|&#x1F50D;|&#x26F6;|&#128279;", rendered))
  buttons <- regmatches(rendered, gregexpr("<button[^>]*>.*?</button>", rendered, perl = TRUE))[[1]]
  expect_true(length(buttons) >= 5)
  expect_false(any(grepl("[^\x01-\x7F]", buttons, perl = TRUE)))
})

test_that("sideview_ui chrome carries no emoji or glyph icons", {
  rendered <- as.character(sideview_ui())
  expect_false(grepl("&#x26F6;|&#10024;|&#128279;|&#x1F50D;|&#x21C5;|&times;|&minus;", rendered))
  expect_match(rendered, "data-sv-icon=\"fullscreen\"", fixed = TRUE)
  expect_match(rendered, "data-sv-icon=\"sparkles\"", fixed = TRUE)
  expect_match(rendered, "data-sv-icon=\"close\"", fixed = TRUE)
})

test_that("every data-sv-icon name used by the R UI exists in the JS icon set", {
  js <- paste(readLines(system.file("www", "sideview.js", package = "sideview"), warn = FALSE), collapse = "
")
  card <- sv_normalize(data.frame(a = 1), name = "x")
  html <- paste(as.character(sideview_ui()), as.character(render_card_tag(card)))
  used <- unique(regmatches(html, gregexpr("(?<=data-sv-icon=\")[A-Za-z]+", html, perl = TRUE))[[1]])
  expect_true(length(used) >= 7)
  for (nm in used) expect_match(js, paste0("
    ", nm, ": '<"), fixed = TRUE, info = nm)
})

test_that("sideview viewer defaults adapt to RStudio environment", {
  # When rstudioapi::isAvailable() returns TRUE
  testthat::with_mocked_bindings(
    isAvailable = function(...) TRUE,
    .package = "rstudioapi",
    code = {
      app <- sideview(mtcars, run = FALSE)
      expect_s3_class(app, "shiny.appobj")
    }
  )

  # When rstudioapi::isAvailable() returns FALSE
  testthat::with_mocked_bindings(
    isAvailable = function(...) FALSE,
    .package = "rstudioapi",
    code = {
      app <- sideview(mtcars, run = FALSE)
      expect_s3_class(app, "shiny.appobj")
    }
  )
})

test_that("render_card_tag renders maximize button and column resizers", {
  df <- data.frame(mpg = c(21, 21), cyl = c(6, 6))
  card <- sv_normalize(df, name = "mtcars")
  rendered <- as.character(render_card_tag(card))

  # Assert maximize button
  expect_match(rendered, "data-action=\"maximize-card\"", fixed = TRUE)
  expect_match(rendered, "data-sv-icon=\"maximize\"", fixed = TRUE)

  # Assert column boundary resizer
  expect_match(rendered, "sideview-col-resizer", fixed = TRUE)

  # Assert column title with type
  expect_match(rendered, "title=\"mpg (numeric)\"", fixed = TRUE)
  expect_match(rendered, "title=\"cyl (numeric)\"", fixed = TRUE)
})

test_that("sideview toolbar renders Fullscreen button and accepts shorthand viewer options", {
  ui <- sideview_ui()
  rendered_ui <- as.character(ui)
  expect_match(rendered_ui, "data-action=\"toggle-fullscreen\"", fixed = TRUE)
  expect_match(rendered_ui, "data-sv-icon=\"fullscreen\"", fixed = TRUE)
  expect_match(rendered_ui, "Fullscreen", fixed = TRUE)

  # Shorthand viewer strings in sideview
  app_browser <- sideview(mtcars, viewer = "browser", run = FALSE)
  expect_s3_class(app_browser, "shiny.appobj")

  app_dialog <- sideview(mtcars, viewer = "dialog", run = FALSE)
  expect_s3_class(app_dialog, "shiny.appobj")

  app_pane <- sideview(mtcars, viewer = "pane", run = FALSE)
  expect_s3_class(app_pane, "shiny.appobj")

  # In sideview_addin
  addin_browser <- sideview_addin(viewer = "browser", run = FALSE)
  expect_s3_class(addin_browser, "shiny.appobj")
})





# ---- lazy (duckdb / arrow) cards in the gadget server -------------------------------

lazy_server_fixture <- function(env = parent.frame()) {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("DBI")
  df <- data.frame(id = 1:1000, grp = rep(c("a", "b", "c", "d"), 250), stringsAsFactors = FALSE)
  other <- data.frame(id = seq(1L, 1000L, by = 2L), score = 500:1)
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(suppressWarnings(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)), envir = env)
  DBI::dbWriteTable(con, "v", df)
  DBI::dbWriteTable(con, "w", other)
  list(
    df = df, con = con,
    v = sv_normalize(dplyr::tbl(con, "v"), name = "v"),
    w = sv_normalize(dplyr::tbl(con, "w"), name = "w")
  )
}

msgs_of <- function(session, type) {
  Filter(function(m) identical(m$type, type), session$userData$custom_messages)
}

test_that("rows request uses the whole lazy table", {
  fx <- lazy_server_fixture()
  shiny::testServer(sideview_server(list(fx$v)), {
    session$setInputs(sideview_rows_request = list(
      card_id = fx$v$id, version = 1, offset = 0, limit = 10,
      sort = list(col = "id", dir = "desc")
    ))
    m <- msgs_of(session, "sideview_rows")
    expect_length(m, 1)
    expect_equal(m[[1]]$message$total, 1000)
    expect_identical(m[[1]]$message$columns$id[1], "1000")   # the true max, not the preview's 50
    expect_length(msgs_of(session, "sideview_toast"), 0)
  })
})

test_that("join and profile requests use the whole table", {
  fx <- lazy_server_fixture()
  shiny::testServer(sideview_server(list(fx$v, fx$w)), {
    session$setInputs(join_diagnostics_request = list(
      id = "j1", left = "v", right = "w",
      by = list(list(left = "id", right = "id"))
    ))
    m <- msgs_of(session, "sideview_join_diagnostics")
    expect_length(m, 1)
    expect_identical(m[[1]]$message$id, "j1")
    expect_equal(m[[1]]$message$n_x, 1000)
    expect_equal(m[[1]]$message$n_y, 500)
    expect_equal(m[[1]]$message$matched_x, 500)

    session$setInputs(column_profile_request = list(id = "p1", table = "v", column = "id"))
    p <- msgs_of(session, "sideview_column_profile")
    expect_length(p, 1)
    expect_equal(p[[1]]$message$n, 1000)
    expect_equal(p[[1]]$message$stats$max, 1000)
    expect_length(msgs_of(session, "sideview_toast"), 0)
  })
})

test_that("codebook export profiles lazy tables in full", {
  fx <- lazy_server_fixture()
  path <- tempfile(fileext = ".csv")
  withr::defer(unlink(path))
  testthat::local_mocked_bindings(sv_choose_codebook_path = function() path)
  shiny::testServer(sideview_server(list(fx$v)), {
    session$setInputs(codebook_export = 1)
    m <- msgs_of(session, "sideview_codebook_saved")
    expect_length(m, 1)
    expect_null(m[[1]]$message$error)
    cb <- utils::read.csv(path, stringsAsFactors = FALSE)
    expect_equal(cb$n, c(1000, 1000))
    expect_equal(cb$rows_profiled, c(1000, 1000))
    # the codebook leaves the session's connection open
    session$setInputs(sideview_rows_request = list(card_id = fx$v$id, version = 1, offset = 0, limit = 5))
    expect_equal(msgs_of(session, "sideview_rows")[[1]]$message$total, 1000)
    # progress toasts depend on timing; a lost link must not be reported
    lost <- Filter(function(m) grepl("Lost the link", m$message$text), msgs_of(session, "sideview_toast"))
    expect_length(lost, 0)
  })
})

test_that("codebook export of a preview-only lazy card reports the true size", {
  fx <- lazy_server_fixture()
  withr::local_options(sideview.use_duckdb = FALSE)
  path <- tempfile(fileext = ".csv")
  withr::defer(unlink(path))
  testthat::local_mocked_bindings(sv_choose_codebook_path = function() path)
  shiny::testServer(sideview_server(list(fx$v)), {
    session$setInputs(codebook_export = 1)
    cb <- utils::read.csv(path, stringsAsFactors = FALSE)
    expect_equal(cb$n, c(1000, 1000))
    expect_equal(cb$rows_profiled, c(50, 50))
  })
})

test_that("codebook progress is sent as throttled toasts", {
  fx <- lazy_server_fixture()
  path <- tempfile(fileext = ".csv")
  withr::defer(unlink(path))
  real_codebook <- sv_codebook
  fake <- function(..., progress = NULL, top_n = 5L, file = NULL) {
    for (j in 1:3) progress("v", j, 3L)
    Sys.sleep(0.3)
    progress("v", 3L, 3L)
    real_codebook(..., top_n = top_n)
  }
  testthat::local_mocked_bindings(sv_choose_codebook_path = function() path, sv_codebook = fake)
  shiny::testServer(sideview_server(list(fx$v)), {
    session$setInputs(codebook_export = 1)
    t <- msgs_of(session, "sideview_toast")
    expect_length(t, 1)   # three quick calls are swallowed, the one after 300 ms is sent
    expect_identical(t[[1]]$message$text, "Profiling v: column 3 of 3")
    expect_identical(t[[1]]$message$id, "codebook-progress")   # the browser updates one toast
    expect_null(t[[1]]$message$card)
  })
})

test_that("a closed connection falls back to the preview once", {
  fx <- lazy_server_fixture()
  shiny::testServer(sideview_server(list(fx$v)), {
    DBI::dbDisconnect(fx$con, shutdown = TRUE)
    rows <- function(v) session$setInputs(sideview_rows_request = list(
      card_id = fx$v$id, version = v, offset = 0, limit = 10
    ))
    rows(1)
    rows(2)
    m <- msgs_of(session, "sideview_rows")
    expect_length(m, 2)
    expect_equal(m[[1]]$message$total, 50)
    expect_equal(m[[2]]$message$total, 50)
    expect_null(m[[2]]$message$error)
    t <- msgs_of(session, "sideview_toast")
    expect_length(t, 1)
    expect_identical(t[[1]]$message$text, "Lost the link to v; showing the first 50 rows.")
    expect_identical(t[[1]]$message$type, "warning")
    # the toast names the card, so the browser can mark it preview-only
    expect_identical(t[[1]]$message$card, fx$v$id)

    # the other requests also answer from the preview, without a second toast
    session$setInputs(column_profile_request = list(id = "p1", table = "v", column = "id"))
    p <- msgs_of(session, "sideview_column_profile")
    expect_equal(p[[1]]$message$n, 50)
    expect_length(msgs_of(session, "sideview_toast"), 1)
  })
})

test_that("a failed join falls back to the preview with one toast per card", {
  fx <- lazy_server_fixture()
  shiny::testServer(sideview_server(list(fx$v, fx$w)), {
    DBI::dbDisconnect(fx$con, shutdown = TRUE)
    session$setInputs(join_diagnostics_request = list(
      id = "j1", left = "v", right = "w", by = list(list(left = "id", right = "id"))
    ))
    m <- msgs_of(session, "sideview_join_diagnostics")
    expect_length(m, 1)
    expect_identical(m[[1]]$message$id, "j1")
    expect_equal(m[[1]]$message$n_x, 50)
    expect_length(msgs_of(session, "sideview_toast"), 2)
  })
})

test_that("a request-specific error is not a lost link", {
  fx <- lazy_server_fixture()
  shiny::testServer(sideview_server(list(fx$v)), {
    session$setInputs(sideview_rows_request = list(
      card_id = fx$v$id, version = 1, offset = 0, limit = 5,
      filter = list(col = "id", op = "bogus", val = "1")
    ))
    m <- msgs_of(session, "sideview_rows")
    expect_length(m, 1)
    expect_match(m[[1]]$message$error, "Unknown filter operator")
    expect_length(msgs_of(session, "sideview_toast"), 0)
    # the card is still full
    session$setInputs(sideview_rows_request = list(card_id = fx$v$id, version = 2, offset = 0, limit = 5))
    expect_equal(msgs_of(session, "sideview_rows")[[2]]$message$total, 1000)
    expect_length(msgs_of(session, "sideview_toast"), 0)
  })
})

test_that("a join with one dead card marks only that card", {
  skip_if_not_installed("arrow")
  fx <- lazy_server_fixture()
  con2 <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(suppressWarnings(try(DBI::dbDisconnect(con2, shutdown = TRUE), silent = TRUE)))
  DBI::dbWriteTable(con2, "z", data.frame(id = 1:200, q = 1))
  z <- sv_normalize(dplyr::tbl(con2, "z"), name = "z")
  a <- sv_normalize(arrow::arrow_table(fx$df), name = "a")
  shiny::testServer(sideview_server(list(a, z)), {
    DBI::dbDisconnect(con2, shutdown = TRUE)
    session$setInputs(join_diagnostics_request = list(
      id = "j1", left = "a", right = "z", by = list(list(left = "id", right = "id"))
    ))
    m <- msgs_of(session, "sideview_join_diagnostics")
    expect_null(m[[1]]$message$error)
    expect_equal(m[[1]]$message$n_x, 1000)   # the healthy card keeps its whole table
    expect_equal(m[[1]]$message$n_y, 50)     # the dead one answers from its preview
    t <- msgs_of(session, "sideview_toast")
    expect_length(t, 1)
    expect_identical(t[[1]]$message$text, "Lost the link to z; showing the first 50 rows.")
    expect_identical(t[[1]]$message$card, z$id)   # only the dead card is named
    session$setInputs(sideview_rows_request = list(card_id = a$id, version = 1, offset = 0, limit = 5))
    session$setInputs(sideview_rows_request = list(card_id = z$id, version = 2, offset = 0, limit = 5))
    r <- msgs_of(session, "sideview_rows")
    expect_equal(r[[1]]$message$total, 1000)
    expect_equal(r[[2]]$message$total, 50)
    expect_length(msgs_of(session, "sideview_toast"), 1)
  })
})

test_that("a self-join of a dead card sends one toast", {
  fx <- lazy_server_fixture()
  shiny::testServer(sideview_server(list(fx$v)), {
    DBI::dbDisconnect(fx$con, shutdown = TRUE)
    session$setInputs(join_diagnostics_request = list(
      id = "j1", left = "v", right = "v", by = list(list(left = "id", right = "id"))
    ))
    expect_equal(msgs_of(session, "sideview_join_diagnostics")[[1]]$message$n_x, 50)
    expect_length(msgs_of(session, "sideview_toast"), 1)
  })
})

test_that("Arrow cards use the whole table", {
  skip_if_not_installed("arrow")
  fx <- lazy_server_fixture()
  a <- sv_normalize(arrow::arrow_table(fx$df), name = "a")
  b <- sv_normalize(arrow::arrow_table(data.frame(id = 1:300, k = 1)), name = "b")
  shiny::testServer(sideview_server(list(a, b, fx$w)), {
    session$setInputs(sideview_rows_request = list(
      card_id = a$id, version = 1, offset = 0, limit = 5, sort = list(col = "id", dir = "desc")
    ))
    r <- msgs_of(session, "sideview_rows")[[1]]$message
    expect_equal(r$total, 1000)
    expect_identical(r$columns$id[1], "1000")

    session$setInputs(column_profile_request = list(id = "p1", table = "a", column = "id"))
    expect_equal(msgs_of(session, "sideview_column_profile")[[1]]$message$n, 1000)

    # Arrow with Arrow, and Arrow with the user's own duckdb table
    session$setInputs(join_diagnostics_request = list(
      id = "j1", left = "a", right = "b", by = list(list(left = "id", right = "id"))
    ))
    session$setInputs(join_diagnostics_request = list(
      id = "j2", left = "a", right = "w", by = list(list(left = "id", right = "id"))
    ))
    j <- msgs_of(session, "sideview_join_diagnostics")
    expect_null(j[[1]]$message$error)
    expect_equal(j[[1]]$message$n_x, 1000)
    expect_equal(j[[1]]$message$n_y, 300)
    expect_null(j[[2]]$message$error)
    expect_equal(j[[2]]$message$n_y, 500)

    # a bad request is not a lost link
    session$setInputs(sideview_rows_request = list(
      card_id = a$id, version = 2, offset = 0, limit = 5, filter = list(col = "id", op = "bogus", val = "1")
    ))
    expect_match(msgs_of(session, "sideview_rows")[[2]]$message$error, "Unknown filter operator")
    expect_length(msgs_of(session, "sideview_toast"), 0)
  })
})

test_that("the gadget inspector and codebook keep Arrow factor classes and time zones", {
  skip_if_not_installed("arrow")
  df <- data.frame(
    id = 1:120,
    f = factor(c("high", "low", "mid")[(0:119) %% 3 + 1], levels = c("low", "mid", "high")),
    o = factor(c("b", "a", NA)[(0:119) %% 3 + 1], levels = c("b", "a"), ordered = TRUE),
    t = as.POSIXct("2024-03-01 08:30:00", tz = "Asia/Singapore") + (0:119) * 3600,
    stringsAsFactors = FALSE
  )
  a <- sv_normalize(arrow::arrow_table(df), name = "a")
  path <- tempfile(fileext = ".csv")
  withr::defer(unlink(path))
  testthat::local_mocked_bindings(sv_choose_codebook_path = function() path)
  shiny::testServer(sideview_server(list(a)), {
    for (cn in c("f", "o", "t")) {
      session$setInputs(column_profile_request = list(id = cn, table = "a", column = cn))
    }
    got <- lapply(msgs_of(session, "sideview_column_profile"), function(m) m$message)
    names(got) <- vapply(got, function(m) m$column, "")
    for (cn in c("f", "o", "t")) {
      want <- sv_column_profile_json(sv_column_profile(as.data.frame(df)[[cn]]))
      expect_identical(got[[cn]]$class, want$class, label = cn)
      expect_identical(got[[cn]]$stats, want$stats, label = cn)
      expect_equal(got[[cn]]$n, 120)
    }
    expect_identical(got$f$class, "factor")
    expect_identical(got$o$class, "ordered")
    expect_identical(got$t$stats$min, "2024-03-01 08:30:00")

    session$setInputs(codebook_export = 1)
    cb <- utils::read.csv(path, stringsAsFactors = FALSE)
    want_path <- withr::local_tempfile(fileext = ".csv")
    sv_write_codebook(sv_codebook(a = as.data.frame(df)), want_path)
    want_cb <- utils::read.csv(want_path, stringsAsFactors = FALSE)
    expect_identical(cb$class, want_cb$class)
    expect_identical(cb$min, want_cb$min)
    expect_identical(cb$max, want_cb$max)
    expect_identical(cb$class[cb$column %in% c("f", "o")], c("factor", "ordered"))
    expect_identical(cb$min[cb$column == "t"], "2024-03-01 08:30:00")
  })
})

test_that("tables on different connections answer with an error and keep the link", {
  fx <- lazy_server_fixture()
  con2 <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con2, shutdown = TRUE))
  DBI::dbWriteTable(con2, "z", data.frame(id = 1:10))
  z <- sv_normalize(dplyr::tbl(con2, "z"), name = "z")
  shiny::testServer(sideview_server(list(fx$v, z)), {
    session$setInputs(join_diagnostics_request = list(
      id = "j1", left = "v", right = "z", by = list(list(left = "id", right = "id"))
    ))
    m <- msgs_of(session, "sideview_join_diagnostics")
    expect_match(m[[1]]$message$error, "different duckdb connections")
    expect_length(msgs_of(session, "sideview_toast"), 0)
    # the cards are still full: a rows request still sees every row
    session$setInputs(sideview_rows_request = list(card_id = fx$v$id, version = 1, offset = 0, limit = 5))
    expect_equal(msgs_of(session, "sideview_rows")[[1]]$message$total, 1000)
  })
})

test_that("preview badge and attributes", {
  fx <- lazy_server_fixture()
  local({
    withr::local_options(sideview.use_duckdb = FALSE)
    html <- as.character(render_card_tag(fx$v))
    expect_match(html, "First 50 of 1,000 rows", fixed = TRUE)
    expect_match(html, "Install duckdb to check the whole table", fixed = TRUE)
    expect_match(html, 'data-total-rows="50"', fixed = TRUE)
    expect_match(html, 'data-table-rows="1000"', fixed = TRUE)
    expect_match(html, 'data-rows-basis="preview"', fixed = TRUE)
    expect_match(html, 'data-lazy="duckdb"', fixed = TRUE)
  })
  html <- as.character(render_card_tag(fx$v))
  expect_match(html, 'data-total-rows="1000"', fixed = TRUE)
  expect_match(html, 'data-rows-basis="full"', fixed = TRUE)
  expect_match(html, 'data-code-ref="v"', fixed = TRUE)
  expect_false(grepl("First 50 of", html, fixed = TRUE))
  expect_false(grepl("Install duckdb", html, fixed = TRUE))

  # a plain data frame keeps its badge and has no lazy attribute
  plain <- as.character(render_card_tag(sv_normalize(data.frame(a = 1:3), name = "p")))
  expect_false(grepl("data-lazy", plain, fixed = TRUE))
  expect_match(plain, 'data-total-rows="3"', fixed = TRUE)
  expect_match(plain, 'data-rows-basis="full"', fixed = TRUE)
  expect_false(grepl("source", plain, fixed = TRUE))
})

test_that("row counts reach the browser as plain digits, not 2e+05", {
  # parseInt("2e+05") is 2 in the browser: the card would never page from the server
  card <- sv_normalize(data.frame(a = 1:5), name = "t")
  card$dims <- c(200000, 1)
  html <- as.character(render_card_tag(card))
  expect_match(html, 'data-table-rows="200000"', fixed = TRUE)
  # the badge text has thousands separators (the attributes stay plain digits)
  expect_match(html, "200,000 × 1", fixed = TRUE)
  expect_no_match(html, "e+05", fixed = TRUE)
  card$dims <- c(100000, 1)
  expect_match(as.character(render_card_tag(card)), 'data-table-rows="100000"', fixed = TRUE)
})

test_that("a card prints its row count with thousands separators", {
  card <- sv_normalize(data.frame(a = 1:5), name = "t")
  card$dims <- c(200000, 1)
  out <- paste(utils::capture.output(print(card)), collapse = "\n")
  expect_match(out, "Dims: 200,000 rows x 1 cols", fixed = TRUE)
  expect_no_match(out, "e+05", fixed = TRUE)
})


test_that("auto-clean on a lazy card uses the card's code ref; a name that looks like a call is quoted", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("withr")
  frame <- data.frame(id = 1:3, gender = c("male", "Female", "male"), stringsAsFactors = FALSE)
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "d", frame)
  cards <- list(
    sv_normalize(arrow::arrow_table(frame), name = "visits (2020)"),
    sv_normalize(con, name = "d"),  # a DBI connection: the card is written as dplyr::tbl(...)
    sv_normalize(arrow::arrow_table(frame), name = "plain")
  )
  disc <- sv_detect_discrepancies(c("male", "Female"), c("Male", "Female"))
  shiny::testServer(sideview_server(cards), {
    code_for <- function(tbl) {
      session$setInputs(apply_auto_clean = list(discrepancy = disc, table = tbl, col = "gender",
                                                pipe = TRUE, nonce = stats::runif(1)))
      msgs <- Filter(function(m) m$type == "sideview_code_update", session$userData$custom_messages)
      msgs[[length(msgs)]]$message$code
    }
    odd <- code_for("visits (2020)")
    expect_true(startsWith(odd, "`visits (2020)` %>%"))
    expect_silent(parse(text = odd))
    expect_true(startsWith(code_for("d"), "dplyr::tbl("))
    expect_true(startsWith(code_for("plain"), "plain %>%"))
  })
  # the generator on its own
  expect_true(startsWith(sv_auto_clean_rules(disc, "visits (2020)", "gender", pipe = TRUE, lazy = TRUE),
                         "`visits (2020)` %>%"))
  expect_true(startsWith(sv_auto_clean_rules(disc, "dplyr::tbl(con, \"d\")", "gender", pipe = TRUE,
                                             lazy = TRUE, df_is_code = TRUE),
                         "dplyr::tbl(con, \"d\") %>%"))
})
