# Real-browser accessibility tests: the AX tree and the keyboard (spec section 9).

test_that("every control has an accessible name (canvas, all modes)", {
  skip_if_no_browser()
  sessions <- list()
  withr::defer(for (b in sessions) {
    try(b$close(), silent = TRUE)
    app <- attr(b, "sv_app")
    if (!is.null(app)) try(app$proc$kill(), silent = TRUE)
  })
  for (mode in names(sv_a11y_pages())) {
    b <- sv_a11y_pages()[[mode]]$open(theme = "light", width = 1360, height = 820)
    sessions[[mode]] <- b
    bad <- sv_ax_unnamed(sv_ax_tree(b))
    expect_equal(nrow(bad), 0, info = paste(mode, paste(bad$role, collapse = ", ")))
  }
})

test_that("Tab reaches the toolbar, then the drawer tabs, in DOM order", {
  skip_if_no_browser()
  b <- sv_a11y_pages()$gadget$open("light", 1360, 820)
  app <- attr(b, "sv_app")
  withr::defer({
    try(b$close(), silent = TRUE)
    if (!is.null(app)) try(app$proc$kill(), silent = TRUE)
  })
  # Cards come first in the DOM (about 40 stops), then the toolbar, then the drawer.
  seen <- character()
  for (i in 1:150) {
    sv_tab(b)
    seen <- c(seen, sv_focus_info(b)$name)
    if (identical(utils::tail(seen, 1), "Pipeline")) break
  }
  expect_true(any(grepl("^Fit", seen)))
  expect_true(any(seen == "Pipeline"))
  expect_true(which(grepl("^Fit", seen))[1] < which(seen == "Pipeline")[1])
})

# Rules that belong to sub-project B (rule id -> reason). Task 16 must remove the target-size
# entry (once B fixes it) and re-run this matrix.
SV_AXE_ACCEPTED <- c(
  "target-size" = "Card controls are 24 px in CSS but the canvas scales cards (fit-to-view zoom < 1), so on-screen size is below 24 px; sub-project B (minimum zoom or zoom-independent chrome)."
)

test_that("axe-core finds no WCAG 2.2 A/AA violation on the canvas (modes x themes x sizes)", {
  skip_if_no_browser()
  skip_if_no_axe()
  for (mode in c("gadget", "widget", "module")) {
    for (theme in c("light", "dark")) {
      for (size in list(c(1360, 820), c(375, 812))) {
        b <- sv_a11y_pages()[[mode]]$open(theme = theme, width = size[1], height = size[2])
        app <- attr(b, "sv_app")
        v <- tryCatch(sv_axe_run(b), finally = {
          try(b$close(), silent = TRUE)
          if (!is.null(app)) try(app$proc$kill(), silent = TRUE)
        })
        v <- v[!v$id %in% names(SV_AXE_ACCEPTED), , drop = FALSE]
        expect_equal(nrow(v), 0,
                     info = paste(mode, theme, size[1], paste(v$id, v$targets, collapse = "; ")))
      }
    }
  }
})

# ---- today's shortcut and typing rules (pinned; sub-project B may change them on purpose) ----

sv_open_gadget <- function() {
  b <- sv_a11y_pages()$gadget$open("light", 1360, 820)
  app <- attr(b, "sv_app")
  withr::defer_parent({
    try(b$close(), silent = TRUE)
    if (!is.null(app)) try(app$proc$kill(), silent = TRUE)
  })
  b
}

sv_canvas_state <- function(b) {
  sv_js(b, "(() => { const c = document.querySelector('.sideview-container');
    return { scale: c._sideviewInstance.panzoom.getScale(),
             collapsed: c.querySelector('.sideview-drawer').classList.contains('collapsed') }; })()")
}

for (sv_sc_state in c(TRUE, FALSE)) {
  local({
    on <- sv_sc_state
    test_that(paste("typing never fires shortcuts, shortcuts", if (on) "on" else "off"), {
      skip_if_no_browser()
      b <- sv_open_gadget()
      sv_js(b, sprintf("document.querySelector('.sideview-container')._sideviewInstance.setShortcuts(%s)", tolower(on)))
      before <- sv_canvas_state(b)
      sv_js(b, "document.querySelector('.sideview-ai-input').focus()")
      sv_key(b, "f", text = "f")
      sv_key(b, "d", text = "d")
      after <- sv_canvas_state(b)
      expect_equal(after$scale, before$scale)
      expect_identical(after$collapsed, before$collapsed)
      expect_identical(sv_js(b, "document.querySelector('.sideview-ai-input').value"), "fd")
    })
  })
}

test_that("canvas shortcuts fire when the canvas owns the keyboard", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_js(b, "document.querySelector('.sideview-container').focus()")
  before <- sv_canvas_state(b)$collapsed
  sv_key(b, "d", text = "d")
  expect_identical(sv_canvas_state(b)$collapsed, !before)
  sv_key(b, "d", text = "d")
  expect_identical(sv_canvas_state(b)$collapsed, before)
})

# ---- live region and announcements (Task 8) ----

sv_announce_log <- function(b) {
  v <- sv_js(b, "JSON.stringify(document.querySelector('.sideview-container')._sideviewInstance.announceLog)")
  as.character(jsonlite::fromJSON(v))
}

sv_join_patients_visits <- function(b) {
  sv_js(b, "document.querySelector('.sideview-container')._sideviewInstance.addConnections([
    {fromTable: 'patients', fromCol: 'patient_id', toTable: 'visits', toCol: 'pid', type: 'left_join'}]); true")
}

test_that("join check is announced as its first sentence", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_join_patients_visits(b)
  expect_true(sv_wait_js(b, "document.querySelector('.sideview-container')._sideviewInstance
    .announceLog.some(m => m.indexOf('Join of') === 0)", timeout = 30))
  env <- new.env(parent = globalenv())
  eval(parse(text = sv_fixture_code), envir = env)
  want <- sv_say_join(sv_join_diagnostics(env$patients, env$visits, by = c(patient_id = "pid")),
                      "patients", "visits")[1]
  got <- grep("^Join of", sv_announce_log(b), value = TRUE)[1]
  expect_identical(got, want)
  # the live region itself is polite, atomic status text and takes no focus
  live <- sv_js(b, "(() => { const a = document.querySelector('.sideview-announcer');
    return { live: a.getAttribute('aria-live'), role: a.getAttribute('role'),
             cls: a.className, focusable: a.tabIndex }; })()")
  expect_identical(live$live, "polite")
  expect_identical(live$role, "status")
  expect_match(live$cls, "sv-sr-only")
  expect_lt(live$focusable, 0)
})

test_that("step changes are announced", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_join_patients_visits(b)
  expect_true(sv_wait_js(b, "document.querySelector('.sideview-container')._sideviewInstance
    .announceLog.indexOf('Join step added. 1 step.') >= 0", timeout = 30))
  sv_js(b, "document.querySelector('.sideview-container')._sideviewInstance.pipeline.undo()")
  expect_true(sv_wait_js(b, "document.querySelector('.sideview-container')._sideviewInstance
    .announceLog.indexOf('Undone. 0 steps.') >= 0", timeout = 30))
})

test_that("announcements are spaced, repeats are re-spoken and text is not parsed as HTML", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  r <- sv_js(b, "(async () => {
    const e = document.querySelector('.sideview-container')._sideviewInstance;
    const el = document.querySelector('.sideview-announcer');
    const seen = [];
    new MutationObserver(() => seen.push([performance.now(), el.textContent]))
      .observe(el, { childList: true, characterData: true, subtree: true });
    e.announce('<b>a</b>'); e.announce('<b>a</b>'); e.announce('c');
    await new Promise(r => setTimeout(r, 1600));
    return { seen: seen, html: el.innerHTML, tags: el.querySelectorAll('b').length }; })()")
  expect_equal(r$tags, 0)
  texts <- vapply(r$seen, function(x) x[[2]], "")
  expect_identical(texts[texts != ""], c("<b>a</b>", "<b>a</b>", "c"))
  expect_true("" %in% texts)  # cleared between the two equal messages
  times <- vapply(r$seen[texts != ""], function(x) x[[1]], 0)
  expect_true(all(diff(times) >= 480))
})

test_that("error toasts are alerts and no toast sits in a live region", {
  skip_if_no_browser()
  for (mode in c("gadget", "widget", "module")) {
    b <- sv_a11y_pages()[[mode]]$open("light", 1360, 820)
    app <- attr(b, "sv_app")
    local({
      withr::defer({
        try(b$close(), silent = TRUE)
        if (!is.null(app)) try(app$proc$kill(), silent = TRUE)
      })
      r <- sv_js(b, "(() => { const e = document.querySelector('.sideview-container')._sideviewInstance;
        e.showToast('x', 'error'); e.showToast('y', 'info');
        const ts = Array.from(document.querySelectorAll('.sideview-toast'));
        const liveAnc = ts.some(t => t.parentElement.closest('[aria-live]') && !t.closest('.sideview-announcer'));
        return { roles: ts.map(t => t.getAttribute('role')), liveAnc: liveAnc,
                 log: e.announceLog.slice(-3) }; })()")
      expect_identical(unlist(r$roles), "alert")  # null (no role) drops out of the list
      expect_false(r$liveAnc)
      expect_true("y" %in% unlist(r$log))
      expect_false("x" %in% unlist(r$log))
    })
  }
})

# ---- announcement fix round 1 ----

sv_eng <- "document.querySelector('.sideview-container')._sideviewInstance"

test_that("a risky join is spoken once: the warning toast stays quiet", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  # a numeric key against a text key: the check reports a type problem and shows a toast
  sv_js(b, sprintf("%s.addConnections([{fromTable: 'patients', fromCol: 'age', toTable: 'labs',
    toCol: 'patient_id', type: 'left_join'}]); true", sv_eng))
  expect_true(sv_wait_js(b, sprintf("%s.announceLog.some(m => m.indexOf('Join of') === 0)", sv_eng)))
  expect_true(sv_wait_js(b, "document.querySelectorAll('.sideview-toast-warning, .sideview-toast-danger').length > 0"))
  Sys.sleep(1)
  r <- sv_js(b, sprintf("(() => ({ log: %s.announceLog,
    toasts: Array.from(document.querySelectorAll('.sideview-toast')).map(t => t.textContent) }))()", sv_eng))
  log <- unlist(r$log)
  expect_equal(sum(grepl("^Join of", log)), 1)
  expect_false(any(unlist(r$toasts) %in% log))
})

test_that("the queue keeps the latest messages and step messages coalesce", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_js(b, sprintf("(() => { const e = %s; window.__spoken = [];
    new MutationObserver(() => { const t = document.querySelector('.sideview-announcer').textContent;
      if (t) window.__spoken.push(t); })
      .observe(document.querySelector('.sideview-announcer'), { childList: true, characterData: true, subtree: true });
    for (let i = 0; i < 10; i++) e.announce('m' + i);
    for (let i = 0; i < 4; i++) e.announce('Undone. ' + i + ' steps.', { coalesce: 'step' });
    return true; })()", sv_eng))
  expect_true(sv_wait_js(b, sprintf("%s._annQueue.length === 0 && !%s._annTimer", sv_eng, sv_eng), timeout = 30))
  Sys.sleep(0.3)
  spoken <- unlist(sv_js(b, "window.__spoken"))
  expect_lte(length(spoken), 4)
  expect_false("m0" %in% spoken)
  expect_true("m9" %in% spoken)
  expect_false("Undone. 0 steps." %in% spoken)
  expect_equal(sv_js(b, sprintf("%s.announceLog.length", sv_eng)), 14)
})

test_that("a profile reply for a column nobody is inspecting stays silent", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  n0 <- sv_js(b, sprintf("%s.announceLog.length", sv_eng))
  sv_js(b, sprintf("(() => { const e = %s; e.inspectTarget = null;
    e.onColumnProfile({ id: JSON.stringify(['patients', 'sex']), kind: 'character', n: 3, n_missing: 0, n_distinct: 2 });
    e.inspectTarget = { table: 'patients', column: 'age' };
    e.onColumnProfile({ id: JSON.stringify(['patients', 'sex']), kind: 'character', n: 3, n_missing: 0, n_distinct: 2 });
    return true; })()", sv_eng))
  Sys.sleep(1)
  expect_equal(sv_js(b, sprintf("%s.announceLog.length", sv_eng)), n0)
  # the inspected column's own reply is spoken
  sv_js(b, sprintf("(() => { %s.columnProfileFor('patients', 'age'); return true; })()", sv_eng))
  expect_true(sv_wait_js(b, sprintf("%s.announceLog.some(m => /^age is a number column/.test(m))", sv_eng)))
})

test_that("destroy() removes the live regions and a later announce is a no-op", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_js(b, sprintf("(() => { const e = %s; e.announce('a'); e.announce('a'); e.announce('b'); e.destroy(); return true; })()", sv_eng))
  Sys.sleep(1)
  r <- sv_js(b, "(() => { const c = document.querySelector('.sideview-container');
    const e = c._sideviewInstance || window.__e; return { regions: c.querySelectorAll('.sideview-announcer, .sideview-announcer-alert').length }; })()")
  expect_equal(r$regions, 0)
  n <- sv_js(b, "(() => { const c = document.querySelector('.sideview-container');
    return window._sideviewInstance ? window._sideviewInstance.announceLog.length : -1; })()")
  sv_js(b, "window._sideviewInstance && window._sideviewInstance.announce('late'); true")
  expect_equal(sv_js(b, "window._sideviewInstance ? window._sideviewInstance.announceLog.length : -1"), n)
  expect_equal(sv_js(b, "document.querySelectorAll('.sideview-announcer').length"), 0)
})

test_that("two module engines on one page have distinct announcers", {
  skip_if_no_browser()
  expr <- paste0(
    "shiny::shinyApp(shiny::fluidPage(sideview::sideviewUI('a', height = '300px'),",
    " sideview::sideviewUI('b', height = '300px')),",
    " function(input, output, session) { sideview::sideviewServer('a', cards = list(patients = patients));",
    " sideview::sideviewServer('b', cards = list(visits = visits)) })")
  app <- sv_start_app(expr)
  b <- sv_open_page(app$url, 1360, 900, wait_for = "document.querySelectorAll('.sideview-container').length === 2 &&
    Array.from(document.querySelectorAll('.sideview-container')).every(c => !!c._sideviewInstance)")
  withr::defer({
    try(b$close(), silent = TRUE)
    try(app$proc$kill(), silent = TRUE)
  })
  r <- sv_js(b, "(async () => { const cs = document.querySelectorAll('.sideview-container');
    const ea = cs[0]._sideviewInstance, eb = cs[1]._sideviewInstance;
    ea.announce('only in a');
    await new Promise(r => setTimeout(r, 900));
    const as = document.querySelectorAll('.sideview-announcer');
    return { n: as.length, a: cs[0].querySelector('.sideview-announcer').textContent,
             b: cs[1].querySelector('.sideview-announcer').textContent,
             same: cs[0].querySelector('.sideview-announcer') === cs[1].querySelector('.sideview-announcer'),
             logb: eb.announceLog.length }; })()")
  expect_equal(r$n, 2)
  expect_false(r$same)
  expect_identical(r$a, "only in a")
  expect_identical(r$b, "")
  expect_equal(r$logb, 0)
})

test_that("an error toast replaces a plain one with a fresh alert element; errors are spoken assertively", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  r <- sv_js(b, sprintf("(async () => { const e = %s;
    e.showToast('first', 'info', 'k'); const t0 = document.querySelector('[data-toast-key=\"k\"]');
    e.showToast('boom', 'error', 'k'); const t1 = document.querySelector('[data-toast-key=\"k\"]');
    e.announce('Merge failed.', { assertive: true });
    await new Promise(r => setTimeout(r, 300));
    return { fresh: t0 !== t1, role: t1.getAttribute('role'), n: document.querySelectorAll('[data-toast-key=\"k\"]').length,
             alert: document.querySelector('.sideview-announcer-alert').textContent,
             polite: document.querySelector('.sideview-announcer').textContent }; })()", sv_eng))
  expect_true(r$fresh)
  expect_identical(r$role, "alert")
  expect_equal(r$n, 1)
  expect_identical(r$alert, "Merge failed.")
  expect_false(identical(r$polite, "Merge failed."))
})

# ---- shortcuts switch (Task 9, WCAG 2.1.4) ----

test_that("shortcuts switch turns single keys off; Ctrl+K stays", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_js(b, "document.querySelector('.sideview-container').focus()")
  before <- sv_canvas_state(b)$collapsed
  sv_js(b, paste0(sv_eng, ".setShortcuts(false)"))
  expect_false(sv_js(b, paste0(sv_eng, ".shortcutsOn()")))
  sv_key(b, "d", text = "d")
  expect_identical(sv_canvas_state(b)$collapsed, before)
  sv_key(b, "k", code = "KeyK", modifiers = 2L)
  expect_true(sv_js(b, "!!document.querySelector('.sideview-search-scrim')"))
  expect_true("Keyboard shortcuts off." %in% sv_announce_log(b))
  sv_key(b, "Escape")
  sv_js(b, paste0(sv_eng, ".setShortcuts(true)"))
  sv_key(b, "d", text = "d")
  expect_identical(sv_canvas_state(b)$collapsed, !before)
  expect_true("Keyboard shortcuts on." %in% sv_announce_log(b))
})

test_that("the ? dialog has a Keyboard shortcuts switch that follows the state", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_js(b, paste0(sv_eng, ".toggleShortcuts(true)"))
  r <- sv_js(b, "(() => { const s = document.querySelector('[data-sv-shortcuts-switch]');
    return { role: s.getAttribute('role'), on: s.getAttribute('aria-checked'), name: s.textContent.trim(),
             first: document.querySelector('.sideview-shortcuts dl') ? s.compareDocumentPosition(
               document.querySelector('.sideview-shortcuts dl')) & 4 : 0 }; })()")
  expect_identical(r$role, "switch")
  expect_identical(r$on, "true")
  expect_match(r$name, "Keyboard shortcuts")
  expect_true(r$first > 0)
  sv_js(b, "document.querySelector('[data-sv-shortcuts-switch]').click()")
  expect_identical(sv_js(b, "document.querySelector('[data-sv-shortcuts-switch]').getAttribute('aria-checked')"), "false")
  expect_false(sv_js(b, paste0(sv_eng, ".shortcutsOn()")))
  sv_js(b, paste0(sv_eng, ".setShortcuts(true)"))
})

test_that("R option turns shortcuts off", {
  skip_if_no_browser()
  app <- sv_start_app("{ options(sideview.shortcuts = FALSE); sideview(patients, visits, labs, run = FALSE) }")
  b <- sv_open_page(app$url, 1360, 820, wait_for = "!!document.querySelector('.sideview-container')._sideviewInstance")
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  expect_false(sv_js(b, paste0(sv_eng, ".shortcutsOn()")))
  sv_js(b, "document.querySelector('.sideview-container').focus()")
  before <- sv_canvas_state(b)$collapsed
  sv_key(b, "d", text = "d")
  expect_identical(sv_canvas_state(b)$collapsed, before)
  # a stored choice wins over the R default
  sv_js(b, paste0(sv_eng, ".setShortcuts(true)"))
  expect_true(sv_js(b, paste0(sv_eng, ".shortcutsOn()")))
  sv_js(b, "localStorage.removeItem('sideview.shortcuts')")
})

test_that("shortcuts switch works when localStorage throws", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  b$Page$enable()
  b$Page$addScriptToEvaluateOnNewDocument(
    "Object.defineProperty(window, 'localStorage', {get: function () { throw new Error('blocked'); }})")
  sv_navigate(b, sv_js(b, "location.href"))
  expect_true(sv_wait_js(b, "!!document.querySelector('.sideview-container')._sideviewInstance && document.querySelectorAll('.sideview-card').length >= 2", timeout = 60))
  expect_true(sv_js(b, "(() => { try { window.localStorage; return false; } catch (e) { return true; } })()"))
  expect_true(sv_js(b, paste0(sv_eng, ".shortcutsOn()")))
  sv_js(b, "document.querySelector('.sideview-container').focus()")
  before <- sv_canvas_state(b)$collapsed
  sv_js(b, paste0(sv_eng, ".setShortcuts(false)"))
  sv_key(b, "d", text = "d")
  expect_identical(sv_canvas_state(b)$collapsed, before)
  sv_js(b, paste0(sv_eng, ".setShortcuts(true)"))
  sv_key(b, "d", text = "d")
  expect_identical(sv_canvas_state(b)$collapsed, !before)
})

# ---- table ARIA (Task 10) ----

test_that("card tables carry row counts", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  tbl <- "document.querySelector('.sideview-card[data-card-name=\"labs\"] table')"
  tree <- sv_ax_tree(b)
  expect_true(any(tree$role == "table" & tree$name == "labs" & !tree$ignored))
  expect_identical(sv_js(b, sprintf("%s.getAttribute('aria-rowcount')", tbl)), "5001")
  expect_identical(sv_js(b, sprintf("%s.getAttribute('aria-colcount')", tbl)), "3")
  expect_identical(sv_js(b, sprintf("%s.querySelector('thead tr').getAttribute('aria-rowindex')", tbl)), "1")
  # scrolled: the first rendered data row's index is its virtual index + 2
  sv_js(b, sprintf("(() => { const s = %s.closest('.sideview-card-body'); s.scrollTop = 2000; s.dispatchEvent(new Event('scroll')); return true; })()", tbl))
  Sys.sleep(0.5)
  r <- sv_js(b, sprintf("(() => { const tr = %s.querySelector('tbody tr[data-virtual-index]');
    return { idx: tr.getAttribute('aria-rowindex'), v: Number(tr.dataset.virtualIndex) }; })()", tbl))
  expect_gt(r$v, 10)
  expect_identical(r$idx, as.character(r$v + 2))
  # a filter leaving few rows: the count follows (rows + header)
  sv_js(b, sprintf("%s._virtualTable.filter(1, 'test', 'equals', 'HbA1c'); true", tbl))
  expect_true(sv_wait_js(b, sprintf("%s._virtualTable.getRowCount() < 5000", tbl)))
  Sys.sleep(0.3)
  r <- sv_js(b, sprintf("({ n: %s._virtualTable.getRowCount(), rc: %s.getAttribute('aria-rowcount') })", tbl, tbl))
  expect_identical(r$rc, as.character(r$n + 1))
  expect_gt(r$n, 0)
  expect_lt(r$n, 5000)
})

test_that("table caption is a screen-reader-only text node with the card name", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  r <- sv_js(b, "(() => { const c = document.querySelector('.sideview-card[data-card-name=\"labs\"] table > caption');
    return { text: c.textContent, kids: c.children.length, cls: c.className, first: c.parentNode.firstElementChild === c }; })()")
  expect_identical(r$text, "labs")
  expect_equal(r$kids, 0)
  expect_match(r$cls, "sv-sr-only")
  expect_true(r$first)
})

# ---- list view shell (Task 12) ----

sv_ax_inside <- function(b, selector) {
  # non-ignored AX nodes whose DOM node lies inside `selector`
  tree <- sv_ax_tree(b)
  tree <- tree[!tree$ignored & !is.na(tree$backend_id), , drop = FALSE]
  b$DOM$enable()
  root <- b$DOM$getDocument()$root$nodeId
  hit <- b$DOM$querySelectorAll(root, selector)$nodeIds
  ids <- integer()
  walk <- function(x) c(x$backendNodeId, unlist(lapply(x$children, walk)))
  for (n in hit) {
    d <- b$DOM$describeNode(nodeId = n, depth = -1L, pierce = TRUE)$node
    ids <- c(ids, walk(d))
  }
  tree[tree$backend_id %in% ids, , drop = FALSE]
}

sv_wait_eng <- "!!document.querySelector('.sideview-container')._sideviewInstance"

test_that("list view hides the canvas from the AX tree and canvas view restores it", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  before <- sv_js(b, "document.querySelector('.sideview-viewport').style.transform")
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  expect_identical(sv_js(b, paste0(sv_eng, ".view")), "list")
  expect_equal(nrow(sv_ax_inside(b, ".sideview-viewport")), 0)
  expect_true(sv_js(b, "[...document.querySelectorAll('.sideview-viewport, .sideview-minimap, .sideview-connector-svg, .sideview-connector-hitlayer')].every(e => e.hidden && e.getAttribute('aria-hidden') === 'true')"))
  expect_gt(nrow(sv_ax_inside(b, ".sideview-listview")), 0)
  sv_js(b, paste0(sv_eng, ".setView('canvas'); true"))
  expect_equal(nrow(sv_ax_inside(b, ".sideview-listview")), 0)
  expect_identical(sv_js(b, "document.querySelector('.sideview-viewport').style.transform"), before)
  expect_gt(nrow(sv_ax_inside(b, ".sideview-viewport")), 0)
})

test_that("list view headings are in order", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  tree <- sv_ax_tree(b)
  h2 <- tree[tree$role == "heading" & !tree$ignored & tree$level %in% 2L, "name"]
  expect_equal(h2, c("Summary", "Tables", "Join", "Merge SUPP", "Transform", "Pipeline", "Code"))
  r <- sv_js(b, "(() => { const l = document.querySelector('.sideview-listview');
    return { tag: l.tagName, role: l.getAttribute('role'), label: l.getAttribute('aria-label'),
             skips: [...l.querySelectorAll('a.sideview-skip')].map(a => a.textContent + '|' + a.getAttribute('href')),
             sentence: l.querySelector('.sideview-lv-summary-text').textContent }; })()")
  expect_identical(r$tag, "SECTION")
  expect_identical(r$role, "region")
  expect_identical(r$label, "sideview list view")
  expect_identical(unlist(r$skips), c("Skip to tables|#sv-lv-tables", "Skip to join|#sv-lv-join", "Skip to code|#sv-lv-code"))
  expect_match(r$sentence, "^3 tables, 0 join steps, 0 pipeline steps\\. No code yet\\.$")
})

test_that("view switch moves focus and announces", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  tog <- "document.querySelector('.sideview-toolbar [data-sv-view-toggle]')"
  sv_js(b, paste0(tog, ".focus()"))
  sv_key(b, "Enter", text = "\r")
  expect_true(sv_wait_js(b, paste0(sv_eng, ".view === 'list'")))
  expect_identical(sv_focus_info(b)$tag, "h2")
  expect_true(sv_wait_js(b, paste0(sv_eng, ".announceLog.slice(-1)[0] === 'List view'")))
  expect_identical(sv_js(b, paste0(tog, ".getAttribute('aria-pressed')")), "true")
  sv_js(b, paste0(tog, ".focus()"))
  sv_key(b, "Enter", text = "\r")
  expect_true(sv_wait_js(b, paste0(sv_eng, ".view === 'canvas'")))
  expect_true(sv_wait_js(b, paste0(sv_eng, ".announceLog.slice(-1)[0] === 'Canvas view'")))
  expect_identical(sv_js(b, paste0(tog, ".getAttribute('aria-pressed')")), "false")
})

test_that("view = 'list' starts in the list view (gadget and widget)", {
  skip_if_no_browser()
  app <- sv_start_app("sideview(patients, visits, labs, view = 'list', run = FALSE)")
  b <- sv_open_page(app$url, 1360, 820, wait_for = sv_wait_eng)
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  expect_identical(sv_js(b, paste0(sv_eng, ".view")), "list")
  expect_true(sv_js(b, "document.querySelector('.sideview-viewport').hidden"))
  expect_false(sv_js(b, paste0(sv_eng, ".shortcutsOn()")))
  # a silent start: no announcement
  expect_equal(sv_js(b, paste0(sv_eng, ".announceLog.length")), 0)
  expect_identical(sv_js(b, paste0(sv_eng, ".getState().view.mode")), "list")
  url <- sv_widget_url("sideview_widget(patients, visits, labs, view = 'list')")
  w <- sv_open_page(url, 1360, 820, wait_for = sv_wait_eng)
  withr::defer(try(w$close(), silent = TRUE))
  expect_identical(sv_js(w, paste0(sv_eng, ".view")), "list")
})

test_that("a restored state's view.mode wins over the view argument; no mode keeps the argument", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_js(b, paste0(sv_eng, ".applyState({ view: { mode: 'list' } }); true"))
  expect_identical(sv_js(b, paste0(sv_eng, ".view")), "list")
  sv_js(b, paste0(sv_eng, ".applyState({ view: { labels_row: true } }); true"))
  expect_identical(sv_js(b, paste0(sv_eng, ".view")), "list")
  sv_js(b, paste0(sv_eng, ".applyState({ view: { mode: 'bogus' } }); true"))
  expect_identical(sv_js(b, paste0(sv_eng, ".view")), "list")
  sv_js(b, paste0(sv_eng, ".applyState({ view: { mode: 'canvas' } }); true"))
  expect_identical(sv_js(b, paste0(sv_eng, ".view")), "canvas")
  open_with <- function(expr) {
    app <- sv_start_app(expr)
    bb <- sv_open_page(app$url, 1360, 820, wait_for = sv_wait_eng)
    withr::defer_parent({ try(bb$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
    bb
  }
  b2 <- open_with("sideview(patients, visits, labs, view = 'canvas', state = list(view = list(mode = 'list')), run = FALSE)")
  expect_identical(sv_js(b2, paste0(sv_eng, ".view")), "list")
  b3 <- open_with("sideview(patients, visits, labs, view = 'list', state = list(view = list(mode = 'canvas')), run = FALSE)")
  expect_identical(sv_js(b3, paste0(sv_eng, ".view")), "canvas")
  b4 <- open_with("sideview(patients, visits, labs, view = 'list', state = list(view = list(labels_row = FALSE)), run = FALSE)")
  expect_identical(sv_js(b4, paste0(sv_eng, ".view")), "list")
})

test_that("shortcuts follow the view when localStorage throws (list half of the Task 9 test)", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  b$Page$enable()
  b$Page$addScriptToEvaluateOnNewDocument(
    "Object.defineProperty(window, 'localStorage', {get: function () { throw new Error('blocked'); }})")
  sv_navigate(b, sv_js(b, "location.href"))
  expect_true(sv_wait_js(b, "!!document.querySelector('.sideview-container')._sideviewInstance && document.querySelectorAll('.sideview-card').length >= 2", timeout = 60))
  expect_true(sv_js(b, "(() => { try { window.localStorage; return false; } catch (e) { return true; } })()"))
  expect_true(sv_js(b, paste0(sv_eng, ".shortcutsOn()")))
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  expect_false(sv_js(b, paste0(sv_eng, ".shortcutsOn()")))
  sw <- "document.querySelector('.sideview-listview [data-sv-shortcuts-switch]')"
  expect_identical(sv_js(b, paste0(sw, ".getAttribute('aria-checked')")), "false")
  sv_js(b, paste0(sw, ".click()"))
  expect_true(sv_js(b, paste0(sv_eng, ".shortcutsOn()")))
  expect_identical(sv_js(b, paste0(sw, ".getAttribute('aria-checked')")), "true")
  sv_js(b, paste0(sv_eng, ".setShortcuts(false); ", sv_eng, ".setView('canvas'); true"))
  expect_false(sv_js(b, paste0(sv_eng, ".shortcutsOn()")))
})

test_that("a hostile table name is never parsed as HTML in the list view", {
  skip_if_no_browser()
  app <- sv_start_app(paste0(
    "sideview(list(`x<img src=x onerror=window.__pwn=1>\"q\" é` = patients, visits = visits), run = FALSE)"))
  b <- sv_open_page(app$url, 1360, 820, wait_for = sv_wait_eng)
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  sv_js(b, paste0(sv_eng, ".setView('list'); ", sv_eng, ".listView.render(); true"))
  r <- sv_js(b, "({ imgs: document.querySelectorAll('.sideview-listview img').length, pwn: !!window.__pwn,
    html: document.querySelector('.sideview-listview').innerHTML.indexOf('<img') })")
  expect_equal(r$imgs, 0)
  expect_false(r$pwn)
  expect_equal(r$html, -1)
  expect_match(sv_js(b, "document.querySelector('.sideview-lv-summary-text').textContent"), "^2 tables")
})

test_that("the list view keeps its summary current and is gone after destroy", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  sv_js(b, paste0(sv_eng, ".pipeline.add({ kind: 'custom', code: 'x |> head()' }); true"))
  expect_true(sv_wait_js(b, "/1 pipeline step\\. Code is ready\\./.test(document.querySelector('.sideview-lv-summary-text').textContent)"))
  sv_js(b, paste0(sv_eng, ".destroy(); true"))
  expect_equal(sv_js(b, "document.querySelectorAll('.sideview-listview').length"), 0)
})
