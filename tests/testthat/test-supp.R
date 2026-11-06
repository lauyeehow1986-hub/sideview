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
