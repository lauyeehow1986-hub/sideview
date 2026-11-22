# Synthetic CDISC-shaped tables for the cdisc tests (no real data).
sv_cdisc_fixtures <- function() {
  n <- 4L
  sid <- rep("SV-001", n)
  usub <- paste0("SV-001-", sprintf("%03d", 1:n))
  dm <- data.frame(STUDYID = sid, DOMAIN = "DM", USUBJID = usub, SUBJID = sprintf("%03d", 1:n),
                   AGE = c(34, 51, 62, 45), SEX = c("F", "M", "F", "M"),
                   ARM = c("A", "B", "A", "B"), stringsAsFactors = FALSE)
  attr(dm$USUBJID, "label") <- "Unique Subject Identifier"
  attr(dm$AGE, "label") <- "Age"
  attr(dm, "label") <- "Demographics"
  ae <- data.frame(STUDYID = sid, DOMAIN = "AE", USUBJID = usub, AESEQ = 1:n,
                   AETERM = c("Headache", "Nausea", "Rash", "Cough"),
                   AEDECOD = c("HEADACHE", "NAUSEA", "RASH", "COUGH"),
                   AESEV = c("MILD", "MODERATE", "MILD", "SEVERE"),
                   AESTDTC = c("2024-01-02", "2024-01-05", "2024-02-01", "2024-02-09"),
                   stringsAsFactors = FALSE)
  suppae <- data.frame(STUDYID = sid, RDOMAIN = "AE", USUBJID = usub, IDVAR = "AESEQ",
                       IDVARVAL = as.character(1:n), QNAM = "AETRTEM",
                       QLABEL = "Treatment Emergent", QVAL = "Y", stringsAsFactors = FALSE)
  labs <- data.frame(STUDYID = sid, USUBJID = usub, LBSEQ = 1:n, LBTESTCD = "ALT",
                     LBTEST = "Alanine Aminotransferase", LBORRES = c("20", "31", "18", "40"),
                     LBORRESU = "U/L", LBDTC = "2024-01-02", stringsAsFactors = FALSE)
  ts <- data.frame(STUDYID = sid, DOMAIN = "TS", TSSEQ = 1:n,
                   TSPARMCD = c("TITLE", "PHASE", "SPONSOR", "RANDOM"),
                   TSPARM = c("Title", "Phase", "Sponsor", "Randomized"),
                   TSVAL = c("Study", "II", "Acme", "Y"), stringsAsFactors = FALSE)
  xy <- data.frame(STUDYID = sid, DOMAIN = "XY", USUBJID = usub, XYSEQ = 1:n,
                   XYTESTCD = "T1", stringsAsFactors = FALSE)
  adsl <- data.frame(STUDYID = sid, USUBJID = usub, TRT01P = c("A", "B", "A", "B"),
                     TRT01A = c("A", "B", "A", "B"), AGE = dm$AGE, SAFFL = "Y",
                     stringsAsFactors = FALSE)
  bds <- data.frame(STUDYID = rep(sid, 2), USUBJID = rep(usub, 2), PARAMCD = "ALT",
                    PARAM = "Alanine Aminotransferase", AVAL = c(20, 31, 18, 40, 22, 30, 19, 41),
                    stringsAsFactors = FALSE)
  adlb <- cbind(bds, AVISIT = rep(c("Baseline", "Week 4"), each = n))
  adtte <- cbind(bds, CNSR = rep(c(0L, 1L), 4))
  adae <- data.frame(STUDYID = sid, USUBJID = usub, AETERM = ae$AETERM, AEDECOD = ae$AEDECOD,
                     TRTA = c("A", "B", "A", "B"), stringsAsFactors = FALSE)
  # admiral-style ADaM that keeps its SDTM-prefixed columns
  adlb_pfx <- data.frame(STUDYID = rep(sid, 2), USUBJID = rep(usub, 2), LBSEQ = 1:8,
                         LBTESTCD = "ALT", LBTEST = "Alanine Aminotransferase", LBCAT = "CHEMISTRY",
                         LBORRES = as.character(c(20, 31, 18, 40, 22, 30, 19, 41)),
                         LBSTRESN = c(20, 31, 18, 40, 22, 30, 19, 41),
                         PARAMCD = "ALT", PARAM = "Alanine Aminotransferase",
                         AVAL = c(20, 31, 18, 40, 22, 30, 19, 41),
                         AVISIT = rep(c("Baseline", "Week 4"), each = n),
                         BASE = rep(c(20, 31, 18, 40), 2), CHG = c(0, 0, 0, 0, 2, -1, 1, 1),
                         stringsAsFactors = FALSE)
  adae_pfx <- data.frame(STUDYID = sid, USUBJID = usub, TRTA = c("A", "B", "A", "B"),
                         AESEQ = 1:n, AETERM = ae$AETERM, AEDECOD = ae$AEDECOD,
                         AESEV = ae$AESEV, AECAT = "GENERAL", AESTDTC = ae$AESTDTC,
                         stringsAsFactors = FALSE)
  advs_pfx <- data.frame(STUDYID = rep(sid, 2), USUBJID = rep(usub, 2), VSSEQ = 1:8,
                         VSTESTCD = "SYSBP", VSTEST = "Systolic Blood Pressure", VSCAT = "VITALS",
                         VSORRES = as.character(c(120, 130, 125, 118, 121, 129, 126, 119)),
                         VSSTRESN = c(120, 130, 125, 118, 121, 129, 126, 119),
                         PARAMCD = "SYSBP", PARAM = "Systolic Blood Pressure",
                         AVAL = c(120, 130, 125, 118, 121, 129, 126, 119),
                         stringsAsFactors = FALSE)
  send_dm <- cbind(dm, SPECIES = "RAT")
  bw <- data.frame(STUDYID = sid, DOMAIN = "BW", USUBJID = usub, BWSEQ = 1:n,
                   BWTESTCD = "BW", BWORRES = c("250", "260", "255", "270"),
                   stringsAsFactors = FALSE)
  lb <- data.frame(STUDYID = sid, DOMAIN = "LB", USUBJID = usub, LBSEQ = 1:n,
                   LBTESTCD = "ALT", VISITNUM = c(1, 1, 2, 2), stringsAsFactors = FALSE)
  vs <- data.frame(STUDYID = sid, DOMAIN = "VS", USUBJID = usub, VSSEQ = 1:n,
                   VSTESTCD = "SYSBP", VISITNUM = c(1, 1, 2, 2), stringsAsFactors = FALSE)
  sv <- data.frame(STUDYID = sid, DOMAIN = "SV", USUBJID = usub, VISITNUM = c(1, 1, 2, 2),
                   VISIT = c("Baseline", "Baseline", "Week 4", "Week 4"), stringsAsFactors = FALSE)
  relrec <- data.frame(STUDYID = sid, RDOMAIN = "AE", USUBJID = usub, IDVAR = "AESEQ",
                       IDVARVAL = as.character(1:n), RELID = "1", stringsAsFactors = FALSE)
  adsl_nostudy <- adsl[, setdiff(names(adsl), "STUDYID")]
  dm_upper_lower <- dm
  names(dm_upper_lower) <- tolower(names(dm_upper_lower))
  ae_lower <- ae
  names(ae_lower) <- tolower(names(ae_lower))
  # ---- SUPPQUAL merge fixtures (synthetic) ----
  supp_cols <- function(rd, usubjid, idvar, idvarval, qnam, qval = "Y", studyid = sid[1]) {
    data.frame(STUDYID = studyid, RDOMAIN = rd, USUBJID = usubjid, IDVAR = idvar,
               IDVARVAL = idvarval, QNAM = qnam, QLABEL = paste("Label", qnam), QVAL = qval,
               stringsAsFactors = FALSE)
  }
  suppae2 <- rbind(
    supp_cols("AE", usub[1:2], "AESEQ", c("1", "2"), "AETRTEM"),
    supp_cols("AE", usub[1:2], "", "", "AESOC2", qval = c("Skin", "Nervous")))
  ae_grp <- cbind(ae, AEGRPID = c("G1", "G1", "G2", "G3"), stringsAsFactors = FALSE)
  suppae_grp <- supp_cols("AE", usub[1:3], "AEGRPID", c("G1", "G2", "G3"), "AEGRPQ")
  cm <- data.frame(STUDYID = sid, DOMAIN = "CM", USUBJID = usub, CMSEQ = 1:n,
                   CMTRT = c("ASPIRIN", "IBUPROFEN", "PARACETAMOL", "ASPIRIN"),
                   stringsAsFactors = FALSE)
  suppqual <- rbind(
    supp_cols("AE", usub[1:2], "AESEQ", c("1", "2"), "AETRTEM"),
    supp_cols("CM", usub[1:2], "CMSEQ", c("1", "2"), "CMPRESP"))
  supp_repeat <- supp_cols("AE", usub[1], "AESEQ", c("01", "1"), "AETRTEM")
  supp_orphan <- supp_cols("AE", c(usub[1], "SV-001-999"), "AESEQ", c("1", "99"), "AETRTEM")
  supp_clash <- supp_cols("AE", usub[1:2], "AESEQ", c("1", "2"), "AESEV")
  supp_two_level <- rbind(
    supp_cols("AE", usub[1], "AESEQ", "1", "AETRTEM"),
    supp_cols("AE", usub[1], "", "", "AETRTEM"))
  supp_bad <- supp_cols("AE", usub[1:2], "AESEQ", c("x", "1.5"), "AETRTEM")
  supp_noqnam <- suppae[, setdiff(names(suppae), "QNAM")]
  suppae_nostudy <- suppae[, setdiff(names(suppae), "STUDYID")]
  supp_na_idvar <- supp_cols("AE", usub[1], NA_character_, "", "AESOC2", qval = "Skin")
  suppbw <- supp_cols("BW", usub[1:2], "BWSEQ", c("1", "2"), "BWFLAG")
  c(list(lb = lb, vs = vs, sv = sv, relrec = relrec, adsl_nostudy = adsl_nostudy,
       dm_upper_lower = dm_upper_lower, ae_lower = ae_lower,
       dm = dm, ae = ae, suppae = suppae, labs = labs, ts = ts, xy = xy, adsl = adsl,
       adlb = adlb, adtte = adtte, adae = adae, adlb_pfx = adlb_pfx,
       adae_pfx = adae_pfx, advs_pfx = advs_pfx, send_dm = send_dm, bw = bw,
       suppae2 = suppae2, ae_grp = ae_grp, suppae_grp = suppae_grp, cm = cm, suppqual = suppqual,
       supp_repeat = supp_repeat, supp_orphan = supp_orphan, supp_clash = supp_clash,
       supp_two_level = supp_two_level, supp_bad = supp_bad, supp_noqnam = supp_noqnam,
       suppae_nostudy = suppae_nostudy, supp_na_idvar = supp_na_idvar, suppbw = suppbw,
       mtcars = mtcars, iris = iris,
       ae_nostudy = ae[, setdiff(names(ae), "STUDYID")],
       studyid_only = data.frame(STUDYID = sid, x = 1:n),
       keys_only = data.frame(STUDYID = sid, USUBJID = usub, VAL = 1:n, stringsAsFactors = FALSE)),
    sv_cs_fixtures(sid[1], usub))
}

# ---- combine_supp() fixtures (synthetic): list(parent, supp) pairs ----
# The parent has two AE records for subject 1 and one for subject 2. The SUPP has the full
# SDTM column set (QORIG, no QEVAL), as an .xpt file gives it: two keyed AETRTEM rows and one
# subject-level row with IDVAR "".
sv_cs_fixtures <- function(sid, usub) {
  parent <- function(...) {
    p <- data.frame(STUDYID = sid, DOMAIN = "AE", USUBJID = usub[c(1, 1, 2)], AESEQ = c(1L, 2L, 1L),
                    AETERM = c("Headache", "Nausea", "Rash"), stringsAsFactors = FALSE)
    a <- list(...)
    for (nm in names(a)) p[[nm]] <- a[[nm]]
    p
  }
  rows <- function(usubjid, idvar, idvarval, qnam, qlabel, qval, rdomain = "AE") {
    data.frame(STUDYID = sid, RDOMAIN = rdomain, USUBJID = usubjid, IDVAR = idvar, IDVARVAL = idvarval,
               QNAM = qnam, QLABEL = qlabel, QVAL = qval, QORIG = "CRF", stringsAsFactors = FALSE)
  }
  keyed <- function(idvarval = c("1", "1"), qlabel = "Treatment Emergent", idvar = "AESEQ",
                    usubjid = usub[1:2]) {
    rows(usubjid, idvar, idvarval, "AETRTEM", qlabel, c("Y", "N"))
  }
  subj <- function(idvar = "") rows(usub[1], idvar, "", "AESUBJQ", "Subject qualifier", "Z")
  ok <- rbind(keyed(), subj())
  cm <- rows(usub[1:2], "CMSEQ", c("1", "2"), "CMPRESP", "Pre-specified", "Y", rdomain = "CM")
  grp <- c("G1", "G2", "G1")
  dbl <- function(x) parent(AESEQ = c(1, 2, x))
  list(
    cs_ok = list(parent(), ok),
    cs_na_idvar = list(parent(), rbind(keyed(), subj(NA_character_))),
    cs_suppqual = list(parent(), rbind(keyed(), cm)),
    cs_suppqual_blank_last = list(parent(), rbind(keyed(qlabel = c("Treatment Emergent", "")), cm)),
    # bad keys
    cs_key01 = list(parent(), keyed(c("01", "1"))),
    cs_key_sp = list(parent(), keyed(c(" 1 ", "1"))),
    cs_key_dec = list(parent(), keyed(c("1.0", "1"))),
    cs_key_nbsp = list(parent(), keyed(c("1\u00a0", "1"))),
    cs_key_nel = list(parent(), keyed(c("1\u0085", "1"))),
    # numeric keys: subject 2's AESEQ is the third parent row
    cs_1e5 = list(dbl(100000), keyed(c("1", "100000"))),
    cs_1e5_sci = list(dbl(100000), keyed(c("1", "1e+05"))),
    cs_110000 = list(dbl(110000), keyed(c("1", "110000"))),
    cs_frac = list(dbl(0.1 + 0.2), keyed(c("1", "0.3"))),
    # key types
    cs_int = list(parent(), keyed()),
    cs_fac = list(parent(AEGRPID = factor(grp)), keyed(c("G2", "G1"), idvar = "AEGRPID")),
    cs_chr = list(parent(AEGRPID = grp), keyed(c("G2", "G1"), idvar = "AEGRPID")),
    # combine_supp() joins DOMAIN to RDOMAIN, so its result has DOMAIN as character
    cs_fac_domain = list(parent(DOMAIN = factor("AE")), ok),
    # columns
    cs_no_qorig = list(parent(), ok[setdiff(names(ok), "QORIG")]),
    cs_qeval = list(parent(), cbind(ok, QEVAL = "", stringsAsFactors = FALSE)),
    cs_extra = list(parent(), cbind(ok, EXTRA = 1)),
    cs_no_domain = list(parent()[c("STUDYID", "USUBJID", "AESEQ", "AETERM")], ok),
    cs_no_studyid = list(parent()[c("DOMAIN", "USUBJID", "AESEQ", "AETERM")], ok),
    # labels
    cs_lab_two = list(parent(), keyed(qlabel = c("TE one", "TE two"))),
    cs_lab_blank_last = list(parent(), keyed(qlabel = c("Treatment Emergent", ""))),
    cs_lab_all_blank = list(parent(), keyed(qlabel = "")),
    cs_lab_all_na = list(parent(), keyed(qlabel = NA_character_)),
    # merge outcomes
    cs_orphan = list(parent(), keyed(c("1", "9"))),
    cs_repeat = list(parent(), keyed(usubjid = usub[c(1, 1)])),
    cs_two_level = list(parent(), rbind(keyed(), transform(subj(), QNAM = "AETRTEM"))),
    cs_clash = list(parent(AETRTEM = "x"), keyed()),
    cs_domain_lower = list(parent(DOMAIN = "ae"), subj())
  )
}

# Two merge results are the same: the same rows in the same order, the same column set (order
# ignored), the same values and classes, and the same label per column (NULL, NA and "" are none).
supp_same_result <- function(a, b) {
  a <- as.data.frame(a, stringsAsFactors = FALSE)
  b <- as.data.frame(b, stringsAsFactors = FALSE)
  if (nrow(a) != nrow(b) || ncol(a) != ncol(b) || !setequal(names(a), names(b))) return(FALSE)
  label <- function(x) {
    l <- attr(x, "label", exact = TRUE)
    if (is.null(l) || (length(l) == 1L && (is.na(l) || !nzchar(l)))) NA_character_ else l
  }
  bare <- function(x) {
    attr(x, "label") <- NULL
    x
  }
  for (nm in names(a)) {
    if (!identical(label(a[[nm]]), label(b[[nm]]))) return(FALSE)
    if (!identical(bare(a[[nm]]), bare(b[[nm]]))) return(FALSE)
  }
  TRUE
}

# Compose a pipeline holding one supp step built from the check's plan. `before` / `after` are
# JS run before / after the step is added; `meta` goes to setTables(). After the add, `style`
# goes to setStyle() and `combine` (a JS expression, e.g. "chk.combine_supp" or a JSON object;
# NULL is null) to setSuppCheck() for the step; `style = NULL` makes neither call.
supp_compose <- function(chk_json, pipe = "%>%", table = "ae", supp = "suppae", rdomain = "AE",
                         meta = "{}", before = "", after = "", style = "dplyr", combine = NULL) {
  set <- if (is.null(style)) "" else sprintf("p.setStyle(%s); p.setSuppCheck(st.key, %s);",
                                             jsonlite::toJSON(style, auto_unbox = TRUE),
                                             if (is.null(combine)) "null" else combine)
  run_pipeline_js(sprintf(
    "const p = new P.Pipeline(); p.setPipe(%s); p.setTables(%s);
     const chk = %s;
     %s
     const st = p.add(P.suppStep(%s, %s, %s, chk.plan), 'merge');
     %s
     %s
     out = p.compose();",
    jsonlite::toJSON(pipe, auto_unbox = TRUE), meta, chk_json, before,
    jsonlite::toJSON(table, auto_unbox = TRUE), jsonlite::toJSON(supp, auto_unbox = TRUE),
    jsonlite::toJSON(rdomain, auto_unbox = TRUE), set, after))
}

# What a run stops with ("" when it runs).
supp_stop <- function(code, ...) {
  tryCatch({ supp_run(code, ...); "" }, error = function(e) conditionMessage(e))
}

# Run composed code with the given tables bound by name.
supp_run <- function(code, ...) {
  skip_if_not_installed("tidyr")  # the generated code pivots with tidyr::pivot_wider()
  env <- list2env(list(...), parent = globalenv())
  env$`%>%` <- dplyr::`%>%`
  eval(parse(text = code), envir = env)
}

# Normalise a named list of tables into cards with final CDISC tags (as the gadget does).
sv_cdisc_cards <- function(tables, cdisc = "auto") {
  sv_cdisc_finalize(sv_normalize_cards(tables), cdisc)
}
