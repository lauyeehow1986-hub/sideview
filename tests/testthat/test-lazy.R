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
    want <- sv_column_profile(cols[[nm]])
    for (how in c("duckdb", "arrow")) {
      src <- profile_source(cols[[nm]], how, fx$con, "pc")
      got <- sv_column_profile(src, column = "c")
      expect_equal(got, want, tolerance = 1e-12, label = paste(nm, how))
    }
  }
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
