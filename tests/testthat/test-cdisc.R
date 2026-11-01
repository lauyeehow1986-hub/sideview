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
