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

test_that("private connection opens once and closes", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  e <- sv_lazy_env()
  expect_null(e$con)
  expect_identical(e$tbls, list())
  withr::defer(sv_lazy_close(e))

  c1 <- sv_lazy_con(e)
  expect_true(DBI::dbIsValid(c1))
  c2 <- sv_lazy_con(e)
  expect_s4_class(c1, "duckdb_connection")
  expect_identical(c1, c2)

  sv_lazy_close(e)
  expect_null(e$con)
  expect_false(DBI::dbIsValid(c1))
  expect_no_error(sv_lazy_close(e))
})

test_that("sv_lazy_tbl converts arrow and caches by key", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  fx <- lazy_fixture()
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))

  a <- arrow::arrow_table(fx$df)
  t1 <- sv_lazy_tbl(a, e, key = "a")
  expect_s3_class(t1, "tbl_duckdb_connection")
  expect_equal(as.data.frame(dplyr::collect(t1)), fx$df)

  t2 <- sv_lazy_tbl(a, e, key = "a")
  expect_identical(t2, t1)
  expect_identical(e$tbls[["a"]], t1)

  # a duckdb tbl is returned as is
  d <- dplyr::tbl(fx$con, "v")
  expect_identical(sv_lazy_tbl(d, e), d)
})

test_that("attach/detach leaves the connection clean", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  fx <- lazy_fixture()
  before <- DBI::dbListTables(fx$con)

  at <- sv_lazy_attach(fx$df, fx$con)
  expect_match(at$name, "^sv_tmp_[0-9a-f]{8}$")
  expect_s3_class(at$tbl, "tbl_duckdb_connection")
  expect_equal(as.data.frame(dplyr::collect(at$tbl)), fx$df)
  sv_lazy_detach(fx$con, at$name)
  expect_identical(DBI::dbListTables(fx$con), before)

  # arrow tables registered by to_duckdb() on a user connection are undone too
  skip_if_not_installed("arrow")
  tb <- arrow::to_duckdb(arrow::arrow_table(fx$df), con = fx$con, auto_disconnect = FALSE)
  nm <- as.character(dbplyr::remote_name(tb))
  sv_lazy_detach_arrow(fx$con, nm)
  expect_identical(DBI::dbListTables(fx$con), before)
})

test_that("attach names do not touch the user's RNG stream", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  fx <- lazy_fixture()
  set.seed(1)
  x <- runif(1)
  set.seed(1)
  a1 <- sv_lazy_attach(fx$df, fx$con)
  a2 <- sv_lazy_attach(fx$df, fx$con)
  y <- runif(1)
  expect_identical(x, y)
  expect_false(identical(a1$name, a2$name))
  sv_lazy_detach(fx$con, a1$name)
  sv_lazy_detach(fx$con, a2$name)
})

# ---- full-table row windows -------------------------------------------------

rows_fixture <- function() {
  set.seed(42)
  n <- 300L
  nm <- c(NA, " a", "A", "a", "b\t", "ab", "Ba", "b", "c1", "a.b", "50%", "x(y)", "q[1]*")
  x <- round(rnorm(n), 1)
  x[c(5, 17, 80, 250)] <- NA
  x[c(10, 11, 12)] <- 0.5
  x[c(30, 31)] <- NaN # R treats NaN as missing, duckdb as the largest number
  x[40] <- -Inf
  df <- data.frame(
    id = seq_len(n),
    name = nm[(seq_len(n) - 1L) %% length(nm) + 1L],
    x = x,
    d = as.Date("2020-01-01") + (seq_len(n) * 7L) %% 90L,
    ok = c(TRUE, FALSE, NA, TRUE, TRUE)[(seq_len(n) - 1L) %% 5L + 1L],
    w = c(0, 10, 100, 130, 2.5, NA, 40, 55.5, 7)[(seq_len(n) - 1L) %% 9L + 1L],
    f = factor(c("u", "v", NA, "uv")[(seq_len(n) - 1L) %% 4L + 1L]),
    stringsAsFactors = FALSE
  )
  df$d[c(3, 9)] <- NA
  df
}

rows_specs <- function() {
  sorts <- c(list(NULL), unlist(lapply(c("id", "name", "x", "d", "ok", "w"), function(cn) {
    list(list(col = cn, dir = "asc"), list(col = cn, dir = "desc"))
  }), recursive = FALSE))
  filters <- list(
    NULL,
    list(col = "name", op = "contains", val = "a"),
    list(col = "id", op = "contains", val = "1"),
    list(col = "x", op = "equals", val = "0.5"),
    list(col = "x", op = "not_equals", val = "0.5"),
    list(col = "x", op = "gt", val = "0.5"),
    list(col = "x", op = "gte", val = "0.5"),
    list(col = "x", op = "lt", val = "0.5"),
    list(col = "x", op = "lte", val = "0.5"),
    list(col = "name", op = "equals", val = ""),
    list(col = "id", op = "gt", val = "250"),
    list(col = "id", op = "equals", val = "7"),
    list(col = "x", op = "equals", val = "abc"),
    # contains matches the text R would give: Date, logical, whole-valued double, factor
    list(col = "d", op = "contains", val = "-01"),
    list(col = "ok", op = "contains", val = "TRUE"),
    list(col = "ok", op = "contains", val = "RU"),
    list(col = "ok", op = "contains", val = "true"),
    list(col = "w", op = "contains", val = "0"),
    list(col = "w", op = "contains", val = "."),
    list(col = "x", op = "contains", val = "N"),
    list(col = "x", op = "contains", val = "Inf"),
    list(col = "f", op = "contains", val = "u"),
    list(col = "d", op = "equals", val = "2020-01-08"),
    # contains is a plain substring match, never a pattern
    list(col = "name", op = "contains", val = "."),
    list(col = "name", op = "contains", val = "%"),
    list(col = "name", op = "contains", val = "("),
    list(col = "name", op = "contains", val = "[1]*"),
    list(col = "name", op = "contains", val = "")
  )
  offsets <- c(0L, 10L, 295L)
  specs <- list()
  for (s in sorts) for (f in filters) for (o in offsets) {
    specs[[length(specs) + 1L]] <- list(sort = s, filter = f, offset = o, limit = 20L)
  }
  specs
}

test_that("lazy row windows equal in-memory windows", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  df <- rows_fixture()
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  con <- sv_lazy_con(e)
  DBI::dbWriteTable(con, "rw", df)
  # keep the Arrow table referenced for as long as duckdb scans it (a card does
  # this through card$source); a collected table under a live scan crashes R
  arrow_src <- arrow::arrow_table(df)
  sources <- list(
    duckdb = sv_lazy_tbl(dplyr::tbl(con, "rw"), e),
    arrow = sv_lazy_tbl(arrow_src, e)
  )
  for (specs_name in names(sources)) {
    tbl <- sources[[specs_name]]
    for (req in rows_specs()) {
      # Paging is the database's job whatever the source, so duckdb runs every
      # offset and arrow the first page of every sort/filter: the full arrow
      # grid (one scan per request) intermittently crashes R inside
      # arrow::to_duckdb's scan, see MEMORY.md.
      if (specs_name == "arrow" && req$offset != 0L) next
      got <- sv_lazy_rows_window(tbl, req)
      want <- sv_rows_window(df, req)
      label <- paste(specs_name, jsonlite::toJSON(req, auto_unbox = TRUE, null = "null"))
      expect_equal(got, want, tolerance = 1e-12, label = label)
    }
  }
})

test_that("lazy sorts do not depend on the database's null order", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("stringr")
  df <- rows_fixture()
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  con <- sv_lazy_con(e)
  DBI::dbWriteTable(con, "rw", df)
  DBI::dbExecute(con, "SET default_null_order = 'NULLS_FIRST'")
  tbl <- dplyr::tbl(con, "rw")
  for (cn in c("name", "x", "d")) for (dir in c("asc", "desc")) {
    req <- list(sort = list(col = cn, dir = dir), offset = 0L, limit = 300L)
    expect_equal(sv_lazy_rows_window(tbl, req), sv_rows_window(df, req), tolerance = 1e-12,
                 label = paste(cn, dir))
  }
})

test_that("lazy row windows clamp and memoise like the in-memory path", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("stringr")
  df <- rows_fixture()
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  con <- sv_lazy_con(e)
  DBI::dbWriteTable(con, "rw", df)
  tbl <- dplyr::tbl(con, "rw")

  for (req in list(list(offset = -5, limit = 0), list(offset = 3, limit = 99999),
                   list(), list(offset = "7", limit = "4"),
                   list(sort = list(col = "nope", dir = "asc"),
                        filter = list(col = "nope", op = "equals", val = "1")))) {
    expect_equal(sv_lazy_rows_window(tbl, req), sv_rows_window(df, req), tolerance = 1e-12)
  }

  cache <- new.env()
  req <- list(filter = list(col = "x", op = "gt", val = "0.5"), offset = 0L, limit = 10L)
  w1 <- sv_lazy_rows_window(tbl, req, cache)
  expect_equal(cache$total, w1$total)
  cache$total <- 12345L # a memoised total is trusted for the same spec
  w2 <- sv_lazy_rows_window(tbl, utils::modifyList(req, list(offset = 10L)), cache)
  expect_equal(w2$total, 12345L)
  w3 <- sv_lazy_rows_window(tbl, list(offset = 0L, limit = 10L), cache)
  expect_equal(w3$total, nrow(df))
})

test_that("lazy row windows handle zero-row tables", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("stringr")
  df <- rows_fixture()[0, ]
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  con <- sv_lazy_con(e)
  DBI::dbWriteTable(con, "rw0", df)
  tbl <- dplyr::tbl(con, "rw0")
  for (req in list(list(offset = 0L, limit = 20L),
                   list(sort = list(col = "x", dir = "desc"),
                        filter = list(col = "name", op = "contains", val = "a"),
                        offset = 0L, limit = 20L))) {
    got <- sv_lazy_rows_window(tbl, req)
    expect_identical(got$total, 0L)
    expect_identical(got$row_ids, integer(0))
    expect_equal(got, sv_rows_window(df, req), tolerance = 1e-12)
  }
})

test_that("lazy filter expressions are language objects that parse", {
  ex <- sv_lazy_filter_expr("a b", "contains", "x\"y", numeric = FALSE)
  expect_true(is.language(ex))
  expect_true(!is.null(parse(text = paste(deparse(ex), collapse = " "))))
  expect_error(sv_lazy_filter_expr("a", "bogus", "1", FALSE), "Unknown filter operator")
})
