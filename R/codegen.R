#' Escape R Identifiers with Backticks If Non-Syntactic
#'
#' @param x Character vector of identifier names.
#' @return Character vector of identifiers, escaped with backticks if necessary.
#' @export
sv_escape_ident <- function(x) {
  if (is.null(x) || length(x) == 0) return(character(0))
  vapply(x, function(name) {
    if (is.na(name)) return(NA_character_)
    if (grepl("^`[^`]+`$", name)) return(name)
    reserved <- c("if", "else", "repeat", "while", "function", "for", "in", 
                  "next", "break", "TRUE", "FALSE", "NULL", "Inf", "NaN", 
                  "NA", "NA_integer_", "NA_real_", "NA_complex_", "NA_character_")
    is_syntactic <- (make.names(name) == name) && !(name %in% reserved)
    if (is_syntactic) {
      name
    } else {
      escaped <- gsub("`", "\\\\`", name)
      sprintf("`%s`", escaped)
    }
  }, FUN.VALUE = character(1), USE.NAMES = FALSE)
}

#' Generate tidyverse Code for Column Renaming
#'
#' @param df_name Name of the data frame.
#' @param old_col Existing column name(s).
#' @param new_col New column name(s).
#' @param pipe Logical; if TRUE, uses pipe syntax `df %>% dplyr::rename(...)`.
#' @return A character string of R code.
#' @export
sv_code_rename <- function(df_name, old_col, new_col, pipe = FALSE) {
  if (length(old_col) == 0 || length(new_col) == 0) {
    stop("`old_col` and `new_col` must not be empty.")
  }
  if (length(old_col) != length(new_col)) {
    stop("`old_col` and `new_col` must have the same length.")
  }
  esc_old <- sv_escape_ident(old_col)
  esc_new <- sv_escape_ident(new_col)
  args <- paste(sprintf("%s = %s", esc_new, esc_old), collapse = ", ")
  
  if (pipe) {
    esc_df <- if (is.null(df_name) || !nzchar(df_name)) NULL else sv_escape_ident(df_name)
    if (is.null(esc_df)) {
      sprintf("dplyr::rename(%s)", args)
    } else {
      sprintf("%s %%>%% dplyr::rename(%s)", esc_df, args)
    }
  } else {
    esc_df <- if (is.null(df_name) || !nzchar(df_name)) NULL else sv_escape_ident(df_name)
    if (is.null(esc_df)) {
      sprintf("dplyr::rename(%s)", args)
    } else {
      sprintf("dplyr::rename(%s, %s)", esc_df, args)
    }
  }
}

#' Generate tidyverse Code for Relational Table Joins
#'
#' @param df1 Name of the first data frame (optional / can be NULL when constructing intermediate piped join segments).
#' @param df2 Name of the second data frame.
#' @param col1 Key column name(s) in df1.
#' @param col2 Key column name(s) in df2 (defaults to col1).
#' @param join_type Type of join: "left", "inner", "anti", "right", "full", "semi".
#' @param pipe Logical; if TRUE, uses pipe syntax `df1 %>% dplyr::<join_type>(df2, ...)`.
#' @return A character string of R code.
#' @export
sv_code_join <- function(df1, df2, col1, col2 = col1, join_type = "left", pipe = FALSE) {
  if (missing(df2) || is.null(df2) || length(df2) != 1 || is.na(df2) || !nzchar(df2)) {
    stop("Join table `df2` must be a single non-empty character string.")
  }

  jt <- tolower(join_type)
  jt <- sub("_join$", "", jt)
  valid_joins <- c("left", "inner", "anti", "right", "full", "semi")
  if (!jt %in% valid_joins) {
    stop(sprintf("Unsupported join_type: '%s'. Must be one of: %s", join_type, paste(valid_joins, collapse = ", ")))
  }
  fn_name <- paste0("dplyr::", jt, "_join")

  if (is.list(col1)) col1 <- unlist(col1, use.names = FALSE)
  if (missing(col2) || is.null(col2)) {
    col2 <- col1
  } else if (is.list(col2)) {
    col2 <- unlist(col2, use.names = FALSE)
  }

  col1 <- as.character(col1)
  col2 <- as.character(col2)

  # Strip outer backticks if present
  col1 <- gsub("^`|`$", "", col1)
  col2 <- gsub("^`|`$", "", col2)

  if (length(col1) == 0 || length(col2) == 0) {
    stop("Join columns (`col1` and `col2`) must not be empty.")
  }
  if (length(col1) != length(col2)) {
    stop("`col1` and `col2` must have the same length.")
  }

  # Format by argument
  is_same <- identical(col1, col2) || (!anyNA(col1) && !anyNA(col2) && all(col1 == col2))
  if (is_same) {
    if (length(col1) == 1) {
      by_str <- sprintf('by = %s', deparse1(col1))
    } else {
      by_str <- sprintf('by = c(%s)', paste(vapply(col1, deparse1, character(1)), collapse = ", "))
    }
  } else {
    pairs <- sprintf('%s = %s', vapply(col1, deparse1, character(1)), vapply(col2, deparse1, character(1)))
    by_str <- sprintf('by = c(%s)', paste(pairs, collapse = ", "))
  }

  has_df1 <- !is.null(df1) && length(df1) == 1 && !is.na(df1) && nzchar(df1)
  esc_df1 <- if (has_df1) sv_escape_ident(df1) else NULL
  esc_df2 <- sv_escape_ident(df2)

  if (pipe) {
    if (has_df1) {
      sprintf("%s %%>%% %s(%s, %s)", esc_df1, fn_name, esc_df2, by_str)
    } else {
      sprintf("%s(%s, %s)", fn_name, esc_df2, by_str)
    }
  } else {
    if (has_df1) {
      sprintf("%s(%s, %s, %s)", fn_name, esc_df1, esc_df2, by_str)
    } else {
      sprintf("%s(%s, %s)", fn_name, esc_df2, by_str)
    }
  }
}

#' Generate tidyverse Code for Column Mutation
#'
#' @param df_name Name of the data frame.
#' @param new_col Name of the column(s) being created or transformed.
#' @param expr R expression string(s) to evaluate.
#' @param pipe Logical; if TRUE, uses pipe syntax `df %>% dplyr::mutate(...)`.
#' @return A character string of R code.
#' @export
sv_code_mutate <- function(df_name, new_col, expr, pipe = FALSE) {
  if (length(new_col) != length(expr)) {
    stop("`new_col` and `expr` must have the same length.")
  }
  esc_cols <- sv_escape_ident(new_col)
  args <- paste(sprintf("%s = %s", esc_cols, expr), collapse = ", ")
  
  if (pipe) {
    esc_df <- if (is.null(df_name) || !nzchar(df_name)) NULL else sv_escape_ident(df_name)
    if (is.null(esc_df)) sprintf("dplyr::mutate(%s)", args) else sprintf("%s %%>%% dplyr::mutate(%s)", esc_df, args)
  } else {
    esc_df <- if (is.null(df_name) || !nzchar(df_name)) NULL else sv_escape_ident(df_name)
    if (is.null(esc_df)) {
      sprintf("dplyr::mutate(%s)", args)
    } else {
      sprintf("dplyr::mutate(%s, %s)", esc_df, args)
    }
  }
}

#' Generate tidyverse Code for Filtering Rows
#'
#' @param df_name Name of the data frame.
#' @param condition Character vector of boolean filter expressions.
#' @param pipe Logical; if TRUE, uses pipe syntax `df %>% dplyr::filter(...)`.
#' @return A character string of R code.
#' @export
sv_code_filter <- function(df_name, condition, pipe = FALSE) {
  args <- paste(condition, collapse = ", ")
  if (pipe) {
    esc_df <- if (is.null(df_name) || !nzchar(df_name)) NULL else sv_escape_ident(df_name)
    if (is.null(esc_df)) {
      sprintf("dplyr::filter(%s)", args)
    } else {
      sprintf("%s %%>%% dplyr::filter(%s)", esc_df, args)
    }
  } else {
    esc_df <- if (is.null(df_name) || !nzchar(df_name)) NULL else sv_escape_ident(df_name)
    if (is.null(esc_df)) {
      sprintf("dplyr::filter(%s)", args)
    } else {
      sprintf("dplyr::filter(%s, %s)", esc_df, args)
    }
  }
}

#' Generate tidyverse Code for Arranging (Sorting) Rows
#'
#' @param df_name Name of the data frame.
#' @param col Character vector of column name(s) to sort by.
#' @param desc Logical vector indicating descending order for each column.
#'   Recycled to match the length of `col`. Defaults to `FALSE`.
#' @param pipe Logical; if TRUE, uses pipe syntax `df %>% dplyr::arrange(...)`.
#' @return A character string of R code.
#' @export
sv_code_arrange <- function(df_name, col, desc = FALSE, pipe = FALSE) {
  if (is.null(col) || length(col) == 0) {
    stop('`col` must not be empty.')
  }
  esc_cols <- sv_escape_ident(col)
  desc <- rep_len(as.logical(desc), length(col))
  
  col_terms <- mapply(function(c_name, is_desc) {
    if (isTRUE(is_desc)) {
      sprintf('dplyr::desc(%s)', c_name)
    } else {
      c_name
    }
  }, esc_cols, desc, USE.NAMES = FALSE)
  
  args <- paste(col_terms, collapse = ', ')
  
  if (pipe) {
    esc_df <- if (is.null(df_name) || !nzchar(df_name)) NULL else sv_escape_ident(df_name)
    if (is.null(esc_df)) {
      sprintf("dplyr::arrange(%s)", args)
    } else {
      sprintf("%s %%>%% dplyr::arrange(%s)", esc_df, args)
    }
  } else {
    esc_df <- if (is.null(df_name) || !nzchar(df_name)) NULL else sv_escape_ident(df_name)
    if (is.null(esc_df)) {
      sprintf('dplyr::arrange(%s)', args)
    } else {
      sprintf('dplyr::arrange(%s, %s)', esc_df, args)
    }
  }
}

#' Generate tidyverse Code for Selecting Columns
#'
#' @param df_name Name of the data frame.
#' @param cols Character vector of column names to select.
#' @param pipe Logical; if TRUE, uses pipe syntax `df %>% dplyr::select(...)`.
#' @return A character string of R code.
#' @export
sv_code_select <- function(df_name, cols, pipe = FALSE) {
  esc_cols <- sv_escape_ident(cols)
  args <- paste(esc_cols, collapse = ", ")
  if (pipe) {
    esc_df <- if (is.null(df_name) || !nzchar(df_name)) NULL else sv_escape_ident(df_name)
    if (is.null(esc_df)) {
      sprintf("dplyr::select(%s)", args)
    } else {
      sprintf("%s %%>%% dplyr::select(%s)", esc_df, args)
    }
  } else {
    esc_df <- if (is.null(df_name) || !nzchar(df_name)) NULL else sv_escape_ident(df_name)
    if (is.null(esc_df)) {
      sprintf("dplyr::select(%s)", args)
    } else {
      sprintf("dplyr::select(%s, %s)", esc_df, args)
    }
  }
}

#' Detect Exact Matches, Discrepancies, and Fuzzy Near-Matches
#'
#' Compares distinct values between two vectors (e.g. columns mapped across tables),
#' computing exact matches, values only in x, values only in y, fuzzy/near-matches
#' using Levenshtein distance (adist), and comprehensive match statistics.
#'
#' @param x Vector of values from the first column.
#' @param y Vector of values from the second column.
#' @param max_distance Maximum Levenshtein edit distance for fuzzy matching (default 2).
#' @return A list with elements:
#' \itemize{
#'   \item `exact_matches`: character vector of values present in both x and y.
#'   \item `fuzzy_matches`: data.frame with columns `x`, `y`, `distance`.
#'   \item `only_in_x`: character vector of values present only in x.
#'   \item `only_in_y`: character vector of values present only in y.
#'   \item `stats`: list of match statistics (counts, NA counts, match rate).
#'   \item `match_stats`: alias to `stats`.
#' }
#' @export
sv_detect_discrepancies <- function(x, y, max_distance = 2) {
  max_dist <- if (is.null(max_distance) || length(max_distance) == 0 || is.na(max_distance[1])) {
    2L
  } else {
    max(0L, as.integer(max_distance[1]))
  }
  
  na_x <- sum(is.na(x))
  na_y <- sum(is.na(y))
  
  clean_x <- if (is.null(x)) character(0) else as.character(x[!is.na(x)])
  clean_y <- if (is.null(y)) character(0) else as.character(y[!is.na(y)])
  
  ux <- unique(clean_x)
  uy <- unique(clean_y)
  
  exact_matches <- intersect(ux, uy)
  only_in_x <- setdiff(ux, uy)
  only_in_y <- setdiff(uy, ux)
  
  # Vectorized fuzzy matching: calculate distance matrix in C
  fuzzy_matches <- data.frame(
    x = character(0),
    y = character(0),
    distance = integer(0),
    stringsAsFactors = FALSE
  )
  
  if (length(only_in_x) > 0 && length(uy) > 0 && max_dist > 0) {
    dist_mat <- utils::adist(only_in_x, uy)
    m_idx <- which(dist_mat <= max_dist, arr.ind = TRUE)
    if (nrow(m_idx) > 0) {
      fuzzy_matches <- data.frame(
        x = as.character(only_in_x[m_idx[, 1]]),
        y = as.character(uy[m_idx[, 2]]),
        distance = as.integer(dist_mat[m_idx]),
        stringsAsFactors = FALSE
      )
      fuzzy_matches <- unique(fuzzy_matches)
      fuzzy_matches <- fuzzy_matches[order(fuzzy_matches$distance, fuzzy_matches$x, fuzzy_matches$y), , drop = FALSE]
      rownames(fuzzy_matches) <- NULL
    }
  }
  
  total_x <- length(x)
  total_y <- length(y)
  unique_x <- length(ux)
  unique_y <- length(uy)
  exact_count <- length(exact_matches)
  fuzzy_count <- nrow(fuzzy_matches)
  only_x_count <- length(only_in_x)
  only_y_count <- length(only_in_y)
  match_rate <- if (unique_x > 0) exact_count / unique_x else 0
  
  stats <- list(
    total_x = total_x,
    total_y = total_y,
    unique_x = unique_x,
    unique_y = unique_y,
    exact_count = exact_count,
    fuzzy_count = fuzzy_count,
    only_x_count = only_x_count,
    only_y_count = only_y_count,
    na_x = na_x,
    na_y = na_y,
    match_rate = match_rate
  )
  
  list(
    exact_matches = exact_matches,
    fuzzy_matches = fuzzy_matches,
    only_in_x = only_in_x,
    only_in_y = only_in_y,
    stats = stats,
    match_stats = stats
  )
}

#' Generate tidyverse Code for Categorical Recoding and Discrepancy Crosswalks
#'
#' @param df_name Name of the data frame.
#' @param col Column name to recode.
#' @param crosswalk Mapping between source and target values. Can be:
#'   \itemize{
#'     \item A data.frame with source values in column 1 and target values in column 2.
#'     \item A named character vector (names = source values, values = target values).
#'     \item A named list where names are target values and elements are vectors of source values.
#'   }
#' @param default Fallback value for unmatched records. If NULL, omitted.
#'   If equal to `col`, emits unquoted column name `.default = <col>`.
#' @param method Recoding function: "case_when" (dplyr, the default), "case_match"
#'   (dplyr; deprecated in dplyr 1.2.0, kept for older pipelines) or "fct_recode" (forcats).
#' @param pipe Logical; if TRUE, uses pipe syntax `df %>% dplyr::mutate(...)`.
#' @return A character string of R code.
#' @export
sv_code_recode <- function(df_name, col, crosswalk, default = NULL, 
                           method = c("case_when", "case_match", "fct_recode"), pipe = FALSE) {
  method <- match.arg(method)
  
  from_vals <- character(0)
  to_vals <- character(0)
  
  if (is.data.frame(crosswalk)) {
    if (ncol(crosswalk) < 2) {
      stop("`crosswalk` data frame must have at least 2 columns.")
    }
    if (all(c("from", "to") %in% names(crosswalk))) {
      from_vals <- as.character(crosswalk$from)
      to_vals <- as.character(crosswalk$to)
    } else if (all(c("old", "new") %in% names(crosswalk))) {
      from_vals <- as.character(crosswalk$old)
      to_vals <- as.character(crosswalk$new)
    } else if (all(c("x", "y") %in% names(crosswalk))) {
      from_vals <- as.character(crosswalk$x)
      to_vals <- as.character(crosswalk$y)
    } else {
      from_vals <- as.character(crosswalk[[1]])
      to_vals <- as.character(crosswalk[[2]])
    }
  } else if (is.list(crosswalk) && !is.null(names(crosswalk)) && !is.character(crosswalk)) {
    for (nm in names(crosswalk)) {
      srcs <- as.character(crosswalk[[nm]])
      from_vals <- c(from_vals, srcs)
      to_vals <- c(to_vals, rep(nm, length(srcs)))
    }
  } else if (is.character(crosswalk)) {
    if (is.null(names(crosswalk))) {
      stop("`crosswalk` vector must be named (e.g. c('old_val' = 'new_val')).")
    }
    from_vals <- names(crosswalk)
    to_vals <- unname(crosswalk)
  } else {
    stop("`crosswalk` must be a data frame, named list, or named character vector.")
  }
  
  esc_col <- sv_escape_ident(col)
  
  default_rep <- NULL
  if (!is.null(default)) {
    default_rep <- if (length(default) == 1 && is.na(default)) {
      "NA"
    } else if (identical(default, col) || identical(default, esc_col)) {
      esc_col
    } else if (is.character(default)) {
      deparse1(default)
    } else {
      as.character(default)
    }
  }
  format_src <- function(s) if (is.na(s)) "NA" else deparse1(s)

  if (method == "case_when") {
    case_lines <- character(0)
    for (tgt in unique(to_vals)) {
      srcs <- if (is.na(tgt)) from_vals[is.na(to_vals)] else from_vals[!is.na(to_vals) & to_vals == tgt]
      tgt_rep <- if (is.na(tgt)) "NA" else deparse1(tgt)
      conds <- character(0)
      if (any(is.na(srcs))) conds <- c(conds, sprintf("is.na(%s)", esc_col))
      vals <- srcs[!is.na(srcs)]
      if (length(vals) == 1) {
        conds <- c(conds, sprintf("%s == %s", esc_col, deparse1(vals)))
      } else if (length(vals) > 1) {
        conds <- c(conds, sprintf("%s %%in%% c(%s)", esc_col,
                                  paste(vapply(vals, deparse1, character(1)), collapse = ", ")))
      }
      if (length(conds)) {
        case_lines <- c(case_lines, sprintf("%s ~ %s", paste(conds, collapse = " | "), tgt_rep))
      }
    }
    if (!is.null(default_rep)) case_lines <- c(case_lines, sprintf(".default = %s", default_rep))
    expr <- sprintf("dplyr::case_when(\n    %s\n  )", paste(case_lines, collapse = ",\n    "))
  } else if (method == "case_match") {
    unique_targets <- unique(to_vals)
    case_lines <- character(0)
    for (tgt in unique_targets) {
      if (is.na(tgt)) {
        srcs <- from_vals[is.na(to_vals)]
        tgt_rep <- "NA"
      } else {
        srcs <- from_vals[!is.na(to_vals) & to_vals == tgt]
        tgt_rep <- deparse1(tgt)
      }
      
      if (length(srcs) == 1) {
        case_lines <- c(case_lines, sprintf("%s ~ %s", format_src(srcs), tgt_rep))
      } else {
        srcs_str <- paste(vapply(srcs, format_src, character(1)), collapse = ", ")
        case_lines <- c(case_lines, sprintf("c(%s) ~ %s", srcs_str, tgt_rep))
      }
    }
    
    if (!is.null(default_rep)) case_lines <- c(case_lines, sprintf(".default = %s", default_rep))
    
    inner <- paste(c(esc_col, case_lines), collapse = ",\n    ")
    expr <- sprintf("dplyr::case_match(\n    %s\n  )", inner)
  } else {
    fct_lines <- sprintf("%s = %s", vapply(to_vals, deparse1, character(1)), vapply(from_vals, deparse1, character(1)))
    inner <- paste(c(esc_col, fct_lines), collapse = ",\n    ")
    expr <- sprintf("forcats::fct_recode(\n    %s\n  )", inner)
  }
  
  sv_code_mutate(df_name = df_name, new_col = col, expr = expr, pipe = pipe)
}


#' Generate tidyverse Code for Reshaping Data from Wide to Long
#'
#' Constructs syntactically valid \code{tidyr::pivot_longer()} calls with proper
#' identifier escaping and support for both piped workflows and direct calls.
#'
#' @param df_name Name of the data frame (optional; can be NULL for piped workflows).
#' @param cols Character vector of column name(s) to pivot into longer format.
#' @param names_to Character string specifying the name of the column to create from the data stored in the column names of \code{cols}. Defaults to \code{"name"}.
#' @param values_to Character string specifying the name of the column to create from the data stored in cell values. Defaults to \code{"value"}.
#' @param pipe Logical; if TRUE, uses pipe syntax `df %>% tidyr::pivot_longer(...)`. Defaults to `FALSE`.
#' @return A character string of R code.
#' @export
sv_code_pivot_longer <- function(df_name = NULL, cols, names_to = "name", values_to = "value", pipe = FALSE) {
  if (missing(cols) || is.null(cols) || length(cols) == 0) {
    stop("`cols` must not be empty.")
  }
  if (anyNA(cols) || any(!nzchar(as.character(cols)))) {
    stop("`cols` must not contain NA or empty strings.")
  }
  if (!is.null(df_name) && length(df_name) > 1) {
    stop("`df_name` must be a single character string or NULL.")
  }
  if (is.null(names_to) || length(names_to) == 0 || anyNA(names_to) || any(!nzchar(as.character(names_to)))) {
    stop("`names_to` must not be empty or contain NA.")
  }
  if (is.null(values_to) || length(values_to) == 0 || anyNA(values_to) || any(!nzchar(as.character(values_to)))) {
    stop("`values_to` must not be empty or contain NA.")
  }

  esc_cols <- sv_escape_ident(cols)
  cols_arg <- if (length(esc_cols) == 1) {
    sprintf("cols = %s", esc_cols)
  } else {
    sprintf("cols = c(%s)", paste(esc_cols, collapse = ", "))
  }

  names_to_arg <- if (length(names_to) == 1) {
    sprintf("names_to = %s", deparse1(names_to))
  } else {
    sprintf("names_to = c(%s)", paste(vapply(names_to, deparse1, character(1)), collapse = ", "))
  }

  values_to_arg <- if (length(values_to) == 1) {
    sprintf("values_to = %s", deparse1(values_to))
  } else {
    sprintf("values_to = c(%s)", paste(vapply(values_to, deparse1, character(1)), collapse = ", "))
  }

  args <- paste(c(cols_arg, names_to_arg, values_to_arg), collapse = ", ")

  has_df <- !is.null(df_name) && length(df_name) == 1 && !is.na(df_name) && nzchar(df_name)
  esc_df <- if (has_df) sv_escape_ident(df_name) else NULL

  if (pipe) {
    if (!is.null(esc_df)) {
      sprintf("%s %%>%% tidyr::pivot_longer(%s)", esc_df, args)
    } else {
      sprintf("tidyr::pivot_longer(%s)", args)
    }
  } else {
    if (!is.null(esc_df)) {
      sprintf("tidyr::pivot_longer(%s, %s)", esc_df, args)
    } else {
      sprintf("tidyr::pivot_longer(%s)", args)
    }
  }
}

#' Generate tidyverse Code for Reshaping Data from Long to Wide
#'
#' Constructs syntactically valid \code{tidyr::pivot_wider()} calls with proper
#' identifier escaping and optional aggregation functions.
#'
#' @param df_name Name of the data frame (optional; can be NULL for piped workflows).
#' @param names_from Character vector of column name(s) to get the name of the output column from.
#' @param values_from Character vector of column name(s) to get the cell values from.
#' @param values_fn Optional function name (character string or named vector/list) to apply to values. Defaults to \code{NULL}.
#' @param pipe Logical; if TRUE, uses pipe syntax `df %>% tidyr::pivot_wider(...)`. Defaults to `FALSE`.
#' @return A character string of R code.
#' @export
sv_code_pivot_wider <- function(df_name = NULL, names_from, values_from, values_fn = NULL, pipe = FALSE) {
  if (missing(names_from) || is.null(names_from) || length(names_from) == 0) {
    stop("`names_from` must not be empty.")
  }
  if (anyNA(names_from) || any(!nzchar(as.character(names_from)))) {
    stop("`names_from` must not contain NA or empty strings.")
  }
  if (missing(values_from) || is.null(values_from) || length(values_from) == 0) {
    stop("`values_from` must not be empty.")
  }
  if (anyNA(values_from) || any(!nzchar(as.character(values_from)))) {
    stop("`values_from` must not contain NA or empty strings.")
  }
  if (!is.null(df_name) && length(df_name) > 1) {
    stop("`df_name` must be a single character string or NULL.")
  }
  if (!is.null(values_fn)) {
    if (is.character(values_fn) && length(values_fn) > 1 && is.null(names(values_fn))) {
      stop("`values_fn` with multiple functions must be a named vector or list.")
    }
    if (!is.null(names(values_fn)) && any(!nzchar(names(values_fn)))) {
      stop("All elements in `values_fn` must be named.")
    }
  }

  esc_names <- sv_escape_ident(names_from)
  names_arg <- if (length(esc_names) == 1) {
    sprintf("names_from = %s", esc_names)
  } else {
    sprintf("names_from = c(%s)", paste(esc_names, collapse = ", "))
  }

  esc_values <- sv_escape_ident(values_from)
  values_arg <- if (length(esc_values) == 1) {
    sprintf("values_from = %s", esc_values)
  } else {
    sprintf("values_from = c(%s)", paste(esc_values, collapse = ", "))
  }

  call_args <- c(names_arg, values_arg)

  if (!is.null(values_fn) && length(values_fn) > 0) {
    if (is.character(values_fn)) {
      if (length(values_fn) == 1 && (is.null(names(values_fn)) || names(values_fn) == "")) {
        if (nzchar(values_fn)) {
          call_args <- c(call_args, sprintf("values_fn = %s", values_fn))
        }
      } else if (!is.null(names(values_fn))) {
        pairs <- sprintf("%s = %s", sv_escape_ident(names(values_fn)), unname(values_fn))
        call_args <- c(call_args, sprintf("values_fn = list(%s)", paste(pairs, collapse = ", ")))
      }
    } else if (is.list(values_fn) && !is.null(names(values_fn))) {
      pairs <- sprintf("%s = %s", sv_escape_ident(names(values_fn)), unlist(values_fn))
      call_args <- c(call_args, sprintf("values_fn = list(%s)", paste(pairs, collapse = ", ")))
    }
  }

  args <- paste(call_args, collapse = ", ")

  has_df <- !is.null(df_name) && length(df_name) == 1 && !is.na(df_name) && nzchar(df_name)
  esc_df <- if (has_df) sv_escape_ident(df_name) else NULL

  if (pipe) {
    if (!is.null(esc_df)) {
      sprintf("%s %%>%% tidyr::pivot_wider(%s)", esc_df, args)
    } else {
      sprintf("tidyr::pivot_wider(%s)", args)
    }
  } else {
    if (!is.null(esc_df)) {
      sprintf("tidyr::pivot_wider(%s, %s)", esc_df, args)
    } else {
      sprintf("tidyr::pivot_wider(%s)", args)
    }
  }
}

#' Generate tidyverse Code for Grouping and Aggregating Data
#'
#' Constructs syntactically valid \code{dplyr::group_by()} and \code{dplyr::summarise()}
#' pipelines with identifier escaping, customizable summary metrics, and reproducible
#' grouping behavior via \code{.groups = 'drop'}.
#'
#' @param df_name Name of the data frame (optional; can be NULL for intermediate piped pipeline segments).
#' @param group_cols Character vector of grouping column name(s).
#' @param summary_exprs Named character vector or named list of aggregation expressions
#'   (e.g., \code{c(total = "dplyr::n()", avg = "mean(val, na.rm = TRUE)")}).
#' @param pipe Logical; if TRUE, uses pipe syntax `df %>% dplyr::group_by(...) %>% dplyr::summarise(...)`. Defaults to `FALSE`.
#' @return A character string of R code.
#' @export
sv_code_group_summarize <- function(df_name = NULL, group_cols, summary_exprs, pipe = FALSE) {
  if (missing(group_cols) || is.null(group_cols) || length(group_cols) == 0) {
    stop("`group_cols` must not be empty.")
  }
  if (anyNA(group_cols) || any(!nzchar(as.character(group_cols)))) {
    stop("`group_cols` must not contain NA or empty strings.")
  }
  if (missing(summary_exprs) || is.null(summary_exprs) || length(summary_exprs) == 0) {
    stop("`summary_exprs` must not be empty.")
  }
  if (!is.character(summary_exprs) && !is.list(summary_exprs)) {
    stop("`summary_exprs` must be a named character vector or named list.")
  }
  nms <- names(summary_exprs)
  if (is.null(nms) || any(is.na(nms)) || any(!nzchar(nms))) {
    stop("All elements in `summary_exprs` must be named.")
  }
  vals <- as.character(unlist(summary_exprs))
  if (anyNA(vals) || any(!nzchar(vals))) {
    stop("`summary_exprs` values must not be empty or NA.")
  }
  if (!is.null(df_name) && length(df_name) > 1) {
    stop("`df_name` must be a single character string or NULL.")
  }

  esc_groups <- sv_escape_ident(group_cols)
  group_str <- paste(esc_groups, collapse = ", ")

  expr_pairs <- character(0)
  for (nm in names(summary_exprs)) {
    expr_pairs <- c(expr_pairs, sprintf("%s = %s", sv_escape_ident(nm), as.character(summary_exprs[[nm]])))
  }
  summary_str <- paste(expr_pairs, collapse = ",\n    ")

  has_df <- !is.null(df_name) && length(df_name) == 1 && !is.na(df_name) && nzchar(df_name)
  esc_df <- if (has_df) sv_escape_ident(df_name) else NULL

  if (pipe) {
    if (!is.null(esc_df)) {
      sprintf("%s %%>%%\n  dplyr::group_by(%s) %%>%%\n  dplyr::summarise(\n    %s,\n    .groups = 'drop'\n  )",
              esc_df, group_str, summary_str)
    } else {
      sprintf("dplyr::group_by(%s) %%>%%\n  dplyr::summarise(\n    %s,\n    .groups = 'drop'\n  )",
              group_str, summary_str)
    }
  } else {
    if (!is.null(esc_df)) {
      sprintf("dplyr::summarise(\n  dplyr::group_by(%s, %s),\n  %s,\n  .groups = 'drop'\n)",
              esc_df, group_str, summary_str)
    } else {
      sprintf("dplyr::summarise(\n  dplyr::group_by(%s),\n  %s,\n  .groups = 'drop'\n)",
              group_str, summary_str)
    }
  }
}


#' Generate tidyverse Code for Automatic Discrepancy Cleaning and Crosswalks
#'
#' Inspects discrepancy detection output or pairwise column discrepancies (exact matches,
#' fuzzy near-matches, and missing levels), automatically synthesizing clean recoding rules
#' using \code{dplyr::case_when()}. Handles casing differences, leading/trailing whitespace
#' discrepancies, and fuzzy string distance variations (Levenshtein distance <= 2).
#'
#' @param discrepancy_result A discrepancy result list (such as returned by \code{sv_detect_discrepancies()})
#'   or an object containing \code{fuzzy_matches}, \code{only_in_x}, \code{only_in_y}, and \code{exact_matches}.
#' @param df_name Name of the data frame to mutate. Defaults to \code{"df"}. Can be \code{NULL} for
#'   piped or standalone expressions.
#' @param col Column name being recoded. Defaults to \code{"status"}. If \code{NULL}, attempts
#'   to extract from \code{discrepancy_result$from_col} or defaults to \code{"status"}.
#' @param default Fallback value for unmatched records. If equal to \code{col}, preserves unmatched
#'   records via \code{.default = <col>}. Set to \code{NULL} to omit the default clause.
#' @param pipe Logical; if TRUE, emits piped syntax \code{df \%>\% dplyr::mutate(...)}.
#'
#' @return A character string of tidyverse code, or \code{NULL} if no discrepancies require cleaning.
#' @export
#' @examples
#' disc <- sv_detect_discrepancies(c("male", "Female"), c("Male", "Female"))
#' sv_auto_clean_rules(disc, df_name = "patients", col = "gender")
sv_auto_clean_rules <- function(discrepancy_result, df_name = "df", col = "status",
                                default = col, pipe = FALSE) {
  if (is.null(discrepancy_result) || !is.list(discrepancy_result) || length(discrepancy_result) == 0) {
    return(NULL)
  }

  target_col <- if (is.null(col) || !nzchar(as.character(col)[1])) {
    discrepancy_result$from_col %||% discrepancy_result$col %||% discrepancy_result$col1 %||% "status"
  } else {
    as.character(col)[1]
  }

  target_default <- if (identical(default, col)) target_col else default

  only_x <- as.character(discrepancy_result$only_in_x %||% character(0))
  only_y <- as.character(discrepancy_result$only_in_y %||% character(0))
  exact <- as.character(discrepancy_result$exact_matches %||% character(0))

  y_pool <- unique(c(exact, only_y))

  fuzzy_df <- discrepancy_result$fuzzy_matches
  if (!is.null(fuzzy_df) && is.data.frame(fuzzy_df) && nrow(fuzzy_df) > 0) {
    if (all(c("x", "y") %in% names(fuzzy_df))) {
      y_pool <- unique(c(y_pool, as.character(fuzzy_df$y)))
    }
  }

  y_pool <- y_pool[!is.na(y_pool) & nzchar(y_pool)]
  if (length(y_pool) == 0) {
    return(NULL)
  }

  mappings <- list()

  # 1. Fuzzy matches from discrepancy result
  if (!is.null(fuzzy_df) && is.data.frame(fuzzy_df) && nrow(fuzzy_df) > 0) {
    for (i in seq_len(nrow(fuzzy_df))) {
      fx <- as.character(fuzzy_df$x[i])
      fy <- as.character(fuzzy_df$y[i])
      fdist <- if ("distance" %in% names(fuzzy_df)) as.numeric(fuzzy_df$distance[i]) else 1
      if (!is.na(fx) && !is.na(fy) && nzchar(fx) && nzchar(fy) && fx != fy && fdist <= 2) {
        if (is.null(mappings[[fx]]) || fdist < mappings[[fx]]$score) {
          mappings[[fx]] <- list(target = fy, score = fdist)
        }
      }
    }
  }

  # 2. Inspect only_in_x for whitespace, casing, and edit-distance matches
  for (src in only_x) {
    if (is.na(src) || !nzchar(src)) next

    trim_src <- trimws(src)
    for (tgt in y_pool) {
      if (src != tgt && trim_src == tgt) {
        if (is.null(mappings[[src]]) || 0.05 < mappings[[src]]$score) {
          mappings[[src]] <- list(target = tgt, score = 0.05)
        }
      }
    }

    lower_src <- tolower(trim_src)
    for (tgt in y_pool) {
      if (src != tgt && lower_src == tolower(trimws(tgt))) {
        if (is.null(mappings[[src]]) || 0.1 < mappings[[src]]$score) {
          mappings[[src]] <- list(target = tgt, score = 0.1)
        }
      }
    }

    if (is.null(mappings[[src]])) {
      dists <- as.integer(utils::adist(src, y_pool)[1, ])
      best_idx <- which(dists <= 2L)
      if (length(best_idx) > 0) {
        min_idx <- best_idx[which.min(dists[best_idx])]
        best_tgt <- y_pool[min_idx]
        best_dist <- dists[min_idx]
        if (src != best_tgt) {
          mappings[[src]] <- list(target = best_tgt, score = best_dist)
        }
      }
    }
  }

  if (length(mappings) == 0) {
    return(NULL)
  }

  from_vals <- names(mappings)
  to_vals <- vapply(mappings, function(m) m$target, character(1))

  valid_idx <- which(from_vals != to_vals)
  if (length(valid_idx) == 0) {
    return(NULL)
  }

  from_vals <- from_vals[valid_idx]
  to_vals <- to_vals[valid_idx]

  crosswalk <- data.frame(
    from = from_vals,
    to = to_vals,
    stringsAsFactors = FALSE
  )

  sv_code_recode(
    df_name = df_name,
    col = target_col,
    crosswalk = crosswalk,
    default = target_default,
    method = "case_when",
    pipe = pipe
  )
}

#' @rdname sv_auto_clean_rules
#' @export
sv_code_auto_clean <- sv_auto_clean_rules
