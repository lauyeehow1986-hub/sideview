# CDISC join keys: which pairs of tagged tables join on which key columns.
# Reads each card's tag and column names only; lazy cards are never collected.

#' CDISC join keys
#'
#' Suggests how tagged CDISC tables join: ADaM records trace back to their SDTM
#' records by `STUDYID`, `USUBJID` and `<DOMAIN>SEQ`; subject-level tables join
#' to the demographics hub (DM, or ADSL for ADaM tables) by `STUDYID` and
#' `USUBJID`; visit-level tables join to SV by the subject key and `VISITNUM`.
#' Column names match whatever their case; each side keeps its own spelling.
#' Only tags and column names are read, so Arrow and duckdb tables are not
#' collected.
#'
#' @param cards A list of `sideview_card` objects whose CDISC tags are final
#'   (the cards a canvas holds).
#' @return A data frame with one row per suggested pair and the columns
#'   `from_table` and `to_table` (card names, left and right), `from_cols` and
#'   `to_cols` (list columns of character vectors, paired by position),
#'   `kind` (`"trace"`, `"subject"` or `"visit"`) and `reason`. It has zero rows
#'   when fewer than two cards can take part.
#' @examples
#' dm <- data.frame(STUDYID = "S1", DOMAIN = "DM", USUBJID = c("S1-1", "S1-2"),
#'                  SUBJID = c("1", "2"), AGE = c(40, 50), SEX = c("F", "M"))
#' ae <- data.frame(STUDYID = "S1", DOMAIN = "AE", USUBJID = c("S1-1", "S1-2"),
#'                  AESEQ = 1:2, AETERM = c("Headache", "Rash"),
#'                  AEDECOD = c("HEADACHE", "RASH"))
#' cards <- sv_normalize_cards(list(dm = dm, ae = ae))
#' cards <- sv_cdisc_finalize(cards)
#' sv_cdisc_join_keys(cards)
#' @export
sv_cdisc_join_keys <- function(cards) {
  empty <- sv_keys_frame(list())
  if (!length(cards)) return(empty)
  cards <- cards[vapply(cards, sv_keys_eligible, logical(1))]
  if (length(cards) < 2L) return(empty)
  rows <- list()
  for (i in seq_len(length(cards) - 1L)) {
    for (j in (i + 1L):length(cards)) {
      r <- sv_keys_pair_rule(cards[[i]], cards[[j]], cards = cards)
      if (is.null(r)) r <- sv_keys_pair_rule(cards[[j]], cards[[i]], cards = cards)
      if (!is.null(r)) rows[[length(rows) + 1L]] <- r
    }
  }
  sv_keys_frame(rows)
}

sv_keys_frame <- function(rows) {
  chr <- function(f) vapply(rows, function(r) r[[f]], character(1))
  out <- data.frame(from_table = chr("left"), to_table = chr("right"),
                    kind = chr("kind"), reason = chr("reason"), stringsAsFactors = FALSE)
  out$from_cols <- lapply(rows, function(r) r$from_cols)
  out$to_cols <- lapply(rows, function(r) r$to_cols)
  out[, c("from_table", "to_table", "from_cols", "to_cols", "kind", "reason"), drop = FALSE]
}

# The real column names of a card's table (the source for a lazy card).
sv_keys_colnames <- function(card) {
  src <- if (!is.null(card$source)) card$source else card$data
  tryCatch({
    if (is.data.frame(src)) names(src) else if (sv_is_lazy_input(src)) as.character(sv_lazy_names(src)) else character()
  }, error = function(e) character())
}

# The card's column spelled as the table spells it, or NA.
sv_keys_col <- function(card, col) {
  nm <- sv_keys_colnames(card)
  nm[match(toupper(col), toupper(nm))][1L]
}

sv_keys_has <- function(card, col) !is.na(sv_keys_col(card, col))

# Tagged, not SUPP-- or RELREC, and has USUBJID.
sv_keys_eligible <- function(card) {
  t <- card$cdisc
  if (is.null(t) || is.null(t$domain)) return(FALSE)
  if (grepl("^SUPP", t$domain) || identical(t$domain, "RELREC") ||
      identical(t$class, "Relationship")) return(FALSE)
  sv_keys_has(card, "USUBJID")
}

sv_keys_is_adam <- function(card) identical(card$cdisc$standard, "ADaM")
sv_keys_is_adsl <- function(card) sv_keys_is_adam(card) && identical(card$cdisc$class, "ADSL")
sv_keys_is_dm <- function(card) !sv_keys_is_adam(card) && identical(card$cdisc$domain, "DM")
sv_keys_is_hub <- function(card) sv_keys_is_adsl(card) || sv_keys_is_dm(card)

# The id of the hub a non-hub card links to: ADSL for ADaM and DM otherwise,
# the other kind when the preferred one is not on the canvas. NULL if none.
sv_keys_hub_id <- function(card, cards) {
  hubs <- cards[vapply(cards, function(c) sv_keys_eligible(c) && sv_keys_is_hub(c), logical(1))]
  adsl <- Filter(sv_keys_is_adsl, hubs)
  dm <- Filter(sv_keys_is_dm, hubs)
  pref <- if (sv_keys_is_adam(card)) c(adsl, dm) else c(dm, adsl)
  if (length(pref)) pref[[1L]]$id else NULL
}

# The subject key columns of a pair, and a note on which was used.
sv_keys_subject <- function(cx, cy) {
  both <- sv_keys_has(cx, "STUDYID") && sv_keys_has(cy, "STUDYID")
  base <- if (both) c("STUDYID", "USUBJID") else "USUBJID"
  note <- ""
  if (!both) {
    lacking <- c(if (!sv_keys_has(cx, "STUDYID")) cx$name,
                 if (!sv_keys_has(cy, "STUDYID")) cy$name)
    note <- sprintf(" (no STUDYID in %s: USUBJID alone)", paste(lacking, collapse = ", "))
  }
  list(base = base, note = note)
}

sv_keys_rule <- function(cx, cy, base, extra, kind, reason) {
  list(left = cx$name, right = cy$name,
       from_cols = vapply(c(base, extra), function(k) sv_keys_col(cx, k), character(1), USE.NAMES = FALSE),
       to_cols = vapply(c(base, extra), function(k) sv_keys_col(cy, k), character(1), USE.NAMES = FALSE),
       kind = kind, reason = reason)
}

# The single suggestion for the ordered pair (cx on the left, cy on the right),
# or NULL. `cards` is the canvas, for the hub choice; by default the pair alone.
sv_keys_pair_rule <- function(cx, cy, cards = list(cx, cy)) {
  if (!sv_keys_eligible(cx) || !sv_keys_eligible(cy)) return(NULL)
  if (identical(cx$id, cy$id)) return(NULL)
  subj <- sv_keys_subject(cx, cy)
  dom_y <- cy$cdisc$domain

  # 1. trace: an ADaM table (not ADSL) to the SDTM/SEND domain it came from
  if (sv_keys_is_adam(cx) && !sv_keys_is_adsl(cx) && !sv_keys_is_adam(cy)) {
    seq_col <- paste0(dom_y, "SEQ")
    if (sv_keys_has(cx, seq_col) && sv_keys_has(cy, seq_col)) {
      return(sv_keys_rule(cx, cy, subj$base, seq_col, "trace",
        sprintf("CDISC trace key: %s records come from %s (%s)%s", cx$name, dom_y, seq_col, subj$note)))
    }
  }

  # 2. subject level: to the hub
  if (sv_keys_is_hub(cy)) {
    ok <- if (sv_keys_is_hub(cx)) {
      sv_keys_is_adsl(cx) && sv_keys_is_dm(cy)
    } else {
      identical(sv_keys_hub_id(cx, cards), cy$id)
    }
    if (ok) {
      hub <- if (sv_keys_is_adsl(cy)) "ADSL" else "DM"
      return(sv_keys_rule(cx, cy, subj$base, character(), "subject",
        sprintf("CDISC subject key: %s has one row per subject%s", hub, subj$note)))
    }
  }

  # 3. visit level: to SV
  if (identical(dom_y, "SV") && !sv_keys_is_adam(cy) && !identical(cx$cdisc$domain, "SV") &&
      sv_keys_has(cx, "VISITNUM") && sv_keys_has(cy, "VISITNUM")) {
    return(sv_keys_rule(cx, cy, subj$base, "VISITNUM", "visit",
      sprintf("CDISC visit key: SV has one row per subject and visit%s", subj$note)))
  }
  NULL
}
