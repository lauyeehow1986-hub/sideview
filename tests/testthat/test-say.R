test_that("say helpers: R and JS agree byte for byte", {
  cases <- list(c(140, 150), c(1, 3), c(2, 3), c(1, 8), c(0, 7), c(7, 7), c(1, 2000))
  r <- vapply(cases, function(k) sv_say_pct(k[1], k[2]), "")
  js <- unlist(run_pipeline_js(sprintf("out = %s.map(function (k) { return P.sayPct(k[0], k[1]); });",
                                       jsonlite::toJSON(cases))))
  expect_identical(r, js)
  expect_identical(r[1:2], c("93.3 percent", "33.3 percent"))
  expect_identical(sv_say_pct(1, 2000), "0.1 percent")   # 0.05 rounds up
  expect_identical(sv_say_pct(3, 0), NA_character_)
  expect_null(run_pipeline_js("out = P.sayPct(3, 0);"))
  expect_identical(sv_say_list(c("A", "B", "C")), "A, B, and C")
  expect_identical(sv_say_list(c("A", "B")), "A and B")
  expect_identical(sv_say_list("A"), "A")
  expect_identical(sv_say_list(character()), "")
  expect_identical(sv_say_samples(c("P05", "P09", "P12", "P20"), total = 10), "P05, P09, P12, and 7 more")
  expect_identical(sv_say_samples(c("P05", "P09")), "P05 and P09")
  expect_identical(sv_say_value(NA), "missing")
  expect_identical(sv_say_value("P05, 2"), "(P05, 2)")
  expect_identical(sv_say_num(1234567), "1,234,567")
  expect_identical(sv_say_num(0.1234567891), "0.123457")

  lists <- list(character(), "A", c("A", "B"), c("A", "B", "C"), c("A", "B", "C", "D"))
  expect_identical(
    vapply(lists, sv_say_list, ""),
    unlist(run_pipeline_js(sprintf("out = %s.map(function (x) { return P.sayList(x); });",
                                   jsonlite::toJSON(lists)))))
  samp <- list(list(c("P05", "P09", "P12", "P20"), 10), list(c("P05", "P09"), NULL),
               list(c("a, b", "c", "d", "e"), 4), list(c("x", "y", "z"), 3))
  rs <- vapply(samp, function(k) sv_say_samples(k[[1]], k[[2]]), "")
  js_s <- unlist(run_pipeline_js(sprintf(
    "out = %s.map(function (k) { return P.saySamples(k[0], k[1]); });",
    jsonlite::toJSON(samp, null = "null"))))
  expect_identical(rs, js_s)
  expect_identical(sv_say_samples(c("a, b", "c", "d", "e"), 4), "(a, b), c, d, and 1 more")
  nums <- c(1234567, 0.1234567891, 42, -3.14159265, 1e6, 2.5)
  expect_identical(
    vapply(nums, sv_say_num, ""),
    unlist(run_pipeline_js(sprintf("out = %s.map(function (v) { return P.sayNum(v); });",
                                   jsonlite::toJSON(nums, digits = NA)))))
  expect_identical(unlist(run_pipeline_js("out = [P.sayValue(null), P.sayValue('P05, 2'), P.sayValue(7)];")),
                   c("missing", "(P05, 2)", "7"))
  long <- strrep("x", 120)
  expect_identical(sv_say_check_lines(c("a", long)), c("a", long))
  expect_identical(unlist(run_pipeline_js(sprintf("out = P.sayCheckLines(['a', '%s']);", long))), c("a", long))
})

test_that("say helpers: cell values and edge numbers agree in R and JS", {
  vals <- list(1e6, 1e5, 0.1 + 0.2, 123456.789, -5, -1234567, TRUE, FALSE, NA, NaN, NULL, "", "P05, 2", "x", 0.00001234)
  r <- vapply(vals, sv_say_value, "")
  js <- unlist(run_pipeline_js(sprintf("out = %s.map(function (v) { return P.sayValue(v); });",
                                       jsonlite::toJSON(vals, null = "null", na = "null", digits = NA, auto_unbox = TRUE))))
  expect_identical(r, js)
  expect_identical(r[1:10], c("1000000", "100000", "0.3", "123456.789", "-5", "-1234567",
                              "TRUE", "FALSE", "missing", "missing"))
  expect_identical(r[11], "missing")
  expect_identical(sv_say_value(Inf), "Inf")
  expect_identical(unlist(run_pipeline_js("out = [P.sayValue(Infinity), P.sayValue(-Infinity), P.sayValue(undefined)];")),
                   c("Inf", "-Inf", "missing"))

  nums <- c(1e6, 1e5, 0.1 + 0.2, 123456.789, -5, -1234567, -0.5)
  expect_identical(
    vapply(nums, sv_say_num, ""),
    unlist(run_pipeline_js(sprintf("out = %s.map(function (v) { return P.sayNum(v); });",
                                   jsonlite::toJSON(nums, digits = NA)))))
  expect_identical(sv_say_num(-1234567), "-1,234,567")
  expect_identical(
    c(sv_say_num(NA), sv_say_num(NaN), sv_say_num(Inf), sv_say_num(-Inf), sv_say_num(""), sv_say_num(TRUE)),
    unlist(run_pipeline_js(paste0("out = [P.sayNum(null), P.sayNum(NaN), P.sayNum(Infinity), ",
                                  "P.sayNum(-Infinity), P.sayNum(''), P.sayNum(true)];"))))
})

# ---- sv_say_join / sayJoin ---------------------------------------------------------

say_join_fixtures <- function() {
  ids <- sprintf("P%02d", 1:150)
  gone <- c(5, 9, 12, 20, 33, 47, 60, 71, 88, 99)
  kept <- ids[-gone]
  d0 <- as.Date("2024-01-10")
  list(
    one_to_one = list(x = data.frame(id = 1:5, a = 1), y = data.frame(id = 1:5, b = 2), by = "id"),
    one_to_many = list(x = data.frame(patient_id = ids, age = 40),
                       y = data.frame(patient_id = rep(kept, 2), visit = 1), by = "patient_id"),
    multi_key_hint = list(
      x = data.frame(pid = c(1, 2, 3, 4), site = c("a", "b", "c", "d"), stringsAsFactors = FALSE),
      y = data.frame(id = c(1, 2, 3, 9), site = c("a", " b", "C", "d"), stringsAsFactors = FALSE),
      by = c(pid = "id", "site")),
    date_rule = list(
      x = data.frame(id = c(1, 2, 3), visit_date = d0 + c(0, 10, 20)),
      y = data.frame(id = c(1, 1, 2, 3), lab_date = d0 + c(-2, 40, 11, 90)), by = "id",
      rule = list(shape = "window", xCol = "visit_date", yCol = "lab_date", from = -7, to = 7))
  )
}

say_join_js <- function(fx, names = c("patients", "visits")) {
  col <- function(v) I(if (inherits(v, c("Date", "POSIXt"))) format(v) else v)
  payload <- lapply(unname(fx), function(cs) {
    by_x <- if (is.null(names(cs$by))) cs$by else ifelse(nzchar(names(cs$by)), names(cs$by), cs$by)
    list(x = lapply(cs$x, col), y = lapply(cs$y, col),
         by = lapply(seq_along(cs$by), function(i) list(left = by_x[i], right = unname(cs$by[i]))),
         rule = cs$rule,
         xTypes = lapply(cs$x, function(v) class(v)[1]), yTypes = lapply(cs$y, function(v) class(v)[1]))
  })
  json <- jsonlite::toJSON(payload, auto_unbox = TRUE, na = "null", null = "null", digits = NA)
  run_pipeline_js(sprintf(
    "const cases = %s; out = cases.map(c => P.sayJoin(P.joinDiagnostics(c.x, c.y, c.by,
       {rule: c.rule, xName: %s, yName: %s, xTypes: c.xTypes, yTypes: c.yTypes}), %s, %s));",
    json, jsonlite::toJSON(names[1], auto_unbox = TRUE), jsonlite::toJSON(names[2], auto_unbox = TRUE),
    jsonlite::toJSON(names[1], auto_unbox = TRUE), jsonlite::toJSON(names[2], auto_unbox = TRUE)))
}

test_that("sayJoin twin: R and JS give the same sentences", {
  fx <- say_join_fixtures()
  r <- lapply(fx, function(cs) {
    sv_say_join(sv_join_diagnostics(cs$x, cs$y, cs$by, rule = cs$rule, x_name = "patients", y_name = "visits"),
                "patients", "visits")
  })
  js <- lapply(say_join_js(fx), function(l) unlist(l))
  names(js) <- names(r)
  expect_identical(r, js)

  lines <- r$one_to_many
  expect_identical(lines[1], "Join of patients and visits by patient_id is one to many.")
  expect_true("10 patients rows have no match, for example P05, P09, P12, and 7 more." %in% lines)
  expect_true("140 of 150 patients rows match, 93.3 percent." %in% lines)
  expect_identical(r$one_to_one[1], "Join of patients and visits by id is one to one.")
  expect_true(any(grepl("^Date rule: lab_date within -7[.][.][+]7 days of visit_date[.]$", r$date_rule)))
  expect_true(any(grepl("^The rule drops [0-9]+ patients rows and [0-9]+ visits rows[.]$", r$date_rule)))
  expect_identical(r$multi_key_hint[1], "Join of patients and visits by pid = id and site is one to one.")
  expect_true(any(grepl("^Trimming whitespace would match 1 more patients rows", r$multi_key_hint)))
  expect_true(any(grepl("^Rows by join type: left [0-9]+, inner [0-9]+, right [0-9]+, full [0-9]+, semi [0-9]+, anti [0-9]+[.]$",
                        r$one_to_many)))

  lines_without_data <- unlist(r)
  expect_true(all(!grepl("[^\x20-\x7e]", lines_without_data)))
  expect_true(all(nchar(lines_without_data) <= 100))

  # an error is one sentence in both
  e <- sv_say_join(list(error = "Not in x: nope"), "x", "y")
  expect_identical(e, "Join check failed: Not in x: nope.")
  expect_identical(unlist(run_pipeline_js("out = P.sayJoin({error: 'Not in x: nope'}, 'x', 'y');")), e)
  expect_identical(sv_say_join(list(error = "Bad window."), "x", "y"), "Join check failed: Bad window.")
  expect_identical(unlist(run_pipeline_js("out = P.sayJoin({error: 'Bad window.'}, 'x', 'y');")),
                   "Join check failed: Bad window.")
  # the name fields are kept on the result, and the print method uses them
  d <- sv_join_diagnostics(fx$one_to_one$x, fx$one_to_one$y, "id", x_name = "patients", y_name = "visits")
  expect_identical(c(d$x_name, d$y_name), c("patients", "visits"))
})

test_that("sayJoin twin: edge cases agree", {
  cases <- list(
    empty = list(x = data.frame(id = integer()), y = data.frame(id = 1:3), by = "id"),
    both_empty = list(x = data.frame(id = integer()), y = data.frame(id = integer()), by = "id"),
    na_keys = list(x = data.frame(id = c(1, NA, NA)), y = data.frame(id = c(1, NA)), by = "id"),
    many = list(x = data.frame(id = c(1, 1)), y = data.frame(id = c(1, 1, 1)), by = "id"),
    dup_unmatched = list(x = data.frame(id = c("a, b", "a, b", "c", "d", "e")), y = data.frame(id = "z"), by = "id"),
    unicode = list(x = data.frame(id = c("\u00e9a", "b")), y = data.frame(id = "b"), by = "id")
  )
  r <- lapply(cases, function(cs) sv_say_join(sv_join_diagnostics(cs$x, cs$y, cs$by, x_name = "x", y_name = "y"), "x", "y"))
  js <- say_join_js(cases, c("x", "y"))
  js <- lapply(js, function(l) unlist(l))
  names(js) <- names(r)
  expect_identical(r, js)
  expect_identical(r$empty[2], "0 of 0 x rows match.")
  expect_true("1 x rows have no match, for example keys (a, b)." %in% r$dup_unmatched ||
              any(grepl("have no match, for example keys ", r$dup_unmatched)))
  expect_true("2 x rows have a missing key." %in% r$na_keys)
})
