# Null-default helper
`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

#' Internal Implementation of Sideview Server
#'
#' @param input Shiny input object.
#' @param output Shiny output object.
#' @param session Shiny session object.
#' @param cards Raw cards or normalized `sideview_card` list.
#' @param llm_fn Function to call for AI completions.
#' @param insert_fn Function to call for editor code insertion.
#' @param console_fn Function to call for console execution.
#' @param gadget If `TRUE`, the app runs as a gadget: Done/Cancel and closing
#'   the window or browser tab stop the app and return to the console.
#' @noRd
sideview_server_impl <- function(input, output, session, cards, llm_fn, insert_fn, console_fn,
                                 gadget = FALSE) {
  # Normalize input cards
  card_list <- if (inherits(cards, "sideview_card") || is.data.frame(cards) ||
                   inherits(cards, c("gt_tbl", "flextable", "table"))) {
    list(cards)
  } else if (is.list(cards)) {
    cards
  } else {
    list(cards)
  }

  normalized_cards <- list()
  cards_by_name <- list()
  cards_by_id <- list()

  for (i in seq_along(card_list)) {
    c_item <- card_list[[i]]
    if (!inherits(c_item, "sideview_card")) {
      nm <- names(card_list)[i]
      if (is.null(nm) || !nzchar(nm)) nm <- paste0("Table_", i)
      c_item <- tryCatch(sv_normalize(c_item, name = nm), error = function(e) NULL)
    }
    if (!is.null(c_item)) {
      normalized_cards[[length(normalized_cards) + 1]] <- c_item
      if (!is.null(c_item$name) && nzchar(c_item$name)) {
        cards_by_name[[c_item$name]] <- c_item
      }
      if (!is.null(c_item$id) && nzchar(c_item$id)) {
        cards_by_id[[c_item$id]] <- c_item
      }
    }
  }

  # Helper to dispatch custom messages and record them for testing/audit
  dispatch_message <- function(type, message) {
    if (is.null(session$userData$custom_messages)) {
      session$userData$custom_messages <- list()
    }
    session$userData$custom_messages[[length(session$userData$custom_messages) + 1]] <- list(
      type = type,
      message = message
    )
    tryCatch(session$sendCustomMessage(type, message), error = function(e) NULL)
  }

  # Gadget lifecycle. stopApp() must run once: a second call (e.g. from
  # onSessionEnded after Done) would replace the returned code with NULL.
  stopped <- FALSE
  stop_gadget <- function(value = invisible(NULL)) {
    if (stopped) return(invisible(NULL))
    stopped <<- TRUE
    session$userData$sideview_result <- list(value = value)
    tryCatch(shiny::stopApp(value), error = function(e) NULL)
  }
  if (isTRUE(gadget)) {
    shiny::observeEvent(input$sideview_done, {
      code <- input$sideview_done$code %||% ""
      code <- if (is.character(code) && length(code) == 1L && nzchar(trimws(code))) code else NULL
      stop_gadget(invisible(code))
    }, ignoreInit = FALSE)
    # `cancel` is what RStudio sends when the dialog window is closed.
    shiny::observeEvent(input$cancel, stop_gadget(), ignoreInit = FALSE)
    shiny::observeEvent(input$sideview_cancel, stop_gadget(), ignoreInit = FALSE)
    # Closing the browser tab (viewer = "browser") frees the console.
    session$onSessionEnded(function() stop_gadget())
  }

  # 1. Column Mapped -> Join Code Generation
  shiny::observeEvent(input$column_mapped, {
    evt <- input$column_mapped
    if (is.null(evt)) return()

    # Relational chaining: multiple joins passed as a sequence
    joins <- evt$joins
    if (!is.null(joins) && is.list(joins) && length(joins) > 0) {
      code <- tryCatch({
        pieces <- character(length(joins))
        for (i in seq_along(joins)) {
          j <- joins[[i]]
          j_from <- j$from_table %||% j$table1
          j_to <- j$to_table %||% j$table2
          j_col1 <- unlist(j$from_cols %||% j$from_col %||% j$col1 %||% j$cols1, use.names = FALSE)
          j_col2 <- unlist(j$to_cols %||% j$to_col %||% j$col2 %||% j$cols2, use.names = FALSE)
          if (is.null(j_col2)) j_col2 <- j_col1
          j_type <- j$join_type %||% "left_join"
          if (i == 1) {
            pieces[i] <- sv_code_join(j_from, j_to, j_col1, j_col2, join_type = j_type, pipe = TRUE)
          } else {
            pieces[i] <- sv_code_join(NULL, j_to, j_col1, j_col2, join_type = j_type, pipe = TRUE)
          }
        }
        paste(pieces, collapse = " %>%\n  ")
      }, error = function(e) {
        sprintf("# Error generating join code: %s", conditionMessage(e))
      })
      dispatch_message("sideview_code_update", list(code = code))
      return()
    }

    from_tbl <- evt$from_table %||% evt$table1
    from_col <- evt$from_cols %||% evt$from_col %||% evt$col1 %||% evt$cols1
    to_tbl <- evt$to_table %||% evt$table2
    to_col <- evt$to_cols %||% evt$to_col %||% evt$col2 %||% evt$cols2
    join_type <- evt$join_type %||% "left_join"

    if (!is.null(from_col)) from_col <- unlist(from_col, use.names = FALSE)
    if (!is.null(to_col)) to_col <- unlist(to_col, use.names = FALSE)
    if (is.null(to_col)) to_col <- from_col

    code <- tryCatch({
      sv_code_join(
        df1 = from_tbl,
        df2 = to_tbl,
        col1 = from_col,
        col2 = to_col,
        join_type = join_type,
        pipe = TRUE
      )
    }, error = function(e) {
      sprintf("# Error generating join code: %s", conditionMessage(e))
    })

    dispatch_message("sideview_code_update", list(code = code))
  }, ignoreInit = FALSE)

  # 1b. Column Disconnected -> Sync Event
  shiny::observeEvent(input$column_disconnected, {
    evt <- input$column_disconnected
    if (is.null(evt)) return()
    code <- if (!is.null(evt$code) && nzchar(evt$code)) {
      evt$code
    } else {
      "# Connect two columns to generate pipeline code"
    }
    dispatch_message("sideview_code_update", list(code = code))
  }, ignoreInit = FALSE)

  # 1bb. Clear Operations -> Reset Event
  shiny::observeEvent(input$clear_operations, {
    evt <- input$clear_operations
    if (is.null(evt)) return()
    dispatch_message("sideview_code_update", list(code = "# Connect two columns to generate pipeline code"))
  }, ignoreInit = FALSE)

  # 1c. Column Sorted -> Arrange Code Generation
  shiny::observeEvent(input$column_sorted, {
    evt <- input$column_sorted
    if (is.null(evt)) return()
    tbl <- evt$table %||% 'df'
    col <- evt$column
    dir <- evt$direction %||% 'asc'
    if (is.null(col) || !nzchar(col)) return()
    if (dir == 'none') return()
    code <- tryCatch({
      sv_code_arrange(df_name = tbl, col = col, desc = (dir == 'desc'), pipe = TRUE)
    }, error = function(e) {
      sprintf('# Error generating arrange code: %s', conditionMessage(e))
    })
    dispatch_message('sideview_code_update', list(code = code))
  }, ignoreInit = FALSE)

  # 1d. Column Filtered -> Filter Code Generation
  shiny::observeEvent(input$column_filtered, {
    evt <- input$column_filtered
    if (is.null(evt)) return()
    tbl <- evt$table %||% 'df'
    cond <- evt$condition
    if (is.null(cond) || !nzchar(cond)) return()
    code <- tryCatch({
      sv_code_filter(df_name = tbl, condition = cond, pipe = TRUE)
    }, error = function(e) {
      sprintf('# Error generating filter code: %s', conditionMessage(e))
    })
    dispatch_message('sideview_code_update', list(code = code))
  }, ignoreInit = FALSE)

  # 1e. Row windows for large cards: sort/filter/scroll answered from the full data
  row_order_caches <- new.env(parent = emptyenv())
  shiny::observeEvent(input$sideview_rows_request, {
    req <- input$sideview_rows_request
    if (is.null(req) || is.null(req$card_id)) return()
    card <- cards_by_id[[req$card_id]] %||% cards_by_name[[req$card_id]]
    if (is.null(card) || !is.data.frame(card$data)) return()
    cache <- row_order_caches[[req$card_id]]
    if (is.null(cache)) {
      cache <- new.env(parent = emptyenv())
      row_order_caches[[req$card_id]] <- cache
    }
    win <- tryCatch(sv_rows_window(card$data, req, order_cache = cache), error = function(e) {
      list(error = conditionMessage(e))
    })
    win$card_id <- req$card_id
    win$version <- req$version %||% 0L
    dispatch_message("sideview_rows", win)
  }, ignoreInit = FALSE)

  # 2. Column Renamed -> Rename Code Generation
  shiny::observeEvent(input$column_renamed, {
    evt <- input$column_renamed
    if (is.null(evt)) return()

    tbl <- evt$table %||% evt$table_name %||% "df"
    old_c <- evt$old_col
    new_c <- evt$new_col

    code <- tryCatch({
      sv_code_rename(
        df_name = tbl,
        old_col = old_c,
        new_col = new_c,
        pipe = TRUE
      )
    }, error = function(e) {
      sprintf("# Error generating rename code: %s", conditionMessage(e))
    })

    dispatch_message("sideview_code_update", list(code = code))
  }, ignoreInit = FALSE)

  # 3. Discrepancy Check -> Discrepancy Analysis
  shiny::observeEvent(input$discrepancy_check, {
    evt <- input$discrepancy_check
    if (is.null(evt)) return()

    tbl1 <- evt$table1 %||% evt$from_table
    col1 <- evt$col1 %||% evt$from_col
    tbl2 <- evt$table2 %||% evt$to_table
    col2 <- evt$col2 %||% evt$to_col

    if (is.null(tbl1) || is.null(tbl2) || is.null(col1) || is.null(col2) ||
        !nzchar(tbl1) || !nzchar(tbl2) || !nzchar(col1) || !nzchar(col2)) return()

    tryCatch({
      # Resolve card data
      c1 <- cards_by_name[[tbl1]] %||% cards_by_id[[tbl1]]
      c2 <- cards_by_name[[tbl2]] %||% cards_by_id[[tbl2]]

      x_vec <- if (!is.null(c1) && !is.null(c1$data) && col1 %in% colnames(c1$data)) {
        c1$data[[col1]]
      } else {
        NULL
      }
      y_vec <- if (!is.null(c2) && !is.null(c2$data) && col2 %in% colnames(c2$data)) {
        c2$data[[col2]]
      } else {
        NULL
      }

      disc <- sv_detect_discrepancies(x_vec, y_vec)

      dispatch_message("sideview_discrepancies", list(
        from_table = tbl1,
        to_table = tbl2,
        from_col = col1,
        to_col = col2,
        exact_matches = disc$exact_matches,
        fuzzy_matches = disc$fuzzy_matches,
        only_in_x = disc$only_in_x,
        only_in_y = disc$only_in_y,
        stats = disc$stats
      ))
    }, error = function(e) {
      message("sideview discrepancy analysis warning: ", conditionMessage(e))
    })
  }, ignoreInit = FALSE)

  # 3b. Request Suggested Mappings -> Heuristic FK detection & dispatch
  shiny::observeEvent(input$request_suggested_mappings, {
    evt <- input$request_suggested_mappings
    min_conf <- if (is.list(evt) && !is.null(evt$min_confidence)) {
      as.numeric(evt$min_confidence)
    } else {
      0.70
    }

    tryCatch({
      suggestions <- sv_suggest_mappings(normalized_cards, min_confidence = min_conf)
      candidates <- if (is.data.frame(suggestions) && nrow(suggestions) > 0) {
        lapply(seq_len(nrow(suggestions)), function(i) {
          as.list(suggestions[i, , drop = FALSE])
        })
      } else {
        list()
      }

      dispatch_message("sideview_suggested_mappings", list(
        candidates = candidates,
        count = length(candidates)
      ))
    }, error = function(e) {
      message("sideview suggested mappings warning: ", conditionMessage(e))
    })
  }, ignoreInit = FALSE)

  # 3c. Apply Auto Clean -> Discrepancy Auto-Resolution Codegen
  shiny::observeEvent(input$apply_auto_clean, {
    evt <- input$apply_auto_clean
    if (is.null(evt)) return()

    tryCatch({
      payload <- evt$discrepancy %||% evt
      tbl <- evt$table %||% evt$from_table %||% evt$table1 %||% payload$from_table %||% "df"
      col <- evt$col %||% evt$from_col %||% evt$col1 %||% payload$from_col %||% payload$col %||% "status"
      pipe <- isTRUE(evt$pipe)

      code <- sv_auto_clean_rules(payload, df_name = tbl, col = col, pipe = pipe)
      if (!is.null(code) && nzchar(code)) {
        dispatch_message("sideview_code_update", list(code = code))
      }
    }, error = function(e) {
      message("sideview auto-clean warning: ", conditionMessage(e))
    })
  }, ignoreInit = FALSE)

  # 4. Run AI Prompt -> LLM Generation
  shiny::observeEvent(input$run_ai_prompt, {
    evt <- input$run_ai_prompt
    if (is.null(evt) || is.null(evt$prompt) || !nzchar(evt$prompt)) return()

    schema <- sv_build_schema_context(normalized_cards)
    prompt_obj <- sv_build_prompt(evt$prompt, schema_context = schema)
    backend <- evt$backend %||% getOption("sideview.llm_backend", Sys.getenv("SIDEVIEW_LLM_BACKEND", "ollama"))
    model <- evt$model %||% getOption("sideview.llm_model", NULL)
    endpoint <- evt$endpoint %||% getOption("sideview.llm_endpoint", NULL)
    api_key <- evt$api_key %||% getOption("sideview.llm_api_key", NULL)

    ai_err <- NULL
    ai_code <- tryCatch({
      raw_resp <- llm_fn(
        prompt = prompt_obj,
        backend = backend,
        model = model,
        endpoint = endpoint,
        api_key = api_key
      )
      extracted <- sv_extract_code(raw_resp)
      if (nzchar(extracted)) extracted else raw_resp
    }, error = function(e) {
      ai_err <<- conditionMessage(e)
      NULL
    })

    if (is.null(ai_err)) {
      dispatch_message("sideview_code_update", list(code = ai_code))
      parses <- tryCatch({ parse(text = ai_code); TRUE }, error = function(e) FALSE)
      dispatch_message("sideview_ai_status", list(
        success = parses,
        message = if (parses) "AI code ready. Review it before running." else
          "The AI reply is not valid R code. Review and edit it, or try a larger model."
      ))
    } else {
      # Keep the user's current code; explain the failure and how to fix it.
      dispatch_message("sideview_ai_status", list(
        success = FALSE,
        message = sv_llm_error_message(ai_err, backend = backend, model = model)
      ))
    }
  }, ignoreInit = FALSE)

  # 4b. Send Copilot Chat -> Conversational Multi-Turn LLM Generation
  shiny::observeEvent(input$send_copilot_chat, {
    evt <- input$send_copilot_chat
    if (is.null(evt)) return()

    user_msg <- if (is.list(evt)) {
      evt$message %||% evt$prompt %||% evt$text %||% ""
    } else {
      as.character(evt)
    }

    if (!nzchar(trimws(user_msg))) return()

    if (is.null(session$userData$copilot_history)) {
      session$userData$copilot_history <- list()
    }
    history <- session$userData$copilot_history
    if (length(history) > 20L) {
      history <- utils::tail(history, 20L)
      session$userData$copilot_history <- history
    }

    current_code <- if (is.list(evt)) evt$current_code %||% evt$code %||% NULL else NULL
    if (is.null(current_code) || !nzchar(trimws(current_code))) {
      current_code <- NULL
    }

    schema <- sv_build_schema_context(normalized_cards)
    prompt_obj <- sv_build_chat_prompt(
      user_message = user_msg,
      history = history,
      current_code = current_code,
      schema_context = schema
    )

    backend <- if (is.list(evt) && !is.null(evt$backend)) evt$backend else getOption("sideview.llm_backend", Sys.getenv("SIDEVIEW_LLM_BACKEND", "ollama"))
    model <- if (is.list(evt) && !is.null(evt$model)) evt$model else getOption("sideview.llm_model", NULL)
    endpoint <- if (is.list(evt) && !is.null(evt$endpoint)) evt$endpoint else getOption("sideview.llm_endpoint", NULL)
    api_key <- if (is.list(evt) && !is.null(evt$api_key)) evt$api_key else getOption("sideview.llm_api_key", NULL)

    chat_err <- NULL
    reply_text <- tryCatch({
      llm_fn(
        prompt = prompt_obj,
        backend = backend,
        model = model,
        endpoint = endpoint,
        api_key = api_key
      )
    }, error = function(e) {
      chat_err <<- conditionMessage(e)
      paste0("# Copilot request failed: ", conditionMessage(e))
    })
    if (!is.null(chat_err)) {
      dispatch_message("sideview_ai_status", list(
        success = FALSE,
        message = sv_llm_error_message(chat_err, backend = backend, model = model)
      ))
    }

    has_code_fence <- grepl("```", reply_text, fixed = TRUE)
    extracted_code <- if (has_code_fence) sv_extract_code(reply_text) else ""

    # Append turns to session history
    session$userData$copilot_history[[length(session$userData$copilot_history) + 1L]] <- list(
      role = "user",
      content = user_msg
    )
    session$userData$copilot_history[[length(session$userData$copilot_history) + 1L]] <- list(
      role = "assistant",
      content = reply_text
    )

    if (length(session$userData$copilot_history) > 20L) {
      session$userData$copilot_history <- utils::tail(session$userData$copilot_history, 20L)
    }

    # Dispatch custom messages
    dispatch_message("sideview_copilot_reply", list(
      text = reply_text,
      code = extracted_code,
      user_message = user_msg
    ))

    if (has_code_fence && !is.null(extracted_code) && nzchar(trimws(extracted_code))) {
      dispatch_message("sideview_code_update", list(code = extracted_code))
    }
  }, ignoreInit = FALSE)

  # 5. Inject Script -> rstudioapi insertion
  shiny::observeEvent(input$inject_script, {
    evt <- input$inject_script
    if (is.null(evt)) return()
    code <- if (is.list(evt)) evt$code else evt
    res <- insert_fn(code)
    dispatch_message("sideview_inject_result", res)
  }, ignoreInit = FALSE)

  # 6. Send Console -> rstudioapi console execution (queued)
  shiny::observeEvent(input$send_console, {
    evt <- input$send_console
    if (is.null(evt)) return()
    code <- if (is.list(evt)) evt$code else evt
    res <- console_fn(code)
    if (isTRUE(res$success)) {
      res$message <- "Code queued to RStudio console (will execute as soon as the gadget closes, or use 'Run & Exit')!"
    }
    dispatch_message("sideview_console_result", res)
  }, ignoreInit = FALSE)

  # 6b. Send Console & Exit -> stops gadget so RStudio console executes immediately
  shiny::observeEvent(input$send_console_and_exit, {
    evt <- input$send_console_and_exit
    if (is.null(evt)) return()
    code <- if (is.list(evt)) evt$code else evt
    res <- console_fn(code)
    dispatch_message("sideview_console_result", res)
    stop_gadget()
  }, ignoreInit = FALSE)

  # 6c. Evaluate in .GlobalEnv -> executes code in active R session environment
  shiny::observeEvent(input$eval_env, {
    evt <- input$eval_env
    if (is.null(evt)) return()
    code <- if (is.list(evt)) evt$code else evt
    # The value of the last expression is kept in the global environment
    # (default `sv_result`) instead of being thrown away.
    target <- if (is.list(evt)) evt$assign_to %||% "sv_result" else "sv_result"
    if (!is.character(target) || length(target) != 1L || !identical(make.names(target), target)) {
      target <- "sv_result"
    }
    eval_res <- tryCatch({
      expr <- parse(text = code)
      out <- eval(expr, envir = .GlobalEnv)
      if (!is.null(out)) assign(target, out, envir = .GlobalEnv)
      msg <- if (is.data.frame(out)) {
        sprintf("Executed in R environment: %d rows x %d cols, saved as `%s`.", nrow(out), ncol(out), target)
      } else if (!is.null(out)) {
        sprintf("Executed successfully in R environment; result saved as `%s`.", target)
      } else {
        "Executed successfully in R environment."
      }
      list(success = TRUE, destination = "environment", message = msg,
           assigned = if (is.null(out)) NULL else target)
    }, error = function(e) {
      list(success = FALSE, destination = "environment", message = paste0("Execution error: ", conditionMessage(e)))
    })
    dispatch_message("sideview_eval_result", eval_res)
  }, ignoreInit = FALSE)

  # 7. Highlight Changes
  shiny::observeEvent(input$sideview_highlight_changed, {
    # Highlight events can be captured or relayed if needed
  }, ignoreInit = FALSE)
}

#' Sideview Server Logic
#'
#' Orchestrates bi-directional Shiny reactivity between the infinite 2D canvas
#' and the R session. Handles field mapping (`column_mapped`), column renaming
#' (`column_renamed`), discrepancy calculations (`discrepancy_check`), natural
#' language AI prompts (`run_ai_prompt`), RStudio script injection (`inject_script`),
#' and RStudio console execution (`send_console`).
#'
#' @param cards A `sideview_card` object, a list of `sideview_card` objects,
#'   or tabular objects to be normalized.
#' @param ... Additional arguments.
#' @param llm_fn Function used to execute LLM queries (default `sv_call_llm`).
#' @param insert_fn Function used to insert code into active RStudio document (default `sv_insert_code`).
#' @param console_fn Function used to send code to RStudio console (default `sv_send_to_console`).
#' @param gadget If `TRUE`, run as a gadget: the Done and Cancel buttons, closing the
#'   RStudio dialog, and closing the browser tab all stop the app. Leave `FALSE`
#'   when embedding the server in your own multi-user Shiny app.
#'
#' @return A Shiny server function `function(input, output, session)`.
#' @export
sideview_server <- function(cards = list(),
                            ...,
                            llm_fn = sv_call_llm,
                            insert_fn = sv_insert_code,
                            console_fn = sv_send_to_console,
                            gadget = FALSE) {
  dots <- list(...)
  # If invoked directly as sideview_server(input, output, session, ...)
  if (length(dots) >= 2 && inherits(dots[[2]], c("ShinySession", "MockShinySession"))) {
    input <- cards
    output <- dots[[1]]
    session <- dots[[2]]
    extra_cards <- if (length(dots) >= 3) dots[[3]] else list()
    return(sideview_server_impl(input, output, session, extra_cards, llm_fn, insert_fn, console_fn,
                                gadget = gadget))
  }

  function(input, output, session) {
    sideview_server_impl(input, output, session, cards, llm_fn, insert_fn, console_fn,
                         gadget = gadget)
  }
}
