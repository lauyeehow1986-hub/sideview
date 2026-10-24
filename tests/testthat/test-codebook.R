# Tests for the column inspector (sv_column_profile) and data dictionary
# (sv_codebook), and their browser twins in sv-pipeline.js (used by the widget).

test_that("numeric profile gives counts, quartiles, histogram and outliers", {
  x <- c(54, 61, 47, 50, 52, 55, 58, 999, NA)
  p <- sv_column_profile(x)
  expect_identical(p$kind, "numeric")
  expect_equal(c(p$n, p$n_missing, p$n_distinct), c(9, 1, 8))
  expect_equal(p$pct_missing, 1 / 9)
  expect_false(p$unique_key)                 # has an NA
  q <- stats::quantile(x, c(0, .25, .5, .75, 1), na.rm = TRUE, names = FALSE)
  expect_equal(unlist(p$stats[c("min", "q1", "median", "q3", "max")]), q, ignore_attr = TRUE)
  expect_equal(p$stats$mean, mean(x, na.rm = TRUE))
  expect_equal(p$stats$sd, stats::sd(x, na.rm = TRUE))
  expect_length(p$histogram$counts, 20)
  expect_equal(sum(p$histogram$counts), 8)
  expect_equal(range(p$histogram$breaks), c(47, 999))
  expect_identical(p$issues, "1 value lies beyond 3 IQR of the quartiles (e.g. 999).")
  expect_equal(nrow(p$top), 8)                 # few distinct numbers are listed

  expect_true(sv_column_profile(1:5)$unique_key)
  expect_equal(nrow(sv_column_profile(1:5)$top), 0)   # a key has nothing worth listing
  expect_equal(nrow(sv_column_profile(rnorm(50))$top), 0)
  one <- sv_column_profile(c(3, 3, 3))
  expect_identical(one$histogram, list(breaks = c(3, 3), counts = 3L))
  expect_identical(one$issues, "Only one distinct value.")
  expect_identical(sv_column_profile(c(NA_real_, NA))$issues, "All values are missing.")
})

test_that("text profile lists common values and flags messy text", {
  sex <- c("Male", "male", " Male", "Female", "Female", "", NA)
  p <- sv_column_profile(sex)
  expect_identical(p$kind, "character")
  expect_identical(p$top$value[1], "Female")
  expect_identical(p$top$n[1], 2L)
  expect_identical(p$n_other, 0L)
  expect_identical(p$issues, c(
    "1 value has leading or trailing spaces.",
    "1 empty string, not NA.",
    "1 value differs only in case or spacing (e.g. \" Male\" / \"Male\" / \"male\")."
  ))
  expect_identical(sv_column_profile(c("1", "2.5", " 3"))$issues[2], "All values are numbers stored as text.")
  expect_identical(sv_column_profile(factor(c("a", "b", "a")))$kind, "character")
  lg <- sv_column_profile(c(TRUE, FALSE, TRUE, NA))
  expect_identical(lg$top$value, c("TRUE", "FALSE"))

  many <- sv_column_profile(rep(letters, 1:26), top_n = 3)
  expect_identical(many$top$value, c("z", "y", "x"))
  expect_identical(many$n_other, 23L)

  lab <- structure(c(1, 2), label = "Age at baseline (years)")
  expect_identical(sv_column_profile(lab)$label, "Age at baseline (years)")
})

test_that("date profile uses ordered values", {
  d <- as.Date("2024-01-01") + c(0, 10, 20, 30, NA)
  p <- sv_column_profile(d)
  expect_identical(p$kind, "date")
  expect_identical(p$stats$min, "2024-01-01")
  expect_identical(p$stats$median, "2024-01-11")
  expect_identical(p$stats$max, "2024-01-31")
  expect_null(p$histogram)
})

test_that("sv_codebook has one row per column and writes CSV", {
  patients <- data.frame(
    id = 1:4, sex = c("M", "F", "f", NA), age = c(40, 51, 62, 999),
    enrolled = as.Date("2020-01-01") + 0:3, stringsAsFactors = FALSE
  )
  attr(patients$age, "label") <- "Age (years)"
  visits <- data.frame(pid = c(1, 1, 2), visit = c("v1", "v2", "v1"))
  cb <- sv_codebook(patients, visits)
  expect_s3_class(cb, "data.frame")
  expect_identical(names(cb), c("table", "column", "position", "class", "label", "n", "n_missing",
                                "pct_missing", "n_distinct", "unique_key", "min", "q1", "median", "q3",
                                "max", "mean", "sd", "top_values", "issues"))
  expect_identical(cb$table, c(rep("patients", 4), rep("visits", 2)))
  expect_identical(cb$column, c("id", "sex", "age", "enrolled", "pid", "visit"))
  expect_identical(cb$label[3], "Age (years)")
  expect_identical(cb$unique_key, c(TRUE, FALSE, TRUE, TRUE, FALSE, FALSE))
  expect_equal(cb$pct_missing[2], 25)
  expect_identical(cb$top_values[2], "F (1); M (1); f (1)")
  expect_identical(cb$top_values[5], "1 (2); 2 (1)")
  expect_identical(cb$median[4], "2020-01-02")
  expect_identical(cb$max[3], "999")
  expect_match(cb$issues[2], "differs only in case")

  expect_identical(sv_codebook(list(a = patients))$table[1], "a")
  expect_identical(sv_codebook(top_n = 1, head(patients))$top_values[2], "F (1); +2 more")

  f <- tempfile(fileext = ".csv")
  on.exit(unlink(f), add = TRUE)
  expect_invisible(sv_codebook(patients, file = f))
  back <- utils::read.csv(f, stringsAsFactors = FALSE)
  expect_identical(back$column, cb$column[1:4])
  expect_identical(back$top_values[2], cb$top_values[2])

  expect_error(sv_codebook(), "at least one")
  expect_error(sv_codebook(1:3), "not a data frame")
  expect_error(sv_codebook(patients, file = tempfile(fileext = ".txt")), ".csv or .xlsx")
})

test_that("sv_codebook writes xlsx when writexl is installed", {
  skip_if_not_installed("writexl")
  f <- tempfile(fileext = ".xlsx")
  on.exit(unlink(f), add = TRUE)
  sv_codebook(mtcars, file = f)
  expect_gt(file.size(f), 0)
})

test_that("the JS twin profiles columns like R", {
  set.seed(11)
  cols <- list(
    num = list(x = c(round(rnorm(40, 50, 8), 1), 400, NA, NA), type = "numeric"),
    int = list(x = sample(c(1:4, NA), 30, replace = TRUE), type = "integer"),
    chr = list(x = sample(c("Male", "male", " Male", "Female", "", NA), 50, replace = TRUE), type = "character"),
    txtnum = list(x = c("1", "2.50", " 3", NA), type = "character"),
    lgl = list(x = c(TRUE, FALSE, TRUE, NA), type = "logical"),
    const = list(x = rep(7, 5), type = "numeric"),
    key = list(x = sprintf("P%03d", 1:20), type = "character"),
    allna = list(x = rep(NA_real_, 3), type = "numeric"),
    small = list(x = c(0.1, 1 / 3, 2e6, 0.1), type = "numeric")
  )
  for (nm in names(cols)) {
    x <- cols[[nm]]$x
    r <- sv_column_profile(x)
    js <- run_pipeline_js(sprintf("out = P.columnProfile(%s, %s);",
      jsonlite::toJSON(x, na = "null", digits = NA), jsonlite::toJSON(cols[[nm]]$type, auto_unbox = TRUE)))
    for (f in c("kind", "n", "n_missing", "pct_missing", "n_distinct", "unique_key", "n_other")) {
      expect_equal(js[[f]], r[[f]], info = paste(nm, f))
    }
    expect_identical(unlist(js$issues) %||% character(0), r$issues, info = nm)
    expect_identical(vapply(js$top, `[[`, character(1), "value"), r$top$value, info = nm)
    expect_equal(vapply(js$top, function(t) as.integer(t$n), integer(1)), r$top$n, info = nm)
    if (!is.null(r$stats)) {
      for (s in names(r$stats)) expect_equal(js$stats[[s]] %||% NA_real_, r$stats[[s]], info = paste(nm, s))
      expect_equal(unlist(js$histogram$counts), r$histogram$counts, info = nm)
      expect_equal(unlist(js$histogram$breaks), r$histogram$breaks, info = nm)
    } else {
      expect_null(js$stats)
    }
  }
  d <- as.Date("2024-01-01") + c(0, 10, 20, 30, NA)
  js <- run_pipeline_js(sprintf("out = P.columnProfile(%s, 'Date');", jsonlite::toJSON(d, na = "null")))
  expect_identical(js$stats, sv_column_profile(d)$stats)
})

test_that("the JS codebook CSV equals write.csv of sv_codebook()", {
  patients <- data.frame(
    id = 1:6, sex = c("M", "F", "f", NA, "M", "M"), age = c(40.5, 51, 62, 999, 47, NA),
    note = c("a \"quoted\" note", "x", "y", "z", "w", "v"), stringsAsFactors = FALSE
  )
  r <- sv_codebook(patients)
  f <- tempfile(fileext = ".csv")
  on.exit(unlink(f), add = TRUE)
  utils::write.csv(r, f, row.names = FALSE, na = "")
  expected <- paste0(paste(readLines(f), collapse = "\n"), "\n")
  types <- vapply(patients, function(c) class(c)[1], character(1))
  rows <- vapply(seq_along(patients), function(j) {
    sprintf("P.codebookRow('patients', %s, %d, %s, %s)",
            jsonlite::toJSON(names(patients)[j], auto_unbox = TRUE), j,
            jsonlite::toJSON(patients[[j]], na = "null", digits = NA),
            jsonlite::toJSON(types[[j]], auto_unbox = TRUE))
  }, character(1))
  js <- run_pipeline_js(sprintf("out = P.codebookCsv([%s]);", paste(rows, collapse = ", ")))
  expect_identical(js, expected)
})

test_that("the server profiles columns on the full data and exports the codebook", {
  patients <- data.frame(patient_id = 1:800, age = c(rep(40:79, 20)), sex = rep(c("M", "F", " m", NA), 200))
  visits <- data.frame(pid = c(1, 1, 2), visit = c("v1", "v2", "v1"))
  cards <- list(sv_normalize(patients, name = "patients"), sv_normalize(visits, name = "visits"))
  dir <- withr::local_tempdir()
  path <- file.path(dir, "cb.csv")
  testthat::local_mocked_bindings(sv_choose_codebook_path = function() path)
  shiny::testServer(sideview_server(cards), {
    last_msg <- function() {
      msgs <- session$userData$custom_messages
      msgs[[length(msgs)]]
    }
    session$setInputs(column_profile_request = list(id = "p1", table = "patients", column = "sex"))
    m <- last_msg()
    expect_identical(m$type, "sideview_column_profile")
    expect_identical(m$message$id, "p1")
    expect_identical(m$message$column, "sex")
    expect_equal(m$message$n, 800)                 # all rows, not the 500-row preview
    expect_equal(m$message$n_missing, 200)
    expect_type(m$message$top, "list")
    expect_identical(m$message$top[[1]]$value, " m")
    expect_type(m$message$issues, "list")

    session$setInputs(column_profile_request = list(id = "p2", table = "patients", column = "age"))
    m <- last_msg()
    expect_equal(m$message$stats$median, 59.5)
    expect_length(m$message$histogram$counts, 20)

    session$setInputs(column_profile_request = list(id = "p3", table = "patients", column = "nope"))
    expect_match(last_msg()$message$error, "No column nope")

    session$setInputs(codebook_export = 1)
    m <- last_msg()
    expect_identical(m$type, "sideview_codebook_saved")
    expect_equal(m$message$n_tables, 2)
    cb <- utils::read.csv(path, stringsAsFactors = FALSE)
    expect_identical(unique(cb$table), c("patients", "visits"))
    expect_equal(cb$n[1], 800)
  })
  testthat::local_mocked_bindings(sv_choose_codebook_path = function() NULL)
  shiny::testServer(sideview_server(cards), {
    session$setInputs(codebook_export = 1)
    msgs <- session$userData$custom_messages
    expect_true(isTRUE(msgs[[length(msgs)]]$message$cancelled))
  })
})
