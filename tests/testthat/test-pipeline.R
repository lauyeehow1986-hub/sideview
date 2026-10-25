# Tests for the browser-side composable pipeline (inst/www/sv-pipeline.js).
# The composer runs under Node; every script it produces must parse() in R and,
# for the core verbs, give the same result as hand-written dplyr.

expect_parses <- function(code, label = code) {
  expect_no_error(parse(text = code), message = label)
}

test_that("every step kind composes into code that parses", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.add({kind:'arrange', key:'a', table:'visits', cols:[{col:'visit date', desc:true}, {col:'id'}]});
    p.addJoinKey('patients', 'visits', 'patient_id', 'patient_id');
    p.addJoinKey('patients', 'visits', 'site', 'site code');
    p.add({kind:'filter', table:'patients', conds:[P.condition('age', 'gt', '50', true),
      P.condition('sex', 'in', 'F, M', false), P.condition('note', 'contains', 'a\"b\\\\c', false),
      P.condition('dose', 'is_na', '', true)], combine:'or'});
    p.add({kind:'recode', table:'patients', col:'sex', map:[{from:'f',to:'F'},{from:'female',to:'F'},{from:'NA',to:'U'}]});
    p.add({kind:'mutate', table:'patients', name:'age group', expr:'age %/% 10'});
    p.add({kind:'rename', table:'patients', from:'age group', to:'decade'});
    p.add({kind:'summarise', table:'patients', groups:['sex'], aggs:[{fn:'n'},{fn:'mean',col:'age'},{fn:'n_distinct',col:'site'}]});
    p.add({kind:'custom', code:'x <- 1 + 1'});
    const a = p.compose();
    p.setPipe('|>');
    out = { magrittr: a, native: p.compose(), steps: p.steps.length };
  ")
  # the two join keys share one join step
  expect_equal(out$steps, 8)
  expect_parses(out$magrittr)
  expect_parses(out$native)
  expect_match(out$magrittr, "visits_prep <- visits %>%", fixed = TRUE)
  expect_match(out$magrittr, 'by = c("patient_id", "site" = "site code")', fixed = TRUE)
  expect_match(out$magrittr, "dplyr::desc(`visit date`)", fixed = TRUE)
  expect_match(out$magrittr, "dplyr::case_when(", fixed = TRUE)
  expect_false(grepl("case_match", out$magrittr, fixed = TRUE))
  expect_false(grepl("%>%", out$native, fixed = TRUE))
})

test_that("keyed steps replace, join keys merge, and undo/redo walk history", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    const k = JSON.stringify(['arrange', 'df']);
    p.add({kind:'arrange', key:k, table:'df', cols:[{col:'x'}]});
    p.add({kind:'arrange', key:k, table:'df', cols:[{col:'y', desc:true}]});
    const afterReplace = p.compose();
    p.addJoinKey('df', 'lk', 'a', 'a');
    p.addJoinKey('df', 'lk', 'b', 'b2');
    p.addJoinKey('df', 'lk', 'a', 'a');
    const joinSteps = p.steps.filter(s => s.kind === 'join').length;
    const merged = p.compose();
    p.removeJoinKey('df', 'lk', 'a', 'a');
    const oneKey = p.compose();
    p.removeJoinKey('df', 'lk', 'b', 'b2');
    const noJoin = p.compose();
    p.undo(); const undone = p.compose();
    p.redo(); const redone = p.compose();
    const id = p.steps[0].id; p.toggle(id); const disabled = p.compose();
    p.clear(); const cleared = p.compose(); p.undo();
    out = { afterReplace, joinSteps, merged, oneKey, noJoin, undone, redone, disabled, cleared,
            restored: p.compose(), canRedo: p.canRedo() };
  ")
  expect_identical(out$afterReplace, "df %>%\n  dplyr::arrange(dplyr::desc(y))")
  expect_equal(out$joinSteps, 1)
  expect_match(out$merged, 'by = c("a", "b" = "b2")', fixed = TRUE)
  expect_match(out$oneKey, 'by = c("b" = "b2")', fixed = TRUE)
  expect_false(grepl("join", out$noJoin))
  expect_identical(out$undone, out$oneKey)
  expect_identical(out$redone, out$noJoin)
  expect_identical(out$disabled, "")
  expect_identical(out$cleared, "")
  expect_identical(out$restored, out$disabled)
  expect_true(out$canRedo)
})

test_that("identifiers and literals are escaped for R", {
  out <- run_pipeline_js("
    out = {
      plain: P.ident('age'), space: P.ident('visit date'), dotnum: P.ident('.2x'),
      reserved: P.ident('if'), tick: P.ident('a`b'), already: P.ident('`x y`'),
      str: P.str('say \"hi\"\\\\'), na: P.literal('NA', false), num: P.literal(' 3.50 ', true),
      numText: P.literal('3.5', false)
    };
  ")
  expect_identical(out$plain, "age")
  expect_identical(out$space, "`visit date`")
  expect_identical(out$dotnum, "`.2x`")
  expect_identical(out$reserved, "`if`")
  expect_identical(eval(parse(text = out$str)), 'say "hi"\\')
  expect_identical(out$na, "NA")
  expect_identical(out$num, "3.5")
  expect_identical(out$numText, '"3.5"')
  df <- data.frame(check.names = FALSE, `a\`b` = 1)
  expect_identical(eval(parse(text = out$tick), df), 1)
  expect_identical(out$already, "`x y`")
})

test_that("a join cycle still composes and parses", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.addJoinKey('a', 'b', 'id', 'id');
    p.addJoinKey('b', 'a', 'id', 'id');
    p.add({kind:'arrange', table:'a', cols:[{col:'id'}]});
    out = p.compose();
  ")
  expect_parses(out)
  expect_match(out, "b_prep <- b %>%", fixed = TRUE)
})

test_that("composed code gives the same answer as hand-written dplyr", {
  skip_if_not_installed("dplyr")
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.add({kind:'filter', table:'labs', conds:[P.condition('value', 'gte', '2', true)]});
    p.add({kind:'arrange', table:'labs', cols:[{col:'value', desc:true}]});
    p.addJoinKey('patients', 'labs', 'patient_id', 'pid');
    p.add({kind:'recode', table:'patients', col:'sex', map:[{from:'f',to:'F'},{from:'m',to:'M'}]});
    p.add({kind:'summarise', table:'patients', groups:['sex'], aggs:[{fn:'n'},{fn:'mean',col:'value'}]});
    out = p.compose();
  ")
  patients <- data.frame(patient_id = 1:4, sex = c("f", "m", "F", "x"))
  labs <- data.frame(pid = c(1, 1, 2, 3, 4, 4), value = c(1, 2, 3, 4, 5, NA))
  env <- new.env()
  env$patients <- patients
  env$labs <- labs
  env$`%>%` <- dplyr::`%>%`
  got <- NULL
  expect_silent(got <- eval(parse(text = out), envir = env))
  want <- patients %>%
    dplyr::left_join(labs %>% dplyr::filter(value >= 2), by = c("patient_id" = "pid")) %>%
    dplyr::mutate(sex = dplyr::case_when(sex == "f" ~ "F", sex == "m" ~ "M", .default = sex)) %>%
    dplyr::group_by(sex) %>%
    dplyr::summarise(n = dplyr::n(), mean_value = mean(value, na.rm = TRUE), .groups = "drop")
  expect_equal(as.data.frame(got), as.data.frame(want))
})

# ---- lazy (arrow / duckdb) tables -------------------------------------------------------------
# Code for a lazy card keeps the work in arrow or the database and ends in one collect().
# Known limit (Task 10 documents it for users): a factor column holding NA segfaults duckdb 1.4.x
# when an arrow table is scanned through it, so no fixture below has one.

lazy_ref <- function(kind, name) {
  if (identical(kind, "duckdb")) sprintf('dplyr::tbl(con, "%s")', name) else name
}
# The meta Pipeline$setTables() takes, as JSON text.
lazy_meta_json <- function(visits = NULL, patients = NULL) {
  one <- function(kind, name) {
    list(lazy = kind, codeRef = lazy_ref(kind, name))
  }
  jsonlite::toJSON(list(visits = one(visits, "visits"), patients = one(patients, "patients")),
                   auto_unbox = TRUE, null = "null")
}
# Compose a pipeline: `body` is JS that adds steps to `p`.
compose_lazy <- function(meta_json, body, pipe = "|>") {
  run_pipeline_js(sprintf(
    "const p = new P.Pipeline(); p.setPipe(%s); p.setTables(%s);\n%s\nout = p.compose();",
    jsonlite::toJSON(pipe, auto_unbox = TRUE), meta_json, body))
}
join_js <- "p.addJoinKey('visits', 'patients', 'id', 'id', '%s');"
n_collect <- function(x) lengths(regmatches(x, gregexpr("collect()", x, fixed = TRUE)))

test_that("joins across arrow, duckdb and data frames follow the design table, with one collect()", {
  join_code <- function(l, r, pipe = "|>") {
    compose_lazy(lazy_meta_json(l, r), sprintf(join_js, "left_join"), pipe)
  }
  tbl_v <- 'dplyr::tbl(con, "visits")'
  tbl_p <- 'dplyr::tbl(con, "patients")'
  expect_identical(join_code("duckdb", NULL), paste0(
    tbl_v, ' |>\n  dplyr::left_join(patients, by = "id", copy = TRUE) |>\n  dplyr::collect()'))
  expect_identical(join_code("arrow", NULL),
                   'visits |>\n  dplyr::left_join(patients, by = "id") |>\n  dplyr::collect()')
  expect_identical(join_code("duckdb", "arrow"), paste0(
    tbl_v, ' |>\n  dplyr::left_join(dplyr::compute(arrow::to_duckdb(patients, con = dbplyr::remote_con(', tbl_v,
    '))), by = "id") |>\n  dplyr::collect()'))
  expect_identical(join_code("arrow", "duckdb"), paste0(
    'dplyr::compute(arrow::to_duckdb(visits, con = dbplyr::remote_con(', tbl_p, '))) |>\n  dplyr::left_join(',
    tbl_p, ', by = "id") |>\n  dplyr::collect()'))
  expect_identical(join_code("arrow", "arrow"),
                   'visits |>\n  dplyr::left_join(patients, by = "id") |>\n  dplyr::collect()')
  expect_identical(join_code(NULL, "duckdb"), paste0(
    'dplyr::copy_to(dbplyr::remote_con(', tbl_p, '), visits, name = "sideview_visits", overwrite = TRUE) |>\n',
    '  dplyr::left_join(', tbl_p, ', by = "id") |>\n  dplyr::collect()'))
  expect_identical(join_code(NULL, "arrow"),
                   'arrow::arrow_table(visits) |>\n  dplyr::left_join(patients, by = "id") |>\n  dplyr::collect()')
  expect_identical(join_code("duckdb", "duckdb"), paste0(
    tbl_v, ' |>\n  dplyr::left_join(', tbl_p, ', by = "id") |>\n  dplyr::collect()'))
  # two data frames: no collect()
  expect_identical(join_code(NULL, NULL), 'visits |>\n  dplyr::left_join(patients, by = "id")')
  # the magrittr pipe is used when asked for
  expect_match(join_code("arrow", NULL, "%>%"), "visits %>%\n  dplyr::left_join", fixed = TRUE)
  # steps before a cross-kind join move into the engine with the left side
  moved <- compose_lazy(lazy_meta_json(NULL, "duckdb"), paste(
    "p.add({kind:'filter', table:'visits', conds:[P.condition('sbp', 'gt', '1', true)]});",
    sprintf(join_js, "left_join")))
  expect_parses(moved)
  expect_match(moved, "visits |>\n    dplyr::filter(sbp > 1),\n  name = \"sideview_visits\"", fixed = TRUE)
  expect_equal(n_collect(moved), 1L)
})

test_that("contains on a lazy table uses str_detect; collect() is one call and last", {
  out <- run_pipeline_js("
    out = {
      chr: P.condition('note', 'contains', 'x\"y', false, 'duckdb'),
      num: P.condition('id', 'contains', '12', true, 'arrow'),
      df: P.condition('note', 'contains', 'x', false),
      dfNum: P.condition('id', 'contains', '12', true, null),
      eq: P.condition('id', 'equals', '1', true, 'duckdb'),
      meta: P.condition('note', 'contains', 'a.b[1]', false, 'arrow'),
      slash: P.condition('note', 'contains', String.fromCharCode(99, 58, 92, 120), false, 'duckdb')
    };
    const p = new P.Pipeline();
    p.setTables({ v: { lazy: 'duckdb', codeRef: 'v' }, d: { lazy: null, codeRef: 'd' } });
    p.add({kind:'filter', table:'v', conds:[out.chr]});
    p.add({kind:'arrange', table:'v', cols:[{col:'id'}]});
    p.add({kind:'summarise', table:'v', groups:['id'], aggs:[{fn:'n'}]});
    out.chain = p.compose();
    const q = new P.Pipeline();
    q.setTables({ d: { lazy: null, codeRef: 'd' } });
    q.add({kind:'filter', table:'d', conds:[out.df]});
    out.dfChain = q.compose();
  ")
  expect_identical(out$chr, 'stringr::str_detect(note, "x\\"y")')
  expect_identical(out$num, 'stringr::str_detect(as.character(id), "12")')
  # the pattern is an escaped regex (fixed() is a plain regex on duckdb); the R literal doubles each backslash
  expect_identical(out$meta, 'stringr::str_detect(note, "a\\\\.b\\\\[1\\\\]")')
  expect_identical(out$slash, 'stringr::str_detect(note, "c:\\\\\\\\x")')
  expect_identical(parse(text = out$meta)[[1]][[3]], "a\\.b\\[1\\]")
  expect_identical(out$df, 'grepl("x", note, fixed = TRUE)')
  expect_identical(out$dfNum, 'grepl("12", id, fixed = TRUE)')
  expect_identical(out$eq, "id == 1")
  expect_equal(n_collect(out$chain), 1L)
  expect_match(out$chain, "\n  dplyr::collect\\(\\)$")
  expect_false(grepl("collect", out$dfChain, fixed = TRUE))
  expect_parses(out$chain)
})

test_that("a lazy table that another chain joins is prepared lazily and collected once", {
  out <- compose_lazy(lazy_meta_json("duckdb", NULL), paste(
    "p.addJoinKey('patients', 'visits', 'id', 'id');",
    "p.add({kind:'filter', table:'visits', conds:['sbp > 1']});"))
  expect_parses(out)
  expect_match(out, 'visits_prep <- dplyr::tbl(con, "visits") |>\n  dplyr::filter(sbp > 1)\n\n', fixed = TRUE)
  # the data frame joins a lazy table: it moves into the engine under its own name
  expect_match(out, 'dplyr::copy_to(dbplyr::remote_con(visits_prep), patients, name = "sideview_patients"', fixed = TRUE)
  expect_equal(n_collect(out), 1L)
  expect_match(out, "dplyr::collect\\(\\)$")
})

test_that("reshape runs lazily on duckdb and in R on arrow", {
  steps <- "
    p.add({kind:'filter', table:'r', conds:['sbp > 1']});
    p.add({kind:'reshape', type:'pivot_longer', table:'r', cols:['sbp','dbp'], namesTo:'measure', valuesTo:'mmHg'});
    p.add({kind:'arrange', table:'r', cols:[{col:'id'}]});"
  wide <- "p.add({kind:'reshape', type:'pivot_wider', table:'r', namesFrom:'visit', valuesFrom:'sbp'});"
  meta <- function(kind) {
    jsonlite::toJSON(list(r = list(lazy = kind, codeRef = "r")), auto_unbox = TRUE, null = "null")
  }
  arrow_long <- compose_lazy(meta("arrow"), steps, "%>%")
  duck_long <- compose_lazy(meta("duckdb"), steps, "%>%")
  df_long <- compose_lazy(meta(NULL), steps, "%>%")
  arrow_wide <- compose_lazy(meta("arrow"), wide)
  duck_wide <- compose_lazy(meta("duckdb"), wide)
  # arrow: collect() just before the pivot, with the comment; none at the end
  expect_match(arrow_long, "  dplyr::filter(sbp > 1) %>%\n  # reshape runs in R\n  dplyr::collect() %>%\n  tidyr::pivot_longer(", fixed = TRUE)
  expect_equal(n_collect(arrow_long), 1L)
  expect_match(arrow_long, "dplyr::arrange\\(id\\)$")
  expect_match(arrow_wide, "# reshape runs in R", fixed = TRUE)
  expect_equal(n_collect(arrow_wide), 1L)
  # duckdb: pivots in SQL, one collect() at the end, no comment
  expect_false(grepl("reshape runs in R", duck_long, fixed = TRUE))
  expect_equal(n_collect(duck_long), 1L)
  expect_match(duck_long, "dplyr::arrange\\(id\\) %>%\n  dplyr::collect\\(\\)$")
  expect_match(duck_long, 'tidyr::pivot_longer(cols = c(sbp, dbp), names_to = "measure", values_to = "mmHg")', fixed = TRUE)
  expect_match(duck_wide, "tidyr::pivot_wider(names_from = visit, values_from = sbp)", fixed = TRUE)
  expect_equal(n_collect(duck_wide), 1L)
  # a data frame has no collect()
  expect_equal(n_collect(df_long), 0L)
  for (code in list(arrow_long, duck_long, df_long, arrow_wide, duck_wide)) expect_parses(code)
})

test_that("recode closes with a TRUE arm on arrow only", {
  body <- "p.add({kind:'recode', table:'t', col:'sex', map:[{from:'f',to:'F'}]});"
  meta <- function(kind) jsonlite::toJSON(list(t = list(lazy = kind, codeRef = "t")), auto_unbox = TRUE, null = "null")
  arrow <- compose_lazy(meta("arrow"), body)
  expect_match(arrow, 'sex == "f" ~ "F", TRUE ~ sex))', fixed = TRUE)
  expect_false(grepl(".default", arrow, fixed = TRUE))
  expect_match(compose_lazy(meta("duckdb"), body), ".default = sex))", fixed = TRUE)
  expect_match(compose_lazy(meta(NULL), body), ".default = sex))", fixed = TRUE)
})

test_that("a data-frame-only pipeline composes to exactly the code it always did", {
  # Recorded from the composer before lazy tables existed (v0.3.x).
  magrittr <- paste(c(
    "visits_prep <- visits %>%",
    "  dplyr::arrange(dplyr::desc(`visit date`), id)",
    "",
    "patients %>%",
    "  dplyr::left_join(visits_prep, by = c(\"patient_id\", \"site\" = \"site code\")) %>%",
    "  dplyr::filter(age > 50 | sex %in% c(\"F\", \"M\") | grepl(\"a\\\"b\\\\c\", note, fixed = TRUE) | is.na(dose)) %>%",
    "  dplyr::mutate(sex = dplyr::case_when(sex %in% c(\"f\", \"female\") ~ \"F\", is.na(sex) ~ \"U\", .default = sex)) %>%",
    "  dplyr::mutate(`age group` = age %/% 10) %>%",
    "  dplyr::rename(decade = `age group`) %>%",
    "  dplyr::group_by(sex) %>%",
    "  dplyr::summarise(n = dplyr::n(), mean_age = mean(age, na.rm = TRUE), n_distinct_site = dplyr::n_distinct(site), .groups = \"drop\")",
    "",
    "x <- 1 + 1"), collapse = "\n")
  build <- "
    const build = (withMeta) => {
      const p = new P.Pipeline();
      if (withMeta) p.setTables({ visits: { lazy: null, codeRef: 'visits' }, patients: { lazy: null, codeRef: 'patients' } });
      p.add({kind:'arrange', key:'a', table:'visits', cols:[{col:'visit date', desc:true}, {col:'id'}]});
      p.addJoinKey('patients', 'visits', 'patient_id', 'patient_id');
      p.addJoinKey('patients', 'visits', 'site', 'site code');
      p.add({kind:'filter', table:'patients', conds:[P.condition('age', 'gt', '50', true),
        P.condition('sex', 'in', 'F, M', false), P.condition('note', 'contains', 'a\"b\\\\c', false),
        P.condition('dose', 'is_na', '', true)], combine:'or'});
      p.add({kind:'recode', table:'patients', col:'sex', map:[{from:'f',to:'F'},{from:'female',to:'F'},{from:'NA',to:'U'}]});
      p.add({kind:'mutate', table:'patients', name:'age group', expr:'age %/% 10'});
      p.add({kind:'rename', table:'patients', from:'age group', to:'decade'});
      p.add({kind:'summarise', table:'patients', groups:['sex'], aggs:[{fn:'n'},{fn:'mean',col:'age'},{fn:'n_distinct',col:'site'}]});
      p.add({kind:'custom', code:'x <- 1 + 1'});
      const a = p.compose(); p.setPipe('|>');
      return { magrittr: a, native: p.compose() };
    };
    out = { plain: build(false), withMeta: build(true) };"
  out <- run_pipeline_js(build)
  expect_identical(out$plain$magrittr, magrittr)
  expect_identical(out$plain$native, gsub("%>%", "|>", magrittr, fixed = TRUE))
  expect_identical(out$withMeta, out$plain)
})

test_that("the pipeline knows when it touches a lazy table", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    const none = p.hasLazy();
    const meta = { v: { lazy: 'duckdb', codeRef: 'v' }, d: { lazy: null, codeRef: 'd' } };
    const changed = p.setTables(meta);
    const same = p.setTables(JSON.parse(JSON.stringify(meta)));
    p.add({kind:'filter', table:'d', conds:['x > 1']});
    const dfOnly = p.hasLazy();
    p.add({kind:'arrange', table:'v', cols:[{col:'x'}]});
    const lazyStep = p.hasLazy();
    p.clear(); p.add({kind:'custom', code:'v |> head()'});
    const custom = p.hasLazy();
    out = { none, changed, same, dfOnly, lazyStep, custom, kind: p.lazyKind('v'), kindD: p.lazyKind('d'),
            ref: p.refFor('v'), weird: p.refFor('my table') };
  ")
  expect_false(out$none)
  expect_true(out$changed)
  expect_false(out$same)
  expect_false(out$dfOnly)
  expect_true(out$lazyStep)
  expect_true(out$custom)
  expect_identical(out$kind, "duckdb")
  expect_null(out$kindD)
  expect_identical(out$ref, "v")
  expect_identical(out$weird, "`my table`")
})

# ---- the generated lazy code runs, and equals the data-frame code -----------------------------

lazy_fixtures <- function() {
  list(
    visits = data.frame(
      id = c(1L, 1L, 2L, 3L, 4L, 4L, 5L, 9L, NA),
      sbp = c(120, 150, 160, 130, NA, 142, 155, 138, 133),
      dbp = c(80, 95, 100, 85, 70, 90, 99, 88, 84),
      site = c("A", "B", "A", "C", "B", "A", " A", NA, "C"),
      stringsAsFactors = FALSE
    ),
    patients = data.frame(
      id = 1:7,
      name = c(" Ann ", "bob", "CARL", "Dee", NA, "eve", "Fay"),
      age = c(30L, 45L, 52L, 61L, 70L, 28L, 39L),
      sex = c("f", "m", "F", "x", "m", NA, "f"),
      stringsAsFactors = FALSE
    ),
    readings = data.frame(
      id = c(1L, 1L, 2L, 2L, 3L),
      visit = c("v1", "v2", "v1", "v2", "v1"),
      sbp = c(120, 150, 160, 130, 142),
      dbp = c(80, 95, 100, 85, 90),
      stringsAsFactors = FALSE
    )
  )
}

# An environment where each fixture is the kind asked for (NULL = data frame). Every fixture
# is also a table in the duckdb connection, whatever its kind, so code that wrongly wrote
# under a fixture's name would be caught. `tbl_<name>` is the duckdb handle.
lazy_env <- function(kinds = list(), frame = parent.frame()) {
  fx <- lazy_fixtures()
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = frame)
  env <- new.env(parent = globalenv())
  env$con <- con
  for (nm in names(fx)) {
    DBI::dbWriteTable(con, nm, fx[[nm]])
    kind <- kinds[[nm]]
    if (identical(kind, "arrow")) env[[nm]] <- arrow::arrow_table(fx[[nm]])
    else if (!identical(kind, "duckdb")) env[[nm]] <- fx[[nm]]
  }
  env
}

# Build the lazy query, run the garbage collector, then collect. A table that to_duckdb()
# registered and nothing holds is dropped by the collector: the generated code must survive that.
run_code <- function(code, env) {
  query <- sub("\\s*(%>%|\\|>)\\s*dplyr::collect\\(\\)\\s*$", "", code)
  q <- eval(parse(text = query), envir = env)
  invisible(gc())
  dplyr::collect(q)
}

expect_same_rows <- function(got, want, info = NULL) {
  norm <- function(x) {
    x <- as.data.frame(x)
    x <- x[, sort(names(x)), drop = FALSE]  # pivot_wider may order new columns differently
    x[do.call(order, unname(as.list(x))), , drop = FALSE] |> `rownames<-`(NULL)
  }
  expect_equal(norm(got), norm(want), tolerance = 1e-9, info = info)
}

skip_unless_lazy_stack <- function() {
  for (pkg in c("duckdb", "DBI", "dbplyr", "arrow", "stringr", "tidyr", "dplyr", "withr")) {
    skip_if_not_installed(pkg)
  }
}

test_that("lazy pipelines run: every join of the design equals the data-frame join", {
  skip_unless_lazy_stack()
  kinds <- list(
    list("duckdb", NULL), list("arrow", NULL), list("duckdb", "arrow"), list("arrow", "duckdb"),
    list("arrow", "arrow"), list(NULL, "duckdb"), list(NULL, "arrow"), list("duckdb", "duckdb")
  )
  body <- paste(
    "p.add({kind:'filter', table:'visits', conds:[P.condition('sbp', 'gte', '130', true)]});",
    "p.addJoinKey('visits', 'patients', 'id', 'id', '%s');",
    "p.add({kind:'arrange', table:'visits', cols:[{col:'id'}, {col:'sbp'}]});")
  for (k in kinds) {
    for (type in c("left_join", "inner_join")) {
      for (pipe in c("%>%", "|>")) {
        label <- sprintf("%s x %s (%s, %s)", k[[1]] %||% "df", k[[2]] %||% "df", type, pipe)
        code <- compose_lazy(lazy_meta_json(k[[1]], k[[2]]), sprintf(body, type), pipe)
        expect_parses(code, label)
        env <- lazy_env(list(visits = k[[1]], patients = k[[2]]))
        # the duckdb handles the card code names
        env$`%>%` <- magrittr::`%>%`
        got <- tryCatch(run_code(code, env), error = function(e) {
          fail(paste0(label, ": ", conditionMessage(e), "\n", code)); NULL
        })
        if (is.null(got)) next
        want_env <- lazy_env()
        want_env$`%>%` <- magrittr::`%>%`
        want <- run_code(compose_lazy(lazy_meta_json(), sprintf(body, type), pipe), want_env)
        expect_same_rows(got, want, info = label)
        # copy_to under the data frame's own name must not replace the database table of that name
        expect_equal(DBI::dbGetQuery(env$con, "select count(*) as n from patients")$n, 7, info = label)
        expect_equal(DBI::dbGetQuery(env$con, "select count(*) as n from visits")$n, 9, info = label)
      }
    }
  }
})

test_that("lazy pipelines run: filter, rename, mutate, recode, arrange, summarise equal the data frame", {
  skip_unless_lazy_stack()
  rows <- "
    p.add({kind:'filter', table:'visits', conds:[P.condition('site', 'contains', 'A', false, LAZY),
      P.condition('id', 'contains', '1', true, LAZY), P.condition('sbp', 'gte', '120', true)]});
    p.add({kind:'rename', table:'visits', from:'sbp', to:'sys'});
    p.add({kind:'mutate', table:'visits', name:'ratio', expr:'sys / dbp'});
    p.add({kind:'recode', table:'visits', col:'site', map:[{from:'A', to:'Alpha'}, {from:'B', to:'Beta'}]});
    p.add({kind:'arrange', table:'visits', cols:[{col:'sys', desc:true}, {col:'id'}]});"
  summ <- "
    p.add({kind:'filter', table:'visits', conds:[P.condition('site', 'contains', 'A', false, LAZY)]});
    p.add({kind:'recode', table:'visits', col:'site', map:[{from:'A', to:'Alpha'}]});
    p.add({kind:'summarise', table:'visits', groups:['site'], aggs:[{fn:'n'}, {fn:'mean', col:'sbp'},
      {fn:'n_distinct', col:'id'}, {fn:'min', col:'sbp'}, {fn:'max', col:'dbp'}, {fn:'sum', col:'dbp'}]});"
  for (kind in c("duckdb", "arrow")) {
    for (body in c(rows, summ)) {
      for (pipe in c("%>%", "|>")) {
        meta <- jsonlite::toJSON(list(visits = list(lazy = kind, codeRef = lazy_ref(kind, "visits"))), auto_unbox = TRUE)
        code <- compose_lazy(meta, gsub("LAZY", shQuote(kind, "cmd"), body, fixed = TRUE), pipe)
        label <- paste(kind, pipe, code)
        expect_parses(code, label)
        expect_equal(n_collect(code), 1L, info = label)
        env <- lazy_env(list(visits = kind))
        env$`%>%` <- magrittr::`%>%`
        got <- tryCatch(run_code(code, env), error = function(e) {
          fail(paste0(label, ": ", conditionMessage(e))); NULL
        })
        if (is.null(got)) next
        want_env <- lazy_env()
        want_env$`%>%` <- magrittr::`%>%`
        want_meta <- jsonlite::toJSON(list(visits = list(lazy = NULL, codeRef = "visits")), auto_unbox = TRUE, null = "null")
        want <- run_code(compose_lazy(want_meta, gsub("LAZY", "null", body, fixed = TRUE), pipe), want_env)
        expect_same_rows(got, want, info = label)
      }
    }
  }
})

test_that("lazy pipelines run: a prepared lazy table, and reshape on arrow and duckdb", {
  skip_unless_lazy_stack()
  steps <- paste("p.addJoinKey('patients', 'visits', 'id', 'id');",
                 "p.add({kind:'filter', table:'visits', conds:[P.condition('sbp', 'gt', '125', true)]});")
  want <- {
    env <- lazy_env()
    env$`%>%` <- magrittr::`%>%`
    run_code(compose_lazy(lazy_meta_json(), steps), env)
  }
  for (right in c("duckdb", "arrow")) {
    code <- compose_lazy(jsonlite::toJSON(list(
      visits = list(lazy = right, codeRef = lazy_ref(right, "visits")),
      patients = list(lazy = NULL, codeRef = "patients")), auto_unbox = TRUE, null = "null"), steps)
    expect_parses(code)
    got <- tryCatch(run_code(code, lazy_env(list(visits = right))), error = function(e) {
      fail(paste0(right, ": ", conditionMessage(e), "\n", code)); NULL
    })
    if (!is.null(got)) expect_same_rows(got, want, info = right)
  }

  long <- "
    p.add({kind:'filter', table:'readings', conds:[P.condition('sbp', 'gt', '121', true)]});
    p.add({kind:'reshape', type:'pivot_longer', table:'readings', cols:['sbp', 'dbp'], namesTo:'measure', valuesTo:'mmHg'});
    p.add({kind:'arrange', table:'readings', cols:[{col:'id'}]});"
  wide <- "p.add({kind:'reshape', type:'pivot_wider', table:'readings', namesFrom:'visit', valuesFrom:'sbp'});"
  for (kind in c("duckdb", "arrow")) {
    for (body in c(long, wide)) {
      meta <- jsonlite::toJSON(list(readings = list(lazy = kind, codeRef = lazy_ref(kind, "readings"))), auto_unbox = TRUE)
      code <- compose_lazy(meta, body)
      expect_parses(code)
      got <- tryCatch(run_code(code, lazy_env(list(readings = kind))), error = function(e) {
        fail(paste0(kind, ": ", conditionMessage(e), "\n", code)); NULL
      })
      want_meta <- jsonlite::toJSON(list(readings = list(lazy = NULL, codeRef = "readings")), auto_unbox = TRUE, null = "null")
      want_long <- run_code(compose_lazy(want_meta, body), lazy_env())
      if (!is.null(got)) expect_same_rows(got, want_long, info = paste(kind, code))
    }
  }
})

test_that("lazy contains matches the text itself, dots and brackets included, on duckdb and arrow", {
  skip_unless_lazy_stack()
  frame <- data.frame(
    id = 1:8,
    x = c("a.b", "axb", "50%", "a_b", "[z]", "c:\\x", "q", NA),
    stringsAsFactors = FALSE
  )
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "m", frame)
  for (kind in c("duckdb", "arrow")) {
    env <- new.env(parent = globalenv())
    env$con <- con
    if (kind == "arrow") env$m <- arrow::arrow_table(frame)
    meta <- jsonlite::toJSON(list(m = list(lazy = kind, codeRef = lazy_ref(kind, "m"))), auto_unbox = TRUE)
    for (pat in c(".", "a.b", "%", "_", "[z]", "c:\\x", "(", "*", "^a", "b$")) {
      body <- sprintf("p.add({kind:'filter', table:'m', conds:[P.condition('x', 'contains', %s, false, %s)]});",
                      jsonlite::toJSON(pat, auto_unbox = TRUE), jsonlite::toJSON(kind, auto_unbox = TRUE))
      code <- compose_lazy(meta, body)
      got <- tryCatch(run_code(code, env), error = function(e) {
        fail(paste0(kind, " ", pat, ": ", conditionMessage(e), "\n", code)); NULL
      })
      want <- frame[grepl(pat, frame$x, fixed = TRUE), ]
      if (!is.null(got)) expect_equal(sort(got$id), sort(want$id), info = paste(kind, "contains", pat))
    }
  }
})
