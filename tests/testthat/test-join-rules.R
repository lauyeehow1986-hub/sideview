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
      // c.lazy: {table: 'duckdb'|'arrow'}; a duckdb card's code is dplyr::tbl(con, <name>)
      const m = {};
      Object.keys(meta).forEach(t => {
        const k = c.lazy ? c.lazy[t] : null;
        m[t] = k ? Object.assign({lazy: k, codeRef: k === 'duckdb' ? 'dplyr::tbl(con, \"' + t + '\")' : t},
          meta[t]) : meta[t];
      });
      p.setTables(m);
      if (c.rule) p.setJoinRule(p.steps[0].id, c.rule);
      // c.then: [[right, xCol, yCol]] key joins of c.left added after the rule join
      (c.then || []).forEach(b => p.addJoinKey(c.left, b[0], b[1], b[2], 'left_join'));
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

# Hand-written data-frame references: j is the dplyr join, the rest is written out literally per shape.
rule_refs <- function(tabs) {
  list(
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
    `window date-time zero` = function(j) tabs$visits |>
      dplyr::mutate(.sv_lo = vtime, .sv_hi = vtime + as.difftime(3, units = "days")) |>
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
}

# The rule of each reference: list(left, right, rule).
rule_specs <- function() {
  rl <- function(...) list(...)
  list(
    `between Date` = list("visits", "dose", rl(shape = "between", xCol = "vdate", yFrom = "start", yTo = "end")),
    `between date-time` = list("visits", "dose", rl(shape = "between", xCol = "vtime", yFrom = "tstart", yTo = "tend")),
    `between numeric` = list("visits", "dose", rl(shape = "between", xCol = "vday", yFrom = "nlo", yTo = "nhi")),
    `overlaps Date` = list("ae", "dose", rl(shape = "overlaps", xFrom = "ae_start", xTo = "ae_end",
                                            yFrom = "start", yTo = "end")),
    `window Date` = list("visits", "labs", rl(shape = "window", xCol = "vdate", yCol = "ldate", from = -7, to = 7)),
    `window Date zero` = list("visits", "labs", rl(shape = "window", xCol = "vdate", yCol = "ldate", from = 0, to = 3)),
    `window date-time` = list("visits", "labs", rl(shape = "window", xCol = "vtime", yCol = "ltime", from = -10, to = -2)),
    `window date-time zero` = list("visits", "labs", rl(shape = "window", xCol = "vtime", yCol = "ltime", from = 0, to = 3)),
    `window numeric` = list("visits", "labs", rl(shape = "window", xCol = "vday", yCol = "lday", from = -7, to = 7)),
    `before Date` = list("visits", "labs", rl(shape = "before", xCol = "vdate", yCol = "ldate", inclusive = TRUE)),
    `before Date strict` = list("visits", "labs", rl(shape = "before", xCol = "vdate", yCol = "ldate", inclusive = FALSE)),
    `before date-time` = list("visits", "labs", rl(shape = "before", xCol = "vtime", yCol = "ltime", inclusive = TRUE)),
    `after Date` = list("visits", "labs", rl(shape = "after", xCol = "vdate", yCol = "ldate", inclusive = TRUE)),
    `after Date strict` = list("visits", "labs", rl(shape = "after", xCol = "vdate", yCol = "ldate", inclusive = FALSE)),
    `after numeric` = list("visits", "labs", rl(shape = "after", xCol = "vday", yCol = "lday", inclusive = TRUE))
  )
}

test_that("rule joins run like join_by on data frames", {
  tabs <- rule_fixture()
  jf <- list(left_join = dplyr::left_join, inner_join = dplyr::inner_join,
             semi_join = dplyr::semi_join, anti_join = dplyr::anti_join)

  refs <- rule_refs(tabs)
  specs <- rule_specs()
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

# ---- rule joins on lazy (duckdb / arrow) chains -----------------------------------------------

# The chain matrix: left x right backends ("df" is a data frame).
lazy_rule_combos <- list(c("df", "duckdb"), c("duckdb", "df"), c("duckdb", "duckdb"), c("duckdb", "arrow"),
                         c("arrow", "duckdb"), c("arrow", "df"), c("arrow", "arrow"), c("df", "arrow"))
lazy_rule_map <- function(left, right, combo) {
  m <- list()
  if (combo[[1]] != "df") m[[left]] <- combo[[1]]
  if (combo[[2]] != "df") m[[right]] <- combo[[2]]
  if (length(m)) m else NULL
}
n_collects <- function(x) lengths(regmatches(x, gregexpr("collect()", x, fixed = TRUE)))

test_that("lazy rule joins parse", {
  kc <- list(
    Date = list(x = "vdate", y = "ldate", lo = "start", hi = "end", axlo = "ae_start", axhi = "ae_end"),
    `date-time` = list(x = "vtime", y = "ltime", lo = "tstart", hi = "tend", axlo = "ae_tstart", axhi = "ae_tend"),
    numeric = list(x = "vday", y = "lday", lo = "nlo", hi = "nhi", axlo = "ae_nlo", axhi = "ae_nhi")
  )
  cases <- list()
  for (combo in lazy_rule_combos) for (pipe in c("%>%", "|>")) for (kind in names(kc)) {
    k <- kc[[kind]]
    cb <- paste(combo, collapse = "x")
    add <- function(label, left, right, ...) {
      cases[[length(cases) + 1]] <<- list(label = paste(label, kind, cb, pipe), shape = label, kind = kind,
                                          combo = cb, pipe = pipe, left = left, right = right,
                                          lazy = lazy_rule_map(left, right, combo), ...)
    }
    add("between", "visits", "dose", rule = list(shape = "between", xCol = k$x, yFrom = k$lo, yTo = k$hi))
    add("overlaps", "ae", "dose",
        rule = list(shape = "overlaps", xFrom = k$axlo, xTo = k$axhi, yFrom = k$lo, yTo = k$hi))
    for (o in list(c(-7, 7), c(0, 3), c(-10, -2))) {
      add(paste0("window", o[1], "_", o[2]), "visits", "labs",
          rule = list(shape = "window", xCol = k$x, yCol = k$y, from = o[1], to = o[2]))
    }
    for (shape in c("before", "after")) for (incl in c(TRUE, FALSE)) {
      for (type in c("left_join", "inner_join", "semi_join", "anti_join")) {
        add(paste(shape, incl, type), "visits", "labs", type = type,
            rule = list(shape = shape, xCol = k$x, yCol = k$y, inclusive = incl))
      }
    }
  }
  code <- compose_rule_cases(cases)
  for (i in seq_along(code)) {
    cs <- cases[[i]]
    cd <- code[[i]]
    expect_parses(cd, cs$label)
    expect_match(cd, 'na_matches = "never"', fixed = TRUE, label = cs$label)
    expect_equal(n_collects(cd), 1L, label = cs$label)
    expect_true(endsWith(cd, "dplyr::collect()"), label = cs$label)
    expect_false(grepl("closest(", cd, fixed = TRUE), label = cs$label)
    expect_false(grepl("by = c(", cd, fixed = TRUE), label = cs$label)
    near <- grepl("^(before|after)", cs$shape)
    if (near && grepl("(left|inner)_join$", cs$shape)) {
      expect_match(cd, "dplyr::mutate(.sv_row = dplyr::row_number())", fixed = TRUE, label = cs$label)
      expect_match(cd, "dplyr::select(-.sv_row, -.sv_yd)", fixed = TRUE, label = cs$label)
    } else if (grepl("^window", cs$shape)) {
      expect_match(cd, "dplyr::select(-.sv_lo, -.sv_hi)", fixed = TRUE, label = cs$label)
    } else {
      expect_false(grepl(".sv_", cd, fixed = TRUE), label = cs$label)
    }
    if (cs$kind == "date-time" && grepl("^window", cs$shape)) {
      expect_false(grepl("difftime", cd, fixed = TRUE), label = cs$label)
      expect_match(cd, "as.POSIXct(vtime) ", fixed = TRUE, label = cs$label)
    }
    # copy = TRUE only where a data frame meets the database
    expect_identical(grepl("copy = TRUE", cd, fixed = TRUE), cs$combo %in% c("duckdbxdf", "arrowxdf"),
                     label = cs$label)
  }

  at <- function(label) code[[match(label, vapply(cases, function(cs) cs$label, ""))]]
  tv <- 'dplyr::tbl(con, "visits")'
  tl <- 'dplyr::tbl(con, "labs")'
  # the nearest match, emulated (closest() has no SQL translation)
  expect_identical(at("before TRUE left_join Date duckdbxduckdb %>%"), paste0(
    tv, " %>%\n",
    "  dplyr::mutate(.sv_row = dplyr::row_number()) %>%\n",
    "  dplyr::left_join(dplyr::mutate(", tl, ", .sv_yd = ldate), by = dplyr::join_by(id, vdate >= .sv_yd), ",
    'na_matches = "never") %>%\n',
    "  dplyr::group_by(.sv_row) %>%\n",
    "  dplyr::filter(is.na(.sv_yd) | .sv_yd == max(.sv_yd, na.rm = TRUE)) %>%\n",
    "  dplyr::ungroup() %>%\n",
    "  dplyr::select(-.sv_row, -.sv_yd) %>%\n",
    "  dplyr::collect()"))
  expect_match(at("after FALSE inner_join Date duckdbxdf |>"),
               'dplyr::inner_join(dplyr::mutate(labs, .sv_yd = ldate), by = dplyr::join_by(id, vdate < .sv_yd), na_matches = "never", copy = TRUE)',
               fixed = TRUE)
  expect_match(at("after FALSE inner_join Date duckdbxdf |>"),
               "dplyr::filter(.sv_yd == min(.sv_yd, na.rm = TRUE))", fixed = TRUE)
  expect_match(at("before FALSE semi_join numeric duckdbxduckdb %>%"),
               paste0("dplyr::semi_join(", tl, ', by = dplyr::join_by(id, vday > lday), na_matches = "never")'),
               fixed = TRUE)
  expect_match(at("after TRUE anti_join Date arrowxdf %>%"),
               'dplyr::anti_join(labs, by = dplyr::join_by(id, vdate <= ldate), na_matches = "never", copy = TRUE)',
               fixed = TRUE)
  # a date-time window on duckdb: TIMESTAMP via as.POSIXct(), days via lubridate::days()
  expect_match(at("window-7_7 date-time duckdbxdf %>%"),
               "dplyr::mutate(.sv_lo = as.POSIXct(vtime) - lubridate::days(7), .sv_hi = as.POSIXct(vtime) + lubridate::days(7))",
               fixed = TRUE)
  # a zero bound is cast too, so both bounds are TIMESTAMP; Date and numeric zero stay the bare column
  expect_match(at("window0_3 date-time arrowxarrow |>"),
               "dplyr::mutate(.sv_lo = as.POSIXct(vtime), .sv_hi = as.POSIXct(vtime) + lubridate::days(3))", fixed = TRUE)
  expect_match(at("window0_3 Date duckdbxduckdb |>"), "dplyr::mutate(.sv_lo = vdate, .sv_hi = vdate + 3L)",
               fixed = TRUE)
  expect_match(at("window0_3 numeric duckdbxduckdb |>"), "dplyr::mutate(.sv_lo = vday, .sv_hi = vday + 3)",
               fixed = TRUE)
  # a Date window on duckdb moves by an integer: 7 would be written 7.0, and DATE - DECIMAL fails
  expect_match(at("window-7_7 Date duckdbxduckdb %>%"), "dplyr::mutate(.sv_lo = vdate - 7L, .sv_hi = vdate + 7L)",
               fixed = TRUE)
  expect_match(at("window-7_7 numeric duckdbxduckdb %>%"), "dplyr::mutate(.sv_lo = vday - 7, .sv_hi = vday + 7)",
               fixed = TRUE)
  expect_match(at("between Date duckdbxduckdb %>%"),
               paste0("dplyr::left_join(dplyr::tbl(con, \"dose\"), by = dplyr::join_by(id, between(vdate, start, end)), ",
                      'na_matches = "never")'), fixed = TRUE)
  # the matrix: arrow moves into duckdb for a rule join
  expect_match(at("between Date arrowxdf %>%"),
               "dplyr::compute(arrow::to_duckdb(visits)) %>%\n  dplyr::left_join(dose, by = dplyr::join_by(", fixed = TRUE)
  expect_match(at("between Date arrowxarrow %>%"),
               "dplyr::compute(arrow::to_duckdb(visits)) %>%\n  dplyr::left_join(dplyr::compute(arrow::to_duckdb(dose)), by = ",
               fixed = TRUE)
  expect_match(at("between Date dfxarrow |>"),
               "dplyr::compute(arrow::to_duckdb(arrow::arrow_table(visits))) |>\n  dplyr::left_join(dplyr::compute(arrow::to_duckdb(dose)), by = ",
               fixed = TRUE)
  expect_match(at("between Date dfxduckdb %>%"),
               'dplyr::copy_to(dbplyr::remote_con(dplyr::tbl(con, "dose")), visits, name = "sideview_visits", overwrite = TRUE)',
               fixed = TRUE)
  expect_match(at("between Date duckdbxarrow %>%"),
               "dplyr::compute(arrow::to_duckdb(dose, con = dbplyr::remote_con(dplyr::tbl(con, \"visits\"))))", fixed = TRUE)
  expect_match(at("between Date arrowxduckdb %>%"),
               "dplyr::compute(arrow::to_duckdb(visits, con = dbplyr::remote_con(dplyr::tbl(con, \"dose\"))))", fixed = TRUE)
})

# Bind the cases' tables: a duckdb table on `con`, an arrow table, or a data frame.
lazy_rule_env <- function(tabs, lazy, con) {
  env <- new.env(parent = globalenv())
  env$`%>%` <- dplyr::`%>%`
  env$con <- con
  for (nm in names(tabs)) {
    k <- lazy[[nm]]
    if (identical(k, "arrow")) env[[nm]] <- arrow::arrow_table(tabs[[nm]])
    else if (!identical(k, "duckdb")) env[[nm]] <- tabs[[nm]]
  }
  env
}
# Build the query, run the garbage collector (a to_duckdb() view nothing holds is dropped), collect.
run_lazy_rule <- function(code, env) {
  invisible(gc())
  q <- eval(parse(text = sub("\\s*(%>%|\\|>)\\s*dplyr::collect\\(\\)\\s*$", "", code)), envir = env)
  invisible(gc())
  dplyr::collect(q)
}
# Rows and columns sorted; a date-time compared as numeric seconds.
norm_rule_rows <- function(x) {
  x <- as.data.frame(x)
  x[] <- lapply(x, function(col) if (inherits(col, "POSIXct")) as.numeric(col) else col)
  x <- x[, sort(names(x)), drop = FALSE]
  x[do.call(order, unname(as.list(x))), , drop = FALSE] |> `rownames<-`(NULL)
}

test_that("lazy rule joins return the in-memory rows", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("arrow")
  skip_if_not_installed("dbplyr")
  tabs <- rule_fixture()
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  for (nm in names(tabs)) DBI::dbWriteTable(con, nm, tabs[[nm]])
  jf <- list(left_join = dplyr::left_join, inner_join = dplyr::inner_join,
             semi_join = dplyr::semi_join, anti_join = dplyr::anti_join)
  refs <- rule_refs(tabs)
  specs <- rule_specs()
  cases <- list()
  for (combo in lazy_rule_combos) for (nm in names(specs)) for (type in names(jf)) {
    sp <- specs[[nm]]
    cases[[length(cases) + 1]] <- list(label = paste(nm, type, paste(combo, collapse = "x")), name = nm,
                                       type = type, left = sp[[1]], right = sp[[2]], rule = sp[[3]],
                                       lazy = lazy_rule_map(sp[[1]], sp[[2]], combo),
                                       pipe = if (length(cases) %% 2) "|>" else "%>%")
  }
  code <- compose_rule_cases(cases)
  got_by_label <- list()
  for (i in seq_along(cases)) {
    cs <- cases[[i]]
    env <- lazy_rule_env(tabs, if (is.null(cs$lazy)) list() else cs$lazy, con)
    got <- tryCatch(run_lazy_rule(code[[i]], env), error = function(e) {
      fail(paste0(cs$label, ": ", conditionMessage(e), "\n", code[[i]])); NULL
    })
    if (is.null(got)) next
    want <- refs[[cs$name]](jf[[cs$type]])
    expect_equal(norm_rule_rows(got), norm_rule_rows(want), tolerance = 1e-12, label = cs$label)
    expect_false(any(grepl("^\\.sv_", names(got))), label = cs$label)
    got_by_label[[cs$label]] <- got
  }
  # the tie (two labs on 2024-01-12) appears twice for the visit of 2024-02-01
  for (cb in c("duckdbxduckdb", "arrowxdf", "dfxarrow")) {
    before <- got_by_label[[paste("before Date left_join", cb)]]
    expect_equal(sum(before$id == 1 & before$vdate == as.Date("2024-02-01"), na.rm = TRUE), 2L, label = cb)
    expect_equal(nrow(before), 6L, label = cb)
  }
})

test_that("same-named rule columns run on duckdb", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("arrow")
  skip_if_not_installed("dbplyr")
  a <- data.frame(id = 1:3, date = as.Date(c("2024-01-10", "2024-02-01", NA)))
  b <- data.frame(id = c(1, 1, 2), date = as.Date(c("2024-01-01", "2024-01-05", "2024-01-20")), z = 1:3)
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "a", a)
  DBI::dbWriteTable(con, "b", b)
  kinds <- list(a = list(date = "Date"), b = list(date = "Date"))
  before <- list(shape = "before", xCol = "date", yCol = "date", inclusive = TRUE)
  window <- list(shape = "window", xCol = "date", yCol = "date", from = -7, to = 7)
  refs <- list(
    before = dplyr::left_join(a, b, by = dplyr::join_by(id, closest(date >= date)), na_matches = "never"),
    window = a |> dplyr::mutate(.sv_lo = date - 7, .sv_hi = date + 7) |>
      dplyr::left_join(b, by = dplyr::join_by(id, between(y$date, x$.sv_lo, x$.sv_hi)), na_matches = "never") |>
      dplyr::select(-.sv_lo, -.sv_hi)
  )
  for (combo in list(c("duckdb", "duckdb"), c("duckdb", "df"), c("arrow", "df"))) {
    lazy <- lazy_rule_map("a", "b", combo)
    cases <- list(list(left = "a", right = "b", rule = before, lazy = lazy),
                  list(left = "a", right = "b", rule = window, lazy = lazy, pipe = "|>"))
    code <- compose_rule_cases(cases, kinds)
    env <- lazy_rule_env(list(a = a, b = b), lazy, con)
    for (i in 1:2) {
      label <- paste(names(refs)[i], paste(combo, collapse = "x"))
      expect_parses(code[[i]], label)
      got <- run_lazy_rule(code[[i]], env)
      expect_true(all(c("date.x", "date.y") %in% names(got)), label = label)
      expect_equal(norm_rule_rows(got), norm_rule_rows(refs[[i]]), tolerance = 1e-12, label = label)
    }
  }
})

test_that("an arrow rule chain moves onto the connection of a later duckdb join", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("arrow")
  skip_if_not_installed("dbplyr")
  tabs <- rule_fixture()
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "dose", tabs$dose)
  refs <- rule_refs(tabs)
  specs <- rule_specs()
  cases <- list()
  for (combo in list(c("arrow", "df"), c("arrow", "arrow"), c("df", "arrow"))) {
    for (nm in c("window Date", "window date-time zero", "before Date", "after numeric")) {
      sp <- specs[[nm]]
      lazy <- lazy_rule_map(sp[[1]], sp[[2]], combo)
      lazy$dose <- "duckdb"
      for (pipe in c("%>%", "|>")) {
        cases[[length(cases) + 1]] <- list(label = paste(nm, paste(combo, collapse = "x"), pipe), name = nm,
                                           left = sp[[1]], right = sp[[2]], rule = sp[[3]], lazy = lazy,
                                           then = list(list("dose", "id", "id")), pipe = pipe)
      }
    }
  }
  code <- compose_rule_cases(cases)
  base_tables <- DBI::dbListTables(con)
  for (i in seq_along(cases)) {
    cs <- cases[[i]]
    expect_parses(code[[i]], cs$label)
    # the rule chain starts on the user's connection, so the duckdb join shares its src
    expect_true(grepl('con = dbplyr::remote_con(dplyr::tbl(con, "dose"))', code[[i]], fixed = TRUE),
                label = cs$label)
    env <- lazy_rule_env(tabs, cs$lazy, con)
    got <- tryCatch(run_lazy_rule(code[[i]], env), error = function(e) {
      fail(paste0(cs$label, ": ", conditionMessage(e), "
", code[[i]])); NULL
    })
    if (is.null(got)) next
    want <- dplyr::left_join(refs[[cs$name]](dplyr::left_join), tabs$dose, by = "id")
    expect_equal(norm_rule_rows(got), norm_rule_rows(want), tolerance = 1e-12, label = cs$label)
    expect_false(any(grepl("^\\.sv_", names(got))), label = cs$label)
  }
  # What the code leaves on the user's connection: no arrow registration once the result is gone, and
  # no new permanent table (compute() and copy = TRUE make TEMPORARY dbplyr_* tables, dropped on close).
  rm(env, got)
  invisible(gc())
  expect_length(duckdb::duckdb_list_arrow(con), 0)
  perm <- DBI::dbGetQuery(con, "select table_name from duckdb_tables() where not temporary")$table_name
  expect_setequal(perm, base_tables)
})

# ---- Strict in the generated code ------------------------------------------------------------

# Synthetic tables for Strict: one patient row per id, labs with several rows per patient.
strict_tables <- function() {
  list(
    patients = data.frame(id = 1:4, pdate = as.Date(c("2024-01-10", "2024-02-01", "2024-01-15", "2024-03-01"))),
    labs = data.frame(id = c(1, 1, 2, 3, 4, 4), lval = 1:6,
                      ldate = as.Date(c("2024-01-08", "2024-01-12", "2024-01-20", "2024-02-01", "2024-02-25",
                                        "2024-03-02")))
  )
}

# Compose the code of join cases with a join check: list(type, pipe, rule, lazy, strict, args).
# `args` is the strict_args map for the join (NULL: no check was made). One Node run for all.
compose_strict_cases <- function(cases, labs_kind = "Date") {
  cases <- lapply(cases, function(cs) {
    if (is.null(cs$pipe)) cs$pipe <- "%>%"
    if (is.null(cs$type)) cs$type <- "left_join"
    if (is.null(cs$strict)) cs$strict <- TRUE
    cs
  })
  json <- jsonlite::toJSON(cases, auto_unbox = TRUE, null = "null")
  file <- tempfile(fileext = ".json")
  on.exit(unlink(file), add = TRUE)
  run_pipeline_js(sprintf("
    const cases = %s;
    const kinds = {patients: {pdate: 'Date'}, labs: {ldate: %s}};
    const codes = cases.map(c => {
      const p = new P.Pipeline({pipe: c.pipe});
      p.addJoinKey('patients', 'labs', 'id', 'id', c.type);
      const m = {};
      Object.keys(kinds).forEach(t => {
        const k = c.lazy ? c.lazy[t] : null;
        m[t] = k ? Object.assign({lazy: k, codeRef: k === 'duckdb' ? 'dplyr::tbl(con, \"' + t + '\")' : t},
          {kinds: kinds[t]}) : {kinds: kinds[t]};
      });
      p.setTables(m);
      const id = p.steps[0].id;
      if (c.rule) p.setJoinRule(id, c.rule);
      if (c.args) p.setJoinCheck(p.joinSig(p.find(id)), c.args);
      if (c.strict) p.setJoinStrict(id, true);
      return p.compose();
    });
    require('fs').writeFileSync(%s, JSON.stringify(codes));
    out = codes.length;
  ", json, jsonlite::toJSON(labs_kind, auto_unbox = TRUE),
  jsonlite::toJSON(normalizePath(file, winslash = "/", mustWork = FALSE), auto_unbox = TRUE)))
  vapply(jsonlite::fromJSON(file, simplifyVector = FALSE), as.character, "")
}

# strict_args as the R join check gives them, in the shape JSON carries them.
strict_args_json <- function(x, y, rule = NULL) {
  d <- sv_join_diagnostics(x, y, "id", rule = rule)
  jsonlite::fromJSON(jsonlite::toJSON(d$strict_args, auto_unbox = TRUE), simplifyVector = FALSE)
}

test_that("strict writes the checked arguments", {
  tabs <- strict_tables()
  # every lab has a patient and every patient has a lab: left, inner and right joins can say "error"
  args <- strict_args_json(tabs$patients, tabs$labs)
  expect_identical(args$left_join$relationship, "one-to-many")
  expect_identical(args$left_join$unmatched, "error")
  # a lab of a patient who is not in the table: a left (or inner) join has no unmatched argument
  orphan <- tabs$labs
  orphan$id[6] <- 9
  args_orphan <- strict_args_json(tabs$patients, orphan)
  expect_null(args_orphan$left_join$unmatched)

  cases <- list()
  for (pipe in c("%>%", "|>")) for (type in c("left_join", "inner_join", "right_join", "full_join",
                                              "semi_join", "anti_join")) {
    cases[[length(cases) + 1]] <- list(label = paste(type, pipe), type = type, pipe = pipe, args = args)
    cases[[length(cases) + 1]] <- list(label = paste(type, "orphan", pipe), type = type, pipe = pipe,
                                       args = args_orphan)
  }
  code <- compose_strict_cases(cases)
  for (i in seq_along(code)) {
    cs <- cases[[i]]
    expect_parses(code[[i]], cs$label)
    words <- strsplit(cs$label, " ")[[1]]
    if (cs$type %in% c("semi_join", "anti_join")) {
      # a filtering join has no relationship argument
      expect_false(grepl("relationship", code[[i]], fixed = TRUE), label = cs$label)
      expect_false(grepl("unmatched", code[[i]], fixed = TRUE), label = cs$label)
      next
    }
    expect_match(code[[i]], 'relationship = "one-to-many"', fixed = TRUE, label = cs$label)
    # unmatched = "error" needs every row of the checked side to match: the right side (labs) for a
    # left join, the left side (patients) for a right join, both for an inner join; never a full join
    want_unmatched <- if ("orphan" %in% words) {
      cs$type == "right_join"
    } else {
      cs$type %in% c("left_join", "inner_join", "right_join")
    }
    expect_identical(grepl('unmatched = "error"', code[[i]], fixed = TRUE), want_unmatched, label = cs$label)
  }
  at <- function(label) code[[match(label, vapply(cases, function(cs) cs$label, ""))]]
  expect_identical(at("left_join %>%"),
                   'patients %>%\n  dplyr::left_join(labs, by = "id", relationship = "one-to-many", unmatched = "error")')
  expect_identical(at("left_join |>"),
                   'patients |>\n  dplyr::left_join(labs, by = "id", relationship = "one-to-many", unmatched = "error")')
  expect_identical(at("left_join orphan %>%"),
                   'patients %>%\n  dplyr::left_join(labs, by = "id", relationship = "one-to-many")')

  # no check yet, a check for another join type, or Strict off: the code is the plain join
  plain <- 'patients %>%\n  dplyr::left_join(labs, by = "id")'
  more <- compose_strict_cases(list(
    list(args = NULL),
    list(args = list(inner_join = list(relationship = "one-to-many"))),
    list(args = args, strict = FALSE)
  ))
  expect_identical(more, rep(plain, 3))

  # a rule join: the arguments come after na_matches
  rule <- list(shape = "window", xCol = "pdate", yCol = "ldate", from = -7, to = 7)
  rargs <- strict_args_json(tabs$patients, tabs$labs, rule = rule)
  rc <- compose_strict_cases(list(
    list(rule = rule, args = rargs), list(rule = rule, args = rargs, pipe = "|>")
  ))
  for (cd in rc) {
    expect_parses(cd)
    expect_match(cd, 'na_matches = "never", relationship = "', fixed = TRUE)
  }

  # a duckdb chain, or an arrow chain that moves onto duckdb, writes neither argument
  lazy_cases <- list(
    list(label = "duckdb", lazy = list(patients = "duckdb", labs = "duckdb"), args = args),
    list(label = "duckdb x df", lazy = list(patients = "duckdb", labs = NULL), args = args),
    list(label = "df x duckdb", lazy = list(patients = NULL, labs = "duckdb"), args = args),
    list(label = "arrow", lazy = list(patients = "arrow", labs = "arrow"), args = args),
    list(label = "arrow rule", lazy = list(patients = "arrow", labs = "arrow"), rule = rule, args = rargs),
    list(label = "duckdb rule", lazy = list(patients = "duckdb", labs = "duckdb"), rule = rule, args = rargs)
  )
  lc <- compose_strict_cases(lazy_cases)
  for (i in seq_along(lc)) {
    expect_parses(lc[[i]], lazy_cases[[i]]$label)
    expect_false(grepl("relationship", lc[[i]], fixed = TRUE), label = lazy_cases[[i]]$label)
    expect_false(grepl("unmatched", lc[[i]], fixed = TRUE), label = lazy_cases[[i]]$label)
  }
})

test_that("an invalid rule does not write the arguments of its check", {
  tabs <- strict_tables()
  rule <- list(shape = "window", xCol = "pdate", yCol = "ldate", from = -7, to = 7)
  rargs <- strict_args_json(tabs$patients, tabs$labs, rule = rule)
  # the rule does not hold for the column kinds: the join falls back to the key join
  code <- compose_strict_cases(list(list(rule = rule, args = rargs)), labs_kind = "character")
  expect_identical(code, 'patients %>%\n  dplyr::left_join(labs, by = "id")')
})

test_that("a strict join fails when the data change", {
  tabs <- strict_tables()
  args <- strict_args_json(tabs$patients, tabs$labs)
  code <- compose_strict_cases(list(list(args = args), list(args = args, pipe = "|>")))
  new_env <- function(patients, labs) {
    env <- new.env(parent = globalenv())
    env$`%>%` <- dplyr::`%>%`
    env$patients <- patients
    env$labs <- labs
    env
  }
  # the data the check saw: the join runs and keeps every lab
  for (cd in code) {
    got <- eval(parse(text = cd), envir = new_env(tabs$patients, tabs$labs))
    expect_equal(nrow(got), nrow(tabs$labs))
  }
  # one extra patient row with a duplicate id: the join is now many-to-many
  dup <- new_env(rbind(tabs$patients, tabs$patients[1, ]), tabs$labs)
  for (cd in code) expect_error(eval(parse(text = cd), envir = dup), "relationship|many|must match at most")
  # a lab with no patient: unmatched = "error" stops the left join
  lost <- new_env(tabs$patients[-4, ], tabs$labs)
  for (cd in code) expect_error(eval(parse(text = cd), envir = lost), "unmatched|match")
})
