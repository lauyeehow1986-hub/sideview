test_that("store keeps order and finds by name or id", {
  st <- sv_card_store()
  a <- sv_normalize(mtcars, name = "a")
  b <- sv_normalize(iris, name = "b")
  st$add(a)
  st$add(b)
  expect_identical(st$get("b"), st$get(b$id))
  expect_equal(st$names(), c("a", "b"))
  expect_true(st$has("a"))
  expect_false(st$has("zz"))

  a2 <- sv_normalize(head(mtcars, 3), name = "a")
  st$replace("a", a2)
  expect_equal(st$names(), c("a", "b"))
  expect_equal(nrow(st$get("a")$data), 3L)
  expect_equal(names(st$all()), c("a", "b"))

  st$remove("a")
  expect_equal(st$names(), "b")
  expect_null(st$get("a"))
})

test_that("payload cuts to the preview and keeps the true row count", {
  big <- mtcars[rep(1:32, 20), ]
  card <- sv_normalize(big, name = "big")
  p <- sv_card_payload(card, preview_rows = 500)
  expect_equal(nrow(p$data), 500L)
  expect_identical(p$totalRows, 640L)
  expect_true(isTRUE(p$remote))
  p2 <- sv_card_payload(card)
  expect_equal(nrow(p2$data), 640L)
  expect_null(p2$remote)
})

test_that("payload of a zero-row frame", {
  p <- sv_card_payload(sv_normalize(mtcars[0, ], name = "z"))
  expect_identical(p$totalRows, 0L)
  expect_equal(nrow(p$data), 0L)
})

test_that("payload never carries source", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "mt", mtcars)
  card <- sv_normalize(dplyr::tbl(con, "mt"), name = "mt")
  p <- sv_card_payload(card)
  expect_null(p$source)
  expect_equal(p$lazy, "duckdb")
})

test_that("sv_normalize_cards names unnamed tables", {
  cs <- sv_normalize_cards(list(mtcars, b = iris))
  expect_equal(vapply(cs, function(c) c$name, ""), c("Table_1", "b"))
  expect_length(sv_normalize_cards(NULL), 0L)
  expect_length(sv_normalize_cards(mtcars), 1L)
})

test_that("one lazy env per session", {
  session <- shiny::MockShinySession$new()
  e1 <- sv_session_lazy_env(session)
  e2 <- sv_session_lazy_env(session)
  expect_true(is.environment(e1))
  expect_identical(e1, e2)
})
