# Source R files if running standalone without package installed
if (!"package:sideview" %in% search()) {
  r_files <- list.files(c("R", "../R", "../../R"), pattern = "\\.[Rr]$", full.names = TRUE)
  for (f in r_files) source(f)
}

test_that("sv_suggest_mappings accepts list of sideview_cards and returns expected schema", {
  df1 <- data.frame(
    patient_id = 1:5,
    name = c("Alice", "Bob", "Charlie", "David", "Eve"),
    stringsAsFactors = FALSE
  )
  df2 <- data.frame(
    patient_id = 3:7,
    diagnosis = c("Flu", "Cold", "Covid", "Headache", "Fever"),
    stringsAsFactors = FALSE
  )
  
  card1 <- sv_normalize(df1, name = "patients")
  card2 <- sv_normalize(df2, name = "diagnoses")
  
  mappings <- sv_suggest_mappings(list(card1, card2))
  
  expect_s3_class(mappings, "data.frame")
  expect_equal(
    colnames(mappings),
    c("from_table", "from_col", "to_table", "to_col", "confidence", "reason")
  )
  expect_type(mappings$from_table, "character")
  expect_type(mappings$from_col, "character")
  expect_type(mappings$to_table, "character")
  expect_type(mappings$to_col, "character")
  expect_type(mappings$confidence, "double")
  expect_type(mappings$reason, "character")
})

test_that("exact key matches receive high confidence (>= 0.85)", {
  df_a <- data.frame(
    patient_id = 101:110,
    age = c(25, 30, 45, 50, 22, 64, 71, 33, 40, 55),
    stringsAsFactors = FALSE
  )
  df_b <- data.frame(
    patient_id = 103:110,
    visit_date = as.Date("2026-01-01") + 0:7,
    stringsAsFactors = FALSE
  )
  
  card_a <- sv_normalize(df_a, name = "patients")
  card_b <- sv_normalize(df_b, name = "visits")
  
  mappings <- sv_suggest_mappings(list(card_a, card_b))
  
  expect_gte(nrow(mappings), 1)
  
  top_match <- mappings[1, ]
  expect_equal(top_match$from_table, "patients")
  expect_equal(top_match$from_col, "patient_id")
  expect_equal(top_match$to_table, "visits")
  expect_equal(top_match$to_col, "patient_id")
  expect_gte(top_match$confidence, 0.85)
  expect_match(top_match$reason, "Exact name match", ignore.case = TRUE)
})

test_that("fuzzy key matches (e.g. patient_id and pat_id) receive strong confidence with overlapping values", {
  df1 <- data.frame(
    patient_id = 201:210,
    blood_group = rep(c("A", "B"), 5),
    stringsAsFactors = FALSE
  )
  df2 <- data.frame(
    pat_id = 201:210,
    heart_rate = rep(72, 10),
    stringsAsFactors = FALSE
  )
  
  mappings <- sv_suggest_mappings(list(patients = df1, vitals = df2))
  
  expect_gte(nrow(mappings), 1)
  
  fuzzy_match <- mappings[mappings$from_col == "patient_id" & mappings$to_col == "pat_id", ]
  expect_equal(nrow(fuzzy_match), 1)
  expect_gte(fuzzy_match$confidence, 0.80)
  expect_match(fuzzy_match$reason, "ID suffix", ignore.case = TRUE)
})

test_that("completely unrelated columns with 0% overlap and different types receive low scores and are filtered out", {
  df1 <- data.frame(
    event_name = c("Registration", "Login", "Logout", "Checkout"),
    notes = c("Alpha", "Beta", "Gamma", "Delta"),
    stringsAsFactors = FALSE
  )
  df2 <- data.frame(
    sensor_id = 1001:1005,
    temperature = c(98.6, 99.1, 97.8, 100.2, 98.4),
    stringsAsFactors = FALSE
  )
  
  mappings_default <- sv_suggest_mappings(list(events = df1, sensors = df2))
  expect_equal(nrow(mappings_default), 0)
  
  # When min_confidence is 0, pairs are returned but unrelated ones have low confidence
  mappings_all <- sv_suggest_mappings(list(events = df1, sensors = df2), min_confidence = 0.0)
  expect_gte(nrow(mappings_all), 1)
  expect_true(all(mappings_all$confidence < 0.35))
})

test_that("custom min_confidence filtering works as expected", {
  df1 <- data.frame(
    patient_id = 1:10,
    code = letters[1:10],
    stringsAsFactors = FALSE
  )
  df2 <- data.frame(
    patient_id = 1:10,
    cd = letters[1:10], # partial name match with code
    stringsAsFactors = FALSE
  )
  
  # High threshold (0.95): only exact key match passes
  mappings_high <- sv_suggest_mappings(list(t1 = df1, t2 = df2), min_confidence = 0.95)
  expect_equal(nrow(mappings_high), 1)
  expect_equal(mappings_high$from_col, "patient_id")
  expect_equal(mappings_high$to_col, "patient_id")
  
  # Lower threshold (0.50): includes the secondary fuzzy column match
  mappings_low <- sv_suggest_mappings(list(t1 = df1, t2 = df2), min_confidence = 0.50)
  expect_gte(nrow(mappings_low), 2)
  expect_true(mappings_low$confidence[1] >= mappings_low$confidence[2])
})

test_that("gracefully handles cards without tabular data, single card, or empty card list", {
  # Empty list
  res_empty <- sv_suggest_mappings(list())
  expect_s3_class(res_empty, "data.frame")
  expect_equal(nrow(res_empty), 0)
  expect_equal(colnames(res_empty), c("from_table", "from_col", "to_table", "to_col", "confidence", "reason"))
  
  # NULL input
  res_null <- sv_suggest_mappings(NULL)
  expect_equal(nrow(res_null), 0)
  expect_equal(colnames(res_null), c("from_table", "from_col", "to_table", "to_col", "confidence", "reason"))
  
  # Single card
  df <- data.frame(x = 1:5, y = 6:10)
  res_single <- sv_suggest_mappings(list(df))
  expect_equal(nrow(res_single), 0)
  expect_equal(colnames(res_single), c("from_table", "from_col", "to_table", "to_col", "confidence", "reason"))
  
  # Card with widget / non-grid type
  card_widget <- structure(
    list(id = "w1", name = "WidgetCard", type = "widget", data = NULL),
    class = c("sideview_card", "list")
  )
  card_valid <- sv_normalize(df, name = "DataCard")
  res_widget <- sv_suggest_mappings(list(card_valid, card_widget))
  expect_equal(nrow(res_widget), 0)
  expect_equal(colnames(res_widget), c("from_table", "from_col", "to_table", "to_col", "confidence", "reason"))
  
  # Card with 0-row empty data frame
  df_empty <- data.frame(x = integer(0), y = character(0))
  card_empty <- sv_normalize(df_empty, name = "EmptyCard")
  res_empty_card <- sv_suggest_mappings(list(card_valid, card_empty))
  expect_equal(nrow(res_empty_card), 0)
  expect_equal(colnames(res_empty_card), c("from_table", "from_col", "to_table", "to_col", "confidence", "reason"))
})

test_that("results are sorted by confidence descending", {
  df1 <- data.frame(
    id = 1:10,
    category = rep(c("A", "B"), 5),
    subcat = rep(c("X", "Y"), 5),
    stringsAsFactors = FALSE
  )
  df2 <- data.frame(
    id = 1:10,
    category = rep(c("A", "B"), 5),
    notes = rep("info", 10),
    stringsAsFactors = FALSE
  )
  
  mappings <- sv_suggest_mappings(list(t1 = df1, t2 = df2), min_confidence = 0.5)
  if (nrow(mappings) > 1) {
    diffs <- diff(mappings$confidence)
    expect_true(all(diffs <= 0))
  }
})

test_that("logical/boolean columns (e.g. is_active vs is_deleted) are not suggested as foreign keys", {
  df1 <- data.frame(
    id = 1:10,
    is_active = rep(c(TRUE, FALSE), 5),
    stringsAsFactors = FALSE
  )
  df2 <- data.frame(
    id = 1:10,
    is_deleted = rep(c(FALSE, TRUE), 5),
    is_active = rep(c(TRUE, FALSE), 5),
    stringsAsFactors = FALSE
  )

  # Even with identical names or high overlap, logical columns should never be suggested
  mappings <- sv_suggest_mappings(list(t1 = df1, t2 = df2), min_confidence = 0.0)

  expect_false(any(mappings$from_col == "is_active"))
  expect_false(any(mappings$to_col == "is_active"))
  expect_false(any(mappings$to_col == "is_deleted"))

  # The integer id <-> id foreign key match should still be suggested
  expect_true(any(mappings$from_col == "id" & mappings$to_col == "id"))
})

test_that("splitReply keeps the prose before and after the code in order", {
  out <- run_pipeline_js("
    out = {
      both: P.splitReply('Join first.\\n\\n```r\\nx\\n```\\n\\nThen count.'),
      two: P.splitReply('A\\n```r\\nx\\n```\\nB\\n```\\ny\\n```\\nC'),
      none: P.splitReply('  just prose  '),
      empty: P.splitReply(null)
    };
  ")
  expect_identical(out$both, list(before = "Join first.", after = "Then count.", hasCode = TRUE))
  expect_identical(out$two$before, "A")
  expect_identical(out$two$after, "B\n\nC")
  expect_identical(out$none, list(before = "just prose", after = "", hasCode = FALSE))
  expect_identical(out$empty, list(before = "", after = "", hasCode = FALSE))
})
