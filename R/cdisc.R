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

# Catalogue row for a code within one standard.
sv_cdisc_row_std <- function(code, standard) {
  cat <- sv_cdisc_catalogue()
  hit <- which(cat$name == code & cat$standard == standard)
  if (length(hit)) cat[hit[1L], , drop = FALSE] else NULL
}

# The column names of a card's table (the source for a lazy card).
sv_cdisc_card_cols <- function(card) {
  src <- if (!is.null(card$source)) card$source else card$data
  tryCatch({
    if (is.data.frame(src)) names(src) else if (sv_is_lazy_input(src)) sv_lazy_names(src) else character()
  }, error = function(e) character())
}

#' Resolve SEND versus SDTM and SUPP parents across the canvas (internal)
#'
#' A domain in both standards is SEND when a SEND-only domain is on the canvas
#' or the DM table has a `SPECIES` column, otherwise SDTM. A SUPP tag gets the
#' id of its parent domain's card as `parent_card`. Idempotent.
#'
#' @param cards A list of `sideview_card` objects.
#' @return The cards, with `cdisc` tags adjusted.
#' @noRd
sv_cdisc_resolve <- function(cards) {
  cat <- sv_cdisc_catalogue()
  sdtm <- cat$name[cat$standard == "SDTM"]
  send <- cat$name[cat$standard == "SEND"]
  send_only <- setdiff(send, sdtm)
  shared <- intersect(sdtm, send)
  tags <- lapply(cards, function(c) c$cdisc)
  has_send <- any(vapply(seq_along(cards), function(i) {
    t <- tags[[i]]
    if (is.null(t)) return(FALSE)
    if (t$domain %in% send_only) return(TRUE)
    t$domain == "DM" && "SPECIES" %in% sv_cdisc_card_cols(cards[[i]])
  }, logical(1)))
  want <- if (has_send) "SEND" else "SDTM"
  other <- if (has_send) "SDTM" else "SEND"
  domains <- vapply(tags, function(t) if (is.null(t)) NA_character_ else t$domain, character(1))
  for (i in seq_along(cards)) {
    t <- tags[[i]]
    if (is.null(t)) next
    if (t$domain %in% shared && identical(t$source, "auto") && identical(t$standard, other)) {
      old <- sv_cdisc_row_std(t$domain, other)
      new <- sv_cdisc_row_std(t$domain, want)
      if (!is.null(new)) {
        if (identical(t$label, old$label)) t$label <- new$label
        t$class <- new$class
        t$standard <- want
      }
    }
    if (!is.null(t$parent)) {
      j <- which(domains == t$parent)
      j <- setdiff(j, i)
      t$parent_card <- if (length(j)) cards[[j[1L]]]$id else NULL
    }
    cards[[i]]$cdisc <- t
  }
  cards
}

#' Apply the `cdisc` argument to a list of cards, then resolve (internal)
#'
#' @param cards A list of `sideview_card` objects.
#' @param cdisc `"auto"`, `FALSE` or a named character vector of domain codes.
#' @return The cards with final `cdisc` tags.
#' @noRd
sv_cdisc_finalize <- function(cards, cdisc = "auto") {
  if (identical(cdisc, FALSE)) {
    for (i in seq_along(cards)) cards[[i]]$cdisc <- NULL
    return(cards)
  }
  if (is.character(cdisc) && !identical(cdisc, "auto")) {
    keys <- if (is.null(names(cdisc))) NULL else names(cdisc)
    clean <- vapply(cards, function(c) {
      n <- sv_cdisc_clean_name(c$name)
      if (is.null(n)) NA_character_ else n
    }, character(1))
    if (!is.null(keys)) {
      unknown <- setdiff(keys, clean)
      if (length(unknown)) {
        warning("`cdisc` names no table: ", paste(unknown, collapse = ", "), call. = FALSE)
      }
    }
    for (i in seq_along(cards)) {
      c <- cards[[i]]
      if (!identical(c$type, "grid")) next
      if (!is.null(keys) && !(clean[i] %in% keys)) next
      src <- if (!is.null(c$source)) c$source else c$data
      tag <- sv_cdisc_detect_safely(src, c$name, cdisc)
      cards[[i]]$cdisc <- tag
    }
  }
  sv_cdisc_resolve(cards)
}

#' The tags that changed between two card lists (internal)
#'
#' @param old,new Lists of cards.
#' @return A named list `card_id -> tag | NULL` for every card in `new` whose
#'   tag differs from its tag in `old`.
#' @noRd
sv_cdisc_tag_diff <- function(old, new) {
  old_tags <- stats::setNames(lapply(old, function(c) c$cdisc), vapply(old, function(c) c$id, character(1)))
  out <- list()
  for (c in new) {
    prev <- old_tags[[c$id]]
    if (!identical(prev, c$cdisc)) out[c$id] <- list(c$cdisc)
  }
  out
}

# ---- Reader ------------------------------------------------------------------

#' Is a package installed? A wrapper so tests can mock it.
#' @noRd
sv_has_pkg <- function(pkg) requireNamespace(pkg, quietly = TRUE)

sv_read_cdisc_pkg <- c(xpt = "haven", sas7bdat = "haven", json = "datasetjson", parquet = "arrow")

#' Read a Dataset-JSON file into a data frame with variable labels.
#' @noRd
sv_read_dataset_json <- function(path) {
  obj <- datasetjson::read_dataset_json(path)
  dat <- if (is.data.frame(obj)) obj else obj$data
  if (!is.data.frame(dat)) stop("no data in the file", call. = FALSE)
  cols <- if (is.list(obj) && !is.data.frame(obj)) obj$columns else NULL
  if (is.data.frame(cols) && all(c("name", "label") %in% names(cols))) {
    for (i in seq_len(nrow(cols))) {
      nm <- cols$name[i]
      lab <- cols$label[i]
      if (nm %in% names(dat) && is.character(lab) && length(lab) == 1L && !is.na(lab) &&
          is.null(attr(dat[[nm]], "label", exact = TRUE))) {
        attr(dat[[nm]], "label") <- lab
      }
    }
  }
  as.data.frame(dat)
}

#' Read CDISC datasets from files
#'
#' Reads `.xpt`, `.sas7bdat`, Dataset-JSON (`.json`) and `.parquet` files into a
#' named list that can go straight into [sideview()] or [sideview_widget()].
#' Names are the lower-case file stems, in file order. Variable labels are kept.
#'
#' Each format needs its package, all in `Suggests:`: haven (`.xpt`,
#' `.sas7bdat`), datasetjson (`.json`) and arrow (`.parquet`). Files are only
#' read, never run. Nothing goes over the network.
#'
#' @param path A directory (its supported files are read, not recursively) or a
#'   character vector of files. A file with an unsupported extension is an
#'   error when named, and ignored when found in a directory.
#' @param lazy When `TRUE` (the default), parquet files are opened as Arrow
#'   Datasets and stay on disk. When `FALSE` they are read into data frames.
#' @return A named list of data frames (and Arrow Datasets for lazy parquet).
#'   A file that cannot be read gives a warning and is skipped.
#' @examples
#' \dontrun{
#' x <- sv_read_cdisc("study/sdtm")
#' sideview_widget(x)
#' }
#' @export
sv_read_cdisc <- function(path, lazy = TRUE) {
  if (!is.character(path) || !length(path) || anyNA(path)) {
    stop("`path` must be a character vector of files or a directory.", call. = FALSE)
  }
  supported <- names(sv_read_cdisc_pkg)
  files <- character()
  for (p in path) {
    if (dir.exists(p)) {
      all <- list.files(p, full.names = TRUE)
      all <- all[!dir.exists(all)]
      found <- all[tolower(tools::file_ext(all)) %in% supported]
      if (!length(found)) {
        stop(sprintf("No .xpt, .sas7bdat, .json or .parquet files in %s.", p), call. = FALSE)
      }
      files <- c(files, found)
    } else if (file.exists(p)) {
      if (!(tolower(tools::file_ext(p)) %in% supported)) {
        stop(sprintf("Unsupported file type: %s.", basename(p)), call. = FALSE)
      }
      files <- c(files, p)
    } else {
      stop(sprintf("Not found: %s.", p), call. = FALSE)
    }
  }

  exts <- tolower(tools::file_ext(files))
  pkgs <- unname(sv_read_cdisc_pkg[exts])
  for (pkg in unique(pkgs)) {
    if (!sv_has_pkg(pkg)) {
      hit <- pkgs == pkg
      stop(sprintf("Reading .%s files needs the %s package: %s.",
                   paste(unique(exts[hit]), collapse = "/."), pkg,
                   paste(basename(files[hit]), collapse = ", ")), call. = FALSE)
    }
  }

  stems <- tolower(tools::file_path_sans_ext(basename(files)))
  dup <- unique(stems[duplicated(stems)])
  if (length(dup)) {
    stop(sprintf("Two files have the stem `%s`: %s.", dup[1],
                 paste(basename(files[stems == dup[1]]), collapse = ", ")), call. = FALSE)
  }

  out <- list()
  for (i in seq_along(files)) {
    f <- files[i]
    res <- tryCatch(
      switch(exts[i],
        xpt = haven::read_xpt(f),
        sas7bdat = haven::read_sas(f),
        json = sv_read_dataset_json(f),
        parquet = if (isTRUE(lazy)) {
          ds <- arrow::open_dataset(f, format = "parquet")
          ds$schema
          ds
        } else {
          as.data.frame(arrow::read_parquet(f))
        }
      ),
      error = function(e) e
    )
    if (inherits(res, "error")) {
      warning(sprintf("Could not read %s (%s); skipped.", basename(f), conditionMessage(res)),
              call. = FALSE)
      next
    }
    if (is.data.frame(res)) res <- as.data.frame(res)
    out[[stems[i]]] <- res
  }
  out
}
