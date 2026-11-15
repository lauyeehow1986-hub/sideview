if (!"package:sideview" %in% search()) {
  r_files <- list.files(c("R", "../R", "../../R"), pattern = "\\.[Rr]$", full.names = TRUE)
  for (f in r_files) source(f)
}

describe_fixture <- function() {
  df <- data.frame(id = 1:4, sex = c("M", "F", "F", NA), age = c(40, 51, 62, 38),
                   stringsAsFactors = FALSE)
  attr(df$age, "label") <- "Age (years)"
  df
}

test_that("sv_describe gives a table line and a line per column", {
  patients <- describe_fixture()
  expect_invisible(sv_describe(patients))
  d <- sv_describe(patients)
  expect_s3_class(d, "sv_description")
  expect_identical(unclass(d), c(
    "patients, 4 rows by 3 columns, 1 column has missing values.",
    "  id, number: 0 missing, 4 distinct, min 1, median 2.5, max 4.",
    "  sex, text: 1 missing, 2 distinct, top F (2), M (1).",
    "  age, Age (years), number: 0 missing, 4 distinct, min 38, median 45.5, max 62."))
  expect_identical(capture.output(print(d)), unclass(d))
})

test_that("grammar and domain", {
  one <- data.frame(a = 1)
  expect_identical(unclass(sv_describe(one))[1], "one, 1 row by 1 column, no columns have missing values.")
  ae <- data.frame(STUDYID = c("S", "S"), USUBJID = c("a", "b"), AESEQ = 1:2, AETERM = c("x", NA), AESEV = c("m", NA))
  expect_match(unclass(sv_describe(ae))[1], "^ae, AE domain, 2 rows by 5 columns, 2 columns have missing values\\.$")
})

test_that("n_levels limits the top values", {
  df <- data.frame(g = c("a", "a", "a", "b", "b", "c", "d"))
  top <- function(n) unclass(sv_describe(df, n_levels = n))[2]
  expect_identical(top(2), "  g, text: 0 missing, 4 distinct, top a (3), b (2).")
  expect_identical(top(5), "  g, text: 0 missing, 4 distinct, top a (3), b (2), c (1), d (1).")
})

test_that("names: explicit, expression, odd columns", {
  df <- data.frame(a = 1:2)
  expect_match(unclass(sv_describe(my = df))[1], "^my, ")
  expect_match(unclass(sv_describe(list(a = df, b = df)))[3], "^b, ")
  l <- list(t = df)
  expect_match(unclass(sv_describe(l$t))[1], "^t, ")
  odd <- data.frame(x = c("<b>", "it's \"q\"", "café", NA))
  names(odd) <- "a <b> é"
  d <- unclass(sv_describe(odd))
  expect_match(d[2], "^  a <b> é, text: 1 missing, 3 distinct")
})

test_that("ASCII fixtures give ASCII lines of at most 100 characters", {
  d <- unclass(sv_describe(describe_fixture()))
  expect_false(any(grepl("[^ -~]", d)))
  expect_true(all(nchar(d) <= 100))
})

test_that("lazy tables give the same lines and are profiled lazily", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  df <- data.frame(id = 1:120, grp = rep(c("a", "b", NA), 40), v = rep(c(1.5, 2, 3), 40),
                   stringsAsFactors = FALSE)
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "d", df)
  want <- unclass(sv_describe(tbl = df))
  calls <- 0L
  real <- sv_lazy_column_profile
  testthat::local_mocked_bindings(
    sv_lazy_column_profile = function(...) {
      calls <<- calls + 1L
      real(...)
    },
    sv_column_profile = function(x, ...) stop("in-memory profile used on a lazy table")
  )
  duck <- unclass(sv_describe(tbl = dplyr::tbl(con, "d")))
  expect_identical(calls, 3L)
  arr <- unclass(sv_describe(tbl = arrow::arrow_table(df)))
  expect_identical(duck, want)
  expect_identical(arr, want)
})
