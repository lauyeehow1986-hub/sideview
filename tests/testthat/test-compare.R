# Tests for the in-memory compare: sv_compare(), sv_compare_plan(), sv_compare_rows(), sv_compare_key().

cmp_cut1 <- function() {
  data.frame(
    USUBJID = c("S1", "S1", "S2", "S3", "S4"), AESEQ = c(1L, 2L, 1L, 1L, 1L),
    AESEV = c("MILD", "MILD", "SEVERE", "MILD", "MILD"), AEDY = c(3L, 5L, 7L, 9L, 11L),
    AESTDTC = c("2024-01-01", "2024-01-02", "2024-01-03", "2024-01-04", "2024-01-05"),
    ONLY1 = 1:5, stringsAsFactors = FALSE)
}

cmp_cut2 <- function() {
  data.frame(
    USUBJID = c("S1", "S1", "S2", "S3", "S5", "S6"), AESEQ = c(1L, 2L, 1L, 1L, 1L, 1L),
    AESEV = c("MODERATE", "MILD", "SEVERE", "SEVERE", "MILD", "MILD"), AEDY = c(3, 5, 8, 9, 20, 21),
    AESTDTC = as.Date(c("2024-01-01", "2024-01-02", "2024-01-03", "2024-01-04", "2024-01-05", "2024-01-06")),
    ONLY2 = letters[1:6], stringsAsFactors = FALSE)
}

cmp_keys <- c("USUBJID", "AESEQ")

# both identities of the build notes
expect_cmp_identities <- function(s) {
  a <- s$n_added %||% s$added; rm <- s$n_removed %||% s$removed; ch <- s$n_changed %||% s$changed
  expect_equal(a + ch + s$same + s$repeated_rows_new, s$n_new)
  expect_equal(rm + ch + s$same + s$repeated_rows_old, s$n_old)
}

cmp_run <- function(old, new, by) {
  plan <- sv_compare_plan(old, new, by)
  sv_compare_rows(old, new, plan)
}

test_that("added, removed, changed and same by key", {
  cut1 <- cmp_cut1(); cut2 <- cmp_cut2()
  r <- sv_compare(cut1, cut2, by = cmp_keys)
  expect_s3_class(r, "sv_compare")
  expect_equal(r$old_name, "cut1")
  expect_equal(r$new_name, "cut2")
  expect_equal(c(r$n_old, r$n_new), c(5L, 6L))
  expect_equal(c(r$n_added, r$n_removed, r$n_changed, r$same), c(2L, 1L, 3L, 1L))
  expect_equal(r$per_column, c(AESEV = 2L, AEDY = 1L))
  expect_equal(r$changed_values, 3L)
  expect_equal(names(r$added), names(cut2))
  expect_equal(r$added$USUBJID, c("S5", "S6"))
  expect_equal(names(r$removed), names(cut1))
  expect_equal(r$removed$USUBJID, "S4")
  expect_equal(names(r$changed), c("USUBJID", "AESEQ", "column", "old", "new"))
  expect_equal(r$changed$USUBJID, c("S1", "S2", "S3"))
  expect_equal(r$changed$column, c("AESEV", "AEDY", "AESEV"))
  expect_equal(r$changed$old, c("MILD", "7", "MILD"))
  expect_equal(r$changed$new, c("MODERATE", "8", "SEVERE"))
  expect_true(all(vapply(r$changed[c("column", "old", "new")], is.character, NA)))
  expect_equal(r$compared, c("AESEV", "AEDY"))
  expect_equal(r$only_old, "ONLY1")
  expect_equal(r$only_new, "ONLY2")
  expect_cmp_identities(r)
})

test_that("changed is ordered by key, then by the column order of new", {
  old <- data.frame(id = 1:2, a = c("x", "x"), b = c("p", "p"))
  new <- data.frame(id = 2:1, b = c("q", "q"), a = c("y", "y"))
  r <- sv_compare(old, new, by = "id")
  expect_equal(r$changed$id, c(1L, 1L, 2L, 2L))
  expect_equal(r$changed$column, c("b", "a", "b", "a"))
  expect_equal(unname(r$per_column), c(2L, 2L))
  expect_equal(names(r$per_column), c("b", "a"))
})

test_that("both identities hold", {
  fx <- list(
    list(cmp_cut1(), cmp_cut2()),
    list(data.frame(k = c(1, 1, 2, 3), v = 1:4), data.frame(k = c(1, 2, 2, 4), v = 1:4)),
    list(data.frame(k = c(1, 1, 1), v = 1:3), data.frame(k = c(1, 1, 1), v = 1:3)),
    list(data.frame(k = 1:3, v = 1:3)[0, ], data.frame(k = 1:3, v = 1:3)))
  for (f in fx) expect_cmp_identities(sv_compare_rows(f[[1]], f[[2]], sv_compare_plan(f[[1]], f[[2]], names(f[[1]])[1]))$summary)
})

test_that("repeated keys leave every count", {
  # repeated in old only
  old <- data.frame(k = c(7, 7, 1, 2), v = 1:4)
  new <- data.frame(k = c(7, 1, 2, 3), v = c(9L, 3L, 5L, 4L))
  r <- sv_compare(old, new, by = "k")
  expect_equal(c(r$repeated_keys, r$repeated_rows_old, r$repeated_rows_new), c(1L, 2L, 1L))
  expect_equal(c(r$n_added, r$n_removed, r$n_changed, r$same), c(1L, 0L, 1L, 1L))
  expect_false(any(c(r$added$k, r$removed$k, r$changed$k) == 7))
  expect_cmp_identities(r)
  # repeated in new only
  r <- sv_compare(new, old, by = "k")
  expect_equal(c(r$repeated_keys, r$repeated_rows_old, r$repeated_rows_new), c(1L, 1L, 2L))
  expect_false(any(c(r$added$k, r$removed$k, r$changed$k) == 7))
  expect_cmp_identities(r)
  # repeated in both, and a key repeated in each of two different ones
  o2 <- data.frame(k = c(7, 7, 8, 1), v = 1:4)
  n2 <- data.frame(k = c(7, 7, 7, 8, 8, 1), v = c(1:5, 4L))
  r <- sv_compare(o2, n2, by = "k")
  expect_equal(c(r$repeated_keys, r$repeated_rows_old, r$repeated_rows_new), c(2L, 3L, 5L))
  expect_equal(c(r$n_added, r$n_removed, r$n_changed, r$same), c(0L, 0L, 0L, 1L))
  expect_cmp_identities(r)
  expect_equal(r$repeated_sample, list(list(k = 7), list(k = 8)))
  # at most 5 sample keys when 7 repeat
  big <- data.frame(k = rep(1:7, each = 2), v = 1:14)
  big2 <- big
  r <- sv_compare(big, big2, by = "k")
  expect_equal(r$repeated_keys, 7L)
  expect_length(r$repeated_sample, 5L)
  expect_equal(r$repeated_sample[[1]], list(k = 1L))
  expect_match(r$text[length(r$text)], "^Warnings: 7 keys repeat: 14 rows in old, 14 in new, not compared$")
})

test_that("NA and NaN compare as missing", {
  old <- data.frame(id = 1:6, x = c(NA, NaN, NA, NA, NaN, 2))
  new <- data.frame(id = 1:6, x = c(NA, NaN, NaN, 1, 1, 2))
  r <- sv_compare(old, new, by = "id")
  expect_equal(c(r$n_changed, r$same), c(2L, 4L))
  expect_equal(r$changed$id, c(4L, 5L))
  expect_equal(r$changed$old, c(NA_character_, NA_character_))
  expect_equal(r$changed$new, c("1", "1"))
  r2 <- sv_compare(new, old, by = "id")
  expect_equal(r2$changed$new, c(NA_character_, NA_character_))
  expect_equal(r2$changed$old, c("1", "1"))
})

test_that("a key with NA matches", {
  old <- data.frame(USUBJID = c("S1", "S1"), AESEQ = c(NA, 2L), v = c("a", "b"))
  new <- data.frame(USUBJID = c("S1", "S1"), AESEQ = c(NA, 2L), v = c("z", "b"))
  r <- sv_compare(old, new, by = c("USUBJID", "AESEQ"))
  expect_equal(c(r$n_added, r$n_removed, r$n_changed, r$same), c(0L, 0L, 1L, 1L))
  expect_true(is.na(r$changed$AESEQ))
  expect_cmp_identities(r)
})

test_that("type changes are listed, not compared", {
  r <- sv_compare(cmp_cut1(), cmp_cut2(), by = cmp_keys)
  expect_equal(r$type_changed, list(list(column = "AESTDTC", old = "chr", new = "date")))
  expect_false("AESTDTC" %in% names(r$per_column))
  expect_match(r$text[3], "type changed AESTDTC (chr -> Date)", fixed = TRUE)
})

test_that("integer and double compare by value", {
  old <- data.frame(id = 1:3, n = c(3L, 4L, 5L))
  new <- data.frame(id = 1:3, n = c(3, 4, 6))
  r <- sv_compare(old, new, by = "id")
  expect_equal(r$compared, "n")
  expect_equal(r$changed$id, 3L)
  expect_equal(r$changed$old, "5")
  expect_equal(r$changed$new, "6")
  expect_equal(r$same, 2L)
})

test_that("factor and character compare", {
  old <- data.frame(id = 1:3, x = factor(c("a", "b", "c")))
  new <- data.frame(id = 1:3, x = c("a", "c", "c"), stringsAsFactors = FALSE)
  r <- sv_compare(old, new, by = "id")
  expect_length(r$type_changed, 0L)
  expect_equal(r$per_column, c(x = 1L))
  expect_equal(r$changed$old, "b")
  expect_equal(r$changed$new, "c")
  same <- sv_compare(old, data.frame(id = 1:3, x = c("a", "b", "c")), by = "id")
  expect_equal(c(same$n_changed, same$same), c(0L, 3L))
})

test_that("keys of differing kinds compare as text", {
  old <- data.frame(USUBJID = c("S1", "S2"), AESEQ = c(1L, 2L), v = c("a", "b"))
  new <- data.frame(USUBJID = c("S1", "S3"), AESEQ = c("1", "1"), v = c("z", "c"), stringsAsFactors = FALSE)
  plan <- sv_compare_plan(old, new, c("USUBJID", "AESEQ"))
  expect_equal(vapply(plan$keys, function(k) k$text, NA), c(FALSE, TRUE))
  r <- sv_compare(old, new, by = c("USUBJID", "AESEQ"))
  expect_equal(c(r$n_added, r$n_removed, r$n_changed, r$same), c(1L, 1L, 1L, 0L))
  expect_type(r$added$AESEQ, "character")
  expect_type(r$removed$AESEQ, "integer")
  expect_type(r$changed$AESEQ, "character")
  expect_equal(r$changed$AESEQ, "1")
  expect_false(any(grepl("^\\.sv_k", c(names(r$added), names(r$removed), names(r$changed)))))
  expect_cmp_identities(r)
})

test_that("empty and identical versions", {
  cut2 <- cmp_cut2()
  cut2b <- cut2
  r <- sv_compare(cut2, cut2b, by = cmp_keys)
  expect_equal(c(r$n_added, r$n_removed, r$n_changed, r$same), c(0L, 0L, 0L, 6L))
  expect_equal(c(nrow(r$added), nrow(r$removed), nrow(r$changed)), c(0L, 0L, 0L))
  expect_equal(names(r$changed), c("USUBJID", "AESEQ", "column", "old", "new"))
  expect_equal(r$open$added, "Open added rows (0)")
  expect_cmp_identities(r)
  # zero-row old: every new row is added
  empty <- cmp_cut1()[0, ]
  r <- sv_compare(empty, cut2, by = cmp_keys)
  expect_equal(c(r$n_added, r$n_removed, r$n_changed, r$same, r$n_old), c(6L, 0L, 0L, 0L, 0L))
  expect_equal(nrow(r$added), 6L)
  expect_cmp_identities(r)
  # zero-row new
  r <- sv_compare(cmp_cut1(), cut2[0, ], by = cmp_keys)
  expect_equal(c(r$n_added, r$n_removed, r$same), c(0L, 5L, 0L))
  # factor against character: no changed rows
  f <- data.frame(id = 1:2, x = factor(c("a", "b")))
  r <- sv_compare(f, data.frame(id = 1:2, x = c("a", "b")), by = "id")
  expect_equal(r$n_changed, 0L)
})

test_that("bad keys are refused", {
  cut1 <- cmp_cut1(); cut2 <- cmp_cut2()
  expect_error(sv_compare_plan(cut1, cut2, character(0)), "Pick the key columns.", fixed = TRUE)
  expect_error(sv_compare_plan(cut1, cut2, "NOPE", "cut1", "cut2"), "Not in cut1: NOPE", fixed = TRUE)
  expect_error(sv_compare_plan(cut1, cut2, "ONLY2", "cut1", "cut2"), "Not in cut1: ONLY2", fixed = TRUE)
  expect_error(sv_compare_plan(cut1, cut2, "ONLY1", "cut1", "cut2"), "Not in cut2: ONLY1", fixed = TRUE)
  expect_error(sv_compare_plan(cut1, cut1, "USUBJID", "same", "same"), "Pick two different tables.", fixed = TRUE)
  expect_error(sv_compare(cut1, cut1, by = "USUBJID"), "Pick two different tables.", fixed = TRUE)
  wide <- as.data.frame(stats::setNames(rep(list(1:2), 21), paste0("c", 1:21)))
  expect_error(sv_compare_plan(wide, wide, names(wide), "a", "b"),
               "A derived table takes at most 20 key pairs.", fixed = TRUE)
  lc <- data.frame(id = 1:2); lc$l <- list(1, 2)
  expect_error(sv_compare_plan(lc, lc, "l", "a", "b"),
               "Column l in a is a list column; it cannot be a key.", fixed = TRUE)
  expect_error(sv_compare(cut1, data.frame(zz = 1)), "Pick the key columns.", fixed = TRUE)
  expect_error(sv_compare(1:3, cut2, by = "x"), "data frames")
})

test_that("key suggestion", {
  old <- cmp_cut1(); new <- cmp_cut2()
  tag <- list(domain = "AE", standard = "SDTM")
  expect_equal(sv_compare_key(old, new, tag, tag), c("USUBJID", "AESEQ"))
  # a tag on one card only, or two different domains, uses the shared-name rule
  a <- data.frame(id = 1:30, note = paste0("n", 1:30))
  b <- data.frame(id = 1:30, other = paste0("o", 1:30))
  expect_equal(sv_compare_key(a, b), "id")
  expect_equal(sv_compare_key(a, data.frame(zz = 1:3)), character(0))
  expect_equal(sv_compare(a, b)$by, "id")
  # a repeated shared column is not a key: the unique id is
  r1 <- data.frame(id = 1:30, sev = rep(c("MILD", "SEVERE"), 15), n = 1:30)
  r2 <- r1; r2$sev[1] <- "X"
  expect_equal(sv_compare_key(r1, r2), "id")
  # no single column is unique, a two-column combination is
  c1 <- data.frame(g = rep(1:10, each = 3), h = rep(1:3, 10), v = rep(c("a", "b"), 15))
  c2 <- c1; names(c2)[3] <- "w"
  expect_equal(sv_compare_key(c1, c2), c("g", "h"))
  # nothing is unique
  d1 <- data.frame(g = rep(1:10, each = 3), h = rep(1:3, 10))[rep(1:30, 2), ]
  expect_equal(sv_compare_key(d1, d1), character(0))
})

test_that("text and labels", {
  cut1 <- cmp_cut1(); cut2 <- cmp_cut2()
  r <- sv_compare(cut1, cut2, by = cmp_keys)
  expect_snapshot(print(r))
  expect_equal(r$open$changed, "Open changed values (3 rows)")
  expect_equal(r$open$added, "Open added rows (2)")
  expect_equal(r$open$removed, "Open removed rows (1)")
  one <- list(added = 1L, removed = 0L, changed_values = 1L)
  expect_equal(sv_say_compare_open(one)$changed, "Open changed values (1 row)")
  # the by-column line: highest first, ties in new's order, zero counts left out
  s <- cmp_run(cmp_cut1(), cmp_cut2(), cmp_keys)$summary
  s$old_name <- "cut1"; s$new_name <- "cut2"
  s$per_column <- c(A = 1L, B = 3L, C = 0L, D = 3L)
  expect_match(sv_say_compare_text(s)[4], "^Changed values by column:  B 3 · D 3 · A 1$")
  s$per_column <- c(A = 0L)
  expect_match(sv_say_compare_text(s)[4], "none$")
  expect_length(sv_say_compare_text(s), 4L)
})

test_that("in-memory code parses, runs with dplyr only and rebuilds", {
  check <- function(cut1, cut2, by) {
    r <- sv_compare(cut1, cut2, by = by)
    env <- list2env(list(cut1 = cut1, cut2 = cut2), parent = baseenv())
    for (op in c("compare_added", "compare_removed", "compare_changed")) {
      key <- sub("^compare_", "", op)
      code <- r$code[[key]]
      expect_parses(code)
      expect_false(grepl("[|]>|%>%|sv_[a-z_]+[(]", code))
      got <- eval(parse(text = code), env)
      expect_equal(as.data.frame(got), as.data.frame(r[[key]]), ignore_attr = "row.names")
    }
    r
  }
  # the main fixture, a repeated key (one version only), NA on both sides of a key
  check(cmp_cut1(), cmp_cut2(), cmp_keys)
  check(data.frame(k = c(7, 7, 1, 2), v = 1:4), data.frame(k = c(7, 1, 2, 3), v = c(9L, 3L, 5L, 4L)), "k")
  check(data.frame(k = c(1L, NA, 3L), v = c("a", "b", "c")), data.frame(k = c(1L, NA, 4L), v = c("a", "z", "d")), "k")
  # NA / NaN values, factor against character, differing key kinds, no compared column, a zero-row old
  check(data.frame(id = 1:6, x = c(NA, NaN, NA, NA, NaN, 2)), data.frame(id = 1:6, x = c(NA, NaN, NaN, 1, 1, 2)), "id")
  check(data.frame(id = 1:3, f = factor(c("a", "b", "c"))), data.frame(id = 1:3, f = c("a", "x", "c")), "id")
  r <- check(data.frame(USUBJID = c("S1", "S2"), AESEQ = c(1L, 2L), v = c("a", "b")),
             data.frame(USUBJID = c("S1", "S3"), AESEQ = c("1", "1"), v = c("z", "c")), c("USUBJID", "AESEQ"))
  expect_match(r$code$changed, ".sv_k2", fixed = TRUE)
  check(data.frame(id = 1:3), data.frame(id = 2:4), "id")
  check(data.frame(id = integer(0), v = character(0)), data.frame(id = 1:2, v = c("a", "b")), "id")
  # date-times are text in their own zone; non-syntactic names
  t1 <- as.POSIXct("2024-01-01 10:00:00", tz = "UTC") + c(0, 3600)
  check(data.frame(id = 1:2, t = t1), data.frame(id = 1:2, t = t1 + c(60, 0)), "id")
  odd1 <- stats::setNames(data.frame(1:2, c(1, 2)), c("visit id", "visit date"))
  odd2 <- stats::setNames(data.frame(1:2, c(1, 3)), c("visit id", "visit date"))
  r <- check(odd1, odd2, "visit id")
  expect_equal(r$changed$column, "visit date")
  # the lazy form is not written yet
  plan <- sv_compare_plan(cmp_cut1(), cmp_cut2(), cmp_keys)
  expect_error(sv_compare_code(plan, c("a", "b"), c("duckdb", NA), "compare_added"), "not yet written")
  expect_equal(sv_compare_code(plan, c("cut1", "cut2"), c(NA, NA), "compare_added")$kind, NA_character_)
})
