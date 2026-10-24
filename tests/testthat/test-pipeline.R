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
