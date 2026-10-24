# Tests for join diagnostics: sv_join_diagnostics() in R and its browser twin
# SideviewPipeline.joinDiagnostics() (used by the htmlwidget).

dplyr_rows <- function(x, y, by) {
  out <- list()
  for (j in c("left_join", "inner_join", "full_join", "right_join")) {
    out[[j]] <- nrow(getExportedValue("dplyr", j)(x, y, by = by, relationship = "many-to-many"))
  }
  out$semi_join <- nrow(dplyr::semi_join(x, y, by = by))
  out$anti_join <- nrow(dplyr::anti_join(x, y, by = by))
  out
}

test_that("row counts for every join type equal dplyr", {
  set.seed(42)
  for (i in 1:6) {
    x <- data.frame(
      id = sample(c(1:8, NA), 25, replace = TRUE),
      site = sample(c("a", "b", NA), 25, replace = TRUE),
      v = 1:25
    )
    y <- data.frame(
      pid = sample(c(3:12, NA), 18, replace = TRUE),
      site = sample(c("a", "b", "c"), 18, replace = TRUE),
      w = 1:18
    )
    for (by in list(c(id = "pid"), c(id = "pid", "site"))) {
      d <- sv_join_diagnostics(x, y, by)
      expect_identical(lapply(d$rows, as.integer), lapply(dplyr_rows(x, y, by), as.integer))
      expect_equal(d$matched_x, nrow(dplyr::semi_join(x, y, by = by)))
      by_x <- ifelse(nzchar(names(by)), names(by), by)
      expect_equal(d$matched_y, nrow(dplyr::semi_join(y, x, by = stats::setNames(by_x, unname(by)))))
    }
  }
})

test_that("relationship follows the keys that match", {
  rel <- function(x, y) sv_join_diagnostics(data.frame(k = x), data.frame(k = y), "k")$relationship
  expect_identical(rel(1:3, 1:3), "one-to-one")
  expect_identical(rel(1:3, c(1, 1, 2)), "one-to-many")
  expect_identical(rel(c(1, 1, 2), 1:3), "many-to-one")
  expect_identical(rel(c(1, 1, 2), c(1, 1)), "many-to-many")
  expect_identical(rel(1:3, 4:6), "no matches")
  # Duplicates that never match do not make a join many-to-many.
  expect_identical(rel(c(1, 2, 9, 9), c(1, 2, 8, 8)), "one-to-one")
})

test_that("summary fields, samples and warnings describe the join", {
  patients <- data.frame(id = c(1, 2, 3, 4, NA), age = 1:5)
  visits <- data.frame(id = c(1, 1, 2, 2, 5, 6, NA), visit = 1:7)
  d <- sv_join_diagnostics(patients, visits, "id", x_name = "patients", y_name = "visits")
  expect_s3_class(d, "sv_join_diagnostics")
  expect_identical(d$by, data.frame(x = "id", y = "id", stringsAsFactors = FALSE))
  expect_equal(c(d$n_x, d$n_y), c(5, 7))
  expect_equal(d$matched_x, 3)            # 1, 2 and NA (NA matches NA, as in dplyr)
  expect_equal(d$matched_y, 5)
  expect_equal(d$match_rate_x, 0.6)
  expect_equal(c(d$na_x, d$na_y), c(1, 1))
  expect_equal(c(d$dup_keys_x, d$dup_keys_y), c(0, 2))
  expect_identical(d$relationship, "one-to-many")
  expect_identical(d$unmatched_x, c("3", "4"))
  expect_identical(d$unmatched_y, c("5", "6"))
  expect_identical(d$status, "warn")
  expect_match(d$warnings, "na_matches", all = FALSE)
  expect_length(d$type_issues, 0)

  out <- capture.output(print(d))
  expect_match(out[1], "<sv_join_diagnostics> by id")
  expect_match(out, "relationship: one-to-many", all = FALSE)
  expect_match(out, "left 7 \\| inner 5", all = FALSE)
  hint <- capture.output(print(sv_join_diagnostics(data.frame(k = "a"), data.frame(k = " a"), "k")))
  expect_match(hint, "hint: trimming whitespace would match 1 more x rows and 1 more y rows", all = FALSE, fixed = TRUE)
  hint <- capture.output(print(sv_join_diagnostics(data.frame(k = "a"), data.frame(k = c("a", " a")), "k")))
  expect_match(hint, "hint: trimming whitespace would match 1 more y rows$", all = FALSE)

  ok <- sv_join_diagnostics(data.frame(k = 1:3), data.frame(k = 1:3), "k")
  expect_identical(ok$status, "ok")
  expect_length(ok$warnings, 0)

  mm <- sv_join_diagnostics(data.frame(k = c(1, 1)), data.frame(k = c(1, 1, 1)), "k", x_name = "a")
  expect_match(mm$warnings[1], "Many-to-many: .* left join gives 6 rows from 2 a rows")

  low <- sv_join_diagnostics(data.frame(k = 1:10), data.frame(k = 1:2), "k")
  expect_match(low$warnings, "Only 20% of x rows", all = FALSE)

  big <- sv_join_diagnostics(data.frame(k = c(1e6, 2.5)), data.frame(k = c("1000000", "2.5")), "k")
  expect_equal(big$matched_x, 2)          # 1e6 is compared as "1000000", not "1e+06"
})

test_that("hints measure what trimming, case and leading zeros would recover", {
  x <- data.frame(code = c(" A1", "b2", "007", "x9"), stringsAsFactors = FALSE)
  y <- data.frame(code = c("A1", "B2", "7", "x9"), stringsAsFactors = FALSE)
  d <- sv_join_diagnostics(x, y, "code")
  fixes <- vapply(d$hints, `[[`, character(1), "fix")
  expect_identical(fixes, c("trim", "case", "zeros"))
  extra <- vapply(d$hints, `[[`, numeric(1), "extra_x")
  expect_equal(extra, c(1, 1, 1))          # each fix is measured on its own

  d2 <- sv_join_diagnostics(data.frame(k = " a"), data.frame(k = "a"), "k")
  expect_identical(vapply(d2$hints, `[[`, character(1), "fix"), "trim")
  expect_length(sv_join_diagnostics(data.frame(k = 1:2), data.frame(k = 1:2), "k")$hints, 0)
})

test_that("key type mismatches are errors and bad input is refused", {
  d <- sv_join_diagnostics(data.frame(id = c("1", "2")), data.frame(id = 1:2), "id",
                           x_name = "a", y_name = "b")
  expect_identical(d$status, "error")
  expect_match(d$type_issues, "id is character in a but numeric in b")
  expect_identical(sv_join_diagnostics(data.frame(id = factor("1")), data.frame(id = "1"), "id")$status, "ok")

  expect_error(sv_join_diagnostics(1:3, data.frame(), "a"), "data frames")
  expect_error(sv_join_diagnostics(data.frame(a = 1), data.frame(a = 1), character()), "at least one")
  expect_error(sv_join_diagnostics(data.frame(a = 1), data.frame(b = 1), "a", y_name = "visits"), "Not in visits: a")
})

test_that("the JS twin gives the same diagnostics as R", {
  set.seed(7)
  x <- data.frame(
    id = sample(c(1:6, NA), 30, replace = TRUE),
    site = sample(c("a", " a", "B", NA), 30, replace = TRUE),
    stringsAsFactors = FALSE
  )
  y <- data.frame(
    pid = sample(c(2:9, NA), 20, replace = TRUE),
    site = sample(c("a", "b", "c"), 20, replace = TRUE),
    stringsAsFactors = FALSE
  )
  cases <- list(c(id = "pid"), c(id = "pid", "site"), c(site = "site"))
  for (by in cases) {
    by_x <- ifelse(nzchar(names(by)), names(by), by)
    r <- sv_join_diagnostics(x, y, by, sample_n = 50, x_name = "x", y_name = "y")
    js <- run_pipeline_js(sprintf(
      "const x = %s; const y = %s; out = P.joinDiagnostics(x, y, %s, {sampleN: 50, xName: 'x', yName: 'y',
         xTypes: {id: 'integer', site: 'character'}, yTypes: {pid: 'integer', site: 'character'}});",
      jsonlite::toJSON(as.list(x), na = "null"), jsonlite::toJSON(as.list(y), na = "null"),
      jsonlite::toJSON(lapply(seq_along(by), function(i) list(left = by_x[i], right = unname(by[i]))), auto_unbox = TRUE)
    ))
    num <- c("n_x", "n_y", "distinct_x", "distinct_y", "distinct_matched", "matched_x", "matched_y",
             "na_x", "na_y", "dup_keys_x", "dup_keys_y", "match_rate_x", "match_rate_y")
    for (f in num) expect_equal(js[[f]], r[[f]], info = paste(f, paste(by, collapse = ",")))
    expect_identical(js$relationship, r$relationship)
    expect_equal(unlist(js$rows), unlist(r$rows))
    expect_setequal(unlist(js$unmatched_x), r$unmatched_x)
    expect_setequal(unlist(js$unmatched_y), r$unmatched_y)
    expect_identical(unlist(js$warnings) %||% character(0), r$warnings)
    expect_identical(js$status, r$status)
    expect_equal(vapply(js$hints, `[[`, character(1), "fix"), vapply(r$hints, `[[`, character(1), "fix"))
  }
  js <- run_pipeline_js("out = P.describeDiagnostics({relationship: 'one-to-many', match_rate_x: 0.975,
    rows: {left_join: 1240}}, 'left_join', 'patients');")
  expect_identical(js, "1:m · 98% of patients matched · 1,240 rows")
})

test_that("the server answers join_diagnostics_request on the full data", {
  patients <- data.frame(patient_id = 1:600, age = 30)
  visits <- data.frame(patient_id = c(rep(1:300, 2), 9999), v = 1)
  cards <- list(sv_normalize(patients, name = "patients"), sv_normalize(visits, name = "visits"))
  shiny::testServer(sideview_server(cards), {
    session$setInputs(join_diagnostics_request = list(
      id = "sig1", left = "patients", right = "visits",
      by = list(list(left = "patient_id", right = "patient_id"))
    ))
    msgs <- session$userData$custom_messages
    m <- msgs[[length(msgs)]]
    expect_identical(m$type, "sideview_join_diagnostics")
    expect_identical(m$message$id, "sig1")
    expect_equal(m$message$n_x, 600)
    expect_equal(m$message$matched_x, 300)
    expect_equal(m$message$rows$left_join, 900)
    expect_identical(m$message$relationship, "one-to-many")
    expect_identical(m$message$by, list(list(left = "patient_id", right = "patient_id")))
    expect_type(m$message$warnings, "list")

    session$setInputs(join_diagnostics_request = list(
      id = "sig2", left = "patients", right = "nope",
      by = list(list(left = "patient_id", right = "patient_id"))
    ))
    msgs <- session$userData$custom_messages
    m <- msgs[[length(msgs)]]
    expect_identical(m$message$id, "sig2")
    expect_match(m$message$error, "both tables")
  })
})
