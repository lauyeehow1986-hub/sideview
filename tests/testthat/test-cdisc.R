test_that("the catalogue has the documented shape", {
  cat <- sv_cdisc_catalogue()
  expect_s3_class(cat, "data.frame")
  expect_identical(names(cat), c("name", "label", "class", "standard", "ig_versions", "keys"))
  expect_false(anyDuplicated(paste(cat$name, cat$standard)) > 0)
  expect_true(all(cat$standard %in% c("SDTM", "SEND", "ADaM")))
  classes <- c("Special-Purpose", "Interventions", "Events", "Findings", "Findings About",
               "Trial Design", "Relationship", "Study Reference", "ADSL", "BDS", "OCCDS", "TTE")
  expect_true(all(cat$class %in% classes))
  expect_true(all(grepl("^[0-9.]+(;[0-9.]+)*$", cat$ig_versions)))
  expect_true(all(vapply(cat, is.character, logical(1))))
})

test_that("the catalogue knows the domains detection relies on", {
  cat <- sv_cdisc_catalogue()
  sdtm <- cat$name[cat$standard == "SDTM"]
  expect_true(all(c("AE", "DM", "LB", "TS", "SUPPQUAL") %in% sdtm))
  send <- cat$name[cat$standard == "SEND"]
  expect_true(all(c("BW", "TX") %in% send))
  expect_false(any(c("BW", "TX") %in% sdtm))
  expect_true(all(c("ADSL", "BDS", "OCCDS", "TTE") %in% cat$name[cat$standard == "ADaM"]))
  expect_identical(cat$label[cat$name == "AE" & cat$standard == "SDTM"], "Adverse Events")
  expect_identical(cat$label[cat$name == "TS" & cat$standard == "SDTM"], "Trial Summary")
})

test_that("the catalogue is read once", {
  expect_identical(sv_cdisc_catalogue(), sv_cdisc_catalogue())
  testthat::local_mocked_bindings(read.csv = function(...) stop("re-read"), .package = "utils")
  expect_s3_class(sv_cdisc_catalogue(), "data.frame")
})

test_that("ADaM rows have empty keys and class equal to name", {
  adam <- sv_cdisc_catalogue()
  adam <- adam[adam$standard == "ADaM", ]
  expect_true(all(adam$keys == ""))
  expect_identical(adam$class, adam$name)
})

test_that("each fixture gets its domain", {
  f <- sv_cdisc_fixtures()
  want <- list(
    list("dm", "dm", "DM", "Special-Purpose", "SDTM"),
    list("ae", "ae", "AE", "Events", "SDTM"),
    list("suppae", "suppae", "SUPPAE", "Relationship", "SDTM"),
    list("labs", "labs", "LB", "Findings", "SDTM"),
    list("ts", "ts", "TS", "Trial Design", "SDTM"),
    list("xy", "xy", "XY", "Custom", "SDTM"),
    list("adsl", "adsl", "ADSL", "ADSL", "ADaM"),
    list("adlb", "adlb", "ADLB", "BDS", "ADaM"),
    list("adtte", "adtte", "ADTTE", "TTE", "ADaM"),
    list("adae", "adae", "ADAE", "OCCDS", "ADaM"),
    list("bw", "bw", "BW", "Findings", "SEND"))
  for (w in want) {
    tag <- sv_cdisc_detect(f[[w[[1]]]], w[[2]])
    info <- paste("fixture", w[[1]])
    expect_false(is.null(tag), info = info)
    expect_identical(tag$domain, w[[3]], info = info)
    expect_identical(tag$class, w[[4]], info = info)
    expect_identical(tag$standard, w[[5]], info = info)
    expect_identical(tag$source, "auto", info = info)
    expect_null(tag$parent_card, info = info)
  }
  expect_identical(sv_cdisc_detect(f$suppae, "suppae")$parent, "AE")
  expect_null(sv_cdisc_detect(f$ae, "ae")$parent)
  expect_true("STUDYID + trial-design DOMAIN TS" %in% sv_cdisc_detect(f$ts, "ts")$evidence)
  expect_true("variable prefix LB (6 columns)" %in% sv_cdisc_detect(f$labs, "labs")$evidence)
  expect_true("ADaM structure BDS" %in% sv_cdisc_detect(f$adlb, "adlb")$evidence)
  expect_true("custom domain XY" %in% sv_cdisc_detect(f$xy, "xy")$evidence)
  expect_true("SUPP name suppae" %in% sv_cdisc_detect(f$suppae, "suppae")$evidence)
  ev <- sv_cdisc_detect(f$ae, "ae")$evidence
  expect_true(all(c("DOMAIN column = AE", "STUDYID + USUBJID") %in% ev))
})

test_that("negatives get no tag", {
  f <- sv_cdisc_fixtures()
  expect_null(sv_cdisc_detect(f$mtcars, "mtcars"))
  expect_null(sv_cdisc_detect(f$iris, "iris"))
  expect_null(sv_cdisc_detect(f$ae_nostudy, "ae"))
  expect_null(sv_cdisc_detect(f$studyid_only, "studyid_only"))
  expect_null(sv_cdisc_detect(f$keys_only, "keys_only"))
})

test_that("DOMAIN beats the name and records the conflict", {
  f <- sv_cdisc_fixtures()
  tag <- sv_cdisc_detect(f$ae, "cm")
  expect_identical(tag$domain, "AE")
  expect_true("name cm disagrees with DOMAIN AE" %in% tag$evidence)
  f$ae$DOMAIN <- NULL
  tag <- sv_cdisc_detect(f$ae, "cm")
  expect_identical(tag$domain, "CM")
  expect_true("prefix AE disagrees with name CM" %in% tag$evidence)
  tag <- sv_cdisc_detect(sv_cdisc_fixtures()$ae, "ae.xpt")
  expect_identical(tag$domain, "AE")
  expect_false(any(grepl("disagrees", tag$evidence)))
})

test_that("labels come from the attribute, else the catalogue", {
  f <- sv_cdisc_fixtures()
  expect_identical(sv_cdisc_detect(f$dm, "dm")$label, "Demographics")
  cat <- sv_cdisc_catalogue()
  expect_identical(sv_cdisc_detect(f$ae, "ae")$label,
                   cat$label[cat$name == "AE" & cat$standard == "SDTM"])
})

test_that("messy DOMAIN values still match", {
  f <- sv_cdisc_fixtures()
  d <- f$ae[1:3, ]
  d$DOMAIN <- factor(c(" ae", "AE", NA))
  expect_identical(sv_cdisc_detect(d, "x")$domain, "AE")
  l <- f$labs
  l$DOMAIN <- NA_character_
  expect_identical(sv_cdisc_detect(l, "x")$domain, "LB")
})

test_that("zero-row tables are tagged without error", {
  f <- sv_cdisc_fixtures()
  expect_identical(sv_cdisc_detect(f$ae[0, ], "ae")$domain, "AE")
})

test_that("cdisc = FALSE and a user code", {
  f <- sv_cdisc_fixtures()
  expect_null(sv_cdisc_detect(f$ae, "ae", cdisc = FALSE))
  tag <- sv_cdisc_detect(f$keys_only, "keys_only", cdisc = "LB")
  expect_identical(tag$domain, "LB")
  expect_identical(tag$source, "user")
  expect_identical(tag$evidence, "set by cdisc =")
  expect_identical(sv_cdisc_detect(f$mtcars, "m", cdisc = "QQ")$class, "Custom")
})

test_that("bad cdisc values are refused", {
  expect_error(sv_cdisc_check_arg(TRUE), "cdisc")
  expect_error(sv_cdisc_check_arg(1), "cdisc")
  expect_error(sv_cdisc_check_arg(c("AE", "LB")), "cdisc")
  expect_error(sv_cdisc_check_arg(NA), "cdisc")
  expect_identical(sv_cdisc_check_arg("auto"), "auto")
  expect_identical(sv_cdisc_check_arg(FALSE), FALSE)
  expect_identical(sv_cdisc_check_arg(c(a = "AE")), c(a = "AE"))
})

test_that("a failing detector is silent unless debugging", {
  f <- sv_cdisc_fixtures()
  testthat::local_mocked_bindings(sv_cdisc_rule_domain_col = function(...) stop("boom"))
  expect_silent(res <- sv_cdisc_detect_safely(f$ae, "ae"))
  expect_null(res)
  withr::local_options(sideview.debug = TRUE)
  expect_message(sv_cdisc_detect_safely(f$ae, "ae"), "boom")
})

test_that("an ADaM table name is confirmed by structure", {
  f <- sv_cdisc_fixtures()
  tag <- sv_cdisc_detect(f$adsl, "adsl")
  expect_identical(c(tag$domain, tag$class, tag$standard), c("ADSL", "ADSL", "ADaM"))
  expect_true("ADaM structure ADSL" %in% tag$evidence)
  dup <- rbind(f$adsl, f$adsl[1, ])
  expect_null(sv_cdisc_detect(dup, "adsl"))
})

test_that("a named cdisc vector resolves by table name", {
  f <- sv_cdisc_fixtures()
  expect_identical(sv_cdisc_detect(f$keys_only, "a", cdisc = c(a = "AE"))$domain, "AE")
  expect_null(sv_cdisc_detect(f$keys_only, "b", cdisc = c(a = "AE")))
  tag <- sv_cdisc_detect(f$keys_only, "lab", cdisc = c(lab = "ADLB"))
  expect_identical(c(tag$domain, tag$standard, tag$class, tag$source),
                   c("ADLB", "ADaM", "Custom", "user"))
})

test_that("file extensions are stripped from the table name", {
  f <- sv_cdisc_fixtures()
  for (ext in c("xpt", "csv", "sas7bdat", "parquet")) {
    tag <- sv_cdisc_detect(f$keys_only[0, ], paste0("ae.", ext))
    expect_identical(tag$domain, "AE", info = ext)
    expect_true("table name = ae" %in% tag$evidence, info = ext)
  }
})

test_that("odd DOMAIN columns do not error", {
  f <- sv_cdisc_fixtures()
  d <- f$ae
  d$DOMAIN <- c("AE", "CM", "AE", "CM")
  tag <- sv_cdisc_detect(d, "x")
  expect_false(any(grepl("^DOMAIN column", tag$evidence)))
  d$DOMAIN <- 1:4
  expect_no_error(sv_cdisc_detect(d, "x"))
})

test_that("SUPP is detected by columns alone, with its parent", {
  f <- sv_cdisc_fixtures()
  tag <- sv_cdisc_detect(f$suppae, "x")
  expect_identical(tag$class, "Relationship")
  expect_identical(tag$parent, "AE")
  expect_true("SUPPQUAL columns" %in% tag$evidence)
})

test_that("known limitation: an ADaM-like table outside the catalogue is tagged by prefix", {
  f <- sv_cdisc_fixtures()
  d <- cbind(f$adae, AESEV = "MILD")
  tag <- sv_cdisc_detect(d, "foo")
  expect_identical(tag$domain, "AE")
  expect_identical(tag$standard, "SDTM")
})
