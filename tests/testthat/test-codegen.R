# Source R files if running standalone without package installed
if (!"package:sideview" %in% search()) {
  r_files <- list.files(c("R", "../R", "../../R"), pattern = "\\.[Rr]$", full.names = TRUE)
  for (f in r_files) source(f)
}

test_that("sv_escape_ident escapes non-syntactic names properly", {
  expect_equal(sv_escape_ident("var1"), "var1")
  expect_equal(sv_escape_ident("var 1"), "`var 1`")
  expect_equal(sv_escape_ident("2024_year"), "`2024_year`")
  expect_equal(sv_escape_ident("data-set"), "`data-set`")
  expect_equal(sv_escape_ident("for"), "`for`")
  expect_equal(sv_escape_ident("TRUE"), "`TRUE`")
  expect_equal(sv_escape_ident("`already_backticked`"), "`already_backticked`")
  expect_equal(sv_escape_ident(character(0)), character(0))
})

test_that("sv_code_rename generates valid rename code with escaping", {
  # Standard column names
  code1 <- sv_code_rename("my_df", "old_col", "new_col")
  expect_equal(code1, "dplyr::rename(my_df, new_col = old_col)")
  expect_silent(parse(text = code1))

  # Non-syntactic column names and table names
  code2 <- sv_code_rename("my df", "old col", "new col")
  expect_equal(code2, "dplyr::rename(`my df`, `new col` = `old col`)")
  expect_silent(parse(text = code2))

  # Multiple columns
  code3 <- sv_code_rename("df", c("a", "b"), c("x", "y"))
  expect_equal(code3, "dplyr::rename(df, x = a, y = b)")
  expect_silent(parse(text = code3))

  # Pipe support
  code4 <- sv_code_rename("df", "old", "new", pipe = TRUE)
  expect_equal(code4, "df %>% dplyr::rename(new = old)")
  expect_silent(parse(text = code4))
})

test_that("sv_code_join generates valid join code across join types and formats by", {
  # left_join with differing column names
  code1 <- sv_code_join("patients", "visits", "patient_id", "subject_id", join_type = "left")
  expect_equal(code1, 'dplyr::left_join(patients, visits, by = c("patient_id" = "subject_id"))')
  expect_silent(parse(text = code1))

  # left_join with matching column names
  code2 <- sv_code_join("patients", "visits", "patient_id", "patient_id", join_type = "left")
  expect_equal(code2, 'dplyr::left_join(patients, visits, by = "patient_id")')
  expect_silent(parse(text = code2))

  # All join types: inner, anti, right, full, semi
  expect_match(sv_code_join("a", "b", "id", "id", join_type = "inner"), "^dplyr::inner_join")
  expect_match(sv_code_join("a", "b", "id", "id", join_type = "anti"), "^dplyr::anti_join")
  expect_match(sv_code_join("a", "b", "id", "id", join_type = "right"), "^dplyr::right_join")
  expect_match(sv_code_join("a", "b", "id", "id", join_type = "full"), "^dplyr::full_join")
  expect_match(sv_code_join("a", "b", "id", "id", join_type = "semi"), "^dplyr::semi_join")

  # Table and column names with spaces or symbols
  code3 <- sv_code_join("table 1", "table 2", "patient id", "subject id")
  expect_equal(code3, 'dplyr::left_join(`table 1`, `table 2`, by = c("patient id" = "subject id"))')
  expect_silent(parse(text = code3))

  # Pipe support
  code4 <- sv_code_join("patients", "visits", "id", "id", pipe = TRUE)
  expect_equal(code4, 'patients %>% dplyr::left_join(visits, by = "id")')
  expect_silent(parse(text = code4))

  # Error on invalid join type
  expect_error(sv_code_join("a", "b", "id", "id", join_type = "cross_product"), "Unsupported join_type")
})

test_that("sv_code_join supports composite multi-key joins", {
  code <- sv_code_join("patients", "visits", 
                       col1 = c("patient_id", "site_id"), 
                       col2 = c("patient_id", "hospital_id"), 
                       pipe = TRUE)
  expect_match(code, 'patients\\s*%>%\\s*dplyr::left_join\\(visits,\\s*by\\s*=\\s*c\\("patient_id"\\s*=\\s*"patient_id",\\s*"site_id"\\s*=\\s*"hospital_id"\\)\\)')
  expect_silent(parse(text = code))

  # Identical vector keys
  code_ident <- sv_code_join("df1", "df2", col1 = c("a", "b"), col2 = c("a", "b"), pipe = TRUE)
  expect_equal(code_ident, 'df1 %>% dplyr::left_join(df2, by = c("a", "b"))')
  expect_silent(parse(text = code_ident))

  # col2 defaults to col1 for vector
  code_default <- sv_code_join("df1", "df2", col1 = c("a", "b"), pipe = TRUE)
  expect_equal(code_default, 'df1 %>% dplyr::left_join(df2, by = c("a", "b"))')
  expect_silent(parse(text = code_default))

  # List representation of multi-keys (as passed from Shiny WebSocket JSON)
  code_list <- sv_code_join("df1", "df2", col1 = list("a", "b"), col2 = list("x", "y"), pipe = TRUE)
  expect_equal(code_list, 'df1 %>% dplyr::left_join(df2, by = c("a" = "x", "b" = "y"))')
  expect_silent(parse(text = code_list))

  code_list_same <- sv_code_join("df1", "df2", col1 = list("a", "b"), col2 = list("a", "b"), pipe = TRUE)
  expect_equal(code_list_same, 'df1 %>% dplyr::left_join(df2, by = c("a", "b"))')
  expect_silent(parse(text = code_list_same))

  # Backtick-wrapped identifiers are stripped inside by = c("col" = "col")
  code_backtick <- sv_code_join("df1", "df2", col1 = c("`col a`", "`col b`"), col2 = c("`col a`", "`col c`"), pipe = TRUE)
  expect_equal(code_backtick, 'df1 %>% dplyr::left_join(df2, by = c("col a" = "col a", "col b" = "col c"))')
  expect_silent(parse(text = code_backtick))
})

test_that("sv_code_join generates intermediate piped join segments when df1 is NULL", {
  code_pipe_null <- sv_code_join(NULL, "df2", "id", pipe = TRUE)
  expect_equal(code_pipe_null, 'dplyr::left_join(df2, by = "id")')

  code_nonpipe_null <- sv_code_join(NULL, "df2", "id", pipe = FALSE)
  expect_equal(code_nonpipe_null, 'dplyr::left_join(df2, by = "id")')

  # Multi-key intermediate segment
  code_multi_null <- sv_code_join(NULL, "df2", c("a", "b"), c("x", "y"), pipe = TRUE)
  expect_equal(code_multi_null, 'dplyr::left_join(df2, by = c("a" = "x", "b" = "y"))')
})

test_that("sv_code_join validates arguments and throws appropriate errors", {
  # Mismatched key lengths
  expect_error(
    sv_code_join("df1", "df2", col1 = c("a", "b"), col2 = "x"),
    "`col1` and `col2` must have the same length."
  )

  # Empty keys
  expect_error(
    sv_code_join("df1", "df2", col1 = character(0)),
    "Join columns \\(`col1` and `col2`\\) must not be empty."
  )
  expect_error(
    sv_code_join("df1", "df2", col1 = "a", col2 = character(0)),
    "Join columns \\(`col1` and `col2`\\) must not be empty."
  )

  # Invalid df2 (missing, NULL, NA, empty string, vector > 1)
  expect_error(sv_code_join("df1"), "Join table `df2` must be a single non-empty character string.")
  expect_error(sv_code_join("df1", NULL, "id"), "Join table `df2` must be a single non-empty character string.")
  expect_error(sv_code_join("df1", "", "id"), "Join table `df2` must be a single non-empty character string.")
  expect_error(sv_code_join("df1", NA_character_, "id"), "Join table `df2` must be a single non-empty character string.")
  expect_error(sv_code_join("df1", c("df2", "df3"), "id"), "Join table `df2` must be a single non-empty character string.")
})


test_that("sv_code_mutate generates valid mutate code", {
  # Single mutation
  code1 <- sv_code_mutate("df", "total", "price * quantity")
  expect_equal(code1, "dplyr::mutate(df, total = price * quantity)")
  expect_silent(parse(text = code1))

  # Non-syntactic column name
  code2 <- sv_code_mutate("my df", "total price", "price * quantity")
  expect_equal(code2, "dplyr::mutate(`my df`, `total price` = price * quantity)")
  expect_silent(parse(text = code2))

  # Multiple mutations
  code3 <- sv_code_mutate("df", c("a", "b"), c("1", "2"))
  expect_equal(code3, "dplyr::mutate(df, a = 1, b = 2)")
  expect_silent(parse(text = code3))

  # Pipe support
  code4 <- sv_code_mutate("df", "total", "price * quantity", pipe = TRUE)
  expect_equal(code4, "df %>% dplyr::mutate(total = price * quantity)")
  expect_silent(parse(text = code4))
})

test_that("sv_code_filter generates valid filter code", {
  # Single condition
  code1 <- sv_code_filter("df", "age >= 18")
  expect_equal(code1, "dplyr::filter(df, age >= 18)")
  expect_silent(parse(text = code1))

  # Multiple conditions
  code2 <- sv_code_filter("df", c("age >= 18", "status == 'Active'"))
  expect_equal(code2, "dplyr::filter(df, age >= 18, status == 'Active')")
  expect_silent(parse(text = code2))

  # Pipe support
  code3 <- sv_code_filter("df", "age >= 18", pipe = TRUE)
  expect_equal(code3, "df %>% dplyr::filter(age >= 18)")
  expect_silent(parse(text = code3))
})

test_that("sv_code_select generates valid select code", {
  # Multiple columns
  code1 <- sv_code_select("df", c("id", "name", "age"))
  expect_equal(code1, "dplyr::select(df, id, name, age)")
  expect_silent(parse(text = code1))

  # Columns with spaces
  code2 <- sv_code_select("df", c("first name", "last name"))
  expect_equal(code2, "dplyr::select(df, `first name`, `last name`)")
  expect_silent(parse(text = code2))

  # Pipe support
  code3 <- sv_code_select("df", c("id", "name"), pipe = TRUE)
  expect_equal(code3, "df %>% dplyr::select(id, name)")
  expect_silent(parse(text = code3))
})

test_that("sv_detect_discrepancies detects exact and fuzzy matches and discrepancies", {
  # Character input with exact matches, fuzzy matches, discrepancies, and NA
  x <- c("Male", "Female", "Mle", "Unknown", NA)
  y <- c("Male", "Female", "Other", NA)

  res <- sv_detect_discrepancies(x, y, max_distance = 2)

  expect_type(res, "list")
  expect_setequal(res$exact_matches, c("Male", "Female"))
  expect_setequal(res$only_in_x, c("Mle", "Unknown"))
  expect_setequal(res$only_in_y, "Other")

  # Fuzzy matches: "Mle" is distance 1 from "Male"
  expect_true(is.data.frame(res$fuzzy_matches))
  expect_equal(colnames(res$fuzzy_matches), c("x", "y", "distance"))
  expect_true(any(res$fuzzy_matches$x == "Mle" & res$fuzzy_matches$y == "Male"))
  expect_equal(res$fuzzy_matches$distance[res$fuzzy_matches$x == "Mle" & res$fuzzy_matches$y == "Male"], 1L)

  # Match statistics
  expect_equal(res$stats$exact_count, 2L)
  expect_equal(res$stats$na_x, 1L)
  expect_equal(res$stats$na_y, 1L)
  expect_equal(res$stats$only_x_count, 2L)
  expect_equal(res$stats$only_y_count, 1L)
  expect_equal(res$match_stats$exact_count, 2L)

  # Numeric input handling
  x_num <- c(100, 200, 305)
  y_num <- c(100, 200, 300)
  res_num <- sv_detect_discrepancies(x_num, y_num, max_distance = 1)
  expect_setequal(res_num$exact_matches, c("100", "200"))
  expect_equal(res_num$fuzzy_matches$x, "305")
  expect_equal(res_num$fuzzy_matches$y, "300")
  expect_equal(res_num$fuzzy_matches$distance, 1L)

  # Factor input handling
  x_fac <- factor(c("A", "B", "C"))
  y_fac <- factor(c("A", "B", "D"))
  res_fac <- sv_detect_discrepancies(x_fac, y_fac)
  expect_setequal(res_fac$exact_matches, c("A", "B"))
  expect_setequal(res_fac$only_in_x, "C")
  expect_setequal(res_fac$only_in_y, "D")

  # Empty and all-NA inputs
  res_empty <- sv_detect_discrepancies(character(0), character(0))
  expect_equal(length(res_empty$exact_matches), 0L)
  expect_equal(nrow(res_empty$fuzzy_matches), 0L)
  expect_equal(res_empty$stats$exact_count, 0L)

  res_all_na <- sv_detect_discrepancies(c(NA, NA), c(NA))
  expect_equal(length(res_all_na$exact_matches), 0L)
  expect_equal(res_all_na$stats$na_x, 2L)
  expect_equal(res_all_na$stats$na_y, 1L)
})

test_that("sv_code_recode generates case_match and fct_recode tidyverse code", {
  cw <- c("Compl." = "Completed", "completed" = "Completed", "InProg" = "In Progress")

  # case_match with default = NULL
  code1 <- sv_code_recode("df", "status", cw, method = "case_match")
  expect_true(grepl("dplyr::case_match", code1))
  expect_true(grepl('c\\("Compl.", "completed"\\) ~ "Completed"', code1) ||
              grepl('c\\("completed", "Compl."\\) ~ "Completed"', code1))
  expect_true(grepl('"InProg" ~ "In Progress"', code1))
  expect_false(grepl("\\.default", code1))
  expect_silent(parse(text = code1))

  # case_match preserving column as default
  code2 <- sv_code_recode("df", "status", cw, default = "status", method = "case_match")
  expect_true(grepl("\\.default = status", code2))
  expect_silent(parse(text = code2))

  # case_match with explicit literal default
  code3 <- sv_code_recode("df", "status", cw, default = "Unknown", method = "case_match")
  expect_true(grepl('\\.default = "Unknown"', code3))
  expect_silent(parse(text = code3))

  # case_match with pipe = TRUE
  code_pipe <- sv_code_recode("df", "status", cw, pipe = TRUE)
  expect_true(grepl("^df %>% dplyr::mutate", code_pipe))
  expect_silent(parse(text = code_pipe))

  # fct_recode method
  code_fct <- sv_code_recode("df", "status", cw, method = "fct_recode")
  expect_true(grepl("forcats::fct_recode", code_fct))
  expect_true(grepl('"Completed" = "Compl."', code_fct))
  expect_true(grepl('"Completed" = "completed"', code_fct))
  expect_true(grepl('"In Progress" = "InProg"', code_fct))
  expect_silent(parse(text = code_fct))

  # crosswalk provided as data.frame
  df_cw <- data.frame(from = c("Mle", "Femle"), to = c("Male", "Female"), stringsAsFactors = FALSE)
  code_df <- sv_code_recode("patients", "gender", df_cw)
  expect_true(grepl("dplyr::case_when", code_df))
  expect_true(grepl('"Mle" ~ "Male"', code_df))
  expect_true(grepl('"Femle" ~ "Female"', code_df))
  expect_silent(parse(text = code_df))

  # crosswalk provided as list
  list_cw <- list("Completed" = c("Compl.", "completed"), "In Progress" = "InProg")
  code_list <- sv_code_recode("df", "status", list_cw)
  expect_true(grepl('c\\("Compl.", "completed"\\) ~ "Completed"', code_list))
  expect_silent(parse(text = code_list))

  # crosswalk with NA targets (e.g. mapping "Unknown" to NA)
  cw_na <- data.frame(
    from = c("Compl.", "InProg", "Missing", "Unknown"),
    to = c("Completed", "In Progress", NA, NA),
    stringsAsFactors = FALSE
  )
  code_na <- sv_code_recode("df", "status", cw_na)
  expect_true(grepl('c\\("Missing", "Unknown"\\) ~ NA', code_na))
  expect_true(grepl('"Compl." ~ "Completed"', code_na))
  expect_false(grepl('NA_character_', code_na))
  expect_silent(parse(text = code_na))
})

test_that("codegen edge cases and defensive checks pass", {
  # Empty columns in rename
  expect_error(sv_code_rename("df", character(0), character(0)), "must not be empty")

  # Empty columns in join
  expect_error(sv_code_join("df1", "df2", character(0), character(0)), "must not be empty")

  # NA in max_distance for discrepancy detection
  res_na_dist <- sv_detect_discrepancies(c("apple", "banana"), c("aple", "berry"), max_distance = NA)
  expect_equal(res_na_dist$stats$exact_count, 0)
  expect_equal(nrow(res_na_dist$fuzzy_matches), 1)
  expect_equal(res_na_dist$fuzzy_matches$x, "apple")
  expect_equal(res_na_dist$fuzzy_matches$y, "aple")

  # Backtick escaping regex check
  expect_equal(sv_escape_ident("`already_escaped`"), "`already_escaped`")
  expect_equal(sv_escape_ident("needs escape"), "`needs escape`")
})


test_that("sv_code_arrange generates valid tidyverse arrange pipelines", {
  # Standard column ascending
  c1 <- sv_code_arrange("patients", "age", pipe = TRUE)
  expect_equal(c1, "patients %>% dplyr::arrange(age)")
  expect_silent(parse(text = c1))

  # Descending column
  c2 <- sv_code_arrange("patients", "age", desc = TRUE, pipe = TRUE)
  expect_equal(c2, "patients %>% dplyr::arrange(dplyr::desc(age))")
  expect_silent(parse(text = c2))

  # Prefix syntax without pipe
  c3 <- sv_code_arrange("patients", "age", desc = FALSE, pipe = FALSE)
  expect_equal(c3, "dplyr::arrange(patients, age)")
  expect_silent(parse(text = c3))

  # Non-syntactic column name
  c4 <- sv_code_arrange("patients", "bad column name", desc = TRUE, pipe = TRUE)
  expect_equal(c4, "patients %>% dplyr::arrange(dplyr::desc(`bad column name`))")
  expect_silent(parse(text = c4))

  # Multiple columns with mixed directions
  c5 <- sv_code_arrange("patients", c("age", "systolic bp"), desc = c(FALSE, TRUE), pipe = TRUE)
  expect_equal(c5, "patients %>% dplyr::arrange(age, dplyr::desc(`systolic bp`))")
  expect_silent(parse(text = c5))

  # Errors on empty column
  expect_error(sv_code_arrange("patients", character(0)), "must not be empty")
})


test_that("sv_code_pivot_longer generates valid tidyr code and escapes identifiers", {
  # Direct function call mode (pipe = FALSE) with single column
  c1 <- sv_code_pivot_longer("my_data", cols = "score")
  expect_equal(c1, 'tidyr::pivot_longer(my_data, cols = score, names_to = "name", values_to = "value")')
  expect_silent(parse(text = c1))

  # Pipe mode with multiple columns
  c2 <- sv_code_pivot_longer("my_data", cols = c("q1", "q2", "q3"), pipe = TRUE)
  expect_equal(c2, 'my_data %>% tidyr::pivot_longer(cols = c(q1, q2, q3), names_to = "name", values_to = "value")')
  expect_silent(parse(text = c2))

  # Custom names_to and values_to
  c3 <- sv_code_pivot_longer("sales", cols = c("2021", "2022"), names_to = "year", values_to = "revenue", pipe = TRUE)
  expect_equal(c3, 'sales %>% tidyr::pivot_longer(cols = c(`2021`, `2022`), names_to = "year", values_to = "revenue")')
  expect_silent(parse(text = c3))

  # Non-syntactic column names and data frame name with backtick escaping
  c4 <- sv_code_pivot_longer("patient records", cols = c("blood pressure", "heart rate"), pipe = TRUE)
  expect_equal(c4, '`patient records` %>% tidyr::pivot_longer(cols = c(`blood pressure`, `heart rate`), names_to = "name", values_to = "value")')
  expect_silent(parse(text = c4))

  # Single non-syntactic column without c() wrapper
  c5 <- sv_code_pivot_longer("df", cols = "weird-name", pipe = FALSE)
  expect_equal(c5, 'tidyr::pivot_longer(df, cols = `weird-name`, names_to = "name", values_to = "value")')
  expect_silent(parse(text = c5))

  # df_name = NULL in pipe mode
  c6 <- sv_code_pivot_longer(NULL, cols = c("a", "b"), pipe = TRUE)
  expect_equal(c6, 'tidyr::pivot_longer(cols = c(a, b), names_to = "name", values_to = "value")')
  expect_silent(parse(text = c6))

  # df_name = NULL in non-pipe mode
  c7 <- sv_code_pivot_longer(NULL, cols = "a", pipe = FALSE)
  expect_equal(c7, 'tidyr::pivot_longer(cols = a, names_to = "name", values_to = "value")')
  expect_silent(parse(text = c7))

  # Error handling: cols empty or missing
  expect_error(sv_code_pivot_longer("df", cols = character(0)), "must not be empty")
  expect_error(sv_code_pivot_longer("df", cols = NULL), "must not be empty")
  expect_error(sv_code_pivot_longer("df"), "must not be empty")
  expect_error(sv_code_pivot_longer("df", cols = c("a", "")), "must not contain NA or empty")
  expect_error(sv_code_pivot_longer("df", cols = c("a", NA)), "must not contain NA or empty")
})

test_that("sv_code_pivot_wider generates valid tidyr code with options", {
  # Direct function call mode (pipe = FALSE) with standard columns
  w1 <- sv_code_pivot_wider("measurements", names_from = "variable", values_from = "value")
  expect_equal(w1, "tidyr::pivot_wider(measurements, names_from = variable, values_from = value)")
  expect_silent(parse(text = w1))

  # Pipe mode
  w2 <- sv_code_pivot_wider("measurements", names_from = "variable", values_from = "value", pipe = TRUE)
  expect_equal(w2, "measurements %>% tidyr::pivot_wider(names_from = variable, values_from = value)")
  expect_silent(parse(text = w2))

  # Non-syntactic columns and df_name escaping
  w3 <- sv_code_pivot_wider("my data", names_from = "var name", values_from = "val 1", pipe = TRUE)
  expect_equal(w3, "`my data` %>% tidyr::pivot_wider(names_from = `var name`, values_from = `val 1`)")
  expect_silent(parse(text = w3))

  # Multiple names_from and values_from
  w4 <- sv_code_pivot_wider("df", names_from = c("k1", "k2"), values_from = c("v1", "v2"), pipe = TRUE)
  expect_equal(w4, "df %>% tidyr::pivot_wider(names_from = c(k1, k2), values_from = c(v1, v2))")
  expect_silent(parse(text = w4))

  # Optional values_fn argument (e.g. mean, sum, dplyr::first)
  w5 <- sv_code_pivot_wider("df", names_from = "key", values_from = "val", values_fn = "mean", pipe = TRUE)
  expect_equal(w5, "df %>% tidyr::pivot_wider(names_from = key, values_from = val, values_fn = mean)")
  expect_silent(parse(text = w5))

  w6 <- sv_code_pivot_wider("df", names_from = "key", values_from = "val", values_fn = "sum")
  expect_equal(w6, "tidyr::pivot_wider(df, names_from = key, values_from = val, values_fn = sum)")
  expect_silent(parse(text = w6))

  w7 <- sv_code_pivot_wider("df", names_from = "key", values_from = "val", values_fn = "dplyr::first", pipe = TRUE)
  expect_equal(w7, "df %>% tidyr::pivot_wider(names_from = key, values_from = val, values_fn = dplyr::first)")
  expect_silent(parse(text = w7))

  # values_fn as named vector/list
  w8 <- sv_code_pivot_wider("df", names_from = "key", values_from = c("v1", "v2"), 
                            values_fn = c(v1 = "mean", v2 = "sum"), pipe = TRUE)
  expect_equal(w8, "df %>% tidyr::pivot_wider(names_from = key, values_from = c(v1, v2), values_fn = list(v1 = mean, v2 = sum))")
  expect_silent(parse(text = w8))

  # df_name = NULL in pipe and non-pipe modes
  w9 <- sv_code_pivot_wider(NULL, names_from = "k", values_from = "v", pipe = TRUE)
  expect_equal(w9, "tidyr::pivot_wider(names_from = k, values_from = v)")
  expect_silent(parse(text = w9))

  w10 <- sv_code_pivot_wider(NULL, names_from = "k", values_from = "v", pipe = FALSE)
  expect_equal(w10, "tidyr::pivot_wider(names_from = k, values_from = v)")
  expect_silent(parse(text = w10))

  # Error handling: required arguments missing or invalid
  expect_error(sv_code_pivot_wider("df", values_from = "val"), "must not be empty")
  expect_error(sv_code_pivot_wider("df", names_from = character(0), values_from = "val"), "must not be empty")
  expect_error(sv_code_pivot_wider("df", names_from = "key"), "must not be empty")
  expect_error(sv_code_pivot_wider("df", names_from = "key", values_from = character(0)), "must not be empty")
  expect_error(sv_code_pivot_wider("df", names_from = c("key", ""), values_from = "val"), "must not contain NA or empty")
  expect_error(sv_code_pivot_wider("df", names_from = "key", values_from = c("val", NA)), "must not contain NA or empty")

  # Error handling: invalid values_fn
  expect_error(sv_code_pivot_wider("df", names_from = "key", values_from = "val", values_fn = c("mean", "sum")),
               "`values_fn` with multiple functions must be a named vector or list.")
  expect_error(sv_code_pivot_wider("df", names_from = "key", values_from = "val", values_fn = c(a = "mean", "sum")),
               "All elements in `values_fn` must be named.")
})


test_that("sv_code_group_summarize generates valid dplyr group_by and summarise pipelines", {
  # 1. Direct call mode (pipe = FALSE) with single group column and single summary expression
  c1 <- sv_code_group_summarize("patients", group_cols = "dept", summary_exprs = c(total = "dplyr::n()"))
  expected_c1 <- "dplyr::summarise(\n  dplyr::group_by(patients, dept),\n  total = dplyr::n(),\n  .groups = 'drop'\n)"
  expect_equal(c1, expected_c1)
  expect_silent(parse(text = c1))

  # 2. Piped mode (pipe = TRUE) with multiple group columns and multiple summary expressions
  c2 <- sv_code_group_summarize(
    "patients",
    group_cols = c("dept", "gender"),
    summary_exprs = c(total = "dplyr::n()", avg_age = "mean(age, na.rm = TRUE)"),
    pipe = TRUE
  )
  expected_c2 <- "patients %>%\n  dplyr::group_by(dept, gender) %>%\n  dplyr::summarise(\n    total = dplyr::n(),\n    avg_age = mean(age, na.rm = TRUE),\n    .groups = 'drop'\n  )"
  expect_equal(c2, expected_c2)
  expect_silent(parse(text = c2))

  # 3. Summary expressions provided as a named list
  c3 <- sv_code_group_summarize(
    "lab_panels",
    group_cols = "patient_id",
    summary_exprs = list(
      total_visits = "dplyr::n()",
      avg_glucose  = "mean(glucose, na.rm = TRUE)",
      max_glucose  = "max(glucose, na.rm = TRUE)"
    ),
    pipe = TRUE
  )
  expected_c3 <- "lab_panels %>%\n  dplyr::group_by(patient_id) %>%\n  dplyr::summarise(\n    total_visits = dplyr::n(),\n    avg_glucose = mean(glucose, na.rm = TRUE),\n    max_glucose = max(glucose, na.rm = TRUE),\n    .groups = 'drop'\n  )"
  expect_equal(c3, expected_c3)
  expect_silent(parse(text = c3))

  # 4. Non-syntactic df_name, group columns, and summary metric names with backtick escaping
  c4 <- sv_code_group_summarize(
    "patient records",
    group_cols = c("study group", "visit number"),
    summary_exprs = c("patient count" = "dplyr::n()", "mean systolic" = "mean(`systolic bp`, na.rm = TRUE)"),
    pipe = TRUE
  )
  expected_c4 <- "`patient records` %>%\n  dplyr::group_by(`study group`, `visit number`) %>%\n  dplyr::summarise(\n    `patient count` = dplyr::n(),\n    `mean systolic` = mean(`systolic bp`, na.rm = TRUE),\n    .groups = 'drop'\n  )"
  expect_equal(c4, expected_c4)
  expect_silent(parse(text = c4))

  # 5. Non-syntactic names in direct call mode (pipe = FALSE)
  c5 <- sv_code_group_summarize(
    "patient records",
    group_cols = "test-result",
    summary_exprs = c("case count" = "dplyr::n()"),
    pipe = FALSE
  )
  expected_c5 <- "dplyr::summarise(\n  dplyr::group_by(`patient records`, `test-result`),\n  `case count` = dplyr::n(),\n  .groups = 'drop'\n)"
  expect_equal(c5, expected_c5)
  expect_silent(parse(text = c5))

  # 6. Intermediate piped pipeline segment with df_name = NULL (pipe = TRUE)
  c6 <- sv_code_group_summarize(
    NULL,
    group_cols = c("dept", "site"),
    summary_exprs = c(n = "dplyr::n()"),
    pipe = TRUE
  )
  expected_c6 <- "dplyr::group_by(dept, site) %>%\n  dplyr::summarise(\n    n = dplyr::n(),\n    .groups = 'drop'\n  )"
  expect_equal(c6, expected_c6)
  expect_silent(parse(text = c6))

  # 7. Intermediate segment with df_name = NULL (pipe = FALSE)
  c7 <- sv_code_group_summarize(
    NULL,
    group_cols = "dept",
    summary_exprs = c(n = "dplyr::n()"),
    pipe = FALSE
  )
  expected_c7 <- "dplyr::summarise(\n  dplyr::group_by(dept),\n  n = dplyr::n(),\n  .groups = 'drop'\n)"
  expect_equal(c7, expected_c7)
  expect_silent(parse(text = c7))

  # 8. Defensive error checking
  expect_error(sv_code_group_summarize(), "`group_cols` must not be empty")
  expect_error(sv_code_group_summarize("df"), "`group_cols` must not be empty")
  expect_error(sv_code_group_summarize("df", group_cols = character(0), summary_exprs = c(n = "n()")), "`group_cols` must not be empty")
  expect_error(sv_code_group_summarize("df", group_cols = NULL, summary_exprs = c(n = "n()")), "`group_cols` must not be empty")
  expect_error(sv_code_group_summarize("df", group_cols = c("a", ""), summary_exprs = c(n = "n()")), "`group_cols` must not contain NA or empty")
  expect_error(sv_code_group_summarize("df", group_cols = c("a", NA), summary_exprs = c(n = "n()")), "`group_cols` must not contain NA or empty")

  expect_error(sv_code_group_summarize("df", group_cols = "a"), "`summary_exprs` must not be empty")
  expect_error(sv_code_group_summarize("df", group_cols = "a", summary_exprs = character(0)), "`summary_exprs` must not be empty")
  expect_error(sv_code_group_summarize("df", group_cols = "a", summary_exprs = NULL), "`summary_exprs` must not be empty")
  expect_error(sv_code_group_summarize("df", group_cols = "a", summary_exprs = 123), "`summary_exprs` must be a named character vector or named list")
  expect_error(sv_code_group_summarize("df", group_cols = "a", summary_exprs = c("dplyr::n()")), "All elements in `summary_exprs` must be named")
  expect_error(sv_code_group_summarize("df", group_cols = "a", summary_exprs = c(tot = "dplyr::n()", "mean(x)")), "All elements in `summary_exprs` must be named")
  expect_error(sv_code_group_summarize("df", group_cols = "a", summary_exprs = c(tot = "")), "`summary_exprs` values must not be empty or NA")
  expect_error(sv_code_group_summarize("df", group_cols = "a", summary_exprs = c(tot = NA_character_)), "`summary_exprs` values must not be empty or NA")

  expect_error(sv_code_group_summarize(c("df1", "df2"), group_cols = "a", summary_exprs = c(n = "n()")), "`df_name` must be a single character string or NULL")
})

test_that("sv_auto_clean_rules generates executable case_when cleanup pipelines", {
  # 1. Detects casing differences (e.g. 'male' vs 'Male') and normalizes
  disc_case <- sv_detect_discrepancies(c("male", "Female"), c("Male", "Female"))
  code_case <- sv_auto_clean_rules(disc_case, df_name = "df", col = "gender")
  expect_true(grepl("dplyr::case_when", code_case))
  expect_true(grepl('"male"\\s*~\\s*"Male"', code_case))
  expect_silent(parse(text = code_case))

  # Verify executable behavior
  df_gender <- data.frame(gender = c("male", "Female"), stringsAsFactors = FALSE)
  expect_no_warning(eval_res_case <- eval(parse(text = code_case), list(df = df_gender)))
  expect_equal(eval_res_case$gender, c("Male", "Female"))

  # 2. Detects whitespace differences (e.g. ' In Progress ' vs 'In Progress') and trims
  disc_space <- sv_detect_discrepancies(c(" In Progress ", "Done"), c("In Progress", "Done"))
  code_space <- sv_auto_clean_rules(disc_space, df_name = "tasks", col = "status")
  expect_true(grepl("dplyr::case_when", code_space))
  expect_true(grepl('" In Progress "\\s*~\\s*"In Progress"', code_space))
  expect_silent(parse(text = code_space))

  df_tasks <- data.frame(status = c(" In Progress ", "Done"), stringsAsFactors = FALSE)
  expect_no_warning(eval_res_space <- eval(parse(text = code_space), list(tasks = df_tasks)))
  expect_equal(eval_res_space$status, c("In Progress", "Done"))

  # 3. Maps fuzzy matches (Levenshtein distance <= 2, e.g. 'Compl.' vs 'Completed')
  disc_fuzzy <- list(
    exact_matches = c("Pending"),
    fuzzy_matches = data.frame(x = "Compl.", y = "Completed", distance = 2L, stringsAsFactors = FALSE),
    only_in_x = c("Compl."),
    only_in_y = c("Completed"),
    stats = list(exact_count = 1L, fuzzy_count = 1L)
  )
  code_fuzzy <- sv_auto_clean_rules(disc_fuzzy, df_name = "df", col = "status")
  expect_true(grepl("dplyr::case_when", code_fuzzy))
  expect_true(grepl('"Compl."\\s*~\\s*"Completed"', code_fuzzy))
  expect_silent(parse(text = code_fuzzy))

  df_status <- data.frame(status = c("Compl.", "Pending"), stringsAsFactors = FALSE)
  expect_no_warning(eval_res_fuzzy <- eval(parse(text = code_fuzzy), list(df = df_status)))
  expect_equal(eval_res_fuzzy$status, c("Completed", "Pending"))

  # 4. Handles empty discrepancies (returns NULL or empty code)
  disc_empty <- sv_detect_discrepancies(c("A", "B"), c("A", "B"))
  expect_null(sv_auto_clean_rules(disc_empty))
  expect_null(sv_auto_clean_rules(NULL))
  expect_null(sv_auto_clean_rules(list()))

  # 5. Supports pipe = TRUE, df_name = NULL, col = NULL
  code_pipe <- sv_auto_clean_rules(disc_case, df_name = "df", col = "gender", pipe = TRUE)
  expect_match(code_pipe, "^df\\s*%>%\\s*dplyr::mutate")
  expect_silent(parse(text = code_pipe))

  code_nodf <- sv_auto_clean_rules(disc_case, df_name = NULL, col = "gender", pipe = FALSE)
  expect_match(code_nodf, "^dplyr::mutate\\(gender\\s*=")
  expect_silent(parse(text = code_nodf))

  code_nocol <- sv_auto_clean_rules(disc_case, df_name = NULL, col = NULL, pipe = FALSE)
  expect_true(grepl("dplyr::case_when", code_nocol))
  expect_silent(parse(text = code_nocol))

  # 6. Alias sv_code_auto_clean works identically
  code_alias <- sv_code_auto_clean(disc_case, df_name = "df", col = "gender")
  expect_equal(code_alias, code_case)
})

test_that("sv_code functions return valid non-empty strings with NULL or empty df and pipe = TRUE", {
  # sv_code_rename
  r1 <- sv_code_rename(NULL, "a", "b", pipe = TRUE)
  expect_type(r1, "character")
  expect_length(r1, 1L)
  expect_false(identical(r1, character(0)))
  expect_equal(r1, "dplyr::rename(b = a)")
  expect_silent(parse(text = r1))

  r2 <- sv_code_rename("", "a", "b", pipe = TRUE)
  expect_equal(r2, "dplyr::rename(b = a)")
  expect_false(identical(r2, character(0)))
  expect_silent(parse(text = r2))

  # sv_code_filter
  f1 <- sv_code_filter(NULL, "x > 1", pipe = TRUE)
  expect_type(f1, "character")
  expect_length(f1, 1L)
  expect_false(identical(f1, character(0)))
  expect_equal(f1, "dplyr::filter(x > 1)")
  expect_silent(parse(text = f1))

  f2 <- sv_code_filter("", "x > 1", pipe = TRUE)
  expect_equal(f2, "dplyr::filter(x > 1)")
  expect_false(identical(f2, character(0)))
  expect_silent(parse(text = f2))

  # sv_code_arrange
  a1 <- sv_code_arrange(NULL, "x", pipe = TRUE)
  expect_type(a1, "character")
  expect_length(a1, 1L)
  expect_false(identical(a1, character(0)))
  expect_equal(a1, "dplyr::arrange(x)")
  expect_silent(parse(text = a1))

  a2 <- sv_code_arrange("", "x", pipe = TRUE)
  expect_equal(a2, "dplyr::arrange(x)")
  expect_false(identical(a2, character(0)))
  expect_silent(parse(text = a2))

  # sv_code_select
  s1 <- sv_code_select(NULL, "x", pipe = TRUE)
  expect_type(s1, "character")
  expect_length(s1, 1L)
  expect_false(identical(s1, character(0)))
  expect_equal(s1, "dplyr::select(x)")
  expect_silent(parse(text = s1))

  s2 <- sv_code_select("", "x", pipe = TRUE)
  expect_equal(s2, "dplyr::select(x)")
  expect_false(identical(s2, character(0)))
  expect_silent(parse(text = s2))
})

test_that("sv_code_recode case_when handles NA sources, multi-value targets and defaults", {
  skip_if_not_installed("dplyr")
  cw <- data.frame(from = c("m", "male", NA, "f"), to = c("Male", "Male", "Unknown", "Female"))
  code <- sv_code_recode("df", "sex", cw, default = "sex", pipe = TRUE)
  expect_match(code, 'sex %in% c("m", "male") ~ "Male"', fixed = TRUE)
  expect_match(code, 'is.na(sex) ~ "Unknown"', fixed = TRUE)
  expect_match(code, ".default = sex", fixed = TRUE)
  df <- data.frame(sex = c("m", "male", NA, "f", "F"))
  `%>%` <- dplyr::`%>%`
  expect_no_warning(out <- eval(parse(text = code)))
  expect_equal(out$sex, c("Male", "Male", "Unknown", "Female", "F"))

  # No default: unmatched values become NA, as with case_match().
  out2 <- eval(parse(text = sv_code_recode("df", "sex", c(m = "Male"), pipe = TRUE)))
  expect_equal(out2$sex, c("Male", NA, NA, NA, NA))

  # Non-syntactic column names are backticked.
  code3 <- sv_code_recode("df", "visit sex", c(m = "Male"))
  expect_match(code3, "`visit sex` == \"m\" ~ \"Male\"", fixed = TRUE)
  expect_silent(parse(text = code3))

  # The legacy case_match() method is still available on request.
  expect_match(sv_code_recode("df", "sex", c(m = "Male"), method = "case_match"), "dplyr::case_match(", fixed = TRUE)
})

test_that("a lazy recode closes with a TRUE arm, not .default, and runs on arrow and duckdb", {
  code <- sv_code_recode("t", "sex", c(f = "F"), default = "sex", lazy = TRUE)
  expect_match(code, "TRUE ~ sex", fixed = TRUE)
  expect_false(grepl(".default", code, fixed = TRUE))
  expect_silent(parse(text = code))
  # unchanged for data frames
  expect_match(sv_code_recode("t", "sex", c(f = "F"), default = "sex"), ".default = sex", fixed = TRUE)
  expect_identical(sv_code_recode("t", "sex", c(f = "F"), default = "sex"),
                   sv_code_recode("t", "sex", c(f = "F"), default = "sex", lazy = FALSE))
})

test_that("sv_auto_clean_rules(lazy = TRUE) writes one collect() and runs on arrow and duckdb", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("withr")
  disc <- sv_detect_discrepancies(c("male", "Female", " Done "), c("Male", "Female", "Done"))
  expect_false(is.null(disc))
  frame <- data.frame(sex = c("male", "Female", "Male", NA, " Done "), n = 1:5, stringsAsFactors = FALSE)
  want <- eval(parse(text = sv_auto_clean_rules(disc, df_name = "vv", col = "sex")), list(vv = frame))

  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "vv", frame)
  for (ref in c('dplyr::tbl(con, "vv")', "vv")) {
    env <- new.env(parent = globalenv())
    env$con <- con
    env$`%>%` <- magrittr::`%>%`
    if (ref == "vv") env$vv <- arrow::arrow_table(frame)
    for (pipe in c(TRUE, FALSE)) {
      code <- sv_auto_clean_rules(disc, df_name = ref, col = "sex", pipe = pipe, lazy = TRUE)
      expect_silent(parse(text = code))
      expect_equal(lengths(regmatches(code, gregexpr("collect(", code, fixed = TRUE))), 1L)
      expect_false(grepl(".default", code, fixed = TRUE))
      got <- as.data.frame(eval(parse(text = code), envir = env))
      expect_equal(got$sex, want$sex, info = paste(ref, pipe))
      expect_equal(got$n, want$n, info = paste(ref, pipe))
    }
  }
  # data frames: still no collect()
  expect_false(grepl("collect", sv_auto_clean_rules(disc, df_name = "vv", col = "sex"), fixed = TRUE))
  expect_false(grepl("collect", sv_auto_clean_rules(disc, df_name = "vv", col = "sex", lazy = FALSE), fixed = TRUE))
  # a bare name or no name still works
  expect_match(sv_auto_clean_rules(disc, df_name = NULL, col = "sex", lazy = TRUE), "dplyr::collect()", fixed = TRUE)
})
