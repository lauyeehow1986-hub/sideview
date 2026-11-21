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
    # a check-level error (no SUPP rows for the RDOMAIN) is a reply with an error, not an exception
    session$setInputs(supp_check_request = list(id = "s3", parent = "sae", supp = "suppae", rdomain = "CM"))
    s3 <- last("sideview_supp_check")
    expect_false(is.null(s3$error))
    expect_null(s3$derive_offers)
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

stack_store <- function(tags = NULL) {
  w1 <- data.frame(AGE = c(34, 51), RACE = c("a", "b"), stringsAsFactors = FALSE)
  attr(w1$RACE, "label") <- "Race"
  w2 <- data.frame(AGE = c("29", "x", "40"), RACE = c("c", "d", "e"), stringsAsFactors = FALSE)
  w3 <- data.frame(AGE = 60, RACE = "f", source = "own", stringsAsFactors = FALSE)
  cards <- list(sv_normalize(w1, name = "wave1"), sv_normalize(w2, name = "wave2"), sv_normalize(w3, name = "wave3"))
  for (i in seq_along(tags)) cards[[i]]$cdisc <- if (is.na(tags[i])) NULL else list(domain = tags[i])
  sv_card_store(cards)
}

test_that("stack derive card: name, rows, tag, args", {
  req <- list(op = "stack", inputs = list("wave1", "wave2"), args = list(fixes = list()))
  card <- sv_derive_card(req, stack_store(c("AE", "AE")), NULL)
  expect_equal(card$name, "wave1_stacked")
  expect_equal(card$dims[1], 5L)
  expect_equal(card$derived$args$plan$id_col, "source")
  expect_equal(card$col_labels[["RACE"]], "Race")
  expect_equal(card$cdisc$domain, "AE")
  expect_equal(card$derived$op, "stack")
  expect_null(sv_derive_card(req, stack_store(c("AE", "DM")), NULL)$cdisc)
  expect_null(sv_derive_card(req, stack_store(c("AE", NA)), NULL)$cdisc)
  # a rebuild from the stored recipe gives the same rows
  store <- stack_store()
  card <- sv_derive_card(list(op = "stack", inputs = list("wave1", "wave2", "wave3"),
                              args = list(fixes = list(list(column = "AGE", action = "cast", to = "chr")))),
                         store, NULL)
  expect_equal(card$derived$args$plan$id_col, "source_2")
  again <- sv_derive_card(sv_derive_request_of(card), store, NULL)
  expect_equal(again$data, card$data)
})

test_that("stack requests are cleaned", {
  store <- stack_store()
  before <- store$names()
  req <- function(inputs, args = list()) list(op = "stack", inputs = as.list(inputs), args = args)
  expect_error(sv_derive_clean(req("wave1"), store), "A stack needs 2 to 8 tables.")
  expect_error(sv_derive_clean(req(rep("wave1", 9)), store), "A stack needs 2 to 8 tables.")
  expect_error(sv_derive_clean(req(c("wave1", "wave1")), store), "A table can be stacked only once.")
  expect_error(sv_derive_clean(req(c("wave1", "nope")), store), "Not in the canvas: nope")
  expect_error(sv_derive_clean(req(c("wave1", "wave2"),
    list(fixes = list(list(column = "AGE", action = "cast", to = "chr", extra = "x")))), store))
  expect_error(sv_derive_clean(req(c("wave1", "wave2"), list(fixes = list(list(column = "AGE")))), store))
  expect_error(sv_derive_clean(req(c("wave1", "wave3"), list(id_col = "source")), store), "source is a column of wave3.")
  expect_error(sv_derive_clean(list(op = "unmatched", inputs = list("wave1", "wave2", "wave3")), store),
               "two input tables")
  expect_equal(store$names(), before)
  ok <- sv_derive_clean(req(c("wave1", "wave2"), list(id_col = "src", junk = 1)), store)
  expect_equal(ok$args$id_col, "src")
  expect_null(ok$args$junk)
  expect_null(sv_derive_validate(req(c("wave1", "wave2")), store))
  expect_match(sv_derive_validate(req("wave1"), store), "A stack needs")
})

test_that("without duckdb a whole lazy card is never stacked from its preview", {
  store <- stack_store()
  testthat::local_mocked_bindings(sv_has_duckdb = function() FALSE)
  whole <- function(cd) identical(cd$name, "wave1")
  expect_error(sv_stack_clean(c("wave1", "wave2"), list(), store, card_full = whole),
               "Stacking a duckdb or Arrow table needs duckdb.", fixed = TRUE)
  expect_match(sv_derive_validate(list(op = "stack", inputs = list("wave1", "wave2")), store, card_full = whole),
               "needs duckdb", fixed = TRUE)
  # in-memory cards stack as before
  expect_equal(sv_stack_clean(c("wave1", "wave2"), list(), store, card_full = function(cd) FALSE)$inputs,
               c("wave1", "wave2"))
})

test_that("stack_check_request replies with the columns, counts, text and code; a fix changes the plan; Open adds the card", {
  cards <- stack_store()$names()
  cards <- sv_normalize_cards(list(
    wave1 = data.frame(AGE = c(34, 51), RACE = c("a", "b"), stringsAsFactors = FALSE),
    wave2 = data.frame(AGE = c("29", "x", "40"), RACE = c("c", "d", "e"), stringsAsFactors = FALSE)))
  shiny::testServer(sideview_server(cards), {
    last <- function(type) {
      m <- Filter(function(z) identical(z$type, type), session$userData$custom_messages)
      m[[length(m)]]$message
    }
    session$setInputs(stack_check_request = list(id = "k1", tables = list("wave1", "wave2")))
    r <- last("sideview_stack_check")
    expect_identical(r$id, "k1")
    expect_null(r$error)
    expect_equal(r$n_rows, 5L)
    expect_identical(r$id_col, "source")
    age <- r$columns[[which(vapply(r$columns, function(c) c$name, "") == "AGE")]]
    expect_identical(unlist(age$table), c("num", "chr"))
    expect_identical(age$target, "chr")
    expect_true(length(r$text) >= 1L)
    expect_match(r$open_label, "Open stacked card (5 rows", fixed = TRUE)
    expect_identical(r$name, "wave1_stacked")
    expect_false(inherits(try(parse(text = r$code_preview), silent = TRUE), "try-error"))
    # a cast fix changes the target and the NA count
    session$setInputs(stack_check_request = list(id = "k2", tables = list("wave1", "wave2"),
      fixes = list(list(column = "AGE", action = "cast", to = "num"))))
    r2 <- last("sideview_stack_check")
    age2 <- r2$columns[[which(vapply(r2$columns, function(c) c$name, "") == "AGE")]]
    expect_identical(age2$target, "num")
    expect_identical(sum(unlist(age2$na), na.rm = TRUE), 1L)
    # a refused request is an error reply
    session$setInputs(stack_check_request = list(id = "k3", tables = list("wave1", "nope")))
    expect_match(last("sideview_stack_check")$error, "Not in the canvas")
    # an id R cannot echo is not dropped silently: no reply (none could reach the pane), a toast that says why
    n_before <- length(Filter(function(z) identical(z$type, "sideview_stack_check"), session$userData$custom_messages))
    session$setInputs(stack_check_request = list(id = strrep("x", 201), tables = list("wave1", "wave2")))
    expect_length(Filter(function(z) identical(z$type, "sideview_stack_check"), session$userData$custom_messages), n_before)
    expect_match(last("sideview_toast")$text, "request id is missing or longer than 200", fixed = TRUE)
    # Open: the same fixes, through derive_request
    session$setInputs(derive_request = list(id = "d1", op = "stack", inputs = list("wave1", "wave2"),
      args = list(fixes = list(list(column = "AGE", action = "cast", to = "num")))))
    m <- Filter(function(z) identical(z$type, "sideview_card_add"), session$userData$custom_messages)
    card <- m[[length(m)]]$message$card
    expect_identical(card$totalRows, r2$n_rows)
  })
})

compare_store <- function(tags = NULL) {
  c1 <- data.frame(id = 1:4, sev = c("MILD", "MILD", "SEVERE", "MILD"), stringsAsFactors = FALSE)
  attr(c1$sev, "label") <- "Severity"
  c2 <- data.frame(id = 2:5, sev = c("MILD", "MODERATE", "SEVERE", "MILD"), stringsAsFactors = FALSE)
  attr(c2$sev, "label") <- "Severity 2"
  cards <- list(sv_normalize(c1, name = "cut1"), sv_normalize(c2, name = "cut2"))
  for (i in seq_along(tags)) cards[[i]]$cdisc <- if (is.na(tags[i])) NULL else list(domain = tags[i])
  sv_card_store(cards)
}

test_that("compare derive cards: names, rows, tags, args", {
  store <- compare_store(c("AE", "AE"))
  req <- function(op) list(op = op, inputs = list("cut1", "cut2"), args = list(by = list("id")))
  rem <- sv_derive_card(req("compare_removed"), store, NULL)
  add <- sv_derive_card(req("compare_added"), store, NULL)
  chg <- sv_derive_card(req("compare_changed"), store, NULL)
  expect_equal(c(rem$name, add$name, chg$name), c("cut1_removed", "cut2_added", "cut2_changed"))
  s <- sv_compare(data.frame(id = 1:4, sev = c("MILD", "MILD", "SEVERE", "MILD")),
                  data.frame(id = 2:5, sev = c("MILD", "MODERATE", "SEVERE", "MILD")), by = "id")
  expect_equal(c(rem$dims[1], add$dims[1], chg$dims[1]), c(s$n_removed, s$n_added, nrow(s$changed)))
  expect_equal(chg$dims[1], 2L)
  expect_equal(rem$derived$args$plan$by, "id")
  expect_equal(add$derived$args$by, "id")
  expect_equal(c(rem$cdisc$domain, add$cdisc$domain), c("AE", "AE"))
  expect_null(chg$cdisc)
  expect_equal(rem$col_labels[["sev"]], "Severity")
  expect_equal(add$col_labels[["sev"]], "Severity 2")
  expect_null(chg$col_labels)
  # untagged cards give untagged cards; the tag of each side is its own
  expect_null(sv_derive_card(req("compare_added"), compare_store(c("AE", NA)), NULL)$cdisc)
  expect_equal(sv_derive_card(req("compare_removed"), compare_store(c("AE", NA)), NULL)$cdisc$domain, "AE")
  # a second open of the same card is named _2, and a rebuild from the stored recipe gives the same rows
  store$add(add)
  again <- sv_derive_card(req("compare_added"), store, NULL)
  expect_equal(again$name, "cut2_added_2")
  expect_equal(sv_derive_card(sv_derive_request_of(chg), compare_store(), NULL)$data, chg$data)
  expect_equal(sv_derive_rows("compare_added", list(cut1 = compare_store()$get("cut1")$data,
                                                    cut2 = compare_store()$get("cut2")$data),
                              list(by = "id"))$id, 5L)
})

test_that("compare requests are cleaned", {
  store <- compare_store()
  before <- store$names()
  req <- function(inputs = c("cut1", "cut2"), by = list("id"), args = NULL) {
    list(op = "compare_added", inputs = as.list(inputs), args = c(list(by = by), args))
  }
  expect_error(sv_derive_clean(req(by = list()), store), "Pick the key columns.")
  expect_error(sv_derive_clean(req(by = list("nope")), store), "Not in cut1: nope")
  expect_error(sv_derive_clean(req(inputs = c("cut1", "cut1")), store), "Pick two different tables.")
  expect_error(sv_derive_clean(req(inputs = c("cut1", "gone")), store), "Not in the canvas: gone")
  expect_error(sv_derive_clean(req(by = as.list(paste0("k", 1:21))), store), "at most 20 key pairs")
  expect_error(sv_derive_clean(req(by = list(1)), store), "Pick the key columns.")
  expect_error(sv_derive_clean(req(by = list(list("id", "sev"))), store), "Pick the key columns.")
  expect_error(sv_derive_clean(list(op = "compare_added", inputs = list("cut1")), store), "two input tables")
  expect_error(sv_compare_clean("cut1", "cut2", "id", store, card_full = function(cd) FALSE)$by, NA)
  expect_equal(store$names(), before)
  # only `by` is read from args
  ok <- sv_derive_clean(req(args = list(junk = 1, plan = "x", side = "y")), store)
  expect_equal(names(ok$args), c("by", "plan"))
  expect_equal(ok$args$by, "id")
  expect_null(sv_derive_validate(req(), store))
  expect_match(sv_derive_validate(req(by = list()), store), "Pick the key")
  cl <- sv_compare_clean("cut1", "cut2", c("id", "id"), store)
  expect_equal(names(cl), c("inputs", "cards", "by", "plan"))
  expect_equal(cl$by, "id")
})

# A saved workspace (as the browser writes it) whose pipeline holds `steps`
compare_state <- function(steps) {
  sv_state_from_json(jsonlite::toJSON(
    list(version = "0.3.0", cards = list(), pipeline = list(steps = steps)),
    auto_unbox = TRUE, null = "null", na = "null", digits = NA))
}

compare_step <- function(op, table, plan = NULL) {
  list(kind = "derive", key = paste0("k_", op), table = table, op = op, inputs = list("cut1", "cut2"),
       args = c(list(by = list("id")), if (!is.null(plan)) list(plan = plan)))
}

test_that("state refresh refits compare args", {
  store <- compare_store()
  req <- function(op) list(op = op, inputs = list("cut1", "cut2"), args = list(by = list("id")))
  cards <- c(store$all(), list(sv_derive_card(req("compare_changed"), store, NULL),
                               sv_derive_card(req("compare_added"), store, NULL)))
  # a plan saved when the data were other: no compared column, a key that is gone
  stale <- list(by = "old_id", keys = list(), compared = list(), type_changed = list(),
                only_old = list(), only_new = list(), lazy = FALSE)
  st <- compare_state(list(compare_step("compare_changed", "cut2_changed", stale),
                           compare_step("compare_added", "cut2_added", stale),
                           compare_step("compare_removed", "cut1_removed", stale)))
  out <- sv_derive_state_refresh(st, cards)
  fresh <- cards[[3]]$derived$args
  expect_identical(out$pipeline$steps[[1]]$args, fresh)
  expect_equal(out$pipeline$steps[[1]]$args$plan$by, "id")
  expect_equal(out$pipeline$steps[[1]]$args$plan$compared[[1]]$name, "sev")
  expect_identical(out$pipeline$steps[[2]]$args, cards[[4]]$derived$args)
  # a step with no card of its name keeps what was saved
  expect_equal(out$pipeline$steps[[3]]$args$plan$by, "old_id")
  # a card of the step's name made by another op does not refit it
  wrong <- cards[[3]]
  wrong$name <- "cut1_removed"
  wrong$derived$op <- "compare_added"
  out2 <- sv_derive_state_refresh(st, c(cards, list(wrong)))
  expect_equal(out2$pipeline$steps[[3]]$args$plan$by, "old_id")
})

test_that("a saved state rebuilds the compare cards", {
  store <- compare_store()
  req <- function(op) list(op = op, inputs = list("cut1", "cut2"), args = list(by = list("id")))
  before <- lapply(c("compare_added", "compare_removed", "compare_changed"), function(op) {
    sv_derive_card(req(op), store, NULL)
  })
  steps <- lapply(before, function(cd) {
    list(kind = "derive", key = paste0("k_", cd$derived$op), table = cd$name, op = cd$derived$op,
         inputs = as.list(cd$derived$inputs), args = cd$derived$args)
  })
  st <- compare_state(steps)
  out <- sv_derive_from_state(compare_store()$all(), st)
  expect_length(out, 5L)
  built <- unname(out[3:5])
  expect_identical(vapply(built, function(cd) cd$name, ""), vapply(before, function(cd) cd$name, ""))
  expect_identical(lapply(built, function(cd) cd$dims), lapply(before, function(cd) cd$dims))
  expect_identical(lapply(built, function(cd) cd$derived$op), lapply(before, function(cd) cd$derived$op))
  for (i in 1:3) expect_equal(built[[i]]$data, before[[i]]$data, ignore_attr = TRUE)
})
