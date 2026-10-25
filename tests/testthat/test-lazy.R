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

  # a state built from the R cards themselves, which do carry `source`
  cards <- list(sv_normalize(dplyr::tbl(fx$con, "v"), name = "v"),
                sv_normalize(arrow::arrow_table(fx$df), name = "a"))
  expect_true(all(vapply(cards, function(cd) !is.null(cd$source), logical(1))))
  st <- new_sideview_state(cards = cards)
  txt <- sv_state_json(st)
  expect_false(grepl('"source"', txt, fixed = TRUE))
  expect_match(txt, '"name":"v"', fixed = TRUE)
  rds <- withr::local_tempfile(fileext = ".rds")
  sv_save_state(st, rds)
  back <- readRDS(rds)
  expect_true(all(vapply(back$cards, function(cd) is.null(cd$source), logical(1))))
  jsn <- withr::local_tempfile(fileext = ".json")
  sv_save_state(st, jsn)
  expect_false(any(grepl('"source"', readLines(jsn), fixed = TRUE)))

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

test_that("arrow dictionary columns reach duckdb decoded", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  # duckdb's arrow scan points the NULL rows of a dictionary column one past the
  # end of the dictionary and reads that slot: a heap over-read that segfaults R
  # when the dictionary ends at a page boundary. Dictionaries must never reach it.
  df <- data.frame(id = 1:6, f = factor(c("u", "v", NA, "uv", NA, "u")), s = c("a", NA, "b"),
                   stringsAsFactors = FALSE)
  at <- arrow::arrow_table(df, g = arrow::DictionaryArray$create(c(0L, 1L, NA, 2L, 0L, NA), c(10L, 20L, 30L)))
  is_dict <- function(x) vapply(arrow::schema(x)$fields, function(f) inherits(f$type, "DictionaryType"), logical(1))
  expect_true(any(is_dict(at)))

  dec <- expect_no_warning(sv_lazy_decode_dictionaries(at))
  expect_false(any(is_dict(dec)))
  expect_identical(arrow::schema(dec)$names, arrow::schema(at)$names)
  expect_identical(arrow::schema(dec)$GetFieldByName("f")$type$ToString(), "string")
  expect_identical(arrow::schema(dec)$GetFieldByName("g")$type$ToString(), "int32")
  got <- as.data.frame(dplyr::collect(dec))
  expect_identical(got$f, as.character(df$f))
  expect_identical(got$g, c(10L, 20L, NA, 30L, 10L, NA))

  # no dictionary: handed over as is (zero-copy)
  plain <- arrow::arrow_table(df[c("id", "s")])
  expect_identical(sv_lazy_decode_dictionaries(plain), plain)

  # sv_lazy_tbl() hands duckdb the decoded object, for tables and datasets
  dir <- withr::local_tempfile()
  arrow::write_dataset(at, dir)
  real_to_duckdb <- arrow::to_duckdb
  seen <- NULL
  local_mocked_bindings(
    to_duckdb = function(.data, ...) {
      seen <<- .data
      real_to_duckdb(.data, ...)
    },
    .package = "arrow"
  )
  for (src in list(at, arrow::open_dataset(dir))) {
    seen <- NULL
    e <- sv_lazy_env()
    tb <- expect_no_warning(sv_lazy_tbl(src, e))
    expect_false(any(is_dict(seen)))
    res <- dplyr::collect(dplyr::arrange(tb, id))
    expect_identical(res$f, as.character(df$f))
    sv_lazy_close(e)
  }
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
  # the arrow grid runs over 3000 scans in one process: before sv_lazy_tbl()
  # decoded dictionaries, the factor `f` crashed R in about half of the runs
  arrow_src <- arrow::arrow_table(df)
  sources <- list(
    duckdb = sv_lazy_tbl(dplyr::tbl(con, "rw"), e),
    arrow = sv_lazy_tbl(arrow_src, e)
  )
  for (specs_name in names(sources)) {
    tbl <- sources[[specs_name]]
    for (req in rows_specs()) {
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

# Factors whose levels are not in alphabetical order, plus filter values that do not
# parse as the column's type.
level_fixture <- function() {
  n <- 60L
  v <- c("high", "low", NA, "mid", "low", "high", "mid")[(seq_len(n) - 1L) %% 7L + 1L]
  data.frame(
    id = seq_len(n),
    lv = factor(v, levels = c("low", "mid", "high")),
    o = factor(v, levels = c("low", "mid", "high"), ordered = TRUE),
    ok = c(TRUE, FALSE, NA)[(seq_len(n) - 1L) %% 3L + 1L],
    d = as.Date("2020-01-01") + seq_len(n),
    stringsAsFactors = FALSE
  )
}

level_specs <- function(what = c("sorts", "filters")) {
  sorts <- c(list(NULL), unlist(lapply(c("lv", "o"), function(cn) {
    list(list(col = cn, dir = "asc"), list(col = cn, dir = "desc"))
  }), recursive = FALSE))
  filters <- list(
    NULL,
    list(col = "lv", op = "equals", val = "mid"),
    list(col = "lv", op = "not_equals", val = "mid"),
    list(col = "lv", op = "contains", val = "i"),
    list(col = "lv", op = "gt", val = "low"),        # unordered: no rows, as in R
    list(col = "o", op = "gt", val = "low"),         # ordered: by level
    list(col = "o", op = "lte", val = "mid"),
    list(col = "o", op = "gt", val = "zzz"),         # not a level: no rows
    list(col = "o", op = "equals", val = "zzz"),
    list(col = "ok", op = "equals", val = "yes"),    # not a logical: compared as text
    list(col = "ok", op = "not_equals", val = "yes"),
    list(col = "ok", op = "equals", val = "TRUE"),
    list(col = "ok", op = "gt", val = "FALSE"),
    list(col = "d", op = "equals", val = "abc"),     # not a date: no rows, no error
    list(col = "d", op = "gt", val = "abc"),
    list(col = "d", op = "lt", val = ""),
    list(col = "d", op = "gte", val = "2020-02-01"),
    list(col = "d", op = "equals", val = "2020-1-5")
  )
  if (!"sorts" %in% what) sorts <- list(NULL)
  if (!"filters" %in% what) filters <- list(NULL)
  specs <- list()
  for (s in sorts) for (f in filters) for (o in c(0L, 7L)) {
    specs[[length(specs) + 1L]] <- list(sort = s, filter = f, offset = o, limit = 25L)
  }
  specs
}

level_sources <- function(e) {
  df <- level_fixture()
  con <- sv_lazy_con(e)
  # duckdb has no ordered ENUM: an ordered factor comes back as a plain factor
  df_db <- df
  df_db$o <- factor(df$o, levels = levels(df$o), ordered = FALSE)
  DBI::dbWriteTable(con, "lv", df_db, overwrite = TRUE)
  list(
    arrow = list(tbl = sv_lazy_tbl(arrow::arrow_table(df), e), df = df),
    duckdb = list(tbl = dplyr::tbl(con, "lv"), df = df_db)
  )
}

test_that("lazy windows sort factors by their levels, not their text", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  sources <- level_sources(e)
  for (nm in names(sources)) {
    for (req in level_specs("sorts")) {
      label <- paste(nm, jsonlite::toJSON(req, auto_unbox = TRUE, null = "null"))
      expect_equal(sv_lazy_rows_window(sources[[nm]]$tbl, req), sv_rows_window(sources[[nm]]$df, req),
                   tolerance = 1e-12, label = label)
    }
  }
  # low, mid, high (text order would be high, low, mid)
  w <- sv_lazy_rows_window(sources$arrow$tbl, list(sort = list(col = "o", dir = "asc"), limit = 60L))
  expect_identical(unique(w$columns$o), c("low", "mid", "high", NA))
})

test_that("lazy filters match R on values that do not parse as the column type", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  sources <- level_sources(e)
  for (nm in names(sources)) {
    for (req in level_specs()) {
      label <- paste(nm, jsonlite::toJSON(req, auto_unbox = TRUE, null = "null"))
      got <- sv_lazy_rows_window(sources[[nm]]$tbl, req)
      want <- suppressWarnings(sv_rows_window(sources[[nm]]$df, req))  # '>' on a factor warns
      expect_equal(got, want, tolerance = 1e-12, label = label)
    }
  }
  # no error either: a Date filter on "abc" is an empty window
  w <- sv_lazy_rows_window(sources$duckdb$tbl, list(filter = list(col = "d", op = "equals", val = "abc")))
  expect_identical(w$total, 0L)
})

test_that("a lazy row total past the integer range stays a number", {
  skip_on_cran()
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  con <- sv_lazy_con(e)
  DBI::dbExecute(con, "CREATE VIEW huge AS SELECT range AS id FROM range(3000000000)")
  w <- sv_lazy_rows_window(dplyr::tbl(con, "huge"), list(offset = 0L, limit = 3L))
  expect_identical(w$total, 3e9)
  expect_identical(w$row_ids, 0:2)
  expect_identical(w$columns$id, c("0", "1", "2"))
})

big_rows_table <- function(con, n = 5e6) {
  DBI::dbExecute(con, sprintf(
    "CREATE TABLE big AS SELECT range AS id, (range * 7919) %% 1000003 AS k,
       'n' || (range %% 997) AS s FROM range(%.0f)", n))
  dplyr::tbl(con, "big")
}

test_that("a sorted window of a 5M-row table is under 1 s (duckdb and arrow)", {
  skip_on_cran()
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  con <- sv_lazy_con(e)
  duck <- big_rows_table(con)
  arrow_src <- arrow::arrow_table(dplyr::collect(duck))
  sources <- list(duckdb = duck, arrow = sv_lazy_tbl(arrow_src, e))
  for (nm in names(sources)) {
    tbl <- sources[[nm]]
    cache <- new.env()
    first <- sv_lazy_rows_window(tbl, list(offset = 0L, limit = 200L), cache)  # counts once
    expect_identical(first$total, 5000000L)
    for (req in list(
      list(sort = list(col = "k", dir = "asc"), offset = 0L, limit = 200L),
      list(sort = list(col = "s", dir = "desc"), offset = 1000L, limit = 200L),
      list(offset = 4999800L, limit = 200L)
    )) {
      t <- system.time(w <- sv_lazy_rows_window(tbl, req, cache))[["elapsed"]]
      label <- paste(nm, jsonlite::toJSON(req, auto_unbox = TRUE))
      expect_lt(t, 1, label = label)
      # stable and numbered by table order: id is the 0-based row number
      expect_identical(as.numeric(w$columns$id), as.numeric(w$row_ids), label = label)
      expect_length(w$row_ids, 200L)
    }
    # ties keep table order; a repeated request gives the same rows
    req <- list(sort = list(col = "s", dir = "asc"), offset = 0L, limit = 50L)
    a <- sv_lazy_rows_window(tbl, req, cache)
    b <- sv_lazy_rows_window(tbl, req, cache)
    expect_identical(a, b)
    expect_true(all(unique(a$columns$s) == "n0"))
    expect_identical(a$row_ids, as.integer(seq(0, by = 997, length.out = 50)))
  }
})

test_that("lazy requests never collect more rows than they show", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  n <- 5000L
  df <- data.frame(id = seq_len(n), g = rep(c("a", "b", "c", "d", "e"), n / 5),
                   x = round(sin(seq_len(n)), 3), stringsAsFactors = FALSE)
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  con <- sv_lazy_con(e)
  DBI::dbWriteTable(con, "spy", df)
  DBI::dbWriteTable(con, "spy2", df[seq(1, n, by = 2), ])
  sizes <- integer(0)
  real_collect <- dplyr::collect
  testthat::local_mocked_bindings(
    collect = function(x, ...) {
      out <- real_collect(x, ...)
      if (is.data.frame(out)) sizes <<- c(sizes, nrow(out))
      out
    },
    .package = "dplyr"
  )
  limit <- 40L
  top_n <- 10L
  bins <- 20L
  for (tbl in list(dplyr::tbl(con, "spy"), sv_lazy_tbl(arrow::arrow_table(df), e))) {
    for (req in list(list(offset = 100L, limit = limit),
                     list(sort = list(col = "x", dir = "desc"), offset = 4000L, limit = limit),
                     list(filter = list(col = "g", op = "equals", val = "b"), offset = 10L, limit = limit))) {
      sv_lazy_rows_window(tbl, req)
    }
    sv_lazy_column_profile(tbl, "x", top_n = top_n, bins = bins, con_env = e)
    sv_lazy_column_profile(tbl, "g", top_n = top_n, bins = bins, con_env = e)
  }
  sv_join_diagnostics(dplyr::tbl(con, "spy"), dplyr::tbl(con, "spy2"), by = c(id = "id"))
  sv_codebook(spy = dplyr::tbl(con, "spy"), top_n = top_n)
  expect_gt(length(sizes), 10L)   # the spy saw the calls
  expect_lte(max(sizes), max(limit, top_n, bins))
})

test_that("lazy filter expressions are language objects that parse", {
  ex <- sv_lazy_filter_expr("a b", "contains", "x\"y", numeric = FALSE)
  expect_true(is.language(ex))
  expect_true(!is.null(parse(text = paste(deparse(ex), collapse = " "))))
  expect_error(sv_lazy_filter_expr("a", "bogus", "1", FALSE), "Unknown filter operator")
})

# ---------------------------------------------------------------------------
# Join check over the whole tables
# ---------------------------------------------------------------------------

join_scenarios <- function() {
  list(
    # whitespace / case / leading-zero near-misses, NA keys, duplicates, different key names
    text = list(
      x = data.frame(
        pid = c("P1", " P1", "p1", "P1\t", "007", NA, "A", "A", "B", "0", "00", "Q", "R", "S", "T"),
        v = seq_len(15), stringsAsFactors = FALSE
      ),
      y = data.frame(
        patient_id = c("P1", "P1", "7", "A", "A", NA, NA, "C", "0", "12", "B", "0", "D"),
        w = seq_len(13), stringsAsFactors = FALSE
      ),
      by = c(pid = "patient_id")
    ),
    # two-column key with NA in either part
    pair = list(
      x = data.frame(
        site = c(1L, 1L, 2L, NA, NA, 3L, 3L, 4L, 5L, 6L, 7L, 8L),
        code = c("a", "b", NA, "a", NA, "z", "z", "q", "r", "s", "t", "u"),
        stringsAsFactors = FALSE
      ),
      y = data.frame(
        site = c(1L, 1L, 1L, 2L, NA, NA, 3L, 9L),
        code = c("a", "a", "b", NA, "a", "a", "z", "q"),
        stringsAsFactors = FALSE
      ),
      by = c("site", "code")
    ),
    # doubles: NaN is missing in R, and duckdb sorts it high
    dbl = list(
      x = data.frame(k = c(1, 2.5, NaN, NA, Inf, 3, 3, 10, 11, 12, 13)),
      y = data.frame(k = c(1, NaN, NA, NA, 3, 3, 2.5, -Inf, 99)),
      by = "k"
    ),
    # a factor against text, with NA
    fct = list(
      x = data.frame(f = factor(c("u", "v", NA, "w", "u", "z")), stringsAsFactors = TRUE),
      y = data.frame(f = c("u", "u", "w", NA, "q"), stringsAsFactors = FALSE),
      by = "f"
    ),
    # a number against text: dplyr would refuse the join, the counts still agree
    mixed = list(
      x = data.frame(id = c(1L, 2L, 3L, 4L, 5L, NA)),
      y = data.frame(id = c("1", "2", "2", "x", NA), stringsAsFactors = FALSE),
      by = "id"
    ),
    # only one side is text, and trimming it would match the numbers
    mixed_ws = list(
      x = data.frame(id = c(" 1", "2 ", "3", NA), stringsAsFactors = FALSE),
      y = data.frame(id = c(1, 2, 2, 4, NA)),
      by = "id"
    )
  )
}

# one side as a data frame, a table on the shared duckdb connection, or an arrow table
join_side <- function(df, how, con, name) {
  switch(how,
    df = df,
    duckdb = {
      DBI::dbWriteTable(con, name, df, overwrite = TRUE)
      dplyr::tbl(con, name)
    },
    arrow = arrow::arrow_table(df)
  )
}

join_combos <- function() {
  g <- expand.grid(x = c("df", "duckdb", "arrow"), y = c("df", "duckdb", "arrow"),
                   stringsAsFactors = FALSE)
  g[!(g$x == "df" & g$y == "df"), ]
}

test_that("lazy join diagnostics equal in-memory", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  fx <- lazy_fixture()
  combos <- join_combos()
  scenarios <- join_scenarios()
  for (nm in names(scenarios)) {
    sc <- scenarios[[nm]]
    want <- sv_join_diagnostics(sc$x, sc$y, sc$by, x_name = "left", y_name = "right")
    for (i in seq_len(nrow(combos))) {
      got <- sv_join_diagnostics(
        join_side(sc$x, combos$x[i], fx$con, "jx"),
        join_side(sc$y, combos$y[i], fx$con, "jy"),
        sc$by, x_name = "left", y_name = "right"
      )
      expect_equal(got, want, tolerance = 1e-12,
                   label = paste(nm, combos$x[i], "x", combos$y[i]))
    }
  }
})

test_that("the lazy join check finds the near-miss fixes and the samples", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("stringr")
  fx <- lazy_fixture()
  sc <- join_scenarios()$text
  d <- sv_join_diagnostics(join_side(sc$x, "duckdb", fx$con, "jx"),
                           join_side(sc$y, "df", fx$con, "jy"), sc$by, sample_n = 3L)
  expect_setequal(vapply(d$hints, `[[`, "", "fix"), c("trim", "case", "zeros"))
  expect_length(d$unmatched_x, 3L)
  expect_equal(d, sv_join_diagnostics(sc$x, sc$y, sc$by, sample_n = 3L), tolerance = 1e-12)
})

test_that("the lazy join check handles zero-row and all-NA keys", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  fx <- lazy_fixture()
  chr <- function(...) data.frame(k = c(...), stringsAsFactors = FALSE)
  cases <- list(
    zero_x = list(x = data.frame(k = character(0), v = integer(0), stringsAsFactors = FALSE),
                  y = chr("a", "b", NA)),
    zero_y = list(x = chr("a", NA), y = chr(NA)[0, , drop = FALSE]),
    zero_both = list(x = chr(NA)[0, , drop = FALSE], y = chr(NA)[0, , drop = FALSE]),
    all_na = list(x = chr(NA_character_, NA_character_),
                  y = chr(NA_character_, NA_character_, NA_character_)),
    all_na_num = list(x = data.frame(k = c(NA_real_, NaN)), y = data.frame(k = c(NaN, NA_real_, 1)))
  )
  combos <- join_combos()
  for (nm in names(cases)) {
    cs <- cases[[nm]]
    want <- sv_join_diagnostics(cs$x, cs$y, "k")
    for (i in seq_len(nrow(combos))) {
      got <- sv_join_diagnostics(join_side(cs$x, combos$x[i], fx$con, "jx"),
                                 join_side(cs$y, combos$y[i], fx$con, "jy"), "k")
      expect_equal(got, want, tolerance = 1e-12, label = paste(nm, combos$x[i], "x", combos$y[i]))
    }
  }
})

test_that("tables on different connections give the message", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  fx1 <- lazy_fixture()
  fx2 <- lazy_fixture()
  msg <- "These tables are on different duckdb connections; join check unavailable."
  err <- tryCatch(
    sv_join_diagnostics(dplyr::tbl(fx1$con, "v"), dplyr::tbl(fx2$con, "v"), "id"),
    error = function(e) e
  )
  expect_s3_class(err, "sv_lazy_cross_con")
  expect_identical(conditionMessage(err), msg)
  expect_error(sv_lazy_join_diagnostics(dplyr::tbl(fx1$con, "v"), dplyr::tbl(fx2$con, "v"), "id"),
               class = "sv_lazy_cross_con")
  # two tbls on the one connection are fine
  d <- sv_join_diagnostics(dplyr::tbl(fx1$con, "v"), dplyr::tbl(fx1$con, "v"), "id")
  expect_identical(d$matched_x, 120L)
})

test_that("a join check leaves the user's connection clean", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  fx <- lazy_fixture()
  tbl_v <- dplyr::tbl(fx$con, "v")
  before <- sort(DBI::dbListTables(fx$con))

  d1 <- sv_join_diagnostics(tbl_v, arrow::arrow_table(fx$df), "id")
  expect_identical(sort(DBI::dbListTables(fx$con)), before)
  d2 <- sv_join_diagnostics(tbl_v, fx$df, "id")
  expect_identical(sort(DBI::dbListTables(fx$con)), before)
  d3 <- sv_join_diagnostics(fx$df, arrow::arrow_table(fx$df), "id")
  d4 <- sv_join_diagnostics(arrow::arrow_table(fx$df), tbl_v, "id")
  expect_identical(sort(DBI::dbListTables(fx$con)), before)
  expect_equal(d1, d2, tolerance = 1e-12)
  expect_equal(d3, d4, tolerance = 1e-12)

  # a failure half way through still puts everything back
  testthat::local_mocked_bindings(
    sv_lazy_join_scalars = function(...) stop("boom")
  )
  expect_error(sv_join_diagnostics(tbl_v, arrow::arrow_table(fx$df), "id"), "boom")
  expect_error(sv_join_diagnostics(tbl_v, fx$df, "id"), "boom")
  expect_identical(sort(DBI::dbListTables(fx$con)), before)
  # a missing column is refused before anything is placed
  expect_error(sv_join_diagnostics(tbl_v, fx$df, "nope"), "Not in")
  expect_identical(sort(DBI::dbListTables(fx$con)), before)
})

test_that("the join check on private tables leaves the shared connection empty", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  df <- data.frame(id = 1:5)
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  d <- sv_lazy_join_diagnostics(arrow::arrow_table(df), df, "id", con_env = e)
  expect_identical(d$matched_x, 5L)
  expect_false(is.null(e$con))
  expect_length(DBI::dbListTables(e$con), 0L)
  expect_true(sv_is_lazy_input(arrow::arrow_table(df)))
  expect_false(sv_is_lazy_input(df))
})

test_that("lazy counts stay integer until they pass the integer range", {
  expect_identical(sv_lazy_count(5), 5L)
  expect_identical(sv_lazy_count(3e9), 3e9)
})

profile_columns <- function() {
  i <- seq_len(300)
  list(
    num_outliers = c(rep(10, 6), 11, 12, 12, 13, 14, 15, 15, 15, 500, NA, 1000, NA),
    num_special = c(1.5, 2.25, NaN, Inf, -Inf, NA, 0.1 + 0.2, 1 / 3, 7, 7, 7),
    num_wide = sin(i) * 10^((i %% 7) - 3),
    num_constant = rep(7, 5),
    num_one = 42,
    num_few = c(3, 3, 1, 2, 2, 2, NA, 5, 5, 4),
    int_key = 1:25,
    int_ties = c(1L, 2L, 2L, 3L, 3L, 3L, NA, 90000L),
    chr_messy = c(" x", "X", "x\t", "", NA, "x", "x", "Y", "y ", "y"),
    chr_numtext = c("1", "2.5", " 3", NA, "-4e2", ".5", "7."),
    chr_key = sprintf("P%03d", 1:30),
    chr_many = rep(letters, 1:26),
    chr_same = rep("a", 4),
    date = as.Date("2024-01-01") + c(0, 10, 20, 30, 30, NA, 365, 4000),
    datetime = as.POSIXct("2024-03-01 08:30:00", tz = "UTC") + c(0, 3600, 86400, NA, 90000, 5),
    datetime_sgt = as.POSIXct("2024-03-01 08:30:00", tz = "Asia/Singapore") + c(0, 3600, 86400, NA, 90000, 5),
    datetime_sgt_midnight = as.POSIXct("2024-03-01 00:00:00", tz = "Asia/Singapore") + c(0, 86400, NA),
    factor = factor(c("a", "b", NA, "a", "c", "a", "b b")),
    ordered = factor(c("lo", "hi", NA, "lo", "mid"), levels = c("lo", "mid", "hi"), ordered = TRUE),
    num_all_inf = c(Inf, -Inf, Inf, NA),
    num_sd_overflow = c(1e-300, 1e300, 5, 6, 7),
    lgl = c(TRUE, FALSE, TRUE, NA, TRUE),
    lgl_na = rep(NA, 4),
    num_na = rep(NA_real_, 3),
    chr_na = rep(NA_character_, 3),
    zero_num = numeric(0),
    zero_chr = character(0),
    zero_date = as.Date(character(0))
  )
}

profile_source <- function(x, how, con, name) {
  df <- data.frame(c = x, stringsAsFactors = FALSE)
  switch(how,
    duckdb = {
      DBI::dbWriteTable(con, name, df, overwrite = TRUE)
      dplyr::tbl(con, name)
    },
    arrow = arrow::arrow_table(df)
  )
}

test_that("lazy column profile equals in-memory", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  fx <- lazy_fixture()
  cols <- profile_columns()
  for (nm in names(cols)) {
    for (how in c("duckdb", "arrow")) {
      x <- cols[[nm]]
      want <- sv_column_profile(x)
      if (how == "duckdb") {
        # duckdb has no stored zone (a timestamp comes back as UTC instants) and no
        # ordered enum, so those columns are compared as duckdb gives them
        if (inherits(x, "POSIXct")) attr(x, "tzone") <- "UTC"
        want <- sv_column_profile(x)
        if (is.ordered(x)) want$class <- "factor"
      }
      src <- profile_source(cols[[nm]], how, fx$con, "pc")
      got <- sv_column_profile(src, column = "c")
      expect_equal(got, want, tolerance = 1e-12, label = paste(nm, how))
    }
  }
})

test_that("lazy column profile keeps the factor class and the time zone of Arrow", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  cols <- profile_columns()
  prof <- function(x) sv_column_profile(arrow::arrow_table(data.frame(c = x)), column = "c")
  expect_identical(prof(cols$factor)$class, "factor")
  expect_identical(prof(cols$ordered)$class, "ordered")
  expect_identical(prof(cols$datetime_sgt)$stats$min, "2024-03-01 08:30:00")
  expect_identical(prof(cols$datetime_sgt_midnight)$stats$min, "2024-03-01")
  # a dataset and a query on it read the same schema
  ds <- arrow::InMemoryDataset$create(data.frame(c = cols$ordered, k = 1))
  expect_identical(sv_column_profile(ds, column = "c")$class, "ordered")
  expect_identical(sv_column_profile(dplyr::filter(ds, k == 1), column = "c")$class, "ordered")
})

test_that("lazy standard deviation does not fail where R overflows", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  fx <- lazy_fixture()
  x <- c(1e-300, 1e300, 5, 6, 7)
  expect_identical(sv_column_profile(x)$stats$sd, Inf)
  for (how in c("duckdb", "arrow")) {
    got <- sv_column_profile(profile_source(x, how, fx$con, "pc"), column = "c")
    expect_identical(got$stats$sd, Inf)
  }
  # large but not overflowing: the scaled fallback agrees with R
  y <- c(-3e153, 4e153, 1e153, 0)
  fx2 <- profile_source(y, "duckdb", fx$con, "pc")
  fin <- dplyr::rename(fx2, .sv_v = c)
  expect_equal(sv_lazy_sd_scaled(fin, min(y), max(y)), stats::sd(y), tolerance = 1e-12)
})

test_that("lazy column profile follows top_n and bins", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  fx <- lazy_fixture()
  cols <- profile_columns()
  for (nm in c("num_wide", "num_few", "chr_many", "chr_messy", "date")) {
    for (how in c("duckdb", "arrow")) {
      src <- profile_source(cols[[nm]], how, fx$con, "pc")
      for (top_n in c(2L, 5L)) {
        for (bins in c(4L, 33L)) {
          expect_equal(
            sv_column_profile(src, top_n = top_n, bins = bins, column = "c"),
            sv_column_profile(cols[[nm]], top_n = top_n, bins = bins),
            tolerance = 1e-12, label = paste(nm, how, top_n, bins)
          )
        }
      }
    }
  }
})

test_that("lazy column profile picks a column of a wider table", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  fx <- lazy_fixture()
  tb <- dplyr::tbl(fx$con, "v")
  expect_equal(sv_column_profile(tb, column = "grp"), sv_column_profile(fx$df$grp))
  expect_equal(sv_column_profile(arrow::arrow_table(fx$df), column = "id"),
               sv_column_profile(fx$df$id))
  expect_error(sv_column_profile(tb, column = "nope"), "Not in")
  # a profile run on a shared connection leaves it empty
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  p <- sv_lazy_column_profile(arrow::arrow_table(fx$df), "grp", con_env = e)
  expect_equal(p, sv_column_profile(fx$df$grp))
  expect_length(DBI::dbListTables(e$con), 0L)
})

test_that("lazy codebook equals in-memory", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  fx <- lazy_fixture()
  lazy <- sv_codebook(v = dplyr::tbl(fx$con, "v"), a = arrow::arrow_table(fx$df))
  expect_equal(lazy, sv_codebook(v = fx$df, a = fx$df), tolerance = 1e-12)
  expect_identical(lazy$rows_profiled, lazy$n)
  # one lazy table is one table, not a list of tables
  one <- sv_codebook(dplyr::tbl(fx$con, "v"))
  expect_identical(one$column, c("id", "grp"))
  expect_equal(one, sv_codebook(fx$df)[, names(one)], tolerance = 1e-12, ignore_attr = TRUE)
  # the user's connection is left as it was
  expect_identical(DBI::dbListTables(fx$con), "v")
  # progress, one call per column, across lazy tables
  seen <- character(0)
  sv_codebook(v = dplyr::tbl(fx$con, "v"), a = arrow::arrow_table(fx$df),
              progress = function(table, j, n_cols) seen <<- c(seen, sprintf("%s %d/%d", table, j, n_cols)))
  expect_identical(seen, c("v 1/2", "v 2/2", "a 1/2", "a 2/2"))
  # a lazy table in the list form, next to a data frame
  mixed <- sv_codebook(list(v = dplyr::tbl(fx$con, "v"), d = fx$df))
  expect_identical(mixed$table, c("v", "v", "d", "d"))
  expect_error(sv_codebook(1:3), "not a data frame or lazy table")
})

test_that("lazy input needs column", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  fx <- lazy_fixture()
  expect_error(sv_column_profile(dplyr::tbl(fx$con, "v")), "Give `column`")
  expect_error(sv_column_profile(arrow::arrow_table(fx$df)), "Give `column`")
})

test_that("lazy issue texts count tabs and newlines as whitespace", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  fx <- lazy_fixture()
  x <- c("a\t", "b", "c\n", " d", "e\r", "F", "f\t")
  for (how in c("duckdb", "arrow")) {
    got <- sv_column_profile(profile_source(x, how, fx$con, "pc"), column = "c")
    expect_identical(got$issues, sv_column_profile(x)$issues)
    expect_match(got$issues[1], "^5 values have leading or trailing spaces")
  }
})

# ---------------------------------------------------------------------------
# Time zones: duckdb keeps the instant, not the zone
# ---------------------------------------------------------------------------

tz_rows_df <- function(tz) {
  utc <- as.POSIXct(c(
    "2024-03-01 00:30:00",   # 08:30 in Singapore
    "2024-03-01 16:00:00",   # local midnight in Singapore
    "2024-03-01 23:59:59",
    NA,
    "2024-11-03 05:30:00",   # 01:30 EDT, the first of two 01:30 in New York
    "2024-11-03 06:30:00",   # 01:30 EST, the second
    "2024-11-03 06:00:00",   # 01:00 EST: earlier on the clock, later in time
    "2024-03-10 07:30:00",   # 03:30 EDT, after the spring-forward gap
    "2024-07-04 12:00:00.5"
  ), tz = "UTC")
  attr(utc, "tzone") <- tz
  data.frame(id = seq_along(utc), t = utc)
}

tz_row_requests <- function() {
  ops <- c("equals", "not_equals", "gt", "gte", "lt", "lte")
  vals <- c("2024-03-01 08:30:00", "2024-03-01", "2024-11-03 01:30:00", "garbage", "")
  reqs <- list()
  for (v in c("08:30", "01:30", "2024-11-03", ".5", "00:00", "03:30:00", "2024", "T", "")) {
    reqs[[length(reqs) + 1L]] <- list(filter = list(col = "t", op = "contains", val = v))
  }
  for (op in ops) for (v in vals) {
    reqs[[length(reqs) + 1L]] <- list(filter = list(col = "t", op = op, val = v))
  }
  for (dir in c("asc", "desc")) {
    reqs[[length(reqs) + 1L]] <- list(sort = list(col = "t", dir = dir))
    reqs[[length(reqs) + 1L]] <- list(sort = list(col = "t", dir = dir),
                                      filter = list(col = "t", op = "contains", val = "01:"))
  }
  lapply(reqs, function(r) c(r, list(offset = 0L, limit = 50L)))
}

test_that("Arrow time zones survive the row window: display, filters and sort", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  for (tz in c("Asia/Singapore", "America/New_York")) {
    df <- tz_rows_df(tz)
    tbl <- sv_lazy_tbl(arrow::arrow_table(df), e)
    expect_identical(attr(tbl, "sv_tz"), c(t = tz))
    for (req in tz_row_requests()) {
      expect_equal(sv_lazy_rows_window(tbl, req), sv_rows_window(df, req), tolerance = 1e-12,
                   label = paste(tz, jsonlite::toJSON(req, auto_unbox = TRUE, null = "null")))
    }
  }

  sgt <- tz_rows_df("Asia/Singapore")
  w <- sv_lazy_rows_window(sv_lazy_tbl(arrow::arrow_table(sgt), e), list(offset = 0L, limit = 3L))
  # local midnight shows as the date alone, as.character() does
  expect_identical(w$columns$t, c("2024-03-01 08:30:00", "2024-03-02", "2024-03-02 07:59:59"))
  hit <- sv_lazy_rows_window(
    sv_lazy_tbl(arrow::arrow_table(sgt), e),
    list(filter = list(col = "t", op = "contains", val = "08:30"), offset = 0L, limit = 10L)
  )
  expect_identical(hit$row_ids, 0L)

  # a sort is by instant, not by the clock text: 01:00 EST comes between the two 01:30
  ny <- tz_rows_df("America/New_York")
  s <- sv_lazy_rows_window(sv_lazy_tbl(arrow::arrow_table(ny), e),
                           list(sort = list(col = "t", dir = "asc"), filter = list(col = "t", op = "contains", val = "01:"),
                                offset = 0L, limit = 10L))
  expect_identical(s$row_ids, c(4L, 6L, 5L))
  expect_identical(s$columns$t, c("2024-11-03 01:30:00", "2024-11-03 01:00:00", "2024-11-03 01:30:00"))
})

test_that("a duckdb timestamp has no stored zone and is shown as UTC", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("stringr")
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  con <- sv_lazy_con(e)
  df <- tz_rows_df("America/New_York")
  DBI::dbWriteTable(con, "tzd", df)
  tbl <- sv_lazy_tbl(dplyr::tbl(con, "tzd"), e)
  expect_null(attr(tbl, "sv_tz"))
  utc <- df
  attr(utc$t, "tzone") <- "UTC"
  for (req in tz_row_requests()) {
    expect_equal(sv_lazy_rows_window(tbl, req), sv_rows_window(utc, req), tolerance = 1e-12,
                 label = jsonlite::toJSON(req, auto_unbox = TRUE, null = "null"))
  }
})

test_that("the SQL text of a timestamp equals as.character() of the POSIXct", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  e <- sv_lazy_env()
  withr::defer(sv_lazy_close(e))
  set.seed(7)
  for (tz in c("Asia/Singapore", "America/New_York", "Europe/London", "UTC")) {
    t <- c(as.numeric(as.POSIXct("1950-01-01", tz = "UTC")) + round(runif(150, 0, 2.2e9)),
           as.numeric(as.POSIXct("2024-11-03 04:30:00", tz = "UTC")) + seq(0, 14400, by = 900),
           as.numeric(as.POSIXct("2024-03-01", tz = tz)) + c(0, 86400, 0.5, 0.123456), -1e9 + 0.5, NA)
    x <- as.POSIXct(t, origin = "1970-01-01", tz = tz)
    tb <- sv_lazy_tbl(arrow::arrow_table(data.frame(c = x)), e)
    got <- dplyr::collect(dplyr::mutate(tb, .t = !!sv_lazy_tz_text_expr(rlang::sym("c"), tz)))$.t
    want <- as.character(x)
    want[is.na(x)] <- NA_character_
    expect_identical(got, want, label = tz)
    # an expression narrowed to the data's own range gives the same text
    narrow <- dplyr::collect(dplyr::mutate(
      tb, .t = !!sv_lazy_tz_text_expr(rlang::sym("c"), tz, sv_lazy_us_range(tb, "c"))
    ))$.t
    expect_identical(narrow, want, label = paste(tz, "narrow"))
  }
  # one segment, and a range that straddles a single transition
  ny <- as.POSIXct(c("2024-01-10 12:00:00", "2024-01-11 01:30:00"), tz = "America/New_York")
  edge <- list(ny, as.POSIXct(c("2024-03-10 06:59:59", "2024-03-10 07:00:00"), tz = "UTC") |>
                 (\(v) { attr(v, "tzone") <- "America/New_York"; v })())
  for (x in edge) {
    tb <- sv_lazy_tbl(arrow::arrow_table(data.frame(c = x)), e)
    r <- sv_lazy_us_range(tb, "c")
    got <- dplyr::collect(dplyr::mutate(tb, .t = !!sv_lazy_tz_text_expr(rlang::sym("c"), "America/New_York", r)))$.t
    expect_identical(got, as.character(x))
  }
})

test_that("the lazy join check shows and compares Arrow time zones as R does", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  skip_if_not_installed("stringr")
  fx <- lazy_fixture()
  tz <- "Asia/Singapore"
  k <- as.POSIXct(c("2024-03-01 08:30:00", "2024-03-01 09:30:00", "2024-03-02 00:00:00", "2024-03-03 10:00:00"), tz = tz)
  x <- data.frame(k = k, v = 1:4)
  # the same instants in the same zone, one missing: both sides keep the zone
  y <- data.frame(k = k[c(1, 2)], w = 1:2)
  want <- sv_join_diagnostics(x, y, "k", sample_n = 5L)
  expect_identical(want$unmatched_x, c("2024-03-02", "2024-03-03 10:00:00"))
  for (how in c("df", "arrow")) {
    got <- sv_join_diagnostics(join_side(x, "arrow", fx$con, "jx"), join_side(y, how, fx$con, "jy"),
                               "k", sample_n = 5L)
    expect_equal(got, want, tolerance = 1e-12, label = how)
  }
  # keys of different types are compared as the text R gives for the time
  ychr <- data.frame(k = c("2024-03-01 08:30:00", "2024-03-02", "zzz"), w = 1:3)
  want_chr <- sv_join_diagnostics(x, ychr, "k")
  expect_equal(want_chr$matched_x, 2L)
  for (how in c("df", "duckdb", "arrow")) {
    got <- sv_join_diagnostics(join_side(x, "arrow", fx$con, "jx"), join_side(ychr, how, fx$con, "jy"), "k")
    expect_equal(got, want_chr, tolerance = 1e-12, label = how)
  }
  got <- sv_join_diagnostics(join_side(ychr, "duckdb", fx$con, "jc"), join_side(x, "arrow", fx$con, "jx"), "k")
  expect_equal(got, sv_join_diagnostics(ychr, x, "k"), tolerance = 1e-12)
})

test_that("a direct lazy codebook row closes the connection it opened", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  fx <- lazy_fixture()
  orig <- sv_lazy_close
  closed <- list()
  testthat::local_mocked_bindings(sv_lazy_close = function(con_env) {
    closed[[length(closed) + 1L]] <<- !is.null(con_env$con)
    orig(con_env)
  })
  row <- sv_codebook_row("a", "grp", 2, list(tbl = arrow::arrow_table(fx$df), column = "grp"), 5)
  expect_equal(row$n, 120)
  # one close, and it found an open connection (the arrow table needed one)
  expect_identical(closed, list(TRUE))
})

test_that("sv_codebook shares one private connection and always closes it", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("arrow")
  fx <- lazy_fixture()
  orig_close <- sv_lazy_close
  orig_con <- sv_lazy_con
  orig_env <- sv_lazy_env
  envs <- list()
  cons <- list()
  closes <- 0L
  testthat::local_mocked_bindings(
    sv_lazy_env = function() {
      e <- orig_env()
      envs[[length(envs) + 1L]] <<- e
      e
    },
    sv_lazy_con = function(con_env) {
      con <- orig_con(con_env)
      cons[[length(cons) + 1L]] <<- con
      con
    },
    sv_lazy_close = function(con_env) {
      closes <<- closes + 1L
      orig_close(con_env)
    }
  )
  a <- arrow::arrow_table(fx$df)
  b <- arrow::arrow_table(fx$df)
  sv_codebook(a = a, b = b)
  # one env for the whole call, one connection reused for every column of both tables
  expect_length(envs, 1L)
  expect_gt(length(cons), 1L)
  expect_true(all(vapply(cons, identical, logical(1), cons[[1]])))
  expect_identical(closes, 1L)
  expect_null(envs[[1]]$con)

  # and on an error halfway through
  envs <- list(); cons <- list(); closes <- 0L
  expect_error(
    sv_codebook(a = a, b = b, progress = function(table, j, n_cols) if (table == "b") stop("boom")),
    "boom")
  expect_length(envs, 1L)
  expect_gt(length(cons), 0L)
  expect_identical(closes, 1L)
  expect_null(envs[[1]]$con)
})

test_that("join check on 1M-row duckdb tables is under 5 s", {
  skip_on_cran()
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # synthetic keys: ids overlap by 80%, with repeats, a text key and a few NAs
  DBI::dbExecute(con, "CREATE TABLE big_x AS SELECT CAST(range AS BIGINT) AS id,
    'k' || CAST(range % 250000 AS VARCHAR) AS code,
    CASE WHEN range % 1000 = 0 THEN NULL ELSE range % 97 END AS v
    FROM range(1000000)")
  DBI::dbExecute(con, "CREATE TABLE big_y AS SELECT CAST(range + 200000 AS BIGINT) AS id,
    'k' || CAST(range % 300000 AS VARCHAR) AS code,
    range % 13 AS w
    FROM range(1000000)")
  x <- dplyr::tbl(con, "big_x")
  y <- dplyr::tbl(con, "big_y")
  elapsed <- system.time(
    res_id <- sv_join_diagnostics(x, y, by = "id", x_name = "big_x", y_name = "big_y")
  )[["elapsed"]]
  elapsed_code <- system.time(
    res_code <- sv_join_diagnostics(x, y, by = "code", x_name = "big_x", y_name = "big_y")
  )[["elapsed"]]
  message(sprintf("join check, 1M x 1M: id %.2f s, code %.2f s", elapsed, elapsed_code))
  expect_identical(res_id$n_x, 1000000L)
  expect_identical(res_id$n_y, 1000000L)
  expect_identical(res_id$matched_x, 800000L)
  expect_lt(elapsed, 5)
  expect_lt(elapsed_code, 5)
})

test_that("BIGINT, HUGEINT and DECIMAL columns work in the join check, profile and row window", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # duckdb hands a BIGINT to R as a double, but dbplyr's is.nan() would PRINTF it
  DBI::dbExecute(con, "CREATE TABLE ints AS SELECT CAST(range AS BIGINT) AS a,
    CAST(range AS HUGEINT) AS b, CAST(range AS DECIMAL(10,2)) AS d FROM range(25)")
  tb <- dplyr::tbl(con, "ints")
  df <- dplyr::collect(tb)
  for (cn in c("a", "b", "d")) {
    expect_equal(sv_join_diagnostics(tb, tb, by = cn)[c("n_x", "matched_x", "distinct_x")],
                 sv_join_diagnostics(df, df, by = cn)[c("n_x", "matched_x", "distinct_x")], tolerance = 1e-12)
    expect_equal(sv_column_profile(tb, column = cn), sv_column_profile(df[[cn]]), tolerance = 1e-12)
    for (op in c("contains", "gt", "equals")) {
      req <- list(offset = 0L, limit = 30L, sort = list(col = cn, dir = "desc"),
                  filter = list(col = cn, op = op, value = "2"), version = 1L)
      expect_equal(sv_lazy_rows_window(tb, req, new.env())$total, sv_rows_window(df, req, new.env())$total)
    }
  }
})
