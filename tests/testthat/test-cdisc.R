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

# ---- canvas resolve and finalize (Task 4) ----
sv_cdisc_cards <- function(...) {
  l <- list(...)
  unname(Map(function(d, n) sv_normalize(d, name = n), l, names(l)))
}

test_that("a SEND-only domain flips shared domains to SEND", {
  f <- sv_cdisc_fixtures()
  dm <- f$dm
  attr(dm, "label") <- NULL
  cards <- sv_cdisc_finalize(sv_cdisc_cards(dm = dm, bw = f$bw), "auto")
  expect_identical(cards[[1]]$cdisc$standard, "SEND")
  send_label <- sv_cdisc_catalogue()
  send_label <- send_label$label[send_label$name == "DM" & send_label$standard == "SEND"]
  expect_identical(cards[[1]]$cdisc$domain, "DM")
  expect_identical(cards[[1]]$cdisc$label, send_label)
  expect_identical(cards[[2]]$cdisc$standard, "SEND")
})

test_that("SPECIES flips DM to SEND", {
  f <- sv_cdisc_fixtures()
  cards <- sv_cdisc_finalize(sv_cdisc_cards(dm = f$send_dm, ae = f$ae), "auto")
  expect_identical(cards[[1]]$cdisc$standard, "SEND")
  # AE has no SEND row in the catalogue, so only shared domains flip.
  expect_identical(cards[[2]]$cdisc$standard, "SDTM")
})

test_that("without SEND evidence domains stay SDTM", {
  f <- sv_cdisc_fixtures()
  cards <- sv_cdisc_finalize(sv_cdisc_cards(dm = f$dm, ae = f$ae), "auto")
  expect_identical(cards[[1]]$cdisc$standard, "SDTM")
  expect_identical(cards[[2]]$cdisc$standard, "SDTM")
})

test_that("resolve flips back when the SEND evidence is gone", {
  f <- sv_cdisc_fixtures()
  both <- sv_cdisc_finalize(sv_cdisc_cards(dm = f$dm, bw = f$bw), "auto")
  alone <- sv_cdisc_resolve(both[1])
  expect_identical(alone[[1]]$cdisc$standard, "SDTM")
})

test_that("SUPP links to its parent card", {
  f <- sv_cdisc_fixtures()
  cards <- sv_cdisc_finalize(sv_cdisc_cards(ae = f$ae, suppae = f$suppae), "auto")
  expect_identical(cards[[2]]$cdisc$parent_card, cards[[1]]$id)
  solo <- sv_cdisc_finalize(sv_cdisc_cards(suppae = f$suppae), "auto")
  expect_null(solo[[1]]$cdisc$parent_card)
})

test_that("cdisc = FALSE strips every tag; overrides re-tag; unknown names warn", {
  f <- sv_cdisc_fixtures()
  cards <- sv_cdisc_cards(dm = f$dm, ae = f$ae)
  off <- sv_cdisc_finalize(cards, FALSE)
  expect_true(all(vapply(off, function(c) is.null(c$cdisc), logical(1))))
  re <- sv_cdisc_finalize(cards, c(ae = "CM"))
  expect_identical(re[[2]]$cdisc$domain, "CM")
  expect_identical(re[[2]]$cdisc$source, "user")
  expect_identical(re[[1]]$cdisc$domain, "DM")
  expect_warning(sv_cdisc_finalize(cards, c(nope = "AE")), "names no table: nope")
})

test_that("only grid cards are tagged", {
  skip_if_not_installed("gt")
  g <- gt::gt(sv_cdisc_fixtures()$ae)
  card <- sv_normalize(g, name = "ae")
  expect_identical(card$type, "html")
  expect_null(card$cdisc)
})

test_that("tag_diff reports changed tags only", {
  f <- sv_cdisc_fixtures()
  old <- sv_cdisc_finalize(sv_cdisc_cards(dm = f$dm), "auto")
  new <- sv_cdisc_finalize(c(old, sv_cdisc_cards(bw = f$bw)), "auto")
  d <- sv_cdisc_tag_diff(old, new)
  expect_setequal(names(d), c(old[[1]]$id, new[[2]]$id))
  expect_identical(d[[old[[1]]$id]]$standard, "SEND")
  expect_length(sv_cdisc_tag_diff(new, new), 0L)
  gone <- sv_cdisc_tag_diff(new, new[2])
  expect_length(gone, 0L)
})

test_that("a user-set tag is not flipped by a SEND-only card", {
  f <- sv_cdisc_fixtures()
  cards <- sv_cdisc_finalize(sv_cdisc_cards(dm = f$dm, bw = f$bw), c(dm = "DM"))
  expect_identical(cards[[1]]$cdisc$source, "user")
  expect_identical(cards[[1]]$cdisc$standard, "SDTM")
  expect_identical(cards[[2]]$cdisc$standard, "SEND")
})

test_that("SUPP parent_card is cleared when the parent card is removed", {
  f <- sv_cdisc_fixtures()
  cards <- sv_cdisc_finalize(sv_cdisc_cards(ae = f$ae, suppae = f$suppae), "auto")
  expect_identical(cards[[2]]$cdisc$parent_card, cards[[1]]$id)
  after <- sv_cdisc_resolve(cards[2])
  expect_null(after[[1]]$cdisc$parent_card)
  expect_identical(sv_cdisc_resolve(after), after)
})

test_that("sideview() checks cdisc and cdisc = FALSE leaves cards untagged", {
  f <- sv_cdisc_fixtures()
  expect_error(sideview(f$dm, cdisc = "bad", run = FALSE), "cdisc")
  app <- sideview(dm = f$dm, ae = f$ae, cdisc = FALSE, run = FALSE)
  expect_true(all(vapply(app$cards, function(c) is.null(c$cdisc), logical(1))))
  tagged <- sideview(dm = f$dm, run = FALSE)
  expect_identical(tagged$cards[[1]]$cdisc$domain, "DM")
})

# ---- sv_read_cdisc() ----------------------------------------------------------

test_that("xpt round trip keeps labels", {
  skip_if_not_installed("haven")
  skip_if_not_installed("withr")
  f <- sv_cdisc_fixtures()
  dir <- withr::local_tempdir()
  haven::write_xpt(f$dm, file.path(dir, "dm.xpt"))
  haven::write_xpt(f$ae, file.path(dir, "AE.XPT"))
  x <- sv_read_cdisc(dir)
  expect_identical(names(x), c("ae", "dm"))
  expect_identical(attr(x$dm$USUBJID, "label"), "Unique Subject Identifier")
  w <- sideview_widget(x)
  tags <- vapply(w$x$cards, function(c) c$cdisc$domain %||% NA_character_, character(1))
  expect_setequal(tags, c("AE", "DM"))
})

test_that("parquet is lazy by default and eager on request", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("withr")
  f <- sv_cdisc_fixtures()
  dir <- withr::local_tempdir()
  arrow::write_parquet(f$ae, file.path(dir, "ae.parquet"))
  arrow::write_parquet(f$dm, file.path(dir, "dm.parquet"))
  x <- sv_read_cdisc(dir)
  expect_s3_class(x$ae, "Dataset")
  expect_identical(sv_normalize(x$ae, "ae")$cdisc$domain, "AE")
  expect_identical(sv_card_payload(sv_normalize(x$dm, "dm"))$col_labels$USUBJID,
                   "Unique Subject Identifier")
  y <- sv_read_cdisc(dir, lazy = FALSE)
  expect_true(is.data.frame(y$ae))
  expect_identical(sv_normalize(y$ae, "ae")$cdisc$domain, "AE")
  expect_identical(sv_card_payload(sv_normalize(y$dm, "dm"))$col_labels$AGE, "Age")
})

test_that("dataset-json is read when datasetjson is installed", {
  skip_if_not_installed("datasetjson")
  skip_if_not_installed("withr")
  f <- sv_cdisc_fixtures()
  dir <- withr::local_tempdir()
  ds <- datasetjson::dataset_json(f$ae, item_oid = "IG.AE", name = "AE", dataset_label = "Adverse Events",
                                  file_oid = "x", last_modified = "2024-01-01T00:00:00",
                                  originator = "t", sys = "t", sys_version = "1", study = "S",
                                  metadata_version = "1", metadata_ref = "x")
  datasetjson::write_dataset_json(ds, file.path(dir, "ae.json"))
  x <- sv_read_cdisc(file.path(dir, "ae.json"))
  expect_identical(sv_normalize(x$ae, "ae")$cdisc$domain, "AE")
})

test_that("sas7bdat goes through haven::read_sas", {
  skip_if_not_installed("haven")
  skip_if_not_installed("withr")
  f <- sv_cdisc_fixtures()
  dir <- withr::local_tempdir()
  file.create(file.path(dir, "ae.sas7bdat"))
  testthat::local_mocked_bindings(read_sas = function(path, ...) f$ae, .package = "haven")
  x <- sv_read_cdisc(dir)
  expect_identical(names(x), "ae")
  expect_identical(sv_normalize(x$ae, "ae")$cdisc$domain, "AE")
})

test_that("sv_read_cdisc names a missing package", {
  skip_if_not_installed("withr")
  dir <- withr::local_tempdir()
  file.create(file.path(dir, c("dm.xpt", "ae.xpt")))
  testthat::local_mocked_bindings(sv_has_pkg = function(pkg) FALSE)
  expect_error(sv_read_cdisc(dir),
               "Reading .xpt files needs the haven package: ae.xpt, dm.xpt.", fixed = TRUE)
})

test_that("sv_read_cdisc rejects a named unsupported file", {
  skip_if_not_installed("withr")
  dir <- withr::local_tempdir()
  p <- file.path(dir, "notes.txt")
  writeLines("x", p)
  expect_error(sv_read_cdisc(p), "Unsupported file type: notes.txt.", fixed = TRUE)
})

test_that("sv_read_cdisc warns and skips an unreadable file", {
  skip_if_not_installed("haven")
  skip_if_not_installed("withr")
  f <- sv_cdisc_fixtures()
  dir <- withr::local_tempdir()
  writeLines("not a transport file", file.path(dir, "bad.xpt"))
  haven::write_xpt(f$dm, file.path(dir, "dm.xpt"))
  expect_warning(x <- sv_read_cdisc(dir), "Could not read bad.xpt (", fixed = TRUE)
  expect_warning(sv_read_cdisc(dir), "); skipped.", fixed = TRUE)
  expect_identical(names(x), "dm")
})

test_that("sv_read_cdisc refuses duplicate stems", {
  skip_if_not_installed("withr")
  dir <- withr::local_tempdir()
  file.create(file.path(dir, c("ae.xpt", "ae.parquet")))
  testthat::local_mocked_bindings(sv_has_pkg = function(pkg) TRUE)
  expect_error(sv_read_cdisc(dir), "Two files have the stem `ae`: ae.parquet, ae.xpt.", fixed = TRUE)
})

test_that("sv_read_cdisc errors when nothing is supported or the path is missing", {
  skip_if_not_installed("withr")
  dir <- withr::local_tempdir()
  writeLines("x", file.path(dir, "notes.txt"))
  expect_error(sv_read_cdisc(dir),
               sprintf("No .xpt, .sas7bdat, .json or .parquet files in %s.", dir), fixed = TRUE)
  gone <- file.path(dir, "nope")
  expect_error(sv_read_cdisc(gone), sprintf("Not found: %s.", gone), fixed = TRUE)
})

test_that("unsupported files in a directory are ignored", {
  skip_if_not_installed("haven")
  skip_if_not_installed("withr")
  dir <- withr::local_tempdir()
  haven::write_xpt(sv_cdisc_fixtures()$ae, file.path(dir, "ae.xpt"))
  writeLines("x", file.path(dir, "notes.txt"))
  expect_identical(names(sv_read_cdisc(dir)), "ae")
})
