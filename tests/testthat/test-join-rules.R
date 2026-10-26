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
