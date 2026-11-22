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
  expect_identical(chk(fx$supp_noqnam)$error, "Not in suppae: QNAM")
  expect_identical(chk(fx$suppae_grp)$error, "Not in ae: AEGRPID")
  p <- fx$ae
  p$USUBJID <- NULL
  expect_identical(chk(fx$suppae, parent = p)$error, "Not in ae: USUBJID")
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
                                 rdomain = "LB")$error,
                   "suppqual has no rows for LB")
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
  expect_identical(chk(s, parent = ae)$error, "Cannot merge on AESTDTC: its type is Date")
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

# ---- combine_supp: would metatools::combine_supp() give the dplyr code's result? ----

cs <- function(name, ...) { f <- fx[[name]]; chk(f[[2]], parent = f[[1]], ...)$combine_supp }

test_that("combine_supp field: eligible cases and prep", {
  expect_true(cs("cs_ok")$ok); expect_null(cs("cs_ok")$reason)
  expect_true(cs("cs_ok")$prep$idvar_na); expect_false(cs("cs_ok")$prep$rdomain)
  expect_false(cs("cs_na_idvar")$prep$idvar_na)
  q <- chk(fx$cs_suppqual[[2]], parent = fx$cs_suppqual[[1]], sn = "suppqual", rdomain = "AE")$combine_supp
  expect_true(q$ok); expect_true(q$prep$rdomain)
  for (n in c("cs_qeval", "cs_int", "cs_chr", "cs_1e5_sci", "cs_110000", "cs_orphan",
              "cs_lab_all_blank", "cs_lab_all_na")) expect_true(cs(n)$ok, info = n)
  # str_trim() and the integer conversion both drop the spaces; "1.0" finds no record in either
  for (n in c("cs_key_sp", "cs_key_dec", "cs_na_idvar")) expect_true(cs(n)$ok, info = n)
  # whitespace-only IDVAR is subject level too, and needs the same prep
  s <- fx$cs_ok[[2]]
  s$IDVAR[s$IDVAR == ""] <- " \t"
  expect_true(chk(s, parent = fx$cs_ok[[1]])$combine_supp$prep$idvar_na)
})

test_that("combine_supp field: reasons, in rule order", {
  expect_equal(cs("cs_no_qorig")$reason, "suppae has no QORIG column")
  expect_equal(cs("cs_extra")$reason, "suppae has extra columns: EXTRA")
  expect_equal(cs("cs_no_domain")$reason, "ae has no DOMAIN column")
  expect_equal(cs("cs_no_studyid")$reason, "ae has no STUDYID column")
  expect_equal(cs("cs_key01")$reason, 'IDVARVAL "01" would not match AESEQ 1 in combine_supp()')
  expect_equal(cs("cs_1e5")$reason, 'IDVARVAL "100000" would not match AESEQ 1e+05 in combine_supp()')
  expect_equal(cs("cs_key_nbsp")$reason, 'IDVARVAL "1\u00a0" would match AESEQ 1 in combine_supp()')
  expect_equal(cs("cs_key_nel")$reason, 'IDVARVAL "1\u0085" would match AESEQ 1 in combine_supp()')
  # as.character(0.1 + 0.2) is "0.3": the text matches, the number (0.30000000000000004) does not
  expect_equal(cs("cs_frac")$reason, 'IDVARVAL "0.3" would match AESEQ 0.3 in combine_supp()')
  # the dplyr code joins a factor key to the text IDVARVAL, so its result has the key as character
  expect_equal(cs("cs_fac")$reason, "AEGRPID would be a factor in combine_supp(), not text")
  expect_equal(cs("cs_fac_domain")$reason, "DOMAIN would be text in combine_supp(), not a factor")
  expect_equal(cs("cs_lab_two")$reason, 'AETRTEM label would be "TE two" in combine_supp(), not "TE one"')
  expect_equal(cs("cs_lab_blank_last")$reason, 'AETRTEM label would be none in combine_supp(), not "Treatment Emergent"')
  expect_match(cs("cs_clash")$reason, "^The merge stops: AETRTEM already in ae$")
  expect_match(cs("cs_repeat")$reason, "^The merge stops: 1 repeated QNAM record$")
  expect_match(cs("cs_two_level")$reason, "^The merge stops: AETRTEM on two IDVAR levels$")
  expect_match(cs("cs_domain_lower")$reason, "would not match in combine_supp\\(\\)$")
  expect_equal(cs("cs_domain_lower")$reason, "SV-001-001 would not match in combine_supp()")
  for (n in c("cs_no_qorig", "cs_key01", "cs_lab_two", "cs_clash")) expect_false(cs(n)$ok, info = n)
  # combine_supp() keeps the last of the distinct labels in order of first appearance
  s <- fx$cs_lab_two[[2]][c(1, 2, 1), ]
  s$USUBJID <- fx$cs_ok[[1]]$USUBJID
  s$IDVARVAL <- c("1", "2", "1")
  expect_equal(chk(s, parent = fx$cs_ok[[1]])$combine_supp$reason,
               'AETRTEM label would be "TE two" in combine_supp(), not "TE one"')
  # two parent records for one keyed row: a different record set, not a missing one
  p <- fx$cs_chr[[1]]
  p$AEGRPID <- c(" G1", "G1", "G1")
  s <- fx$cs_chr[[2]][1, ]
  s$IDVARVAL <- "G1"
  expect_equal(chk(s, parent = p)$combine_supp$reason,
               'IDVARVAL "G1" would match a different ae record in combine_supp()')
  # the stop reason lists every part, in order
  r <- list(repeats = list(n = 2L), clashes = c("A", "B"), two_level = "C")
  expect_identical(sv_supp_combine_stop_reason(r, "ae"),
                   "The merge stops: 2 repeated QNAM records; A, B already in ae; C on two IDVAR levels")
})

test_that("combine_supp field ignores the session's scipen and restores it", {
  withr::local_options(scipen = 999)
  expect_equal(cs("cs_1e5")$reason, 'IDVARVAL "100000" would not match AESEQ 1e+05 in combine_supp()')
  expect_true(cs("cs_1e5_sci")$ok)
  expect_equal(getOption("scipen"), 999)
})

test_that("combine_supp field reads a numeric key column the same under any scipen", {
  f <- fx$cs_ok
  ids <- c(100000, 200000)
  p <- f[[1]]
  p$USUBJID <- ids[match(p$USUBJID, unique(p$USUBJID))]
  s <- f[[2]]
  s$USUBJID <- ids[match(s$USUBJID, unique(f[[1]]$USUBJID))]
  at0 <- withr::with_options(list(scipen = 0), chk(s, parent = p)$combine_supp)
  expect_true(at0$ok)
  expect_identical(withr::with_options(list(scipen = 999), chk(s, parent = p)$combine_supp), at0)
})

test_that("blank last AE label in a SUPPQUAL counts after the RDOMAIN filter", {
  f <- fx$cs_suppqual_blank_last
  want <- 'AETRTEM label would be none in combine_supp(), not "Treatment Emergent"'
  r <- chk(f[[2]], parent = f[[1]], sn = "suppqual", rdomain = "AE")$combine_supp
  expect_false(r$ok)
  expect_true(r$prep$rdomain)
  expect_equal(r$reason, want)
  # a CM row after it with the same QNAM and a label is filtered out, so it does not count
  cm <- f[[2]][f[[2]]$RDOMAIN == "CM", ][1, ]
  cm$QNAM <- "AETRTEM"
  cm$QLABEL <- "Treatment Emergent"
  r2 <- chk(rbind(f[[2]], cm), parent = f[[1]], sn = "suppqual", rdomain = "AE")$combine_supp
  expect_equal(r2$reason, want)
})

test_that("sv_str_trim matches stringr::str_trim", {
  skip_if_not_installed("stringr")
  x <- paste0(c(" ", "\t", "\u00a0", "\u0085", "\u3000", "\ufeff", "\u2028"), "1", " ")
  expect_identical(sideview:::sv_str_trim(x), stringr::str_trim(x))
  # every BMP code point on either side; stringi drops one leading BOM before it trims
  cps <- c(1:0xD7FF, 0xE000:0xFFFF)
  ch <- intToUtf8(cps, multiple = TRUE)
  y <- c(paste0(ch, "1"), paste0("1", ch), paste0("\ufeff\ufeff", ch, "1"), " \ufeff1", NA)
  expect_identical(sideview:::sv_str_trim(y), stringr::str_trim(y))
})

test_that("sv_r_chr is as.character() under scipen 0", {
  withr::local_options(scipen = 999)
  expect_identical(sideview:::sv_r_chr(c(100000, 110000, 0.1 + 0.2, 1 / 3)),
                   c("1e+05", "110000", "0.3", "0.333333333333333"))
  expect_identical(sideview:::sv_r_chr(factor("G1")), "G1")
  expect_equal(getOption("scipen"), 999)
})

test_that("print and JSON carry the line and the field", {
  expect_match(paste(capture.output(print(chk(fx$cs_key01[[2]], parent = fx$cs_key01[[1]]))), collapse = "\n"),
               'combine_supp\\(\\): no, IDVARVAL "01"')
  expect_identical(utils::tail(capture.output(print(chk(fx$cs_ok[[2]], parent = fx$cs_ok[[1]]))), 1),
                   "combine_supp(): yes")
  expect_identical(utils::tail(capture.output(print(chk(fx$supp_noqnam))), 1),
                   "combine_supp(): no, Not in suppae: QNAM")
  j <- jsonlite::fromJSON(sv_supp_check_json(chk(fx$cs_ok[[2]], parent = fx$cs_ok[[1]])), simplifyVector = FALSE)
  expect_equal(j$combine_supp, list(ok = TRUE, reason = NULL, prep = list(rdomain = FALSE, idvar_na = TRUE)))
  expect_match(sv_supp_check_json(chk(fx$cs_ok[[2]], parent = fx$cs_ok[[1]])),
               '"combine_supp":{"ok":true,"reason":null,"prep":{"rdomain":false,"idvar_na":true}}', fixed = TRUE)
  expect_identical(sideview:::sv_supp_combine_of(list(error = "x")),
                   list(ok = FALSE, reason = "x", prep = list(rdomain = FALSE, idvar_na = FALSE)))
})

# The tables a fixture's check and merges need: the parent, the SUPP, the SUPP's name.
cs_case <- function(name) {
  f <- fx[[name]]
  sn <- if (grepl("suppqual", name)) "suppqual" else "suppae"
  r <- sv_supp_check(f[[1]], f[[2]], parent_name = "ae", supp_name = sn, rdomain = "AE")
  list(parent = f[[1]], supp = f[[2]], sn = sn, chk = r, field = r$combine_supp)
}

# metatools::combine_supp() on the SUPP after the field's prep lines; or the error it stops with.
cs_theirs <- function(k) {
  s <- k$supp
  if (k$field$prep$rdomain) s <- dplyr::filter(s, RDOMAIN == "AE")
  if (k$field$prep$idvar_na) s <- dplyr::mutate(s, IDVAR = dplyr::na_if(trimws(IDVAR), ""))
  tryCatch(suppressWarnings(metatools::combine_supp(k$parent, s)), error = function(e) e)
}

# The 0.7.0 dplyr code's result for the fixture.
cs_ours <- function(k) {
  code <- supp_compose(sv_supp_check_json(k$chk), supp = k$sn)
  do.call(supp_run, c(list(code), stats::setNames(list(k$parent, k$supp), c("ae", k$sn))))
}

cs_names <- function() grep("^cs_", names(fx), value = TRUE)

test_that("not-ok fixtures: the real combine_supp() errors or differs", {
  skip_if_not_installed("metatools", "0.3.0")
  skip_if_not_installed("tidyr")
  n_seen <- 0L
  for (nm in cs_names()) {
    k <- cs_case(nm)
    if (k$field$ok || startsWith(k$field$reason, "The merge stops: ")) next
    n_seen <- n_seen + 1L
    theirs <- cs_theirs(k)
    if (inherits(theirs, "error")) {
      succeed()
      next
    }
    expect_false(supp_same_result(theirs, cs_ours(k)), info = nm)
  }
  expect_identical(n_seen, 15L)
})

test_that("ok fixtures: the real combine_supp() gives the dplyr code's result", {
  skip_if_not_installed("metatools", "0.3.0")
  skip_if_not_installed("tidyr")
  n_seen <- 0L
  for (nm in cs_names()) {
    k <- cs_case(nm)
    if (!k$field$ok) next
    n_seen <- n_seen + 1L
    theirs <- cs_theirs(k)
    expect_false(inherits(theirs, "error"), info = nm)
    if (!inherits(theirs, "error")) expect_true(supp_same_result(theirs, cs_ours(k)), info = nm)
  }
  expect_identical(n_seen, 13L)
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
                    sample_n = 5L, parent_name = "ae", extra = list(), wire = "exact") {
  types <- lapply(parent, function(col) class(col)[1])
  opts <- list(parentName = parent_name, suppName = supp_name, parentTypes = types,
               suppTypes = lapply(supp, function(col) class(col)[1]),
               sampleN = sample_n, parentCols = names(parent), suppCols = names(supp))
  if (!is.null(rdomain)) opts$rdomain <- rdomain
  if (!is.null(plan)) opts$plan <- plan
  # wire = "widget": rows as the widget payload sends them (htmlwidgets' toJSON2: 16 significant
  # digits; NA, Inf and NaN as null), with `rounded: true` and each card's `col_inexact` as the
  # engine passes them
  if (identical(wire, "widget")) {
    opts$rounded <- TRUE
    opts$inexact <- list(parent = I(sv_inexact_cols(parent)), supp = I(sv_inexact_cols(supp)))
  }
  opts[names(extra)] <- extra
  # else 17 significant digits, so the browser gets the very doubles R has (0.1 + 0.2, not 0.3)
  rows <- function(d) {
    rownames(d) <- NULL
    if (identical(wire, "widget")) {
      return(jsonlite::toJSON(d, dataframe = "rows", na = "null", null = "null", auto_unbox = TRUE,
                              digits = 16, use_signif = TRUE))
    }
    jsonlite::toJSON(d, dataframe = "rows", na = "null", digits = I(17))
  }
  run_pipeline_js(sprintf(
    "out = P.suppCheck(%s, %s, %s);", rows(parent), rows(supp),
    jsonlite::toJSON(opts, auto_unbox = TRUE, na = "null", null = "null")))
}

supp_parity <- function(label, parent, supp, supp_name = "suppae", rdomain = NULL, plan = NULL,
                        js_reason = NULL) {
  r <- sv_supp_check(parent, supp, parent_name = "ae", supp_name = supp_name, rdomain = rdomain,
                     plan = plan)
  want <- jsonlite::fromJSON(sv_supp_check_json(r), simplifyVector = FALSE)
  got <- supp_js(parent, supp, supp_name, rdomain, plan)
  # `installed` is the server's (R adds it to the reply; the browser sends null)
  want$combine_supp$installed <- NULL
  got$combine_supp$installed <- NULL
  # the browser's combine_supp may be not ok where R is sure (an IDVARVAL R_strtod may read
  # otherwise, suppNumSure): then it says so, and the rest still equals R
  if (!is.null(js_reason)) {
    expect_false(got$combine_supp$ok, label = label)
    expect_identical(got$combine_supp$reason, js_reason, label = label)
    want$combine_supp$ok <- FALSE
    want$combine_supp$reason <- js_reason
  }
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
  # every combine_supp() fixture, eligible or not
  for (nm in cs_names()) {
    cases[[nm]] <- list(f[[nm]][[1]], f[[nm]][[2]], if (grepl("suppqual", nm)) "suppqual" else "suppae", "AE")
  }
  expect_length(cs_names(), 31L)
  # numeric USUBJID: 1e+05 as R writes it, on both sides
  ids <- c(100000, 200000)
  p <- f$cs_ok[[1]]
  p$USUBJID <- ids[match(p$USUBJID, unique(p$USUBJID))]
  s <- f$cs_ok[[2]]
  s$USUBJID <- ids[match(s$USUBJID, unique(f$cs_ok[[1]]$USUBJID))]
  cases$cs_num_usubjid <- list(p, s)
  # cs_frac's IDVARVAL "0.3" is not a double exactly, so R_strtod may round it otherwise
  fail_safe <- c(cs_frac = "IDVARVAL 0.3 is too close to R's rounding to check in the browser")
  for (nm in names(cases)) {
    a <- cases[[nm]]
    supp_parity(nm, a[[1]], a[[2]], if (length(a) > 2) a[[3]] else "suppae",
                if (length(a) > 3) a[[4]] else NULL, if (length(a) > 4) a[[5]] else NULL,
                js_reason = if (nm %in% names(fail_safe)) fail_safe[[nm]])
  }

  # sample_n truncates samples and the preview alike
  s <- f$supp_orphan[rep(2, 8), ]
  s$QNAM <- paste0("Q", 1:8)
  r <- sv_supp_check(f$ae, s, parent_name = "ae", supp_name = "suppae", sample_n = 3L)
  got <- supp_js(f$ae, s, sample_n = 3L)
  got$combine_supp$installed <- NULL
  expect_equal(supp_canon(got), supp_canon(jsonlite::fromJSON(sv_supp_check_json(r),
                                                                 simplifyVector = FALSE)))
  expect_length(got$orphan_samples, 3L)
  expect_length(got$preview, 3L)
})

# Doubles as JSON for the JS helpers: 17 digits, and Inf, -Inf, NaN as strings.
js_dbls <- function(vals) {
  jsonlite::toJSON(lapply(vals, function(v) {
    if (is.nan(v)) "NaN" else if (is.infinite(v)) if (v > 0) "Inf" else "-Inf" else v
  }), digits = I(17), na = "null", auto_unbox = TRUE)
}

test_that("rAsCharacter matches R's as.character for doubles", {
  vals <- c(1, 99999, 100000, 110000, 123456, 1e15, 1e15 + 2, 1e16, 123456789012345678, 0.1, 0.1 + 0.2,
            1/3, 2/3, -1/3, -100000, 1e-4, 1e-5, 0.0001234, 1.5e-300, 1.7976931348623157e308, 5e-324,
            -0, 3.14159265358979, 1234.5678, 1e5 + 0.1, Inf, -Inf, NaN, NA)
  want <- local({ op <- options(scipen = 0); on.exit(options(op)); as.character(vals) })
  got <- run_pipeline_js(sprintf("out = %s.map(P.rAsCharacter);", js_dbls(vals)))
  expect_identical(vapply(got, function(x) if (is.null(x)) NA_character_ else x, ""), want)
  # 15-digit ties round to even; fixed form when it is no wider than scientific
  ties <- c(1000000000000005, 1000000000000015, 1000000000000025, 100000000000000.5, 100000000000001.5,
            12345678901234.25, 12345678901234.75, 2^-22, 3 * 2^-22, 7 * 2^-22, 0.1000000000000005,
            0.3000000000000005, 1234.567890123455, 2^53, 2^60, 12345678901234567890, 1e21, 1e22, 1e-15,
            999999999999999.9, 0.1234567890123456, -2^-1074, 123456.7, 1e100, 1.5e-99, 1e-100)
  want <- local({ op <- options(scipen = 0); on.exit(options(op)); as.character(ties) })
  got <- run_pipeline_js(sprintf("out = %s.map(P.rAsCharacter);", js_dbls(ties)))
  expect_identical(unlist(got), want)
})

test_that("rAsCharacter agrees with R on a sweep of doubles wherever it is sure", {
  set.seed(20261122)
  x <- c(runif(600) * 10^sample(-25:25, 600, TRUE), -runif(100) * 10^sample(-5:20, 100, TRUE),
         round(runif(300) * 1e6) / 10^sample(0:8, 300, TRUE), round(runif(200) * 2^53),
         round(runif(100) * 1e19), (0:99) / 7, 1 / (1:100))
  want <- local({ op <- options(scipen = 999); on.exit(options(op)); sideview:::sv_r_chr(x) })
  got <- run_pipeline_js(sprintf(
    "var xs = %s; out = {text: xs.map(P.rAsCharacter), sure: xs.map(P.rAsCharacterSure)};", js_dbls(x)))
  sure <- unlist(got$sure)
  expect_gt(mean(sure), 0.95)
  expect_identical(unlist(got$text)[sure], want[sure])
  # a 15-digit tie that R rounds through long double arithmetic is not sure
  got <- run_pipeline_js("out = [2.384185791015625e-7, 1234567890123456.5, 0.3, 1e5].map(P.rAsCharacterSure);")
  expect_identical(unlist(got), c(FALSE, FALSE, TRUE, TRUE))
})

test_that("strTrim matches stringr::str_trim", {
  skip_if_not_installed("stringr")
  cps <- c(1:0xD7FF, 0xE000:0xFFFF)
  ch <- intToUtf8(cps, multiple = TRUE)
  y <- c(paste0(ch, "1"), paste0("1", ch), paste0("\ufeff\ufeff", ch, "1"), " \ufeff1")
  # code points both ways: U+007F and other controls do not survive the trip through stdout
  got <- run_pipeline_js(sprintf(paste(
    "out = %s.map(function (a) {",
    "  var t = P.strTrim(String.fromCodePoint.apply(null, a));",
    "  return Array.from(t).map(function (c) { return c.codePointAt(0); });",
    "});"), jsonlite::toJSON(lapply(y, utf8ToInt))))
  expect_identical(lapply(got, function(a) as.integer(unlist(a))), lapply(stringr::str_trim(y), utf8ToInt))
  expect_null(run_pipeline_js("out = P.strTrim(null);"))
})

test_that("suppCheck: rule 1 before rule 2 (lazy) before rule 3 (preview) before the rest", {
  k <- fx$cs_key01
  rd <- function(...) supp_js(k[[1]], k[[2]], extra = list(...))$combine_supp
  r <- rd(lazy = list(name = "ae", kind = "duckdb"))
  expect_identical(r$reason, "combine_supp() needs data frames: ae is a duckdb table")
  expect_false(r$ok)
  expect_identical(r$prep, list(rdomain = FALSE, idvar_na = FALSE))
  expect_null(r$installed)
  expect_identical(rd(lazy = list(name = "suppae", kind = "arrow"), preview = TRUE)$reason,
                   "combine_supp() needs data frames: suppae is an Arrow table")
  expect_identical(rd(preview = TRUE)$reason, "Checked on preview rows only")
  expect_identical(rd(lazy = NULL, preview = FALSE)$reason, 'IDVARVAL "01" would not match AESEQ 1 in combine_supp()')
  # the merge stops: rule 1 wins over a lazy card
  cl <- fx$cs_clash
  expect_identical(supp_js(cl[[1]], cl[[2]], extra = list(lazy = list(name = "ae", kind = "duckdb")))$combine_supp$reason,
                   "The merge stops: AETRTEM already in ae")
  # the stop text, as R writes it
  d <- list(repeats = list(n = 2L), clashes = list("A", "B"), two_level = list("C"))
  expect_identical(run_pipeline_js(sprintf("out = P.combineSuppStopReason(%s, 'ae');",
                                           jsonlite::toJSON(d, auto_unbox = TRUE))),
                   sv_supp_combine_stop_reason(d, "ae"))
  d1 <- list(repeats = list(n = 1L), clashes = list(), two_level = list())
  expect_identical(run_pipeline_js(sprintf("out = P.combineSuppStopReason(%s, 'ae');",
                                           jsonlite::toJSON(d1, auto_unbox = TRUE))),
                   "The merge stops: 1 repeated QNAM record")
})

test_that("suppCheck: a key value R may write differently is not ok (rule 7)", {
  p <- fx$cs_ok[[1]]
  p$AESEQ <- c(2^-22, 2, 1)
  s <- fx$cs_ok[[2]]
  s$IDVARVAL[1] <- "2.38418579101562e-07"
  r <- supp_js(p, s)$combine_supp
  expect_false(r$ok)
  expect_identical(r$reason, "AESEQ 2.38418579101562e-07 is too close to R's rounding to check in the browser")
})

test_that("sv_inexact_cols() names each double column 16-digit JSON does not carry exactly", {
  skip_if_not_installed("htmlwidgets")
  set.seed(20261122)
  r <- c(runif(150) * 10^sample(-20:20, 150, TRUE), round(runif(50) * 1e6) / 8,
         1e15 + sample.int(1e6, 50) + 0.25, -2^53, 2^53, 2^53 + 2, 1e300, 5e-324, 0.1)
  d <- as.data.frame(setNames(lapply(r, function(v) c(v, NA, 1)), sprintf("x%03d", seq_along(r))))
  d$half <- c(0.5, NA, 1)
  d$three <- c(2.9999999999999996, 1, 1)
  d$big_frac <- c(1234567890123456.2, 1, 1)
  d$frac <- c(0.1 + 0.2, 1, 1)
  d$inf <- c(Inf, 1, 1)
  d$ninf <- c(-Inf, 1, 1)
  d$nan <- c(NaN, 1, 1)
  d$na_only <- NA_real_
  d$int <- 1:3
  d$chr <- c("a", "b", NA)
  d$lgl <- c(TRUE, NA, FALSE)
  # 16 digits that R's as.numeric() reads back as x but JSON.parse (and yajl) does not
  rs <- c(0.47360295429825783, 8.3669512206688525e+37, 5853.6245371215045, 230778.35096046329)
  for (i in seq_along(rs)) d[[sprintf("strtod%d", i)]] <- c(rs[i], 1, 1)
  expect_true(all(as.numeric(formatC(rs, digits = 16, format = "g")) == rs))
  bad <- sv_inexact_cols(d)
  expect_true(all(c("three", "big_frac", "frac", "inf", "ninf", "nan", sprintf("strtod%d", 1:4)) %in% bad))
  # eighths, whole numbers to 2^53 and past it while 16 digits hold, 1e300, 5e-324 and 0.1 are
  # exact; 1e15 + k + 0.25 needs 17 digits
  expect_false(any(c("half", "na_only", "int", "chr", "lgl", sprintf("x%03d", c(151:200, 251:256))) %in% bad))
  expect_true(all(sprintf("x%03d", 201:250) %in% bad))
  rnd <- sprintf("x%03d", 1:150)
  expect_true(any(rnd %in% bad) && !all(rnd %in% bad))
  # the real wire: every column not listed comes back as the very doubles R has (null = NA) ...
  json <- as.character(htmlwidgets:::toJSON(d))
  back <- jsonlite::parse_json(json)
  num <- function(v) vapply(v, function(x) if (is.null(x)) NA_real_ else as.numeric(x), numeric(1))
  dbl <- names(d)[vapply(d, is.double, logical(1))]
  for (nm in setdiff(dbl, bad)) expect_identical(num(back[[nm]]), d[[nm]], info = nm)
  # ... and every column listed does not
  for (nm in bad) expect_false(identical(num(back[[nm]]), d[[nm]]), info = nm)
  # the same in the browser's JSON.parse, against R's 17-digit text of each value
  want <- lapply(d[dbl], function(x) ifelse(is.na(x) & !is.nan(x), NA, sprintf("%.17g", x)))
  got <- run_pipeline_js(sprintf(paste0(
    "var w = %s, want = %s; out = [];",
    "Object.keys(want).forEach(function (k) {",
    "  var ok = w[k].every(function (v, i) {",
    "    var t = want[k][i]; return t === null ? v === null : v !== null && v === Number(t); });",
    "  if (!ok) out.push(k); });"), json, jsonlite::toJSON(want, na = "null")))
  expect_setequal(unlist(got), bad)
  # the widget's cards carry it as a JSON array, also with one name or none
  card <- function(w) w$x$cards[[1]]
  wire <- function(w) as.character(htmlwidgets:::toJSON(card(w)["col_inexact"]))
  w <- sideview_widget(t = data.frame(a = 0.1 + 0.2, b = 1, c = "x"))
  expect_identical(card(w)$col_inexact, list("a"))
  expect_match(wire(w), '"col_inexact":["a"]', fixed = TRUE)
  w <- sideview_widget(u = data.frame(b = 1))
  expect_match(wire(w), '"col_inexact":[]', fixed = TRUE)
  # ... worked out on the rows the widget embeds, after max_rows
  big <- data.frame(a = c(1, 2, 0.1 + 0.2))
  expect_identical(card(sideview_widget(big = big))$col_inexact, list("a"))
  w <- suppressMessages(sideview_widget(big = big, max_rows = 2))
  expect_identical(nrow(card(w)$data), 2L)
  expect_identical(card(w)$col_inexact, list())
  # the gadget and the module check combine_supp in R: their payloads leave it out
  expect_null(sv_card_payload(sv_normalize(big, name = "big"))$col_inexact)
  expect_null(sv_card_payload(sv_normalize(big, name = "big"), preview_rows = 2)$col_inexact)
})

test_that("sv_inexact_cols() lists an integer64 column with a value past 2^53", {
  skip_if_not_installed("bit64")
  skip_if_not_installed("htmlwidgets")
  i64 <- bit64::as.integer64
  d <- data.frame(id = 1:2)
  d$small <- i64(c("9007199254740992", NA))
  d$neg_small <- i64(c("-9007199254740992", "1"))
  d$big <- i64(c("1", "9007199254740993"))
  d$neg_big <- i64(c("-9007199254740993", NA))
  d$na <- i64(c(NA, NA))
  expect_identical(sv_inexact_cols(d), c("big", "neg_big"))
  # the browser reads the digits as a double: the unlisted columns arrive exact, the listed do not
  json <- as.character(htmlwidgets:::toJSON(d))
  cols <- c("small", "neg_small", "big", "neg_big", "na")
  want <- lapply(d[cols], function(x) ifelse(is.na(x), NA, as.character(x)))
  got <- run_pipeline_js(sprintf(paste0(
    "var w = %s, want = %s; out = [];",
    "Object.keys(want).forEach(function (k) {",
    "  var ok = w[k].every(function (v, i) {",
    "    var t = want[k][i]; return t === null ? v === null : v !== null && BigInt(v) === BigInt(t); });",
    "  if (!ok) out.push(k); });"), json, jsonlite::toJSON(want, na = "null")))
  expect_setequal(unlist(got), c("big", "neg_big"))
  # combine_supp in the widget: an integer64 key past 2^53 is not trusted
  p <- fx$cs_1e5[[1]]
  p$AESEQ <- i64(c("1", "2", "9007199254740993"))
  s <- fx$cs_1e5[[2]]
  s$IDVARVAL <- c("1", "9007199254740993")
  r <- supp_js(p, s, wire = "widget")$combine_supp
  expect_false(r$ok)
  expect_identical(r$reason, "AESEQ has values the browser cannot read exactly")
})

test_that("suppCheck: rows rounded to 16 digits (the widget) trust only R's exact double columns", {
  skip_if_not_installed("htmlwidgets")
  # the widget's JSON: 0.1 + 0.2 arrives as 0.3, and Inf, NaN and NA all as null
  expect_identical(as.character(htmlwidgets:::toJSON(data.frame(a = c(0.1 + 0.2, Inf, NaN, NA)))),
                   '{"a":[0.3,null,null,null]}')
  expect_identical(as.character(jsonlite::toJSON(data.frame(a = c(0.1 + 0.2, Inf, NaN, NA)),
                                                 dataframe = "columns", na = "null", digits = 16,
                                                 use_signif = TRUE)),
                   '{"a":[0.3,null,null,null]}')
  r_says <- function(k) sv_supp_check(k[[1]], k[[2]], parent_name = "ae", supp_name = "suppae")$combine_supp
  # a parent AESEQ x keyed by SUPP IDVARVAL t
  keyed_dbl <- function(x, t) {
    p <- fx$cs_1e5[[1]]
    p$AESEQ <- c(1, 2, x)
    s <- fx$cs_1e5[[2]]
    s$IDVARVAL <- c("1", t)
    list(p, s)
  }
  lossy <- "AESEQ has values the browser cannot read exactly"
  # R lists the column, so the browser does not guess: 2.9999999999999996 arrives as 3,
  # 1234567890123456.2 as 1234567890123456, 0.1 + 0.2 as 0.3, Inf and NaN as null
  # 0.47360295429825783 and 8.3669512206688525e+37 come back from 16 digits as x in R's
  # as.numeric() but not in JSON.parse, so R's parser cannot be the test (R26)
  cases <- list(three = keyed_dbl(2.9999999999999996, "3"),
                big_frac = keyed_dbl(1234567890123456.2, "1234567890123456.2"),
                cs_frac = fx$cs_frac,
                inf = keyed_dbl(Inf, "Inf"), nan = keyed_dbl(NaN, "NaN"),
                strtod1 = keyed_dbl(0.47360295429825783, "0.47360295429825783"),
                strtod2 = keyed_dbl(8.3669512206688525e+37, "8.3669512206688525e+37"))
  for (nm in names(cases)) {
    k <- cases[[nm]]
    expect_identical(sv_inexact_cols(k[[1]]), "AESEQ", info = nm)
    expect_false(r_says(k)$ok, info = nm)
    r <- supp_js(k[[1]], k[[2]], wire = "widget")$combine_supp
    expect_false(r$ok, info = nm)
    expect_identical(r$reason, lossy, info = nm)
  }
  # columns R does not list are exact on the wire (null in them is NA): the same answer as R
  same <- list(cs_ok = fx$cs_ok, cs_1e5 = fx$cs_1e5, cs_1e5_sci = fx$cs_1e5_sci,
               cs_110000 = fx$cs_110000, half = keyed_dbl(0.5, "0.5"),
               two40 = keyed_dbl(2^40, "1099511627776"), na = keyed_dbl(NA, "2"))
  for (nm in names(same)) {
    k <- same[[nm]]
    expect_identical(sv_inexact_cols(k[[1]]), character(0), info = nm)
    want <- r_says(k)
    got <- supp_js(k[[1]], k[[2]], wire = "widget")$combine_supp
    expect_identical(got$ok, want$ok, info = nm)
    expect_identical(got$reason, want$reason, info = nm)
  }
  expect_true(r_says(same$half)$ok)
  expect_true(supp_js(fx$cs_ok[[1]], fx$cs_ok[[2]], wire = "widget")$combine_supp$ok)
  # rounded rows with no list from R: no double column can be trusted
  k <- same$half
  r <- supp_js(k[[1]], k[[2]], wire = "widget", extra = list(inexact = NULL))$combine_supp
  expect_false(r$ok)
  expect_identical(r$reason, lossy)
  # exact rows (the gadget's 17 digits, no `rounded`) need no list
  expect_true(supp_js(k[[1]], k[[2]])$combine_supp$ok)
})

test_that("suppCheck: an IDVARVAL R_strtod may read as another double is not sure (rule 7)", {
  keyed_dbl <- function(x, t) {
    p <- fx$cs_1e5[[1]]
    p$AESEQ <- c(1, 2, x)
    s <- fx$cs_1e5[[2]]
    s$IDVARVAL <- c("1", t)
    list(p, s)
  }
  unsure <- function(t) sprintf("IDVARVAL %s is too close to R's rounding to check in the browser", t)
  # R reads "0.4736029542982578" as 0.47360295429825783, so dplyr matches; Number() reads its
  # neighbour. Exact 17-digit rows: R is not ok, the browser must not say ok
  # (x is R's own reading of the text; an R literal goes through R_strtod too, so it is not used)
  for (a in c("0.4736029542982578", "8.366951220668853e+37")) {
    x <- as.numeric(a)
    # the browser reads the text as another double (x's 17 digits read back exactly in JS)
    js <- run_pipeline_js(sprintf("out = [Number('%s') === Number('%s')];", a, sprintf("%.17g", x)))
    expect_false(js[[1]], info = a)
    k <- keyed_dbl(x, a)
    expect_false(sv_supp_check(k[[1]], k[[2]], parent_name = "ae", supp_name = "suppae")$combine_supp$ok)
    r <- supp_js(k[[1]], k[[2]])$combine_supp
    expect_false(r$ok, info = a)
    expect_identical(r$reason, unsure(a), info = a)
  }
  # 16 digits are never sure, even an exact 2^53 (R is ok there; the browser is not)
  k <- keyed_dbl(2^53, " 9007199254740992 ")
  expect_true(sv_supp_check(k[[1]], k[[2]], parent_name = "ae", supp_name = "suppae")$combine_supp$ok)
  expect_identical(supp_js(k[[1]], k[[2]])$combine_supp$reason, unsure("9007199254740992"))
  got <- run_pipeline_js(paste0("out = ['0.5', '1e5', '100000e-2', '-0', '0.375', '1099511627776', ",
    "'6.228e-9', '0.3', '0.4736029542982578', '1234567890123456', '1e28', '1' + '0'.repeat(20), ",
    "'1.5e-30'].map(P.suppNumSure);"))
  expect_identical(unlist(got), c(rep(TRUE, 6), rep(FALSE, 7)))
})

test_that("suppNumSure(): every text the browser calls sure is the double R reads", {
  # random decimal texts: 1 to 20 significant digits, exponents across the double range, in
  # scientific, integer-mantissa, fixed (with and without trailing zeros) and leading-zero forms;
  # plus the exact texts of dyadic fractions and of integers, which are the sure region
  set.seed(27)
  n <- 20000L
  nsig <- sample(1:20, n, TRUE)
  digs <- vapply(nsig, function(k) paste0(sample(1:9, 1), paste(sample(0:9, k - 1, TRUE), collapse = "")), "")
  e <- sample(-330:310, n, TRUE)
  form <- sample(c("sci", "int_e", "fixed", "fixed_tz", "lead0_e"), n, TRUE)
  mk <- function(d, k, e, f) {
    switch(f,
      sci = paste0(substr(d, 1, 1), if (k > 1) paste0(".", substr(d, 2, k)) else "", "e", e),
      int_e = paste0(d, "e", e - k + 1),
      lead0_e = paste0("0.000", d, "e", e + 4),
      {
        d2 <- if (f == "fixed_tz") paste0(d, "000") else d
        k2 <- nchar(d2)
        if (e >= k2 - 1) paste0(d2, strrep("0", e - k2 + 1))
        else if (e >= 0) paste0(substr(d2, 1, e + 1), ".", substr(d2, e + 2, k2))
        else paste0("0.", strrep("0", -e - 1), d2)
      })
  }
  rnd <- mapply(mk, digs, nsig, e, form, USE.NAMES = FALSE)
  small <- mapply(mk, digs[1:5000], pmin(nsig[1:5000], 15L), sample(-25:25, 5000, TRUE),
                  form[1:5000], USE.NAMES = FALSE)
  q <- sample.int(2^20, 5000, TRUE) / 2^sample(0:40, 5000, TRUE)
  dy <- sub("[.]$", "", sub("0+$", "", sprintf("%.45f", q)))
  w <- sprintf("%.0f", sample.int(2^31 - 1, 2000, TRUE) * sample(c(1, 10, 1000, 1e6), 2000, TRUE))
  txt <- c(rnd, small, dy, paste0("-", dy[1:1000]), paste0(dy[1:1000], "e-2"), w,
           paste0(w, "00e-2"), paste0(w, ".0"), paste0(w, "e3"))
  x <- as.numeric(txt)
  hex <- apply(matrix(as.character(writeBin(x, raw(), endian = "big")), nrow = 8), 2, paste, collapse = "")
  got <- run_pipeline_js(sprintf(paste0(
    "var t = %s, h = %s, b = Buffer.alloc(8), sure = 0, differ = 0, bad = [];",
    "t.forEach(function (s, i) {",
    "  b.writeDoubleBE(Number(s)); var same = b.toString('hex') === h[i];",
    "  if (!same) differ++;",
    "  if (P.suppNumSure(s)) { sure++; if (!same) bad.push(s); } });",
    "out = {sure: sure, differ: differ, bad: bad};"), jsonlite::toJSON(txt), jsonlite::toJSON(hex)))
  # the sweep has teeth: R and Number() part on some texts, short ones among them ...
  expect_gt(got$differ, 10)
  # ... but never on one called sure, and the sure region is not empty
  expect_identical(unlist(got$bad), NULL)
  expect_gt(got$sure, 10000)
})

test_that("suppCheck: combine_supp needs a type for every column rules 7 and 8 read", {
  k <- fx$cs_ok
  for (miss in c("parentTypes", "suppTypes")) {
    extra <- list()
    extra[miss] <- list(NULL)
    r <- supp_js(k[[1]], k[[2]], extra = extra)$combine_supp
    expect_false(r$ok)
    expect_identical(r$reason, "Column types are not known in the browser", info = miss)
    # prep as computed (cs_ok has a subject-level row with IDVAR "")
    expect_identical(r$prep, list(rdomain = FALSE, idvar_na = TRUE), info = miss)
    # an empty map ({} on the wire)
    extra[miss] <- list(structure(list(), names = character(0)))
    r <- supp_js(k[[1]], k[[2]], extra = extra)$combine_supp
    expect_identical(r$reason, "Column types are not known in the browser", info = paste(miss, "{}"))
  }
  expect_identical(as.character(jsonlite::toJSON(list(t = structure(list(), names = character(0))),
                                                 auto_unbox = TRUE)), '{"t":{}}')
  # a map without one of the columns read: the parent's keys and IDVAR column, the SUPP's
  # keys, IDVARVAL and QLABEL
  k <- fx$cs_1e5
  reads <- list(parentTypes = c("STUDYID", "USUBJID", "DOMAIN", "AESEQ"),
                suppTypes = c("STUDYID", "USUBJID", "RDOMAIN", "IDVARVAL", "QLABEL"))
  for (side in names(reads)) {
    for (col in reads[[side]]) {
      types <- lapply(k[[if (side == "parentTypes") 1L else 2L]], function(x) class(x)[1])
      types[[col]] <- NULL
      r <- supp_js(k[[1]], k[[2]], extra = setNames(list(types), side))$combine_supp
      expect_false(r$ok)
      expect_identical(r$reason, "Column types are not known in the browser", info = paste(side, col))
    }
  }
  # a column neither rule reads may be left out
  types <- lapply(k[[1]], function(x) class(x)[1])
  other <- setdiff(names(types), reads$parentTypes)
  expect_true(length(other) > 0L)
  types[other] <- NULL
  want <- sv_supp_check(k[[1]], k[[2]], parent_name = "ae", supp_name = "suppae")$combine_supp
  r <- supp_js(k[[1]], k[[2]], extra = list(parentTypes = types))$combine_supp
  expect_identical(r$ok, want$ok)
  expect_identical(r$reason, want$reason)
  # after rule 5 (the parent's columns), before rule 7
  r <- supp_js(fx$cs_no_domain[[1]], fx$cs_no_domain[[2]], extra = list(suppTypes = NULL))$combine_supp
  expect_identical(r$reason, "ae has no DOMAIN column")
  expect_true(supp_js(fx$cs_ok[[1]], fx$cs_ok[[2]])$combine_supp$ok)
})

test_that("suppCheck: a blank IDVAR is blank as R's trimws() sees it", {
  # "\f" and NBSP are not blank to trimws(): R looks for a parent column of that name
  for (w in c("\f", "\v", "\u00a0", "\u2028", "  ", "\t\r\n")) {
    s <- fx$cs_ok[[2]]
    s$IDVAR[3] <- w
    supp_parity(sprintf("subject IDVAR %s", paste(utf8ToInt(w), collapse = " ")), fx$cs_ok[[1]], s)
  }
})

test_that("suppCheck: double STUDYID / USUBJID keys are R's 15-digit text on each side", {
  # parent 0.1 + 0.2 and SUPP 0.3 are both "0.3" to R, so they match
  p <- fx$cs_ok[[1]]
  p$USUBJID <- c(0.1 + 0.2, 0.7)[match(p$USUBJID, unique(p$USUBJID))]
  s <- fx$cs_ok[[2]]
  s$USUBJID <- c(0.3, 0.7)[match(s$USUBJID, unique(fx$cs_ok[[1]]$USUBJID))]
  want <- supp_parity("usubjid 0.1 + 0.2 vs 0.3", p, s)
  expect_true(want$combine_supp$ok)
  expect_identical(want$n_matched, 3L)
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

test_that("only ASCII whitespace around IDVARVAL is trimmed, in R and JS (NBSP, BOM, U+2028, U+3000 are bad)", {
  dbl <- fx$ae
  dbl$AESEQ <- c(1, 2, 3, 4)
  ws <- c("\u00a01", "1\u00a0", "\u20281", "\ufeff2", "\u30003", "\t1", "2\n", "\r3\f", "\v4", " 1 ")
  s <- fx$suppae[rep(1, length(ws)), ]
  s$IDVARVAL <- ws
  s$QNAM <- paste0("Q", seq_along(ws))
  w <- supp_parity("ws_double", dbl, s)
  expect_identical(w$bad_idvarval$n, 5L)
  expect_identical(sv_supp_convert(ws, "double"), c(rep(NA, 5), "1", "2", "3", "4", "1"))
  w2 <- supp_parity("ws_integer", fx$ae, s)
  expect_identical(w2$bad_idvarval$n, 5L)
  expect_identical(sv_supp_convert(ws, "integer"), c(rep(NA, 5), "1", "2", "3", "4", "1"))
})

test_that("a double IDVARVAL past 1e308 is bad in R and JS alike (R's parser rounds the largest double up to Inf)", {
  dbl <- fx$ae
  dbl$AESEQ <- c(1, 2, 3, 4)
  edge <- c("1.7976931348623158e308", "-1.7976931348623157e308", "1.5e308", "1e308", "2")
  s <- fx$suppae[rep(1, length(edge)), ]
  s$IDVARVAL <- edge
  s$QNAM <- paste0("Q", seq_along(edge))
  w <- supp_parity("edge_double", dbl, s)
  expect_identical(w$bad_idvarval$n, 3L)
  expect_identical(sv_supp_convert(edge, "double"), c(NA, NA, NA, "1e+308", "2"))
})

test_that("non-finite double IDVARVAL (1e999, -1e999, Inf, NaN) is bad, never an orphan, in R and JS", {
  dbl <- fx$ae
  dbl$AESEQ <- c(1, 2, 3, 4)
  nonfin <- c("1e999", "-1e999", "1E400", "Inf", "-Inf", "NaN", "NA")
  s <- fx$suppae[rep(1, length(nonfin)), ]
  s$IDVARVAL <- nonfin
  s$QNAM <- paste0("Q", seq_along(nonfin))
  w <- supp_parity("nonfinite_double", dbl, s)
  expect_identical(w$bad_idvarval$n, length(nonfin))
  expect_identical(w$n_orphan, 0L)
  expect_identical(sv_supp_convert(c("1e999", "-1e999", "2.5"), "double"), c(NA, NA, "2.5"))
  # an integer parent: out of range / non-finite text is bad as well
  int <- fx$ae
  s$IDVARVAL <- nonfin
  w2 <- supp_parity("nonfinite_integer", int, s)
  expect_identical(w2$bad_idvarval$n, length(nonfin))
})

test_that("an NA QNAM counts as the text NA in R and JS (as pivot_wider names it)", {
  s <- fx$suppae2
  s$QNAM[2] <- NA
  r <- sv_supp_check(fx$ae, s, "ae", "suppae", rdomain = "AE")
  expect_identical(vapply(r$columns, function(cl) cl$name, ""), c("AETRTEM", "NA", "AESOC2"))
  w <- supp_parity("na_qnam", fx$ae, s)
  # two NA QNAMs for one record repeat
  s2 <- fx$suppae2
  s2$QNAM[1:2] <- NA
  s2$IDVARVAL[2] <- "1"
  s2$USUBJID[2] <- s2$USUBJID[1]
  w2 <- supp_parity("na_qnam_repeat", fx$ae, s2)
  expect_identical(w2$repeats$n, 1L)
  expect_identical(w2$repeats$samples[[1]]$QNAM, "NA")
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
    # the combine_supp field, plus whether metatools (0.3.0 or later) is installed here
    cs <- last$message$combine_supp
    expect_true(is.logical(cs$ok) && length(cs$ok) == 1L)
    expect_true(is.logical(cs$installed) && length(cs$installed) == 1L && !is.na(cs$installed))
    expect_identical(cs$installed, requireNamespace("metatools", quietly = TRUE) &&
                       utils::packageVersion("metatools") >= "0.3.0")
    expect_true(is.logical(cs$prep$rdomain) && is.logical(cs$prep$idvar_na))
    # the installed flag is the server's, not the check's
    expect_null(sv_supp_check(fx$ae, fx$suppae, "ae", "suppae")$combine_supp$installed)
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

test_that("server says combine_supp() needs data frames for a lazy card, also after a lost link", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  cs_last <- function(session) {
    msgs <- session$userData$custom_messages
    msgs[[length(msgs)]]$message
  }
  mk <- function(pair, env = parent.frame()) {
    con <- DBI::dbConnect(duckdb::duckdb())
    withr::defer(suppressWarnings(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)), envir = env)
    DBI::dbWriteTable(con, "p", pair[[1]])
    DBI::dbWriteTable(con, "s", pair[[2]])
    list(con = con,
         cards = list(sv_normalize(dplyr::tbl(con, "p"), name = "ae"),
                      sv_normalize(dplyr::tbl(con, "s"), name = "suppae")))
  }
  ask <- function(session, id) {
    session$setInputs(supp_check_request = list(id = id, parent = "ae", supp = "suppae", rdomain = "AE"))
    cs_last(session)
  }
  want_rule2 <- "combine_supp() needs data frames: ae is a duckdb table"
  # the link is alive: the lazy twin answers
  m <- mk(fx$cs_ok)
  shiny::testServer(sideview_server(m$cards), {
    r <- ask(session, "l1")
    expect_identical(r$status, "ok")
    expect_false(r$combine_supp$ok)
    expect_identical(r$combine_supp$reason, want_rule2)
    expect_identical(r$combine_supp$installed, requireNamespace("metatools", quietly = TRUE) &&
                       utils::packageVersion("metatools") >= "0.3.0")
    expect_false(r$combine_supp$prep$rdomain)
    expect_true(r$combine_supp$prep$idvar_na)   # the subject-level row has IDVAR ""
  })
  # the link is lost: the preview answers, and rule 2 still holds for a lazy card
  m <- mk(fx$cs_ok)
  shiny::testServer(sideview_server(m$cards), {
    DBI::dbDisconnect(m$con, shutdown = TRUE)
    r <- ask(session, "l2")
    expect_identical(r$status, "ok")
    expect_false(r$combine_supp$ok)
    expect_identical(r$combine_supp$reason, want_rule2)
    expect_true(is.logical(r$combine_supp$installed))
  })
  # a lazy SUPP with a plain parent names the SUPP card
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(suppressWarnings(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)))
  DBI::dbWriteTable(con, "s", fx$cs_ok[[2]])
  mixed <- list(sv_normalize(fx$cs_ok[[1]], name = "ae"), sv_normalize(dplyr::tbl(con, "s"), name = "suppae"))
  shiny::testServer(sideview_server(mixed), {
    DBI::dbDisconnect(con, shutdown = TRUE)
    r <- ask(session, "l3")
    expect_identical(r$combine_supp$reason, "combine_supp() needs data frames: suppae is a duckdb table")
  })
  # rule 1 comes first: a check that stops says so, lazy or not
  m <- mk(fx$cs_clash)
  shiny::testServer(sideview_server(m$cards), {
    DBI::dbDisconnect(m$con, shutdown = TRUE)
    r <- ask(session, "l4")
    expect_identical(r$status, "error")
    expect_false(r$combine_supp$ok)
    expect_match(r$combine_supp$reason, "^The merge stops: AETRTEM already in ae$")
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
    r1 <- ask(session, "h1")
    expect_identical(r1$error, "suppqual has no rows for QUAL")
    expect_null(r1$combine_supp)   # an {error} reply has no combine_supp, as in both twins
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

# ---- class, print and the unchanged browser JSON (Task 6) ----
# Snapshots of sv_supp_check_json() taken at the base commit, before the class existed, plus the
# combine_supp field (E1) at the end.
snap_supp_ok <- r"({"status":"ok","plan":{"keys":["STUDYID","USUBJID"],"idvars":[{"idvar":"AESEQ","type":"integer"}],"qnams":[{"qnam":"AETRTEM","label":"Treatment Emergent","idvar":"AESEQ"}],"rdomain_col":true},"n_parent":4,"n_supp":4,"n_matched":4,"n_orphan":0,"orphan_samples":[],"n_other_rdomain":0,"repeats":{"n":0,"samples":[]},"clashes":[],"two_level":[],"bad_idvarval":{"n":0,"samples":[]},"columns":[{"name":"AETRTEM","label":"Treatment Emergent"}],"preview":[{"STUDYID":"SV-001","DOMAIN":"AE","USUBJID":"SV-001-001","AESEQ":1,"AETERM":"Headache","AEDECOD":"HEADACHE","AESEV":"MILD","AESTDTC":"2024-01-02","AETRTEM":"Y"},{"STUDYID":"SV-001","DOMAIN":"AE","USUBJID":"SV-001-002","AESEQ":2,"AETERM":"Nausea","AEDECOD":"NAUSEA","AESEV":"MODERATE","AESTDTC":"2024-01-05","AETRTEM":"Y"},{"STUDYID":"SV-001","DOMAIN":"AE","USUBJID":"SV-001-003","AESEQ":3,"AETERM":"Rash","AEDECOD":"RASH","AESEV":"MILD","AESTDTC":"2024-02-01","AETRTEM":"Y"},{"STUDYID":"SV-001","DOMAIN":"AE","USUBJID":"SV-001-004","AESEQ":4,"AETERM":"Cough","AEDECOD":"COUGH","AESEV":"SEVERE","AESTDTC":"2024-02-09","AETRTEM":"Y"}],"drift":{"stale":false,"reasons":[]},"combine_supp":{"ok":false,"reason":"suppae has no QORIG column","prep":{"rdomain":false,"idvar_na":false}}})"
snap_supp_orphan <- r"({"status":"warning","plan":{"keys":["STUDYID","USUBJID"],"idvars":[{"idvar":"AESEQ","type":"integer"}],"qnams":[{"qnam":"AETRTEM","label":"Label AETRTEM","idvar":"AESEQ"}],"rdomain_col":true},"n_parent":4,"n_supp":2,"n_matched":1,"n_orphan":1,"orphan_samples":[{"USUBJID":"SV-001-999","IDVAR":"AESEQ","IDVARVAL":"99","QNAM":"AETRTEM"}],"n_other_rdomain":0,"repeats":{"n":0,"samples":[]},"clashes":[],"two_level":[],"bad_idvarval":{"n":0,"samples":[]},"columns":[{"name":"AETRTEM","label":"Label AETRTEM"}],"preview":[{"STUDYID":"SV-001","DOMAIN":"AE","USUBJID":"SV-001-001","AESEQ":1,"AETERM":"Headache","AEDECOD":"HEADACHE","AESEV":"MILD","AESTDTC":"2024-01-02","AETRTEM":"Y"},{"STUDYID":"SV-001","DOMAIN":"AE","USUBJID":"SV-001-002","AESEQ":2,"AETERM":"Nausea","AEDECOD":"NAUSEA","AESEV":"MODERATE","AESTDTC":"2024-01-05","AETRTEM":null},{"STUDYID":"SV-001","DOMAIN":"AE","USUBJID":"SV-001-003","AESEQ":3,"AETERM":"Rash","AEDECOD":"RASH","AESEV":"MILD","AESTDTC":"2024-02-01","AETRTEM":null},{"STUDYID":"SV-001","DOMAIN":"AE","USUBJID":"SV-001-004","AESEQ":4,"AETERM":"Cough","AEDECOD":"COUGH","AESEV":"SEVERE","AESTDTC":"2024-02-09","AETRTEM":null}],"drift":{"stale":false,"reasons":[]},"combine_supp":{"ok":false,"reason":"suppae has no QORIG column","prep":{"rdomain":false,"idvar_na":false}}})"

test_that("a SUPP check carries a class, prints as sentences and sends the same JSON", {
  r <- chk(fx$suppae)
  expect_s3_class(r, "sv_supp_check")
  expect_true(is.list(unclass(r)))
  expect_identical(c(r$parent_name, r$supp_name), c("ae", "suppae"))
  expect_output(print(r), "Merging suppae into ae adds")
  expect_identical(capture.output(print(chk(fx$suppae))),
                   c("Merging suppae into ae adds 1 column: AETRTEM.", "4 of 4 suppae rows match a ae row.",
                     "combine_supp(): no, suppae has no QORIG column"))
  expect_output(print(chk(fx$supp_noqnam)), "SUPP check failed: Not in suppae: QNAM.", fixed = TRUE)
  expect_s3_class(chk(fx$supp_noqnam), "sv_supp_check")
  expect_identical(chk(fx$supp_noqnam)$error, "Not in suppae: QNAM")
  expect_identical(sv_supp_check_json(chk(fx$suppae)), snap_supp_ok)
  expect_identical(sv_supp_check_json(chk(fx$supp_orphan)), snap_supp_orphan)
  expect_identical(sv_supp_check_json(chk(fx$supp_noqnam)), "{\"error\":\"Not in suppae: QNAM\"}")
  expect_false(grepl("parent_name|supp_name", sv_supp_check_json(chk(fx$suppae))))
})
