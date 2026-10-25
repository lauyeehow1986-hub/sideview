# Lazy (arrow / duckdb) cards keep their source so later code can use the whole
# table. The source is an R object and must never reach the browser or a file.

if (!"package:sideview" %in% search()) {
  r_files <- list.files(c("R", "../R", "../../R"), pattern = "\\.[Rr]$", full.names = TRUE)
  for (f in r_files) source(f)
}

lazy_fixture <- function(env = parent.frame()) {
  df <- data.frame(id = 1:120, grp = rep(c("a", "b", "c"), 40), stringsAsFactors = FALSE)
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  DBI::dbWriteTable(con, "v", df)
  list(df = df, con = con)
}

test_that("lazy cards keep their source", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  fx <- lazy_fixture()

  d <- sv_normalize(dplyr::tbl(fx$con, "v"), name = "v")
  expect_s3_class(d$source, "tbl_duckdb_connection")
  expect_identical(d$code_ref, "v")
  expect_true(d$is_lazy)
  expect_identical(d$lazy_source, "duckdb")

  a <- sv_normalize(arrow::arrow_table(fx$df), name = "a")
  expect_s3_class(a$source, "ArrowTabular")
  expect_identical(a$code_ref, "a")
  expect_identical(a$lazy_source, "arrow")

  p <- sv_normalize(fx$df)
  expect_null(p$source)
  expect_identical(p$code_ref, p$name)

  mock <- sv_normalize(structure(list(data = fx$df, dims = c(1000L, 2L)),
                                 class = c("tbl_duckdb_connection", "tbl_lazy_mock")),
                       name = "m")
  expect_null(mock$source)
  expect_true(mock$is_lazy)
})

test_that("a whole connection gets a tbl() code_ref", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  fx <- lazy_fixture()
  con <- fx$con

  card <- sv_normalize(con, name = "con")
  expect_identical(card$code_ref, 'dplyr::tbl(con, "v")')
  expect_s3_class(card$source, "tbl_duckdb_connection")
  expect_identical(card$name, "con")
  expect_true(!is.null(parse(text = card$code_ref)))

  # the argument expression is passed in by the callers
  card2 <- sv_normalize(con, name = "x", expr = "db$con")
  expect_identical(card2$code_ref, 'dplyr::tbl(db$con, "v")')
})

test_that("source is never serialised", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  fx <- lazy_fixture()

  w <- sideview_widget(v = dplyr::tbl(fx$con, "v"))
  card <- w$x$cards[[1]]
  expect_null(card$source)
  expect_identical(card$lazy, "duckdb")
  expect_identical(card$totalRows, nrow(fx$df))
  expect_identical(card$codeRef, "v")

  json <- jsonlite::toJSON(w$x, auto_unbox = TRUE, force = TRUE)
  expect_false(grepl('"source"', json, fixed = TRUE))

  st <- new_sideview_state(cards = w$x$cards)
  expect_false(grepl('"source"', sv_state_json(st), fixed = TRUE))

  # a whole connection takes its code_ref from the argument expression
  wc <- sideview_widget(visits = fx$con)
  expect_identical(wc$x$cards[[1]]$name, "visits")
  expect_identical(wc$x$cards[[1]]$codeRef, 'dplyr::tbl(fx$con, "v")')
  con <- fx$con
  wc2 <- sideview_widget(con)
  expect_identical(wc2$x$cards[[1]]$codeRef, 'dplyr::tbl(con, "v")')

  wa <- sideview_widget(a = arrow::arrow_table(fx$df))
  expect_null(wa$x$cards[[1]]$source)
  expect_identical(wa$x$cards[[1]]$lazy, "arrow")

  wp <- sideview_widget(p = fx$df)
  expect_null(wp$x$cards[[1]]$lazy)
})

test_that("sv_card_is_lazy respects the option", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  fx <- lazy_fixture()

  d <- sv_normalize(dplyr::tbl(fx$con, "v"), name = "v")
  a <- sv_normalize(arrow::arrow_table(fx$df), name = "a")
  expect_true(sv_has_duckdb())
  expect_true(sv_card_is_lazy(d))
  expect_true(sv_card_is_lazy(a))
  expect_false(sv_card_is_lazy(sv_normalize(fx$df)))

  withr::local_options(sideview.use_duckdb = FALSE)
  expect_false(sv_has_duckdb())
  expect_false(sv_card_is_lazy(d))
  expect_false(sv_card_is_lazy(a))
})
