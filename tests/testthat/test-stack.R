# Tests for the stack column check: sv_stack_check(), sv_stack_plan(), sv_stack_cast(), sv_stack_type().

stack_pair <- function(a, b, nm = "V") {
  t1 <- data.frame(a, stringsAsFactors = FALSE); names(t1) <- nm
  t2 <- data.frame(b, stringsAsFactors = FALSE); names(t2) <- nm
  sv_stack_plan(list(wave1 = t1, wave2 = t2))$columns[[1]]
}

test_that("types and the default target follow the cast order", {
  d <- as.Date("2024-01-01"); p <- as.POSIXct("2024-01-01 10:00:00", tz = "UTC")
  expect_equal(stack_pair(TRUE, 1L)$target, "int")
  expect_equal(stack_pair(1L, 1.5)$target, "num")
  expect_equal(stack_pair(1.5, "a")$target, "chr")
  expect_equal(stack_pair(d, "a")$target, "chr")
  expect_equal(stack_pair(d, p)$target, "dttm")
  expect_equal(stack_pair(factor("x"), "a")$target, "chr")
  expect_equal(stack_pair(TRUE, "a")$target, "chr")
  f <- stack_pair(factor(c("x", "y")), factor(c("y", "z")))
  expect_equal(f$target, "fct")
  expect_equal(f$levels, c("x", "y", "z"))
  expect_true(f$levels_differ)
  expect_equal(stack_pair(factor("x", ordered = TRUE), factor("x"))$target, "chr")
  expect_equal(sv_stack_type(Sys.time()), "dttm")
  expect_equal(sv_stack_type(factor("a", ordered = TRUE)), "fct")
  expect_equal(attr(sv_stack_type(as.difftime(1, units = "secs")), "class1"), "difftime")
})

test_that("offered targets come from the cast table", {
  expect_equal(stack_pair(1.5, "a")$targets, c("chr", "num"))
  expect_equal(stack_pair(as.Date("2024-01-01"), 1.5)$targets, "chr")
  t1 <- data.frame(V = TRUE); t2 <- data.frame(V = 1L); t3 <- data.frame(V = 1.5)
  col <- sv_stack_plan(list(a = t1, b = t2, c = t3))$columns[[1]]
  expect_equal(col$targets, c("num", "chr", "lgl", "int"))
})

test_that("casts convert exactly or give NA, and NA is counted", {
  nas <- function(x, r) sum(is.na(r) & !is.na(x))
  x <- c("12", " 12 ", "\t12", "1e5", "0x1A", "Inf", "", "1e999", NA)
  r <- sv_stack_cast(x, "chr", "num")
  expect_equal(r, c(12, 12, 12, 1e5, NA, NA, NA, NA, NA))
  expect_equal(nas(x, r), 4L)  # the input NA was already missing
  y <- c(1, 2.5, NaN, 3e9, NA)
  r <- sv_stack_cast(y, "num", "int")
  expect_equal(r, c(1L, NA, NA, NA, NA))
  expect_equal(nas(y, r), 2L)
  z <- c(0L, 1L, 2L)
  r <- sv_stack_cast(z, "int", "lgl")
  expect_equal(r, c(FALSE, TRUE, NA))
  expect_equal(nas(z, r), 1L)
  expect_equal(sv_stack_cast(as.POSIXct("2024-01-01", tz = "UTC"), "dttm", "chr", "UTC"), "2024-01-01 00:00:00")
  r <- sv_stack_cast(as.Date("2024-01-01"), "date", "dttm")
  expect_equal(as.numeric(r), as.numeric(as.POSIXct("2024-01-01", tz = "UTC")))
  expect_equal(sv_stack_cast(c("2024-02-30", "2024-02-29"), "chr", "date"), as.Date(c(NA, "2024-02-29")))
  expect_equal(sv_stack_cast(c("TRUE", "true"), "chr", "lgl"), c(TRUE, NA))
})

test_that("near-miss is flagged, never merged, and the rename fix merges it", {
  w1 <- data.frame(AGE = c(1, 2)); w2 <- data.frame(Age = c("3", "4"))
  p <- sv_stack_plan(list(wave1 = w1, wave2 = w2))
  expect_length(p$columns, 2L)
  expect_equal(p$columns[[2]]$status, "near-miss for AGE? (case)")
  expect_equal(p$columns[[2]]$near_miss_of, "AGE")
  chk <- sv_stack_check(w1, w2, rename = c(Age = "AGE"))
  expect_length(chk$columns, 1L)
  expect_equal(chk$columns[[1]]$name, "AGE")
  expect_equal(chk$columns[[1]]$target, "chr")  # num + chr
  expect_equal(chk$columns[[1]]$rename_from, c(NA, "Age"))
  expect_error(sv_stack_check(w1, w2, rename = c(Age = "RACE")), "is not a near-miss of")
  # names that clash inside one input are not a near-miss
  w3 <- data.frame(AGE = 1, Age = 2)
  expect_equal(sv_stack_plan(list(a = w3, b = w1))$columns[[2]]$near_miss_of, NA_character_)
})

test_that("labels: first kept, differences listed", {
  w1 <- data.frame(RACE = "a"); attr(w1$RACE, "label") <- "Race"
  w2 <- data.frame(RACE = "b"); attr(w2$RACE, "label") <- "RACE"
  p <- sv_stack_plan(list(wave1 = w1, wave2 = w2))
  expect_equal(p$kept_labels[["RACE"]], "Race")
  expect_equal(p$columns[[1]]$status, "label differs (wave1 label kept)")
})

test_that("a column in some inputs only", {
  w1 <- data.frame(A = 1, B = 2); w2 <- data.frame(A = 3); w3 <- data.frame(A = 4, B = 5)
  p <- sv_stack_plan(list(wave1 = w1, wave2 = w2))
  b <- p$columns[[2]]
  expect_equal(b$status, "only in wave1 (NA in wave2)")
  expect_equal(sum(b$na, na.rm = TRUE), 0)
  p3 <- sv_stack_plan(list(wave1 = w1, wave2 = w2, wave3 = w3))
  expect_equal(p3$columns[[2]]$status, "only in wave1, wave3 (NA in wave2)")
  expect_equal(p3$n_rows, 3L)
  expect_equal(p3$id_col, "source")
})

test_that("id column avoids an existing source column", {
  w1 <- data.frame(source = 1); w2 <- data.frame(source = 2)
  expect_equal(sv_stack_plan(list(a = w1, b = w2))$id_col, "source_2")
})

test_that("status text and summary lines", {
  wave1 <- data.frame(AGE = c(1, 2), N = 1L); wave2 <- data.frame(Age = c("3", "x"), N = 2.5)
  chk <- sv_stack_check(wave1, wave2, cast = c(N = "chr"))
  expect_equal(chk$table$Status, c("only in wave1 (NA in wave2)", "type differs -> as.character", "near-miss for AGE? (case)"))
  chk <- sv_stack_check(wave1, wave2)
  expect_equal(chk$table$Status[2], "type differs -> as.numeric")
  wave3 <- data.frame(AGE = c("1", "z"))
  chk <- sv_stack_check(data.frame(AGE = 1), wave3)
  expect_equal(chk$table$Status, "type differs -> as.character")
  chk <- sv_stack_check(wave3, data.frame(AGE = 1), cast = c(AGE = "num"))
  expect_equal(chk$table$Status, "type differs -> as.numeric; 1 value in wave3 becomes NA")
  expect_equal(chk$text[1], "Stack 2 tables: 3 rows, 2 columns.")
  expect_equal(chk$text[2], "1 column changes type; 1 value becomes NA.")
  expect_equal(sv_say_stack_open(chk), "Open stacked card (3 rows; 1 value becomes NA)")
  chk <- sv_stack_check(wave1, wave2)
  expect_equal(chk$text[length(chk$text)], "1 near-miss name left apart.")
  expect_equal(sv_say_stack_open(chk), "Open stacked card (4 rows)")
})

test_that("bad fixes are refused", {
  w1 <- data.frame(A = 1); w2 <- data.frame(A = "x")
  expect_error(sv_stack_check(w1, w2, cast = c(ZZ = "chr")), "Not in the stack: ZZ")
  expect_error(sv_stack_check(w1, w2, cast = c(A = "lgl")), "A cannot be cast to lgl")
  expect_error(sv_stack_check(w1, w2, cast = c(A = "chr", A = "num", A = "chr")), "Too many fixes")
  wl <- data.frame(A = 1); wl$L <- list(1)
  expect_error(sv_stack_check(w1, wl), "Column L in wl is a list column; it cannot be stacked.")
})

test_that("print shows the table", {
  wave1 <- data.frame(AGE = c(1, 2), SEX = c("F", "M"))
  wave2 <- data.frame(AGE = c("3", "4"), SEX = c("F", "F"), SITE = 1:2)
  expect_snapshot(print(sv_stack_check(wave1, wave2)))
})

stack_waves <- function() {
  w1 <- data.frame(AGE = c(34, 51), RACE = c("a", "b"), stringsAsFactors = FALSE)
  attr(w1$RACE, "label") <- "Race"
  w2 <- data.frame(AGE = c("29", "x", "40"), RACE = c("c", "d", "e"), SITE = 1:3, stringsAsFactors = FALSE)
  w3 <- data.frame(AGE = 60, RACE = "f", stringsAsFactors = FALSE)
  list(wave1 = w1, wave2 = w2, wave3 = w3)
}

test_that("rows equal bind_rows and the sum of inputs", {
  w <- stack_waves()
  wave1 <- w$wave1; wave2 <- w$wave2; wave3 <- w$wave3
  res <- sv_stack(wave1, wave2, wave3)
  expect_equal(nrow(res), nrow(wave1) + nrow(wave2) + nrow(wave3))
  expect_equal(unique(res$source), c("wave1", "wave2", "wave3"))
  expect_equal(names(res), c("source", "AGE", "RACE", "SITE"))
  # AGE becomes chr (num + chr)
  exp <- dplyr::bind_rows(wave1 = dplyr::mutate(wave1, AGE = as.character(AGE)), wave2 = wave2,
                          wave3 = dplyr::mutate(wave3, AGE = as.character(AGE)), .id = "source")
  strip <- function(d) { for (n in names(d)) attr(d[[n]], "label") <- NULL; d }
  expect_equal(strip(res), strip(exp))
})

test_that("id column avoids taken names", {
  a <- data.frame(source = 1, x = 1); b <- data.frame(source = 2, source_2 = 3, x = 2)
  res <- sv_stack(a, b)
  expect_equal(names(res)[1], "source_3")
  expect_equal(res$source, c(1, 2))
  expect_equal(res$source_3, c("a", "b"))
  expect_match(sv_stack_check(a, b)$code, ".id = \"source_3\"", fixed = TRUE)
})

test_that("zero-row input and all-NA logical column", {
  a <- data.frame(V = c("x", "y"), stringsAsFactors = FALSE)
  b <- data.frame(V = logical(0))
  res <- sv_stack(a, b)
  expect_equal(nrow(res), 2L)
  expect_equal(res$V, c("x", "y"))
  chk <- sv_stack_check(a, b)
  expect_equal(chk$columns[[1]]$status, "type differs -> as.character")
  expect_equal(sum(chk$columns[[1]]$na, na.rm = TRUE), 0)
  c1 <- data.frame(V = NA); c2 <- data.frame(V = "z", stringsAsFactors = FALSE)
  expect_equal(sv_stack(c1, c2)$V, c(NA, "z"))
  expect_equal(sum(sv_stack_check(c1, c2)$columns[[1]]$na, na.rm = TRUE), 0)
  got <- eval(parse(text = sv_stack_check(a, b)$code), envir = list2env(list(a = a, b = b), parent = baseenv()))
  expect_equal(got, sv_stack(a, b))
})

test_that("labels survive in the result", {
  w <- stack_waves()
  wave1 <- w$wave1; wave2 <- w$wave2
  res <- sv_stack(wave1, wave2)
  expect_equal(attr(res$RACE, "label"), "Race")
  expect_null(attr(res$AGE, "label"))
})

test_that("in-memory code parses, runs with dplyr only and rebuilds", {
  wave1 <- stack_waves()$wave1
  wave2 <- stack_waves()$wave2
  chk <- sv_stack_check(wave1, wave2, cast = c(AGE = "chr"))
  code <- chk$code
  expect_parses(code)
  expect_false(grepl("sv_|%>%|\\|>", code))
  got <- eval(parse(text = code), envir = list2env(list(wave1 = wave1, wave2 = wave2), parent = baseenv()))
  expect_equal(got, sv_stack(wave1, wave2, check = chk))
  expect_equal(attr(got$RACE, "label"), "Race")
  expect_error(sv_stack(wave1, wave2, check = sv_stack_check(wave1, stack_waves()$wave3)), "was made for other tables")
})

test_that("code rebuilds across types, renames, zones and awkward names", {
  d <- as.Date(c("2024-01-02", NA))
  p <- as.POSIXct(c("2024-01-02 00:00:00", "2024-03-04 10:30:00"), tz = "Asia/Singapore")
  `wave 2` <- data.frame(Age = c("1", "x"), `visit date` = d, L = c(TRUE, NA),
                         stringsAsFactors = FALSE, check.names = FALSE)
  attr(`wave 2`$Age, "label") <- "Age \"quoted\" \\ café"
  wave3 <- data.frame(AGE = c(1.5, NaN), `visit date` = p, L = c("TRUE", "no"), N = c(1e5, 2.5),
                      F = factor(c("u", "v")), stringsAsFactors = FALSE, check.names = FALSE)
  env <- list2env(list(`wave 2` = `wave 2`, wave3 = wave3), parent = baseenv())
  chk <- sv_stack_check(`wave 2`, wave3, rename = c(Age = "AGE"))
  expect_parses(chk$code)
  got <- eval(parse(text = chk$code), envir = env)
  expect_equal(got, sv_stack(`wave 2`, wave3, check = chk))
  expect_equal(attr(got$AGE, "label"), "Age \"quoted\" \\ café")
  expect_equal(got$source, c("wave.2", "wave.2", "wave3", "wave3"))
  chk2 <- sv_stack_check(`wave 2`, wave3, rename = c(Age = "AGE"), cast = c(`visit date` = "chr", L = "lgl"))
  got2 <- eval(parse(text = chk2$code), envir = env)
  expect_equal(got2, sv_stack(`wave 2`, wave3, check = chk2))
})

test_that("cast code agrees with sv_stack_cast on odd values", {
  run <- function(chk, ...) eval(parse(text = chk$code), envir = list2env(list(...), parent = baseenv()))
  x <- c("12", " 12 ", "\t12", "1e5", "0x1A", "Inf", "", "1e999", "2147483648", "-3", "1.5", NA)
  a <- data.frame(V = x, stringsAsFactors = FALSE)
  for (pair in list(c("num", 1.5), c("int", 1L), c("lgl", TRUE))) {
    b <- data.frame(V = switch(pair[[1]], num = 1.5, int = 1L, lgl = TRUE))
    chk <- sv_stack_check(a, b, cast = c(V = pair[[1]]))
    expect_equal(run(chk, a = a, b = b), sv_stack(a, b, check = chk), info = pair[[1]])
    expect_gt(sum(chk$columns[[1]]$na, na.rm = TRUE), 0)
  }
  num <- data.frame(V = c(0, 1, 2, NaN, 2.5, 3e9, NA))
  for (to in c("int", "lgl", "chr")) {
    one <- data.frame(V = switch(to, int = 1L, lgl = TRUE, chr = "a", stringsAsFactors = FALSE))
    chk <- sv_stack_check(num, one, cast = c(V = to))
    expect_equal(run(chk, num = num, one = one), sv_stack(num, one, check = chk), info = to)
  }
  tt <- data.frame(V = as.POSIXct("2024-01-01 00:00:00", tz = "UTC")); dd <- data.frame(V = as.Date("2024-02-01"))
  chk <- sv_stack_check(tt, dd, cast = c(V = "chr"))
  expect_equal(run(chk, tt = tt, dd = dd)$V, c("2024-01-01 00:00:00", "2024-02-01"))
  expect_equal(run(chk, tt = tt, dd = dd), sv_stack(tt, dd, check = chk))
  chk <- sv_stack_check(dd, tt)
  expect_equal(run(chk, tt = tt, dd = dd), sv_stack(dd, tt, check = chk))
})

test_that("check validates that cast and rename are named", {
  w <- stack_waves()
  wave1 <- w$wave1; wave2 <- w$wave2
  expect_error(sv_stack_check(wave1, wave2, cast = "chr"), "`cast` must be a named character vector")
  expect_error(sv_stack_check(wave1, wave2, rename = c("AGE")), "`rename` must be a named character vector")
  expect_error(sv_stack_check(wave1, wave2, cast = c(AGE = NA)), "`cast` must be a named character vector")
})

test_that("rename direction: the name is the near-miss, the value its partner", {
  a <- data.frame(AGE = 1); b <- data.frame(Age = 2)
  chk <- sv_stack_check(a, b, rename = c(Age = "AGE"))
  expect_equal(names(sv_stack(a, b, check = chk)), c("source", "AGE"))
  # lenient: either spelling may be the one renamed; the value is the name that is kept
  expect_equal(names(sv_stack(a, b, check = sv_stack_check(a, b, rename = c(AGE = "Age")))), c("source", "Age"))
  expect_error(sv_stack_check(a, b, rename = c(Age = "RACE")), "is not a near-miss")
})
