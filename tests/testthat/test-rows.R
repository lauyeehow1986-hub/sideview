rows_fixture <- function(n = 1200) {
  set.seed(42)
  data.frame(
    id = seq_len(n),
    age = sample(c(18:90, NA), n, replace = TRUE),
    site = sample(c("north", "South", "east", "West", NA, "b c", "a\"q"), n, replace = TRUE),
    score = round(rnorm(n, 50, 15), 2),
    stringsAsFactors = FALSE
  )
}

test_that("sv_filter_condition builds parseable R conditions", {
  ops <- c("contains", "equals", "not_equals", "gt", "gte", "lt", "lte")
  for (op in ops) {
    cond <- sv_filter_condition("age", op, "50", numeric = TRUE)
    expect_silent(parse(text = cond))
  }
  expect_equal(sv_filter_condition("age", "gt", "50", numeric = TRUE), "age > 50")
  expect_equal(sv_filter_condition("site", "equals", "north"), "site == \"north\"")
  expect_equal(
    sv_filter_condition("site", "contains", "a\"q"),
    "grepl(\"a\\\"q\", site, fixed = TRUE)"
  )
  # Non-syntactic names are backquoted and values with quotes stay valid R
  cond <- sv_filter_condition("my col", "equals", "x\\y\"z")
  expect_silent(parse(text = cond))
  expect_match(cond, "^`my col` == ", perl = TRUE)
  # A non-numeric value on a numeric column is compared as a string, not injected
  expect_equal(sv_filter_condition("age", "gt", "1; system('x')", numeric = TRUE),
               "age > \"1; system('x')\"")
  expect_error(sv_filter_condition("age", "bogus", "1"), "Unknown filter operator")
})

test_that("sv_rows_order matches dplyr::arrange and dplyr::filter", {
  skip_if_not_installed("dplyr")
  df <- rows_fixture()

  for (col in c("age", "site", "score")) {
    asc <- sv_rows_order(df, sort = list(col = col, dir = "asc"))
    expect_equal(df$id[asc], dplyr::arrange(df, .data[[col]])$id, info = col)
    desc <- sv_rows_order(df, sort = list(col = col, dir = "desc"))
    expect_equal(df$id[desc], dplyr::arrange(df, dplyr::desc(.data[[col]]))$id, info = col)
  }

  f <- sv_rows_order(df, filter = list(col = "age", op = "gt", val = "50"))
  expect_equal(df$id[f], dplyr::filter(df, age > 50)$id)

  f <- sv_rows_order(df, filter = list(col = "site", op = "contains", val = "th"))
  expect_equal(df$id[f], dplyr::filter(df, grepl("th", site, fixed = TRUE))$id)

  # Filter and sort combine like filter() %>% arrange()
  fs <- sv_rows_order(df, sort = list(col = "score", dir = "desc"),
                      filter = list(col = "site", op = "equals", val = "South"))
  expected <- df |> dplyr::filter(site == "South") |> dplyr::arrange(dplyr::desc(score))
  expect_equal(df$id[fs], expected$id)
})

test_that("sv_rows_window returns 0-based ids and character columns", {
  df <- rows_fixture(1200)
  cache <- new.env(parent = emptyenv())
  req <- list(offset = 600, limit = 200, sort = list(col = "age", dir = "desc"))
  win <- sv_rows_window(df, req, order_cache = cache)
  ord <- sv_rows_order(df, sort = req$sort)
  expect_equal(win$total, 1200L)
  expect_equal(win$offset, 600L)
  expect_equal(win$row_ids, as.integer(ord[601:800] - 1L))
  expect_named(win$columns, names(df))
  expect_type(win$columns$age, "character")
  expect_equal(win$columns$id, as.character(df$id[ord[601:800]]))
  expect_true(all(is.na(win$columns$age[is.na(df$age[ord[601:800]])])))

  # The order is memoised per spec
  expect_identical(cache$idx, ord)

  # Past the end returns an empty window; filters report their match count
  tail <- sv_rows_window(df, list(offset = 5000, limit = 200))
  expect_length(tail$row_ids, 0)
  fw <- sv_rows_window(df, list(offset = 0, limit = 50, filter = list(col = "age", op = "lte", val = "30")))
  expect_equal(fw$total, sum(df$age <= 30, na.rm = TRUE))
  expect_length(fw$row_ids, 50)
})

test_that("sideview_rows_request is answered from the full data", {
  df <- rows_fixture(1500)
  card <- sv_normalize(df, name = "big")
  server <- sideview_server(list(card))
  shiny::testServer(server, {
    session$setInputs(sideview_rows_request = list(
      card_id = card$id, version = 3, offset = 0, limit = 100,
      sort = list(col = "score", dir = "asc")
    ))
    msgs <- Filter(function(m) identical(m$type, "sideview_rows"), session$userData$custom_messages)
    expect_length(msgs, 1)
    msg <- msgs[[1]]$message
    expect_equal(msg$version, 3)
    expect_equal(msg$total, 1500L)
    expect_equal(msg$row_ids, as.integer(order(df$score, method = "radix")[1:100] - 1L))
  })
})
