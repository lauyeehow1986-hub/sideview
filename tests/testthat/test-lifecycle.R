msgs_of <- function(session, type) {
  Filter(function(m) identical(m$type, type), session$userData$custom_messages)
}

test_that("Done returns the generated code and Cancel returns NULL (gadget mode)", {
  card <- sv_normalize(data.frame(a = 1:3), name = "t")

  shiny::testServer(sideview_server(list(card), gadget = TRUE), {
    session$setInputs(sideview_done = list(code = "t %>% dplyr::filter(a > 1)"))
    expect_equal(session$userData$sideview_result$value, "t %>% dplyr::filter(a > 1)")
    # A later stop (e.g. session end) must not replace the returned code.
    session$setInputs(sideview_cancel = list(at = 1))
    expect_equal(session$userData$sideview_result$value, "t %>% dplyr::filter(a > 1)")
  })

  shiny::testServer(sideview_server(list(card), gadget = TRUE), {
    session$setInputs(cancel = 1)
    expect_true(is.list(session$userData$sideview_result))
    expect_null(session$userData$sideview_result$value)
  })

  shiny::testServer(sideview_server(list(card), gadget = TRUE), {
    session$setInputs(sideview_done = list(code = "   "))
    expect_null(session$userData$sideview_result$value)
  })

  # The code panel's placeholder is not code
  shiny::testServer(sideview_server(list(card), gadget = TRUE), {
    session$setInputs(sideview_done = list(code = "# Connect two columns to generate pipeline code"))
    expect_true(is.list(session$userData$sideview_result))
    expect_null(session$userData$sideview_result$value)
  })
})

test_that("asset version changes with the file contents", {
  dir <- tempfile("svassets")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  writeLines("var a = 1;", file.path(dir, "sideview.js"))
  v1 <- sv_asset_version(dir)
  expect_identical(v1, sv_asset_version(dir))
  expect_true(startsWith(v1, paste0(as.character(utils::packageVersion("sideview")), ".")))
  expect_s3_class(package_version(v1), "package_version")
  writeLines("var a = 2;", file.path(dir, "sideview.js"))
  expect_false(identical(v1, sv_asset_version(dir)))
  expect_identical(sideview_html_dependency()$version, sv_asset_version(find_sideview_www()))
})

test_that("browser mode stops only after the last tab closes", {
  card <- sv_normalize(data.frame(a = 1:3), name = "t")
  lc <- function(server) environment(server)$lifecycle
  open_tab <- function(server) {
    s <- shiny::MockShinySession$new()
    shiny::withReactiveDomain(s, server(s$input, s$output, s))
    s
  }

  # No grace: a second tab closing leaves the first alive; the last one stops the app
  old <- options(sideview.session_grace = 0)
  on.exit(options(old), add = TRUE)
  server <- sideview_server(list(card), gadget = TRUE)
  tab1 <- open_tab(server)
  tab2 <- open_tab(server)
  expect_equal(lc(server)$sessions, 2L)
  tab2$close()
  expect_equal(lc(server)$sessions, 1L)
  expect_false(lc(server)$stopped)
  tab1$close()
  expect_equal(lc(server)$sessions, 0L)
  expect_true(lc(server)$stopped)

  # With a grace period, a reload (close then reopen) keeps the app running
  options(sideview.session_grace = 0.2)
  server <- sideview_server(list(card), gadget = TRUE)
  open_tab(server)$close()
  expect_false(lc(server)$stopped)
  tab <- open_tab(server)
  Sys.sleep(0.3)
  later::run_now(0.1)
  expect_false(lc(server)$stopped)
  tab$close()
  Sys.sleep(0.3)
  later::run_now(0.1)
  expect_true(lc(server)$stopped)
})

test_that("Done/Cancel are ignored outside gadget mode", {
  card <- sv_normalize(data.frame(a = 1:3), name = "t")
  shiny::testServer(sideview_server(list(card)), {
    session$setInputs(sideview_done = list(code = "x"))
    expect_null(session$userData$sideview_result)
  })
})

test_that("sideview() builds a gadget page with Done and Cancel", {
  app <- sideview(data.frame(a = 1), run = FALSE)
  html <- as.character(sideview_ui(attr(app, "cards"), gadget = TRUE))
  expect_match(html, 'data-action="gadget-done"', fixed = TRUE)
  expect_match(html, 'data-action="gadget-cancel"', fixed = TRUE)
  expect_false(grepl("gadget-done", as.character(sideview_ui(attr(app, "cards"))), fixed = TRUE))
})

test_that("Run in R keeps the result as sv_result (or a chosen name)", {
  card <- sv_normalize(data.frame(a = 1:3), name = "t")
  run_env <- new.env()
  shiny::testServer(sideview_server(list(card), run_env = run_env), {
    session$setInputs(eval_env = list(code = "data.frame(x = 1:4)"))
    expect_equal(nrow(get("sv_result", envir = run_env)), 4L)
    msg <- utils::tail(msgs_of(session, "sideview_eval_result"), 1)[[1]]$message
    expect_true(msg$success)
    expect_match(msg$message, "saved as `sv_result`", fixed = TRUE)

    session$setInputs(eval_env = list(code = "1 + 1", assign_to = "my_out"))
    expect_equal(get("my_out", envir = run_env), 2)

    # An invalid target name falls back to sv_result instead of erroring
    session$setInputs(eval_env = list(code = "3", assign_to = "bad name; rm()"))
    expect_equal(get("sv_result", envir = run_env), 3)
  })
  expect_false(exists("sv_result", envir = globalenv(), inherits = FALSE))
})

test_that("sideview() runs code in the environment it is called from", {
  caller <- function() {
    app <- sideview(data.frame(a = 1:2), run = FALSE)
    shiny::testServer(app, session$setInputs(eval_env = list(code = "nrow(data.frame(a = 1:5))")))
    get0("sv_result", envir = environment(), inherits = FALSE)
  }
  expect_equal(caller(), 5L)
  expect_false(exists("sv_result", envir = globalenv(), inherits = FALSE))
})

test_that("AI failures keep the current code and explain the fix", {
  card <- sv_normalize(data.frame(a = 1:3), name = "t")
  failing_llm <- function(...) stop("Sideview LLM API error (404): model 'llama3.2' not found", call. = FALSE)
  shiny::testServer(sideview_server(list(card), llm_fn = failing_llm), {
    session$setInputs(run_ai_prompt = list(prompt = "filter a > 1", backend = "ollama", model = "llama3.2"))
    expect_length(msgs_of(session, "sideview_code_update"), 0)
    st <- msgs_of(session, "sideview_ai_status")
    expect_length(st, 1)
    expect_false(st[[1]]$message$success)
    expect_match(st[[1]]$message$message, "ollama pull llama3.2", fixed = TRUE)
  })

  bad_code_llm <- function(...) "```r\nt %>% filter(a %== 1)\n```"
  shiny::testServer(sideview_server(list(card), llm_fn = bad_code_llm), {
    session$setInputs(run_ai_prompt = list(prompt = "x"))
    expect_length(msgs_of(session, "sideview_code_update"), 1)
    st <- msgs_of(session, "sideview_ai_status")[[1]]$message
    expect_false(st$success)
    expect_match(st$message, "not valid R code")
  })

  good_llm <- function(...) "<think>plan</think>\n```r\nt %>% dplyr::filter(a > 1)\n```"
  shiny::testServer(sideview_server(list(card), llm_fn = good_llm), {
    session$setInputs(run_ai_prompt = list(prompt = "x"))
    code <- msgs_of(session, "sideview_code_update")[[1]]$message$code
    expect_equal(code, "t %>% dplyr::filter(a > 1)")
    expect_true(msgs_of(session, "sideview_ai_status")[[1]]$message$success)
  })
})

test_that("sv_llm_error_message gives a hint for common failures", {
  local_mocked_bindings(sv_llm_models = function(...) c("llama3.2:3b", "qwen2.5-coder:7b"))
  m <- sv_llm_error_message("Sideview LLM API error (404): model 'llama3.2' not found", "ollama", "llama3.2")
  expect_match(m, "ollama pull llama3.2", fixed = TRUE)
  expect_match(m, "installed: llama3.2:3b, qwen2.5-coder:7b", fixed = TRUE)
  m <- sv_llm_error_message("Sideview LLM connection failed (ollama at x): Failed to perform HTTP request. Timeout was reached", "ollama")
  expect_match(m, "ollama serve", fixed = TRUE)
  m <- sv_llm_error_message("Sideview LLM API error (401): bad key", "openai", "gpt-4o-mini")
  expect_match(m, "OPENAI_API_KEY", fixed = TRUE)
  expect_equal(sv_llm_error_message("weird", "openai"), "AI request failed: weird")
})

test_that("sv_extract_code drops <think> blocks from reasoning models", {
  expect_equal(sv_extract_code("<think>\nlet me think\n</think>\n```r\nx <- 1\n```"), "x <- 1")
  expect_equal(sv_extract_code("<think>a</think>plain answer"), "plain answer")
})

test_that("sv_call_llm sends think = FALSE to Ollama and retries an untagged model", {
  skip_if_not_installed("httr2", "1.0.0")
  seen <- list()
  httr2::local_mocked_responses(function(req) {
    if (grepl("/api/tags$", req$url)) {
      return(httr2::response_json(body = list(models = list(list(name = "llama3.2:3b"), list(name = "qwen3:14b")))))
    }
    body <- req$body$data
    seen[[length(seen) + 1L]] <<- body
    if (!body$model %in% c("llama3.2:3b", "qwen3:14b")) {
      return(httr2::response(status_code = 404L, headers = list(`Content-Type` = "application/json"),
                             body = charToRaw('{"error":"model \'llama3.2\' not found"}')))
    }
    httr2::response_json(body = list(message = list(role = "assistant", content = "```r\n1\n```")))
  })
  out <- sv_call_llm("hi", backend = "ollama", model = "llama3.2", endpoint = "http://localhost:11434")
  expect_equal(out, "```r\n1\n```")
  expect_equal(vapply(seen, function(b) b$model, ""), c("llama3.2", "llama3.2:3b"))
  expect_false(seen[[1]]$think)
  expect_false(seen[[1]]$stream)

  # A tagged model that is missing is not retried
  seen <- list()
  expect_error(sv_call_llm("hi", backend = "ollama", model = "llama3.2:1b", endpoint = "http://localhost:11434"),
               "404")

  # OpenAI-compatible: no think field, bearer key sent
  httr2::local_mocked_responses(function(req) {
    seen[[length(seen) + 1L]] <<- list(body = req$body$data, auth = req$headers$Authorization)
    httr2::response_json(body = list(choices = list(list(message = list(content = "ok")))))
  })
  seen <- list()
  expect_equal(sv_call_llm("hi", backend = "openai", model = "m", endpoint = "http://localhost:11434/v1", api_key = "k"), "ok")
  expect_null(seen[[1]]$body$think)
  expect_false(is.null(seen[[1]]$auth))
})

test_that("sv_llm_models lists Ollama and OpenAI-compatible models", {
  skip_if_not_installed("httr2", "1.0.0")
  httr2::local_mocked_responses(function(req) {
    if (grepl("/api/tags$", req$url)) {
      httr2::response_json(body = list(models = list(list(name = "a:1"), list(name = "b:2"))))
    } else {
      expect_match(req$url, "/v1/models$")
      httr2::response_json(body = list(data = list(list(id = "gpt-x"))))
    }
  })
  expect_equal(sv_llm_models("ollama", endpoint = "http://h:11434/api/chat"), c("a:1", "b:2"))
  expect_equal(sv_llm_models("openai", endpoint = "http://h/v1/chat/completions", api_key = ""), "gpt-x")
})

# Live check against a local Ollama (skipped unless one is running).
# Exercises both the native API and Ollama's OpenAI-compatible /v1 API.
test_that("live: Ollama native and OpenAI-compatible endpoints produce R code", {
  skip_on_cran()
  skip_on_ci()
  models <- tryCatch(sv_llm_models("ollama", endpoint = "http://localhost:11434", timeout = 2),
                     error = function(e) character())
  skip_if(length(models) == 0, "no local Ollama server")
  pick <- Sys.getenv("SIDEVIEW_TEST_OLLAMA_MODEL", "")
  if (!nzchar(pick)) {
    pref <- c("qwen2.5-coder:7b", "llama3.2:3b", "llama3.1:8b")
    pick <- c(intersect(pref, models), models)[1]
  }
  cards <- list(sv_normalize(data.frame(id = 1:5, age = c(30, 70, 65, 20, 80)), name = "patients"))
  p <- sv_build_prompt("Keep rows of patients where age is over 60", sv_build_schema_context(cards))

  native <- sv_extract_code(sv_call_llm(p, backend = "ollama", model = pick,
                                        endpoint = "http://localhost:11434", timeout = 120))
  expect_true(nzchar(native))
  expect_silent(parse(text = native))

  compat <- sv_extract_code(sv_call_llm(p, backend = "openai", model = pick,
                                        endpoint = "http://localhost:11434/v1", api_key = "ollama",
                                        timeout = 120))
  expect_true(nzchar(compat))
  expect_silent(parse(text = compat))
})
