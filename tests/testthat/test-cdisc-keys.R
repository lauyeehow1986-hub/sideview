# CDISC join keys: the rule engine (sv_cdisc_join_keys).


test_that("trace: adae joins ae by STUDYID, USUBJID, AESEQ", {
  fx <- sv_cdisc_fixtures()
  k <- sv_cdisc_join_keys(sv_cdisc_cards(list(adae = fx$adae_pfx, ae = fx$ae)))
  expect_equal(nrow(k), 1L)
  expect_identical(k$from_table, "adae")
  expect_identical(k$to_table, "ae")
  expect_identical(k$from_cols[[1]], c("STUDYID", "USUBJID", "AESEQ"))
  expect_identical(k$to_cols[[1]], c("STUDYID", "USUBJID", "AESEQ"))
  expect_identical(k$kind, "trace")
})

test_that("trace beats subject", {
  fx <- sv_cdisc_fixtures()
  k <- sv_cdisc_join_keys(sv_cdisc_cards(list(dm = fx$dm, ae = fx$ae, adae = fx$adae_pfx)))
  row <- k[k$from_table == "adae" & k$to_table == "ae", ]
  expect_equal(nrow(row), 1L)
  expect_identical(row$kind, "trace")
})

test_that("subject: ae to dm, adlb to adsl", {
  fx <- sv_cdisc_fixtures()
  k <- sv_cdisc_join_keys(sv_cdisc_cards(list(dm = fx$dm, ae = fx$ae)))
  expect_equal(nrow(k), 1L)
  expect_identical(k$kind, "subject")
  expect_identical(k$from_table, "ae")
  expect_identical(k$to_table, "dm")
  expect_identical(k$from_cols[[1]], c("STUDYID", "USUBJID"))

  # ADaM goes to ADSL even when DM is present
  k <- sv_cdisc_join_keys(sv_cdisc_cards(list(dm = fx$dm, adsl = fx$adsl, adlb = fx$adlb)))
  row <- k[k$from_table == "adlb", ]
  expect_equal(nrow(row), 1L)
  expect_identical(row$to_table, "adsl")
  # with both hubs present: adsl -> dm
  hub <- k[k$from_table == "adsl", ]
  expect_equal(nrow(hub), 1L)
  expect_identical(hub$to_table, "dm")
  expect_identical(hub$kind, "subject")

  # ae goes to adsl when dm is absent
  k <- sv_cdisc_join_keys(sv_cdisc_cards(list(adsl = fx$adsl, ae = fx$ae)))
  expect_equal(nrow(k), 1L)
  expect_identical(k$from_table, "ae")
  expect_identical(k$to_table, "adsl")

  # ae with adsl while dm exists: no ae -> adsl row
  k <- sv_cdisc_join_keys(sv_cdisc_cards(list(dm = fx$dm, adsl = fx$adsl, ae = fx$ae)))
  expect_false(any(k$from_table == "ae" & k$to_table == "adsl"))
  expect_true(any(k$from_table == "ae" & k$to_table == "dm"))
})

test_that("visit: lb joins sv by STUDYID, USUBJID, VISITNUM", {
  fx <- sv_cdisc_fixtures()
  k <- sv_cdisc_join_keys(sv_cdisc_cards(list(lb = fx$lb, sv = fx$sv)))
  expect_equal(nrow(k), 1L)
  expect_identical(k$kind, "visit")
  expect_identical(k$from_table, "lb")
  expect_identical(k$to_table, "sv")
  expect_identical(k$from_cols[[1]], c("STUDYID", "USUBJID", "VISITNUM"))
  expect_identical(k$to_cols[[1]], c("STUDYID", "USUBJID", "VISITNUM"))
})

test_that("lb with vs gives nothing", {
  fx <- sv_cdisc_fixtures()
  k <- sv_cdisc_join_keys(sv_cdisc_cards(list(lb = fx$lb, vs = fx$vs)))
  expect_equal(nrow(k), 0L)
})

test_that("excluded: SUPP, RELREC and trial design never appear; cleared tags take no part", {
  fx <- sv_cdisc_fixtures()
  cards <- sv_cdisc_cards(list(dm = fx$dm, suppae = fx$suppae, relrec = fx$relrec, ts = fx$ts))
  expect_false(is.null(cards[[3]]$cdisc))
  k <- sv_cdisc_join_keys(cards)
  expect_equal(nrow(k), 0L)

  cards <- sv_cdisc_cards(list(dm = fx$dm, ae = fx$ae))
  cards[[2]]$cdisc <- NULL
  expect_equal(nrow(sv_cdisc_join_keys(cards)), 0L)

  two_dm <- sv_cdisc_cards(list(dm = fx$dm, dm2 = fx$dm))
  expect_equal(nrow(sv_cdisc_join_keys(two_dm)), 0L)
})

test_that("no STUDYID: USUBJID alone", {
  fx <- sv_cdisc_fixtures()
  # auto-detection needs STUDYID, so the table without it is tagged by the user
  cards <- sv_cdisc_cards(list(adsl = fx$adsl_nostudy, adlb = fx$adlb), cdisc = c(adsl = "ADSL"))
  expect_false(is.null(cards[[1]]$cdisc))
  k <- sv_cdisc_join_keys(cards)
  expect_equal(nrow(k), 1L)
  expect_identical(k$from_cols[[1]], "USUBJID")
  expect_identical(k$to_cols[[1]], "USUBJID")
  expect_match(k$reason, "no STUDYID")
})

test_that("column spelling follows each table", {
  fx <- sv_cdisc_fixtures()
  k <- sv_cdisc_join_keys(sv_cdisc_cards(list(dm = fx$dm_upper_lower, ae = fx$ae_lower)))
  expect_equal(nrow(k), 1L)
  expect_identical(k$from_cols[[1]], c("studyid", "usubjid"))
  expect_identical(k$to_cols[[1]], c("studyid", "usubjid"))
  # mixed spelling: per side
  k <- sv_cdisc_join_keys(sv_cdisc_cards(list(dm = fx$dm_upper_lower, ae = fx$ae)))
  expect_equal(nrow(k), 1L)
  expect_identical(k$from_cols[[1]], c("STUDYID", "USUBJID"))
  expect_identical(k$to_cols[[1]], c("studyid", "usubjid"))
})

test_that("lazy card gives the same keys and its source is not collected", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  fx <- sv_cdisc_fixtures()
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "ae", fx$ae)
  lazy_ae <- dplyr::tbl(con, "ae")
  cards <- sv_cdisc_cards(list(dm = fx$dm, ae = lazy_ae))
  expect_true(isTRUE(cards[[2]]$is_lazy))
  k <- sv_cdisc_join_keys(cards)
  ref <- sv_cdisc_join_keys(sv_cdisc_cards(list(dm = fx$dm, ae = fx$ae)))
  expect_equal(k, ref)
  expect_s3_class(cards[[2]]$source, "tbl_lazy")
  expect_identical(sv_keys_colnames(cards[[2]]), names(fx$ae))
})

test_that("empty: fewer than two eligible cards gives a zero-row frame", {
  fx <- sv_cdisc_fixtures()
  k <- sv_cdisc_join_keys(sv_cdisc_cards(list(dm = fx$dm)))
  expect_s3_class(k, "data.frame")
  expect_equal(nrow(k), 0L)
  expect_identical(names(k), c("from_table", "to_table", "from_cols", "to_cols", "kind", "reason"))
  expect_equal(nrow(sv_cdisc_join_keys(list())), 0L)
})

test_that("sv_keys_eligible", {
  fx <- sv_cdisc_fixtures()
  cards <- sv_cdisc_cards(list(dm = fx$dm, suppae = fx$suppae, relrec = fx$relrec,
                               ts = fx$ts, mtcars = fx$mtcars, ae_lower = fx$ae_lower))
  expect_identical(vapply(cards, sv_keys_eligible, logical(1), USE.NAMES = FALSE),
                   c(TRUE, FALSE, FALSE, FALSE, FALSE, TRUE))
})
