# Tests for the browser-side composable pipeline (inst/www/sv-pipeline.js).
# The composer runs under Node; every script it produces must parse() in R and,
# for the core verbs, give the same result as hand-written dplyr.

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

# ---- addJoinKeys: a key set as one undo step ---------------------------------------------------

test_that("addJoinKeys adds a key set as one step and one undo", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.addJoinKeys('adae', 'ae', [{left:'STUDYID',right:'STUDYID'},{left:'USUBJID',right:'USUBJID'},
                                 {left:'AESEQ',right:'AESEQ'}], 'left_join');
    const n = p.steps.length, by = p.steps[0].by.length, depth = p.undoStack.length;
    p.undo();
    out = { n: n, by: by, depth: depth, afterUndo: p.steps.length };
  ")
  expect_equal(out$n, 1)
  expect_equal(out$by, 3)
  expect_equal(out$depth, 1)
  expect_equal(out$afterUndo, 0)
})

test_that("addJoinKeys adds only missing pairs and leaves a no-op out of history", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.addJoinKeys('adae', 'ae', [{left:'STUDYID',right:'STUDYID'},{left:'USUBJID',right:'USUBJID'}]);
    p.addJoinKeys('adae', 'ae', [{left:'USUBJID',right:'USUBJID'},{left:'AESEQ',right:'AESEQ'}]);
    const n = p.steps.length, by = p.steps[0].by.length, depth = p.undoStack.length;
    p.addJoinKeys('adae', 'ae', [{left:'AESEQ',right:'AESEQ'}]);
    out = { n: n, by: by, depth: depth, depthAfterNoop: p.undoStack.length };
  ")
  expect_equal(out$n, 1)
  expect_equal(out$by, 3)
  expect_equal(out$depth, 2)
  expect_equal(out$depthAfterNoop, 2)
})

test_that("addJoinKeys merges into the reverse join, swapped, keeping its direction", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.addJoinKey('ae', 'adae', 'USUBJID', 'USUBJID');
    p.addJoinKeys('adae', 'ae', [{left:'USUBJID',right:'USUBJID'},{left:'AESEQ',right:'AESEQ'}]);
    out = { n: p.steps.length, table: p.steps[0].table, by: p.steps[0].by };
  ")
  expect_equal(out$n, 1)
  expect_equal(out$table, "ae")
  expect_equal(length(out$by), 2)
  expect_equal(out$by[[2]]$left, "AESEQ")
  expect_equal(out$by[[2]]$right, "AESEQ")
})

test_that("addJoinKeys composes parseable code with dplyr's row count", {
  skip_if_not_installed("dplyr")
  fx <- sv_cdisc_fixtures()
  groups <- list(
    trace   = list(l = "adae_pfx", r = "ae", keys = c("STUDYID", "USUBJID", "AESEQ")),
    subject = list(l = "ae", r = "dm", keys = c("STUDYID", "USUBJID")),
    visit   = list(l = "lb", r = "sv", keys = c("STUDYID", "USUBJID", "VISITNUM"))
  )
  for (kind in names(groups)) {
    g <- groups[[kind]]
    pairs <- paste(sprintf("{left:'%s',right:'%s'}", g$keys, g$keys), collapse = ",")
    code <- run_pipeline_js(sprintf("
      const p = new P.Pipeline();
      p.addJoinKeys('%s', '%s', [%s]);
      out = p.compose();", g$l, g$r, pairs))
    expect_parses(code)
    env <- new.env()
    env[[g$l]] <- fx[[g$l]]
    env[[g$r]] <- fx[[g$r]]
    env$`%>%` <- dplyr::`%>%`
    got <- eval(parse(text = code), envir = env)
    want <- dplyr::left_join(fx[[g$l]], fx[[g$r]], by = g$keys)
    expect_equal(nrow(got), nrow(want), info = kind)
  }
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
  expect_equal(norm(got), norm(want), tolerance = 1e-12, info = info)
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
        env$`%>%` <- dplyr::`%>%`
        got <- tryCatch(run_code(code, env), error = function(e) {
          fail(paste0(label, ": ", conditionMessage(e), "\n", code)); NULL
        })
        if (is.null(got)) next
        want_env <- lazy_env()
        want_env$`%>%` <- dplyr::`%>%`
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
        env$`%>%` <- dplyr::`%>%`
        got <- tryCatch(run_code(code, env), error = function(e) {
          fail(paste0(label, ": ", conditionMessage(e))); NULL
        })
        if (is.null(got)) next
        want_env <- lazy_env()
        want_env$`%>%` <- dplyr::`%>%`
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
    env$`%>%` <- dplyr::`%>%`
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

# ---- fix round 1: "contains" is written for the engine the chain is in when the step runs ----------
# A data-frame card's filter is built with the data-frame form (grepl(fixed = TRUE)) because that
# is what the card is on its own. After a join into duckdb or arrow the chain is lazy, and duckdb
# cannot translate grepl(fixed = TRUE): compose() must write str_detect() for that step instead.

contains_step <- function(col, val, numeric = FALSE) {
  # what the browser adds for a data-frame card: the data-frame condition text plus the spec
  sprintf("p.add({kind:'filter', table:'visits', conds:[P.condition(%s, 'contains', %s, %s)],
           specs:[{col:%s, op:'contains', val:%s, numeric:%s}]});",
          jsonlite::toJSON(col, auto_unbox = TRUE), jsonlite::toJSON(val, auto_unbox = TRUE),
          tolower(numeric), jsonlite::toJSON(col, auto_unbox = TRUE),
          jsonlite::toJSON(val, auto_unbox = TRUE), tolower(numeric))
}

test_that("a contains filter added after a join into duckdb or arrow is written for that engine", {
  join <- sprintf(join_js, "left_join")
  for (right in c("duckdb", "arrow")) {
    meta <- lazy_meta_json(NULL, right)
    after <- compose_lazy(meta, paste(join, contains_step("site", "a.b")))
    expect_parses(after)
    expect_match(after, 'dplyr::filter(stringr::str_detect(site, "a\\\\.b"))', fixed = TRUE, info = right)
    expect_false(grepl("grepl", after, fixed = TRUE), info = right)
    expect_false(grepl("fixed", after, fixed = TRUE), info = right)
    expect_equal(n_collect(after), 1L, info = right)
    # numeric column: as.character() inside str_detect
    num <- compose_lazy(meta, paste(join, contains_step("id", "12", TRUE)))
    expect_match(num, 'stringr::str_detect(as.character(id), "12")', fixed = TRUE, info = right)
    # before the join the chain is still in R, so the same step keeps the data-frame form
    before <- compose_lazy(meta, paste(contains_step("site", "a.b"), join))
    expect_parses(before)
    expect_match(before, 'grepl("a.b", site, fixed = TRUE)', fixed = TRUE, info = right)
    expect_false(grepl("str_detect", before, fixed = TRUE), info = right)
  }
  # a chain that never leaves R is unchanged
  df <- compose_lazy(lazy_meta_json(), paste(join, contains_step("site", "a.b")))
  expect_match(df, 'dplyr::filter(grepl("a.b", site, fixed = TRUE))', fixed = TRUE)
  expect_false(grepl("str_detect|collect", df))
  # a step without a spec (older state, a custom condition) is left as written
  plain <- compose_lazy(lazy_meta_json(NULL, "duckdb"), paste(join,
    "p.add({kind:'filter', table:'visits', conds:['sbp > 1']});"))
  expect_match(plain, "dplyr::filter(sbp > 1)", fixed = TRUE)
})

test_that("a contains filter added after a join into duckdb or arrow runs and equals the data frame", {
  skip_unless_lazy_stack()
  join <- sprintf(join_js, "left_join")
  steps <- list(
    paste(join, contains_step("site", "A")),
    paste(join, contains_step("site", ".")),      # a regex dot would match every row on duckdb
    paste(join, contains_step("site", "A"), contains_step("id", "1", TRUE)),
    paste(contains_step("site", "A"), join)       # before the join: stays in R
  )
  for (right in c("duckdb", "arrow")) {
    for (i in seq_along(steps)) {
      label <- sprintf("%s, case %d", right, i)
      code <- compose_lazy(lazy_meta_json(NULL, right), steps[[i]])
      expect_parses(code, label)
      got <- tryCatch(run_code(code, lazy_env(list(patients = right))), error = function(e) {
        fail(paste0(label, ": ", conditionMessage(e), "\n", code)); NULL
      })
      want_env <- lazy_env()
      want_env$`%>%` <- dplyr::`%>%`
      want <- run_code(compose_lazy(lazy_meta_json(), steps[[i]]), want_env)
      if (!is.null(got)) expect_same_rows(got, want, info = label)
    }
  }
})

test_that("a three-way chain across duckdb, a data frame and arrow equals the data-frame result", {
  skip_unless_lazy_stack()
  three_meta <- function(a, b, c) {
    one <- function(kind, name) list(lazy = kind, codeRef = lazy_ref(kind, name))
    jsonlite::toJSON(list(visits = one(a, "visits"), patients = one(b, "patients"),
                          readings = one(c, "readings")), auto_unbox = TRUE, null = "null")
  }
  body <- paste(
    "p.addJoinKey('visits', 'patients', 'id', 'id', 'left_join');",
    "p.addJoinKey('patients', 'readings', 'id', 'id', 'left_join');",
    "p.add({kind:'filter', table:'visits', conds:[P.condition('age', 'gte', '40', true)]});",
    "p.add({kind:'arrange', table:'visits', cols:[{col:'id'}, {col:'age'}, {col:'visit'}]});")
  want_env <- lazy_env()
  want_env$`%>%` <- dplyr::`%>%`
  # patients and readings both repeat an id: the many-to-many join is the point, so mute dplyr's note
  want <- suppressWarnings(run_code(compose_lazy(three_meta(NULL, NULL, NULL), body), want_env))
  orders <- list(
    list("duckdb", NULL, "arrow"), list("arrow", NULL, "duckdb"), list(NULL, "duckdb", "arrow"),
    list("arrow", "duckdb", NULL), list("duckdb", "arrow", NULL), list(NULL, "arrow", "duckdb")
  )
  for (k in orders) {
    label <- paste(vapply(k, function(x) x %||% "df", ""), collapse = " <- ")
    code <- compose_lazy(three_meta(k[[1]], k[[2]], k[[3]]), body)
    expect_parses(code, label)
    expect_equal(n_collect(code), 1L, info = label)
    env <- lazy_env(list(visits = k[[1]], patients = k[[2]], readings = k[[3]]))
    got <- tryCatch(run_code(code, env), error = function(e) {
      fail(paste0(label, ": ", conditionMessage(e), "\n", code)); NULL
    })
    if (!is.null(got)) expect_same_rows(got, want, info = label)
  }
})

test_that("disableMissing keeps steps whose columns exist", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.add({kind:'arrange', key:'a', table:'labs', cols:[{col:'id'}]});
    p.add({kind:'filter', table:'labs', conds:[P.condition('val', 'gt', '1', true)], condCols:['val'], combine:'and'});
    const n = p.undoStack.length;
    const r = p.disableMissing('labs', ['id', 'val']);
    out = { r: r, en: p.steps.map(s => s.enabled), same: p.undoStack.length === n };
  ")
  expect_length(out$r$disabled, 0)
  expect_length(out$r$missing, 0)
  expect_equal(unlist(out$en), c(TRUE, TRUE))
  expect_true(out$same)
})

test_that("disableMissing disables a filter on a dropped column", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.add({kind:'arrange', key:'a', table:'labs', cols:[{col:'id'}]});
    const f = p.add({kind:'filter', table:'labs', conds:[P.condition('lab_dt', 'is_na', '', true)], condCols:['lab_dt'], combine:'and'});
    const r = p.disableMissing('labs', ['id', 'val']);
    out = { r: r, fid: f.id, en: p.steps.map(s => s.enabled), u: p.undoStack.length, d: p.redoStack.length };
  ")
  expect_equal(out$r$disabled[[1]]$id, out$fid)
  expect_equal(out$r$disabled[[1]]$kind, "filter")
  expect_equal(unlist(out$r$disabled[[1]]$missing), "lab_dt")
  expect_equal(unlist(out$r$missing), "lab_dt")
  expect_equal(unlist(out$en), c(TRUE, FALSE))
  expect_equal(c(out$u, out$d), c(0, 0))
})

test_that("disableMissing follows renames and mutates", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.add({kind:'rename', table:'labs', from:'lab_dt', to:'d'});
    p.add({kind:'arrange', key:'a', table:'labs', cols:[{col:'d'}]});
    p.add({kind:'mutate', table:'labs', name:'z', expr:'1'});
    p.add({kind:'filter', table:'labs', conds:[P.condition('z', 'gt', '0', true)], condCols:['z'], combine:'and'});
    const r = p.disableMissing('labs', ['lab_dt', 'val']);
    out = { r: r, en: p.steps.map(s => s.enabled) };
  ")
  expect_length(out$r$disabled, 0)
  expect_equal(unlist(out$en), rep(TRUE, 4))
})

test_that("disableMissing stops checking after a summarise", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.add({kind:'summarise', table:'labs', groups:['id'], aggs:[{fn:'n'}]});
    p.add({kind:'filter', table:'labs', conds:[P.condition('nope', 'gt', '0', true)], condCols:['nope'], combine:'and'});
    const r = p.disableMissing('labs', ['id']);
    out = { r: r, en: p.steps.map(s => s.enabled) };
  ")
  expect_length(out$r$disabled, 0)
  expect_equal(unlist(out$en), c(TRUE, TRUE))
})

test_that("disableMissing checks both sides of a join", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.addJoinKey('visits', 'labs', 'id', 'pid');
    const left = p.disableMissing('visits', ['id']);
    const right = p.disableMissing('labs', ['id', 'val']);
    out = { left: left, right: right, en: p.steps.map(s => s.enabled) };
  ")
  expect_length(out$left$disabled, 0)
  expect_equal(unlist(out$right$disabled[[1]]$missing), "pid")
  expect_equal(unlist(out$right$missing), "pid")
  expect_equal(unlist(out$en), FALSE)
})

test_that("disableMissing with null disables everything on the table", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.add({kind:'arrange', key:'a', table:'labs', cols:[{col:'id'}]});
    p.add({kind:'arrange', key:'b', table:'visits', cols:[{col:'id'}]});
    p.addJoinKey('visits', 'labs', 'id', 'pid');
    const r = p.disableMissing('labs', null);
    out = { r: r, en: p.steps.map(s => s.enabled), u: p.undoStack.length };
  ")
  expect_length(out$r$disabled, 2)
  expect_length(out$r$missing, 0)
  expect_equal(unlist(out$en), c(FALSE, TRUE, FALSE))
  expect_equal(out$u, 0)
})

test_that("disableMissing checks mutate expressions against the dropped columns", {
  out <- run_pipeline_js("
    const old = ['id', 'weight', 'height', 'lab value'];
    const t = (expr, now, name) => {
      const p = new P.Pipeline();
      const s = p.add({kind:'mutate', table:'t', name: name || 'z', expr: expr});
      const r = p.disableMissing('t', now, old);
      return { en: p.steps[0].enabled, miss: r.missing, off: r.disabled.length };
    };
    out = {
      dropped: t('weight / height^2', ['id', 'weight', 'lab value'], 'bmi'),
      other_dropped: t('weight / height^2', ['id', 'weight', 'height'], 'bmi'),
      backtick: t('`lab value` * 2', ['id', 'weight', 'height']),
      in_string: t('paste0(\"height\", id)', ['id', 'weight', 'lab value']),
      in_string_single: t(\"paste('height', id)\", ['id', 'weight', 'lab value']),
      function_name: t('round(weight, 1)', ['id', 'weight', 'height', 'lab value']),
      fn_named_like_col: t('height(weight)', ['id', 'weight', 'lab value']),
      new_variable: t('bmi_old * 2', ['id', 'weight', 'height']),
      list_member: t('x$height + weight', ['id', 'weight', 'lab value']),
      arg_name: t('round(weight, digits = 1)', ['id', 'weight', 'lab value']),
      no_old: (() => { const p = new P.Pipeline();
        p.add({kind:'mutate', table:'t', name:'z', expr:'height * 2'});
        const r = p.disableMissing('t', ['id']); return { en: p.steps[0].enabled, off: r.disabled.length }; })()
    };
  ")
  expect_false(out$dropped$en)
  expect_equal(unlist(out$dropped$miss), "height")
  expect_true(out$other_dropped$en)
  expect_false(out$backtick$en)
  expect_equal(unlist(out$backtick$miss), "lab value")
  expect_true(out$in_string$en)
  expect_true(out$in_string_single$en)
  expect_true(out$function_name$en)
  expect_true(out$fn_named_like_col$en)
  expect_true(out$new_variable$en)
  expect_true(out$list_member$en)
  expect_true(out$arg_name$en)
  # without the old columns the check cannot tell a function from a column: the step is kept
  expect_true(out$no_old$en)
})

test_that("disableMissing: a column made by an earlier step is not a dropped column", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.add({kind:'mutate', table:'t', name:'height', expr:'1'});
    p.add({kind:'mutate', table:'t', name:'z', expr:'height * 2'});
    const r = p.disableMissing('t', ['id'], ['id', 'height']);
    out = { en: p.steps.map(s => s.enabled), off: r.disabled.length };
  ")
  expect_equal(unlist(out$en), c(TRUE, TRUE))
})

test_that("disableMissing covers join rule, recode, reshape and filters without condCols", {
  out <- run_pipeline_js("
    const rule = new P.Pipeline();
    rule.addJoinKey('visits', 'labs', 'id', 'id');
    rule.setTables({visits: {kinds: {visit_date: 'Date'}}, labs: {kinds: {lab_date: 'Date'}}});
    rule.setJoinRule(rule.steps[0].id, {shape: 'window', xCol: 'visit_date', yCol: 'lab_date', from: -7, to: 7});
    const rl = rule.disableMissing('visits', ['id']);
    const rr = new P.Pipeline();
    rr.addJoinKey('visits', 'labs', 'id', 'id');
    rr.setTables({visits: {kinds: {visit_date: 'Date'}}, labs: {kinds: {lab_date: 'Date'}}});
    rr.setJoinRule(rr.steps[0].id, {shape: 'window', xCol: 'visit_date', yCol: 'lab_date', from: -7, to: 7});
    const rrr = rr.disableMissing('labs', ['id']);

    const rec = new P.Pipeline();
    rec.add({kind:'recode', table:'t', col:'sex', map:[{from:'f', to:'F'}]});
    const rc = rec.disableMissing('t', ['id']);

    const lng = new P.Pipeline();
    lng.add({kind:'reshape', type:'pivot_longer', table:'t', cols:['sbp','dbp'], namesTo:'m', valuesTo:'v'});
    const rs = lng.disableMissing('t', ['id', 'sbp']);
    const wid = new P.Pipeline();
    wid.add({kind:'reshape', type:'pivot_wider', table:'t', namesFrom:'visit', valuesFrom:'sbp'});
    const rw = wid.disableMissing('t', ['id', 'visit']);

    const nocols = new P.Pipeline();
    nocols.add({kind:'filter', table:'t', conds:['gone > 1'], combine:'and'});
    const rn = nocols.disableMissing('t', ['id']);
    out = { rl: rl, rrr: rrr, rc: rc, rs: rs, rw: rw, rn: rn, nocols: nocols.steps[0].enabled };
  ")
  expect_equal(unlist(out$rl$missing), "visit_date")
  expect_equal(unlist(out$rrr$missing), "lab_date")
  expect_equal(unlist(out$rc$missing), "sex")
  expect_equal(unlist(out$rs$missing), "dbp")
  expect_equal(unlist(out$rw$missing), "sbp")
  expect_length(out$rn$disabled, 0)
  expect_true(out$nocols)
})

test_that("compose skips disabled steps and still parses", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.add({kind:'arrange', key:'a', table:'labs', cols:[{col:'id'}]});
    p.add({kind:'filter', table:'labs', conds:[P.condition('lab_dt', 'is_na', '', true)], condCols:['lab_dt'], combine:'and'});
    p.addJoinKey('visits', 'labs', 'id', 'pid');
    p.disableMissing('labs', ['id', 'val']);
    out = p.compose();
  ")
  expect_parses(out)
  expect_false(grepl("lab_dt", out, fixed = TRUE))
  expect_false(grepl("pid", out, fixed = TRUE))
})

# ---- the supp merge step (SUPP-- rows folded into the parent domain) -------------------------

# The check's JSON (plan included) for a parent and a SUPP table, as sv_supp_check() gives it.
supp_chk_json <- function(parent, supp, parent_name = "ae", supp_name = "suppae", rdomain = "AE") {
  chk <- sv_supp_check(parent, supp, parent_name, supp_name, rdomain = rdomain)
  if (!is.null(chk$error)) stop(chk$error)
  sv_supp_check_json(chk)
}

# Compose a pipeline holding one supp step built from the check's plan. `before` / `after` are
# JS run before / after the step is added; `meta` goes to setTables().
supp_compose <- function(chk_json, pipe = "%>%", table = "ae", supp = "suppae", rdomain = "AE",
                         meta = "{}", before = "", after = "") {
  run_pipeline_js(sprintf(
    "const p = new P.Pipeline(); p.setPipe(%s); p.setTables(%s);
     const chk = %s;
     %s
     p.add(P.suppStep(%s, %s, %s, chk.plan), 'merge');
     %s
     out = p.compose();",
    jsonlite::toJSON(pipe, auto_unbox = TRUE), meta, chk_json, before,
    jsonlite::toJSON(table, auto_unbox = TRUE), jsonlite::toJSON(supp, auto_unbox = TRUE),
    jsonlite::toJSON(rdomain, auto_unbox = TRUE), after))
}

# Run composed code with the given tables bound by name.
supp_run <- function(code, ...) {
  env <- list2env(list(...), parent = globalenv())
  env$`%>%` <- dplyr::`%>%`
  eval(parse(text = code), envir = env)
}

# What a run stops with ("" when it runs).
supp_stop <- function(code, ...) {
  tryCatch({ supp_run(code, ...); "" }, error = function(e) conditionMessage(e))
}

# The merge written by hand: one pivot per IDVAR level, joined on the converted key.
supp_hand_merge <- function(parent, supp, keys = c("STUDYID", "USUBJID"), idvar = "AESEQ",
                            convert = as.integer, labels = NULL) {
  supp$IDVAR[is.na(supp$IDVAR)] <- ""
  out <- parent
  lv <- supp[supp$IDVAR == idvar, , drop = FALSE]
  if (nrow(lv)) {
    lv[[idvar]] <- convert(lv$IDVARVAL)
    lv <- lv[!is.na(lv[[idvar]]), , drop = FALSE]
    lv <- tidyr::pivot_wider(lv[c(keys, idvar, "QNAM", "QVAL")], names_from = QNAM, values_from = QVAL)
    out <- dplyr::left_join(out, lv, by = c(keys, idvar))
  }
  sj <- supp[supp$IDVAR == "", , drop = FALSE]
  if (nrow(sj)) {
    sj <- tidyr::pivot_wider(sj[c(keys, "QNAM", "QVAL")], names_from = QNAM, values_from = QVAL)
    out <- dplyr::left_join(out, sj, by = keys)
  }
  for (nm in names(labels)) attr(out[[nm]], "label") <- labels[[nm]]
  out
}

test_that("supp code equals hand merge", {
  fx <- sv_cdisc_fixtures()
  code <- supp_compose(supp_chk_json(fx$ae, fx$suppae2))
  expect_parses(code)
  expect_match(code, 'suppae_q <- suppae %>%\n  dplyr::filter(RDOMAIN == "AE")', fixed = TRUE)
  expect_match(code, "suppae_aeseq <- tidyr::pivot_wider(suppae_aeseq, names_from = QNAM, values_from = QVAL)",
               fixed = TRUE)
  expect_match(code, 'suppae_labels <- c(AETRTEM = "Label AETRTEM", AESOC2 = "Label AESOC2")', fixed = TRUE)
  expect_match(code, 'ae %>%\n  dplyr::left_join(suppae_aeseq, by = c("STUDYID", "USUBJID", "AESEQ")) %>%\n',
               fixed = TRUE)
  got <- supp_run(code, ae = fx$ae, suppae = fx$suppae2)
  # written independently of the generator
  aeseq <- fx$suppae2 |>
    dplyr::filter(IDVAR == "AESEQ") |>
    dplyr::transmute(STUDYID, USUBJID, AESEQ = as.integer(IDVARVAL), QNAM, QVAL) |>
    tidyr::pivot_wider(names_from = QNAM, values_from = QVAL)
  subj <- fx$suppae2 |>
    dplyr::filter(IDVAR == "") |>
    dplyr::select(STUDYID, USUBJID, QNAM, QVAL) |>
    tidyr::pivot_wider(names_from = QNAM, values_from = QVAL)
  want <- fx$ae |>
    dplyr::left_join(aeseq, by = c("STUDYID", "USUBJID", "AESEQ")) |>
    dplyr::left_join(subj, by = c("STUDYID", "USUBJID"))
  attr(want$AETRTEM, "label") <- "Label AETRTEM"
  attr(want$AESOC2, "label") <- "Label AESOC2"
  expect_equal(got, want)
  expect_identical(attr(got$AETRTEM, "label"), "Label AETRTEM")
  expect_identical(got$AETRTEM, structure(c("Y", "Y", NA, NA), label = "Label AETRTEM"))
})

test_that("supp code with |>", {
  fx <- sv_cdisc_fixtures()
  code <- supp_compose(supp_chk_json(fx$ae, fx$suppae2), pipe = "|>")
  expect_parses(code)
  expect_false(grepl("%>%", code, fixed = TRUE))
  got <- supp_run(code, ae = fx$ae, suppae = fx$suppae2)
  want <- supp_hand_merge(fx$ae, fx$suppae2,
                          labels = c(AETRTEM = "Label AETRTEM", AESOC2 = "Label AESOC2"))
  expect_equal(got, want)
})

test_that("supp guards stop", {
  fx <- sv_cdisc_fixtures()
  # a new IDVAR level after the plan was made
  code <- supp_compose(supp_chk_json(fx$ae, fx$suppae2))
  extra <- rbind(fx$suppae2, transform(fx$suppae2[1, ], IDVAR = "AEGRPID", IDVARVAL = "G1"))
  expect_identical(supp_stop(code, ae = fx$ae, suppae = extra),
                   "suppae has IDVAR values this merge does not handle: AEGRPID. Refresh the merge step.")
  # a QNAM that is a parent column
  code <- supp_compose(supp_chk_json(fx$ae, fx$supp_clash))
  expect_parses(code)
  expect_identical(supp_stop(code, ae = fx$ae, suppae = fx$supp_clash),
                   "suppae QNAMs clash with ae columns: AESEV")
  # a QNAM at two IDVAR levels
  code <- supp_compose(supp_chk_json(fx$ae, fx$supp_two_level))
  expect_parses(code)
  expect_identical(supp_stop(code, ae = fx$ae, suppae = fx$supp_two_level),
                   "suppae QNAMs are at two levels: AETRTEM")
  # "01" and "1" are one record once converted
  code <- supp_compose(supp_chk_json(fx$ae, fx$supp_repeat))
  expect_parses(code)
  expect_identical(supp_stop(code, ae = fx$ae, suppae = fx$supp_repeat),
                   "suppae repeats a QNAM for 1 record(s), first: SV-001-001 AESEQ 1 AETRTEM")
  # the subject level has its own repeat guard
  code <- supp_compose(supp_chk_json(fx$ae, fx$suppae2))
  twice <- rbind(fx$suppae2, fx$suppae2[3, ])
  expect_identical(supp_stop(code, ae = fx$ae, suppae = twice),
                   "suppae repeats a QNAM for 1 record(s), first: SV-001-001 AESOC2")
  # a level the plan does not have is unhandled too, and named
  code <- supp_compose(supp_chk_json(fx$ae, fx$suppae))
  expect_identical(supp_stop(code, ae = fx$ae, suppae = fx$suppae2),
                   "suppae has IDVAR values this merge does not handle: (subject level). Refresh the merge step.")
})

test_that("supp merge without STUDYID, without RDOMAIN, on a character key", {
  fx <- sv_cdisc_fixtures()
  # no STUDYID: USUBJID alone
  code <- supp_compose(supp_chk_json(fx$ae_nostudy, fx$suppae_nostudy))
  expect_parses(code)
  expect_match(code, 'by = c("USUBJID", "AESEQ")', fixed = TRUE)
  expect_false(grepl("STUDYID", code, fixed = TRUE))
  got <- supp_run(code, ae = fx$ae_nostudy, suppae = fx$suppae_nostudy)
  want <- supp_hand_merge(fx$ae_nostudy, fx$suppae_nostudy, keys = "USUBJID",
                          labels = c(AETRTEM = "Treatment Emergent"))
  expect_equal(got, want)
  # no RDOMAIN column: no filter
  nord <- fx$suppae2[, setdiff(names(fx$suppae2), "RDOMAIN")]
  code <- supp_compose(supp_chk_json(fx$ae, nord))
  expect_parses(code)
  expect_false(grepl("RDOMAIN", code, fixed = TRUE))
  got <- supp_run(code, ae = fx$ae, suppae = nord)
  expect_equal(got, supp_hand_merge(fx$ae, nord,
                                    labels = c(AETRTEM = "Label AETRTEM", AESOC2 = "Label AESOC2")))
  # a character key is used as it is
  code <- supp_compose(supp_chk_json(fx$ae_grp, fx$suppae_grp))
  expect_parses(code)
  expect_match(code, "AEGRPID = IDVARVAL", fixed = TRUE)
  got <- supp_run(code, ae = fx$ae_grp, suppae = fx$suppae_grp)
  expect_equal(got, supp_hand_merge(fx$ae_grp, fx$suppae_grp, idvar = "AEGRPID", convert = identity,
                                    labels = c(AEGRPQ = "Label AEGRPQ")))
})

test_that("supp merge: other RDOMAIN rows are dropped, bad IDVARVAL rows join nothing", {
  fx <- sv_cdisc_fixtures()
  code <- supp_compose(supp_chk_json(fx$ae, fx$suppqual, supp_name = "suppqual"), supp = "suppqual")
  expect_parses(code)
  got <- supp_run(code, ae = fx$ae, suppqual = fx$suppqual)
  expect_equal(got, supp_hand_merge(fx$ae, fx$suppqual[fx$suppqual$RDOMAIN == "AE", ],
                                    labels = c(AETRTEM = "Label AETRTEM")))
  expect_false("CMPRESP" %in% names(got))
  # "x" and "1.5" on an integer key do not convert; they are dropped, not joined as NA
  code <- supp_compose(supp_chk_json(fx$ae, fx$supp_bad))
  got <- supp_run(code, ae = fx$ae, suppae = fx$supp_bad)
  expect_identical(nrow(got), nrow(fx$ae))
  expect_true(all(is.na(got$AETRTEM)))
})

test_that("supp merge: the SUPP card's own steps come first", {
  fx <- sv_cdisc_fixtures()
  code <- supp_compose(supp_chk_json(fx$ae, fx$suppae2), before =
    "p.add({kind:'filter', table:'suppae', conds:[P.condition('USUBJID', 'not_equals', 'SV-001-002', false)],
            condCols:['USUBJID'], combine:'and'});")
  expect_parses(code)
  expect_match(code, 'suppae_prep <- suppae %>%\n  dplyr::filter(USUBJID != "SV-001-002")', fixed = TRUE)
  expect_match(code, "suppae_q <- suppae_prep %>%", fixed = TRUE)
  expect_lt(regexpr("suppae_prep <-", code), regexpr("suppae_q <-", code))
  got <- supp_run(code, ae = fx$ae, suppae = fx$suppae2)
  kept <- fx$suppae2[fx$suppae2$USUBJID != "SV-001-002", ]
  expect_equal(got, supp_hand_merge(fx$ae, kept,
                                    labels = c(AETRTEM = "Label AETRTEM", AESOC2 = "Label AESOC2")))
})

test_that("supp merge on a lazy parent equals the in-memory result", {
  skip_unless_lazy_stack()
  fx <- sv_cdisc_fixtures()
  chk <- supp_chk_json(fx$ae, fx$suppae2)
  labels <- c(AETRTEM = "Label AETRTEM", AESOC2 = "Label AESOC2")
  want <- supp_hand_merge(fx$ae, fx$suppae2, labels = labels)
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "ae", fx$ae)
  DBI::dbWriteTable(con, "suppae_db", fx$suppae2)
  cases <- list(
    duckdb = list(meta = '{"ae": {"lazy": "duckdb", "codeRef": "dplyr::tbl(con, \\"ae\\")"}}',
                  ae = NULL, supp = fx$suppae2, pattern = "copy = TRUE", n = 1L),
    arrow = list(meta = '{"ae": {"lazy": "arrow", "codeRef": "ae"}}',
                 ae = arrow::arrow_table(fx$ae), supp = fx$suppae2,
                 pattern = "arrow::arrow_table(suppae_aeseq)", n = 1L),
    lazy_supp = list(meta = '{"suppae": {"lazy": "arrow", "codeRef": "suppae"}}',
                     ae = fx$ae, supp = arrow::arrow_table(fx$suppae2),
                     pattern = "dplyr::collect() %>%\n  dplyr::mutate(IDVAR", n = 1L),
    both = list(meta = '{"ae": {"lazy": "duckdb", "codeRef": "dplyr::tbl(con, \\"ae\\")"},
                         "suppae": {"lazy": "duckdb", "codeRef": "dplyr::tbl(con, \\"suppae_db\\")"}}',
                ae = NULL, supp = NULL, pattern = "copy = TRUE", n = 2L))
  for (nm in names(cases)) {
    cs <- cases[[nm]]
    code <- supp_compose(chk, meta = cs$meta)
    expect_parses(code, nm)
    expect_match(code, cs$pattern, fixed = TRUE, info = nm)
    expect_equal(n_collect(code), cs$n, info = nm)
    args <- list(code = code, con = con)
    if (!is.null(cs$ae)) args$ae <- cs$ae
    if (!is.null(cs$supp)) args$suppae <- cs$supp
    got <- tryCatch(do.call(supp_run, args), error = function(e) {
      fail(paste0(nm, ": ", conditionMessage(e), "\n", code)); NULL
    })
    if (is.null(got)) next
    for (lab in names(labels)) expect_identical(attr(got[[lab]], "label"), labels[[lab]], info = nm)
    expect_same_rows(got, want, info = nm)
  }
  # a lazy parent's chain prepared for another chain stays lazy and gets no labels
  code <- supp_compose(chk, meta = cases$duckdb$meta,
                       after = "p.addJoinKey('dm', 'ae', 'USUBJID', 'USUBJID');")
  expect_parses(code)
  expect_match(code, "ae_prep <- dplyr::tbl(con, \"ae\") %>%", fixed = TRUE)
  expect_false(grepl("suppae_labels", code, fixed = TRUE))
})

test_that("odd QNAM and QLABEL parse", {
  fx <- sv_cdisc_fixtures()
  odd <- fx$suppae
  odd$QNAM <- "AE TRT"
  odd$QLABEL <- 'He said "x" \\ y'
  code <- supp_compose(supp_chk_json(fx$ae, odd))
  expect_parses(code)
  got <- supp_run(code, ae = fx$ae, suppae = odd)
  expect_identical(attr(got$`AE TRT`, "label"), 'He said "x" \\ y')
  expect_equal(got, supp_hand_merge(fx$ae, odd, labels = c(`AE TRT` = 'He said "x" \\ y')))
  # a supp card name that is not syntactic goes through ident()
  code <- supp_compose(supp_chk_json(fx$ae, odd, supp_name = "supp ae"), supp = "supp ae")
  expect_parses(code)
  expect_match(code, "`supp ae_q` <- `supp ae` %>%", fixed = TRUE)
  env_args <- list(code = code, ae = fx$ae)
  env_args[["supp ae"]] <- odd
  expect_identical(attr(do.call(supp_run, env_args)$`AE TRT`, "label"), 'He said "x" \\ y')
})

test_that("factor keys run", {
  fx <- sv_cdisc_fixtures()
  ae_f <- fx$ae
  ae_f$STUDYID <- factor(ae_f$STUDYID)
  ae_f$USUBJID <- factor(ae_f$USUBJID)
  code <- supp_compose(supp_chk_json(ae_f, fx$suppae2))
  expect_parses(code)
  got <- supp_run(code, ae = ae_f, suppae = fx$suppae2)
  want <- supp_hand_merge(ae_f, fx$suppae2,
                          labels = c(AETRTEM = "Label AETRTEM", AESOC2 = "Label AESOC2"))
  expect_equal(got, want)
  expect_identical(got$AETRTEM[1:2], c("Y", "Y"))
})

test_that("supp merge without labels writes no labels", {
  fx <- sv_cdisc_fixtures()
  nolab <- fx$suppae[, setdiff(names(fx$suppae), "QLABEL")]
  code <- supp_compose(supp_chk_json(fx$ae, nolab))
  expect_parses(code)
  expect_false(grepl("labels", code, fixed = TRUE))
  got <- supp_run(code, ae = fx$ae, suppae = nolab)
  expect_equal(got, supp_hand_merge(fx$ae, nolab))
})

test_that("supp step: describe, disableMissing and the parent's columns", {
  fx <- sv_cdisc_fixtures()
  chk <- supp_chk_json(fx$ae, fx$suppae2)
  out <- run_pipeline_js(sprintf("
    const chk = %s;
    const mk = () => { const p = new P.Pipeline(); p.add(P.suppStep('ae', 'suppae', 'AE', chk.plan)); return p; };
    const aeCols = ['STUDYID', 'DOMAIN', 'USUBJID', 'AESEQ', 'AETERM', 'AEDECOD', 'AESEV', 'AESTDTC'];
    const gone = mk();
    const rg = gone.disableMissing('suppae', null);
    const nokey = mk();
    const rk = nokey.disableMissing('ae', aeCols.filter(c => c !== 'AESEQ'));
    const later = mk();
    later.add({kind:'arrange', table:'ae', cols:[{col:'AETRTEM'}, {col:'AESOC2'}]});
    later.add({kind:'filter', table:'ae', conds:[P.condition('AETRTEM', 'equals', 'Y', false)],
               condCols:['AETRTEM'], combine:'and'});
    const rl = later.disableMissing('ae', aeCols);
    const keep = mk();
    const rs = keep.disableMissing('suppae', ['STUDYID', 'RDOMAIN', 'USUBJID', 'IDVAR', 'IDVARVAL', 'QNAM', 'QLABEL', 'QVAL']);
    const noq = mk();
    const rq = noq.disableMissing('suppae', ['STUDYID', 'RDOMAIN', 'USUBJID', 'IDVAR', 'IDVARVAL', 'QVAL']);
    const s = gone.steps[0];
    out = { desc: P.describe(s), descP: gone.describe(s), key: s.key,
            rg: rg, gone: gone.steps[0].enabled, rk: rk, nokey: nokey.steps[0].enabled,
            rl: rl, later: later.steps.map(x => x.enabled), rs: rs, keep: keep.steps[0].enabled,
            rq: rq, noq: noq.steps[0].enabled, one: P.describe(P.suppStep('ae', 'suppae', 'AE',
              { keys: ['USUBJID'], idvars: [{ idvar: 'AESEQ', type: 'integer' }],
                qnams: [{ qnam: 'A', label: '', idvar: 'AESEQ' }], rdomain_col: true })),
            strict: (() => { const p = mk(); p.addJoinKey('ae', 'dm', 'USUBJID', 'USUBJID');
                             return p.strictApplies(p.steps[1]).ok; })(),
            lazy: (() => { const p = mk(); p.setTables({ suppae: { lazy: 'arrow', codeRef: 'suppae' } });
                           return p.hasLazy(); })() };
  ", chk))
  expect_identical(out$desc, "merge SUPPAE (2 QNAMs on AESEQ and subject)")
  expect_identical(out$descP, out$desc)
  expect_identical(out$one, "merge SUPPAE (1 QNAMs on AESEQ)")
  expect_identical(out$key, '["supp","ae","suppae"]')
  expect_false(out$gone)
  expect_length(out$rg$disabled, 1)
  expect_false(out$nokey)
  expect_equal(unlist(out$rk$missing), "AESEQ")
  # the QNAM columns are known after the merge
  expect_equal(unlist(out$later), c(TRUE, TRUE, TRUE))
  expect_length(out$rl$disabled, 0)
  expect_true(out$keep)
  expect_false(out$noq)
  expect_equal(unlist(out$rq$missing), "QNAM")
  # not row-changing: a later join can still be Strict
  expect_true(out$strict)
  expect_true(out$lazy)
})

test_that("supp step state round trip", {
  fx <- sv_cdisc_fixtures()
  chk <- supp_chk_json(fx$ae, fx$suppae2)
  chk1 <- supp_chk_json(fx$ae, fx$suppae)
  first <- run_pipeline_js(sprintf("
    const p = new P.Pipeline();
    p.add(P.suppStep('ae', 'suppae', 'AE', (%s).plan), 'merge');
    out = { state: JSON.stringify({ version: '0.3.0', pipeline: { steps: p.toJSON().steps, pipe: p.pipe } }),
            code: p.compose() };
  ", chk))
  # through R's state reader and writer, as a saved workspace goes
  st <- sv_state_from_json(first$state)
  back <- sv_state_json(st)
  out <- run_pipeline_js(sprintf("
    const st = %s;
    const q = new P.Pipeline();
    q.load(st.pipeline);
    const code = q.compose();
    // plain table meta (cards without CDISC tags, cdisc = FALSE): the step carries its plan
    const bare = new P.Pipeline();
    bare.setTables({ ae: { lazy: null, codeRef: 'ae' }, suppae: { lazy: null, codeRef: 'suppae' } });
    bare.load(JSON.parse(JSON.stringify(st.pipeline)));
    const n = q.undoStack.length;
    q.add(P.suppStep('ae', 'suppae', 'AE', (%s).plan), 'merge');
    out = { code: code, bare: bare.compose(), n: q.steps.length, undo: q.undoStack.length - n,
            qnams: q.steps[0].qnams.map(x => x.qnam), kind: q.steps[0].kind };
  ", back, chk1))
  expect_identical(out$code, first$code)
  expect_identical(out$bare, first$code)
  # re-adding with the same key replaces the step, one undo step
  expect_equal(out$n, 1)
  expect_equal(out$undo, 1)
  expect_equal(unlist(out$qnams), "AETRTEM")
  expect_identical(out$kind, "supp")
})
