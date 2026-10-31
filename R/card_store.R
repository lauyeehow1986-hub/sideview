# Card store, card payload, shared normalisation and the per-session lazy env.
# All internal: the gadget, the widget and (later) the Shiny module use them.

# Rows a module sends to the browser; the rest is paged from R.
sv_preview_rows <- 500L

#' Normalise whatever the user passed into a list of `sideview_card`s
#'
#' A single object becomes a one-element list; unnamed elements are called
#' `Table_<i>`; elements that cannot be normalised are dropped.
#' @noRd
sv_normalize_cards <- function(cards) {
  card_list <- if (is.null(cards)) {
    list()
  } else if (inherits(cards, "sideview_card") || is.data.frame(cards) ||
             inherits(cards, c("gt_tbl", "flextable", "table"))) {
    list(cards)
  } else if (is.list(cards)) {
    cards
  } else {
    list(cards)
  }

  out <- list()
  for (i in seq_along(card_list)) {
    item <- card_list[[i]]
    if (!inherits(item, "sideview_card")) {
      nm <- names(card_list)[i]
      if (is.null(nm) || is.na(nm) || !nzchar(nm)) nm <- paste0("Table_", i)
      item <- tryCatch(sv_normalize(item, name = nm), error = function(e) NULL)
    }
    if (!is.null(item)) out[[length(out) + 1L]] <- item
  }
  out
}

#' A mutable store of cards, keyed by name (insertion order kept)
#'
#' `add(card)`, `replace(name, card)` (keeps the slot), `remove(name)`,
#' `get(key)` (name, then id; `NULL` if absent), `names()`, `all()`, `has(name)`.
#' @noRd
sv_card_store <- function(cards = list()) {
  by_name <- list()
  order <- character()
  self <- new.env(parent = emptyenv())

  self$add <- function(card) {
    nm <- card$name
    if (is.null(nm) || !nzchar(nm)) return(invisible(self))
    if (!nm %in% order) order <<- c(order, nm)
    by_name[[nm]] <<- card
    invisible(self)
  }
  self$replace <- function(name, card) {
    if (name %in% order) {
      by_name[[name]] <<- card
      if (!identical(card$name, name) && !is.null(card$name) && nzchar(card$name)) {
        # renamed on replace: the slot keeps its place under the new name
        by_name[[name]] <<- NULL
        order[order == name] <<- card$name
        by_name[[card$name]] <<- card
      }
      invisible(self)
    } else {
      self$add(card)
    }
  }
  self$remove <- function(name) {
    by_name[[name]] <<- NULL
    order <<- setdiff(order, name)
    invisible(self)
  }
  self$get <- function(key) {
    if (!is.character(key) || length(key) != 1L || is.na(key)) return(NULL)
    hit <- by_name[[key]]
    if (!is.null(hit)) return(hit)
    for (nm in order) {
      id <- by_name[[nm]]$id
      if (!is.null(id) && identical(id, key)) return(by_name[[nm]])
    }
    NULL
  }
  self$names <- function() order
  self$all <- function() by_name[order]
  self$has <- function(name) is.character(name) && length(name) == 1L && name %in% order

  for (card in cards) self$add(card)
  self
}

#' The card as the browser receives it
#'
#' Drops the R `source` (never serialised), adds labels, `lazy`, `codeRef` and the
#' true row count. With `preview_rows` the data is cut to that many rows and
#' `remote = TRUE` is added.
#' @noRd
sv_card_payload <- function(card, preview_rows = NULL) {
  if (is.data.frame(card$data)) {
    labels <- lapply(card$data, function(col) attr(col, "label", exact = TRUE))
    labels <- Filter(function(l) is.character(l) && length(l) == 1L, labels)
    if (length(labels)) card$col_labels <- labels
  }
  if (!is.null(card$col_types) && is.character(card$col_types)) {
    card$col_types <- as.list(card$col_types)
  }
  # The R source object stays in R; the browser only learns that the card is lazy.
  card$source <- NULL
  card$lazy <- if (isTRUE(card$is_lazy)) card$lazy_source else NULL
  card$codeRef <- card$code_ref
  total <- card$dims[1]
  if (length(total) == 1L && !is.na(total)) {
    card$totalRows <- if (total == round(total) && abs(total) < .Machine$integer.max) as.integer(total) else total
  }
  if (is.numeric(preview_rows) && length(preview_rows) == 1L && is.data.frame(card$data)) {
    card$data <- utils::head(card$data, preview_rows)
    card$remote <- TRUE
  }
  card
}

#' One private lazy (duckdb / arrow) env per Shiny session
#'
#' Created on first call and kept in `session$userData`; one `onSessionEnded`
#' close is registered, once.
#' @noRd
sv_session_lazy_env <- function(session) {
  env <- session$userData$sv_lazy_env
  if (is.null(env)) {
    env <- sv_lazy_env()
    session$userData$sv_lazy_env <- env
    session$onSessionEnded(function() sv_lazy_close(env))
  }
  env
}
