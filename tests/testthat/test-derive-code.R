# The code twin of the derived-card builder (D1 task 7): the code the pipeline composes for a derive step,
# evaluated on the input objects, gives the rows sv_derive_card() builds. Rows are compared sorted, so
# only the set of rows has to agree (the derived card's own order is the builder's, and a database has none).

dc_need <- function(kinds) {
  if (any(kinds %in% c("duckdb", "arrow", "arrow64"))) {
    skip_if_not_installed("duckdb")
    skip_if_not_installed("dbplyr")
    skip_if_not_installed("DBI")
    skip_if_not_installed("lubridate")
  }
  if (any(kinds %in% c("arrow", "arrow64"))) skip_if_not_installed("arrow")
}

# The input objects the code is run on, the cards the builder reads, and the table meta the pipeline gets.
# `kinds`: "df", "duckdb", "arrow" or "arrow64" (an Arrow table whose columns named in `int64` are int64).
dc_fixture <- function(tables, kinds, int64 = character(), env = parent.frame()) {
  dc_need(kinds)
  con_env <- sv_lazy_env()
  withr::defer(sv_lazy_close(con_env), envir = env)
  con <- NULL
  objs <- list()
  cards <- list()
  meta <- list()
  for (i in seq_along(tables)) {
    nm <- names(tables)[i]
    df <- tables[[i]]
    kind <- kinds[[i]]
    obj <- switch(kind,
      df = df,
      duckdb = {
        if (is.null(con)) {
          con <- DBI::dbConnect(duckdb::duckdb())
          withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
        }
        DBI::dbWriteTable(con, nm, df)
        dplyr::tbl(con, nm)
      },
      arrow = arrow::arrow_table(df),
      arrow64 = {
        tab <- arrow::arrow_table(df)
        for (cn in intersect(int64, names(df))) tab[[cn]] <- tab[[cn]]$cast(arrow::int64())
        tab
      })
    objs[[nm]] <- obj
    cards[[nm]] <- sv_normalize(obj, name = nm)
    meta[[nm]] <- list(lazy = switch(kind, df = NULL, arrow64 = "arrow", kind), codeRef = nm,
                       kinds = lapply(df, sv_key_kind))
  }
  list(objs = objs, cards = cards, meta = meta, con_env = con_env)
}

dc_json <- function(x) jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null", digits = NA)

# The card sv_derive_card() builds; `extra` are derived cards already built (inputs of a later one).
dc_card <- function(fx, op, inputs, args, extra = list()) {
  store <- sv_card_store(unname(c(fx$cards, extra)))
  sv_derive_card(list(op = op, inputs = as.list(inputs), args = args), store, fx$con_env)
}

# The rows the builder holds for the card (the collected source for a lazy card).
dc_rows <- function(fx, card) {
  if (sv_card_is_lazy(card)) dplyr::collect(sv_lazy_tbl(card$source, fx$con_env, card$id)) else card$data
}

dc_norm <- function(df) {
  df <- as.data.frame(dplyr::collect(df), stringsAsFactors = FALSE)
  df <- dplyr::arrange(df, dplyr::across(dplyr::everything()))
  rownames(df) <- NULL
  df
}

# Compose each chain of derived cards (a list of cards, the last one the one asked for) in node.
dc_compose <- function(fx, chains) {
  step <- function(card) {
    d <- card$derived
    list(kind = "derive", key = as.character(dc_json(list("derive", d$op, d$inputs, d$args))), table = card$name,
         op = d$op, inputs = as.list(d$inputs), args = d$args)
  }
  groups <- unname(lapply(chains, function(ch) unname(lapply(ch, step))))
  run_pipeline_js(sprintf("
    const groups = %s;
    out = groups.map(function (steps) {
      const p = new P.Pipeline();
      p.setPipe('|>');
      p.setTables(%s);
      steps.forEach(function (s) { p.add(s); });
      return { code: p.compose(), kind: p.lazyKind(steps[steps.length - 1].table) };
    });", dc_json(groups), dc_json(fx$meta)))
}

dc_eval <- function(fx, code, name) {
  env <- list2env(fx$objs, parent = globalenv())
  eval(parse(text = code), env)
  get(name, env)
}

# Evaluate the composed code and compare it with the builder's rows. No collect() in a derive assignment,
# except the SUPP match, which reads its rows inside one local() block.
dc_expect <- function(fx, res, card, info, supp = FALSE) {
  expect_parses(res$code, info)
  if (!supp) expect_false(grepl("collect(", res$code, fixed = TRUE), info = info)
  got <- dc_eval(fx, res$code, card$name)
  expect_equal(dc_norm(got), dc_norm(dc_rows(fx, card)), tolerance = 1e-12, info = info)
}

dc_input_kinds <- list(c("df", "df"), c("duckdb", "duckdb"), c("arrow", "arrow"), c("df", "duckdb"), c("arrow", "df"))

dc_rule_args <- function(rule, side, by = list(list(x = "id", y = "id"))) list(by = by, side = side, rule = rule)

test_that("unmatched without a rule: code equals the builder, NA matching NA, on every input kind", {
  x <- data.frame(USUBJID = c("a", "b", "b", "z", NA, "q"), term = letters[1:6], stringsAsFactors = FALSE)
  y <- data.frame(USUBJID = c("a", "b", "c", NA), site = 1:4, stringsAsFactors = FALSE)
  for (ik in dc_input_kinds) {
    fx <- dc_fixture(list(x = x, y = y), ik)
    cards <- list()
    for (side in c("x", "y")) {
      cards[[side]] <- dc_card(fx, "unmatched", c("x", "y"), list(by = list(list(x = "USUBJID", y = "USUBJID")), side = side))
    }
    res <- dc_compose(fx, lapply(cards, list))
    expect_gt(nrow(dc_rows(fx, cards[[1]])), 0)
    for (side in c("x", "y")) {
      info <- paste(paste(ik, collapse = "/"), side)
      dc_expect(fx, res[[match(side, names(cards))]], cards[[side]], info)
    }
    if (identical(ik, c("arrow", "arrow"))) expect_identical(res[[1]]$kind, "arrow")
    if (identical(ik, c("duckdb", "duckdb"))) expect_identical(res[[1]]$kind, "duckdb")
    if (identical(ik, c("df", "df"))) expect_null(res[[1]]$kind)
  }
})

test_that("a non-syntactic key column and several keys give the builder's rows", {
  x <- data.frame(id = c(1, 1, 2, NA, 3), v = 1:5, stringsAsFactors = FALSE)
  x[["my key"]] <- c("a", "b", "a", NA, "c")
  y <- data.frame(id = c(1, 2, NA, 4), stringsAsFactors = FALSE)
  y[["their key"]] <- c("a", "a", NA, "d")
  by <- list(list(x = "my key", y = "their key"), list(x = "id", y = "id"))
  for (ik in dc_input_kinds[1:2]) {
    fx <- dc_fixture(list(x = x, y = y), ik)
    for (side in c("x", "y")) {
      card <- dc_card(fx, "unmatched", c("x", "y"), list(by = by, side = side))
      res <- dc_compose(fx, list(list(card)))[[1]]
      expect_match(res$code, '"my key"', fixed = TRUE)
      dc_expect(fx, res, card, paste(paste(ik, collapse = "/"), side))
    }
  }
})

test_that("with a date rule, unmatched and outside_window code equal the builder, both sides, every input kind", {
  for (kind in c("Date", "date-time", "numeric")) {
    t <- rule_tables(kind, 7)
    kinds_to_run <- if (kind == "Date") dc_input_kinds else dc_input_kinds[1:2]
    for (ik in kinds_to_run) {
      fx <- dc_fixture(list(x = t$x, y = t$y), ik)
      for (op in c("unmatched", "outside_window")) {
        cards <- list()
        infos <- character()
        for (rule in rule_cases()) {
          for (side in c("x", "y")) {
            cards[[length(cards) + 1L]] <- dc_card(fx, op, c("x", "y"), dc_rule_args(rule, side))
            infos <- c(infos, paste(kind, paste(ik, collapse = "/"), op, rule$shape, side, length(cards)))
          }
        }
        res <- dc_compose(fx, lapply(cards, list))
        # a broken code that returned nothing on both sides must not pass: the cases hold rows
        n_rows <- vapply(cards, function(cd) nrow(dc_rows(fx, cd)), 1)
        expect_gt(sum(n_rows), 0, label = paste(kind, paste(ik, collapse = "/"), op))
        for (i in seq_along(cards)) {
          dc_expect(fx, res[[i]], cards[[i]], infos[i])
          if (ik[1] == "arrow" && ik[2] == "arrow") expect_identical(res[[i]]$kind, "duckdb", info = infos[i])
        }
      }
    }
  }
})

test_that("an Arrow input with no rule stays Arrow, and a rule on it moves to duckdb", {
  t <- rule_tables("Date", 3)
  fx <- dc_fixture(list(x = t$x, y = t$y), c("arrow", "arrow"))
  none <- dc_card(fx, "unmatched", c("x", "y"), list(by = list(list(x = "id", y = "id")), side = "x"))
  ruled <- dc_card(fx, "unmatched", c("x", "y"), dc_rule_args(rule_cases()[[1]], "x"))
  res <- dc_compose(fx, list(list(none), list(ruled)))
  expect_identical(res[[1]]$kind, "arrow")
  expect_identical(res[[2]]$kind, "duckdb")
  expect_match(res[[1]]$code, 'na_matches = "na"', fixed = TRUE)
  expect_match(res[[2]]$code, 'na_matches = "never"', fixed = TRUE)
})

test_that("a derived-of-derived chain evaluates in order and equals the builder", {
  x <- data.frame(id = c(1:6, NA), v = 1:7)
  y <- data.frame(id = c(1:3, NA))
  z <- data.frame(id = c(4, 5))
  for (ik in list(c("df", "df", "df"), c("duckdb", "duckdb", "duckdb"))) {
    fx <- dc_fixture(list(x = x, y = y, z = z), ik)
    c1 <- dc_card(fx, "unmatched", c("x", "y"), list(by = list(list(x = "id", y = "id")), side = "x"))
    c2 <- dc_card(fx, "unmatched", c(c1$name, "z"), list(by = list(list(x = "id", y = "id")), side = "x"),
                  extra = list(c1))
    res <- dc_compose(fx, list(list(c1, c2)))[[1]]
    expect_parses(res$code)
    expect_false(grepl("collect(", res$code, fixed = TRUE))
    env <- list2env(fx$objs, parent = globalenv())
    eval(parse(text = res$code), env)
    info <- paste(ik, collapse = "/")
    expect_equal(dc_norm(get(c1$name, env)), dc_norm(dc_rows(fx, c1)), info = info)
    expect_equal(dc_norm(get(c2$name, env)), dc_norm(dc_rows(fx, c2)), info = info)
  }
})

# SUPP: the orphan and bad-IDVARVAL rows by the TEXT-key match of Task 2
dc_supp_tables <- function(dbl) {
  f <- sv_cdisc_fixtures()
  u <- f$ae$USUBJID
  ae <- f$ae
  if (dbl) ae$AESEQ <- c(1, 2, 2.5, 4)
  mk <- function(rd, usubjid, idvar, idvarval, qnam) {
    data.frame(STUDYID = "SV-001", RDOMAIN = rd, USUBJID = usubjid, IDVAR = idvar, IDVARVAL = idvarval,
               QNAM = qnam, QLABEL = qnam, QVAL = "Y", stringsAsFactors = FALSE)
  }
  supp <- rbind(
    mk("AE", u[1], "AESEQ", "1", "Q1"),
    mk("AE", u[2], "AESEQ", "99", "Q2"),
    mk("AE", u[3], "AESEQ", " 3 ", "Q3"),
    mk("AE", u[3], "AESEQ", "2.5", "Q3b"),
    mk("AE", u[2], "AESEQ", "2.0", "Q3c"),
    mk("AE", u[1], "AESEQ", "x", "Q4"),
    mk("AE", u[1], "AESEQ", "1e999", "Q5"),
    mk("AE", u[1], "AESEQ", "NA", "Q5b"),
    mk("AE", u[4], "AESEQ", "4.0", "Q5c"),
    mk("AE", "SV-001-999", "", "", "Q6"),
    mk("AE", u[2], "", "", "Q7"),
    mk("AE", u[2], NA_character_, NA_character_, "Q7b"),
    mk("CM", u[1], "CMSEQ", "1", "Q8"))
  list(ae = ae, supp = supp)
}

test_that("supp_orphans and supp_bad_idvarval code equal the builder: text keys, NA strings, double keys", {
  for (dbl in c(FALSE, TRUE)) {
    t <- dc_supp_tables(dbl)
    for (ik in list(c("df", "df"), c("duckdb", "duckdb"), c("arrow", "arrow"), c("df", "duckdb"), c("duckdb", "df"))) {
      fx <- dc_fixture(list(ae = t$ae, suppae = t$supp), ik)
      cards <- lapply(c("supp_orphans", "supp_bad_idvarval"), function(op) {
        dc_card(fx, op, c("ae", "suppae"), list(rdomain = "AE"))
      })
      expect_true(nrow(cards[[1]]$data) > 0)
      res <- dc_compose(fx, lapply(cards, list))
      for (i in 1:2) {
        dc_expect(fx, res[[i]], cards[[i]], paste("dbl", dbl, paste(ik, collapse = "/"), i), supp = TRUE)
        expect_null(res[[i]]$kind)
      }
    }
  }
})

test_that("supp code handles NA subject keys in a lazy parent and an Arrow int64 IDVAR key", {
  t <- dc_supp_tables(FALSE)
  ae <- t$ae
  ae$USUBJID[2] <- NA
  for (ik in list(c("df", "df"), c("duckdb", "duckdb"))) {
    fx <- dc_fixture(list(ae = ae, suppae = t$supp), ik)
    for (op in c("supp_orphans", "supp_bad_idvarval")) {
      card <- dc_card(fx, op, c("ae", "suppae"), list(rdomain = "AE"))
      res <- dc_compose(fx, list(list(card)))[[1]]
      dc_expect(fx, res, card, paste("NA subject", paste(ik, collapse = "/"), op), supp = TRUE)
    }
  }
  fx <- dc_fixture(list(ae = t$ae, suppae = t$supp), c("arrow64", "arrow"), int64 = "AESEQ")
  for (op in c("supp_orphans", "supp_bad_idvarval")) {
    card <- dc_card(fx, op, c("ae", "suppae"), list(rdomain = "AE"))
    res <- dc_compose(fx, list(list(card)))[[1]]
    dc_expect(fx, res, card, paste("int64", op), supp = TRUE)
  }
})

test_that("a derive step and a chain on the same data frame use different copy_to names, and the rows stay intact", {
  x <- data.frame(id = c(1:6, NA), v = 1:7)
  y <- data.frame(id = c(1:3, NA), w = 4:1)
  fx <- dc_fixture(list(x = x, y = y), c("df", "duckdb"))
  card <- dc_card(fx, "unmatched", c("x", "y"), list(by = list(list(x = "id", y = "id")), side = "x"))
  step <- list(kind = "derive", key = "k1", table = card$name, op = "unmatched", inputs = list("x", "y"),
               args = card$derived$args)
  join <- list(kind = "join", table = "x", right = "y", type = "left_join", by = list(list(left = "id", right = "id")))
  filt <- list(kind = "filter", table = "x", conds = list("v > 3"), condCols = list("v"))
  res <- run_pipeline_js(sprintf("
    const p = new P.Pipeline();
    p.setPipe('|>');
    p.setTables(%s);
    p.add(%s); p.add(%s); p.add(%s);
    out = p.compose();", dc_json(fx$meta), dc_json(step), dc_json(filt), dc_json(join)))
  names_used <- regmatches(res, gregexpr('name = "[^"]+"', res))[[1]]
  expect_length(names_used, 2L)
  expect_false(anyDuplicated(names_used) > 0)
  expect_parses(res)
  env <- list2env(fx$objs, parent = globalenv())
  eval(parse(text = res), env)
  expect_equal(dc_norm(get(card$name, env)), dc_norm(dc_rows(fx, card)), tolerance = 1e-12)
})

test_that("building a SUPP card on an Arrow parent leaves no temp table on the connection", {
  t <- dc_supp_tables(FALSE)
  fx <- dc_fixture(list(ae = t$ae, suppae = t$supp), c("arrow", "arrow"))
  dc_card(fx, "supp_orphans", c("ae", "suppae"), list(rdomain = "AE"))
  con <- fx$con_env$con
  before <- DBI::dbListTables(con)
  for (i in 1:3) dc_card(fx, "supp_orphans", c("ae", "suppae"), list(rdomain = "AE"))
  expect_setequal(DBI::dbListTables(con), before)
  expect_false(any(grepl("sv_supp_keys_|dbplyr_", DBI::dbListTables(con))))
})

# ---- stack (D2 task 4): the pipeline's code rebuilds the stacked card ----

dc_stack_tables <- function() {
  a <- data.frame(id = 1:4, age = c(34, 51, NA, 60), sex = c("F", "M", "F", NA),
                  visit = as.Date(c("2024-01-02", "2024-02-03", NA, "2024-03-04")),
                  wt = c(60.5, 72, 80.25, NA), flag = c(TRUE, FALSE, NA, TRUE), stringsAsFactors = FALSE)
  a[["my col"]] <- c(1.5, 2, NA, 4)
  attr(a$age, "label") <- "Age \"in\" years"
  b <- data.frame(id = c("5", "6", "7x"), age = 1:3, sex = c("M", "M", "F"),
                  visit = as.POSIXct(c("2024-04-01 08:30:00", "2024-04-02 00:00:00", NA), tz = "UTC"),
                  note = c("n1", NA, "n3"), Flag = c(TRUE, NA, FALSE), stringsAsFactors = FALSE)
  b[["my col"]] <- c("u", "v", NA)
  c3 <- data.frame(id = 8:9, age = c(70, 71), sex = c("F", "F"),
                   visit = as.Date(c("2024-05-01", "2024-05-02")), note = c("a", "b"),
                   flag = c(FALSE, FALSE), grp = factor(c("g1", "g2")), stringsAsFactors = FALSE)
  list(w1 = a, `wave 2` = b, w3 = c3)
}

test_that("stack code rebuilds the card", {
  tb <- dc_stack_tables()
  fixes <- list(list(column = "Flag", action = "rename", to = "flag"),
                list(column = "age", action = "cast", to = "chr"))
  sets <- list(c("df", "df", "df"), c("duckdb", "duckdb", "duckdb"), c("arrow", "arrow", "arrow"),
               c("df", "duckdb", "df"), c("arrow", "df", "duckdb"), c("arrow", "df", "df"))
  for (ik in sets) {
    info <- paste(ik, collapse = "/")
    fx <- dc_fixture(tb, ik)
    card <- dc_card(fx, "stack", names(tb), list(fixes = fixes))
    res <- dc_compose(fx, list(list(card)))[[1]]
    dc_expect(fx, res, card, info)
    if (all(ik == "df")) {
      expect_null(res$kind)
      got <- dc_eval(fx, res$code, card$name)
      expect_identical(attr(got$age, "label"), attr(card$data$age, "label"), info = info)
      expect_equal(got, card$data, info = info)
    } else {
      expect_identical(res$kind, "duckdb", info = info)
    }
  }
})

test_that("stack code with two inputs and no fixes rebuilds the card", {
  tb <- dc_stack_tables()[c(1, 3)]
  for (ik in list(c("df", "df"), c("duckdb", "arrow"))) {
    fx <- dc_fixture(tb, ik)
    card <- dc_card(fx, "stack", names(tb), list())
    dc_expect(fx, dc_compose(fx, list(list(card)))[[1]], card, paste(ik, collapse = "/"))
  }
})
