# Source R files if running standalone without package installed
if (!"package:sideview" %in% search()) {
  r_files <- list.files(c("R", "../R", "../../R"), pattern = "\\.[Rr]$", full.names = TRUE)
  for (f in r_files) source(f)
}

test_that("data.frame and tibble normalization works", {
  df <- data.frame(
    id = 1:3,
    name = c("Alice", "Bob", "Charlie"),
    stringsAsFactors = FALSE
  )
  
  card <- sv_normalize(df, name = "users", id = "card_users")
  
  expect_s3_class(card, "sideview_card")
  expect_equal(card$id, "card_users")
  expect_equal(card$name, "users")
  expect_equal(card$type, "grid")
  expect_equal(nrow(card$data), 3)
  expect_equal(ncol(card$data), 2)
  expect_equal(card$dims, c(3L, 2L))
  expect_equal(names(card$col_types), c("id", "name"))
  expect_equal(unname(card$col_types["id"]), "integer")
  expect_equal(unname(card$col_types["name"]), "character")

  # Test tibble
  tbl <- dplyr::tibble(
    x = c(1.5, 2.5),
    y = c(TRUE, FALSE)
  )
  card_tbl <- sv_normalize(tbl, name = "my_tibble")
  expect_s3_class(card_tbl, "sideview_card")
  expect_equal(card_tbl$name, "my_tibble")
  expect_equal(card_tbl$type, "grid")
  expect_equal(card_tbl$dims, c(2L, 2L))
  expect_true(nchar(card_tbl$id) > 0)
})

test_that("base::table normalization converts to data.frame grid", {
  # 1D table
  tbl_1d <- table(c("apple", "banana", "apple", "cherry"))
  card_1d <- sv_normalize(tbl_1d, name = "fruits")
  
  expect_s3_class(card_1d, "sideview_card")
  expect_equal(card_1d$name, "fruits")
  expect_equal(card_1d$type, "grid")
  expect_true(is.data.frame(card_1d$data))
  expect_equal(ncol(card_1d$data), 2) # Var1, Freq
  expect_equal(card_1d$dims, c(3L, 2L))
  
  # 2D table
  tbl_2d <- table(c("A", "A", "B"), c("X", "Y", "X"))
  card_2d <- sv_normalize(tbl_2d, name = "crosstab")
  expect_s3_class(card_2d, "sideview_card")
  expect_equal(card_2d$type, "grid")
  expect_equal(ncol(card_2d$data), 3) # Var1, Var2, Freq
  expect_equal(card_2d$dims, c(4L, 3L))
})

test_that("gt_tbl normalization renders HTML and retains underlying data", {
  skip_if_not_installed("gt")
  
  gt_obj <- gt::gt(head(mtcars, 4)[, c("mpg", "cyl", "hp")])
  card_gt <- sv_normalize(gt_obj, name = "gt_cars")
  
  expect_s3_class(card_gt, "sideview_card")
  expect_equal(card_gt$name, "gt_cars")
  expect_equal(card_gt$type, "html")
  expect_true(is.character(card_gt$html_content))
  expect_true(grepl("<table", card_gt$html_content))
  expect_equal(nrow(card_gt$data), 4)
  expect_equal(ncol(card_gt$data), 3)
  expect_equal(card_gt$dims, c(4L, 3L))
})

test_that("flextable normalization renders HTML and retains dataset", {
  skip_if_not_installed("flextable")
  
  ft_obj <- flextable::flextable(head(iris, 5)[, 1:3])
  card_ft <- sv_normalize(ft_obj, name = "ft_iris")
  
  expect_s3_class(card_ft, "sideview_card")
  expect_equal(card_ft$name, "ft_iris")
  expect_equal(card_ft$type, "html")
  expect_true(is.character(card_ft$html_content))
  expect_true(nchar(card_ft$html_content) > 0)
  expect_equal(nrow(card_ft$data), 5)
  expect_equal(ncol(card_ft$data), 3)
  expect_equal(card_ft$dims, c(5L, 3L))
})

test_that("htmlwidget normalization wraps widget container", {
  skip_if_not_installed("htmlwidgets")
  
  widget <- htmlwidgets::createWidget(
    name = "dummyWidget",
    x = list(values = 1:5),
    width = 400,
    height = 300
  )
  
  card_widget <- sv_normalize(widget, name = "my_widget")
  
  expect_s3_class(card_widget, "sideview_card")
  expect_equal(card_widget$name, "my_widget")
  expect_equal(card_widget$type, "widget")
  expect_s3_class(card_widget$widget, "htmlwidget")
})

test_that("sv_normalize handles unsupported types with error", {
  expect_error(
    sv_normalize(function(x) x),
    "Cannot normalize object"
  )
})

test_that("sv_normalize handles matrix and edge cases gracefully", {
  mat <- matrix(1:6, nrow = 2, ncol = 3, dimnames = list(NULL, c("a", "b", "c")))
  card_mat <- sv_normalize(mat, name = "matrix_data")
  expect_s3_class(card_mat, "sideview_card")
  expect_equal(card_mat$type, "grid")
  expect_equal(card_mat$dims, c(2L, 3L))

  # Edge case: character(0) id and length > 1 names
  card_zero_id <- sv_normalize(data.frame(x = 1), id = character(0), name = c("TableA", "TableB"))
  expect_true(nzchar(card_zero_id$id))
  expect_equal(card_zero_id$name, "TableA")

  # Empty data frame
  card_empty <- sv_normalize(data.frame())
  expect_equal(card_empty$dims, c(0L, 0L))

  # print.sideview_card output
  expect_output(print(card_mat), "<sideview_card \\[grid\\]>")
})

test_that("sv_normalize handles Arrow objects lazily with soft dependency", {
  # Mock arrow_table S3 class
  mock_arrow <- structure(
    list(
      schema = list(
        names = c("id", "value"),
        fields = list(
          id = list(type = list(name = "int32")),
          value = list(type = list(name = "double"))
        )
      ),
      data = data.frame(id = 1:10, value = rnorm(10)),
      dims = c(1000L, 2L)
    ),
    class = c("arrow_table", "ArrowTabular")
  )

  # Check missing dependency guard
  orig_req_arrow <- base::requireNamespace
  testthat::with_mocked_bindings(
    expect_error(
      sv_normalize(mock_arrow),
      "Package 'arrow' must be installed"
    ),
    requireNamespace = function(pkg, ...) if (identical(pkg, "arrow")) FALSE else orig_req_arrow(pkg, ...),
    .package = "base"
  )

  # Normalization with mock Arrow table
  card_mock <- sv_normalize(mock_arrow, name = "mock_arrow_tbl")
  expect_s3_class(card_mock, "sideview_card")
  expect_equal(card_mock$name, "mock_arrow_tbl")
  expect_equal(card_mock$type, "grid")
  expect_true(card_mock$is_lazy)
  expect_equal(card_mock$lazy_source, "arrow")
  expect_equal(card_mock$dims, c(1000L, 2L))
  expect_equal(card_mock$col_types, c(id = "int32", value = "double"))
  expect_equal(nrow(card_mock$data), 10)

  # If arrow package is installed, test with real Arrow objects
  skip_if_not_installed("arrow")

  # arrow::arrow_table
  tab <- arrow::arrow_table(mtcars)
  card_tab <- sv_normalize(tab, name = "arrow_mtcars")
  expect_s3_class(card_tab, "sideview_card")
  expect_true(card_tab$is_lazy)
  expect_equal(card_tab$lazy_source, "arrow")
  expect_equal(card_tab$dims, c(32L, 11L))
  expect_equal(names(card_tab$col_types), colnames(mtcars))
  expect_equal(nrow(card_tab$data), 32)

  # arrow::record_batch
  rb <- arrow::record_batch(mtcars)
  card_rb <- sv_normalize(rb, name = "arrow_rb")
  expect_s3_class(card_rb, "sideview_card")
  expect_true(card_rb$is_lazy)
  expect_equal(card_rb$dims, c(32L, 11L))

  # arrow::Dataset
  tmp_parquet <- tempfile(fileext = ".parquet")
  on.exit(unlink(tmp_parquet), add = TRUE)
  arrow::write_parquet(mtcars, tmp_parquet)
  ds <- arrow::open_dataset(tmp_parquet)
  card_ds <- sv_normalize(ds, name = "arrow_ds")
  expect_s3_class(card_ds, "sideview_card")
  expect_true(card_ds$is_lazy)
  expect_equal(card_ds$dims, c(32L, 11L))
  expect_equal(names(card_ds$col_types), colnames(mtcars))
})

test_that("sv_normalize handles DuckDB objects lazily with soft dependency", {
  # Mock tbl_duckdb_connection S3 class
  mock_duck <- structure(
    list(
      schema = list(col_a = "integer", col_b = "character"),
      data = data.frame(col_a = 1:5, col_b = letters[1:5], stringsAsFactors = FALSE),
      dims = c(50000L, 2L)
    ),
    class = "tbl_duckdb_connection"
  )

  # Check missing dependency guard
  orig_req_duck <- base::requireNamespace
  testthat::with_mocked_bindings(
    expect_error(
      sv_normalize(mock_duck),
      "Package 'duckdb' must be installed"
    ),
    requireNamespace = function(pkg, ...) if (identical(pkg, "duckdb")) FALSE else orig_req_duck(pkg, ...),
    .package = "base"
  )

  # Normalization with mock DuckDB tbl
  card_mock <- sv_normalize(mock_duck, name = "mock_duck_tbl")
  expect_s3_class(card_mock, "sideview_card")
  expect_equal(card_mock$name, "mock_duck_tbl")
  expect_equal(card_mock$type, "grid")
  expect_true(card_mock$is_lazy)
  expect_equal(card_mock$lazy_source, "duckdb")
  expect_equal(card_mock$dims, c(50000L, 2L))
  expect_equal(card_mock$col_types, c(col_a = "integer", col_b = "character"))
  expect_equal(nrow(card_mock$data), 5)

  # Mock duckdb_connection S3 class
  mock_con <- structure(
    list(
      schema = list(x = "numeric"),
      data = data.frame(x = 1:10),
      dims = c(10L, 1L)
    ),
    class = "duckdb_connection"
  )
  card_mock_con <- sv_normalize(mock_con, name = "mock_con")
  expect_s3_class(card_mock_con, "sideview_card")
  expect_true(card_mock_con$is_lazy)
  expect_equal(card_mock_con$lazy_source, "duckdb")

  # If duckdb and DBI are installed, test with real DuckDB instance
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  skip_if_not_installed("dbplyr")

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbWriteTable(con, "duck_mtcars", mtcars)

  # tbl_duckdb_connection
  tbl_obj <- dplyr::tbl(con, "duck_mtcars")
  card_tbl <- sv_normalize(tbl_obj, name = "duck_tbl_card")
  expect_s3_class(card_tbl, "sideview_card")
  expect_true(card_tbl$is_lazy)
  expect_equal(card_tbl$lazy_source, "duckdb")
  expect_equal(card_tbl$dims, c(32L, 11L))
  expect_equal(names(card_tbl$col_types), colnames(mtcars))
  expect_equal(nrow(card_tbl$data), 32)

  # duckdb_connection with table lookup
  card_con <- sv_normalize(con, name = "duck_mtcars")
  expect_s3_class(card_con, "sideview_card")
  expect_true(card_con$is_lazy)
  expect_equal(card_con$lazy_source, "duckdb")
  expect_equal(card_con$dims, c(32L, 11L))
})

test_that("print.sideview_card displays lazy badge for lazy cards", {
  lazy_card <- new_sideview_card(
    id = "card_lazy_test",
    name = "lazy_dataset",
    type = "grid",
    data = head(mtcars, 10),
    dims = c(1000000L, 11L),
    is_lazy = TRUE,
    lazy_source = "arrow"
  )

  expect_true(lazy_card$is_lazy)
  expect_output(print(lazy_card), "\\[grid - lazy\\]")
  expect_output(print(lazy_card), "Lazy: TRUE")
})
