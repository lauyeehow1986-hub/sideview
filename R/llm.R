# Helper operator for null default
`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

# The "Dimensions" line of a card. A lazy card reports the table's true row count;
# its column ranges and levels still come from the preview rows.
sv_schema_dimensions <- function(card, nr, nc) {
  total <- if (isTRUE(card$is_lazy) && length(card$dims) >= 1L) card$dims[1] else NA
  if (is.na(total) || total <= nr) {
    return(sprintf("Dimensions: %d rows x %d columns", nr, nc))
  }
  sprintf("Dimensions: %s rows x %d columns (ranges from the first %d rows)",
          format(total, scientific = FALSE, trim = TRUE), nc, nr)
}

#' Build a Privacy-Safe Schema Context from Sideview Cards
#'
#' Summarizes the metadata of sideview cards (table names, dimensions, column
#' names, types, value ranges for numerics/dates, sample levels for factors, and
#' unique samples for characters) without leaking full raw row data or records.
#' Non-tabular widget cards and NULL data are handled safely.
#'
#' @param cards A `sideview_card`, a list of `sideview_card`s, or tabular data.
#' @param max_categories Maximum sample unique categories to report for categorical columns. Default is 5.
#'
#' @return A character string containing the privacy-safe schema summary.
#' @export
sv_build_schema_context <- function(cards, max_categories = 5L) {
  if (is.null(cards) || (is.list(cards) && length(cards) == 0L)) {
    return("")
  }

  if (inherits(cards, "sideview_card") || is.data.frame(cards) ||
      inherits(cards, c("gt_tbl", "flextable", "table")) || !is.list(cards)) {
    cards <- list(cards)
  }

  card_summaries <- character(0)

  for (card in cards) {
    if (!inherits(card, "sideview_card")) {
      card <- tryCatch(sv_normalize(card), error = function(e) NULL)
      if (is.null(card)) next
    }

    c_name <- card$name %||% "Table"
    c_id <- card$id %||% "card"
    c_type <- card$type %||% "grid"
    df <- card$data

    if (is.null(df) || !is.data.frame(df)) {
      summary_txt <- sprintf(
        "Table: %s (id: %s, type: %s - no tabular data available)",
        c_name, c_id, c_type
      )
      card_summaries <- c(card_summaries, summary_txt)
      next
    }

    nr <- nrow(df)
    nc <- ncol(df)

    lines <- c(
      sprintf("Table: %s (id: %s)", c_name, c_id),
      sv_schema_dimensions(card, nr, nc),
      "Columns:"
    )

    col_names <- colnames(df)
    if (length(col_names) == 0L) {
      lines <- c(lines, "  (No columns)")
    } else {
      for (col in col_names) {
        val <- df[[col]]
        col_type <- class(val)[1]

        detail <- ""
        if (is.numeric(val)) {
          non_na <- val[!is.na(val)]
          if (length(non_na) == 0L) {
            detail <- "[all NA]"
          } else {
            min_v <- signif(min(non_na), 4)
            max_v <- signif(max(non_na), 4)
            detail <- sprintf("[range: %s to %s]", min_v, max_v)
            na_cnt <- sum(is.na(val))
            if (na_cnt > 0L) {
              detail <- paste0(detail, sprintf(" (%d NAs)", na_cnt))
            }
          }
        } else if (inherits(val, "Date") || inherits(val, "POSIXt")) {
          non_na <- val[!is.na(val)]
          if (length(non_na) == 0L) {
            detail <- "[all NA]"
          } else {
            min_v <- format(min(non_na))
            max_v <- format(max(non_na))
            detail <- sprintf("[range: %s to %s]", min_v, max_v)
            na_cnt <- sum(is.na(val))
            if (na_cnt > 0L) {
              detail <- paste0(detail, sprintf(" (%d NAs)", na_cnt))
            }
          }
        } else if (is.factor(val)) {
          levs <- levels(val)
          n_levs <- length(levs)
          sample_n <- min(as.integer(max_categories), n_levs)
          sample_levs <- levs[seq_len(sample_n)]
          samp_str <- paste(sample_levs, collapse = ", ")
          if (n_levs > sample_n) {
            samp_str <- paste0(samp_str, sprintf(", ... (%d total levels)", n_levs))
          }
          detail <- sprintf("[categories: %s]", samp_str)
        } else if (is.character(val)) {
          non_na <- unique(val[!is.na(val)])
          n_uniq <- length(non_na)
          sample_n <- min(as.integer(max_categories), n_uniq)
          sample_vals <- non_na[seq_len(sample_n)]
          samp_str <- paste(sample_vals, collapse = ", ")
          if (n_uniq > sample_n) {
            samp_str <- paste0(samp_str, sprintf(", ... (%d unique values)", n_uniq))
          }
          detail <- sprintf("[categories: %s]", samp_str)
        } else if (is.logical(val)) {
          detail <- sprintf(
            "[logical: %d TRUE, %d FALSE, %d NA]",
            sum(val == TRUE, na.rm = TRUE),
            sum(val == FALSE, na.rm = TRUE),
            sum(is.na(val))
          )
        } else {
          detail <- sprintf("[%s]", col_type)
        }

        lines <- c(lines, sprintf("  - %s (%s): %s", col, col_type, detail))
      }
    }

    card_summaries <- c(card_summaries, paste(lines, collapse = "\n"))
  }

  paste(card_summaries, collapse = "\n\n")
}

#' Build Structured Prompt for Tidyverse LLM Code Generation
#'
#' Formats system instructions emphasizing pure, executable tidyverse R code
#' enclosed in markdown code fences (` ```r ... ``` `) and packages user task
#' description alongside privacy-safe table schemas.
#'
#' @param user_prompt Natural language description of desired data transformation.
#' @param schema_context Optional privacy-safe schema string built via `sv_build_schema_context`.
#'
#' @return A list of class `sideview_prompt` containing `system_message`, `user_message`, and `prompt`.
#' @export
sv_build_prompt <- function(user_prompt, schema_context = NULL) {
  system_message <- paste(
    "You are an expert R and tidyverse data transformation assistant.",
    "Your task is to generate clean, robust, and executable R code using modern tidyverse packages (e.g. dplyr, tidyr, purrr, ggplot2).",
    "Follow these strict rules:",
    "1. Return ONLY executable R code enclosed in a ```r ... ``` code block.",
    "2. Use modern native pipe |> or dplyr pipe %>% consistently.",
    "3. Refer only to the tables and column names provided in the schema context.",
    "4. Do NOT output conversational chit-chat, pleasantries, or preamble outside the code block.",
    "5. If comments are needed, write them as R code comments (#) inside the code block.",
    sep = "\n"
  )

  user_parts <- character(0)
  if (!is.null(schema_context) && nzchar(trimws(schema_context))) {
    user_parts <- c(user_parts, "Available table schemas:", schema_context, "")
  }
  user_parts <- c(user_parts, paste("Task:", user_prompt))
  user_message <- paste(user_parts, collapse = "\n")

  full_prompt <- paste(system_message, "\n\n", user_message, sep = "")

  structure(
    list(
      system_message = system_message,
      user_message = user_message,
      system = system_message,
      user = user_message,
      prompt = full_prompt
    ),
    class = c("sideview_prompt", "list")
  )
}

#' Build Structured Multi-Turn Prompt for Conversational Copilot
#'
#' Formats a multi-turn conversational prompt for the Sideview AI Copilot drawer.
#' Preserves database/table schema context, active pipeline R code, and previous
#' dialogue turns (user/assistant). Instructs the model to output updated executable
#' tidyverse R code within code fences.
#'
#' @param user_message Natural language query or instruction from the user.
#' @param history A list of previous conversation turns, where each turn is a list
#'   containing `role` ("user" or "assistant") and `content` (or `text`/`message`).
#' @param current_code Optional character string containing the currently active
#'   pipeline code in the drawer.
#' @param schema_context Optional privacy-safe schema string built via `sv_build_schema_context`.
#'
#' @return A list of class `c("sideview_chat_prompt", "sideview_prompt", "list")`
#'   containing `system_message`, `user_message`, `history`, `messages`, and `prompt`.
#' @export
sv_build_chat_prompt <- function(user_message,
                                 history = list(),
                                 current_code = NULL,
                                 schema_context = NULL) {
  if (is.null(user_message)) user_message <- ""
  user_message <- as.character(user_message)

  system_message <- paste(
    "You are Sideview Copilot, an expert R and tidyverse data transformation assistant.",
    "Your task is to assist the user in exploring, transforming, joining, and analyzing data using modern tidyverse packages (e.g. dplyr, tidyr, purrr, ggplot2).",
    "Follow these strict rules:",
    "1. Whenever suggesting or modifying data transformations, return clean, robust, and executable R code enclosed in a ```r ... ``` code block.",
    "2. Use modern native pipe |> or dplyr pipe %>% consistently.",
    "3. Refer only to the tables and column names provided in the schema context.",
    "4. When modifying existing pipeline code, preserve the existing logic and emit the complete updated pipeline code block.",
    "5. Keep conversational explanations concise and focused on the requested R transformation.",
    sep = "\n"
  )

  # Context segments
  ctx_parts <- character(0)
  if (!is.null(schema_context) && nzchar(trimws(schema_context))) {
    ctx_parts <- c(ctx_parts, paste0("Available table schemas:\n", trimws(schema_context)))
  }
  if (!is.null(current_code) && nzchar(trimws(current_code))) {
    ctx_parts <- c(ctx_parts, paste0("Current active pipeline code:\n```r\n", trimws(current_code), "\n```"))
  }

  # Build user turn message
  user_turn_parts <- character(0)
  if (length(ctx_parts) > 0L) {
    user_turn_parts <- c(user_turn_parts, paste(ctx_parts, collapse = "\n\n"), "")
  }
  user_turn_parts <- c(user_turn_parts, paste("User request:", user_message))
  curr_user_msg <- paste(user_turn_parts, collapse = "\n")

  # Normalize history into standardized role/content list
  norm_history <- list()
  if (is.list(history) && length(history) > 0L) {
    for (turn in history) {
      if (is.list(turn)) {
        r <- turn$role %||% "user"
        cnt <- turn$content %||% turn$message %||% turn$text %||% ""
        norm_history[[length(norm_history) + 1L]] <- list(role = as.character(r), content = as.character(cnt))
      }
    }
  }

  # Build messages list for chat completions API
  messages <- list()
  messages[[1L]] <- list(role = "system", content = system_message)
  for (turn in norm_history) {
    messages[[length(messages) + 1L]] <- turn
  }
  messages[[length(messages) + 1L]] <- list(role = "user", content = curr_user_msg)

  # Build full prompt string representation
  history_str_parts <- character(0)
  for (turn in norm_history) {
    prefix <- if (identical(turn$role, "assistant")) "Assistant: " else "User: "
    history_str_parts <- c(history_str_parts, paste0(prefix, turn$content))
  }

  full_parts <- c(system_message)
  if (length(history_str_parts) > 0L) {
    full_parts <- c(full_parts, "\n--- Conversation History ---", paste(history_str_parts, collapse = "\n\n"), "--- End History ---\n")
  }
  full_parts <- c(full_parts, curr_user_msg)
  full_prompt <- paste(full_parts, collapse = "\n\n")

  structure(
    list(
      system_message = system_message,
      user_message = curr_user_msg,
      system = system_message,
      user = curr_user_msg,
      history = norm_history,
      messages = messages,
      prompt = full_prompt
    ),
    class = c("sideview_chat_prompt", "sideview_prompt", "list")
  )
}

#' Extract Executable R Code from LLM Response Text
#'
#' Parses code fence blocks (` ```r ... ``` `, ` ```R ... ``` `, ` ``` ... ``` `)
#' out of LLM responses. If multiple fences exist, concatenates them. If no fence
#' is found, falls back to the trimmed raw text. Strips extraneous whitespace
#' and returns valid R code.
#'
#' @param response_text Character vector containing the LLM response text.
#'
#' @return A character string of extracted R code.
#' @export
sv_extract_code <- function(response_text) {
  if (is.null(response_text) || length(response_text) == 0L) {
    return("")
  }

  text <- paste(response_text, collapse = "\n")
  # Reasoning models (qwen3, deepseek-r1, ...) may prepend a <think> block.
  text <- gsub("(?s)<think>.*?</think>\\s*", "", text, perl = TRUE)

  # First check for explicit R code fences: ```r, ```R, ```{r...}
  r_pattern <- "(?s)```(?:[rR]|\\{r[^}]*\\})\\s*\\r?\\n(.*?)\\r?\\n?```"
  r_matches <- gregexpr(r_pattern, text, perl = TRUE)

  extracted <- character(0)
  reg_starts <- r_matches[[1]]

  if (length(reg_starts) > 0L && reg_starts[1] != -1L) {
    match_lens <- attr(r_matches[[1]], "match.length")
    for (i in seq_along(reg_starts)) {
      block_str <- substr(text, reg_starts[i], reg_starts[i] + match_lens[i] - 1L)
      inner <- sub("^```(?:[rR]|\\{r[^}]*\\})\\s*\\r?\\n", "", block_str, perl = TRUE)
      inner <- sub("\\r?\\n?```$", "", inner, perl = TRUE)
      extracted <- c(extracted, trimws(inner))
    }
  } else {
    # Fallback to generic ``` code fence
    gen_pattern <- "(?s)```(?:[a-zA-Z0-9_-]+)?\\s*\\r?\\n(.*?)\\r?\\n?```"
    gen_matches <- gregexpr(gen_pattern, text, perl = TRUE)
    reg_starts <- gen_matches[[1]]
    if (length(reg_starts) > 0L && reg_starts[1] != -1L) {
      match_lens <- attr(gen_matches[[1]], "match.length")
      for (i in seq_along(reg_starts)) {
        block_str <- substr(text, reg_starts[i], reg_starts[i] + match_lens[i] - 1L)
        inner <- sub("^```(?:[a-zA-Z0-9_-]+)?\\s*\\r?\\n", "", block_str, perl = TRUE)
        inner <- sub("\\r?\\n?```$", "", inner, perl = TRUE)
        extracted <- c(extracted, trimws(inner))
      }
    }
  }

  if (length(extracted) > 0L) {
    code <- paste(extracted[nzchar(extracted)], collapse = "\n")
  } else {
    code <- trimws(text)
  }

  trimws(code)
}

#' Call Local Ollama or OpenAI-Compatible LLM Endpoint
#'
#' Sends prompt requests to local Ollama (`http://localhost:11434`) or OpenAI-compatible
#' endpoints via `httr2`. Supports model selection, customizable endpoints, API key authentication,
#' and clean error reporting for network or HTTP status failures.
#'
#' @param prompt A character string or `sideview_prompt` object from `sv_build_prompt`.
#' @param backend Character string: either `"ollama"` or `"openai"`.
#' @param model Model name (e.g., `"llama3.2"`, `"llama3"`, `"gpt-4o-mini"`).
#' @param endpoint Base URL or full chat endpoint for the API.
#' @param api_key API key (for OpenAI or authenticated endpoints).
#' @param timeout Request timeout in seconds. Default 60.
#' @param extract_code Logical; if TRUE, runs `sv_extract_code()` on the response text. Default FALSE.
#' @param resolve_model Logical; for Ollama, if an untagged model such as `"llama3.2"` is not
#'   installed, retry once with an installed tag of it (e.g. `"llama3.2:3b"`). Default TRUE.
#' @param ... Additional options added to the request body (e.g. `temperature`). For Ollama,
#'   `think = FALSE` is sent unless you pass `think` or set `options(sideview.llm_think = TRUE)`,
#'   so reasoning models answer promptly.
#'
#' @return Character string containing the LLM response text (or extracted code if `extract_code = TRUE`).
#' @export
sv_call_llm <- function(prompt,
                        backend = c("ollama", "openai"),
                        model = NULL,
                        endpoint = NULL,
                        api_key = NULL,
                        timeout = 60,
                        extract_code = FALSE,
                        resolve_model = TRUE,
                        ...) {
  backend <- match.arg(backend)
  call_args <- list(prompt = prompt, backend = backend, endpoint = endpoint, api_key = api_key,
                    timeout = timeout, extract_code = extract_code, ...)

  # Format prompt into system and user messages
  if (inherits(prompt, "sideview_prompt") || is.list(prompt)) {
    sys_msg <- prompt$system_message %||% prompt$system %||% ""
    usr_msg <- prompt$user_message %||% prompt$user %||% prompt$prompt %||% ""
  } else {
    p_obj <- sv_build_prompt(as.character(prompt))
    sys_msg <- p_obj$system_message
    usr_msg <- p_obj$user_message
  }

  # Endpoint and model defaults
  if (backend == "ollama") {
    endpoint <- endpoint %||% getOption("sideview.llm_endpoint", Sys.getenv("OLLAMA_HOST", "http://localhost:11434"))
    model <- model %||% getOption("sideview.llm_model", Sys.getenv("SIDEVIEW_OLLAMA_MODEL", "llama3.2"))
    endpoint <- sub("/+$", "", endpoint)
    if (!grepl("/api/chat$", endpoint)) {
      endpoint <- paste0(endpoint, "/api/chat")
    }
  } else {
    endpoint <- endpoint %||% getOption("sideview.llm_endpoint", Sys.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1"))
    model <- model %||% getOption("sideview.llm_model", Sys.getenv("SIDEVIEW_OPENAI_MODEL", "gpt-4o-mini"))
    api_key <- api_key %||% getOption("sideview.llm_api_key", Sys.getenv("OPENAI_API_KEY", ""))
    endpoint <- sub("/+$", "", endpoint)
    if (!grepl("/chat/completions$", endpoint)) {
      endpoint <- paste0(endpoint, "/chat/completions")
    }
  }

  # Build messages array
  messages <- if (is.list(prompt) && !is.null(prompt$messages) && length(prompt$messages) > 0L) {
    prompt$messages
  } else {
    msgs <- list()
    if (nzchar(sys_msg)) {
      msgs <- c(msgs, list(list(role = "system", content = sys_msg)))
    }
    if (nzchar(usr_msg)) {
      msgs <- c(msgs, list(list(role = "user", content = usr_msg)))
    }
    msgs
  }

  payload <- list(
    model = model,
    messages = messages
  )

  if (backend == "ollama") {
    payload$stream <- FALSE
    payload$think <- isTRUE(getOption("sideview.llm_think", FALSE))
  }

  # Forward any additional kwargs (temperature, max_tokens, etc.)
  extra_args <- list(...)
  if (length(extra_args) > 0L) {
    for (nm in names(extra_args)) {
      if (nzchar(nm)) payload[[nm]] <- extra_args[[nm]]
    }
  }

  req <- httr2::request(endpoint)
  req <- httr2::req_method(req, "POST")
  req <- httr2::req_timeout(req, timeout)
  req <- httr2::req_headers(req, "Content-Type" = "application/json")

  if (backend == "openai" && !is.null(api_key) && nzchar(api_key)) {
    req <- httr2::req_headers(req, "Authorization" = paste("Bearer", api_key))
  }

  req <- httr2::req_body_json(req, payload)

  extract_llm_error <- function(resp_obj) {
    body_txt <- tryCatch(httr2::resp_body_string(resp_obj), error = function(e) "")
    tryCatch({
      err_json <- jsonlite::fromJSON(body_txt)
      if (is.list(err_json$error) && !is.null(err_json$error$message)) {
        err_json$error$message
      } else if (is.character(err_json$error)) {
        err_json$error
      } else if (!is.null(err_json$message)) {
        err_json$message
      } else {
        body_txt
      }
    }, error = function(e) body_txt)
  }

  # Execute request with error trapping
  resp <- tryCatch(
    httr2::req_perform(req),
    error = function(e) {
      if (inherits(e, "httr2_http")) {
        err_resp <- e$resp
        status <- httr2::resp_status(err_resp)
        err_msg <- extract_llm_error(err_resp)
        if (status == 404L) return(structure(list(err_msg = err_msg), class = "sv_llm_404"))
        stop(sprintf("Sideview LLM API error (%d): %s", status, err_msg), call. = FALSE)
      }
      # httr2 puts the useful cause (timeout, refused) in the parent condition.
      why <- conditionMessage(e)
      if (!is.null(e$parent)) why <- paste(why, conditionMessage(e$parent))
      stop(sprintf("Sideview LLM connection failed (%s at %s): %s", backend, endpoint, why), call. = FALSE)
    }
  )

  if (inherits(resp, "sv_llm_404")) {
    alt <- if (isTRUE(resolve_model) && backend == "ollama" && !grepl(":", model, fixed = TRUE)) {
      installed <- tryCatch(sv_llm_models("ollama", endpoint = endpoint), error = function(e) character())
      utils::head(installed[startsWith(installed, paste0(model, ":"))], 1L)
    } else {
      character()
    }
    if (length(alt) == 1L) {
      call_args$model <- alt
      call_args$resolve_model <- FALSE
      return(do.call(sv_call_llm, call_args))
    }
    stop(sprintf("Sideview LLM API error (404): %s", resp$err_msg), call. = FALSE)
  }

  # Verify status
  status <- httr2::resp_status(resp)
  if (status >= 400L) {
    err_msg <- extract_llm_error(resp)
    stop(sprintf("Sideview LLM API error (%d): %s", status, err_msg), call. = FALSE)
  }

  # Parse response body
  resp_json <- tryCatch(
    httr2::resp_body_json(resp),
    error = function(e) {
      stop("Failed to parse JSON response from LLM server: ", e$message, call. = FALSE)
    }
  )

  content <- NULL
  if (!is.null(resp_json$choices) && length(resp_json$choices) > 0L) {
    content <- resp_json$choices[[1]]$message$content
  } else if (!is.null(resp_json$message$content)) {
    content <- resp_json$message$content
  } else if (!is.null(resp_json$response)) {
    content <- resp_json$response
  }

  if (is.null(content)) {
    content <- ""
  }

  if (extract_code) {
    content <- sv_extract_code(content)
  }

  content
}

#' Turn an LLM failure into a short message with a fix hint
#'
#' @param err Error message from `sv_call_llm()` (or a custom `llm_fn`).
#' @param backend Backend name (`"ollama"` or `"openai"`).
#' @param model Model name, if known.
#' @return A single character string for display in the UI.
#' @noRd
sv_llm_error_message <- function(err, backend = "ollama", model = NULL) {
  err <- paste(as.character(err), collapse = " ")
  backend <- if (is.character(backend) && length(backend) == 1L) backend else "ollama"
  model <- model %||% getOption("sideview.llm_model",
    if (identical(backend, "ollama")) Sys.getenv("SIDEVIEW_OLLAMA_MODEL", "llama3.2") else "gpt-4o-mini")
  hint <- if (grepl("not found|404", err, ignore.case = TRUE) && identical(backend, "ollama")) {
    installed <- tryCatch(sv_llm_models("ollama", timeout = 2), error = function(e) character())
    sprintf("Model '%s' is not installed. Run `ollama pull %s` or set options(sideview.llm_model = \"...\")%s.",
            model, model,
            if (length(installed)) paste0(" (installed: ", paste(utils::head(installed, 6), collapse = ", "), ")") else "")
  } else if (grepl("connection failed|refused|couldn't connect|could not connect|timed? ?out|resolve host",
                   err, ignore.case = TRUE)) {
    if (identical(backend, "ollama")) {
      "Ollama is not reachable. Start it with `ollama serve`, or set options(sideview.llm_backend = \"openai\")."
    } else {
      "The API endpoint is not reachable. Check options(sideview.llm_endpoint) and your network."
    }
  } else if (grepl("401|403|api key|unauthori", err, ignore.case = TRUE)) {
    "The API rejected the key. Set options(sideview.llm_api_key) or the OPENAI_API_KEY variable."
  } else {
    NULL
  }
  msg <- paste0("AI request failed: ", sub("^Sideview LLM ", "", err))
  if (!is.null(hint)) msg <- paste(msg, hint, sep = "\n")
  msg
}

#' List the models available from an LLM backend
#'
#' Queries a local Ollama server (`/api/tags`) or an OpenAI-compatible server
#' (`/models`) for the installed or available model names. Useful for choosing
#' `options(sideview.llm_model = ...)`.
#'
#' @param backend `"ollama"` or `"openai"`.
#' @param endpoint Base URL. Defaults as in [sv_call_llm()]; a chat endpoint
#'   (`.../api/chat`, `.../chat/completions`) is also accepted.
#' @param api_key API key for OpenAI-compatible servers.
#' @param timeout Request timeout in seconds. Default 5.
#' @return A character vector of model names.
#' @export
sv_llm_models <- function(backend = c("ollama", "openai"), endpoint = NULL, api_key = NULL, timeout = 5) {
  backend <- match.arg(backend)
  if (backend == "ollama") {
    endpoint <- endpoint %||% getOption("sideview.llm_endpoint", Sys.getenv("OLLAMA_HOST", "http://localhost:11434"))
    base <- sub("/api/chat$", "", sub("/+$", "", endpoint))
    req <- httr2::request(paste0(base, "/api/tags"))
  } else {
    endpoint <- endpoint %||% getOption("sideview.llm_endpoint", Sys.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1"))
    api_key <- api_key %||% getOption("sideview.llm_api_key", Sys.getenv("OPENAI_API_KEY", ""))
    base <- sub("/chat/completions$", "", sub("/+$", "", endpoint))
    req <- httr2::request(paste0(base, "/models"))
    if (nzchar(api_key)) req <- httr2::req_headers(req, "Authorization" = paste("Bearer", api_key))
  }
  req <- httr2::req_timeout(req, timeout)
  body <- httr2::resp_body_json(httr2::req_perform(req))
  items <- if (backend == "ollama") body$models else body$data
  vapply(items, function(m) as.character(m$name %||% m$id %||% NA_character_), character(1))
}
