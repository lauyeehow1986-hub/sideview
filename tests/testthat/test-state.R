# Source R files if running standalone without package installed
if (!"package:sideview" %in% search()) {
  r_files <- list.files(c("R", "../R", "../../R"), pattern = "\\.[Rr]$", full.names = TRUE)
  for (f in r_files) source(f)
}

test_that("new_sideview_state creates valid sideview_state object", {
  state <- new_sideview_state()
  expect_s3_class(state, "sideview_state")
  expect_s3_class(state, "list")
  expect_equal(state$version, "0.3.0")
  expect_type(state$canvas, "list")
  expect_equal(state$canvas$zoom, 1)
  expect_equal(state$canvas$pan_x, 0)
  expect_equal(state$canvas$pan_y, 0)
  expect_true(is.list(state$cards))
  expect_equal(length(state$cards), 0)
  expect_true(is.list(state$connections))
  expect_equal(length(state$connections), 0)
  expect_type(state$pipeline, "list")
  expect_equal(state$pipeline$active_tab, "pipeline")
})

test_that("sv_save_state and sv_load_state roundtrip with JSON", {
  tf <- tempfile(fileext = ".json")
  on.exit(unlink(tf), add = TRUE)
  
  sample_state <- new_sideview_state(
    version = "0.2.0",
    canvas = list(zoom = 1.5, pan_x = 100.0, pan_y = -50.0),
    cards = list(
      list(
        id = "card_1",
        name = "orders",
        x = 50.0,
        y = 100.0,
        width = 400.0,
        height = 300.0,
        sorts = list(list(col = "order_date", dir = "desc")),
        filters = list(list(col = "status", op = "==", val = "completed"))
      ),
      list(
        id = "card_2",
        name = "customers",
        x = 500.0,
        y = 100.0,
        width = 380.0,
        height = 280.0,
        sorts = list(),
        filters = list()
      )
    ),
    connections = list(
      list(
        from_table = "orders",
        from_col = "customer_id",
        to_table = "customers",
        to_col = "id",
        join_type = "left_join"
      )
    ),
    pipeline = list(
      code = "orders %>% left_join(customers, by = c('customer_id' = 'id'))",
      active_tab = "pipeline"
    )
  )
  
  res <- sv_save_state(sample_state, tf)
  expect_equal(res, tf)
  expect_true(file.exists(tf))
  
  # Verify JSON content
  raw_txt <- readLines(tf, warn = FALSE)
  expect_true(any(grepl("\"version\": \"0.2.0\"", raw_txt) | grepl("\"version\":\\s*\"0.2.0\"", raw_txt)))
  
  # Load state
  loaded <- sv_load_state(tf)
  expect_s3_class(loaded, "sideview_state")
  expect_s3_class(loaded, "list")
  expect_equal(loaded$version, "0.2.0")
  expect_equal(loaded$canvas$zoom, 1.5)
  expect_equal(loaded$canvas$pan_x, 100.0)
  expect_equal(loaded$canvas$pan_y, -50.0)
  expect_equal(length(loaded$cards), 2)
  expect_equal(loaded$cards[[1]]$id, "card_1")
  expect_equal(loaded$cards[[1]]$name, "orders")
  expect_equal(loaded$cards[[1]]$x, 50.0)
  expect_equal(loaded$cards[[1]]$y, 100.0)
  expect_equal(loaded$cards[[1]]$width, 400.0)
  expect_equal(loaded$cards[[1]]$height, 300.0)
  expect_equal(loaded$cards[[1]]$sorts[[1]]$col, "order_date")
  expect_equal(loaded$cards[[1]]$filters[[1]]$val, "completed")
  expect_equal(length(loaded$connections), 1)
  expect_equal(loaded$connections[[1]]$from_table, "orders")
  expect_equal(loaded$connections[[1]]$to_table, "customers")
  expect_equal(loaded$connections[[1]]$join_type, "left_join")
  expect_equal(loaded$pipeline$active_tab, "pipeline")
  expect_equal(loaded$pipeline$code, sample_state$pipeline$code)
})

test_that("sv_save_state and sv_load_state roundtrip with RDS", {
  tf <- tempfile(fileext = ".rds")
  on.exit(unlink(tf), add = TRUE)
  
  sample_state <- new_sideview_state(
    version = "0.2.0",
    canvas = list(zoom = 0.8, pan_x = -200, pan_y = 120),
    cards = list(
      list(
        id = "card_a",
        name = "mtcars",
        x = 10,
        y = 20,
        width = 300,
        height = 200,
        sorts = list(),
        filters = list()
      )
    ),
    connections = list(),
    pipeline = list(code = "", active_tab = "pipeline")
  )
  
  res <- sv_save_state(sample_state, tf)
  expect_equal(res, tf)
  expect_true(file.exists(tf))
  
  loaded <- sv_load_state(tf)
  expect_s3_class(loaded, "sideview_state")
  expect_equal(loaded, sample_state)
})

test_that("sv_save_state supports explicit format argument", {
  tf_json <- tempfile(fileext = ".custom_json")
  tf_rds <- tempfile(fileext = ".custom_rds")
  on.exit(unlink(c(tf_json, tf_rds)), add = TRUE)
  
  st <- new_sideview_state()
  sv_save_state(st, tf_json, format = "json")
  sv_save_state(st, tf_rds, format = "rds")
  
  expect_true(file.exists(tf_json))
  expect_true(file.exists(tf_rds))
  
  # Loading custom extensions if format can be inferred or supported
  expect_error(sv_load_state(tf_json), "Invalid or unsupported")
  
  # Reading with fromJSON should work on tf_json
  parsed <- jsonlite::fromJSON(tf_json, simplifyVector = FALSE)
  expect_equal(parsed$version, "0.3.0")
})

test_that("sv_save_state and sv_load_state error handling", {
  st <- new_sideview_state()
  
  # Invalid format in save
  expect_error(sv_save_state(st, tempfile(), format = "xml"), "Invalid format")

  # Unrecognized extension without format in save
  expect_error(sv_save_state(st, tempfile(fileext = ".xyz")), "Cannot infer format")
  
  # Non-existent file in load
  expect_error(sv_load_state("non_existent_state_file_12345.json"), "does not exist")
  
  # Invalid extension in load
  tf_txt <- tempfile(fileext = ".txt")
  writeLines("hello", tf_txt)
  on.exit(unlink(tf_txt), add = TRUE)
  expect_error(sv_load_state(tf_txt), "Invalid or unsupported")

  # Invalid format in load
  expect_error(sv_load_state(tf_txt, format = "xml"), "Invalid format")
})

test_that("sv_load_state loads non-standard extensions when format is explicitly specified", {
  tf_custom <- tempfile(fileext = ".canvas")
  on.exit(unlink(tf_custom), add = TRUE)

  st <- new_sideview_state(
    version = "0.2.0",
    canvas = list(zoom = 1.25, pan_x = 42, pan_y = -10)
  )
  sv_save_state(st, tf_custom, format = "json")

  # Without format, loading non-standard extension fails
  expect_error(sv_load_state(tf_custom), "Invalid or unsupported")

  # With explicit format = "json", it succeeds
  loaded <- sv_load_state(tf_custom, format = "json")
  expect_s3_class(loaded, "sideview_state")
  expect_equal(loaded$version, "0.2.0")
  expect_equal(loaded$canvas$zoom, 1.25)
  expect_equal(loaded$canvas$pan_x, 42)
})

test_that("sv_save_state creates missing nested directories", {
  nested_dir <- file.path(tempdir(), paste0("test_nested_", as.integer(runif(1, 1000, 9999))), "deep", "nested")
  tf_nested <- file.path(nested_dir, "state.json")
  on.exit(unlink(dirname(dirname(nested_dir)), recursive = TRUE), add = TRUE)

  expect_false(dir.exists(nested_dir))

  st <- new_sideview_state()
  res <- sv_save_state(st, tf_nested)
  expect_equal(res, tf_nested)
  expect_true(dir.exists(nested_dir))
  expect_true(file.exists(tf_nested))

  loaded <- sv_load_state(tf_nested)
  expect_s3_class(loaded, "sideview_state")
})

test_that("sv_load_state rejects corrupted non-list state files with informative error", {
  tf_json <- tempfile(fileext = ".json")
  tf_rds <- tempfile(fileext = ".rds")
  on.exit(unlink(c(tf_json, tf_rds)), add = TRUE)

  # Non-list JSON scalar
  writeLines('"not a list or object"', tf_json)
  expect_error(sv_load_state(tf_json), "root object must be a list")

  # Non-list RDS scalar
  saveRDS("not a list or object", tf_rds)
  expect_error(sv_load_state(tf_rds), "root object must be a list")
})

test_that("print.sideview_state displays clean summary", {
  st <- new_sideview_state(
    version = "0.2.0",
    canvas = list(zoom = 1.25, pan_x = 50, pan_y = -30),
    cards = list(
      list(id = "c1", name = "table1"),
      list(id = "c2", name = "table2")
    ),
    connections = list(
      list(from_table = "table1", from_col = "id", to_table = "table2", to_col = "id")
    )
  )
  
  out <- capture.output(print(st))
  expect_true(any(grepl("<sideview_state v0.2.0>", out)))
  expect_true(any(grepl("Cards:\\s*2", out)))
  expect_true(any(grepl("Connections:\\s*1", out)))
  expect_true(any(grepl("Canvas:", out)))
})

test_that("sv_load_state with launch=TRUE returns state when non-interactive", {
  tf <- tempfile(fileext = ".json")
  on.exit(unlink(tf), add = TRUE)
  
  st <- new_sideview_state()
  sv_save_state(st, tf)
  
  # In automated/testthat runs interactive() is FALSE
  res <- sv_load_state(tf, launch = TRUE)
  expect_s3_class(res, "sideview_state")
  expect_equal(res$version, "0.3.0")
})

state_json_fixture <- paste0(
  '{"version":"0.3.0","canvas":{"zoom":0.8333333,"pan_x":12.25,"pan_y":-3},',
  '"cards":[{"id":"c1","name":"a","x":1.125,"y":40,"width":null,"height":310,"minimized":false,',
  '"sorts":[],"filters":[{"col":"x","op":"gt","val":"5"}]}],',
  '"connections":[{"from_table":"a","from_col":"id","to_table":"b","to_col":"id","join_type":"left_join"}],',
  '"pipeline":{"code":"a %>% filter(x > 5)","active_tab":"pipeline",',
  '"steps":[{"kind":"filter","table":"a","conds":["x > 5"],"id":"s1","enabled":true}],"pipe":"|>"}}'
)

test_that("sv_state_json keeps nulls, one-element arrays and full precision", {
  st <- sv_state_from_json(state_json_fixture)
  expect_s3_class(st, "sideview_state")
  js <- sv_state_json(st)
  expect_match(js, '"conds":["x > 5"]', fixed = TRUE)
  expect_match(js, '"sorts":[]', fixed = TRUE)
  expect_match(js, '"width":null', fixed = TRUE)
  expect_match(js, '"zoom":0.8333333', fixed = TRUE)
  expect_match(js, '"x":1.125', fixed = TRUE)
  # Stable through a file round trip.
  tf <- tempfile(fileext = ".json")
  on.exit(unlink(tf), add = TRUE)
  sv_save_state(st, tf)
  expect_identical(sv_state_json(sv_load_state(tf)), js)
  expect_error(sv_state_from_json("[1, 2]"), "root object must be a list")
  expect_error(sv_state_from_json(""), "expected JSON text")
})

test_that("sv_as_state accepts NULL, a state, a list or a file path", {
  expect_null(sv_as_state(NULL))
  st <- sv_as_state(list(version = "0.3.0", cards = list()))
  expect_s3_class(st, "sideview_state")
  tf <- tempfile(fileext = ".json")
  on.exit(unlink(tf), add = TRUE)
  sv_save_state(new_sideview_state(canvas = list(zoom = 2, pan_x = 1, pan_y = 2)), tf)
  expect_equal(sv_as_state(tf)$canvas$zoom, 2)
  expect_error(sv_as_state(42), "must be a sideview_state")
})

test_that("sideview_ui embeds the state as escaped JSON for the engine", {
  st <- new_sideview_state(
    cards = list(list(name = "mtcars", x = 10, y = 20)),
    pipeline = list(code = "# </script><b>x</b>", active_tab = "pipeline")
  )
  html <- as.character(sideview_ui(list(sv_normalize(mtcars, name = "mtcars")), gadget = TRUE, state = st))
  expect_match(html, '<script type="application/json" class="sideview-state">', fixed = TRUE)
  expect_false(grepl("</script><b>", html, fixed = TRUE))
  body <- regmatches(html, regexpr('(?s)class="sideview-state">.*?</script>', html, perl = TRUE))
  json <- sub('(?s)^class="sideview-state">(.*)</script>$', "\\1", body, perl = TRUE)
  expect_identical(jsonlite::fromJSON(json)$pipeline$code, "# </script><b>x</b>")
  expect_false(grepl("sideview-state", as.character(sideview_ui(list(), gadget = TRUE)), fixed = TRUE))
})

test_that("Save/Open go through R only when RStudio's file dialog exists", {
  cards <- list(sv_normalize(mtcars, name = "mtcars"))
  testthat::local_mocked_bindings(sv_has_file_dialog = function() TRUE)
  expect_match(as.character(sideview_ui(cards, gadget = TRUE)), 'data-sv-file-dialog="r"', fixed = TRUE)
  expect_false(grepl("data-sv-file-dialog", as.character(sideview_ui(cards, gadget = FALSE)), fixed = TRUE))
  testthat::local_mocked_bindings(sv_has_file_dialog = function() FALSE)
  expect_false(grepl("data-sv-file-dialog", as.character(sideview_ui(cards, gadget = TRUE)), fixed = TRUE))
})

test_that("sideview() and sideview_widget() pass state through", {
  tf <- tempfile(fileext = ".json")
  on.exit(unlink(tf), add = TRUE)
  sv_save_state(new_sideview_state(cards = list(list(name = "mtcars", x = 5, y = 6))), tf)
  got <- NULL
  testthat::local_mocked_bindings(sideview_ui = function(..., state = NULL) {
    got <<- state
    htmltools::div()
  })
  sideview(mtcars, state = tf, run = FALSE)
  expect_s3_class(got, "sideview_state")
  expect_equal(got$cards[[1]]$x, 5)

  w <- sideview_widget(mtcars, state = tf)
  expect_type(w$x$options$state, "character")
  expect_identical(jsonlite::fromJSON(w$x$options$state)$cards$name, "mtcars")
  expect_null(sideview_widget(mtcars)$x$options$state)
})

test_that("sv_load_state(launch = TRUE) launches sideview() with the state and its tables", {
  tf <- tempfile(fileext = ".json")
  on.exit(unlink(tf), add = TRUE)
  sv_save_state(new_sideview_state(cards = list(list(name = "pts_state_test"), list(name = "gone"))), tf)
  pts_state_test <- data.frame(id = 1:3)
  other_tbl <- data.frame(z = 1)
  got <- NULL
  testthat::local_mocked_bindings(
    sv_interactive = function() TRUE,
    sideview = function(...) { got <<- list(...); "launched" }
  )
  expect_identical(sv_load_state(tf, launch = TRUE, viewer = "pane"), "launched")
  expect_named(got[[1]], "pts_state_test")
  expect_s3_class(got$state, "sideview_state")
  expect_identical(got$viewer, "pane")

  # Explicit tables win.
  sv_load_state(tf, tables = list(x = mtcars), launch = TRUE)
  expect_named(got[[1]], "x")

  tf2 <- tempfile(fileext = ".json")
  on.exit(unlink(tf2), add = TRUE)
  sv_save_state(new_sideview_state(cards = list(list(name = "no_such_table_xyz"))), tf2)
  f <- function() sv_load_state(tf2, launch = TRUE)
  expect_error(f(), "None of the saved tables \\(no_such_table_xyz\\)")
})

test_that("sv_choose_state_path writes a new file in getwd() without RStudio", {
  testthat::local_mocked_bindings(sv_has_file_dialog = function() FALSE)
  withr::local_dir(withr::local_tempdir())
  p1 <- sv_choose_state_path()
  expect_identical(basename(p1), "sideview-workspace.json")
  writeLines("{}", p1)
  expect_identical(basename(sv_choose_state_path()), "sideview-workspace_2.json")
  expect_error(sv_choose_state_path(existing = TRUE), "No file dialog")
})

test_that("the server saves the canvas state and opens one from the file dialog", {
  cards <- list(sv_normalize(data.frame(id = 1:3, x = c(4, 6, 8)), name = "a"))
  tf <- tempfile(fileext = ".json")
  on.exit(unlink(tf), add = TRUE)
  testthat::local_mocked_bindings(sv_choose_state_path = function(existing = FALSE) tf)
  shiny::testServer(sideview_server(cards), {
    last_msg <- function() {
      msgs <- session$userData$custom_messages
      msgs[[length(msgs)]]
    }
    session$setInputs(state_save = list(json = state_json_fixture, nonce = 1))
    m <- last_msg()
    expect_identical(m$type, "sideview_state_saved")
    expect_equal(m$message$n_cards, 1)
    expect_true(file.exists(tf))
    saved <- sv_load_state(tf)
    expect_equal(saved$cards[[1]]$x, 1.125)
    expect_identical(saved$pipeline$steps[[1]]$conds, list("x > 5"))

    session$setInputs(state_open_request = 2)
    m <- last_msg()
    expect_identical(m$type, "sideview_state_loaded")
    expect_identical(m$message$json, sv_state_json(sv_state_from_json(state_json_fixture)))

    session$setInputs(state_save = list(json = "[1, 2]", nonce = 3))
    expect_match(last_msg()$message$error, "root object must be a list")
  })
  testthat::local_mocked_bindings(sv_choose_state_path = function(existing = FALSE) NULL)
  shiny::testServer(sideview_server(cards), {
    session$setInputs(state_open_request = 1)
    msgs <- session$userData$custom_messages
    expect_true(isTRUE(msgs[[length(msgs)]]$message$cancelled))
  })
})
