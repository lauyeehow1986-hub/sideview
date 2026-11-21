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
    # the ready-time population is flagged initial, so the browser does not announce it
    expect_true(all(vapply(adds, function(m) isTRUE(m$message$initial), TRUE)))
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
    expect_equal(types[types != "sideview_llm"], c("sideview_card_add", "sideview_card_add", "sideview_state_set"))
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
    expect_equal(n0, 3L) # two cards and the llm notice (no llm_fn)

    rv(list(b = labs[1:3, ], c = mtcars))
    session$flushReact()
    new <- session$userData$custom_messages[-seq_len(n0)]
    expect_equal(
      vapply(new, function(m) paste(m$type, m$message$card$name %||% m$message$name), ""),
      c("sideview_card_replace b", "sideview_card_add c", "sideview_card_remove a")
    )
    expect_equal(px$cards(), c("b", "c"))
    # a reactive add is not initial: the browser announces it
    added <- Filter(function(m) m$type == "sideview_card_add", new)
    expect_null(added[[1]]$message$initial)

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

test_that("forged LLM settings in module inputs are ignored", {
  seen <- list()
  llm <- function(prompt, backend, model, endpoint, api_key) {
    seen[[length(seen) + 1L]] <<- list(backend = backend, model = model, endpoint = endpoint, api_key = api_key)
    "x <- 1"
  }
  withr::local_options(sideview.llm_backend = "ollama", sideview.llm_model = "m0",
                       sideview.llm_endpoint = NULL, sideview.llm_api_key = NULL)
  forged <- list(backend = "openai", model = "evil", endpoint = "http://evil.example", api_key = "k")
  shiny::testServer(sideviewServer, args = start_module(llm_fn = llm), {
    session$setInputs(run_ai_prompt = c(list(prompt = "count rows"), forged))
    session$setInputs(send_copilot_chat = c(list(message = "hi"), forged))
  })
  expect_length(seen, 2L)
  for (s in seen) {
    expect_identical(s$backend, "ollama")
    expect_identical(s$model, "m0")
    expect_null(s$endpoint)
    expect_null(s$api_key)
  }
})

test_that("widget cards are sent as html in a module: initial, reactive and verbs", {
  wcard <- function(txt) new_sideview_card(name = "w", type = "widget", widget = htmltools::tags$div(txt))
  rv <- shiny::reactiveVal(list(w = wcard("first")))
  shiny::testServer(sideviewServer, args = list(id = "cv", cards = shiny::reactive(rv())), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    session$flushReact()
    add <- msgs(session, "sideview_card_add")[[1]]$message$card
    expect_match(add$html_content, "first", fixed = TRUE)
    expect_null(add$widget)
    rv(list(w = wcard("second")))
    session$flushReact()
    rep <- msgs(session, "sideview_card_replace")[[1]]$message$card
    expect_match(rep$html_content, "second", fixed = TRUE)
    expect_null(rep$widget)
    sv_add_card(px, wcard("third"), "w3")
    last <- session$userData$custom_messages[[length(session$userData$custom_messages)]]$message$card
    expect_match(last$html_content, "third", fixed = TRUE)
  })
})

test_that("without llm_fn the canvas is told to hide the AI bar, with one it is not", {
  shiny::testServer(sideviewServer, args = start_module(), {
    expect_length(msgs(session, "sideview_llm"), 0L)
    session$setInputs(sideview_ready = list(nonce = 1))
    m <- msgs(session, "sideview_llm")
    expect_length(m, 1L)
    expect_false(m[[1]]$message$enabled)
    expect_identical(m[[1]]$message$ns, session$ns(""))
  })
  shiny::testServer(sideviewServer, args = start_module(llm_fn = function(...) "x"), {
    session$setInputs(sideview_ready = list(nonce = 1))
    expect_length(msgs(session, "sideview_llm"), 0L)
  })
})


test_that("a reactive cards that stops with req() means no cards yet", {
  rv <- shiny::reactiveVal(NULL)
  shiny::testServer(sideviewServer, args = list(id = "cv", cards = shiny::reactive({ shiny::req(rv()) })), {
    px <- session$getReturned()
    expect_length(px$cards(), 0L)
    session$setInputs(sideview_ready = list(nonce = 1))
    session$flushReact()
    expect_length(msgs(session, "sideview_card_add"), 0L)

    rv(list(a = visits, b = labs))
    session$flushReact()
    expect_equal(px$cards(), c("a", "b"))
    expect_equal(px$ctl$store$names(), c("a", "b"))
    adds <- msgs(session, "sideview_card_add")
    expect_equal(vapply(adds, function(m) m$message$card$name, ""), c("a", "b"))
  })
})

test_that("cards that become valid before the canvas is ready are sent at ready", {
  rv <- shiny::reactiveVal(NULL)
  shiny::testServer(sideviewServer, args = list(id = "cv", cards = shiny::reactive({ shiny::req(rv()) })), {
    rv(list(a = visits, b = labs))
    session$flushReact()
    expect_length(msgs(session, "sideview_card_add"), 0L)
    session$setInputs(sideview_ready = list(nonce = 1))
    expect_length(msgs(session, "sideview_card_add"), 2L)
  })
})

test_that("a reactive cards that errors at start warns with the id and starts empty", {
  bad <- shiny::reactive(stop("feed not there"))
  expect_warning(
    shiny::testServer(sideviewServer, args = list(id = "cv", cards = bad), {
      expect_length(session$getReturned()$cards(), 0L)
    }),
    "cv"
  )
})

test_that("a reactive refresh whose element does not normalise keeps the old card and warns once", {
  rv <- shiny::reactiveVal(list(a = visits, b = labs))
  shiny::testServer(sideviewServer, args = list(id = "cv", cards = shiny::reactive(rv())), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    session$flushReact()
    n0 <- length(session$userData$custom_messages)
    expect_warning({
      rv(list(a = visits, b = sum))
      session$flushReact()
    }, "b")
    expect_equal(px$cards(), c("a", "b"))
    expect_length(msgs(session, "sideview_card_remove"), 0L)
    expect_warning({
      rv(list(a = visits[1:2, ], b = sum))
      session$flushReact()
    }, NA)
    expect_equal(px$cards(), c("a", "b"))
    expect_equal(nrow(px$ctl$store$get("a")$data), 2L)
  })
})

test_that("height goes through validateCssUnit", {
  expect_match(as.character(sideviewUI("cv", height = 600)), "height: 600px; position: relative", fixed = TRUE)
  expect_match(as.character(sideviewUI("cv", height = "50%")), "height: 50%; position: relative", fixed = TRUE)
})

test_that("the module codebook csv is the file write.csv wrote, byte for byte", {
  shiny::testServer(sideviewServer, args = start_module(), {
    session$setInputs(codebook_export = list(at = 1))
    csv <- msgs(session, "sideview_codebook_saved")[[1]]$message$csv
    # write.csv ends every line, the last too, with the platform's line break; keep it as written
    eol <- if (.Platform$OS.type == "windows") "\r\n" else "\n"
    expect_true(endsWith(csv, eol))
    expect_gt(lengths(regmatches(csv, gregexpr(eol, csv, fixed = TRUE))), 1L)
  })
})

test_that("replacing an Arrow card unregisters the old table from the session connection", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  mk <- function(n) arrow::arrow_table(id = 1:n, v = n:1)
  shiny::testServer(sideviewServer, args = list(id = "cv", cards = list(labs = mk(20), other = mk(5))), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    con_env <- session$userData$sv_lazy_env
    rows <- function(name, ver) {
      id <- px$ctl$store$get(name)$id
      session$setInputs(sideview_rows_request = list(card_id = id, offset = 0L, limit = 5L, version = ver))
    }
    rows("labs", 1L)
    rows("other", 2L)
    n_registered <- function() length(duckdb::duckdb_list_arrow(con_env$con))
    expect_equal(n_registered(), 2L)
    for (i in 1:3) {
      sv_replace_card(px, "labs", mk(20 + i))
      rows("labs", 10L + i)
      expect_equal(n_registered(), 2L, info = paste("replace", i))
    }
    # the rows still come from the new table
    last <- msgs(session, "sideview_rows")
    expect_equal(last[[length(last)]]$message$total, 23L)
    # removing a card unregisters its table too
    sv_remove_card(px, "labs")
    expect_equal(n_registered(), 1L)
  })
})

# ---- CDISC tag updates --------------------------------------------------------------
cdisc_start <- function(...) list(id = "cd", cards = list(dm = sv_cdisc_fixtures()$dm), ...)

test_that("adding a SEND domain updates DM's tag", {
  f <- sv_cdisc_fixtures()
  shiny::testServer(sideviewServer, args = cdisc_start(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    dm_id <- px$ctl$store$get("dm")$id
    expect_equal(msgs(session, "sideview_card_add")[[1]]$message$card$cdisc$standard, "SDTM")
    sv_add_card(px, f$bw, "bw")
    add <- msgs(session, "sideview_card_add")
    expect_equal(add[[length(add)]]$message$card$cdisc$standard, "SEND")
    up <- msgs(session, "sideview_cdisc_update")
    expect_length(up, 1L)
    expect_equal(names(up[[1]]$message$tags), dm_id)
    expect_equal(up[[1]]$message$tags[[dm_id]]$standard, "SEND")
    expect_identical(up[[1]]$message$ns, session$ns(""))
  })
})

test_that("removing the SEND domain flips DM back", {
  f <- sv_cdisc_fixtures()
  shiny::testServer(sideviewServer, args = cdisc_start(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    dm_id <- px$ctl$store$get("dm")$id
    sv_add_card(px, f$bw, "bw")
    sv_remove_card(px, "bw")
    up <- msgs(session, "sideview_cdisc_update")
    expect_length(up, 2L)
    expect_equal(up[[2]]$message$tags[[dm_id]]$standard, "SDTM")
  })
})

test_that("no update when nothing changes", {
  shiny::testServer(sideviewServer, args = cdisc_start(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    sv_add_card(px, mtcars, "mt")
    expect_length(msgs(session, "sideview_cdisc_update"), 0L)
  })
})

test_that("cdisc updates before ready are not replayed: the cards carry current tags", {
  f <- sv_cdisc_fixtures()
  shiny::testServer(sideviewServer, args = cdisc_start(), {
    px <- session$getReturned()
    sv_add_card(px, f$bw, "bw")
    expect_length(msgs(session, "sideview_cdisc_update"), 0L)
    session$setInputs(sideview_ready = list(nonce = 1))
    expect_length(msgs(session, "sideview_cdisc_update"), 0L)
    adds <- msgs(session, "sideview_card_add")
    expect_equal(vapply(adds, function(m) m$message$card$cdisc$standard, ""), c("SEND", "SEND"))
  })
})

test_that("a queued cdisc update cannot overwrite a fresher payload at ready", {
  f <- sv_cdisc_fixtures()
  shiny::testServer(sideviewServer, args = cdisc_start(), {
    px <- session$getReturned()
    old_id <- px$ctl$store$get("dm")$id
    sv_add_card(px, f$bw, "bw")                 # queues {dm: SEND}
    sv_replace_card(px, "dm", mtcars)           # dm is no longer taggable
    new_id <- px$ctl$store$get("dm")$id
    session$setInputs(sideview_ready = list(nonce = 1))
    updates <- msgs(session, "sideview_cdisc_update")
    stale <- Filter(function(m) any(c(old_id, new_id) %in% names(m$message$tags)), updates)
    expect_length(stale, 0L)
    dm_add <- Filter(function(m) identical(m$message$card$name, "dm"),
                     msgs(session, "sideview_card_add"))
    expect_null(dm_add[[1]]$message$card$cdisc)
  })
})

test_that("a reactive re-firing with the same data replaces nothing", {
  f <- sv_cdisc_fixtures()
  rv <- shiny::reactiveVal(list(dm = f$dm, bw = f$bw))
  shiny::testServer(sideviewServer, args = list(id = "cd", cards = rv), {
    session$setInputs(sideview_ready = list(nonce = 1))
    rv(list(dm = f$dm, bw = f$bw))
    session$flushReact()
    expect_length(msgs(session, "sideview_card_replace"), 0L)
    expect_length(msgs(session, "sideview_card_add"), 2L)
  })
})

test_that("cdisc = FALSE in a module tags nothing", {
  f <- sv_cdisc_fixtures()
  shiny::testServer(sideviewServer, args = cdisc_start(cdisc = FALSE), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    sv_add_card(px, f$bw, "bw")
    for (m in msgs(session, "sideview_card_add")) expect_null(m$message$card$cdisc)
    expect_length(msgs(session, "sideview_cdisc_update"), 0L)
  })
})

# ---- CDISC fix round 1 ----------------------------------------------------------------
test_that("sideviewServer validates cdisc", {
  for (bad in list(TRUE, c("AE", "LB"), "foo")) {
    expect_error(shiny::testServer(sideviewServer, args = cdisc_start(cdisc = bad), {}), "cdisc")
  }
})

test_that("a tag in the update is normalised like the card payload", {
  f <- sv_cdisc_fixtures()
  shiny::testServer(sideviewServer, args = cdisc_start(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    dm_id <- px$ctl$store$get("dm")$id
    sv_add_card(px, f$bw, "bw")
    tag <- msgs(session, "sideview_cdisc_update")[[1]]$message$tags[[dm_id]]
    expect_type(tag$evidence, "list")
    expect_false(any(vapply(tag, is.null, TRUE)))
  })
  tag1 <- sv_cdisc_wire_tag(list(domain = "DM", evidence = "one", extra = NULL))
  expect_type(tag1$evidence, "list")
  expect_null(sv_cdisc_wire_tag(NULL))
})

test_that("a re-firing reactive with other data replaces only what changed", {
  f <- sv_cdisc_fixtures()
  rv <- shiny::reactiveVal(list(dm = f$dm, bw = f$bw))
  shiny::testServer(sideviewServer, args = list(id = "cd", cards = rv), {
    session$setInputs(sideview_ready = list(nonce = 1))
    rv(list(dm = f$dm, bw = f$bw, mt = mtcars))
    session$flushReact()
    expect_length(msgs(session, "sideview_card_replace"), 0L)
    adds <- vapply(msgs(session, "sideview_card_add"), function(m) m$message$card$name, "")
    expect_equal(adds, c("dm", "bw", "mt"))
  })
})

test_that("changed data and a moved tag give a replace and an update", {
  f <- sv_cdisc_fixtures()
  rv <- shiny::reactiveVal(list(dm = f$dm, bw = f$bw))
  shiny::testServer(sideviewServer, args = list(id = "cd", cards = rv), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    dm_id <- px$ctl$store$get("dm")$id
    expect_equal(px$ctl$store$get("dm")$cdisc$standard, "SEND")
    rv(list(dm = f$dm, bw = mtcars))
    session$flushReact()
    rep <- msgs(session, "sideview_card_replace")
    expect_length(rep, 1L)
    expect_equal(rep[[1]]$message$card$name, "bw")
    up <- msgs(session, "sideview_cdisc_update")
    expect_equal(up[[length(up)]]$message$tags[[dm_id]]$standard, "SDTM")
  })
})

test_that("a named override applies in a module, also to a later card", {
  f <- sv_cdisc_fixtures()
  suppressWarnings(shiny::testServer(sideviewServer, args = cdisc_start(cdisc = c(odd = "AE")), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    sv_add_card(px, f$labs, "odd")
    add <- msgs(session, "sideview_card_add")
    expect_equal(add[[length(add)]]$message$card$cdisc$domain, "AE")
    expect_equal(add[[length(add)]]$message$card$cdisc$source, "user")
  }))
})

test_that("sv_replace_card emits an update for other cards", {
  f <- sv_cdisc_fixtures()
  shiny::testServer(sideviewServer, args = cdisc_start(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    sv_add_card(px, mtcars, "bw")
    expect_length(msgs(session, "sideview_cdisc_update"), 0L)
    dm_id <- px$ctl$store$get("dm")$id
    sv_replace_card(px, "bw", f$bw)
    up <- msgs(session, "sideview_cdisc_update")
    expect_length(up, 1L)
    expect_equal(up[[1]]$message$tags[[dm_id]]$standard, "SEND")
  })
})

test_that("unknown override names warn once at start for static cards only", {
  expect_warning(
    shiny::testServer(sideviewServer, args = cdisc_start(cdisc = c(nope = "AE")), {
      px <- session$getReturned()
      sv_add_card(px, mtcars, "mt")
    }),
    "names no table"
  ) |> suppressMessages()
  rv <- shiny::reactiveVal(list())
  expect_no_warning(
    shiny::testServer(sideviewServer, args = list(id = "cd", cards = rv, cdisc = c(later = "AE")), {
      rv(list(later = sv_cdisc_fixtures()$labs))
      session$flushReact()
    })
  )
})

test_that("sideviewUI carries data-sv-view", {
  expect_true(grepl('data-sv-view="canvas"', as.character(sideviewUI("a")), fixed = TRUE))
  expect_true(grepl('data-sv-view="list"', as.character(sideviewUI("a", view = "list")), fixed = TRUE))
  expect_error(sideviewUI("a", view = "grid"), "should be one of")
})

test_that("sideviewUI with an invalid sideview.view option errors", {
  withr::with_options(list(sideview.view = "bogus"),
    expect_error(sideviewUI("a"), "should be one of"))
})

test_that("the module chrome renders no code-execution buttons and no gadget LLM signal", {
  html <- as.character(sideviewUI("cv"))
  for (label in c("Insert Script", "Run &amp; Exit", "Run in R", "Run Console")) {
    expect_false(grepl(label, html, fixed = TRUE), info = label)
  }
  expect_false(grepl("data-sv-llm", html, fixed = TRUE))
  # the gadget says it has an LLM behind its Copilot
  expect_true(grepl('data-sv-llm="true"', as.character(sideview_ui(list(a = mtcars), gadget = TRUE)), fixed = TRUE))
  expect_false(grepl("data-sv-llm", as.character(sideview_ui(list(a = mtcars))), fixed = TRUE))
})

# ---- derive_request / derive_forget (D1 task 5) ----

dv_ae <- data.frame(USUBJID = c("a", "b", "b", "z", NA, "q"), term = letters[1:6], stringsAsFactors = FALSE)
dv_dm <- data.frame(USUBJID = c("a", "b", "c", NA), site = 1:4, stringsAsFactors = FALSE)
dv_sae <- data.frame(USUBJID = c("S1", "S2"), AESEQ = 1:2, stringsAsFactors = FALSE)
dv_supp <- data.frame(RDOMAIN = "AE", USUBJID = c("S1", "S2", "S2"), IDVAR = "AESEQ",
                      IDVARVAL = c("1", "9", "x"), QNAM = "AETRTEM", QVAL = "Y", stringsAsFactors = FALSE)
dv_start <- function() list(id = "cv", cards = list(ae = dv_ae, dm = dv_dm, sae = dv_sae, suppae = dv_supp))
dv_by <- function(x = "USUBJID", y = "USUBJID") list(list(x = x, y = y))
dv_req <- function(id = "r1", op = "unmatched", inputs = list("ae", "dm"), args = list(by = dv_by(), side = "x"),
                   ...) {
  c(list(id = id, op = op, inputs = inputs, args = args), list(...))
}
dv_last <- function(session, type) {
  m <- msgs(session, type)
  if (length(m)) m[[length(m)]]$message else NULL
}

test_that("a valid derive_request adds the card, sends it with request_id, and n equals the offer", {
  shiny::testServer(sideviewServer, args = dv_start(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    n_before <- length(msgs(session, "sideview_card_add"))
    session$setInputs(derive_request = dv_req(
      args = list(by = dv_by(), side = "x", code = "system('id')")))
    expect_true(px$ctl$store$has("ae_unmatched_dm"))
    adds <- msgs(session, "sideview_card_add")
    expect_length(adds, n_before + 1L)
    m <- adds[[length(adds)]]$message
    expect_identical(m$request_id, "r1")
    expect_identical(m$card$name, "ae_unmatched_dm")
    expect_identical(m$card$derived$op, "unmatched")
    expect_identical(unlist(m$card$derived$inputs), c("ae", "dm"))
    # an argument off the allowlist is dropped, not passed on
    expect_null(m$card$derived$args$code)
    expect_identical(m$ns, session$ns(""))
    n <- nrow(sv_unmatched(dv_ae, dv_dm, "USUBJID"))
    expect_identical(m$card$totalRows, n)
    expect_null(dv_last(session, "sideview_derive_result"))
    expect_true("ae_unmatched_dm" %in% px$cards())
  })
})

test_that("a forged derive_request is refused with an error reply and the store unchanged", {
  shiny::testServer(sideviewServer, args = dv_start(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    before <- px$ctl$store$names()
    n_msgs <- length(msgs(session, "sideview_card_add"))
    i <- 0L
    refuse <- function(req, pattern = NULL) {
      i <<- i + 1L
      req$id <- paste0("bad", i)
      session$setInputs(derive_request = req)
      r <- dv_last(session, "sideview_derive_result")
      expect_identical(r$id, req$id)
      expect_true(is.character(r$error) && nzchar(r$error))
      if (!is.null(pattern)) expect_match(r$error, pattern, fixed = TRUE)
      expect_identical(px$ctl$store$names(), before)
      expect_length(msgs(session, "sideview_card_add"), n_msgs)
    }
    refuse(dv_req(op = "system"))
    refuse(dv_req(op = c("unmatched", "outside_window")))
    refuse(dv_req(inputs = list("Sys.getenv", "dm")))
    refuse(dv_req(inputs = list("ae", "ae", "dm")))
    refuse(dv_req(inputs = list("ae")))
    refuse(dv_req(args = list(by = dv_by(y = "x; system('id')"), side = "x")))
    refuse(dv_req(args = list(by = dv_by(x = "x; system('id')"), side = "x")))
    refuse(dv_req(args = list(by = rep(dv_by(), 21L), side = "x")))
    refuse(dv_req(args = list(by = list(), side = "x")))
    refuse(dv_req(args = list(by = dv_by(), side = "z")))
    # mixed key kinds (decision 2): the message is the join check's
    refuse(dv_req(args = list(by = dv_by(x = "term", y = "site"), side = "x")), "dplyr will refuse")
    # a rule with a column the table does not have
    refuse(dv_req(op = "outside_window",
                  args = list(by = dv_by(), side = "x",
                              rule = list(shape = "window", xCol = "nope", yCol = "site", from = 0, to = 1))))
    refuse(dv_req(op = "outside_window"))
    refuse(dv_req(op = "supp_orphans", inputs = list("sae", "suppae"), args = list(rdomain = "AE;drop")))
    refuse(dv_req(op = "supp_orphans", inputs = list("sae", "nope"), args = list(rdomain = "AE")))
    # a request that is not even a list is ignored without a reply
    session$setInputs(derive_request = "unmatched")
    expect_identical(px$ctl$store$names(), before)
  })
})

test_that("an exact name is used as it is, and a taken one is an error", {
  shiny::testServer(sideviewServer, args = dv_start(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    session$setInputs(derive_request = dv_req(id = "n1", name = "my_rows"))
    expect_true(px$ctl$store$has("my_rows"))
    before <- px$ctl$store$names()
    session$setInputs(derive_request = dv_req(id = "n2", name = "my_rows"))
    r <- dv_last(session, "sideview_derive_result")
    expect_identical(r$id, "n2")
    expect_match(r$error, "A table named my_rows is already on the canvas.", fixed = TRUE)
    session$setInputs(derive_request = dv_req(id = "n3", name = "ae"))
    expect_match(dv_last(session, "sideview_derive_result")$error, "already on the canvas", fixed = TRUE)
    expect_identical(px$ctl$store$names(), before)
    # no name: R chooses one and numbers it when taken
    session$setInputs(derive_request = dv_req(id = "n4"))
    session$setInputs(derive_request = dv_req(id = "n5"))
    expect_true(all(c("ae_unmatched_dm", "ae_unmatched_dm_2") %in% px$ctl$store$names()))
  })
})

test_that("a SUPP derive_request takes the plan from R, never from the client", {
  shiny::testServer(sideviewServer, args = dv_start(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    session$setInputs(derive_request = dv_req(
      id = "s1", op = "supp_orphans", inputs = list("sae", "suppae"),
      args = list(rdomain = "AE", plan = list(keys = list("EVIL"), idvars = list()))))
    m <- msgs(session, "sideview_card_add")
    m <- m[[length(m)]]$message
    expect_identical(m$card$name, "suppae_orphans")
    expect_identical(m$request_id, "s1")
    expect_identical(unlist(m$card$derived$args$plan$keys), "USUBJID")
    expect_identical(m$card$derived$args$rdomain, "AE")
    expect_identical(m$card$totalRows, nrow(sv_supp_orphans(dv_sae, dv_supp, "AE")))
    session$setInputs(derive_request = dv_req(
      id = "s2", op = "supp_bad_idvarval", inputs = list("sae", "suppae"), args = list(rdomain = "AE")))
    m2 <- msgs(session, "sideview_card_add")
    m2 <- m2[[length(m2)]]$message
    expect_identical(m2$card$name, "suppae_bad_idvarval")
    expect_identical(m2$card$totalRows, nrow(sv_supp_orphans(dv_sae, dv_supp, "AE", what = "bad_idvarval")))
  })
})

test_that("derive_forget removes a derived card only, and anything else is ignored", {
  shiny::testServer(sideviewServer, args = dv_start(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    session$setInputs(derive_request = dv_req())
    expect_true(px$ctl$store$has("ae_unmatched_dm"))
    session$setInputs(derive_forget = list(name = "ae"))
    expect_true(px$ctl$store$has("ae"))
    session$setInputs(derive_forget = list(name = "nope"))
    session$setInputs(derive_forget = list(name = c("ae", "dm")))
    session$setInputs(derive_forget = "ae_unmatched_dm")
    expect_true(px$ctl$store$has("ae_unmatched_dm"))
    session$setInputs(derive_forget = list(name = "ae_unmatched_dm"))
    expect_false(px$ctl$store$has("ae_unmatched_dm"))
    expect_false("ae_unmatched_dm" %in% px$cards())
    expect_setequal(px$ctl$store$names(), c("ae", "dm", "sae", "suppae"))
  })
})

test_that("the gadget server answers derive_request too", {
  cards <- sv_normalize_cards(list(ae = dv_ae, dm = dv_dm))
  shiny::testServer(sideview_server(cards), {
    session$setInputs(derive_request = dv_req(id = "g1"))
    adds <- msgs(session, "sideview_card_add")
    m <- adds[[length(adds)]]$message
    expect_identical(m$request_id, "g1")
    expect_identical(m$card$name, "ae_unmatched_dm")
    expect_null(m$ns)
    session$setInputs(derive_request = dv_req(id = "g2", op = "nope"))
    expect_match(dv_last(session, "sideview_derive_result")$error, "Unknown")
  })
})

test_that("sv_derive_validate is the one validation path: NULL or the message, exact field names", {
  store <- sv_card_store(sv_normalize_cards(list(ae = dv_ae, dm = dv_dm)))
  expect_null(sv_derive_validate(dv_req(), store))
  expect_match(sv_derive_validate(dv_req(op = "system"), store), "Unknown")
  expect_match(sv_derive_validate(dv_req(inputs = list("Sys.getenv", "dm")), store), "Not in the canvas")
  expect_match(sv_derive_validate(dv_req(args = list(by = dv_by(x = "term", y = "site"), side = "x")), store),
               "dplyr will refuse", fixed = TRUE)
  expect_match(sv_derive_validate(dv_req(name = "ae"), store), "already on the canvas", fixed = TRUE)
  # a field is read by its exact name: `operation` is not `op`
  forged <- list(id = "p", operation = "unmatched", inputs = list("ae", "dm"),
                 args = list(by = dv_by(), side = "x"))
  expect_match(sv_derive_validate(forged, store), "Unknown")
  partial_args <- dv_req(args = list(by = dv_by(), sid = "x"))
  expect_match(sv_derive_validate(partial_args, store), "side")
})

test_that("a payload that cannot be built is an error reply and leaves the store unchanged", {
  shiny::testServer(sideviewServer, args = dv_start(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    before <- px$ctl$store$names()
    n_msgs <- length(msgs(session, "sideview_card_add"))
    testthat::with_mocked_bindings(
      session$setInputs(derive_request = dv_req(id = "pe")),
      sv_card_payload = function(...) stop("boom")
    )
    expect_match(dv_last(session, "sideview_derive_result")$error, "boom")
    expect_identical(px$ctl$store$names(), before)
    expect_length(msgs(session, "sideview_card_add"), n_msgs)
  })
})

test_that("derive add and forget resolve CDISC tags again and broadcast what moved (module)", {
  ae <- data.frame(STUDYID = "S", USUBJID = c("S1", "S2", "S3"), AESEQ = 1:3, AETERM = c("a", "b", "c"),
                   AEDECOD = "x", stringsAsFactors = FALSE)
  dm <- data.frame(STUDYID = "S", USUBJID = c("S1", "S2"), AGE = 1:2, stringsAsFactors = FALSE)
  supp <- data.frame(STUDYID = "S", RDOMAIN = "AE", USUBJID = c("S1", "S2"), IDVAR = "AESEQ",
                     IDVARVAL = c("1", "2"), QNAM = "AETRTEM", QVAL = "Y", stringsAsFactors = FALSE)
  shiny::testServer(sideviewServer, args = list(id = "cv", cards = list(ae = ae, dm = dm, suppae = supp)), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    upd <- function() msgs(session, "sideview_cdisc_update")
    session$setInputs(derive_request = dv_req(
      args = list(by = dv_by(), side = "x")))
    d <- px$ctl$store$get("ae_unmatched_dm")
    # the derived card carries its kept card's tag, and a later resolve does not wipe it
    expect_identical(d$cdisc$domain, "AE")
    supp_id <- px$ctl$store$get("suppae")$id
    n0 <- length(upd())
    # removing the original AE card takes the derived card with it; the proxy path broadcasts once, and
    # SUPPAE has no parent card any more
    sv_remove_card(px, "ae")
    expect_false(px$ctl$store$has("ae_unmatched_dm"))
    expect_length(upd(), n0 + 1L)
    expect_true(supp_id %in% names(upd()[[n0 + 1L]]$message$tags))
    expect_null(upd()[[n0 + 1L]]$message$tags[[supp_id]]$parent_card)
    expect_null(px$ctl$store$get("suppae")$cdisc$parent_card)
  })
})

test_that("derive_forget resolves CDISC tags again and broadcasts the parent that moved", {
  ae <- data.frame(STUDYID = "S", USUBJID = c("S1", "S2", "S3"), AESEQ = 1:3, AETERM = c("a", "b", "c"),
                   AEDECOD = "x", stringsAsFactors = FALSE)
  dm <- data.frame(STUDYID = "S", USUBJID = c("S1", "S2"), AGE = 1:2, stringsAsFactors = FALSE)
  supp <- data.frame(STUDYID = "S", RDOMAIN = "AE", USUBJID = c("S1", "S2"), IDVAR = "AESEQ",
                     IDVARVAL = c("1", "2"), QNAM = "AETRTEM", QVAL = "Y", stringsAsFactors = FALSE)
  shiny::testServer(sideviewServer, args = list(id = "cv", cards = list(ae = ae, dm = dm, suppae = supp)), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    upd <- function() msgs(session, "sideview_cdisc_update")
    session$setInputs(derive_request = dv_req(args = list(by = dv_by(), side = "x")))
    store <- px$ctl$store
    supp_id <- store$get("suppae")$id
    ae_id <- store$get("ae")$id
    d_id <- store$get("ae_unmatched_dm")$id
    # put the derived card ahead of its input, so it is the first AE card and SUPPAE's parent (the store
    # keeps insertion order, and the resolver takes the first card of the parent domain)
    ae_card <- store$get("ae")
    store$remove("ae")
    store$add(ae_card)
    sv_module_refinalize(px$ctl)
    expect_identical(store$get("suppae")$cdisc$parent_card, d_id)
    n0 <- length(upd())
    session$setInputs(derive_forget = list(name = "ae_unmatched_dm"))
    expect_false(store$has("ae_unmatched_dm"))
    expect_length(upd(), n0 + 1L)
    tags <- upd()[[n0 + 1L]]$message$tags
    expect_identical(names(tags), supp_id)
    expect_identical(tags[[supp_id]]$parent_card, ae_id)
    expect_identical(store$get("suppae")$cdisc$parent_card, ae_id)
  })
})

# ---- derived cards follow their inputs (D1 task 6) ----

dv_chain <- function(session, px) {
  session$setInputs(sideview_ready = list(nonce = 1))
  session$setInputs(derive_request = dv_req(id = "c1"))
  session$setInputs(derive_request = dv_req(id = "c2", inputs = list("ae_unmatched_dm", "sae"),
                                            args = list(by = dv_by(), side = "x")))
  expect_true(px$ctl$store$has("ae_unmatched_dm_unmatched_sae"))
}
dv_types <- function(session, type) vapply(msgs(session, type), function(m) m$message$name %||% "", "")

test_that("sv_derive_dependants reads derived$inputs, transitively, in dependency order", {
  shiny::testServer(sideviewServer, args = dv_start(), {
    px <- session$getReturned()
    dv_chain(session, px)
    expect_identical(sv_derive_dependants(px$ctl$store, "ae"),
                     c("ae_unmatched_dm", "ae_unmatched_dm_unmatched_sae"))
    expect_identical(sv_derive_dependants(px$ctl$store, "ae_unmatched_dm"), "ae_unmatched_dm_unmatched_sae")
    expect_identical(sv_derive_dependants(px$ctl$store, "sae"), "ae_unmatched_dm_unmatched_sae")
    expect_identical(sv_derive_dependants(px$ctl$store, "suppae"), character())
  })
})

test_that("removing an input removes the derived cards that read it, child first", {
  shiny::testServer(sideviewServer, args = dv_start(), {
    px <- session$getReturned()
    dv_chain(session, px)
    n0 <- length(msgs(session, "sideview_card_remove"))
    sv_remove_card(px, "ae")
    expect_false(px$ctl$store$has("ae_unmatched_dm"))
    expect_false(px$ctl$store$has("ae_unmatched_dm_unmatched_sae"))
    rm_names <- utils::tail(dv_types(session, "sideview_card_remove"), length(dv_types(session, "sideview_card_remove")) - n0)
    expect_identical(rm_names, c("ae_unmatched_dm_unmatched_sae", "ae_unmatched_dm", "ae"))
    expect_true(all(vapply(msgs(session, "sideview_card_remove"), function(m) !is.null(m$message$ns), TRUE)))
  })
})

test_that("removing an inner derived card removes the ones that read it, and releases lazy tables in order", {
  shiny::testServer(sideviewServer, args = dv_start(), {
    px <- session$getReturned()
    dv_chain(session, px)
    released <- character()
    inner_id <- px$ctl$store$get("ae_unmatched_dm")$id
    outer_id <- px$ctl$store$get("ae_unmatched_dm_unmatched_sae")$id
    fg <- px$ctl$forget
    px$ctl$forget <- function(id) { released <<- c(released, id); fg(id) }
    sv_remove_card(px, "ae_unmatched_dm")
    expect_false(px$ctl$store$has("ae_unmatched_dm_unmatched_sae"))
    expect_identical(released, c(outer_id, inner_id))
    expect_true(px$ctl$store$has("ae"))
  })
})

test_that("replacing an input rebuilds the derived cards in place, in order", {
  shiny::testServer(sideviewServer, args = dv_start(), {
    px <- session$getReturned()
    dv_chain(session, px)
    before <- nrow(px$ctl$store$get("ae_unmatched_dm")$data)
    old_id <- px$ctl$store$get("ae_unmatched_dm")$id
    n0 <- length(msgs(session, "sideview_card_replace"))
    sv_replace_card(px, "dm", rbind(dv_dm, data.frame(USUBJID = "z", site = 9L)))
    reps <- utils::tail(msgs(session, "sideview_card_replace"), length(msgs(session, "sideview_card_replace")) - n0)
    nms <- vapply(reps, function(m) m$message$card$name, "")
    expect_identical(nms, c("dm", "ae_unmatched_dm", "ae_unmatched_dm_unmatched_sae"))
    m <- reps[[2L]]$message$card
    expect_identical(m$dims[[1L]], before - 1L)
    expect_identical(nrow(px$ctl$store$get("ae_unmatched_dm")$data), before - 1L)
    expect_identical(px$ctl$store$get("ae_unmatched_dm")$derived$op, "unmatched")
    expect_true(px$ctl$store$has("ae_unmatched_dm_unmatched_sae"))
    expect_length(msgs(session, "sideview_toast"), 0L)
  })
})

test_that("replacing a SUPP card sends the rebuilt derived card with the plan of the new data", {
  st <- dv_start()
  st$cards$sae$AESPID <- c(7L, 8L)
  shiny::testServer(sideviewServer, args = st, {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    session$setInputs(derive_request = dv_req(
      id = "s1", op = "supp_orphans", inputs = list("sae", "suppae"), args = list(rdomain = "AE")))
    old <- px$ctl$store$get("suppae_orphans")
    old_idvars <- vapply(old$derived$args$plan$idvars, function(v) v$idvar, "")
    expect_identical(old_idvars, "AESEQ")
    n0 <- length(msgs(session, "sideview_card_replace"))
    supp2 <- rbind(dv_supp, data.frame(RDOMAIN = "AE", USUBJID = "S1", IDVAR = "AESPID",
                                       IDVARVAL = "7", QNAM = "AEX", QVAL = "N", stringsAsFactors = FALSE))
    sv_replace_card(px, "suppae", supp2)
    reps <- utils::tail(msgs(session, "sideview_card_replace"), length(msgs(session, "sideview_card_replace")) - n0)
    expect_identical(vapply(reps, function(m) m$message$card$name, ""), c("suppae", "suppae_orphans"))
    d <- reps[[2L]]$message$card$derived
    expect_identical(d$op, "supp_orphans")
    expect_true("AESPID" %in% vapply(d$args$plan$idvars, function(v) v$idvar, ""))
  })
})

test_that("a rebuild that fails removes the card and its dependants with one toast", {
  shiny::testServer(sideviewServer, args = dv_start(), {
    px <- session$getReturned()
    dv_chain(session, px)
    n0 <- length(msgs(session, "sideview_card_remove"))
    sv_replace_card(px, "dm", data.frame(other = 1:2))
    expect_false(px$ctl$store$has("ae_unmatched_dm"))
    expect_false(px$ctl$store$has("ae_unmatched_dm_unmatched_sae"))
    expect_true(px$ctl$store$has("dm"))
    rm_names <- utils::tail(dv_types(session, "sideview_card_remove"), length(dv_types(session, "sideview_card_remove")) - n0)
    expect_identical(rm_names, c("ae_unmatched_dm_unmatched_sae", "ae_unmatched_dm"))
    toasts <- msgs(session, "sideview_toast")
    expect_length(toasts, 1L)
    expect_match(toasts[[1L]]$message$text, "ae_unmatched_dm", fixed = TRUE)
    expect_match(toasts[[1L]]$message$text, "ae_unmatched_dm_unmatched_sae", fixed = TRUE)
  })
})

dv_state <- function(steps) {
  sv_state_from_json(jsonlite::toJSON(
    list(version = "0.3.0", cards = list(), pipeline = list(steps = steps)),
    auto_unbox = TRUE, null = "null"))
}
dv_step1 <- list(kind = "derive", key = "d1", table = "ae_unmatched_dm", op = "unmatched",
                 inputs = list("ae", "dm"), args = list(by = dv_by(), side = "x"))
dv_step2 <- list(kind = "derive", key = "d2", table = "second", op = "unmatched",
                 inputs = list("ae_unmatched_dm", "sae"), args = list(by = dv_by(), side = "x"))

test_that("sideviewServer(state =) has the derived cards in the store before sideview_ready", {
  st <- dv_state(list(dv_step1, dv_step2))
  shiny::testServer(sideviewServer, args = c(dv_start(), list(state = st)), {
    px <- session$getReturned()
    expect_true(px$ctl$store$has("ae_unmatched_dm"))
    expect_true(px$ctl$store$has("second"))
    expect_identical(px$ctl$store$get("second")$derived$inputs, c("ae_unmatched_dm", "sae"))
    session$setInputs(sideview_ready = list(nonce = 1))
    added <- vapply(msgs(session, "sideview_card_add"), function(m) m$message$card$name, "")
    expect_true(all(c("ae_unmatched_dm", "second") %in% added))
    expect_length(msgs(session, "sideview_state_set"), 1L)
  })
})

test_that("a derive step from a file that fails is skipped, and nothing is evaluated", {
  bad <- list(kind = "derive", key = "x", table = "evil", op = "unmatched", inputs = list("ae", "nope"),
              args = list(by = dv_by(), side = "x", code = "stop('boom')"))
  bad2 <- list(kind = "derive", key = "y", table = "evil2", op = "system", inputs = list("ae", "dm"), args = list())
  st <- dv_state(list(bad, bad2, dv_step1))
  shiny::testServer(sideviewServer, args = c(dv_start(), list(state = st)), {
    px <- session$getReturned()
    expect_false(px$ctl$store$has("evil"))
    expect_false(px$ctl$store$has("evil2"))
    expect_true(px$ctl$store$has("ae_unmatched_dm"))
  })
})

test_that("sv_set_state() builds the derived cards before the state is sent", {
  shiny::testServer(sideviewServer, args = dv_start(), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    sv_set_state(px, dv_state(list(dv_step1)))
    expect_true(px$ctl$store$has("ae_unmatched_dm"))
    ord <- vapply(session$userData$custom_messages, function(m) m$type, "")
    expect_lt(max(which(ord == "sideview_card_add")), max(which(ord == "sideview_state_set")))
  })
})

test_that("sideview(state =) lists the derived cards", {
  st <- dv_state(list(dv_step1, dv_step2))
  app <- sideview(ae = dv_ae, dm = dv_dm, sae = dv_sae, state = st, run = FALSE)
  nms <- vapply(app$cards, function(cd) cd$name, "")
  expect_identical(nms, c("ae", "dm", "sae", "ae_unmatched_dm", "second"))
  expect_equal(nrow(app$cards[[4L]]$data), 2L)
})

test_that("lazy derived cards: removal cascades and releases tables, replace rebuilds the whole table", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbWriteTable(con, "lae", data.frame(USUBJID = c("a", "b", "z", "q"), n = 1:4, stringsAsFactors = FALSE))
  DBI::dbWriteTable(con, "ldm", data.frame(USUBJID = c("a", "b"), s = 1:2, stringsAsFactors = FALSE))
  DBI::dbWriteTable(con, "lex", data.frame(USUBJID = "q", e = 1L, stringsAsFactors = FALSE))
  cards <- list(lae = dplyr::tbl(con, "lae"), ldm = dplyr::tbl(con, "ldm"), lex = dplyr::tbl(con, "lex"))
  shiny::testServer(sideviewServer, args = list(id = "cv", cards = cards), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    session$setInputs(derive_request = dv_req(id = "l1", inputs = list("lae", "ldm")))
    session$setInputs(derive_request = dv_req(id = "l2", inputs = list("lae_unmatched_ldm", "lex")))
    inner <- px$ctl$store$get("lae_unmatched_ldm")
    outer <- px$ctl$store$get("lae_unmatched_ldm_unmatched_lex")
    expect_true(inner$is_lazy && outer$is_lazy)
    expect_identical(inner$dims[[1L]], 2L)
    expect_identical(outer$dims[[1L]], 1L)
    DBI::dbWriteTable(con, "ldm", data.frame(USUBJID = c("a", "b", "z"), s = 1:3, stringsAsFactors = FALSE),
                      overwrite = TRUE)
    sv_replace_card(px, "ldm", dplyr::tbl(con, "ldm"))
    expect_identical(px$ctl$store$get("lae_unmatched_ldm")$dims[[1L]], 1L)
    expect_identical(px$ctl$store$get("lae_unmatched_ldm_unmatched_lex")$dims[[1L]], 0L)
    sv_remove_card(px, "lae_unmatched_ldm")
    expect_false(px$ctl$store$has("lae_unmatched_ldm_unmatched_lex"))
    expect_true(px$ctl$store$has("lae"))
  })
})

test_that("gadget state restore: a derive step on lazy inputs is built on whole tables, not from previews", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbWriteTable(con, "gae", data.frame(USUBJID = sprintf("u%03d", 1:200), stringsAsFactors = FALSE))
  DBI::dbWriteTable(con, "gdm", data.frame(USUBJID = sprintf("u%03d", 1:197), stringsAsFactors = FALSE))
  st <- dv_state(list(dv_step1))
  app <- sideview(ae = dplyr::tbl(con, "gae"), dm = dplyr::tbl(con, "gdm"), state = st, run = FALSE)
  # the card list has no derived card: from 50-row previews it would be the wrong table
  expect_identical(vapply(app$cards, function(cd) cd$name, ""), c("ae", "dm"))
  shiny::testServer(app, {
    session$flushReact()
    adds <- Filter(function(m) identical(m$type, "sideview_card_add"), session$userData$custom_messages)
    hit <- Filter(function(m) identical(m$message$card$name, "ae_unmatched_dm"), adds)
    expect_length(hit, 1L)
    expect_identical(hit[[1L]]$message$card$totalRows, 3L)
  })
})

test_that("reactive cards=: a re-fire keeps the derived card; dropping an input removes it by cascade", {
  rv <- shiny::reactiveVal(list(ae = dv_ae, dm = dv_dm))
  shiny::testServer(sideviewServer, args = list(id = "cv", cards = rv), {
    px <- session$getReturned()
    session$flushReact()
    session$setInputs(sideview_ready = list(nonce = 1))
    session$setInputs(derive_request = dv_req())
    expect_true(px$ctl$store$has("ae_unmatched_dm"))
    rv(list(ae = dv_ae, dm = dv_dm, extra = data.frame(a = 1)))
    session$flushReact()
    expect_true(px$ctl$store$has("extra"))
    expect_true(px$ctl$store$has("ae_unmatched_dm"))
    rv(list(dm = dv_dm, extra = data.frame(a = 1)))
    session$flushReact()
    expect_false(px$ctl$store$has("ae"))
    expect_false(px$ctl$store$has("ae_unmatched_dm"))
    expect_true(px$ctl$store$has("dm"))
  })
})

test_that("forged stack requests are refused", {
  w1 <- data.frame(AGE = c(34, 51), RACE = c("a", "b"), stringsAsFactors = FALSE)
  w2 <- data.frame(AGE = c("29", "x", "40"), RACE = c("c", "d", "e"), stringsAsFactors = FALSE)
  shiny::testServer(sideviewServer, args = list(id = "cv", cards = list(wave1 = w1, wave2 = w2)), {
    px <- session$getReturned()
    session$setInputs(sideview_ready = list(nonce = 1))
    before <- px$ctl$store$names()
    n_all <- length(session$userData$custom_messages)
    i <- 0L
    refuse <- function(req) {
      i <<- i + 1L
      req$id <- paste0("bad", i)
      session$setInputs(stack_check_request = req)
      all <- session$userData$custom_messages
      expect_length(all, n_all + 1L)
      n_all <<- length(all)
      r <- all[[length(all)]]
      expect_identical(r$type, "sideview_stack_check")
      expect_identical(r$message$id, req$id)
      expect_true(is.character(r$message$error) && nzchar(r$message$error))
      expect_null(r$message$columns)
      expect_identical(r$message$ns, session$ns(""))
      expect_identical(px$ctl$store$names(), before)
    }
    refuse(list(tables = list("Sys.getenv", "wave2")))
    refuse(list(tables = list("wave1", "nope")))
    refuse(list(tables = as.list(rep("wave1", 9L))))
    refuse(list(tables = list("wave1", "wave1")))
    refuse(list(tables = list("wave1")))
    refuse(list(tables = list("wave1", "wave2"),
                fixes = list(list(column = "x; system('id')", action = "cast", to = "chr"))))
    refuse(list(tables = list("wave1", "wave2"),
                fixes = rep(list(list(column = "AGE", action = "keep")), 10000L)))
    # and a good one still answers
    session$setInputs(stack_check_request = list(id = "ok", tables = list("wave1", "wave2")))
    all <- session$userData$custom_messages
    expect_null(all[[length(all)]]$message$error)
    expect_identical(px$ctl$store$names(), before)
  })
})
