visits <- data.frame(id = 1:5, site = letters[1:5], stringsAsFactors = FALSE)
labs <- data.frame(id = 1:8, lab_date = as.Date("2026-01-01") + 0:7, value = c(1.5, 2, 3, 4, 5, 6, 7, 8))

msgs <- function(session, type) {
  Filter(function(m) identical(m$type, type), session$userData$custom_messages)
}

start_module <- function(...) list(id = "cv", cards = list(visits = visits, labs = labs), ...)

test_that("nothing is sent before ready", {
  shiny::testServer(sideviewServer, args = start_module(), {
    expect_length(msgs(session, "sideview_card_add"), 0L)
  })
})

test_that("ready sends every card in store order with ns", {
  shiny::testServer(sideviewServer, args = start_module(), {
    session$setInputs(sideview_ready = list(nonce = 1))
    adds <- msgs(session, "sideview_card_add")
    expect_length(adds, 2L)
    expect_equal(vapply(adds, function(m) m$message$card$name, ""), c("visits", "labs"))
    for (m in session$userData$custom_messages) expect_identical(m$message$ns, session$ns(""))
    expect_true(all(vapply(adds, function(m) isTRUE(m$message$card$remote), TRUE)))
    expect_true(all(vapply(adds, function(m) nrow(m$message$card$data) <= 500L, TRUE)))
  })
})

test_that("a second ready resends the cards", {
  shiny::testServer(sideviewServer, args = start_module(), {
    session$setInputs(sideview_ready = list(nonce = 1))
    session$setInputs(sideview_ready = list(nonce = 2))
    expect_length(msgs(session, "sideview_card_add"), 4L)
  })
})

test_that("state is queued until ready, after the cards", {
  st <- new_sideview_state()
  shiny::testServer(sideviewServer, args = start_module(state = st), {
    expect_length(msgs(session, "sideview_state_set"), 0L)
    session$setInputs(sideview_ready = list(nonce = 1))
    types <- vapply(session$userData$custom_messages, function(m) m$type, "")
    expect_equal(types, c("sideview_card_add", "sideview_card_add", "sideview_state_set"))
    expect_type(msgs(session, "sideview_state_set")[[1]]$message$state, "character")
  })
})

test_that("verbs update the store before sending", {
  shiny::testServer(sideviewServer, args = start_module(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    sv_replace_card(px, "labs", labs[0, ])
    expect_equal(nrow(px$ctl$store$get("labs")$data), 0L)
    last <- session$userData$custom_messages[[length(session$userData$custom_messages)]]
    expect_equal(last$type, "sideview_card_replace")
    expect_identical(last$message$card$totalRows, 0L)
  })
})

test_that("a 0-row card serialises column-wise (the engine reads the columns from the keys)", {
  p <- sv_card_payload(sv_normalize(labs[0, ], name = "labs"), sv_preview_rows)
  json <- as.character(shiny:::toJSON(list(card = p)))
  parsed <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  expect_equal(names(parsed$card$data), c("id", "lab_date", "value"))
  expect_true(all(vapply(parsed$card$data, length, 1L) == 0L))
  expect_match(json, "\"data\":{\"id\":[],\"lab_date\":[],\"value\":[]}", fixed = TRUE)
})

test_that("replace keeps the card id, so row requests from the browser still resolve", {
  shiny::testServer(sideviewServer, args = start_module(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    old_id <- px$ctl$store$get("labs")$id
    sv_replace_card(px, "labs", labs[1:3, ])
    expect_identical(px$ctl$store$get("labs")$id, old_id)
    session$setInputs(sideview_rows_request = list(card_id = old_id, offset = 0L, limit = 10L, version = 1L))
    rows <- msgs(session, "sideview_rows")
    expect_length(rows, 1L)
    expect_equal(rows[[1]]$message$total, 3L)
  })
})

test_that("cards() updates right after a verb", {
  shiny::testServer(sideviewServer, args = start_module(), {
    px <- session$getReturned()
    expect_equal(px$cards(), c("visits", "labs"))
    sv_add_card(px, mtcars, "cars")
    expect_equal(px$cards(), c("visits", "labs", "cars"))
    sv_remove_card(px, "visits")
    expect_equal(px$cards(), c("labs", "cars"))
  })
})

test_that("reactive cards are diffed by name", {
  rv <- shiny::reactiveVal(list(a = visits, b = labs))
  shiny::testServer(sideviewServer, args = list(id = "cv", cards = shiny::reactive(rv())), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    session$flushReact()
    n0 <- length(session$userData$custom_messages)
    expect_equal(n0, 2L)

    rv(list(b = labs[1:3, ], c = mtcars))
    session$flushReact()
    new <- session$userData$custom_messages[-seq_len(n0)]
    expect_equal(
      vapply(new, function(m) paste(m$type, m$message$card$name %||% m$message$name), ""),
      c("sideview_card_replace b", "sideview_card_add c", "sideview_card_remove a")
    )
    expect_equal(px$cards(), c("b", "c"))

    n1 <- length(session$userData$custom_messages)
    rv(list(b = labs[1:3, ], c = mtcars))
    session$flushReact()
    expect_length(session$userData$custom_messages, n1)
  })
})

test_that("errors use the documented messages", {
  shiny::testServer(sideviewServer, args = start_module(), {
    px <- session$getReturned()
    expect_error(sv_add_card(px, mtcars, "labs"),
                 "Card 'labs' already exists; use sv_replace_card()", fixed = TRUE)
    expect_error(sv_replace_card(px, "labz", mtcars),
                 "No card 'labz'. Cards: visits, labs", fixed = TRUE)
    expect_error(sv_remove_card(px, "labz"),
                 "No card 'labz'. Cards: visits, labs", fixed = TRUE)
    expect_error(sv_add_card(px, mtcars, c("a", "b")), "'name' must be a single string", fixed = TRUE)
    expect_error(sv_highlight(px, 1, "a"), "'name' must be a single string", fixed = TRUE)
    expect_error(sv_highlight(px, "labs", 1:2), "'cols' must be a character vector", fixed = TRUE)
    expect_error(sideviewProxy("nope"),
                 "sideviewServer(\"nope\") has not been started in this session", fixed = TRUE)
  })
  expect_error(sideviewProxy("cv", session = NULL),
               "sideviewProxy() needs a Shiny session: call it inside a server function", fixed = TRUE)
})

test_that("verbs pipe and highlight is queued until ready", {
  shiny::testServer(sideviewServer, args = start_module(), {
    px <- session$getReturned()
    out <- px |> sv_highlight("labs", c("lab_date", "value"))
    expect_identical(out, px)
    expect_length(msgs(session, "sideview_highlight"), 0L)
    session$setInputs(sideview_ready = list(nonce = 1))
    h <- msgs(session, "sideview_highlight")
    expect_length(h, 1L)
    expect_equal(unlist(h[[1]]$message$cols), c("lab_date", "value"))
    sv_set_state(px, new_sideview_state())
    expect_length(msgs(session, "sideview_state_set"), 1L)
  })
})

test_that("code-running inputs are refused in module mode", {
  shiny::testServer(sideviewServer, args = start_module(), {
    expect_no_error({
      session$setInputs(eval_env = list(code = "stop('ran')"))
      session$setInputs(inject_script = list(code = "x"))
      session$setInputs(send_console = list(code = "x"))
      session$setInputs(send_console_and_exit = list(code = "x"))
    })
    expect_length(msgs(session, "sideview_eval_result"), 0L)
    expect_length(msgs(session, "sideview_inject_result"), 0L)
    expect_length(msgs(session, "sideview_console_result"), 0L)
  })
})

test_that("snapshot sets the reactives and sends nothing back", {
  shiny::testServer(sideviewServer, args = start_module(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    n0 <- length(session$userData$custom_messages)
    session$setInputs(sideview_snapshot = list(
      code = "x <- 1", pipeline = "[]",
      state = sv_state_json(new_sideview_state()), cards = list()
    ))
    expect_equal(px$code(), "x <- 1")
    expect_identical(px$pipeline(), list())
    expect_s3_class(px$state(), "sideview_state")
    expect_length(session$userData$custom_messages, n0)
  })
})

test_that("bad snapshots are dropped", {
  shiny::testServer(sideviewServer, args = start_module(), {
    px <- session$getReturned()
    good <- list(code = "x <- 1", pipeline = "[]", state = sv_state_json(new_sideview_state()))
    session$setInputs(sideview_snapshot = good)
    expect_warning(
      session$setInputs(sideview_snapshot = list(code = strrep("a", 2e6), pipeline = "[]")),
      "dropped"
    )
    expect_equal(px$code(), "x <- 1")
    # the warning goes to the log once per canvas
    expect_no_warning(session$setInputs(sideview_snapshot = list(code = "y", pipeline = "{")))
    expect_equal(px$code(), "x <- 1")
    session$setInputs(sideview_snapshot = list(code = list(1, 2), pipeline = "[]"))
    expect_equal(px$code(), "")
  })
})

test_that("sv_parse_snapshot", {
  expect_null(suppressWarnings(sv_parse_snapshot(list(code = "a", pipeline = "{"))))
  expect_warning(sv_parse_snapshot(list(code = "a", state = "[")), "dropped")
  ok <- sv_parse_snapshot(list(code = "a", pipeline = "[{\"type\":\"filter\"}]"))
  expect_equal(ok$pipeline[[1]]$type, "filter")
  expect_null(ok$state)
  expect_equal(sv_parse_snapshot(list(code = c("a", "b")))$code, "")
})

test_that("nested modules find the canvas and carry the full prefix", {
  outer <- function(id) {
    shiny::moduleServer(id, function(input, output, session) {
      px1 <- sideviewServer("review", cards = list(visits = visits))
      px2 <- sideviewProxy("review")
      list(px1 = px1, px2 = px2)
    })
  }
  shiny::testServer(outer, args = list(id = "outer"), {
    both <- session$getReturned()
    expect_identical(both$px1$ctl, both$px2$ctl)
    session$setInputs(`review-sideview_ready` = list(nonce = 1))
    adds <- msgs(session, "sideview_card_add")
    expect_length(adds, 1L)
    expect_identical(adds[[1]]$message$ns, session$ns("review-"))
    expect_match(adds[[1]]$message$ns, "outer-review-", fixed = TRUE)
  })
})

test_that("lazy card replaced in a module", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbWriteTable(con, "big", data.frame(id = 1:1000, v = 1000:1))
  shiny::testServer(sideviewServer, args = start_module(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    sv_replace_card(px, "labs", dplyr::tbl(con, "big"))
    last <- session$userData$custom_messages[[length(session$userData$custom_messages)]]
    expect_equal(last$type, "sideview_card_replace")
    expect_equal(last$message$card$lazy, "duckdb")
    expect_equal(last$message$card$totalRows, 1000L)
    expect_null(last$message$card$source)
    id <- px$ctl$store$get("labs")$id
    session$setInputs(sideview_rows_request = list(card_id = id, offset = 0L, limit = 5L, version = 1L))
    rows <- msgs(session, "sideview_rows")
    expect_equal(rows[[1]]$message$total, 1000L)
  })
})

test_that("module UI has no code-running buttons and no html-level rules", {
  html <- as.character(sideviewUI("cv"))
  expect_match(html, "data-sv-ns=\"cv-\"", fixed = TRUE)
  expect_false(grepl("data-r-only", html, fixed = TRUE))
  expect_false(grepl("sv-standalone", html, fixed = TRUE))
  expect_false(grepl("id=\"sideview-chat-input\"", html, fixed = TRUE))
  expect_false(grepl("sideview-brand", html, fixed = TRUE))
  expect_match(html, "height: 600px; position: relative", fixed = TRUE)
  expect_match(html, "mode: 'embedded', ns: ns", fixed = TRUE)
  expect_match(as.character(sideviewUI("cv", title = "Review")), "sideview-brand", fixed = TRUE)
  # the gadget UI keeps its code buttons
  expect_match(as.character(sideview_ui(list(a = mtcars))), "data-r-only", fixed = TRUE)
})

test_that("codebook in a module replies with csv", {
  shiny::testServer(sideviewServer, args = start_module(), {
    session$setInputs(codebook_export = list(at = 1))
    saved <- msgs(session, "sideview_codebook_saved")
    expect_length(saved, 1L)
    csv <- saved[[1]]$message$csv
    expect_true(is.character(csv) && nzchar(csv))
    cb <- utils::read.csv(text = csv)
    expect_true("rows_profiled" %in% names(cb))
    expect_equal(saved[[1]]$message$filename, "codebook.csv")
  })
})
