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
