# Source R files if running standalone without package installed
if (!"package:sideview" %in% search()) {
  r_files <- list.files(c("R", "../R", "../../R"), pattern = "\\.[Rr]$", full.names = TRUE)
  for (f in r_files) source(f)
}

`%||%` <- function(x, y) if (is.null(x)) y else x

test_that("sv_build_schema_context summarizes single tabular card safely", {
  card <- sv_normalize(mtcars, name = "CarsData")
  schema <- sv_build_schema_context(card)

  expect_type(schema, "character")
  expect_length(schema, 1L)
  expect_true(grepl("CarsData", schema))
  expect_true(grepl("32 rows", schema, ignore.case = TRUE))
  expect_true(grepl("11 col", schema, ignore.case = TRUE))
  expect_true(grepl("mpg", schema))
  expect_true(grepl("range", schema, ignore.case = TRUE))

  # Ensure raw full dump is not leaked (mtcars has 32 rows, should not dump all row values)
  # Check that it doesn't contain a raw dataframe printout like "Mazda RX4"
  expect_false(grepl("Mazda RX4", schema))
})

test_that("sv_build_schema_context summarizes factor, character, and date columns", {
  df <- data.frame(
    category = factor(rep(c("Alpha", "Beta", "Gamma"), length.out = 100)),
    city = rep(c("Tokyo", "London", "Paris", "Berlin"), length.out = 100),
    event_date = seq(as.Date("2024-01-01"), by = "day", length.out = 100),
    score = rnorm(100, mean = 50, sd = 5),
    stringsAsFactors = FALSE
  )
  card <- sv_normalize(df, name = "Metrics")
  schema <- sv_build_schema_context(card)

  expect_true(grepl("Metrics", schema))
  expect_true(grepl("category", schema))
  expect_true(grepl("Alpha", schema))
  expect_true(grepl("event_date", schema))
  expect_true(grepl("2024-01-01", schema))
})

test_that("sv_build_schema_context handles missing values and truncated categories", {
  df <- data.frame(
    id = 1:50,
    tags = paste0("tag_", 1:50), # 50 distinct categories
    val_na = c(10, 20, NA, 40, NA, rep(NA, 45)),
    all_na = as.numeric(rep(NA, 50)),
    stringsAsFactors = FALSE
  )
  card <- sv_normalize(df, name = "TagTable")
  schema <- sv_build_schema_context(card)

  expect_true(grepl("TagTable", schema))
  expect_true(grepl("tags", schema))
  # Should truncate categories rather than dump all 50
  expect_false(grepl("tag_49", schema))
  expect_true(grepl("val_na", schema))
  expect_true(grepl("all_na", schema))
})

test_that("sv_build_schema_context handles multiple cards, empty lists, and non-tabular cards", {
  # Empty input
  expect_equal(sv_build_schema_context(list()), "")

  # Multiple cards
  c1 <- sv_normalize(data.frame(a = 1:5), name = "T1")
  c2 <- sv_normalize(data.frame(b = c("x", "y")), name = "T2")
  schema <- sv_build_schema_context(list(c1, c2))
  expect_true(grepl("T1", schema))
  expect_true(grepl("T2", schema))

  # Card with NULL data or widget
  null_card <- structure(
    list(id = "card_widget", name = "MyWidget", type = "widget", data = NULL),
    class = c("sideview_card", "list")
  )
  schema_null <- sv_build_schema_context(null_card)
  expect_true(grepl("MyWidget", schema_null))
  expect_true(grepl("widget|no tabular data", schema_null, ignore.case = TRUE))
})

test_that("sv_build_prompt formats system instructions and combines schema context", {
  prompt_info <- sv_build_prompt(
    user_prompt = "Join sales and customers on customer_id and sum amount",
    schema_context = "Table: sales (customer_id, amount)\nTable: customers (customer_id, name)"
  )

  expect_type(prompt_info, "list")
  expect_true("system_message" %in% names(prompt_info) || "system" %in% names(prompt_info))
  expect_true("user_message" %in% names(prompt_info) || "user" %in% names(prompt_info))

  sys_msg <- prompt_info$system_message %||% prompt_info$system
  usr_msg <- prompt_info$user_message %||% prompt_info$user

  # System message should instruct clean tidyverse R code in ```r blocks
  expect_true(grepl("tidyverse|dplyr", sys_msg, ignore.case = TRUE))
  expect_true(grepl("```r", sys_msg))

  # User message contains the prompt and schema
  expect_true(grepl("Join sales and customers", usr_msg))
  expect_true(grepl("customer_id", usr_msg))
})

test_that("sv_extract_code extracts code from various markdown fences and raw text", {
  # Standard ```r ... ```
  res1 <- sv_extract_code("Here is your solution:\n```r\nmtcars |> filter(mpg > 20)\n```\nEnjoy!")
  expect_equal(res1, "mtcars |> filter(mpg > 20)")

  # Uppercase ```R ... ```
  res2 <- sv_extract_code("```R\nlibrary(dplyr)\niris |> count(Species)\n```")
  expect_equal(res2, "library(dplyr)\niris |> count(Species)")

  # Generic ``` ... ```
  res3 <- sv_extract_code("```\nx <- 1:10\nmean(x)\n```")
  expect_equal(res3, "x <- 1:10\nmean(x)")

  # Multiple code fences concatenated
  res4 <- sv_extract_code("First step:\n```r\na <- 1\n```\nSecond step:\n```r\nb <- 2\n```")
  expect_equal(res4, "a <- 1\nb <- 2")

  # Raw code fallback without markdown fences
  raw_code <- "df |> mutate(z = x + y)"
  expect_equal(sv_extract_code(raw_code), raw_code)

  # Whitespace trimming
  padded <- "   \n```r\nval <- 42\n```\n\n   "
  expect_equal(sv_extract_code(padded), "val <- 42")

  # Ensure parsed expression works
  parsed <- parse(text = sv_extract_code(res1))
  expect_true(is.expression(parsed))
})

test_that("sv_call_llm constructs valid requests for Ollama backend", {
  captured_req <- NULL
  mock_ollama <- function(req) {
    captured_req <<- req
    resp_payload <- list(
      model = "llama3.2",
      message = list(role = "assistant", content = "```r\nmtcars |> select(mpg)\n```"),
      done = TRUE
    )
    httr2::response(
      status_code = 200L,
      headers = list("content-type" = "application/json"),
      body = charToRaw(jsonlite::toJSON(resp_payload, auto_unbox = TRUE))
    )
  }

  prompt <- sv_build_prompt("Show mpg", schema_context = "Table: mtcars")

  httr2::with_mocked_responses(mock_ollama, {
    result <- sv_call_llm(
      prompt = prompt,
      backend = "ollama",
      model = "llama3.2",
      endpoint = "http://localhost:11434"
    )

    expect_type(result, "character")
    expect_true(grepl("mtcars", result))
    expect_false(is.null(captured_req))

    # Check request URL and method
    expect_true(grepl("11434", captured_req$url))
    expect_equal(captured_req$method, "POST")

    # Inspect payload sent
    expect_equal(captured_req$body$data$model, "llama3.2")
    expect_false(is.null(captured_req$body$data$messages))
    expect_false(captured_req$body$data$stream)

    # Test with extract_code = TRUE
    result_code <- sv_call_llm(
      prompt = prompt,
      backend = "ollama",
      model = "llama3.2",
      endpoint = "http://localhost:11434",
      extract_code = TRUE
    )
    expect_equal(result_code, "mtcars |> select(mpg)")
  })
})

test_that("sv_call_llm constructs valid requests for OpenAI backend", {
  captured_req <- NULL
  mock_openai <- function(req) {
    captured_req <<- req
    resp_payload <- list(
      id = "chatcmpl-123",
      choices = list(
        list(
          index = 0L,
          message = list(role = "assistant", content = "```r\ndf |> group_by(grp) |> summarize(n = n())\n```"),
          finish_reason = "stop"
        )
      )
    )
    httr2::response(
      status_code = 200L,
      headers = list("content-type" = "application/json"),
      body = charToRaw(jsonlite::toJSON(resp_payload, auto_unbox = TRUE))
    )
  }

  prompt <- sv_build_prompt("Summarize by grp", schema_context = "Table: df (grp)")

  httr2::with_mocked_responses(mock_openai, {
    result <- sv_call_llm(
      prompt = prompt,
      backend = "openai",
      model = "gpt-4o-mini",
      endpoint = "https://api.openai.com/v1",
      api_key = "sk-test-secret-key"
    )

    expect_type(result, "character")
    expect_true(grepl("group_by", result))
    expect_false(is.null(captured_req))

    # Verify endpoint and Authorization header
    expect_true(grepl("chat/completions", captured_req$url))
    dry <- httr2::req_dry_run(captured_req, redact_headers = FALSE, quiet = TRUE)
    expect_equal(dry$headers$authorization, "Bearer sk-test-secret-key")

    # Verify JSON body
    expect_equal(captured_req$body$data$model, "gpt-4o-mini")
    expect_equal(length(captured_req$body$data$messages), 2L)
  })
})

test_that("sv_call_llm handles API errors cleanly with informative messages", {
  mock_401 <- function(req) {
    httr2::response(
      status_code = 401L,
      headers = list("content-type" = "application/json"),
      body = charToRaw('{"error": {"message": "Incorrect API key provided"}}')
    )
  }

  httr2::with_mocked_responses(mock_401, {
    expect_error(
      sv_call_llm(
        prompt = "test",
        backend = "openai",
        endpoint = "https://api.openai.com/v1",
        api_key = "invalid-key"
      ),
      "401|API key|Unauthorized"
    )
  })

  mock_500 <- function(req) {
    httr2::response(
      status_code = 500L,
      headers = list("content-type" = "application/json"),
      body = charToRaw('{"error": "Internal server error"}')
    )
  }

  httr2::with_mocked_responses(mock_500, {
    expect_error(
      sv_call_llm(
        prompt = "test",
        backend = "ollama",
        endpoint = "http://localhost:11434"
      ),
      "500|server error"
    )
  })
})

test_that("sv_call_llm and sv_extract_code handle trailing slashes and knitr options", {
  # Knitr chunk options and multi-block language extraction
  md_text <- paste(
    "Here is the bash setup:",
    "```bash",
    "pip install pandas",
    "```",
    "Here is the tidyverse code:",
    "```{r summary-chunk, eval=FALSE}",
    "df |> mutate(z = x + y)",
    "```",
    sep = "\n"
  )
  extracted <- sv_extract_code(md_text)
  expect_equal(extracted, "df |> mutate(z = x + y)")
  expect_false(grepl("pip install", extracted))

  # Trailing slash handling on base URL
  captured_url <- NULL
  mock_slash <- function(req) {
    captured_url <<- req$url
    httr2::response(
      status_code = 200L,
      headers = list("content-type" = "application/json"),
      body = charToRaw('{"choices":[{"message":{"content":"ok"}}]}')
    )
  }

  httr2::with_mocked_responses(mock_slash, {
    sv_call_llm(
      prompt = "hi",
      backend = "openai",
      endpoint = "https://api.openai.com/v1/chat/completions/"
    )
    expect_equal(captured_url, "https://api.openai.com/v1/chat/completions")

    sv_call_llm(
      prompt = "hi",
      backend = "ollama",
      endpoint = "http://localhost:11434/"
    )
    expect_equal(captured_url, "http://localhost:11434/api/chat")
  })

  # Single raw table into sv_build_schema_context
  tbl <- table(c("A", "B", "A"))
  schema <- sv_build_schema_context(tbl)
  expect_true(grepl("Table", schema))
})


test_that("sv_build_chat_prompt constructs multi-turn prompt with history, schema, and active code", {
  history <- list(
    list(role = "user", content = "Join sales and customers on customer_id"),
    list(role = "assistant", content = "Here is the code:\n```r\nsales |> left_join(customers, by = 'customer_id')\n```")
  )
  current_code <- "sales |> left_join(customers, by = 'customer_id')"
  schema_context <- "Table: sales (customer_id, amount)\nTable: customers (customer_id, name, region)"

  chat_prompt <- sv_build_chat_prompt(
    user_message = "Now filter for region == 'North' and summarize total amount",
    history = history,
    current_code = current_code,
    schema_context = schema_context
  )

  expect_s3_class(chat_prompt, "sideview_prompt")
  expect_s3_class(chat_prompt, "sideview_chat_prompt")
  expect_type(chat_prompt, "list")

  # 1. Preserves schema context
  expect_true(grepl("Table: sales", chat_prompt$user_message))
  expect_true(grepl("Table: customers", chat_prompt$user_message))
  expect_true(grepl("region", chat_prompt$user_message))

  # 2. Includes active pipeline code in prompt context
  expect_true(grepl("sales \\|> left_join\\(customers", chat_prompt$user_message))
  expect_true(grepl("Current active pipeline code", chat_prompt$user_message, ignore.case = TRUE))

  # 3. Includes previous turns in context
  expect_equal(length(chat_prompt$history), 2L)
  expect_equal(chat_prompt$history[[1]]$role, "user")
  expect_equal(chat_prompt$history[[1]]$content, "Join sales and customers on customer_id")
  expect_equal(chat_prompt$history[[2]]$role, "assistant")
  expect_true(grepl("left_join", chat_prompt$history[[2]]$content))

  # 4. Synthesizes clean structured system and user prompts
  expect_true(grepl("tidyverse|dplyr", chat_prompt$system_message, ignore.case = TRUE))
  expect_true(grepl("```r", chat_prompt$system_message))
  expect_true(grepl("filter for region == 'North'", chat_prompt$user_message))

  # 5. Full prompt string and messages array for LLM calls
  expect_true(length(chat_prompt$messages) >= 4L) # system + 2 history + 1 current user
  expect_equal(chat_prompt$messages[[1]]$role, "system")
  expect_equal(chat_prompt$messages[[2]]$role, "user")
  expect_equal(chat_prompt$messages[[3]]$role, "assistant")
  expect_equal(chat_prompt$messages[[4]]$role, "user")
  expect_true(grepl("region == 'North'", chat_prompt$messages[[4]]$content))

  # 6. Extracts executable R code from multi-turn responses
  assistant_reply <- paste(
    "Sure! Here is the updated pipeline filtering for region and summarizing total amount:",
    "```r",
    "sales |>",
    "  left_join(customers, by = 'customer_id') |>",
    "  filter(region == 'North') |>",
    "  summarise(total_amount = sum(amount, na.rm = TRUE))",
    "```",
    "Let me know if you need to group by customer as well!",
    sep = "\n"
  )
  extracted <- sv_extract_code(assistant_reply)
  expect_true(grepl("filter\\(region == 'North'\\)", extracted))
  expect_true(grepl("summarise\\(total_amount", extracted))
  expect_false(grepl("Sure!", extracted))
})

test_that("sv_build_chat_prompt handles empty history, NULL code, and NULL schema", {
  prompt_simple <- sv_build_chat_prompt("Calculate average score")

  expect_s3_class(prompt_simple, "sideview_prompt")
  expect_equal(length(prompt_simple$history), 0L)
  expect_true(grepl("Calculate average score", prompt_simple$user_message))
  expect_true(length(prompt_simple$messages) == 2L) # system + user
})

test_that("sv_call_llm supports multi-turn chat prompt with mock", {
  captured_req <- NULL
  mock_chat_backend <- function(req) {
    captured_req <<- req
    resp_payload <- list(
      choices = list(
        list(
          message = list(
            role = "assistant",
            content = "```r\ndf |> filter(x > 10)\n```"
          )
        )
      )
    )
    httr2::response(
      status_code = 200L,
      headers = list("content-type" = "application/json"),
      body = charToRaw(jsonlite::toJSON(resp_payload, auto_unbox = TRUE))
    )
  }

  chat_p <- sv_build_chat_prompt(
    user_message = "filter x > 10",
    history = list(list(role = "user", content = "load data")),
    current_code = "df <- read_csv('data.csv')"
  )

  httr2::with_mocked_responses(mock_chat_backend, {
    res <- sv_call_llm(
      prompt = chat_p,
      backend = "openai",
      extract_code = TRUE
    )
    expect_equal(res, "df |> filter(x > 10)")
    # Verify multi-turn messages were passed to API
    sent_msgs <- captured_req$body$data$messages
    expect_true(length(sent_msgs) >= 3L)
  })
})

test_that("sv_extract_code correctly distinguishes code fences from conversational text", {
  # Text with standard R fence
  r_block <- "Here is the transformation:\n```r\ndf |> filter(age > 30)\n```\nHope that helps!"
  expect_equal(sv_extract_code(r_block), "df |> filter(age > 30)")

  # Text with knitr chunk fence
  knitr_block <- "```{r my-chunk, echo=TRUE}\ndf |> mutate(y = x * 2)\n```"
  expect_equal(sv_extract_code(knitr_block), "df |> mutate(y = x * 2)")

  # Text with generic fence
  gen_block <- "```\ndf |> arrange(desc(score))\n```"
  expect_equal(sv_extract_code(gen_block), "df |> arrange(desc(score))")

  # Conversational text without code fences
  plain_text <- "I see two tables in your workspace: patients and labs. How can I help?"
  expect_equal(sv_extract_code(plain_text), plain_text)

  # Error string without code fences
  err_text <- "# Copilot request failed: Connection refused"
  expect_equal(sv_extract_code(err_text), err_text)
})

test_that("sv_build_chat_prompt formats conversation history with arbitrary turn lengths", {
  # Create 25 turns of conversation history
  hist <- lapply(seq_len(25), function(i) {
    list(
      role = if (i %% 2 == 1) "user" else "assistant",
      content = paste("Turn content", i)
    )
  })

  # Pass last 20 capped turns
  capped_hist <- utils::tail(hist, 20L)
  p <- sv_build_chat_prompt("Current question", history = capped_hist)

  expect_equal(length(p$history), 20L)
  expect_equal(length(p$messages), 22L) # system + 20 history + current user message
  expect_equal(p$messages[[1]]$role, "system")
  expect_equal(p$messages[[2]]$content, "Turn content 6")
  expect_equal(p$messages[[21]]$content, "Turn content 25")
  expect_equal(p$messages[[22]]$role, "user")
  expect_match(p$messages[[22]]$content, "Current question")
})


test_that("schema context states the true row count of a lazy card", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "v", data.frame(id = 1:1000, x = seq(0.5, 500, length.out = 1000)))
  ctx <- sv_build_schema_context(list(sv_normalize(dplyr::tbl(con, "v"), name = "v")))
  expect_match(ctx, "1000 rows", fixed = TRUE)
  expect_match(ctx, "(ranges from the first 50 rows)", fixed = TRUE)
  # a data frame is described as before
  ctx_df <- sv_build_schema_context(list(sv_normalize(data.frame(id = 1:3), name = "p")))
  expect_match(ctx_df, "Dimensions: 3 rows x 1 columns", fixed = TRUE)
  expect_false(grepl("ranges from the first", ctx_df, fixed = TRUE))
})
