# The merge check for CDISC SUPP-- tables (SUPPAE, SUPPQUAL, ...): can the
# qualifier rows be folded into their parent as one column per QNAM?

#' Check a SUPP-- merge
#'
#' A supplemental qualifier table (`SUPPAE`, `SUPPQUAL`, ...) holds one row per
#' qualifier, named by `QNAM` and tied to a parent record by `USUBJID`, `IDVAR`
#' and `IDVARVAL`. This checks that the rows can be folded into the parent as
#' one column per `QNAM`, and reports what would go wrong: rows that match no
#' parent record, a `QNAM` that repeats for one record, a `QNAM` that clashes
#' with a parent column or sits at two `IDVAR` levels, and `IDVARVAL` values
#' that do not convert to the type of the parent column.
#'
#' `IDVARVAL` is text; it is converted to the type of the parent's `IDVAR`
#' column before matching (`"1.5"` does not become `1` for an integer column).
#' A blank or `NA` `IDVAR` means the qualifier belongs to the subject.
#'
#' @param parent The parent table: a data frame, or a sideview card (its data
#'   and CDISC tag are used).
#' @param supp The SUPP-- table: a data frame with `USUBJID`, `IDVAR`,
#'   `IDVARVAL`, `QNAM` and `QVAL` (and optionally `STUDYID`, `RDOMAIN`,
#'   `QLABEL`).
#' @param parent_name,supp_name Names used in messages.
#' @param rdomain The parent domain to merge into. `NULL` uses the parent
#'   card's CDISC domain, else `supp_name` without its `SUPP` prefix. Rows are
#'   filtered on `RDOMAIN` only when `supp` has that column.
#' @param plan A plan from an earlier check. The result's `drift` says whether
#'   the data still fits it.
#' @param sample_n Most rows in each sample.
#' @return A list with `status` (`"ok"`, `"warning"` or `"error"`), `plan`,
#'   `n_parent`, `n_supp`, `n_matched`, `n_orphan`, `orphan_samples`,
#'   `n_other_rdomain`, `repeats`, `clashes`, `two_level`, `bad_idvarval`,
#'   `columns`, `preview` and `drift`; or just `list(error = )` when the check
#'   cannot run.
#' @examples
#' ae <- data.frame(USUBJID = c("S1", "S2"), AESEQ = 1:2, AETERM = c("Rash", "Cough"))
#' suppae <- data.frame(RDOMAIN = "AE", USUBJID = c("S1", "S2"), IDVAR = "AESEQ",
#'                      IDVARVAL = c("1", "2"), QNAM = "AETRTEM",
#'                      QLABEL = "Treatment Emergent", QVAL = c("Y", "N"))
#' chk <- sv_supp_check(ae, suppae, parent_name = "ae", supp_name = "suppae")
#' chk$status
#' chk$preview
#' @export
sv_supp_check <- function(parent, supp, parent_name = "parent", supp_name = "supp",
                          rdomain = NULL, plan = NULL, sample_n = 5L) {
  card_domain <- NULL
  if (!is.data.frame(parent) && is.list(parent) && !is.null(parent$data)) {
    card_domain <- parent$cdisc$domain
    parent <- parent$data
  }
  if (!is.data.frame(supp) && is.list(supp) && !is.null(supp$data)) supp <- supp$data
  from_name <- sub("^SUPP", "", toupper(supp_name))
  if (is.null(rdomain)) {
    rdomain <- if (is.character(card_domain) && length(card_domain) == 1L && !is.na(card_domain) &&
                   nzchar(card_domain)) card_domain else from_name
  }
  sv_supp_check_df(as.data.frame(parent, stringsAsFactors = FALSE),
                   as.data.frame(supp, stringsAsFactors = FALSE),
                   parent_name, supp_name, rdomain, plan, as.integer(sample_n),
                   from_name == rdomain)
}

#' @rdname sv_supp_check
#' @param x A vector.
#' @param chk A result of `sv_supp_check()`.
#' @return `sv_supp_key_type()`: `"integer"`, `"double"`, `"character"` or `NA`
#'   (a factor counts as character, an integer64 as double).
#'   `sv_supp_check_json()`: the check as JSON text, one-element arrays kept as
#'   arrays and `NA` as `null`.
#' @export
sv_supp_key_type <- function(x) {
  if (inherits(x, "integer64")) return("double")
  if (is.factor(x) || is.character(x)) return("character")
  if (is.integer(x) && is.null(attr(x, "class"))) return("integer")
  if (is.double(x) && is.null(attr(x, "class"))) return("double")
  NA_character_
}

# Convert IDVARVAL text to the key type; NA means it did not convert.
sv_supp_convert <- function(v, type) {
  v <- as.character(v)
  if (identical(type, "character")) return(v)
  if (identical(type, "integer")) {
    ok <- grepl("^\\s*[+-]?[0-9]+\\s*$", v)
    out <- rep(NA_character_, length(v))
    num <- suppressWarnings(as.integer(ifelse(ok, v, NA_character_)))
    out[!is.na(num)] <- as.character(num[!is.na(num)])
    return(out)
  }
  # Plain decimal or exponent forms only: as.numeric() would also take "0x10", "Inf", "1d3"
  # and JavaScript's Number() disagrees on those, so both sides use this one pattern.
  ok <- grepl("^\\s*[+-]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][+-]?[0-9]+)?\\s*$", v)
  num <- suppressWarnings(as.numeric(ifelse(ok, v, NA_character_)))
  # "1e999" overflows to Inf: not a key value, so it is bad, never an orphan
  num[!is.finite(num)] <- NA_real_
  out <- rep(NA_character_, length(v))
  out[!is.na(num)] <- as.character(num[!is.na(num)])
  out
}

sv_supp_key_chr <- function(x) {
  if (is.factor(x)) x <- as.character(x)
  as.character(x)
}

# A missing QNAM is the text "NA", as for keys and as tidyr::pivot_wider() names its column.
sv_supp_qnam <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- "NA"
  x
}

sv_supp_paste <- function(...) paste(..., sep = "\r")

sv_supp_samples <- function(s, idvar, val, rows, n, qnam) {
  rows <- utils::head(which(rows), n)
  data.frame(USUBJID = as.character(s$USUBJID[rows]), IDVAR = idvar[rows],
             IDVARVAL = as.character(s$IDVARVAL[rows]), QNAM = qnam[rows],
             stringsAsFactors = FALSE)
}

# The check is split in steps so the lazy twin (sv_lazy_supp_check(), R/lazy.R) shares every
# SUPP-side step and the final assembly. Only the parent-side facts differ: in memory they come
# from the parent data frame, in the lazy twin from 0-row types, a count, a semi-join and a head.

# A list(error =) when `supp` lacks a column the check needs, else NULL.
sv_supp_cols_error <- function(supp_cols, supp_name) {
  for (col in c("USUBJID", "IDVAR", "IDVARVAL", "QNAM", "QVAL")) {
    if (!col %in% supp_cols) return(list(error = paste0("Not in ", supp_name, ": ", col)))
  }
  NULL
}

# The SUPP rows of one parent domain and what is derived from them alone; or list(error =).
sv_supp_side <- function(supp, supp_name, rdomain) {
  has_rd <- "RDOMAIN" %in% names(supp)
  n_other <- 0L
  if (has_rd) {
    keep <- !is.na(supp$RDOMAIN) & as.character(supp$RDOMAIN) == rdomain
    n_other <- sum(!keep)
    supp <- supp[keep, , drop = FALSE]
  }
  n_supp <- nrow(supp)
  if (!n_supp) return(list(error = paste0(supp_name, " has no rows for ", rdomain)))

  idvar <- as.character(supp$IDVAR)
  idvar[is.na(idvar) | !nzchar(trimws(idvar))] <- ""
  levels_ <- unique(idvar)
  levels_ <- c(levels_[nzchar(levels_)], if ("" %in% levels_) "")
  list(supp = supp, has_rd = has_rd, n_other = n_other, n_supp = n_supp, idvar = idvar,
       qnam = sv_supp_qnam(supp$QNAM), levels = levels_)
}

# Key type of each IDVAR level's parent column. `parent0` is the parent or any 0-row slice of
# it holding at least those columns. A named character vector, or list(error =).
sv_supp_types <- function(levels_, parent0, parent_name) {
  types <- character(0)
  for (iv in levels_[nzchar(levels_)]) {
    if (!iv %in% names(parent0)) return(list(error = paste0("Not in ", parent_name, ": ", iv)))
    ty <- sv_supp_key_type(parent0[[iv]])
    if (is.na(ty)) {
      return(list(error = paste0("Cannot merge on ", iv, ": its type is ", class(parent0[[iv]])[1])))
    }
    types[iv] <- ty
  }
  types
}

# The SUPP key text per row, and IDVARVAL converted to the parent key type ("" at subject
# level; `bad` = did not convert).
sv_supp_convert_side <- function(side, types, keys) {
  supp <- side$supp
  skey <- do.call(sv_supp_paste, lapply(supp[keys], sv_supp_key_chr))
  val <- rep("", side$n_supp)
  bad <- rep(FALSE, side$n_supp)
  for (iv in side$levels[nzchar(side$levels)]) {
    r <- side$idvar == iv
    cv <- sv_supp_convert(supp$IDVARVAL[r], types[[iv]])
    val[r] <- ifelse(is.na(cv), NA_character_, cv)
    bad[r] <- is.na(cv)
  }
  list(skey = skey, val = val, bad = bad)
}

# Which SUPP rows find a parent record, on a parent data frame.
sv_supp_match_df <- function(side, conv, parent, keys) {
  pkey <- do.call(sv_supp_paste, lapply(parent[keys], sv_supp_key_chr))
  matched <- rep(FALSE, side$n_supp)
  for (iv in side$levels) {
    r <- side$idvar == iv
    matched[r] <- if (!nzchar(iv)) {
      conv$skey[r] %in% pkey
    } else {
      !conv$bad[r] & sv_supp_paste(conv$skey[r], conv$val[r]) %in%
        sv_supp_paste(pkey, sv_supp_key_chr(parent[[iv]]))
    }
  }
  matched
}

# Everything after the parent-side facts are known: `matched`, the parent column names, its
# row count and `pv` (its first `sample_n` rows).
sv_supp_finish <- function(side, conv, matched, types, keys, parent_names, n_parent, pv, plan,
                           sample_n, warn_other) {
  supp <- side$supp
  idvar <- side$idvar
  qnam <- side$qnam
  levels_ <- side$levels
  n_supp <- side$n_supp
  n_other <- side$n_other
  skey <- conv$skey
  val <- conv$val
  bad <- conv$bad
  orphan <- !matched & !bad

  # QNAMs: first appearance, level, label
  qn <- unique(qnam)
  qnams <- lapply(qn, function(q) {
    r <- which(qnam == q)
    lab <- as.character(supp$QLABEL[r])
    lab <- if ("QLABEL" %in% names(supp)) lab[!is.na(lab)][1] else ""
    if (is.na(lab)) lab <- ""
    list(qnam = q, label = lab, idvar = idvar[r[1]])
  })
  idvars <- lapply(levels_, function(iv) list(idvar = iv, type = if (nzchar(iv)) types[[iv]] else NA_character_))
  new_plan <- list(keys = keys, idvars = idvars, qnams = qnams, rdomain_col = side$has_rd)

  # repeats: after conversion
  dkey <- sv_supp_paste(skey, idvar, val, qnam)
  dup <- rep(FALSE, n_supp)
  dup[!bad] <- duplicated(dkey[!bad])
  two_level <- Filter(function(q) length(unique(idvar[qnam == q])) > 1L, qn)
  clashes <- intersect(qn, parent_names)
  two_level <- as.character(unlist(two_level))

  status <- if (sum(dup) || length(clashes) || length(two_level)) "error" else
    if (sum(orphan) || sum(bad) || (warn_other && n_other > 0L)) "warning" else "ok"

  drift <- list(stale = FALSE, reasons = character(0))
  if (!is.null(plan)) {
    pick <- function(l, f) as.character(unlist(lapply(l, function(e) {
      v <- e[[f]]
      if (is.null(v)) NA_character_ else as.character(v)
    })))
    p_q <- pick(plan$qnams, "qnam")
    p_i <- pick(plan$idvars, "idvar")
    p_t <- pick(plan$idvars, "type")
    new_iv <- setdiff(levels_, p_i)
    say <- function(prefix, x) if (length(x)) paste0(prefix, x) else character(0)
    reasons <- c(say("New QNAM: ", setdiff(qn, p_q)),
                 say("New IDVAR: ", ifelse(nzchar(new_iv), new_iv, "(subject level)")),
                 say("QNAM gone: ", setdiff(p_q, qn)))
    for (iv in intersect(levels_[nzchar(levels_)], p_i)) {
      old <- p_t[match(iv, p_i)]
      if (!is.na(old) && !identical(old, types[[iv]])) {
        reasons <- c(reasons, paste0(iv, " type changed from ", old, " to ", types[[iv]]))
      }
    }
    drift <- list(stale = length(reasons) > 0L, reasons = reasons)
  }

  # preview: the first parent rows with one column per QNAM (single-level, no clash)
  pvkey <- do.call(sv_supp_paste, lapply(pv[keys], sv_supp_key_chr))
  for (q in setdiff(qn, c(clashes, two_level))) {
    iv <- idvar[match(q, qnam)]
    rows <- which(qnam == q & !bad)
    sk <- if (nzchar(iv)) sv_supp_paste(skey[rows], val[rows]) else skey[rows]
    pk <- if (nzchar(iv)) sv_supp_paste(pvkey, sv_supp_key_chr(pv[[iv]])) else pvkey
    pv[[q]] <- as.character(supp$QVAL[rows])[match(pk, sk)]
  }
  rownames(pv) <- NULL

  list(
    status = status,
    plan = new_plan,
    n_parent = n_parent,
    n_supp = n_supp,
    n_matched = sum(matched),
    n_orphan = sum(orphan),
    orphan_samples = sv_supp_samples(supp, idvar, val, orphan, sample_n, qnam),
    n_other_rdomain = n_other,
    repeats = list(n = sum(dup), samples = sv_supp_samples(supp, idvar, val, dup, sample_n, qnam)),
    clashes = clashes,
    two_level = two_level,
    bad_idvarval = list(n = sum(bad), samples = sv_supp_samples(supp, idvar, val, bad, sample_n, qnam)),
    columns = lapply(qnams, function(q) list(name = q$qnam, label = q$label)),
    preview = pv,
    drift = drift
  )
}

# The pure logic, on plain data frames.
# `warn_other`: other-RDOMAIN rows make a warning.
sv_supp_check_df <- function(parent, supp, parent_name, supp_name, rdomain, plan, sample_n,
                             warn_other) {
  err <- sv_supp_cols_error(names(supp), supp_name)
  if (!is.null(err)) return(err)
  if (!"USUBJID" %in% names(parent)) return(list(error = paste0("Not in ", parent_name, ": USUBJID")))
  side <- sv_supp_side(supp, supp_name, rdomain)
  if (!is.null(side$error)) return(side)
  types <- sv_supp_types(side$levels, parent, parent_name)
  if (is.list(types)) return(types)
  keys <- intersect(c("STUDYID", "USUBJID"), intersect(names(parent), names(supp)))
  conv <- sv_supp_convert_side(side, types, keys)
  matched <- sv_supp_match_df(side, conv, parent, keys)
  sv_supp_finish(side, conv, matched, types, keys, names(parent), nrow(parent),
                 utils::head(parent, sample_n), plan, sample_n, warn_other)
}

#' @rdname sv_supp_check
#' @export
sv_supp_check_json <- function(chk) {
  if (!is.null(chk$error)) {
    return(as.character(jsonlite::toJSON(list(error = chk$error), auto_unbox = TRUE, null = "null")))
  }
  chk$clashes <- as.list(chk$clashes)
  chk$two_level <- as.list(chk$two_level)
  chk$plan$keys <- as.list(chk$plan$keys)
  chk$drift$reasons <- as.list(chk$drift$reasons)
  as.character(jsonlite::toJSON(chk, auto_unbox = TRUE, null = "null", na = "null",
                                digits = NA, dataframe = "rows"))
}
