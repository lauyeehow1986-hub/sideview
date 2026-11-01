# CDISC awareness: dataset catalogue (SDTM, SEND, ADaM) and detection.

.sv_cdisc_cache <- new.env(parent = emptyenv())

#' CDISC dataset catalogue
#'
#' The SDTM, SEND and ADaM datasets that sideview recognises, read once per
#' session from a file shipped with the package.
#'
#' @return A data frame of character columns: `name` (dataset code, or the
#'   ADaM class name), `label` (published dataset label), `class`, `standard`
#'   (`"SDTM"`, `"SEND"` or `"ADaM"`), `ig_versions` (`;`-separated
#'   implementation guide versions) and `keys` (`;`-separated natural keys).
#' @examples
#' head(sv_cdisc_catalogue())
#' @export
sv_cdisc_catalogue <- function() {
  if (is.null(.sv_cdisc_cache$catalogue)) {
    path <- system.file("extdata", "cdisc_catalogue.csv", package = "sideview")
    .sv_cdisc_cache$catalogue <- utils::read.csv(path, colClasses = "character",
                                                 na.strings = character())
  }
  .sv_cdisc_cache$catalogue
}

# SDTM variable-name suffixes used by the variable-prefix rule (spec 5.1.3).
sv_cdisc_suffixes <- c("SEQ", "TERM", "DECOD", "TRT", "CAT", "SCAT", "SEV", "SER",
                       "STDTC", "ENDTC", "DTC", "DY", "TESTCD", "TEST", "ORRES", "ORRESU",
                       "STRESC", "STRESN", "STRESU", "STAT", "BLFL", "DOSE", "DOSU")

sv_cdisc_trial_design <- c("TS", "TA", "TE", "TV", "TI", "TX")

# Stop unless `cdisc` is "auto", FALSE or a named character vector of domain codes.
sv_cdisc_check_arg <- function(cdisc) {
  ok <- identical(cdisc, "auto") || identical(cdisc, FALSE) ||
    (is.character(cdisc) && length(cdisc) >= 1L && !anyNA(cdisc) &&
       !is.null(names(cdisc)) && !anyNA(names(cdisc)) && all(nzchar(names(cdisc))) &&
       all(nzchar(trimws(cdisc))))
  if (!ok) {
    stop("`cdisc` must be \"auto\", FALSE, or a named character vector of domain codes ",
         "such as c(my_ae = \"AE\").", call. = FALSE)
  }
  cdisc
}

# The only place the detector reads columns and values from a table. Values
# that cost something are functions, so a rule that does not need them never
# pays for them.
sv_cdisc_peek <- function(data) {
  clean <- function(x) {
    x <- toupper(trimws(as.character(x)))
    unique(x[!is.na(x) & nzchar(x)])
  }
  if (sv_is_lazy_input(data)) {
    cols <- sv_lazy_names(data)
    return(list(
      cols = cols,
      domain_values = if ("DOMAIN" %in% cols) clean(sv_cdisc_lazy_query(data, "domain")) else character(),
      usubjid_unique = function() {
        "USUBJID" %in% cols && isTRUE(sv_cdisc_lazy_query(data, "adsl"))
      },
      rdomain_values = function() {
        if ("RDOMAIN" %in% cols) clean(sv_cdisc_lazy_query(data, "rdomain")) else character()
      }
    ))
  }
  cols <- names(data)
  list(
    cols = cols,
    domain_values = if ("DOMAIN" %in% cols) clean(data[["DOMAIN"]]) else character(),
    usubjid_unique = function() {
      "USUBJID" %in% cols && !anyDuplicated(data[["USUBJID"]])
    },
    rdomain_values = function() {
      if ("RDOMAIN" %in% cols) clean(data[["RDOMAIN"]]) else character()
    }
  )
}

# Catalogue row for a code: SDTM first, then SEND, then ADaM.
sv_cdisc_row <- function(code) {
  cat <- sv_cdisc_catalogue()
  for (std in c("SDTM", "SEND", "ADaM")) {
    hit <- which(cat$name == code & cat$standard == std)
    if (length(hit)) return(cat[hit[1L], , drop = FALSE])
  }
  NULL
}

sv_cdisc_extensions <- c("xpt", "csv", "tsv", "txt", "sas7bdat", "parquet", "feather",
                         "arrow", "rds", "rda", "xlsx", "xls", "json")

# The table name without a data-file extension (case kept).
sv_cdisc_clean_name <- function(name) {
  if (is.null(name) || length(name) != 1L || is.na(name)) return(NULL)
  sub(paste0("\\.(", paste(sv_cdisc_extensions, collapse = "|"), ")$"), "",
      basename(as.character(name)), ignore.case = TRUE)
}

sv_cdisc_name_code <- function(name) {
  name <- sv_cdisc_clean_name(name)
  if (is.null(name)) return(NA_character_)
  toupper(name)
}

# Rule 1: one distinct DOMAIN value, known to the SDTM or SEND catalogue.
sv_cdisc_rule_domain_col <- function(peek) {
  v <- peek$domain_values
  if (length(v) != 1L) return(NULL)
  row <- sv_cdisc_row(v)
  if (is.null(row) || row$standard == "ADaM") return(NULL)
  list(code = v, evidence = paste("DOMAIN column =", v))
}

# Rule 2: the table name is a catalogue name.
sv_cdisc_rule_name <- function(name) {
  code <- sv_cdisc_name_code(name)
  if (is.na(code) || is.null(sv_cdisc_row(code))) return(NULL)
  list(code = code, evidence = paste("table name =", name))
}

# Rule 3: three or more columns share a catalogue domain prefix and an SDTM suffix.
sv_cdisc_rule_prefix <- function(peek) {
  cat <- sv_cdisc_catalogue()
  codes <- unique(cat$name[cat$standard != "ADaM" & nchar(cat$name) == 2L])
  cols <- peek$cols
  hit <- nchar(cols) > 2L & substring(cols, 3L) %in% sv_cdisc_suffixes
  pre <- substr(cols[hit], 1L, 2L)
  pre <- pre[pre %in% codes]
  if (!length(pre)) return(NULL)
  counts <- table(pre)
  if (max(counts) < 3L) return(NULL)
  code <- names(counts)[which.max(counts)]
  list(code = code,
       evidence = sprintf("variable prefix %s (%d columns)", code, as.integer(max(counts))))
}

# Rule 4: ADaM structure, tried in order ADSL, TTE, BDS, OCCDS.
sv_cdisc_rule_adam <- function(peek, name) {
  code <- sv_cdisc_name_code(name)
  by_name <- !is.na(code) && grepl("^AD[A-Z0-9]*$", code)
  row <- if (!is.na(code)) sv_cdisc_row(code) else NULL
  if (!by_name && !(!is.null(row) && row$standard == "ADaM")) return(NULL)
  cols <- peek$cols
  has <- function(...) all(c(...) %in% cols)
  cls <- if (has("USUBJID") && any(c("TRT01P", "TRT01A") %in% cols) && peek$usubjid_unique()) {
    "ADSL"
  } else if (has("PARAMCD", "PARAM", "AVAL", "CNSR")) {
    "TTE"
  } else if (has("PARAMCD", "PARAM") && any(c("AVAL", "AVALC") %in% cols)) {
    "BDS"
  } else if (!("PARAMCD" %in% cols) && any(grepl("^..(TERM|DECOD)$", cols))) {
    "OCCDS"
  } else {
    return(NULL)
  }
  list(code = if (is.na(code)) cls else code, class = cls, standard = "ADaM",
       evidence = paste("ADaM structure", cls))
}

# Rule 5: SUPPQUAL by name or by its characteristic columns.
sv_cdisc_rule_suppqual <- function(peek, name) {
  code <- sv_cdisc_name_code(name)
  by_name <- !is.na(code) && grepl("^SUPP[A-Z]{2}$", code)
  by_cols <- all(c("RDOMAIN", "IDVAR", "IDVARVAL", "QNAM", "QVAL") %in% peek$cols)
  if (!by_name && !by_cols) return(NULL)
  rd <- if (by_cols) peek$rdomain_values() else character()
  parent <- if (length(rd) == 1L) rd else if (by_name) substring(code, 5L) else NULL
  dom <- if (by_name) code else if (length(rd) == 1L) paste0("SUPP", rd) else "SUPPQUAL"
  list(code = dom, class = "Relationship", standard = "SDTM", parent = parent,
       row_code = "SUPPQUAL",
       evidence = if (by_name) paste("SUPP name", name) else "SUPPQUAL columns")
}

# Rule 6: a custom domain, X, Y or Z followed by a letter.
sv_cdisc_rule_custom <- function(peek) {
  v <- peek$domain_values
  if (length(v) != 1L || !grepl("^[XYZ][A-Z]$", v)) return(NULL)
  list(code = v, class = "Custom", standard = "SDTM", evidence = paste("custom domain", v))
}

sv_cdisc_make_tag <- function(data, code, class = NULL, standard = NULL, parent = NULL,
                              evidence, source = "auto", row_code = code) {
  row <- sv_cdisc_row(row_code)
  if (is.null(class)) class <- if (is.null(row)) "Custom" else row$class
  if (is.null(standard)) standard <- if (is.null(row)) "SDTM" else row$standard
  label <- attr(data, "label", exact = TRUE)
  if (!(is.character(label) && length(label) == 1L && !is.na(label) && nzchar(label))) {
    label <- if (is.null(row)) code else row$label
  }
  list(domain = code, label = label, class = class, standard = standard,
       parent = parent, parent_card = NULL, evidence = evidence, source = source)
}

#' Detect the CDISC dataset a table is (internal)
#'
#' @param data A data frame.
#' @param name The table's name.
#' @param cdisc `"auto"`, `FALSE`, or one domain code (a user override that
#'   skips the gate).
#' @return A tag list, or `NULL` when the table does not look like CDISC.
#' @keywords internal
#' @noRd
sv_cdisc_detect <- function(data, name, cdisc = "auto") {
  name <- sv_cdisc_clean_name(name)
  if (is.character(cdisc) && !is.null(names(cdisc))) {
    cdisc <- if (!is.null(name) && name %in% names(cdisc)) cdisc[[name]] else "auto"
  }
  if (identical(cdisc, FALSE)) return(NULL)
  if (is.character(cdisc) && length(cdisc) == 1L && !is.na(cdisc) && cdisc != "auto") {
    code <- toupper(trimws(cdisc))
    adam_like <- is.null(sv_cdisc_row(code)) && grepl("^AD[A-Z0-9]+$", code)
    return(sv_cdisc_make_tag(data, code, standard = if (adam_like) "ADaM",
                             evidence = "set by cdisc =", source = "user"))
  }
  peek <- sv_cdisc_peek(data)
  if (!("STUDYID" %in% peek$cols)) return(NULL)
  td <- intersect(peek$domain_values, sv_cdisc_trial_design)
  gate <- if ("USUBJID" %in% peek$cols) {
    "STUDYID + USUBJID"
  } else if (length(td)) {
    paste("STUDYID + trial-design DOMAIN", td[1L])
  } else {
    return(NULL)
  }

  r2 <- sv_cdisc_rule_name(name)
  # An ADaM name only counts when the structure confirms it.
  if (!is.null(r2) && sv_cdisc_row(r2$code)$standard == "ADaM") {
    r2 <- sv_cdisc_rule_adam(peek, name)
  }
  independent <- list(sv_cdisc_rule_domain_col(peek), r2, sv_cdisc_rule_prefix(peek))
  rule_names <- c("DOMAIN", "name", "prefix")
  found <- which(!vapply(independent, is.null, logical(1)))
  win <- NULL
  winner_rule <- NULL
  if (length(found)) {
    winner_rule <- found[1L]
    win <- independent[[winner_rule]]
  } else {
    win <- sv_cdisc_rule_adam(peek, name)
    if (is.null(win)) win <- sv_cdisc_rule_suppqual(peek, name)
    if (is.null(win)) win <- sv_cdisc_rule_custom(peek)
  }
  if (is.null(win)) return(NULL)

  conflicts <- character()
  for (i in setdiff(found, winner_rule)) {
    r <- independent[[i]]
    if (identical(r$code, win$code)) next
    val <- if (i == 2L) name else r$code
    conflicts <- c(conflicts, sprintf("%s %s disagrees with %s %s", rule_names[i], val,
                                      rule_names[winner_rule], win$code))
  }
  sv_cdisc_make_tag(data, win$code, class = win$class, standard = win$standard,
                    parent = win$parent,
                    row_code = if (is.null(win$row_code)) win$code else win$row_code,
                    evidence = c(win$evidence, conflicts, gate))
}

# Detection that never breaks the caller: a failure gives NULL, plus a message
# when options(sideview.debug = TRUE).
sv_cdisc_detect_safely <- function(data, name, cdisc = "auto") {
  tryCatch(sv_cdisc_detect(data, name, cdisc), error = function(e) {
    if (isTRUE(getOption("sideview.debug"))) {
      message("sideview: CDISC detection failed for '", name, "': ", conditionMessage(e))
    }
    NULL
  })
}
