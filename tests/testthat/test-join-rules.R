# Tests for the date rule and Strict flag on join steps (inst/www/sv-pipeline.js).
# The step model is pure JS: it runs under Node via run_pipeline_js().

test_that("setJoinRule stores a rule, describes it, and undoes", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.addJoinKey('visits', 'labs', 'id', 'id');
    p.setTables({visits: {kinds: {visit_date: 'Date'}}, labs: {kinds: {lab_date: 'Date'}}});
    const id = p.steps[0].id;
    const ok = p.setJoinRule(id, {shape: 'window', xCol: 'visit_date', yCol: 'lab_date', from: -7, to: 7});
    const step = p.find(id);
    const text = p.describe(step);
    const stored = JSON.parse(JSON.stringify(step.rule));
    const problem = p.joinRuleProblem(step);
    p.undo();
    out = {ok: ok, text: text, stored: stored, problem: problem, after: p.find(id).rule === undefined ||
      p.find(id).rule === null, again: p.setJoinRule(id, null)};
  ")
  expect_true(out$ok)
  expect_identical(out$text, "left join labs on id · lab_date within -7..+7 days of visit_date")
  expect_identical(out$stored$from, -7L)
  expect_identical(out$stored$to, 7L)
  expect_null(out$problem)
  expect_true(out$after)
  expect_false(out$again)
})

test_that("rule labels follow the table", {
  out <- run_pipeline_js("
    const L = (r, k) => P.ruleLabel(r, k);
    out = {
      date: L({shape: 'window', xCol: 'v', yCol: 'l', from: 0, to: 3}, 'Date'),
      neg: L({shape: 'window', xCol: 'v', yCol: 'l', from: -10, to: -2}, 'date-time'),
      num: L({shape: 'window', xCol: 'vady', yCol: 'ady', from: -7, to: 7}, 'numeric'),
      before: L({shape: 'before', xCol: 'visit_date', yCol: 'lab_date', inclusive: true}, 'Date'),
      before2: L({shape: 'before', xCol: 'visit_date', yCol: 'lab_date', inclusive: false}, 'Date'),
      beforeDef: L({shape: 'before', xCol: 'visit_date', yCol: 'lab_date'}, 'Date'),
      after: L({shape: 'after', xCol: 'visit_date', yCol: 'lab_date', inclusive: true}, 'Date'),
      after2: L({shape: 'after', xCol: 'visit_date', yCol: 'lab_date', inclusive: false}, 'Date'),
      between: L({shape: 'between', xCol: 'visit_date', yFrom: 'start', yTo: 'end'}, 'Date'),
      overlaps: L({shape: 'overlaps', xFrom: 'ae_start', xTo: 'ae_end', yFrom: 'start', yTo: 'end'}, 'Date')
    };
  ")
  expect_identical(out$date, "l within 0..+3 days of v")
  expect_identical(out$neg, "l within -10..-2 days of v")
  expect_identical(out$num, "ady within -7..+7 of vady")
  expect_identical(out$before, "last lab_date on or before visit_date")
  expect_identical(out$before2, "last lab_date before visit_date")
  expect_identical(out$beforeDef, "last lab_date on or before visit_date")
  expect_identical(out$after, "first lab_date on or after visit_date")
  expect_identical(out$after2, "first lab_date after visit_date")
  expect_identical(out$between, "visit_date between start and end")
  expect_identical(out$overlaps, "ae_start..ae_end overlaps start..end")
})

test_that("ruleSlots lists the slots of each shape", {
  out <- run_pipeline_js("
    out = {shapes: P.RULE_SHAPES, between: P.ruleSlots('between'), window: P.ruleSlots('window'),
      before: P.ruleSlots('before'), after: P.ruleSlots('after'), overlaps: P.ruleSlots('overlaps'),
      none: P.ruleSlots('nope')};
  ")
  expect_identical(unlist(out$shapes), c("between", "window", "before", "after", "overlaps"))
  slots <- function(x) vapply(x, function(s) paste(s$slot, s$side), "")
  expect_identical(slots(out$between), c("xCol x", "yFrom y", "yTo y"))
  expect_identical(slots(out$window), c("xCol x", "yCol y"))
  expect_identical(slots(out$before), c("xCol x", "yCol y"))
  expect_identical(slots(out$after), c("xCol x", "yCol y"))
  expect_identical(slots(out$overlaps), c("xFrom x", "xTo x", "yFrom y", "yTo y"))
  expect_length(out$none, 0)
})

test_that("before/after switch a right join to left", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.addJoinKey('visits', 'labs', 'id', 'id', 'right_join');
    p.setTables({visits: {kinds: {visit_date: 'Date'}}, labs: {kinds: {lab_date: 'Date'}}});
    const id = p.steps[0].id;
    const before = p.find(id).type;
    p.setJoinRule(id, {shape: 'before', xCol: 'visit_date', yCol: 'lab_date', inclusive: true});
    const mid = {type: p.find(id).type, hasRule: !!p.find(id).rule, depth: p.undoStack.length};
    p.undo();
    const s = p.find(id);
    const type = s.type, rule = s.rule === undefined ? null : s.rule;
    // a window rule leaves a full join alone
    p.update(id, {type: 'full_join'});
    p.setJoinRule(id, {shape: 'window', xCol: 'visit_date', yCol: 'lab_date', from: -1, to: 1});
    out = {before: before, mid: mid, type: type, rule: rule, windowType: p.find(id).type};
  ")
  expect_identical(out$before, "right_join")
  expect_identical(out$mid$type, "left_join")
  expect_true(out$mid$hasRule)
  expect_identical(out$mid$depth, 2L)  # the join, then the rule + type change
  expect_identical(out$type, "right_join")
  expect_null(out$rule)
  expect_identical(out$windowType, "full_join")
})

test_that("ruleProblem gives each message", {
  out <- run_pipeline_js("
    const w = (o) => Object.assign({shape: 'window', xCol: 'a', yCol: 'b', from: -7, to: 7}, o || {});
    const kx = {a: 'Date', n: 'numeric', t: 'date-time', c: 'character'};
    const ky = {b: 'Date', n2: 'numeric', t2: 'date-time'};
    out = {
      ok: P.ruleProblem(w(), kx, ky, 'left_join'),
      unknown: P.ruleProblem({shape: 'zig'}, kx, ky, 'left_join'),
      none: P.ruleProblem(null, kx, ky, 'left_join'),
      empty: P.ruleProblem(w({yCol: ''}), kx, ky, 'left_join'),
      missing: P.ruleProblem({shape: 'between', xCol: 'a', yFrom: 'b'}, kx, ky, 'left_join'),
      notDate: P.ruleProblem(w({xCol: 'c'}), kx, ky, 'left_join'),
      absent: P.ruleProblem(w({yCol: 'zzz'}), kx, ky, 'left_join'),
      differ: P.ruleProblem({shape: 'window', xCol: 'a', yCol: 't2', from: 0, to: 1}, kx, ky, 'left_join'),
      differ2: P.ruleProblem({shape: 'window', xCol: 'a', yCol: 'n2', from: 0, to: 1}, kx, ky, 'left_join'),
      frac: P.ruleProblem(w({from: '7.5'}), kx, ky, 'left_join'),
      range: P.ruleProblem(w({from: -3651}), kx, ky, 'left_join'),
      range2: P.ruleProblem(w({to: 3651}), kx, ky, 'left_join'),
      nobound: P.ruleProblem(w({to: undefined}), kx, ky, 'left_join'),
      nan: P.ruleProblem(w({from: 'abc'}), kx, ky, 'left_join'),
      order: P.ruleProblem(w({from: 8, to: 7}), kx, ky, 'left_join'),
      strOk: P.ruleProblem(w({from: '-7', to: '7'}), kx, ky, 'left_join'),
      edge: P.ruleProblem(w({from: -3650, to: 3650}), kx, ky, 'left_join'),
      right: P.ruleProblem({shape: 'before', xCol: 'a', yCol: 'b'}, kx, ky, 'right_join'),
      full: P.ruleProblem({shape: 'after', xCol: 'a', yCol: 'b'}, kx, ky, 'full_join'),
      semi: P.ruleProblem({shape: 'after', xCol: 'a', yCol: 'b'}, kx, ky, 'semi_join'),
      winRight: P.ruleProblem(w(), kx, ky, 'right_join')
    };
  ")
  expect_null(out$ok)
  expect_identical(out$unknown, "Unknown date rule.")
  expect_identical(out$none, "Unknown date rule.")
  expect_identical(out$empty, "Pick a column for every slot.")
  expect_identical(out$missing, "Pick a column for every slot.")
  expect_identical(out$notDate, "c is not a date, date-time or number.")
  expect_identical(out$absent, "zzz is not a date, date-time or number.")
  expect_identical(out$differ, "a is Date but t2 is date-time: both sides of a date rule need the same kind.")
  expect_identical(out$differ2, "a is Date but n2 is numeric: both sides of a date rule need the same kind.")
  bounds <- "Window bounds must be whole numbers from -3650 to 3650."
  expect_identical(out$frac, bounds)
  expect_identical(out$range, bounds)
  expect_identical(out$range2, bounds)
  expect_identical(out$nobound, bounds)
  expect_identical(out$nan, bounds)
  expect_identical(out$order, "The window start must not be after its end.")
  expect_null(out$strOk)
  expect_null(out$edge)
  nearest <- "A nearest-match rule works with left, inner, semi and anti joins only."
  expect_identical(out$right, nearest)
  expect_identical(out$full, nearest)
  expect_null(out$semi)
  expect_null(out$winRight)
})

test_that("a rule on a changed column needs fixing", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.addJoinKey('visits', 'labs', 'id', 'id');
    p.setTables({visits: {kinds: {visit_date: 'Date'}}, labs: {kinds: {lab_date: 'Date'}}});
    const id = p.steps[0].id;
    p.setJoinRule(id, {shape: 'window', xCol: 'visit_date', yCol: 'lab_date', from: -7, to: 7});
    const changed = p.setTables({visits: {kinds: {visit_date: 'Date'}}, labs: {kinds: {lab_date: 'character'}}});
    const same = p.setTables({visits: {kinds: {visit_date: 'Date'}}, labs: {kinds: {lab_date: 'character'}}});
    out = {changed: changed, same: same, text: p.describe(p.find(id)), problem: p.joinRuleProblem(p.find(id)),
      plain: p.describe({kind: 'join', type: 'left_join', right: 'labs', by: [{left: 'id', right: 'id'}]})};
  ")
  expect_true(out$changed)
  expect_false(out$same)
  expect_identical(out$text, "left join labs on id · Rule needs fixing")
  expect_identical(out$problem, "lab_date is not a date, date-time or number.")
  expect_identical(out$plain, "left join labs on id")
})

test_that("setJoinStrict is undoable and joinSig includes the rule", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    const events = [];
    p.onChange = (_, label) => events.push(label);
    p.addJoinKey('visits', 'labs', 'id', 'id');
    p.setTables({visits: {kinds: {visit_date: 'Date'}}, labs: {kinds: {lab_date: 'Date'}}});
    const id = p.steps[0].id;
    const sig0 = p.joinSig(p.find(id));
    const s1 = p.setJoinStrict(id, true);
    const strictOn = p.find(id).strict;
    const s1again = p.setJoinStrict(id, true);
    p.setJoinRule(id, {shape: 'window', xCol: 'visit_date', yCol: 'lab_date', from: -7, to: 7});
    const sig1 = p.joinSig(p.find(id));
    p.setJoinRule(id, {shape: 'window', xCol: 'visit_date', yCol: 'lab_date', from: -3, to: 7});
    const sig2 = p.joinSig(p.find(id));
    const depth = p.undoStack.length;
    events.length = 0;
    p.setJoinCheck(sig2, {a: 1});
    p.setJoinCheck(sig2, {a: 1});
    const e1 = events.slice();
    p.clearJoinChecks();
    p.clearJoinChecks();
    const e2 = events.slice();
    const depthAfter = p.undoStack.length;
    p.undo(); p.undo(); p.undo();
    out = {sig0: sig0, sig1: sig1, sig2: sig2, s1: s1, s1again: s1again, strictOn: strictOn,
      depth: depth, depthAfter: depthAfter, e1: e1, e2: e2,
      strictAfterUndo: p.find(id).strict === true,
      json: JSON.stringify(p.toJSON()).indexOf('checks')};
  ")
  expect_identical(out$sig0, '["visits","labs",[["id","id"]],null]')
  expect_false(identical(out$sig0, out$sig1))
  expect_false(identical(out$sig1, out$sig2))
  expect_match(out$sig1, '"window"', fixed = TRUE)
  expect_true(out$s1)
  expect_false(out$s1again)
  expect_true(out$strictOn)
  expect_identical(out$depth, 4L)  # join, strict, two rules
  expect_identical(out$depthAfter, 4L)  # setJoinCheck adds none
  expect_identical(unlist(out$e1), "checks")
  expect_identical(unlist(out$e2), c("checks", "checks"))  # set once, cleared once
  expect_false(out$strictAfterUndo)
  expect_identical(out$json, -1L)
})

test_that("rule and strict survive the workspace state", {
  out <- run_pipeline_js("
    const p = new P.Pipeline();
    p.addJoinKey('visits', 'labs', 'id', 'id');
    p.setTables({visits: {kinds: {visit_date: 'Date'}}, labs: {kinds: {lab_date: 'Date'}}});
    const id = p.steps[0].id;
    p.setJoinRule(id, {shape: 'window', xCol: 'visit_date', yCol: 'lab_date', from: '-7', to: '7'});
    p.setJoinStrict(id, true);
    const saved = JSON.parse(JSON.stringify(p.toJSON()));
    const q = new P.Pipeline();
    q.load(saved);
    const old = new P.Pipeline();
    old.load({pipe: '%>%', steps: [{kind: 'join', table: 'a', right: 'b', type: 'left_join',
      by: [{left: 'k', right: 'k'}], id: 's1', enabled: true}]});
    out = {rule: q.steps[0].rule, strict: q.steps[0].strict,
      oldRule: old.steps[0].rule === undefined, oldStrict: old.steps[0].strict === undefined,
      oldKeys: Object.keys(old.steps[0]).sort()};
  ")
  expect_identical(out$rule$from, -7L)
  expect_identical(out$rule$to, 7L)
  expect_identical(out$rule$shape, "window")
  expect_true(out$strict)
  expect_true(out$oldRule)
  expect_true(out$oldStrict)
  expect_identical(unlist(out$oldKeys),
                   c("by", "enabled", "id", "kind", "right", "table", "type"))

  # R round trip: numbers stay numbers and booleans stay booleans
  step <- list(kind = "join", id = "s1", key = "k", table = "visits", right = "labs",
               type = "left_join", enabled = TRUE, strict = TRUE,
               by = list(list(left = "id", right = "id")),
               rule = list(shape = "before", xCol = "visit_date", yCol = "lab_date", inclusive = FALSE))
  step2 <- step
  step2$rule <- list(shape = "window", xCol = "a", yCol = "b", from = -7, to = 7)
  for (s in list(step, step2)) {
    state <- new_sideview_state(pipeline = list(code = "", active_tab = "pipeline", steps = list(s), pipe = "%>%"))
    back <- sv_state_from_json(sv_state_json(state))
    expect_equal(back$pipeline$steps[[1]]$rule, s$rule)
    expect_identical(back$pipeline$steps[[1]]$strict, TRUE)
  }
  txt <- sv_state_json(new_sideview_state(pipeline = list(code = "", active_tab = "pipeline",
                                                           steps = list(step2), pipe = "%>%")))
  expect_match(txt, '"from":-7', fixed = TRUE)
  expect_match(txt, '"strict":true', fixed = TRUE)
})

# ---- in-memory code for a join with a rule --------------------------------------------------

# Column kinds of the synthetic tables used below.
rule_kinds <- list(
  visits = list(vdate = "Date", vtime = "date-time", vday = "numeric", `visit date` = "Date", date = "Date"),
  labs = list(ldate = "Date", ltime = "date-time", lday = "numeric", `lab date` = "Date", date = "Date"),
  dose = list(start = "Date", end = "Date", tstart = "date-time", tend = "date-time", nlo = "numeric",
              nhi = "numeric"),
  ae = list(ae_start = "Date", ae_end = "Date", ae_tstart = "date-time", ae_tend = "date-time",
            ae_nlo = "numeric", ae_nhi = "numeric")
)

# Compose the code of each case: list(left, right, type, pipe, rule, by). One Node run for all.
compose_rule_cases <- function(cases, kinds = rule_kinds) {
  cases <- lapply(cases, function(cs) {
    if (is.null(cs$pipe)) cs$pipe <- "%>%"
    if (is.null(cs$type)) cs$type <- "left_join"
    if (is.null(cs$by)) cs$by <- list(list("id", "id"))
    cs
  })
  json <- jsonlite::toJSON(list(cases = cases, kinds = kinds), auto_unbox = TRUE, null = "null")
  # The code goes through a file: a long stdout line can be broken by the pipe.
  file <- tempfile(fileext = ".json")
  on.exit(unlink(file), add = TRUE)
  run_pipeline_js(sprintf("
    const input = %s;
    const meta = {};
    Object.keys(input.kinds).forEach(t => { meta[t] = {kinds: input.kinds[t]}; });
    const codes = input.cases.map(c => {
      const p = new P.Pipeline({pipe: c.pipe});
      c.by.forEach(b => p.addJoinKey(c.left, c.right, b[0], b[1], c.type));
      p.setTables(meta);
      if (c.rule) p.setJoinRule(p.steps[0].id, c.rule);
      return p.compose();
    });
    require('fs').writeFileSync(%s, JSON.stringify(codes));
    out = codes.length;
  ", json, jsonlite::toJSON(normalizePath(file, winslash = "/", mustWork = FALSE), auto_unbox = TRUE)))
  vapply(jsonlite::fromJSON(file, simplifyVector = FALSE), as.character, "")
}

test_that("rule joins write join_by and parse", {
  kc <- list(
    Date = list(x = "vdate", y = "ldate", lo = "start", hi = "end", axlo = "ae_start", axhi = "ae_end"),
    `date-time` = list(x = "vtime", y = "ltime", lo = "tstart", hi = "tend", axlo = "ae_tstart", axhi = "ae_tend"),
    numeric = list(x = "vday", y = "lday", lo = "nlo", hi = "nhi", axlo = "ae_nlo", axhi = "ae_nhi")
  )
  cases <- list()
  add <- function(label, ...) cases[[length(cases) + 1]] <<- list(label = label, ...)
  offsets <- list(c(-7, 7), c(0, 3), c(-10, -2))
  for (pipe in c("%>%", "|>")) {
    for (kind in names(kc)) {
      k <- kc[[kind]]
      add(paste("between", kind, pipe), pipe = pipe, left = "visits", right = "dose",
          rule = list(shape = "between", xCol = k$x, yFrom = k$lo, yTo = k$hi))
      add(paste("overlaps", kind, pipe), pipe = pipe, left = "ae", right = "dose",
          rule = list(shape = "overlaps", xFrom = k$axlo, xTo = k$axhi, yFrom = k$lo, yTo = k$hi))
      for (o in offsets) {
        add(paste("window", kind, pipe, o[1], o[2]), pipe = pipe, left = "visits", right = "labs",
            rule = list(shape = "window", xCol = k$x, yCol = k$y, from = o[1], to = o[2]))
      }
      for (shape in c("before", "after")) for (incl in c(TRUE, FALSE)) {
        add(paste(shape, kind, pipe, incl), pipe = pipe, left = "visits", right = "labs",
            rule = list(shape = shape, xCol = k$x, yCol = k$y, inclusive = incl))
      }
    }
  }
  code <- compose_rule_cases(cases)
  labels <- vapply(cases, function(cs) cs$label, "")
  for (i in seq_along(code)) {
    expect_parses(code[[i]], labels[[i]])
    expect_match(code[[i]], 'na_matches = "never"', fixed = TRUE, label = labels[[i]])
    expect_match(code[[i]], "dplyr::join_by(id, ", fixed = TRUE, label = labels[[i]])
    expect_false(grepl("by = c(", code[[i]], fixed = TRUE), label = labels[[i]])
    # the helper columns never stay in the output
    if (grepl("^window", labels[[i]])) {
      expect_match(code[[i]], "dplyr::select(-.sv_lo, -.sv_hi)", fixed = TRUE, label = labels[[i]])
    } else {
      expect_false(grepl(".sv_", code[[i]], fixed = TRUE), label = labels[[i]])
    }
  }

  at <- function(label) code[[match(label, labels)]]
  expect_match(at("between Date %>%"),
               'dplyr::left_join(dose, by = dplyr::join_by(id, between(vdate, start, end)), na_matches = "never")',
               fixed = TRUE)
  expect_match(at("window Date %>% -7 7"),
               "dplyr::mutate(.sv_lo = vdate - 7, .sv_hi = vdate + 7)", fixed = TRUE)
  expect_match(at("window Date %>% -7 7"),
               'dplyr::left_join(labs, by = dplyr::join_by(id, between(y$ldate, x$.sv_lo, x$.sv_hi)), na_matches = "never")',
               fixed = TRUE)
  expect_match(at("window Date |> 0 3"), "dplyr::mutate(.sv_lo = vdate, .sv_hi = vdate + 3)", fixed = TRUE)
  expect_match(at("window Date %>% -10 -2"),
               "dplyr::mutate(.sv_lo = vdate - 10, .sv_hi = vdate - 2)", fixed = TRUE)
  expect_match(at("window date-time %>% -7 7"),
               'dplyr::mutate(.sv_lo = vtime - as.difftime(7, units = "days"), .sv_hi = vtime + as.difftime(7, units = "days"))',
               fixed = TRUE)
  expect_match(at("window date-time |> 0 3"),
               '.sv_lo = vtime, .sv_hi = vtime + as.difftime(3, units = "days")', fixed = TRUE)
  expect_match(at("window numeric %>% -7 7"), "dplyr::mutate(.sv_lo = vday - 7, .sv_hi = vday + 7)", fixed = TRUE)
  expect_match(at("before Date %>% TRUE"), "closest(vdate >= ldate)", fixed = TRUE)
  expect_match(at("before Date %>% FALSE"), "closest(vdate > ldate)", fixed = TRUE)
  expect_match(at("after Date |> TRUE"), "closest(vdate <= ldate)", fixed = TRUE)
  expect_match(at("after Date |> FALSE"), "closest(vdate < ldate)", fixed = TRUE)
  expect_match(at("overlaps Date %>%"), "dplyr::join_by(id, overlaps(ae_start, ae_end, start, end))", fixed = TRUE)
  # the extra lines join the chain with the chosen pipe
  expect_match(at("before Date |> TRUE"), "visits |>\n  dplyr::left_join(", fixed = TRUE)
  expect_match(at("window Date |> 0 3"), "visits |>\n  dplyr::mutate(.sv_lo", fixed = TRUE)
  expect_match(at("window Date %>% -7 7"), "na_matches = \"never\") %>%\n  dplyr::select(", fixed = TRUE)
})

test_that("rule joins write other key pairs and every join type", {
  cases <- list(
    list(left = "visits", right = "labs", by = list(list("id", "id"), list("site", "site code")),
         rule = list(shape = "before", xCol = "vdate", yCol = "ldate", inclusive = TRUE)),
    list(left = "visits", right = "labs", type = "inner_join",
         rule = list(shape = "window", xCol = "vdate", yCol = "ldate", from = -1, to = 1)),
    list(left = "visits", right = "labs", type = "semi_join",
         rule = list(shape = "after", xCol = "vdate", yCol = "ldate", inclusive = TRUE)),
    list(left = "visits", right = "labs", type = "anti_join",
         rule = list(shape = "before", xCol = "vdate", yCol = "ldate", inclusive = TRUE)),
    list(left = "visits", right = "dose", type = "full_join",
         rule = list(shape = "between", xCol = "vdate", yFrom = "start", yTo = "end")),
    list(left = "visits", right = "dose", type = "right_join",
         rule = list(shape = "between", xCol = "vdate", yFrom = "start", yTo = "end"))
  )
  code <- compose_rule_cases(cases)
  for (cd in code) expect_parses(cd)
  expect_match(code[[1]],
               'by = dplyr::join_by(id, site == `site code`, closest(vdate >= ldate)), na_matches = "never")',
               fixed = TRUE)
  expect_match(code[[2]], "dplyr::inner_join(labs, by = dplyr::join_by(", fixed = TRUE)
  expect_match(code[[3]],
               'dplyr::semi_join(labs, by = dplyr::join_by(id, closest(vdate <= ldate)), na_matches = "never")',
               fixed = TRUE)
  expect_match(code[[4]],
               'dplyr::anti_join(labs, by = dplyr::join_by(id, closest(vdate >= ldate)), na_matches = "never")',
               fixed = TRUE)
  expect_match(code[[5]], "dplyr::full_join(dose, by = dplyr::join_by(", fixed = TRUE)
  expect_match(code[[6]], "dplyr::right_join(dose, by = dplyr::join_by(", fixed = TRUE)
})

# The fixture: synthetic, with an NA date, a tie and an NA id.
rule_fixture <- function() {
  d <- function(x) as.Date(x)
  t <- function(x) as.POSIXct(x, tz = "UTC")
  visits <- data.frame(id = c(1, 1, 2, 3, 4), site = c("a", "a", "b", "b", "c"),
                       vdate = d(c("2024-01-10", "2024-02-01", "2024-01-15", NA, "2024-03-01")),
                       vtime = t(c("2024-01-10 08:00:00", "2024-02-01 08:00:00", "2024-01-15 08:00:00", NA,
                                   "2024-03-01 08:00:00")),
                       vday = c(10L, 32L, 15L, NA, 61L))
  labs <- data.frame(id = c(1, 1, 1, 2, 2, 3, NA, 4, 4), lval = 1:9,
                     ldate = d(c("2024-01-08", "2024-01-12", "2024-01-12", "2024-01-20", NA, "2024-02-01",
                                 "2024-01-01", "2024-02-25", "2024-03-02")),
                     ltime = t(c("2024-01-08 09:00:00", "2024-01-12 09:00:00", "2024-01-12 09:00:00",
                                 "2024-01-20 09:00:00", NA, "2024-02-01 09:00:00", "2024-01-01 09:00:00",
                                 "2024-02-25 09:00:00", "2024-03-02 09:00:00")),
                     lday = c(8L, 12L, 12L, 20L, NA, 32L, 1L, 56L, 62L))
  dose <- data.frame(id = c(1, 2, 3, 4), dval = 1:4,
                     start = d(c("2024-01-05", "2024-01-01", "2024-02-01", "2024-02-20")),
                     end = d(c("2024-01-31", "2024-01-14", "2024-02-10", "2024-03-05")),
                     tstart = t(c("2024-01-05 00:00:00", "2024-01-01 00:00:00", "2024-02-01 00:00:00",
                                  "2024-02-20 00:00:00")),
                     tend = t(c("2024-01-31 00:00:00", "2024-01-14 00:00:00", "2024-02-10 00:00:00",
                                "2024-03-05 00:00:00")),
                     nlo = c(5L, 1L, 30L, 50L), nhi = c(31L, 14L, 40L, 65L))
  ae <- data.frame(id = c(1, 2, 3, 4), aval = 1:4,
                   ae_start = d(c("2024-01-09", "2024-01-10", "2024-03-01", NA)),
                   ae_end = d(c("2024-01-20", "2024-01-30", "2024-03-05", "2024-03-10")))
  list(visits = visits, labs = labs, dose = dose, ae = ae)
}

test_that("rule joins run like join_by on data frames", {
  tabs <- rule_fixture()
  jf <- list(left_join = dplyr::left_join, inner_join = dplyr::inner_join,
             semi_join = dplyr::semi_join, anti_join = dplyr::anti_join)

  # Hand-written references: j is the dplyr join, the rest is written out literally per shape.
  refs <- list(
    `between Date` = function(j) j(tabs$visits, tabs$dose,
      by = dplyr::join_by(id, between(vdate, start, end)), na_matches = "never"),
    `between date-time` = function(j) j(tabs$visits, tabs$dose,
      by = dplyr::join_by(id, between(vtime, tstart, tend)), na_matches = "never"),
    `between numeric` = function(j) j(tabs$visits, tabs$dose,
      by = dplyr::join_by(id, between(vday, nlo, nhi)), na_matches = "never"),
    `overlaps Date` = function(j) j(tabs$ae, tabs$dose,
      by = dplyr::join_by(id, overlaps(ae_start, ae_end, start, end)), na_matches = "never"),
    `window Date` = function(j) tabs$visits |>
      dplyr::mutate(.sv_lo = vdate - 7, .sv_hi = vdate + 7) |>
      j(tabs$labs, by = dplyr::join_by(id, between(y$ldate, x$.sv_lo, x$.sv_hi)), na_matches = "never") |>
      dplyr::select(-.sv_lo, -.sv_hi),
    `window Date zero` = function(j) tabs$visits |>
      dplyr::mutate(.sv_lo = vdate, .sv_hi = vdate + 3) |>
      j(tabs$labs, by = dplyr::join_by(id, between(y$ldate, x$.sv_lo, x$.sv_hi)), na_matches = "never") |>
      dplyr::select(-.sv_lo, -.sv_hi),
    `window date-time` = function(j) tabs$visits |>
      dplyr::mutate(.sv_lo = vtime - as.difftime(10, units = "days"),
                    .sv_hi = vtime - as.difftime(2, units = "days")) |>
      j(tabs$labs, by = dplyr::join_by(id, between(y$ltime, x$.sv_lo, x$.sv_hi)), na_matches = "never") |>
      dplyr::select(-.sv_lo, -.sv_hi),
    `window numeric` = function(j) tabs$visits |>
      dplyr::mutate(.sv_lo = vday - 7, .sv_hi = vday + 7) |>
      j(tabs$labs, by = dplyr::join_by(id, between(y$lday, x$.sv_lo, x$.sv_hi)), na_matches = "never") |>
      dplyr::select(-.sv_lo, -.sv_hi),
    `before Date` = function(j) j(tabs$visits, tabs$labs,
      by = dplyr::join_by(id, closest(vdate >= ldate)), na_matches = "never"),
    `before Date strict` = function(j) j(tabs$visits, tabs$labs,
      by = dplyr::join_by(id, closest(vdate > ldate)), na_matches = "never"),
    `before date-time` = function(j) j(tabs$visits, tabs$labs,
      by = dplyr::join_by(id, closest(vtime >= ltime)), na_matches = "never"),
    `after Date` = function(j) j(tabs$visits, tabs$labs,
      by = dplyr::join_by(id, closest(vdate <= ldate)), na_matches = "never"),
    `after Date strict` = function(j) j(tabs$visits, tabs$labs,
      by = dplyr::join_by(id, closest(vdate < ldate)), na_matches = "never"),
    `after numeric` = function(j) j(tabs$visits, tabs$labs,
      by = dplyr::join_by(id, closest(vday <= lday)), na_matches = "never")
  )
  rl <- function(...) list(...)
  specs <- list(
    `between Date` = list("visits", "dose", rl(shape = "between", xCol = "vdate", yFrom = "start", yTo = "end")),
    `between date-time` = list("visits", "dose", rl(shape = "between", xCol = "vtime", yFrom = "tstart", yTo = "tend")),
    `between numeric` = list("visits", "dose", rl(shape = "between", xCol = "vday", yFrom = "nlo", yTo = "nhi")),
    `overlaps Date` = list("ae", "dose", rl(shape = "overlaps", xFrom = "ae_start", xTo = "ae_end",
                                            yFrom = "start", yTo = "end")),
    `window Date` = list("visits", "labs", rl(shape = "window", xCol = "vdate", yCol = "ldate", from = -7, to = 7)),
    `window Date zero` = list("visits", "labs", rl(shape = "window", xCol = "vdate", yCol = "ldate", from = 0, to = 3)),
    `window date-time` = list("visits", "labs", rl(shape = "window", xCol = "vtime", yCol = "ltime", from = -10, to = -2)),
    `window numeric` = list("visits", "labs", rl(shape = "window", xCol = "vday", yCol = "lday", from = -7, to = 7)),
    `before Date` = list("visits", "labs", rl(shape = "before", xCol = "vdate", yCol = "ldate", inclusive = TRUE)),
    `before Date strict` = list("visits", "labs", rl(shape = "before", xCol = "vdate", yCol = "ldate", inclusive = FALSE)),
    `before date-time` = list("visits", "labs", rl(shape = "before", xCol = "vtime", yCol = "ltime", inclusive = TRUE)),
    `after Date` = list("visits", "labs", rl(shape = "after", xCol = "vdate", yCol = "ldate", inclusive = TRUE)),
    `after Date strict` = list("visits", "labs", rl(shape = "after", xCol = "vdate", yCol = "ldate", inclusive = FALSE)),
    `after numeric` = list("visits", "labs", rl(shape = "after", xCol = "vday", yCol = "lday", inclusive = TRUE))
  )
  # left, inner, semi and anti for every shape: the four types a nearest match allows
  cases <- list()
  for (nm in names(specs)) for (type in names(jf)) for (pipe in c("%>%", "|>")) {
    cases[[length(cases) + 1]] <- list(label = paste(nm, type, pipe), name = nm, pipe = pipe,
                                       left = specs[[nm]][[1]], right = specs[[nm]][[2]],
                                       type = type, rule = specs[[nm]][[3]])
  }
  code <- compose_rule_cases(cases)

  env <- new.env(parent = globalenv())
  env$`%>%` <- dplyr::`%>%`
  list2env(tabs, envir = env)
  norm <- function(df) dplyr::arrange(as.data.frame(df), dplyr::across(dplyr::everything()))
  got_by_label <- list()
  for (i in seq_along(cases)) {
    cs <- cases[[i]]
    got <- eval(parse(text = code[[i]]), envir = env)
    want <- refs[[cs$name]](jf[[cs$type]])
    expect_equal(norm(got), norm(want), label = cs$label)
    expect_false(any(c(".sv_lo", ".sv_hi") %in% names(got)), label = cs$label)
    got_by_label[[cs$label]] <- got
  }
  # the rules do something: a window keeps 3 labs for visit 1, a nearest match keeps the tie (both
  # labs on 2024-01-12) and a visit with no date still gets its row from a left join
  win <- got_by_label[["window Date left_join %>%"]]
  expect_equal(sum(win$id == 1 & win$vdate == as.Date("2024-01-10"), na.rm = TRUE), 3L)
  before <- got_by_label[["before Date left_join %>%"]]
  expect_equal(nrow(before), 6L)
  expect_equal(sum(before$id == 1 & before$vdate == as.Date("2024-02-01"), na.rm = TRUE), 2L)
  expect_true(any(is.na(before$vdate) & before$id == 3))
})

test_that("same-named and non-syntactic rule columns run", {
  # `date` is in both tables: the result keeps date.x and date.y
  a <- data.frame(id = 1:3, date = as.Date(c("2024-01-10", "2024-02-01", NA)))
  b <- data.frame(id = c(1, 1, 2), date = as.Date(c("2024-01-01", "2024-01-05", "2024-01-20")), z = 1:3)
  # a column named `visit date`
  w <- data.frame(id = 1:3, `visit date` = as.Date(c("2024-01-10", "2024-02-01", NA)), check.names = FALSE)
  kinds <- list(a = list(date = "Date"), b = list(date = "Date"),
                w = list(`visit date` = "Date"))
  cases <- list(
    list(left = "a", right = "b", rule = list(shape = "before", xCol = "date", yCol = "date", inclusive = TRUE)),
    list(left = "a", right = "b", rule = list(shape = "window", xCol = "date", yCol = "date", from = -7, to = 7)),
    list(left = "w", right = "b", rule = list(shape = "before", xCol = "visit date", yCol = "date", inclusive = TRUE)),
    list(left = "w", right = "b", pipe = "|>",
         rule = list(shape = "window", xCol = "visit date", yCol = "date", from = -10, to = 10))
  )
  code <- compose_rule_cases(cases, kinds)
  for (cd in code) expect_parses(cd)
  expect_match(code[[3]], "closest(`visit date` >= date)", fixed = TRUE)
  expect_match(code[[4]], ".sv_lo = `visit date` - 10", fixed = TRUE)

  env <- new.env(parent = globalenv())
  env$`%>%` <- dplyr::`%>%`
  list2env(list(a = a, b = b, w = w), envir = env)
  r1 <- eval(parse(text = code[[1]]), envir = env)
  expect_true(all(c("date.x", "date.y") %in% names(r1)))
  expect_equal(r1$date.y, as.Date(c("2024-01-05", "2024-01-20", NA)))
  r2 <- eval(parse(text = code[[2]]), envir = env)
  expect_true(all(c("date.x", "date.y") %in% names(r2)))
  expect_false(any(c(".sv_lo", ".sv_hi") %in% names(r2)))
  r3 <- eval(parse(text = code[[3]]), envir = env)
  expect_true("visit date" %in% names(r3))
  expect_equal(r3$date, as.Date(c("2024-01-05", "2024-01-20", NA)))
  r4 <- eval(parse(text = code[[4]]), envir = env)
  expect_identical(names(r4), c("id", "visit date", "date", "z"))
  expect_equal(nrow(r4), 4L)  # visit 1 matches two labs (9 and 5 days before); 2 and 3 none
})

test_that("an invalid rule falls back to the key join", {
  base <- list(left = "visits", right = "labs")
  rule <- list(shape = "window", xCol = "vdate", yCol = "ldate", from = -7, to = 7)
  code <- compose_rule_cases(list(
    c(base, list(rule = NULL)),
    c(base, list(rule = rule)),
    c(base, list(rule = rule, pipe = "|>"))
  ))
  # the second and third have a valid rule; now the kind of ldate changes under them
  kinds <- rule_kinds
  kinds$labs$ldate <- "character"
  bad <- compose_rule_cases(list(
    c(base, list(rule = rule)),
    c(base, list(rule = rule, pipe = "|>"))
  ), kinds)
  plain <- compose_rule_cases(list(c(base, list(rule = NULL)), c(base, list(rule = NULL, pipe = "|>"))), kinds)
  expect_identical(bad, plain)
  expect_identical(code[[1]], 'visits %>%\n  dplyr::left_join(labs, by = "id")')
  expect_false(grepl("join_by", bad[[1]], fixed = TRUE))
  expect_true(grepl("join_by", code[[2]], fixed = TRUE))
  expect_parses(bad[[1]])
  expect_parses(bad[[2]])
})
