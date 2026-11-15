# Runs the accessibility test files and fails the job when nothing really ran.
# A skipped browser test is reported green by testthat, so check the results here:
# no expectation may be skipped for a missing browser or axe-core, and each file
# must have passed at least one expectation.
files <- c("a11y-browser", "say")
bad <- character()
for (f in files) {
  path <- file.path("tests/testthat", paste0("test-", f, ".R"))
  if (!file.exists(path)) { message("no test file for filter: ", f); next }
  res <- testthat::test_local(filter = f, reporter = "silent", stop_on_failure = FALSE)
  df <- as.data.frame(res)
  skips <- unlist(lapply(res, function(t) {
    vapply(t$results, function(e) if (inherits(e, "expectation_skip")) conditionMessage(e) else NA_character_, "")
  }))
  skips <- skips[!is.na(skips)]
  missing_tool <- grepl("Chrome not found|axe-core not found|not installed", skips)
  message(sprintf("%s: %d passed, %d failed, %d skipped, %d errors", f,
                  sum(df$passed), sum(df$failed), sum(df$skipped), sum(df$error)))
  if (sum(df$failed) > 0 || any(df$error)) bad <- c(bad, paste0(f, ": failed expectations or errors"))
  if (sum(df$passed) == 0) bad <- c(bad, paste0(f, ": 0 passed expectations"))
  if (any(missing_tool)) bad <- c(bad, paste0(f, ": skipped for a missing tool: ", paste(unique(skips[missing_tool]), collapse = "; ")))
}
if (length(bad)) {
  message(paste0("FAIL ", bad, collapse = "\n"))
  quit(status = 1)
}
