#' Suggest Foreign Key Mappings Across Canvas Cards
#'
#' Evaluates pairwise heuristic column relationships across loaded `sideview_card`
#' objects or tabular data structures, computing a 3-part composite confidence score based
#' on name similarity (40%), data type compatibility (20%), and Jaccard value overlap (40%).
#'
#' @param cards A list of `sideview_card` objects or tabular data frames. Alternatively,
#'   individual cards or tables can be passed via `...`.
#' @param ... Additional cards or tables passed as positional arguments.
#' @param min_confidence Minimum confidence threshold (numeric between 0 and 1) for
#'   returned suggestions (default `0.6`).
#' @param cdisc `"auto"` (default) or anything but `FALSE` to suggest the CDISC
#'   join keys (see [sv_cdisc_join_keys()]) for pairs of tagged tables; `FALSE`
#'   keeps the heuristic suggestions only. Rule rows have confidence 1, come
#'   first and are never filtered by `min_confidence`. A pair of CDISC tables
#'   that can take part (tagged, with `USUBJID`) but has no rule gets no
#'   heuristic rows either.
#'
#' @return A `data.frame` with columns:
#'   \describe{
#'     \item{`from_table`}{Source table or card name.}
#'     \item{`from_col`}{Source column name.}
#'     \item{`to_table`}{Destination table or card name.}
#'     \item{`to_col`}{Destination column name.}
#'     \item{`confidence`}{Composite confidence score in `[0, 1]`.}
#'     \item{`reason`}{Human-readable justification describing similarity components.}
#'     \item{`group`}{`NA` for heuristic rows; `"cdisc:<from>~<to>"` for the rows of
#'       one CDISC key (the columns of one join).}
#'     \item{`kind`}{`NA` for heuristic rows; `"trace"`, `"subject"` or `"visit"`.}
#'   }
#' @export
#' @examples
#' df1 <- data.frame(patient_id = 1:5, age = c(20, 30, 40, 50, 60))
#' df2 <- data.frame(patient_id = 3:7, score = c(10, 20, 30, 40, 50))
#' sv_suggest_mappings(list(patients = df1, visits = df2))
sv_suggest_mappings <- function(cards, ..., min_confidence = 0.6, cdisc = "auto") {
  if (is.null(cards)) {
    return(.empty_mappings_result())
  }

  dots <- list(...)
  card_list <- if (inherits(cards, "sideview_card") || is.data.frame(cards)) {
    list(cards)
  } else if (is.list(cards)) {
    cards
  } else {
    return(.empty_mappings_result())
  }

  if (length(dots) > 0L) {
    card_list <- c(card_list, dots)
  }

  if (length(card_list) < 2L) {
    return(.empty_mappings_result())
  }

  # Normalize and filter cards with tabular data
  valid_cards <- list()
  for (i in seq_along(card_list)) {
    item <- card_list[[i]]
    if (is.null(item)) next

    nm <- names(card_list)[i]
    default_name <- if (!is.null(nm) && nzchar(trimws(nm))) {
      trimws(nm)
    } else {
      paste0("Table", i)
    }

    card_obj <- if (inherits(item, "sideview_card")) {
      if (!is.null(nm) && nzchar(trimws(nm)) &&
          (!nzchar(item$name) || item$name %in% c("Table", "Data"))) {
        item$name <- trimws(nm)
      }
      item
    } else if (is.data.frame(item)) {
      sv_normalize(item, name = default_name)
    } else {
      tryCatch(sv_normalize(item, name = default_name), error = function(e) NULL)
    }

    if (is.null(card_obj)) next

    # Must be a grid card with non-empty data frame
    if (!is.null(card_obj$data) && is.data.frame(card_obj$data) &&
        nrow(card_obj$data) > 0L && ncol(card_obj$data) > 0L) {
      valid_cards[[length(valid_cards) + 1L]] <- card_obj
    }
  }

  if (length(valid_cards) < 2L) {
    return(.empty_mappings_result())
  }

  min_conf <- if (is.null(min_confidence) || is.na(min_confidence) || min_confidence < 0) {
    0.0
  } else {
    as.numeric(min_confidence)
  }

  candidates <- list()
  n_cards <- length(valid_cards)

  # CDISC rule rows: one row per key pair, confidence 1, listed first.
  rule_rows <- NULL
  skip_pair <- matrix(FALSE, n_cards, n_cards)
  if (!identical(cdisc, FALSE)) {
    keys <- sv_cdisc_join_keys(valid_cards)
    card_names <- vapply(valid_cards, function(cd) cd$name, character(1))
    eligible <- vapply(valid_cards, sv_keys_eligible, logical(1))
    for (i in seq_len(n_cards - 1L)) {
      for (j in seq.int(i + 1L, n_cards)) {
        if (eligible[i] && eligible[j]) skip_pair[i, j] <- TRUE
      }
    }
    rule_rows <- lapply(seq_len(nrow(keys)), function(r) {
      fc <- keys$from_cols[[r]]
      tc <- keys$to_cols[[r]]
      data.frame(
        from_table = keys$from_table[r], from_col = fc,
        to_table = keys$to_table[r], to_col = tc,
        confidence = 1, reason = keys$reason[r],
        group = paste0("cdisc:", keys$from_table[r], "~", keys$to_table[r]),
        kind = keys$kind[r], stringsAsFactors = FALSE
      )
    })
    rule_rows <- if (length(rule_rows)) do.call(rbind, rule_rows) else NULL
  }

  # Precompute unique sets and column metadata once per table
  # Sampling up to 10,000 rows if nrow > 10,000
  table_cols <- vector("list", n_cards)
  for (k in seq_len(n_cards)) {
    df_k <- valid_cards[[k]]$data
    nr <- nrow(df_k)
    sample_rows <- if (nr > 10000L) sample.int(nr, 10000L) else NULL

    col_data <- vector("list", ncol(df_k))
    names(col_data) <- names(df_k)

    for (col_name in names(df_k)) {
      raw_vec <- df_k[[col_name]]
      is_log <- is.logical(raw_vec)

      u_vals <- if (is_log || !is.atomic(raw_vec)) {
        character(0)
      } else {
        vec_sample <- if (!is.null(sample_rows)) raw_vec[sample_rows] else raw_vec
        clean <- vec_sample[!is.na(vec_sample)]
        if (length(clean) > 0L) unique(clean) else character(0)
      }

      col_data[[col_name]] <- list(
        raw = raw_vec,
        is_logical = is_log,
        unique = u_vals
      )
    }
    table_cols[[k]] <- col_data
  }

  # Pairwise iteration across loaded cards (c1, c2)
  for (i in seq_len(n_cards - 1L)) {
    for (j in seq.int(i + 1L, n_cards)) {
      if (skip_pair[i, j]) next
      c1 <- valid_cards[[i]]
      c2 <- valid_cards[[j]]

      cols1_info <- table_cols[[i]]
      cols2_info <- table_cols[[j]]

      for (col1 in names(cols1_info)) {
        info1 <- cols1_info[[col1]]
        if (info1$is_logical) next

        for (col2 in names(cols2_info)) {
          info2 <- cols2_info[[col2]]
          if (info2$is_logical) next

          pair_result <- .score_column_pair(
            col1 = col1,
            v1 = info1$raw,
            col2 = col2,
            v2 = info2$raw,
            u1 = info1$unique,
            u2 = info2$unique,
            min_confidence = min_conf
          )

          if (pair_result$confidence >= min_conf) {
            candidates[[length(candidates) + 1L]] <- list(
              from_table = c1$name,
              from_col = col1,
              to_table = c2$name,
              to_col = col2,
              confidence = pair_result$confidence,
              reason = pair_result$reason
            )
          }
        }
      }
    }
  }

  if (length(candidates) == 0L) {
    return(if (is.null(rule_rows)) .empty_mappings_result() else {
      rownames(rule_rows) <- NULL
      rule_rows
    })
  }

  res <- data.frame(
    from_table = vapply(candidates, `[[`, character(1), "from_table"),
    from_col = vapply(candidates, `[[`, character(1), "from_col"),
    to_table = vapply(candidates, `[[`, character(1), "to_table"),
    to_col = vapply(candidates, `[[`, character(1), "to_col"),
    confidence = vapply(candidates, `[[`, numeric(1), "confidence"),
    reason = vapply(candidates, `[[`, character(1), "reason"),
    stringsAsFactors = FALSE
  )

  # Sort by confidence descending, then by table and column names
  ord <- order(-res$confidence, res$from_table, res$to_table, res$from_col, res$to_col)
  res <- res[ord, , drop = FALSE]
  res$group <- NA_character_
  res$kind <- NA_character_
  if (!is.null(rule_rows)) res <- rbind(rule_rows, res)
  rownames(res) <- NULL
  res
}

#' Internal: Return 0-row data.frame with expected mapping schema
#' @noRd
.empty_mappings_result <- function() {
  data.frame(
    from_table = character(0),
    from_col = character(0),
    to_table = character(0),
    to_col = character(0),
    confidence = numeric(0),
    reason = character(0),
    group = character(0),
    kind = character(0),
    stringsAsFactors = FALSE
  )
}

#' Internal: Score a pair of columns based on name similarity, type compatibility, and Jaccard overlap
#' @noRd
.score_column_pair <- function(col1, v1, col2, v2, u1 = NULL, u2 = NULL, min_confidence = 0.0) {
  if (is.logical(v1) || is.logical(v2)) {
    return(list(
      confidence = 0.0,
      reason = "Logical/boolean columns excluded",
      name_sim = 0.0,
      type_compat = 0.0,
      jaccard = 0.0
    ))
  }

  name_res <- .compute_name_similarity(col1, col2)
  type_compat <- .compute_type_compatibility(v1, v2)

  # Early exit pruning: if theoretical max score is below min_confidence, skip set operations
  max_possible <- (0.40 * name_res$similarity) + (0.20 * type_compat) + 0.40
  if (max_possible < min_confidence) {
    return(list(
      confidence = 0.0,
      reason = "Pruned: maximum possible confidence below threshold",
      name_sim = name_res$similarity,
      type_compat = type_compat,
      jaccard = 0.0
    ))
  }

  jaccard <- .compute_jaccard_overlap(v1, v2, u1 = u1, u2 = u2)

  # Composite score = 0.40 * name_sim + 0.20 * type_compat + 0.40 * jaccard
  composite <- 0.40 * name_res$similarity + 0.20 * type_compat + 0.40 * jaccard
  confidence <- round(composite, 4)

  reason <- .build_mapping_reason(col1, col2, name_res, type_compat, jaccard)

  list(
    confidence = confidence,
    reason = reason,
    name_sim = name_res$similarity,
    type_compat = type_compat,
    jaccard = jaccard
  )
}

#' Internal: Compute Levenshtein distance on sanitized lowercase names with ID suffix bonus
#' @noRd
.compute_name_similarity <- function(col1, col2) {
  s1 <- tolower(trimws(as.character(col1)))
  s2 <- tolower(trimws(as.character(col2)))

  if (!nzchar(s1) || !nzchar(s2)) {
    return(list(similarity = 0.0, has_id_suffix = FALSE))
  }

  has_id1 <- grepl("(^|[_.-])id$", s1) || grepl("(^|[a-z])Id$", as.character(col1))
  has_id2 <- grepl("(^|[_.-])id$", s2) || grepl("(^|[a-z])Id$", as.character(col2))
  has_id_suffix <- has_id1 && has_id2

  if (identical(s1, s2)) {
    return(list(similarity = 1.0, has_id_suffix = has_id_suffix))
  }

  # Raw string Levenshtein distance
  dist_raw <- utils::adist(s1, s2)[1, 1]
  max_len_raw <- max(nchar(s1), nchar(s2))
  sim_raw <- if (max_len_raw == 0L) 1.0 else 1.0 - (dist_raw / max_len_raw)

  # Cleaned alphanumeric string similarity (handles patient_id vs patientId, patient.id, etc.)
  s1_clean <- gsub("[^a-z0-9]", "", s1)
  s2_clean <- gsub("[^a-z0-9]", "", s2)
  dist_clean <- utils::adist(s1_clean, s2_clean)[1, 1]
  max_len_clean <- max(nchar(s1_clean), nchar(s2_clean))
  sim_clean <- if (max_len_clean == 0L) 1.0 else 1.0 - (dist_clean / max_len_clean)

  base_sim <- max(sim_raw, sim_clean)

  bonus <- if (has_id_suffix) 0.20 else 0.0

  final_sim <- min(1.0, max(0.0, base_sim + bonus))
  list(similarity = final_sim, has_id_suffix = has_id_suffix)
}

#' Internal: Compute type compatibility score
#' @noRd
.compute_type_compatibility <- function(v1, v2) {
  if (!is.atomic(v1) || !is.atomic(v2)) {
    return(0.0)
  }

  c1 <- class(v1)[1]
  c2 <- class(v2)[1]

  if (identical(c1, c2)) {
    return(1.0)
  }

  num_types <- c("numeric", "integer", "double")
  if (c1 %in% num_types && c2 %in% num_types) {
    return(0.9)
  }

  char_types <- c("character", "factor")
  if (c1 %in% char_types && c2 %in% char_types) {
    return(0.9)
  }

  date_types <- c("Date", "POSIXct", "POSIXlt", "POSIXt")
  if (c1 %in% date_types && c2 %in% date_types) {
    return(0.9)
  }

  0.0
}

#' Internal: Compute Jaccard value overlap
#' @noRd
.compute_jaccard_overlap <- function(v1, v2, u1 = NULL, u2 = NULL) {
  if (is.null(u1)) {
    if (!is.atomic(v1)) {
      return(0.0)
    }
    clean1 <- v1[!is.na(v1)]
    if (length(clean1) == 0L) {
      return(0.0)
    }
    u1 <- unique(clean1)
  }

  if (is.null(u2)) {
    if (!is.atomic(v2)) {
      return(0.0)
    }
    clean2 <- v2[!is.na(v2)]
    if (length(clean2) == 0L) {
      return(0.0)
    }
    u2 <- unique(clean2)
  }

  if (length(u1) == 0L || length(u2) == 0L) {
    return(0.0)
  }

  intersection_len <- length(intersect(u1, u2))
  union_len <- length(union(u1, u2))

  if (union_len == 0L) {
    0.0
  } else {
    intersection_len / union_len
  }
}

#' Internal: Format reason string
#' @noRd
.build_mapping_reason <- function(col1, col2, name_res, type_compat, jaccard) {
  name_part <- if (tolower(col1) == tolower(col2)) {
    "Exact name match"
  } else if (name_res$similarity >= 0.70) {
    "High name similarity"
  } else if (name_res$similarity >= 0.40) {
    "Partial name match"
  } else {
    "Low name similarity"
  }

  if (name_res$has_id_suffix) {
    name_part <- paste0(name_part, " with ID suffix")
  }

  type_part <- if (type_compat >= 1.0) {
    "identical types"
  } else if (type_compat >= 0.9) {
    "compatible types"
  } else {
    "incompatible types"
  }

  overlap_part <- sprintf("%.0f%% value overlap", jaccard * 100)

  paste(name_part, type_part, overlap_part, sep = "; ")
}
