# sv_supp_check(): the merge check for SUPP-- tables (synthetic fixtures only).

fx <- sv_cdisc_fixtures()
chk <- function(supp, parent = fx$ae, sn = "suppae", ...) {
  sv_supp_check(parent, supp, parent_name = "ae", supp_name = sn, ...)
}

test_that("ok on one level", {
  r <- chk(fx$suppae)
  expect_identical(r$status, "ok")
  expect_identical(r$n_parent, 4L)
  expect_identical(r$n_supp, 4L)
  expect_identical(r$n_matched, 4L)
  expect_identical(r$n_orphan, 0L)
  expect_identical(r$n_other_rdomain, 0L)
  expect_identical(r$plan$keys, c("STUDYID", "USUBJID"))
  expect_identical(r$plan$idvars[[1]]$idvar, "AESEQ")
  expect_identical(r$plan$idvars[[1]]$type, "integer")
  expect_true(r$plan$rdomain_col)
  expect_identical(r$columns[[1]]$name, "AETRTEM")
  expect_identical(r$columns[[1]]$label, "Treatment Emergent")
  expect_identical(r$plan$qnams[[1]]$label, "Treatment Emergent")
  expect_identical(r$plan$qnams[[1]]$idvar, "AESEQ")
  expect_identical(r$repeats$n, 0L)
  expect_identical(r$clashes, character(0))
  expect_identical(r$two_level, character(0))
  expect_identical(r$bad_idvarval$n, 0L)
  expect_identical(r$drift, list(stale = FALSE, reasons = character(0)))
  expect_identical(nrow(r$preview), 4L)
  expect_identical(r$preview$AETRTEM, rep("Y", 4))
})

test_that("a card parent supplies the default rdomain", {
  card <- list(data = fx$ae, cdisc = list(domain = "AE"))
  r <- sv_supp_check(card, fx$suppqual, parent_name = "ae", supp_name = "suppqual")
  expect_identical(r$n_supp, 2L)
  expect_identical(r$n_other_rdomain, 2L)
  expect_identical(r$status, "ok")   # other domains are normal in a SUPPQUAL
})

test_that("two levels", {
  r <- chk(fx$suppae2)
  expect_identical(vapply(r$plan$idvars, `[[`, "", "idvar"), c("AESEQ", ""))
  expect_true(is.na(r$plan$idvars[[2]]$type))
  expect_identical(vapply(r$plan$qnams, `[[`, "", "qnam"), c("AETRTEM", "AESOC2"))
  expect_identical(r$plan$qnams[[2]]$idvar, "")
  expect_identical(r$n_matched, 4L)
  expect_identical(r$status, "ok")
  expect_identical(r$preview$AESOC2, c("Skin", "Nervous", NA, NA))
})

test_that("character key", {
  r <- chk(fx$suppae_grp, parent = fx$ae_grp)
  expect_identical(r$plan$idvars[[1]]$idvar, "AEGRPID")
  expect_identical(r$plan$idvars[[1]]$type, "character")
  # the fixture's group ids pair up for one subject only (G1 on SV-001-001)
  expect_identical(r$n_matched, 1L)
  expect_identical(r$n_orphan, 2L)
  f <- fx$ae_grp
  f$AEGRPID <- factor(f$AEGRPID)
  expect_identical(chk(fx$suppae_grp, parent = f)$plan$idvars[[1]]$type, "character")
})

test_that("repeat after conversion", {
  r <- chk(fx$supp_repeat)
  expect_identical(r$status, "error")
  expect_identical(r$repeats$n, 1L)
  expect_identical(nrow(r$repeats$samples), 1L)
  expect_identical(names(r$repeats$samples), c("USUBJID", "IDVAR", "IDVARVAL", "QNAM"))
})

test_that("orphans warn", {
  r <- chk(fx$supp_orphan)
  expect_identical(r$status, "warning")
  expect_identical(r$n_orphan, 1L)
  expect_identical(r$n_matched, 1L)
  expect_identical(names(r$orphan_samples), c("USUBJID", "IDVAR", "IDVARVAL", "QNAM"))
  expect_identical(r$orphan_samples$USUBJID, "SV-001-999")
  expect_identical(r$orphan_samples$IDVARVAL, "99")
  expect_identical(r$n_matched + r$n_orphan + r$bad_idvarval$n, r$n_supp)
})

test_that("clash", {
  r <- chk(fx$supp_clash)
  expect_identical(r$clashes, "AESEV")
  expect_identical(r$status, "error")
})

test_that("two_level", {
  r <- chk(fx$supp_two_level)
  expect_identical(r$two_level, "AETRTEM")
  expect_identical(r$status, "error")
})

test_that("bad_idvarval", {
  r <- chk(fx$supp_bad)
  expect_identical(r$bad_idvarval$n, 2L)
  expect_identical(r$n_orphan, 0L)
  expect_identical(r$status, "warning")
  expect_identical(r$bad_idvarval$samples$IDVARVAL, c("x", "1.5"))
  expect_identical(r$n_matched + r$n_orphan + r$bad_idvarval$n, r$n_supp)
  dbl <- fx$ae
  dbl$AESEQ <- as.numeric(dbl$AESEQ)
  rd <- chk(fx$supp_bad, parent = dbl)
  expect_identical(rd$plan$idvars[[1]]$type, "double")
  expect_identical(rd$bad_idvarval$n, 1L)
  expect_identical(rd$bad_idvarval$samples$IDVARVAL, "x")
  expect_identical(rd$n_orphan, 1L)   # 1.5 converts, but finds no record
})

test_that("missing column", {
  expect_identical(chk(fx$supp_noqnam), list(error = "Not in suppae: QNAM"))
  expect_identical(chk(fx$suppae_grp), list(error = "Not in ae: AEGRPID"))
  p <- fx$ae
  p$USUBJID <- NULL
  expect_identical(chk(fx$suppae, parent = p), list(error = "Not in ae: USUBJID"))
})

test_that("no STUDYID", {
  r <- chk(fx$suppae_nostudy)
  expect_identical(r$plan$keys, "USUBJID")
  expect_identical(r$n_matched, 4L)
  r2 <- chk(fx$suppae, parent = fx$ae_nostudy)
  expect_identical(r2$plan$keys, "USUBJID")
})

test_that("NA IDVAR is subject level", {
  r <- chk(fx$supp_na_idvar)
  expect_identical(length(r$plan$idvars), 1L)
  expect_identical(r$plan$idvars[[1]]$idvar, "")
  expect_true(is.na(r$plan$idvars[[1]]$type))
  expect_identical(r$n_matched, 1L)
  expect_identical(r$status, "ok")
})

test_that("no rows for rdomain", {
  expect_identical(sv_supp_check(fx$ae, fx$suppqual, parent_name = "ae", supp_name = "suppqual",
                                 rdomain = "LB"),
                   list(error = "suppqual has no rows for LB"))
})

test_that("other RDOMAIN rows warn only in a SUPPxx card", {
  mixed <- rbind(fx$suppae, fx$suppbw)
  r <- chk(mixed)
  expect_identical(r$n_other_rdomain, 2L)
  expect_identical(r$n_supp, 4L)
  expect_identical(r$status, "warning")
  noRd <- fx$suppae[, setdiff(names(fx$suppae), "RDOMAIN")]
  r2 <- chk(noRd)
  expect_identical(r2$n_other_rdomain, 0L)
  expect_false(r2$plan$rdomain_col)
})

test_that("unsupported type", {
  ae <- fx$ae
  ae$AESTDTC <- as.Date(ae$AESTDTC)
  s <- data.frame(STUDYID = "SV-001", RDOMAIN = "AE", USUBJID = "SV-001-001", IDVAR = "AESTDTC",
                  IDVARVAL = "2024-01-02", QNAM = "X", QLABEL = "x", QVAL = "Y",
                  stringsAsFactors = FALSE)
  expect_identical(chk(s, parent = ae),
                   list(error = "Cannot merge on AESTDTC: its type is Date"))
})

test_that("sv_supp_key_type", {
  expect_identical(sv_supp_key_type(1L), "integer")
  expect_identical(sv_supp_key_type(1), "double")
  expect_identical(sv_supp_key_type("a"), "character")
  expect_identical(sv_supp_key_type(factor("a")), "character")
  expect_identical(sv_supp_key_type(structure(1, class = "integer64")), "double")
  expect_true(is.na(sv_supp_key_type(Sys.Date())))
  expect_true(is.na(sv_supp_key_type(TRUE)))
})

test_that("drift", {
  base <- chk(fx$suppae2)$plan
  p <- base
  p$qnams <- p$qnams[-1]
  expect_identical(chk(fx$suppae2, plan = p)$drift,
                   list(stale = TRUE, reasons = "New QNAM: AETRTEM"))
  p <- base
  p$idvars <- p$idvars[-1]
  expect_identical(chk(fx$suppae2, plan = p)$drift$reasons, "New IDVAR: AESEQ")
  p <- base
  p$qnams <- c(p$qnams, list(list(qnam = "ZZ", label = "", idvar = "")))
  expect_identical(chk(fx$suppae2, plan = p)$drift$reasons, "QNAM gone: ZZ")
  p <- base
  p$idvars[[1]]$type <- "double"
  expect_identical(chk(fx$suppae2, plan = p)$drift$reasons,
                   "AESEQ type changed from double to integer")
  fresh <- chk(fx$suppae2, plan = base)
  expect_false(fresh$drift$stale)
  # the plan in the result always describes the data
  p <- base
  p$qnams <- p$qnams[-1]
  expect_identical(chk(fx$suppae2, plan = p)$plan, base)
})

test_that("json keeps arrays", {
  j <- jsonlite::fromJSON(sv_supp_check_json(chk(fx$suppae_grp, parent = fx$ae_grp)),
                          simplifyVector = FALSE)
  expect_true(is.list(j$plan$keys))
  expect_identical(length(j$plan$keys), 2L)
  expect_true(is.list(j$plan$idvars))
  expect_true(is.list(j$clashes))
  expect_true(is.list(j$two_level))
  expect_true(is.list(j$drift$reasons))
  expect_true(is.list(j$orphan_samples))
  expect_true(is.list(j$columns))
  expect_identical(length(j$columns), 1L)
  one <- sv_supp_check_json(chk(fx$supp_na_idvar))
  expect_match(one, "\"type\":null", fixed = TRUE)
  expect_identical(sv_supp_check_json(list(error = "Not in suppae: QNAM")),
                   "{\"error\":\"Not in suppae: QNAM\"}")
  jc <- jsonlite::fromJSON(sv_supp_check_json(chk(fx$supp_clash)), simplifyVector = FALSE)
  expect_identical(jc$clashes, list("AESEV"))
})

test_that("a QNAM with no QLABEL gets an empty label", {
  s <- fx$suppae[, setdiff(names(fx$suppae), "QLABEL")]
  r <- chk(s)
  expect_identical(r$plan$qnams[[1]]$label, "")
  expect_identical(r$columns[[1]]$label, "")
  expect_match(sv_supp_check_json(r), "\"label\":\"\"", fixed = TRUE)
})

# ---- JS twin: SideviewPipeline.suppCheck ------------------------------------

test_that("suppKeyType maps col_types", {
  types <- list(integer = c("integer", "int8", "int16", "int32"),
                double = c("numeric", "double", "float", "int64", "integer64"),
                character = c("character", "factor", "string", "utf8", "large_utf8",
                              "dictionary<values=string, indices=int32>"))
  for (want in names(types)) {
    for (ty in types[[want]]) {
      js <- run_pipeline_js(sprintf("out = P.suppKeyType(%s);", jsonlite::toJSON(ty, auto_unbox = TRUE)))
      expect_identical(js, want, info = ty)
    }
  }
  for (ty in c("Date", "logical", "POSIXct", "")) {
    js <- run_pipeline_js(sprintf("out = P.suppKeyType(%s);", jsonlite::toJSON(ty, auto_unbox = TRUE)))
    expect_null(js, info = ty)
  }
})

# Sort names recursively so list order cannot matter.
supp_canon <- function(x) {
  if (is.list(x)) {
    if (!is.null(names(x))) x <- x[order(names(x))]
    return(lapply(x, supp_canon))
  }
  x
}

supp_js <- function(parent, supp, supp_name = "suppae", rdomain = NULL, plan = NULL,
                    sample_n = 5L, parent_name = "ae") {
  types <- lapply(parent, function(col) class(col)[1])
  opts <- list(parentName = parent_name, suppName = supp_name, parentTypes = types,
               sampleN = sample_n, parentCols = names(parent), suppCols = names(supp))
  if (!is.null(rdomain)) opts$rdomain <- rdomain
  if (!is.null(plan)) opts$plan <- plan
  rows <- function(d) {
    rownames(d) <- NULL
    jsonlite::toJSON(d, dataframe = "rows", na = "null")
  }
  run_pipeline_js(sprintf(
    "out = P.suppCheck(%s, %s, %s);", rows(parent), rows(supp),
    jsonlite::toJSON(opts, auto_unbox = TRUE, na = "null", null = "null")))
}

supp_parity <- function(label, parent, supp, supp_name = "suppae", rdomain = NULL, plan = NULL) {
  r <- sv_supp_check(parent, supp, parent_name = "ae", supp_name = supp_name, rdomain = rdomain,
                     plan = plan)
  want <- jsonlite::fromJSON(sv_supp_check_json(r), simplifyVector = FALSE)
  got <- supp_js(parent, supp, supp_name, rdomain, plan)
  expect_equal(supp_canon(got), supp_canon(want), info = label)
  invisible(want)
}

test_that("suppCheck matches sv_supp_check", {
  skip_if_not_installed("jsonlite")
  f <- fx
  dbl <- f$ae
  dbl$AESEQ <- as.numeric(dbl$AESEQ)
  fac <- f$ae_grp
  fac$AEGRPID <- factor(fac$AEGRPID)
  dated <- f$ae
  dated$AESTDTC <- as.Date(dated$AESTDTC)
  datedsupp <- data.frame(STUDYID = "SV-001", RDOMAIN = "AE", USUBJID = "SV-001-001",
                          IDVAR = "AESTDTC", IDVARVAL = "2024-01-02", QNAM = "X", QLABEL = "x",
                          QVAL = "Y", stringsAsFactors = FALSE)
  nop <- f$ae
  nop$USUBJID <- NULL
  base <- sv_supp_check(f$ae, f$suppae2, supp_name = "suppae")$plan
  p_q <- base; p_q$qnams <- p_q$qnams[-1]
  p_i <- base; p_i$idvars <- p_i$idvars[-1]
  p_g <- base; p_g$qnams <- c(p_g$qnams, list(list(qnam = "ZZ", label = "", idvar = "")))
  p_t <- base; p_t$idvars[[1]]$type <- "double"
  no_label <- f$suppae[, setdiff(names(f$suppae), "QLABEL")]
  no_rd <- f$suppae[, setdiff(names(f$suppae), "RDOMAIN")]

  cases <- list(
    ok = list(f$ae, f$suppae),
    card_like_suppqual = list(f$ae, f$suppqual, "suppqual", "AE"),
    no_rows_for_rdomain = list(f$ae, f$suppqual, "suppqual", "LB"),
    two_levels = list(f$ae, f$suppae2),
    character_key = list(f$ae_grp, f$suppae_grp),
    factor_key = list(fac, f$suppae_grp),
    repeat_after_conversion = list(f$ae, f$supp_repeat),
    orphans = list(f$ae, f$supp_orphan),
    clash = list(f$ae, f$supp_clash),
    two_level = list(f$ae, f$supp_two_level),
    bad_integer = list(f$ae, f$supp_bad),
    bad_double = list(dbl, f$supp_bad),
    missing_qnam = list(f$ae, f$supp_noqnam),
    missing_parent_col = list(f$ae, f$suppae_grp),
    missing_parent_usubjid = list(nop, f$suppae),
    no_studyid_supp = list(f$ae, f$suppae_nostudy),
    no_studyid_parent = list(f$ae_nostudy, f$suppae),
    na_idvar = list(f$ae, f$supp_na_idvar),
    mixed_rdomain_warns = list(f$ae, rbind(f$suppae, f$suppbw)),
    no_rdomain_col = list(f$ae, no_rd),
    unsupported_type = list(dated, datedsupp),
    no_qlabel = list(f$ae, no_label),
    drift_new_qnam = list(f$ae, f$suppae2, "suppae", NULL, p_q),
    drift_new_idvar = list(f$ae, f$suppae2, "suppae", NULL, p_i),
    drift_qnam_gone = list(f$ae, f$suppae2, "suppae", NULL, p_g),
    drift_type = list(f$ae, f$suppae2, "suppae", NULL, p_t),
    drift_fresh = list(f$ae, f$suppae2, "suppae", NULL, base)
  )
  for (nm in names(cases)) {
    a <- cases[[nm]]
    supp_parity(nm, a[[1]], a[[2]], if (length(a) > 2) a[[3]] else "suppae",
                if (length(a) > 3) a[[4]] else NULL, if (length(a) > 4) a[[5]] else NULL)
  }

  # sample_n truncates samples and the preview alike
  s <- f$supp_orphan[rep(2, 8), ]
  s$QNAM <- paste0("Q", 1:8)
  r <- sv_supp_check(f$ae, s, parent_name = "ae", supp_name = "suppae", sample_n = 3L)
  got <- supp_js(f$ae, s, sample_n = 3L)
  expect_equal(supp_canon(got), supp_canon(jsonlite::fromJSON(sv_supp_check_json(r),
                                                                 simplifyVector = FALSE)))
  expect_length(got$orphan_samples, 3L)
  expect_length(got$preview, 3L)
})

test_that("suppCheck follows R on NA keys", {
  # an NA key becomes the string "NA" on both sides, so NA matches NA
  ae <- fx$ae
  ae$USUBJID[2] <- NA
  s <- fx$suppae
  s$USUBJID[2] <- NA
  s$IDVARVAL[3] <- NA
  w <- supp_parity("na_keys", ae, s)
  expect_identical(w$bad_idvarval$n, 1L)
  expect_identical(w$n_matched, 3L)
  ae2 <- fx$ae_grp
  ae2$AEGRPID[1] <- NA
  s2 <- fx$suppae_grp
  s2$IDVARVAL[1] <- "NA"
  supp_parity("na_character_key", ae2, s2)
  s3 <- fx$suppae_grp
  s3$IDVARVAL[2] <- NA
  supp_parity("na_idvarval_character", fx$ae_grp, s3)
})

test_that("odd numeric IDVARVAL strings are treated alike in R and JS", {
  dbl <- fx$ae
  dbl$AESEQ <- c(1, 16, 1000, 0.5)
  odd <- c("1e3", "0x10", "Inf", "1d3", "", " 1 ", "+.5", "1.", "NaN", "1e", "TRUE", "1,5")
  s <- fx$suppae[rep(1, length(odd)), ]
  s$IDVARVAL <- odd
  s$QNAM <- paste0("Q", seq_along(odd))
  w <- supp_parity("odd_double", dbl, s)
  # only ordinary decimal / exponent forms convert
  expect_identical(w$bad_idvarval$n, 8L)
  int <- fx$ae
  oddi <- c("99999999999", "-2147483648", "2147483647", " 7 ", "+3", "1.0", "1e3", "0x10", "01", "")
  si <- fx$suppae[rep(1, length(oddi)), ]
  si$IDVARVAL <- oddi
  si$QNAM <- paste0("Q", seq_along(oddi))
  supp_parity("odd_integer", int, si)
})

# ---- server, Auto Map rows, join note (Task 6) ----

test_that("server answers supp_check_request", {
  cards <- sv_normalize_cards(list(ae = fx$ae, suppae = fx$suppae))
  shiny::testServer(sideview_server(cards), {
    session$setInputs(supp_check_request = list(id = "r1", parent = "ae", supp = "suppae"))
    msgs <- session$userData$custom_messages
    last <- msgs[[length(msgs)]]
    expect_identical(last$type, "sideview_supp_check")
    expect_identical(last$message$id, "r1")
    expect_identical(last$message$status, "ok")
    expect_true(length(last$message$plan) > 0)
    # the plan from the reply, as JSON text, gives a drift of "not stale"
    plan_json <- as.character(jsonlite::toJSON(sv_supp_check(fx$ae, fx$suppae, "ae", "suppae")$plan,
                                               auto_unbox = TRUE))
    session$setInputs(supp_check_request = list(id = "r2", parent = "ae", supp = "suppae", plan = plan_json))
    msgs <- session$userData$custom_messages
    last <- msgs[[length(msgs)]]
    expect_identical(last$message$id, "r2")
    expect_false(last$message$drift$stale)
  })
})

test_that("server takes the step's rdomain hint only where the tags allow it", {
  last_reply <- function(session) {
    msgs <- session$userData$custom_messages
    msgs[[length(msgs)]]$message
  }
  ask <- function(session, id, rdomain = NULL) {
    req <- list(id = id, parent = "ae", supp = "suppqual")
    if (!is.null(rdomain)) req$rdomain <- rdomain
    session$setInputs(supp_check_request = req)
    last_reply(session)
  }
  n_ae <- sum(fx$suppqual$RDOMAIN == "AE")
  # no tags (cdisc = FALSE): a re-check needs the hint, the name alone gives "QUAL"
  plain <- sv_cdisc_cards(list(ae = fx$ae, suppqual = fx$suppqual), cdisc = FALSE)
  expect_null(plain[[2]]$cdisc)
  shiny::testServer(sideview_server(plain, cdisc = FALSE), {
    expect_identical(ask(session, "h1")$error, "suppqual has no rows for QUAL")
    r <- ask(session, "h2", "AE")
    expect_identical(r$id, "h2")
    expect_identical(r$status, "ok")
    expect_identical(r$n_supp, n_ae)
  })
  # tagged: a hint in the card's rdomains is taken, any other is ignored (the tags decide)
  tagged <- sv_cdisc_cards(list(ae = fx$ae, suppqual = fx$suppqual))
  expect_true(all(c("AE", "CM") %in% unlist(tagged[[2]]$cdisc$rdomains)))
  shiny::testServer(sideview_server(tagged), {
    expect_identical(ask(session, "h3")$n_supp, n_ae)
    # CM is one of the card's RDOMAINs, so it is taken (and AE has no CMSEQ)
    expect_identical(ask(session, "h4", "CM")$error, "Not in ae: CMSEQ")
    expect_identical(ask(session, "h5", "ZZ")$n_supp, n_ae)
    expect_identical(ask(session, "h6", "x); stop(")$n_supp, n_ae)
  })
  expect_identical(sv_supp_rdomain_hint(list(cdisc = NULL), " ae "), "AE")
  expect_null(sv_supp_rdomain_hint(list(cdisc = NULL), c("AE", "CM")))
  expect_null(sv_supp_rdomain_hint(list(cdisc = list(rdomains = list())), "AE"))
})

test_that("server supp error for an unknown card", {
  cards <- sv_normalize_cards(list(ae = fx$ae, suppae = fx$suppae))
  shiny::testServer(sideview_server(cards), {
    session$setInputs(supp_check_request = list(id = "r9", parent = "ae", supp = "nope"))
    msgs <- session$userData$custom_messages
    last <- msgs[[length(msgs)]]
    expect_identical(last$type, "sideview_supp_check")
    expect_identical(last$message$id, "r9")
    expect_identical(last$message$error, "Not in the canvas: nope")
  })
})

test_that("supp rows in suggest_mappings", {
  cards <- sv_cdisc_cards(list(ae = fx$ae, suppae = fx$suppae))
  m <- sv_suggest_mappings(cards)
  s <- m[which(m$kind == "supp"), ]
  expect_equal(nrow(s), 1L)
  expect_identical(s$from_table, "suppae")
  expect_identical(s$from_col, "USUBJID")
  expect_identical(s$to_table, "ae")
  expect_identical(s$to_col, "USUBJID")
  expect_identical(s$confidence, 1)
  expect_identical(s$group, "cdisc:suppae~ae")
  expect_identical(s$reason, "CDISC SUPP merge: suppae holds qualifiers for AE")
  # no heuristic row for the pair, and the supp row comes after the rule rows
  pair <- m[(m$from_table == "suppae" & m$to_table == "ae") | (m$from_table == "ae" & m$to_table == "suppae"), ]
  expect_equal(nrow(pair), 1L)
  off <- sv_suggest_mappings(sv_normalize_cards(list(ae = fx$ae, suppae = fx$suppae)), cdisc = FALSE)
  expect_false("supp" %in% off$kind)
})

test_that("supp note replaces summarise", {
  cards <- sv_cdisc_cards(list(ae = fx$ae, suppae = fx$suppae))
  want <- "SUPPAE has one row per qualifier: use Merge into AE on the SUPPAE card (one column per QNAM) instead of a join."
  expect_identical(sv_keys_m2m_note(cards[[1]], cards[[2]], "USUBJID"), want)
  expect_identical(sv_keys_m2m_note(cards[[2]], cards[[1]], "USUBJID"), want)
  diag <- list(relationship = "many-to-many")
  expect_identical(sv_cdisc_key_notes(cards[[2]], cards[[1]], "USUBJID", "USUBJID", diag)[1], want)
})
