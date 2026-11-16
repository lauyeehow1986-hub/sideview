# Tests for derived rows: sv_unmatched(), sv_derive_rows(), sv_derive_name(), sv_say_derive_offer().

derive_fx <- function() {
  list(
    ae = data.frame(USUBJID = c("a", "b", "b", "z", NA, "q"), term = letters[1:6], stringsAsFactors = FALSE),
    dm = data.frame(USUBJID = c("a", "b", "c", NA), site = 1:4, stringsAsFactors = FALSE)
  )
}

test_that("unmatched with no rule equals n_x - matched_x, NA matching NA", {
  f <- derive_fx()
  d <- sv_join_diagnostics(f$ae, f$dm, "USUBJID")
  expect_equal(nrow(sv_unmatched(f$ae, f$dm, "USUBJID")), d$n_x - d$matched_x)
  expect_equal(nrow(sv_unmatched(f$ae, f$dm, "USUBJID", side = "y")), d$n_y - d$matched_y)
  # dm also has an NA key, so the NA ae row is matched and not in the result
  expect_false(anyNA(sv_unmatched(f$ae, f$dm, "USUBJID")$USUBJID))
  expect_setequal(sv_unmatched(f$ae, f$dm, "USUBJID")$USUBJID, c("z", "q"))
})

test_that("with a rule, unmatched + outside_window partition what the rule drops", {
  for (kind in c("Date", "date-time", "numeric")) {
    t <- rule_tables(kind, 7)
    for (rule in rule_cases()) {
      d <- sv_join_diagnostics(t$x, t$y, "id", rule = rule)
      for (side in c("x", "y")) {
        un <- sv_unmatched(t$x, t$y, "id", rule = rule, side = side)
        ow <- sv_unmatched(t$x, t$y, "id", rule = rule, side = side, what = "outside_window")
        n <- if (side == "x") d$n_x - d$matched_x else d$n_y - d$matched_y
        dropped <- if (side == "x") d$rule_dropped_x else d$rule_dropped_y
        expect_equal(nrow(un) + nrow(ow), n, info = paste(kind, rule$shape, side))
        expect_equal(nrow(ow), dropped, info = paste(kind, rule$shape, side))
      }
    }
  }
})

test_that("rows equal dplyr", {
  f <- derive_fx()
  expect_equal(sv_unmatched(f$ae, f$dm, "USUBJID"),
               dplyr::anti_join(f$ae, f$dm, by = "USUBJID", na_matches = "na"))
  expect_equal(sv_unmatched(f$ae, f$dm, c(USUBJID = "USUBJID"), side = "y"),
               dplyr::anti_join(f$dm, f$ae, by = "USUBJID", na_matches = "na"))
  t <- rule_tables("Date", 3)
  rule <- list(shape = "between", xCol = "xd", yFrom = "ys", yTo = "ye")
  by <- dplyr::join_by(id, between(xd, ys, ye))
  un <- sv_unmatched(t$x, t$y, "id", rule = rule)
  ow <- sv_unmatched(t$x, t$y, "id", rule = rule, what = "outside_window")
  has_key <- dplyr::semi_join(t$x, t$y, by = "id", na_matches = "never")
  expect_equal(un, dplyr::anti_join(t$x, t$y, by = "id", na_matches = "never"))
  expect_equal(ow, dplyr::anti_join(has_key, t$y, by = by, na_matches = "never"))
})

test_that("outside_window needs a rule, and a bad rule is refused", {
  f <- derive_fx()
  expect_error(sv_unmatched(f$ae, f$dm, "USUBJID", what = "outside_window"), "outside_window needs a date rule.")
  expect_error(sv_unmatched(f$ae, f$dm, "USUBJID", rule = list(shape = "zig")), "Unknown date rule")
})

test_that("mixed key kinds are refused", {
  x <- data.frame(id = c(1, 2))
  y <- data.frame(id = c("1", "2"))
  expect_error(sv_unmatched(x, y, "id"), "dplyr will refuse")
})

test_that("names", {
  nm <- function(inputs, taken = character(), ...) {
    sv_derive_name("unmatched", inputs, list(side = "x"), taken, ...)
  }
  expect_identical(nm(c("ae", "dm")), "ae_unmatched_dm")
  expect_identical(nm(c("ae", "dm"), "ae_unmatched_dm"), "ae_unmatched_dm_2")
  expect_identical(nm(c("ae", "dm"), c("ae_unmatched_dm", "ae_unmatched_dm_2")), "ae_unmatched_dm_3")
  expect_identical(nm(c("ae 2026", "dm")), "ae.2026_unmatched_dm")
  expect_identical(sv_derive_name("unmatched", c("ae", "dm"), list(side = "y"), character()), "dm_unmatched_ae")
  expect_identical(sv_derive_name("outside_window", c("ae", "dm"), list(side = "x"), character()), "ae_outside_window")
  expect_identical(nm(c("ae", "dm"), name = "mine"), "mine")
  expect_error(nm(c("ae", "dm"), "ae_unmatched_dm", name = "ae_unmatched_dm"), "already on the canvas")
})

test_that("say", {
  expect_identical(sv_say_derive_offer("unmatched", 12, "ae", "dm"), "Open 12 unmatched ae rows as a card")
  expect_identical(sv_say_derive_offer("unmatched", 1, "ae", "dm"), "Open 1 unmatched ae row as a card")
  expect_identical(sv_say_derive_offer("outside_window", 3, "ae", "dm"), "Open 3 ae rows outside the date window as a card")
  expect_identical(sv_say_derive_offer("outside_window", 1, "ae", "dm"), "Open 1 ae row outside the date window as a card")
  expect_identical(sv_say_derive_offer("supp_orphans", 2, "suppae", "ae"), "Open 2 orphan suppae rows as a card")
  expect_identical(sv_say_derive_offer("supp_orphans", 1, "suppae", "ae"), "Open 1 orphan suppae row as a card")
  expect_identical(sv_say_derive_offer("supp_bad_idvarval", 1, "suppae", "ae"), "Open 1 suppae row with a bad IDVARVAL as a card")
  expect_identical(sv_say_derive_offer("supp_bad_idvarval", 12, "suppae", "ae"), "Open 12 suppae rows with a bad IDVARVAL as a card")
})

supp_derive_fx <- function() {
  f <- sv_cdisc_fixtures()
  u <- f$ae$USUBJID
  mk <- function(rd, usubjid, idvar, idvarval, qnam) {
    data.frame(STUDYID = "SV-001", RDOMAIN = rd, USUBJID = usubjid, IDVAR = idvar, IDVARVAL = idvarval,
               QNAM = qnam, QLABEL = qnam, QVAL = "Y", stringsAsFactors = FALSE)
  }
  s <- rbind(
    mk("AE", u[1], "AESEQ", "1", "Q1"),
    mk("AE", u[2], "AESEQ", "99", "Q2"),
    mk("AE", u[3], "AESEQ", " 3 ", "Q3"),
    mk("AE", u[1], "AESEQ", "x", "Q4"),
    mk("AE", u[1], "AESEQ", "1e999", "Q5"),
    mk("AE", "SV-001-999", "", "", "Q6"),
    mk("AE", u[2], "", "", "Q7"),
    mk("CM", u[1], "CMSEQ", "1", "Q8"))
  list(ae = f$ae, supp = s)
}

test_that("supp_orphans count equals the check's n_orphan", {
  f <- supp_derive_fx()
  chk <- sv_supp_check(f$ae, f$supp, "ae", "suppae")
  o <- sv_supp_orphans(f$ae, f$supp, rdomain = "AE")
  expect_s3_class(o, "data.frame")
  expect_equal(nrow(o), chk$n_orphan)
  expect_identical(o$QNAM, c("Q2", "Q6"))
  expect_identical(names(o), names(f$supp))
})

test_that("bad_idvarval count equals bad_idvarval$n", {
  f <- supp_derive_fx()
  chk <- sv_supp_check(f$ae, f$supp, "ae", "suppae")
  b <- sv_supp_orphans(f$ae, f$supp, rdomain = "AE", what = "bad_idvarval")
  expect_equal(nrow(b), chk$bad_idvarval$n)
  # "x" and "1e999" are bad; " 3 " converts (ASCII whitespace) and is matched
  expect_identical(b$IDVARVAL, c("x", "1e999"))
  expect_false(" 3 " %in% sv_supp_orphans(f$ae, f$supp, rdomain = "AE")$IDVARVAL)
})

test_that("orphans + bad + matched = n_supp", {
  f <- supp_derive_fx()
  chk <- sv_supp_check(f$ae, f$supp, "ae", "suppae")
  o <- sv_supp_orphans(f$ae, f$supp, rdomain = "AE")
  b <- sv_supp_orphans(f$ae, f$supp, rdomain = "AE", what = "bad_idvarval")
  expect_equal(nrow(o) + nrow(b) + chk$n_matched, chk$n_supp)
})

test_that("supp ops filter on RDOMAIN", {
  f <- supp_derive_fx()
  o <- sv_supp_orphans(f$ae, f$supp, rdomain = "AE")
  expect_true(all(o$RDOMAIN == "AE"))
  # the CM row is not an orphan of AE; asked for CM, only the CM row is looked at
  expect_false("Q8" %in% o$QNAM)
  cm <- data.frame(STUDYID = "SV-001", USUBJID = f$ae$USUBJID, CMSEQ = 2:5, stringsAsFactors = FALSE)
  expect_identical(sv_supp_orphans(cm, f$supp, rdomain = "CM")$QNAM, "Q8")
})

test_that("supp ops through sv_derive_rows take the plan and give SUPP row order", {
  f <- supp_derive_fx()
  plan <- sv_supp_check(f$ae, f$supp, "ae", "suppae")$plan
  o <- sv_derive_rows("supp_orphans", list(parent = f$ae, supp = f$supp), list(plan = plan, rdomain = "AE"))
  expect_identical(o$QNAM, c("Q2", "Q6"))
  expect_identical(rownames(o), as.character(seq_len(nrow(o))))
  expect_identical(sv_derive_name("supp_orphans", c("ae", "suppae"), list(), character()), "suppae_orphans")
})

test_that("a list form of `by` gives the same unmatched rows as the character form", {
  f <- derive_fx()
  expect_equal(sv_unmatched(f$ae, f$dm, list(list(x = "USUBJID", y = "USUBJID"))),
               sv_unmatched(f$ae, f$dm, "USUBJID"))
})

# ---- offers in the check replies (Task 4) ----

offer_ns <- function(o) vapply(o, function(z) z$n, 1L)

test_that("join offers without a rule: unmatched x and y, counts equal the derived rows", {
  f <- derive_fx()
  d <- sv_join_diagnostics(f$ae, f$dm, "USUBJID", x_name = "ae", y_name = "dm")
  o <- sv_derive_offers_join(d, "ae", "dm", "USUBJID", NULL)
  expect_length(o, 2L)
  expect_identical(vapply(o, function(z) z$op, ""), c("unmatched", "unmatched"))
  expect_identical(vapply(o, function(z) z$args$side, ""), c("x", "y"))
  expect_identical(o[[1]]$inputs, c("ae", "dm"))
  expect_equal(o[[1]]$n, nrow(sv_unmatched(f$ae, f$dm, "USUBJID")))
  expect_equal(o[[2]]$n, nrow(sv_unmatched(f$ae, f$dm, "USUBJID", side = "y")))
  expect_true(all(nzchar(vapply(o, function(z) z$label, ""))))
})

test_that("join offers with a rule: counts equal the derived rows, zeros dropped", {
  t <- rule_tables("Date", 7)
  rule <- rule_cases()[[3]]
  d <- sv_join_diagnostics(t$x, t$y, "id", rule = rule, x_name = "x", y_name = "y")
  o <- sv_derive_offers_join(d, "x", "y", "id", rule)
  expect_lte(length(o), 4L)
  for (z in o) {
    rows <- sv_unmatched(t$x, t$y, "id", rule = rule, side = z$args$side, what = z$op)
    expect_equal(z$n, nrow(rows), info = paste(z$op, z$args$side))
    expect_gt(z$n, 0L)
  }
  expect_true("outside_window" %in% vapply(o, function(z) z$op, ""))
  # a perfect match offers nothing
  x <- data.frame(id = 1:3)
  d0 <- sv_join_diagnostics(x, x, "id", x_name = "x", y_name = "y")
  expect_length(sv_derive_offers_join(d0, "x", "y", "id", NULL), 0L)
})

test_that("mixed key kinds get no offer", {
  x <- data.frame(id = c("1", "2", "9"))
  y <- data.frame(id = 1:2)
  d <- sv_join_diagnostics(x, y, "id", x_name = "x", y_name = "y")
  expect_true(length(d$type_issues) > 0L)
  expect_length(sv_derive_offers_join(d, "x", "y", "id", NULL), 0L)
})

derive_supp_fx <- function() {
  list(
    ae = data.frame(USUBJID = c("S1", "S2"), AESEQ = 1:2, stringsAsFactors = FALSE),
    supp = data.frame(RDOMAIN = "AE", USUBJID = c("S1", "S2", "S2"), IDVAR = "AESEQ",
                      IDVARVAL = c("1", "9", "x"), QNAM = "AETRTEM", QVAL = "Y", stringsAsFactors = FALSE)
  )
}

test_that("SUPP offers: orphans and bad IDVARVAL, no plan", {
  f <- derive_supp_fx()
  chk <- sv_supp_check(f$ae, f$supp, "ae", "suppae", rdomain = "AE")
  o <- sv_derive_offers_supp(chk, "ae", "suppae", "AE")
  expect_identical(vapply(o, function(z) z$op, ""), c("supp_orphans", "supp_bad_idvarval"))
  expect_equal(offer_ns(o), c(nrow(sv_supp_orphans(f$ae, f$supp, "AE")),
                              nrow(sv_supp_orphans(f$ae, f$supp, "AE", what = "bad_idvarval"))))
  expect_identical(o[[1]]$args, list(rdomain = "AE"))
  expect_identical(o[[1]]$inputs, c("ae", "suppae"))
  # nothing wrong, nothing offered
  ok <- sv_supp_check(f$ae, f$supp[1, ], "ae", "suppae", rdomain = "AE")
  expect_length(sv_derive_offers_supp(ok, "ae", "suppae", "AE"), 0L)
})

test_that("the join and SUPP replies carry derive_offers, [] when empty, none on an error", {
  f <- derive_fx()
  sf <- derive_supp_fx()
  cards <- sv_normalize_cards(list(ae = f$ae, dm = f$dm, sae = sf$ae, suppae = sf$supp))
  shiny::testServer(sideview_server(cards), {
    last <- function(type) {
      m <- Filter(function(z) identical(z$type, type), session$userData$custom_messages)
      m[[length(m)]]$message
    }
    session$setInputs(join_diagnostics_request = list(
      id = "j1", left = "ae", right = "dm", by = list(list(left = "USUBJID", right = "USUBJID"))))
    j <- last("sideview_join_diagnostics")
    expect_length(j$derive_offers, 2L)
    expect_identical(j$derive_offers[[1]]$op, "unmatched")
    session$setInputs(join_diagnostics_request = list(
      id = "j2", left = "ae", right = "ae", by = list(list(left = "USUBJID", right = "USUBJID"))))
    j2 <- last("sideview_join_diagnostics")
    expect_identical(j2$derive_offers, list())
    session$setInputs(join_diagnostics_request = list(
      id = "j3", left = "ae", right = "dm", by = list(list(left = "nope", right = "USUBJID"))))
    j3 <- last("sideview_join_diagnostics")
    expect_false(is.null(j3$error))
    expect_null(j3$derive_offers)

    session$setInputs(supp_check_request = list(id = "s1", parent = "sae", supp = "suppae", rdomain = "AE"))
    s <- last("sideview_supp_check")
    expect_length(s$derive_offers, 2L)
    expect_identical(s$derive_offers[[1]]$op, "supp_orphans")
    session$setInputs(supp_check_request = list(id = "s2", parent = "sae", supp = "nope"))
    s2 <- last("sideview_supp_check")
    expect_false(is.null(s2$error))
    expect_null(s2$derive_offers)
  })
})

test_that("the module path carries derive_offers on both replies", {
  f <- derive_fx()
  sf <- derive_supp_fx()
  shiny::testServer(sideviewServer, args = list(id = "cv",
      cards = list(ae = f$ae, dm = f$dm, sae = sf$ae, suppae = sf$supp)), {
    session$setInputs(sideview_ready = list(nonce = 1))
    last <- function(type) {
      m <- Filter(function(z) identical(z$type, type), session$userData$custom_messages)
      m[[length(m)]]$message
    }
    session$setInputs(join_diagnostics_request = list(
      id = "j1", left = "ae", right = "dm", by = list(list(left = "USUBJID", right = "USUBJID"))))
    expect_length(last("sideview_join_diagnostics")$derive_offers, 2L)
    session$setInputs(supp_check_request = list(id = "s1", parent = "sae", supp = "suppae", rdomain = "AE"))
    expect_length(last("sideview_supp_check")$derive_offers, 2L)
  })
})
