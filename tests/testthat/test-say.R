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
