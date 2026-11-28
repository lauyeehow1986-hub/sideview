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
#'   `columns`, `preview`, `drift` and `combine_supp`; or just `list(error = )`
#'   when the check cannot run. `combine_supp` says whether
#'   `metatools::combine_supp()` (0.3.0) would give the same result as the
#'   generated dplyr code: `list(ok, reason, prep = list(rdomain, idvar_na))`,
#'   where `reason` (`NULL` when `ok`) is the first difference and `prep` the
#'   SUPP lines the call needs first (an `RDOMAIN` filter; blank `IDVAR` to
#'   `NA`).
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
  sv_supp_classify(
    sv_supp_check_df(as.data.frame(parent, stringsAsFactors = FALSE),
                     as.data.frame(supp, stringsAsFactors = FALSE),
                     parent_name, supp_name, rdomain, plan, as.integer(sample_n),
                     from_name == rdomain),
    parent_name, supp_name)
}

# The class of a check, with the two names the sentences need. sv_supp_check_json() drops the
# names and the class, so the browser payload is the same as before.
sv_supp_classify <- function(chk, parent_name, supp_name) {
  chk$parent_name <- parent_name
  chk$supp_name <- supp_name
  structure(chk, class = "sv_supp_check")
}

#' @export
print.sv_supp_check <- function(x, ...) {
  cs <- sv_supp_combine_of(x)
  line <- if (is.null(cs)) NULL else if (isTRUE(cs$ok)) "combine_supp(): yes" else
    paste0("combine_supp(): no, ", cs$reason)
  cat(c(sv_say_supp(x), line), sep = "\n")
  invisible(x)
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

# The whitespace allowed around a numeric IDVARVAL: ASCII only (space, tab, LF, CR, FF, VT),
# which is what as.integer()/as.numeric() skip. JavaScript's trim() and \s also take NBSP,
# U+2028, U+3000 and the BOM, so both sides spell the class out. Inside a bracket TRE reads
# "\t" as a backslash and a "t", so the R side (and the generated code) use perl = TRUE.
sv_supp_ws <- "[ \\t\\n\\r\\f\\x0b]"
sv_supp_int_re <- paste0("^", sv_supp_ws, "*[+-]?[0-9]+", sv_supp_ws, "*$")
sv_supp_dbl_re <- paste0("^", sv_supp_ws, "*[+-]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][+-]?[0-9]+)?",
                         sv_supp_ws, "*$")
# Past this a double key is bad: R parses "1.7976931348623158e308" (the largest double) to Inf
# where JavaScript keeps it, so the top of the range is cut off on both sides alike.
sv_supp_dbl_max <- 1e308

# IDVARVAL converted to the key type as a number (NA = did not convert); NULL for character.
sv_supp_convert_num <- function(v, type) {
  v <- as.character(v)
  if (identical(type, "character")) return(NULL)
  if (identical(type, "integer")) {
    ok <- grepl(sv_supp_int_re, v, perl = TRUE)
    return(suppressWarnings(as.integer(ifelse(ok, v, NA_character_))))
  }
  # Plain decimal or exponent forms only: as.numeric() would also take "0x10", "Inf", "1d3"
  # and JavaScript's Number() disagrees on those, so both sides use this one pattern.
  ok <- grepl(sv_supp_dbl_re, v, perl = TRUE)
  num <- suppressWarnings(as.numeric(ifelse(ok, v, NA_character_)))
  # "1e999" overflows to Inf: not a key value, so it is bad, never an orphan
  num[is.na(num) | abs(num) > sv_supp_dbl_max] <- NA_real_
  num
}

# Convert IDVARVAL text to the key type; NA means it did not convert.
sv_supp_convert <- function(v, type) {
  v <- as.character(v)
  num <- sv_supp_convert_num(v, type)
  if (is.null(num)) return(v)
  out <- rep(NA_character_, length(v))
  out[!is.na(num)] <- as.character(num[!is.na(num)])
  out
}

sv_supp_key_chr <- function(x) {
  if (is.factor(x)) x <- as.character(x)
  # an integer64 key is a double key (sv_supp_key_type()): its text must be the double's text,
  # "3e+09", as IDVARVAL "3000000000" converts to, not "3000000000"
  if (inherits(x, "integer64")) x <- suppressWarnings(as.numeric(x))
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
# level; `bad` = did not convert). `num` is the converted value as a full-precision double for
# numeric levels (NA elsewhere): the lazy match compares numbers, and the text in `val` keeps
# only the 15 digits as.character() writes.
sv_supp_convert_side <- function(side, types, keys) {
  supp <- side$supp
  skey <- do.call(sv_supp_paste, lapply(supp[keys], sv_supp_key_chr))
  val <- rep("", side$n_supp)
  bad <- rep(FALSE, side$n_supp)
  num <- rep(NA_real_, side$n_supp)
  for (iv in side$levels[nzchar(side$levels)]) {
    r <- side$idvar == iv
    cn <- sv_supp_convert_num(supp$IDVARVAL[r], types[[iv]])
    cv <- sv_supp_convert(supp$IDVARVAL[r], types[[iv]])
    val[r] <- ifelse(is.na(cv), NA_character_, cv)
    bad[r] <- is.na(cv)
    if (!is.null(cn)) num[r] <- as.numeric(cn)
  }
  list(skey = skey, val = val, bad = bad, num = num)
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
  res <- sv_supp_finish(side, conv, matched, types, keys, names(parent), nrow(parent),
                        utils::head(parent, sample_n), plan, sample_n, warn_other)
  cs <- sv_supp_combine(parent, supp, side, conv, matched, keys, parent_name, supp_name, res$plan)
  if (identical(res$status, "error")) {
    cs$ok <- FALSE
    cs["reason"] <- list(sv_supp_combine_stop_reason(res, parent_name))
  }
  res$combine_supp <- cs
  res
}

# ---- combine_supp: would metatools::combine_supp() (0.3.0) give the dplyr code's result? ----
# Rules 1, 4, 5, 7 and 8 of the E1 design (section 5.2); the lazy twin adds rules 2 and 3.

# The Unicode White_Space set that stringr::str_trim() (stringi) trims. Written with R's \u
# escapes, so the pattern is UTF-8 (PCRE then runs in UTF mode) and this file stays ASCII.
sv_str_trim_ws <- "[\t\n\v\f\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]"

# stringr::str_trim() without stringr (a Suggests): stringi also drops one leading BOM
# (U+FEFF) as it reads the text, before it trims; a BOM anywhere else stays.
sv_str_trim <- function(x) {
  x <- sub("^\ufeff", "", as.character(x), perl = TRUE)
  gsub(paste0("^", sv_str_trim_ws, "+|", sv_str_trim_ws, "+$"), "", x, perl = TRUE)
}

# as.character() as R writes it under the default scipen = 0 ("1e+05", not "100000"), whatever
# the session's setting: combine_supp() compares this text, and the JS twin assumes scipen 0.
sv_r_chr <- function(x) {
  op <- options(scipen = 0)
  on.exit(options(op), add = TRUE)
  as.character(x)
}

sv_supp_combine_supp_cols <- c("STUDYID", "RDOMAIN", "USUBJID", "IDVAR", "IDVARVAL", "QNAM",
                               "QLABEL", "QVAL", "QORIG")
sv_supp_combine_parent_cols <- c("STUDYID", "DOMAIN", "USUBJID")

# A number as exact text (C99 hex), so equal text is equal doubles; -0 is written as 0.
sv_supp_hex <- function(x) {
  if (inherits(x, "integer64")) x <- suppressWarnings(as.numeric(x))
  x <- as.numeric(x)
  x[!is.na(x) & x == 0] <- 0
  sprintf("%a", x)
}

# For each element of `s`, how many elements of `p` equal it.
sv_supp_count <- function(p, s) {
  u <- unique(p)
  out <- tabulate(match(p, u), nbins = length(u))[match(s, u)]
  out[is.na(out)] <- 0L
  out
}

# The combine_supp field. `side`, `conv`, `matched`, `keys` and `plan` (the check's new plan:
# its QNAM labels are "ours" for rule 8) are the check's own steps; `supp` is the SUPP before
# the RDOMAIN filter (its column names), `parent` a data frame.
sv_supp_combine <- function(parent, supp, side, conv, matched, keys, parent_name, supp_name, plan) {
  op <- options(scipen = 0)
  on.exit(options(op), add = TRUE)
  iv_raw <- as.character(side$supp$IDVAR)
  prep <- list(rdomain = isTRUE(side$n_other > 0L),
               idvar_na = any(!is.na(iv_raw) & !nzchar(trimws(iv_raw))))
  no <- function(reason) list(ok = FALSE, reason = reason, prep = prep)
  # rule 4: combine_supp() wants exactly the SDTM SUPP columns (QEVAL may be there or not)
  miss <- setdiff(sv_supp_combine_supp_cols, names(supp))
  if (length(miss)) return(no(paste0(supp_name, " has no ", miss[1], " column")))
  extra <- setdiff(names(supp), c(sv_supp_combine_supp_cols, "QEVAL"))
  if (length(extra)) return(no(paste0(supp_name, " has extra columns: ", paste(extra, collapse = ", "))))
  # rule 5: it joins on STUDYID, DOMAIN and USUBJID
  miss <- setdiff(sv_supp_combine_parent_cols, names(parent))
  if (length(miss)) return(no(paste0(parent_name, " has no ", miss[1], " column")))
  # it drops a parent IDVARVAL column (ret$IDVARVAL <- NULL); the dplyr code keeps it
  if ("IDVARVAL" %in% names(parent)) {
    return(no(paste0(parent_name, " has an IDVARVAL column, which combine_supp() would drop")))
  }
  why <- sv_supp_combine_rows(parent, side, conv, matched, keys, parent_name)
  if (is.null(why)) why <- sv_supp_combine_factor(parent, supp, supp_name, side)
  if (is.null(why)) why <- sv_supp_combine_labels(side, plan)
  if (!is.null(why)) return(no(why))
  list(ok = TRUE, reason = NULL, prep = prep)
}

# Rule 7: for each SUPP row (after the RDOMAIN filter), the parent rows the dplyr code joins
# ("ours") and the rows combine_supp() joins ("theirs") must be the same set. Theirs: STUDYID,
# DOMAIN == RDOMAIN and USUBJID equal (NA matches NA), plus for a keyed row
# str_trim(as.character(IDVARVAL)) == str_trim(as.character(<key>)). Ours: the check's keys plus
# the converted IDVARVAL; a numeric key is compared as a full-precision number, as the dplyr
# code's join does (the check's `matched` compares the 15-digit text, so 0.3 would match
# 0.1 + 0.2 there). A bad IDVARVAL joins nothing. The first row whose sets differ gives the text.
sv_supp_combine_rows <- function(parent, side, conv, matched, keys, parent_name) {
  s <- side$supp
  enc <- function(x) {
    x <- sv_r_chr(x)
    ifelse(is.na(x), "\001", paste0("\002", x))
  }
  pk_t <- sv_supp_paste(enc(parent$STUDYID), enc(parent$DOMAIN), enc(parent$USUBJID))
  sk_t <- sv_supp_paste(enc(s$STUDYID), enc(s$RDOMAIN), enc(s$USUBJID))
  # Both key texts are built here, under the caller's scipen = 0: conv$skey was written under the
  # session's scipen, so a numeric USUBJID would read "1e+05" on one side and "100000" on the other.
  pkey <- do.call(sv_supp_paste, lapply(parent[keys], sv_supp_key_chr))
  skey <- do.call(sv_supp_paste, lapply(s[keys], sv_supp_key_chr))
  n <- side$n_supp
  n_o <- n_t <- n_b <- integer(n)
  s_o <- s_t <- character(n)
  lv <- list()
  for (k in seq_along(side$levels)) {
    iv <- side$levels[k]
    r <- which(side$idvar == iv)
    # the check's own `matched` decides whether a row joins, except on a numeric key
    joins <- matched[r]
    if (!nzchar(iv)) {
      p_o <- pkey
      p_t <- pk_t
      s_o[r] <- skey[r]
      s_t[r] <- sk_t[r]
    } else {
      pv <- parent[[iv]]
      if (identical(sv_supp_key_type(pv), "character")) {
        p_o <- sv_supp_paste(pkey, sv_supp_key_chr(pv))
        s_o[r] <- sv_supp_paste(skey[r], conv$val[r])
      } else {
        p_o <- sv_supp_paste(pkey, sv_supp_hex(pv))
        s_o[r] <- sv_supp_paste(skey[r], sv_supp_hex(conv$num[r]))
        joins <- !conv$bad[r]
      }
      p_t <- sv_supp_paste(pk_t, enc(sv_str_trim(sv_r_chr(pv))))
      s_t[r] <- sv_supp_paste(sk_t[r], enc(sv_str_trim(sv_r_chr(s$IDVARVAL[r]))))
    }
    n_o[r] <- ifelse(joins, sv_supp_count(p_o, s_o[r]), 0L)
    n_t[r] <- sv_supp_count(p_t, s_t[r])
    n_b[r] <- ifelse(joins, sv_supp_count(paste(p_o, p_t, sep = "\n"), paste(s_o[r], s_t[r], sep = "\n")), 0L)
    lv[[k]] <- list(p_o = p_o, p_t = p_t)
  }
  differ <- !(n_o == n_t & n_b == n_o)
  if (!any(differ)) return(NULL)
  i <- which(differ)[1]
  iv <- side$idvar[i]
  if (!nzchar(iv)) return(paste0(sv_r_chr(s$USUBJID[i]), " would not match in combine_supp()"))
  p <- lv[[match(iv, side$levels)]]
  v <- paste0("IDVARVAL \"", sv_r_chr(s$IDVARVAL[i]), "\" ")
  key <- function(j) paste0(iv, " ", sv_r_chr(parent[[iv]][j]))
  if (n_t[i] == 0L) return(paste0(v, "would not match ", key(which(p$p_o == s_o[i])[1]), " in combine_supp()"))
  if (n_o[i] == 0L) return(paste0(v, "would match ", key(which(p$p_t == s_t[i])[1]), " in combine_supp()"))
  paste0(v, "would match a different ", parent_name, " record in combine_supp()")
}

# Rule 7, the classes: a join changes a factor it joins to text. The dplyr code joins a factor
# IDVAR key to the text IDVARVAL (so returns it as character), which combine_supp() does not;
# combine_supp() joins the parent's DOMAIN to RDOMAIN (so returns a factor DOMAIN as character),
# which the dplyr code does not. STUDYID and USUBJID are joined by both. Rule 8, the classes:
# combine_supp() picks a factor QNAM's column by its integer code and sets a factor QLABEL as the
# label, so the labels differ (`supp` is the SUPP as given, before the RDOMAIN filter).
sv_supp_combine_factor <- function(parent, supp, supp_name, side) {
  for (iv in side$levels[nzchar(side$levels)]) {
    if (is.factor(parent[[iv]])) return(paste0(iv, " would be a factor in combine_supp(), not text"))
  }
  if (is.factor(parent$DOMAIN)) return("DOMAIN would be text in combine_supp(), not a factor")
  if (is.factor(supp$QNAM)) return(paste0(supp_name, " QNAM is a factor, so combine_supp() would label the wrong columns"))
  if (is.factor(supp$QLABEL)) return(paste0(supp_name, " QLABEL is a factor, so combine_supp() would set factor labels"))
  NULL
}

# Rule 8: combine_supp() labels each QNAM from unique(supp[c("QNAM", "QLABEL")]), the last pair
# winning: the last distinct QLABEL in order of first appearance. Ours is the plan's label
# (sv_supp_finish(): the first non-NA QLABEL, "" when none). NA and "" both mean no label.
sv_supp_combine_labels <- function(side, plan) {
  if (!"QLABEL" %in% names(side$supp)) return(NULL)
  lab <- as.character(side$supp$QLABEL)
  none <- function(x) is.null(x) || is.na(x) || !nzchar(x)
  say <- function(x) if (none(x)) "none" else paste0("\"", x, "\"")
  for (e in plan$qnams) {
    q <- e$qnam
    ours <- e$label
    theirs <- utils::tail(unique(lab[side$qnam == q]), 1L)
    if (none(ours) && none(theirs)) next
    if (!none(ours) && !none(theirs) && identical(ours, theirs)) next
    return(paste0(q, " label would be ", say(theirs), " in combine_supp(), not ", say(ours)))
  }
  NULL
}

# Rule 1: the text for a check whose status is "error" (the merge code stops).
sv_supp_combine_stop_reason <- function(chk, parent_name) {
  n <- chk$repeats$n
  clashes <- as.character(unlist(chk$clashes))
  two <- as.character(unlist(chk$two_level))
  parts <- c(
    if (!is.null(n) && n > 0) paste0(n, " repeated QNAM ", if (n == 1) "record" else "records"),
    if (length(clashes)) paste0(paste(clashes, collapse = ", "), " already in ", parent_name),
    if (length(two)) paste0(paste(two, collapse = ", "), " on two IDVAR levels"))
  paste0("The merge stops: ", paste(parts, collapse = "; "))
}

# The field of a check; for an {error} check, not ok with the error as its reason.
sv_supp_combine_of <- function(chk) {
  if (!is.null(chk$error)) {
    return(list(ok = FALSE, reason = chk$error, prep = list(rdomain = FALSE, idvar_na = FALSE)))
  }
  chk$combine_supp
}

#' @rdname sv_supp_check
#' @export
sv_supp_check_json <- function(chk) {
  chk <- unclass(chk)
  chk$parent_name <- NULL
  chk$supp_name <- NULL
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
