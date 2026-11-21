# Tests for the stack column check: sv_stack_check(), sv_stack_plan(), sv_stack_cast(), sv_stack_type().

stack_pair <- function(a, b, nm = "V") {
  t1 <- data.frame(a, stringsAsFactors = FALSE); names(t1) <- nm
  t2 <- data.frame(b, stringsAsFactors = FALSE); names(t2) <- nm
  sv_stack_plan(list(wave1 = t1, wave2 = t2))$columns[[1]]
}

test_that("types and the default target follow the cast order", {
  d <- as.Date("2024-01-01"); p <- as.POSIXct("2024-01-01 10:00:00", tz = "UTC")
  expect_equal(stack_pair(TRUE, 1L)$target, "int")
  expect_equal(stack_pair(1L, 1.5)$target, "num")
  expect_equal(stack_pair(1.5, "a")$target, "chr")
  expect_equal(stack_pair(d, "a")$target, "chr")
  expect_equal(stack_pair(d, p)$target, "dttm")
  expect_equal(stack_pair(factor("x"), "a")$target, "chr")
  expect_equal(stack_pair(TRUE, "a")$target, "chr")
  f <- stack_pair(factor(c("x", "y")), factor(c("y", "z")))
  expect_equal(f$target, "fct")
  expect_equal(f$levels, c("x", "y", "z"))
  expect_true(f$levels_differ)
  expect_equal(stack_pair(factor("x", ordered = TRUE), factor("x"))$target, "chr")
  expect_equal(sv_stack_type(Sys.time()), "dttm")
  expect_equal(sv_stack_type(factor("a", ordered = TRUE)), "fct")
  expect_equal(attr(sv_stack_type(as.difftime(1, units = "secs")), "class1"), "difftime")
})

test_that("offered targets come from the cast table", {
  expect_equal(stack_pair(1.5, "a")$targets, c("chr", "num"))
  expect_equal(stack_pair(as.Date("2024-01-01"), 1.5)$targets, "chr")
  t1 <- data.frame(V = TRUE); t2 <- data.frame(V = 1L); t3 <- data.frame(V = 1.5)
  col <- sv_stack_plan(list(a = t1, b = t2, c = t3))$columns[[1]]
  expect_equal(col$targets, c("num", "chr", "lgl", "int"))
})

test_that("casts convert exactly or give NA, and NA is counted", {
  nas <- function(x, r) sum(is.na(r) & !is.na(x))
  x <- c("12", " 12 ", "\t12", "1e5", "0x1A", "Inf", "", "1e999", NA)
  r <- sv_stack_cast(x, "chr", "num")
  expect_equal(r, c(12, 12, 12, 1e5, NA, NA, NA, NA, NA))
  expect_equal(nas(x, r), 4L)  # the input NA was already missing
  y <- c(1, 2.5, NaN, 3e9, NA)
  r <- sv_stack_cast(y, "num", "int")
  expect_equal(r, c(1L, NA, NA, NA, NA))
  expect_equal(nas(y, r), 2L)
  z <- c(0L, 1L, 2L)
  r <- sv_stack_cast(z, "int", "lgl")
  expect_equal(r, c(FALSE, TRUE, NA))
  expect_equal(nas(z, r), 1L)
  expect_equal(sv_stack_cast(as.POSIXct("2024-01-01", tz = "UTC"), "dttm", "chr", "UTC"), "2024-01-01 00:00:00")
  r <- sv_stack_cast(as.Date("2024-01-01"), "date", "dttm")
  expect_equal(as.numeric(r), as.numeric(as.POSIXct("2024-01-01", tz = "UTC")))
  expect_equal(sv_stack_cast(c("2024-02-30", "2024-02-29"), "chr", "date"), as.Date(c(NA, "2024-02-29")))
  expect_equal(sv_stack_cast(c("TRUE", "true"), "chr", "lgl"), c(TRUE, NA))
})

test_that("near-miss is flagged, never merged, and the rename fix merges it", {
  w1 <- data.frame(AGE = c(1, 2)); w2 <- data.frame(Age = c("3", "4"))
  p <- sv_stack_plan(list(wave1 = w1, wave2 = w2))
  expect_length(p$columns, 2L)
  expect_equal(p$columns[[2]]$status, "near-miss for AGE? (case)")
  expect_equal(p$columns[[2]]$near_miss_of, "AGE")
  chk <- sv_stack_check(w1, w2, rename = c(Age = "AGE"))
  expect_length(chk$columns, 1L)
  expect_equal(chk$columns[[1]]$name, "AGE")
  expect_equal(chk$columns[[1]]$target, "chr")  # num + chr
  expect_equal(chk$columns[[1]]$rename_from, c(NA, "Age"))
  expect_error(sv_stack_check(w1, w2, rename = c(Age = "RACE")), "is not a near-miss of")
  # names that clash inside one input are not a near-miss
  w3 <- data.frame(AGE = 1, Age = 2)
  expect_equal(sv_stack_plan(list(a = w3, b = w1))$columns[[2]]$near_miss_of, NA_character_)
})

test_that("labels: first kept, differences listed", {
  w1 <- data.frame(RACE = "a"); attr(w1$RACE, "label") <- "Race"
  w2 <- data.frame(RACE = "b"); attr(w2$RACE, "label") <- "RACE"
  p <- sv_stack_plan(list(wave1 = w1, wave2 = w2))
  expect_equal(p$kept_labels[["RACE"]], "Race")
  expect_equal(p$columns[[1]]$status, "label differs (wave1 label kept)")
})

test_that("a column in some inputs only", {
  w1 <- data.frame(A = 1, B = 2); w2 <- data.frame(A = 3); w3 <- data.frame(A = 4, B = 5)
  p <- sv_stack_plan(list(wave1 = w1, wave2 = w2))
  b <- p$columns[[2]]
  expect_equal(b$status, "only in wave1 (NA in wave2)")
  expect_equal(sum(b$na, na.rm = TRUE), 0)
  p3 <- sv_stack_plan(list(wave1 = w1, wave2 = w2, wave3 = w3))
  expect_equal(p3$columns[[2]]$status, "only in wave1, wave3 (NA in wave2)")
  expect_equal(p3$n_rows, 3L)
  expect_equal(p3$id_col, "source")
})

test_that("id column avoids an existing source column", {
  w1 <- data.frame(source = 1); w2 <- data.frame(source = 2)
  expect_equal(sv_stack_plan(list(a = w1, b = w2))$id_col, "source_2")
})

test_that("status text and summary lines", {
  wave1 <- data.frame(AGE = c(1, 2), N = 1L); wave2 <- data.frame(Age = c("3", "x"), N = 2.5)
  chk <- sv_stack_check(wave1, wave2, cast = c(N = "chr"))
  expect_equal(chk$table$Status, c("only in wave1 (NA in wave2)", "type differs -> as.character", "near-miss for AGE? (case)"))
  chk <- sv_stack_check(wave1, wave2)
  expect_equal(chk$table$Status[2], "type differs -> as.numeric")
  wave3 <- data.frame(AGE = c("1", "z"))
  chk <- sv_stack_check(data.frame(AGE = 1), wave3)
  expect_equal(chk$table$Status, "type differs -> as.character")
  chk <- sv_stack_check(wave3, data.frame(AGE = 1), cast = c(AGE = "num"))
  expect_equal(chk$table$Status, "type differs -> as.numeric; 1 value in wave3 becomes NA")
  expect_equal(chk$text[1], "Stack 2 tables: 3 rows, 2 columns.")
  expect_equal(chk$text[2], "1 column changes type; 1 value becomes NA.")
  expect_equal(sv_say_stack_open(chk), "Open stacked card (3 rows; 1 value becomes NA)")
  chk <- sv_stack_check(wave1, wave2)
  expect_equal(chk$text[length(chk$text)], "1 near-miss name left apart.")
  expect_equal(sv_say_stack_open(chk), "Open stacked card (4 rows)")
})

test_that("bad fixes are refused", {
  w1 <- data.frame(A = 1); w2 <- data.frame(A = "x")
  expect_error(sv_stack_check(w1, w2, cast = c(ZZ = "chr")), "Not in the stack: ZZ")
  expect_error(sv_stack_check(w1, w2, cast = c(A = "lgl")), "A cannot be cast to lgl")
  expect_error(sv_stack_check(w1, w2, cast = c(A = "chr", A = "num", A = "chr")), "Too many fixes")
  wl <- data.frame(A = 1); wl$L <- list(1)
  expect_error(sv_stack_check(w1, wl), "Column L in wl is a list column; it cannot be stacked.")
})

test_that("print shows the table", {
  wave1 <- data.frame(AGE = c(1, 2), SEX = c("F", "M"))
  wave2 <- data.frame(AGE = c("3", "4"), SEX = c("F", "F"), SITE = 1:2)
  expect_snapshot(print(sv_stack_check(wave1, wave2)))
})

stack_waves <- function() {
  w1 <- data.frame(AGE = c(34, 51), RACE = c("a", "b"), stringsAsFactors = FALSE)
  attr(w1$RACE, "label") <- "Race"
  w2 <- data.frame(AGE = c("29", "x", "40"), RACE = c("c", "d", "e"), SITE = 1:3, stringsAsFactors = FALSE)
  w3 <- data.frame(AGE = 60, RACE = "f", stringsAsFactors = FALSE)
  list(wave1 = w1, wave2 = w2, wave3 = w3)
}

test_that("rows equal bind_rows and the sum of inputs", {
  w <- stack_waves()
  wave1 <- w$wave1; wave2 <- w$wave2; wave3 <- w$wave3
  res <- sv_stack(wave1, wave2, wave3)
  expect_equal(nrow(res), nrow(wave1) + nrow(wave2) + nrow(wave3))
  expect_equal(unique(res$source), c("wave1", "wave2", "wave3"))
  expect_equal(names(res), c("source", "AGE", "RACE", "SITE"))
  # AGE becomes chr (num + chr)
  exp <- dplyr::bind_rows(wave1 = dplyr::mutate(wave1, AGE = as.character(AGE)), wave2 = wave2,
                          wave3 = dplyr::mutate(wave3, AGE = as.character(AGE)), .id = "source")
  strip <- function(d) { for (n in names(d)) attr(d[[n]], "label") <- NULL; d }
  expect_equal(strip(res), strip(exp))
})

test_that("id column avoids taken names", {
  a <- data.frame(source = 1, x = 1); b <- data.frame(source = 2, source_2 = 3, x = 2)
  res <- sv_stack(a, b)
  expect_equal(names(res)[1], "source_3")
  expect_equal(res$source, c(1, 2))
  expect_equal(res$source_3, c("a", "b"))
  expect_match(sv_stack_check(a, b)$code, ".id = \"source_3\"", fixed = TRUE)
})

test_that("zero-row input and all-NA logical column", {
  a <- data.frame(V = c("x", "y"), stringsAsFactors = FALSE)
  b <- data.frame(V = logical(0))
  res <- sv_stack(a, b)
  expect_equal(nrow(res), 2L)
  expect_equal(res$V, c("x", "y"))
  chk <- sv_stack_check(a, b)
  expect_equal(chk$columns[[1]]$status, "type differs -> as.character")
  expect_equal(sum(chk$columns[[1]]$na, na.rm = TRUE), 0)
  c1 <- data.frame(V = NA); c2 <- data.frame(V = "z", stringsAsFactors = FALSE)
  expect_equal(sv_stack(c1, c2)$V, c(NA, "z"))
  expect_equal(sum(sv_stack_check(c1, c2)$columns[[1]]$na, na.rm = TRUE), 0)
  got <- eval(parse(text = sv_stack_check(a, b)$code), envir = list2env(list(a = a, b = b), parent = baseenv()))
  expect_equal(got, sv_stack(a, b))
})

test_that("labels survive in the result", {
  w <- stack_waves()
  wave1 <- w$wave1; wave2 <- w$wave2
  res <- sv_stack(wave1, wave2)
  expect_equal(attr(res$RACE, "label"), "Race")
  expect_null(attr(res$AGE, "label"))
})

test_that("in-memory code parses, runs with dplyr only and rebuilds", {
  wave1 <- stack_waves()$wave1
  wave2 <- stack_waves()$wave2
  chk <- sv_stack_check(wave1, wave2, cast = c(AGE = "chr"))
  code <- chk$code
  expect_parses(code)
  expect_false(grepl("sv_|%>%|\\|>", code))
  got <- eval(parse(text = code), envir = list2env(list(wave1 = wave1, wave2 = wave2), parent = baseenv()))
  expect_equal(got, sv_stack(wave1, wave2, check = chk))
  expect_equal(attr(got$RACE, "label"), "Race")
  expect_error(sv_stack(wave1, wave2, check = sv_stack_check(wave1, stack_waves()$wave3)), "was made for other tables")
})

test_that("code rebuilds across types, renames, zones and awkward names", {
  d <- as.Date(c("2024-01-02", NA))
  p <- as.POSIXct(c("2024-01-02 00:00:00", "2024-03-04 10:30:00"), tz = "Asia/Singapore")
  `wave 2` <- data.frame(Age = c("1", "x"), `visit date` = d, L = c(TRUE, NA),
                         stringsAsFactors = FALSE, check.names = FALSE)
  attr(`wave 2`$Age, "label") <- "Age \"quoted\" \\ café"
  wave3 <- data.frame(AGE = c(1.5, NaN), `visit date` = p, L = c("TRUE", "no"), N = c(1e5, 2.5),
                      F = factor(c("u", "v")), stringsAsFactors = FALSE, check.names = FALSE)
  env <- list2env(list(`wave 2` = `wave 2`, wave3 = wave3), parent = baseenv())
  chk <- sv_stack_check(`wave 2`, wave3, rename = c(Age = "AGE"))
  expect_parses(chk$code)
  got <- eval(parse(text = chk$code), envir = env)
  expect_equal(got, sv_stack(`wave 2`, wave3, check = chk))
  expect_equal(attr(got$AGE, "label"), "Age \"quoted\" \\ café")
  expect_equal(got$source, c("wave.2", "wave.2", "wave3", "wave3"))
  chk2 <- sv_stack_check(`wave 2`, wave3, rename = c(Age = "AGE"), cast = c(`visit date` = "chr", L = "lgl"))
  got2 <- eval(parse(text = chk2$code), envir = env)
  expect_equal(got2, sv_stack(`wave 2`, wave3, check = chk2))
})

test_that("cast code agrees with sv_stack_cast on odd values", {
  run <- function(chk, ...) eval(parse(text = chk$code), envir = list2env(list(...), parent = baseenv()))
  x <- c("12", " 12 ", "\t12", "1e5", "0x1A", "Inf", "", "1e999", "2147483648", "-3", "1.5", NA)
  a <- data.frame(V = x, stringsAsFactors = FALSE)
  for (pair in list(c("num", 1.5), c("int", 1L), c("lgl", TRUE))) {
    b <- data.frame(V = switch(pair[[1]], num = 1.5, int = 1L, lgl = TRUE))
    chk <- sv_stack_check(a, b, cast = c(V = pair[[1]]))
    expect_equal(run(chk, a = a, b = b), sv_stack(a, b, check = chk), info = pair[[1]])
    expect_gt(sum(chk$columns[[1]]$na, na.rm = TRUE), 0)
  }
  num <- data.frame(V = c(0, 1, 2, NaN, 2.5, 3e9, NA))
  for (to in c("int", "lgl", "chr")) {
    one <- data.frame(V = switch(to, int = 1L, lgl = TRUE, chr = "a", stringsAsFactors = FALSE))
    chk <- sv_stack_check(num, one, cast = c(V = to))
    expect_equal(run(chk, num = num, one = one), sv_stack(num, one, check = chk), info = to)
  }
  tt <- data.frame(V = as.POSIXct("2024-01-01 00:00:00", tz = "UTC")); dd <- data.frame(V = as.Date("2024-02-01"))
  chk <- sv_stack_check(tt, dd, cast = c(V = "chr"))
  expect_equal(run(chk, tt = tt, dd = dd)$V, c("2024-01-01 00:00:00", "2024-02-01"))
  expect_equal(run(chk, tt = tt, dd = dd), sv_stack(tt, dd, check = chk))
  chk <- sv_stack_check(dd, tt)
  expect_equal(run(chk, tt = tt, dd = dd), sv_stack(dd, tt, check = chk))
})

test_that("check validates that cast and rename are named", {
  w <- stack_waves()
  wave1 <- w$wave1; wave2 <- w$wave2
  expect_error(sv_stack_check(wave1, wave2, cast = "chr"), "`cast` must be a named character vector")
  expect_error(sv_stack_check(wave1, wave2, rename = c("AGE")), "`rename` must be a named character vector")
  expect_error(sv_stack_check(wave1, wave2, cast = c(AGE = NA)), "`cast` must be a named character vector")
})

test_that("rename direction: the name is the near-miss, the value its partner", {
  a <- data.frame(AGE = 1); b <- data.frame(Age = 2)
  chk <- sv_stack_check(a, b, rename = c(Age = "AGE"))
  expect_equal(names(sv_stack(a, b, check = chk)), c("source", "AGE"))
  # lenient: either spelling may be the one renamed; the value is the name that is kept
  expect_equal(names(sv_stack(a, b, check = sv_stack_check(a, b, rename = c(AGE = "Age")))), c("source", "Age"))
  expect_error(sv_stack_check(a, b, rename = c(Age = "RACE")), "is not a near-miss")
})

# ---- D2 task 4: the JS pipeline writes the same code as sv_stack_code() ----

# Three inputs that between them need every cast target, a rename, a missing column in each form, a kept label,
# awkward names and two zones (one with daylight saving time). `visit` and `Visit` are a near-miss pair.
stk_js_tables <- function() {
  w1 <- data.frame(A = c(TRUE, NA), B = 1:2, C = c(1.5, 2), D = as.Date(c("2024-01-02", NA)),
                   E = as.POSIXct(c("2024-01-02 03:04:05", NA), tz = "Asia/Singapore"),
                   F = c("12", "x"), G = c("7", "7.5"), H = c("TRUE", "no"), I = c("2024-01-02", "2024-13-45"),
                   J = c(1, 2.5), K = c(0L, 2L), L = as.Date(c("2024-02-03", "2024-02-04")),
                   M = as.POSIXct(c("2024-03-04 10:30:00", "2024-03-05 00:00:00"), tz = "UTC"),
                   N = factor(c("a", "b")), O = factor(c("a", "b")), only1 = c(TRUE, FALSE),
                   P = c(1, NaN), Visit = as.Date(c("2024-01-01", "2024-01-02")),
                   stringsAsFactors = FALSE)
  w1[["my col"]] <- c(1.5, NA)
  w1[["a\"b"]] <- c(1L, 2L)
  attr(w1$A, "label") <- "Flag \"quoted\" \\ café"
  w2 <- data.frame(A = 1:2, B = c(1.5, NA), C = c("a", "b"), D = c("2024-01-01", "b"),
                   E = c("2024-05-06 07:08:09", "z"), F = c(1.5, 2), G = 1:2, H = c(TRUE, NA),
                   I = as.Date(c("2024-07-08", NA)), J = 1:2, K = c(TRUE, FALSE),
                   L = as.POSIXct(c("2024-08-09 10:11:12", NA), tz = "UTC"),
                   M = as.Date(c("2024-09-10", "2024-09-11")), N = c("x", "y"), O = factor(c("c", "a")),
                   P = c(2.5, 3), visit = as.Date(c("2024-01-03", "2024-01-04")), stringsAsFactors = FALSE)
  w2[["my col"]] <- c("u", "v")
  w2[["a\"b"]] <- c(3L, 4L)
  w3 <- data.frame(A = 3L, E = as.POSIXct("2024-07-01 12:00:00", tz = "America/New_York"), P = 4L,
                   extra = c(TRUE), only3 = as.Date("2024-01-05"), stringsAsFactors = FALSE)
  list(w1 = w1, `wave 2` = w2, w3 = w3)
}

stk_js_fixes <- function() {
  list(cast = c(F = "num", G = "int", H = "lgl", I = "date", J = "int", K = "lgl", M = "date", N = "chr",
                P = "chr"),
       rename = c(visit = "Visit"))
}

# The code the browser composes for a stack step: plan, the inputs and what kind each is (NA: a data frame).
stk_js_code <- function(plan, inputs, refs, kinds) {
  meta <- stats::setNames(lapply(seq_along(inputs), function(i) {
    list(lazy = if (is.na(kinds[i])) NULL else kinds[i], codeRef = refs[i])
  }), inputs)
  res <- run_pipeline_js(sprintf("
    const p = new P.Pipeline();
    p.setTables(%s);
    out = p.deriveExpr({kind: 'derive', op: 'stack', table: 'out', inputs: %s, args: {plan: %s}});",
    dc_json_stack(meta), dc_json_stack(as.list(inputs)), dc_json_stack(plan)))
  res
}

dc_json_stack <- function(x) jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null", digits = NA)

test_that("R and JS write the same stack code", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("DBI")
  skip_if_not_installed("stringr")
  tb <- stk_js_tables()
  fx <- stk_js_fixes()
  fixes <- c(lapply(seq_along(fx$cast), function(i) list(column = names(fx$cast)[i], action = "cast", to = unname(fx$cast[[i]]))),
             lapply(seq_along(fx$rename), function(i) list(column = names(fx$rename)[i], action = "rename", to = unname(fx$rename[[i]]))))
  inputs <- names(tb)
  refs <- unname(sv_escape_ident(inputs))
  # the plans: in memory (data frames), and with a duckdb input (the lazy plan carries the time text)
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbWriteTable(con, "dk", tb[[2]])
  mixed <- list(w1 = tb[[1]], `wave 2` = dplyr::tbl(con, "dk"), w3 = tb[[3]])
  p_mem <- sv_stack_plan(tb, fixes)
  p_lazy <- sv_stack_plan(mixed, fixes)
  expect_true(any(vapply(p_lazy$columns, function(c) !is.null(c$tz_text), NA)))
  expect_true(any(vapply(p_mem$columns, function(c) !is.na(c$cast[1]), NA)))
  na <- NA_character_
  cases <- list(
    list(p_mem, c(na, na, na)),
    list(p_lazy, c("duckdb", "duckdb", "duckdb")),
    list(p_lazy, c(na, "duckdb", na)),
    list(p_lazy, c("arrow", "duckdb", na)),
    list(p_lazy, c("arrow", "arrow", "arrow")),
    list(p_lazy, c("arrow", na, na)),
    list(p_lazy, c(na, "arrow", "duckdb")),
    list(p_lazy, c("duckdb", na, "arrow")))
  for (cs in cases) {
    kinds <- cs[[2]]
    info <- paste(ifelse(is.na(kinds), "df", kinds), collapse = "/")
    want <- sv_stack_code(cs[[1]], refs, kinds)
    got <- stk_js_code(cs[[1]], inputs, refs, kinds)
    expect_identical(got$code, want$code, info = info)
    expect_identical(got$kind, if (is.na(want$kind)) NULL else want$kind, info = info)
    expect_parses(got$code, info)
  }
  # a stack of 2 whose id column is source_3, no casts, no labels
  a <- data.frame(source = 1, source_2 = 2, v = 1)
  b <- data.frame(source = 3, source_2 = 4, v = 2)
  p2 <- sv_stack_plan(list(a = a, b = b))
  expect_equal(p2$id_col, "source_3")
  expect_identical(stk_js_code(p2, c("a", "b"), c("a", "b"), c(na, na))$code,
                   sv_stack_code(p2, c("a", "b"), c(na, na))$code)
  # a lazy plan with no zone to write (all casts but time to text) has no tz_text, and still agrees
  DBI::dbWriteTable(con, "da", a)
  p3 <- sv_stack_plan(list(a = dplyr::tbl(con, "da"), b = b))
  expect_identical(stk_js_code(p3, c("a", "b"), c("a", "b"), c("duckdb", na))$code,
                   sv_stack_code(p3, c("a", "b"), c("duckdb", na))$code)
})

test_that("a stack plan is JSON that keeps the labels and the zones", {
  tb <- stk_js_tables()
  plan <- sv_stack_plan(tb)
  j <- jsonlite::fromJSON(as.character(dc_json_stack(plan)), simplifyVector = FALSE)
  expect_equal(names(j$kept_labels), "A")
  expect_equal(names(j$tz)[1], "E")
})

test_that("a check made before the tables changed is refused", {
  wave1 <- data.frame(AGE = c(34, 51), SEX = c("F", "M"))
  wave2 <- data.frame(Age = c("29", "40"), SEX = c("M", "M"))
  chk <- sv_stack_check(wave1, wave2, rename = c(Age = "AGE"))
  expect_equal(nrow(sv_stack(wave1, wave2, check = chk)), 4L)
  msg <- "was made for other data"
  wave1b <- wave1
  wave1b$AGE <- as.character(wave1b$AGE)
  expect_error(local({ wave1 <- wave1b; sv_stack(wave1, wave2, check = chk) }), msg)
  expect_error(local({ wave1 <- rbind(wave1, wave1); sv_stack(wave1, wave2, check = chk) }), msg)
  expect_error(local({ wave2$X <- 1; sv_stack(wave1, wave2, check = chk) }), msg)
  expect_error(local({ names(wave2)[1] <- "age"; sv_stack(wave1, wave2, check = chk) }), msg)
})

test_that("R and JS quote awkward names and strings the same way", {
  nms <- c("été", "a\\b", "a`b", "ok_1", ".x", ".1x", "if", "a b")
  txt <- c("a\001b", "bell\a", "bs\b", "ff\f", "vt\v", "del\x7f", "esc\x1b", "c1\u0085", "tab\t", "q\"\\")
  js <- run_pipeline_js(sprintf("out = {i: %s.map(P.ident), s: %s.map(P.str)};",
                                dc_json_stack(as.list(nms)), dc_json_stack(as.list(txt))))
  expect_equal(unlist(js$i), sv_escape_ident(nms))
  expect_equal(unlist(js$s), unname(encodeString(txt, quote = "\"")))
  # and each name reads back as itself
  q <- sv_escape_ident(nms)
  for (i in which(nms != "if")) {
    expect_identical(as.character(parse(text = q[i], keep.source = FALSE)[[1]]), nms[i])
  }
})
