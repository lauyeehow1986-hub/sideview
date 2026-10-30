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

# ---- date rules (sideview 0.4.0) -----------------------------------------------

# Synthetic tables with ties, NA dates and NA keys; the date columns are Date, date-time or numeric.
rule_tables <- function(kind, seed) {
  set.seed(seed)
  conv <- function(v) switch(kind,
    Date = as.Date("2024-01-01") + v,
    `date-time` = as.POSIXct("2024-01-01", tz = "UTC") + v * 86400,
    numeric = as.numeric(v))
  nx <- 14L
  ny <- 20L
  vx <- sample(c(0:40, NA), nx, replace = TRUE)
  vy <- sample(c(0:40, NA), ny, replace = TRUE)
  x <- data.frame(id = sample(c(1:5, NA), nx, replace = TRUE), .i = seq_len(nx))
  x$xd <- conv(vx)
  x$xe <- conv(vx + sample(0:6, nx, replace = TRUE))
  y <- data.frame(id = sample(c(1:6, NA), ny, replace = TRUE))
  y$yd <- conv(vy)
  y$ys <- conv(vy)
  y$ye <- conv(vy + sample(0:6, ny, replace = TRUE))
  list(x = x, y = y, unit = if (kind == "date-time") 86400 else 1)
}

# The dplyr reference of a rule: the table x (with window helpers) and the join_by().
rule_reference <- function(shape, t, from = -7, to = 7, inclusive = TRUE) {
  x <- t$x
  by <- switch(shape,
    between = dplyr::join_by(id, between(xd, ys, ye)),
    overlaps = dplyr::join_by(id, overlaps(xd, xe, ys, ye)),
    window = {
      x$.lo <- x$xd + from * t$unit
      x$.hi <- x$xd + to * t$unit
      dplyr::join_by(id, between(y$yd, x$.lo, x$.hi))
    },
    before = if (inclusive) dplyr::join_by(id, closest(xd >= yd)) else dplyr::join_by(id, closest(xd > yd)),
    after = if (inclusive) dplyr::join_by(id, closest(xd <= yd)) else dplyr::join_by(id, closest(xd < yd)))
  list(x = x, by = by)
}

test_that("a rule check counts like dplyr", {
  rules <- list(
    list(shape = "between", xCol = "xd", yFrom = "ys", yTo = "ye"),
    list(shape = "overlaps", xFrom = "xd", xTo = "xe", yFrom = "ys", yTo = "ye"),
    list(shape = "window", xCol = "xd", yCol = "yd", from = -7, to = 7),
    list(shape = "window", xCol = "xd", yCol = "yd", from = 0, to = 3),
    list(shape = "window", xCol = "xd", yCol = "yd", from = -10, to = -2),
    list(shape = "before", xCol = "xd", yCol = "yd", inclusive = TRUE),
    list(shape = "before", xCol = "xd", yCol = "yd", inclusive = FALSE),
    list(shape = "after", xCol = "xd", yCol = "yd", inclusive = TRUE),
    list(shape = "after", xCol = "xd", yCol = "yd", inclusive = FALSE)
  )
  n_checked <- 0L
  for (kind in c("Date", "date-time", "numeric")) for (seed in 1:5) for (rule in rules) {
    t <- rule_tables(kind, seed)
    ref <- rule_reference(rule$shape, t, rule$from, rule$to, !identical(rule$inclusive, FALSE))
    d <- sv_join_diagnostics(t$x[c("id", "xd", "xe")], t$y, "id", rule = rule)
    jn <- function(f, ...) f(ref$x, t$y, by = ref$by, na_matches = "never", ...)
    lab <- paste(kind, seed, rule$shape, rule$from, rule$inclusive)
    expect_equal(d$rows$left_join, nrow(jn(dplyr::left_join, relationship = "many-to-many")), label = lab)
    expect_equal(d$rows$inner_join, nrow(jn(dplyr::inner_join, relationship = "many-to-many")), label = lab)
    expect_equal(d$rows$semi_join, nrow(jn(dplyr::semi_join)), label = lab)
    expect_equal(d$rows$anti_join, nrow(jn(dplyr::anti_join)), label = lab)
    if (rule$shape %in% c("between", "window", "overlaps")) {
      expect_equal(d$rows$right_join, nrow(jn(dplyr::right_join, relationship = "many-to-many")), label = lab)
      expect_equal(d$rows$full_join, nrow(jn(dplyr::full_join, relationship = "many-to-many")), label = lab)
    } else {
      expect_true(is.na(d$rows$right_join), label = lab)
      expect_true(is.na(d$rows$full_join), label = lab)
    }
    inner <- jn(dplyr::inner_join, relationship = "many-to-many")
    expect_equal(d$matched_x, dplyr::n_distinct(inner$.i), label = lab)
    n_checked <- n_checked + 1L
  }
  expect_equal(n_checked, 135L)
})

rule_visits <- function(ids = 1:3) {
  data.frame(id = ids, visit_date = rep(as.Date("2024-01-10"), length(ids)))
}
win7 <- list(shape = "window", xCol = "visit_date", yCol = "lab_date", from = -7, to = 7)

test_that("rule fields and strict_args", {
  d0 <- as.Date("2024-01-10")
  visits <- rule_visits()
  labs <- data.frame(id = c(1, 1, 2, 9), lab_date = d0 + c(-2, 2, 50, 0))
  d <- sv_join_diagnostics(visits, labs, "id", rule = win7)
  expect_equal(c(d$matched_x, d$matched_y), c(1, 2))
  expect_identical(d$relationship, "one-to-many")
  # one labs row has no partner: no unmatched = "error" on left or inner
  expect_identical(d$strict_args$left_join, list(relationship = "one-to-many"))
  expect_identical(d$strict_args$inner_join, list(relationship = "one-to-many"))
  expect_identical(d$strict_args$right_join, list(relationship = "one-to-many"))
  expect_identical(d$strict_args$full_join, list(relationship = "one-to-many"))
  expect_identical(names(d$strict_args), c("left_join", "inner_join", "right_join", "full_join"))
  # ids 1 and 2 have a key partner but only id 1 has a rule pair (hand count: 1 x row, 1 y row)
  expect_equal(d$rule_dropped_x, 1)
  expect_equal(d$rule_dropped_y, 1)
  expect_identical(d$rule$shape, "window")
  expect_identical(d$rule$from, -7)

  # everything matches: Strict can also write unmatched = "error"
  v2 <- rule_visits(1:2)
  l2 <- data.frame(id = c(1, 1, 2), lab_date = d0 + c(-2, 2, 1))
  f <- sv_join_diagnostics(v2, l2, "id", rule = win7)
  full <- list(relationship = "one-to-many", unmatched = "error")
  expect_identical(f$strict_args$left_join, full)
  expect_identical(f$strict_args$inner_join, full)
  expect_identical(f$strict_args$right_join, full)
  expect_identical(f$strict_args$full_join, list(relationship = "one-to-many"))
  expect_equal(c(f$rule_dropped_x, f$rule_dropped_y), c(0, 0))
  # visit 2 has no labs row: left and inner cannot say "error", right can
  l3 <- data.frame(id = c(1, 1), lab_date = d0 + c(-2, 2))
  g <- sv_join_diagnostics(v2, l3, "id", rule = win7)
  expect_identical(g$strict_args$left_join, full)
  expect_identical(g$strict_args$right_join, list(relationship = "one-to-many"))
  expect_identical(g$strict_args$inner_join, list(relationship = "one-to-many"))

  # no matches: no entry at all
  none <- sv_join_diagnostics(visits, data.frame(id = 1, lab_date = d0 + 99), "id", rule = win7)
  expect_identical(none$relationship, "no matches")
  expect_length(none$strict_args, 0)

  # nearest match: no right or full entry, and no right/full row counts
  b <- sv_join_diagnostics(v2, l2, "id",
                           rule = list(shape = "before", xCol = "visit_date", yCol = "lab_date", inclusive = TRUE))
  expect_true(is.na(b$rows$right_join))
  expect_true(is.na(b$rows$full_join))
  expect_identical(names(b$strict_args), c("left_join", "inner_join"))
  expect_identical(b$rule$inclusive, TRUE)
})

test_that("no rule changes nothing but adds strict_args", {
  patients <- data.frame(id = c(1, 2, 3, 4, NA), age = 1:5)
  visits <- data.frame(id = c(1, 1, 2, 2, 5, 6, NA), visit = 1:7)
  d <- sv_join_diagnostics(patients, visits, "id", x_name = "patients", y_name = "visits")
  expect_identical(names(d), c("by", "n_x", "n_y", "distinct_x", "distinct_y", "distinct_matched",
                               "matched_x", "matched_y", "match_rate_x", "match_rate_y", "na_x", "na_y",
                               "dup_keys_x", "dup_keys_y", "relationship", "rows", "unmatched_x",
                               "unmatched_y", "type_issues", "hints", "strict_args", "warnings", "status"))
  expect_null(d$rule)
  expect_match(d$warnings, "na_matches = \"na\"", fixed = TRUE, all = FALSE)
  expect_identical(d$strict_args$left_join, list(relationship = "one-to-many"))
  expect_identical(names(d$strict_args), c("left_join", "inner_join", "right_join", "full_join"))
  all <- sv_join_diagnostics(data.frame(k = 1:3), data.frame(k = 1:3), "k")
  expect_identical(all$strict_args$full_join, list(relationship = "one-to-one"))
  expect_identical(all$strict_args$inner_join, list(relationship = "one-to-one", unmatched = "error"))
})

test_that("print and json show the rule", {
  d0 <- as.Date("2024-01-10")
  d <- sv_join_diagnostics(rule_visits(1:2), data.frame(id = c(1, 1, 2), lab_date = d0 + c(-2, 2, 40)),
                           "id", rule = win7)
  out <- capture.output(print(d))
  expect_match(out, "  rule: lab_date within -7..+7 days of visit_date", fixed = TRUE, all = FALSE)
  expect_match(out, "dropped by the rule:", fixed = TRUE, all = FALSE)

  b <- sv_join_diagnostics(rule_visits(1:2), data.frame(id = c(1, 2), lab_date = d0 + c(-2, 1)), "id",
                           rule = list(shape = "before", xCol = "visit_date", yCol = "lab_date"))
  j <- sv_join_diagnostics_json(b)
  expect_false("right_join" %in% names(j$rows))
  expect_false("full_join" %in% names(j$rows))
  expect_true(all(c("left_join", "inner_join", "semi_join", "anti_join") %in% names(j$rows)))
  txt <- jsonlite::toJSON(j, auto_unbox = TRUE, null = "null")
  expect_false(grepl("right_join", txt, fixed = TRUE))
  none <- sv_join_diagnostics_json(sv_join_diagnostics(data.frame(k = 1), data.frame(k = 2), "k"))
  expect_identical(as.character(jsonlite::toJSON(none$strict_args, auto_unbox = TRUE)), "{}")
})

test_that("a rule changes the missing-key warning", {
  d0 <- as.Date("2024-01-10")
  v <- data.frame(id = c(1, NA), visit_date = d0)
  l <- data.frame(id = c(1, NA, NA), lab_date = d0)
  d <- sv_join_diagnostics(v, l, "id", rule = win7, x_name = "visits", y_name = "labs")
  expect_true(paste0("Missing keys (1 in visits, 2 in labs): with a date rule they match nothing ",
                     "(na_matches = \"never\").") %in% d$warnings)
  # a missing key matches nothing under a rule: the NA rows have no partner
  expect_equal(d$matched_x, 1)
  expect_equal(d$matched_y, 1)
  expect_equal(c(d$na_x, d$na_y), c(1, 2))
})

test_that("a bad rule stops with the shared message", {
  v <- rule_visits()
  l <- data.frame(id = 1, lab_date = as.Date("2024-01-10"))
  bad <- function(...) modifyList(win7, list(...))
  expect_error(sv_join_diagnostics(v, l, "id", rule = bad(from = 7.5)), "Window bounds must be whole numbers")
  expect_error(sv_join_diagnostics(v, l, "id", rule = bad(from = 9, to = 7)), "must not be after its end")
  expect_error(sv_join_diagnostics(v, l, "id", rule = bad(yCol = "nope")), "nope is not a date")
  expect_error(sv_join_diagnostics(v, l, "id", rule = list(shape = "zig")), "Unknown date rule.")
})

test_that("sv_join_rule_problem and sv_join_rule_label match the browser", {
  kx <- c(a = "Date", n = "numeric", t = "date-time", c = "character")
  ky <- c(b = "Date", n2 = "numeric", t2 = "date-time")
  w <- function(...) modifyList(list(shape = "window", xCol = "a", yCol = "b", from = -7, to = 7), list(...))
  p <- function(r, type = "left_join") sv_join_rule_problem(r, kx, ky, type)
  expect_null(p(w()))
  expect_identical(p(list(shape = "zig")), "Unknown date rule.")
  expect_identical(p(NULL), "Unknown date rule.")
  expect_identical(p(w(yCol = "")), "Pick a column for every slot.")
  expect_identical(p(list(shape = "between", xCol = "a", yFrom = "b")), "Pick a column for every slot.")
  expect_identical(p(w(xCol = "c")), "c is not a date, date-time or number.")
  expect_identical(p(w(yCol = "zzz")), "zzz is not a date, date-time or number.")
  expect_identical(p(w(yCol = "t2")), "a is Date but t2 is date-time: both sides of a date rule need the same kind.")
  expect_identical(p(w(yCol = "n2")), "a is Date but n2 is numeric: both sides of a date rule need the same kind.")
  bounds <- "Window bounds must be whole numbers from -3650 to 3650."
  expect_identical(p(w(from = "7.5")), bounds)
  expect_identical(p(w(from = -3651)), bounds)
  expect_identical(p(w(to = 3651)), bounds)
  expect_identical(p(utils::modifyList(w(), list(to = NULL))), bounds)
  expect_identical(p(w(from = "abc")), bounds)
  expect_identical(p(w(from = 8, to = 7)), "The window start must not be after its end.")
  expect_null(p(w(from = "-7", to = "7")))
  expect_null(p(w(from = -3650, to = 3650)))
  nearest <- "A nearest-match rule works with left, inner, semi and anti joins only."
  expect_identical(p(list(shape = "before", xCol = "a", yCol = "b"), "right_join"), nearest)
  expect_identical(p(list(shape = "after", xCol = "a", yCol = "b"), "full_join"), nearest)
  expect_null(p(list(shape = "after", xCol = "a", yCol = "b"), "semi_join"))
  expect_null(p(w(), "right_join"))

  L <- sv_join_rule_label
  expect_identical(L(list(shape = "window", xCol = "v", yCol = "l", from = 0, to = 3), "Date"), "l within 0..+3 days of v")
  expect_identical(L(list(shape = "window", xCol = "v", yCol = "l", from = -10, to = -2), "date-time"),
                   "l within -10..-2 days of v")
  expect_identical(L(list(shape = "window", xCol = "vady", yCol = "ady", from = -7, to = 7), "numeric"),
                   "ady within -7..+7 of vady")
  expect_identical(L(list(shape = "before", xCol = "visit_date", yCol = "lab_date"), "Date"),
                   "last lab_date on or before visit_date")
  expect_identical(L(list(shape = "before", xCol = "visit_date", yCol = "lab_date", inclusive = FALSE), "Date"),
                   "last lab_date before visit_date")
  expect_identical(L(list(shape = "after", xCol = "visit_date", yCol = "lab_date", inclusive = TRUE), "Date"),
                   "first lab_date on or after visit_date")
  expect_identical(L(list(shape = "after", xCol = "visit_date", yCol = "lab_date", inclusive = FALSE), "Date"),
                   "first lab_date after visit_date")
  expect_identical(L(list(shape = "between", xCol = "visit_date", yFrom = "start", yTo = "end"), "Date"),
                   "visit_date between start and end")
  expect_identical(L(list(shape = "overlaps", xFrom = "ae_start", xTo = "ae_end", yFrom = "start", yTo = "end"), "Date"),
                   "ae_start..ae_end overlaps start..end")
})
