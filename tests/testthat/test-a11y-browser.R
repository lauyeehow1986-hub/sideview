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

# A slow browser start: wait by condition until the engine is up, the document has focus and a frame has painted.
sv_wait_ready_for_keys <- function(b) {
  ok <- sv_wait_js(b, "!!document.querySelector('.sideview-container')._sideviewInstance &&
    document.readyState === 'complete' &&
    new Promise(r => requestAnimationFrame(() => setTimeout(() => r(true), 0)))", timeout = 60)
  expect_true(ok)
  invisible(b)
}

test_that("Tab reaches the toolbar, then the drawer tabs, in DOM order", {
  skip_if_no_browser()
  b <- sv_a11y_pages()$gadget$open("light", 1360, 820)
  app <- attr(b, "sv_app")
  withr::defer({
    try(b$close(), silent = TRUE)
    if (!is.null(app)) try(app$proc$kill(), silent = TRUE)
  })
  sv_wait_ready_for_keys(b)
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

# Rules accepted on the CANVAS view only (rule id -> reason). The list view has none: it passes axe outright.
# The canvas keeps one: card and column-header buttons are 24 px in CSS but the canvas scales cards
# (fit-to-view scale 0.5 to 0.71 here), so they are 12 to 17 px on screen. Making them pass means
# zoom-independent chrome (counter-scaled controls or a minimum zoom), which is a canvas redesign.
SV_AXE_ACCEPTED <- c(
  "target-size" = "Canvas controls scale with the canvas zoom (12 to 17 px on screen); the list view is the accessible path."
)

test_that("axe-core finds no WCAG 2.2 A/AA violation (views x modes x themes x sizes)", {
  skip_if_no_browser()
  skip_if_no_axe()
  for (view in c("canvas", "list")) {
    for (mode in c("gadget", "widget", "module")) {
      for (theme in c("light", "dark")) {
        for (size in list(c(1360, 820), c(375, 812))) {
          b <- sv_a11y_pages()[[mode]]$open(theme = theme, width = size[1], height = size[2])
          app <- attr(b, "sv_app")
          v <- tryCatch({
            if (view == "list") {
              sv_js(b, "document.querySelector('.sideview-container')._sideviewInstance.setView('list'); true")
              stopifnot(sv_wait_js(b, "!!document.querySelector('.sideview-listview h2') && !document.querySelector('.sideview-listview').hidden"))
            }
            sv_axe_run(b)
          }, finally = {
            try(b$close(), silent = TRUE)
            if (!is.null(app)) try(app$proc$kill(), silent = TRUE)
          })
          if (view == "canvas") v <- v[!v$id %in% names(SV_AXE_ACCEPTED), , drop = FALSE]
          expect_equal(nrow(v), 0,
                       info = paste(view, mode, theme, size[1], paste(v$id, v$targets, collapse = "; ")))
        }
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
      sv_wait_ready_for_keys(b)
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
  expect_equal(h2, c("Summary", "Tables", "Join", "Merge SUPP", "Transform", "Pipeline", "Code", "Copilot"))
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

# ---- list view tables (Task 13) ----

sv_lv <- "document.querySelector('.sideview-listview')"
sv_js_str <- function(x) as.character(jsonlite::toJSON(x, auto_unbox = TRUE))
sv_lv_table <- function(name) {
  sprintf("document.querySelector('.sideview-listview [data-sv-table=\"' + CSS.escape(%s) + '\"]')",
          sv_js_str(name))
}
# Rows the list view shows now: aria-rowindex and the cell texts of each row.
sv_lv_rows_js <- function(name) {
  sprintf("(() => { const s = %s; const t = s.querySelector('table');
    return { rc: t.getAttribute('aria-rowcount'), cc: t.getAttribute('aria-colcount'),
      rows: [...t.querySelectorAll('tbody tr')].map(tr => ({ i: tr.getAttribute('aria-rowindex'),
        c: [...tr.cells].map(td => td.textContent) })) }; })()", sv_lv_table(name))
}
sv_lv_btn <- function(name, label) {
  sprintf("[...%s.querySelectorAll('button')].find(b => b.textContent === %s || b.getAttribute('aria-label') === %s)",
          sv_lv_table(name), sv_js_str(label), sv_js_str(label))
}

sv_set_fixture <- function() {
  env <- new.env(parent = globalenv())
  eval(parse(text = sv_fixture_code), envir = env)
  env
}

test_that("list rows table matches the card", {
  skip_if_no_browser()
  fx <- sv_set_fixture()
  b <- sv_open_gadget()
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  heading <- sv_js(b, sprintf("%s.querySelector('h3').textContent", sv_lv_table("labs")))
  expect_identical(heading, "labs, 5,000 rows by 3 columns, full table.")
  r <- sv_js(b, sv_lv_rows_js("labs"))
  expect_identical(r$rc, "5001")
  expect_identical(r$cc, "3")
  expect_equal(length(r$rows), 25)
  sv_js(b, sprintf("%s.click(); true", sv_lv_btn("labs", "Next rows")))
  r <- sv_js(b, sv_lv_rows_js("labs"))
  expect_identical(r$rows[[1]]$i, "27")
  vt <- "document.querySelector('.sideview-card[data-card-name=\"labs\"]')._virtualTable"
  expect <- sv_js(b, sprintf("(() => { const vt = %s; return vt.colNames.map(c => vt.cellText(25, c)); })()", vt))
  expect_identical(unlist(r$rows[[1]]$c), unlist(expect))
  expect_identical(unlist(r$rows[[1]]$c)[3], as.character(fx$labs$value[26]))
  expect_identical(sv_js(b, paste0(sv_eng, ".announceLog.slice(-1)[0]")), "Rows 26 to 50 of 5,000.")
  # the pressed control keeps focus
  expect_identical(sv_focus_info(b)$name, "Next rows")
  # Go to row 4990
  sv_js(b, sprintf("(() => { const s = %s; const i = s.querySelector('input[type=number]');
    i.value = '4990'; i.dispatchEvent(new Event('input', { bubbles: true })); return true; })()", sv_lv_table("labs")))
  sv_js(b, sprintf("%s.click(); true", sv_lv_btn("labs", "Go")))
  r <- sv_js(b, sv_lv_rows_js("labs"))
  expect_equal(length(r$rows), 11)
  expect_identical(r$rows[[1]]$i, "4991")
  expect_identical(sv_js(b, paste0(sv_eng, ".announceLog.slice(-1)[0]")), "Rows 4,990 to 5,000 of 5,000.")
  expect_true(sv_js(b, sprintf("%s.disabled", sv_lv_btn("labs", "Next rows"))))
  expect_false(sv_js(b, sprintf("%s.disabled", sv_lv_btn("labs", "Previous rows"))))
})

test_that("list rows follow canvas sort and filter", {
  skip_if_no_browser()
  fx <- sv_set_fixture()
  b <- sv_open_gadget()
  card <- "document.querySelector('.sideview-card[data-card-name=\"labs\"]')"
  # the canvas: sort by value descending (two sort clicks), then filter value > 10
  sv_js(b, sprintf("(() => { const b = %s.querySelector('[data-action=\"sort-col\"][data-col-name=\"value\"]');
    b.click(); b.click(); return true; })()", card))
  sv_js(b, sprintf("%s._virtualTable.filter(2, 'value', 'gt', '10'); true", card))
  Sys.sleep(1)
  want <- dplyr::arrange(dplyr::filter(fx$labs, value > 10), dplyr::desc(value))
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  expect_true(sv_wait_js(b, sprintf("%s.querySelector('table').getAttribute('aria-rowcount') === '%d'",
                                    sv_lv_table("labs"), nrow(want) + 1L)))
  r <- sv_js(b, sv_lv_rows_js("labs"))
  expect_equal(length(r$rows), 25)
  expect_identical(vapply(r$rows, function(x) x$c[[3]], ""), as.character(want$value[1:25]))
  expect_identical(vapply(r$rows, function(x) x$c[[1]], ""), as.character(want$patient_id[1:25]))
  expect_identical(r$rows[[1]]$i, "2")
})

test_that("list view escapes names", {
  skip_if_no_browser()
  app <- sv_start_app(paste0(
    "sideview(list(`a<b \"c\" é` = data.frame(`x <y>` = 1:3, check.names = FALSE)), run = FALSE)"))
  b <- sv_open_page(app$url, 1360, 820, wait_for = sv_wait_eng)
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  nm <- "a<b \"c\" é"
  r <- sv_js(b, sprintf("(() => { const s = %s; const lv = %s;
    return { found: !!s, h3: s.querySelector('h3').textContent, cap: s.querySelector('caption').textContent,
      item: s.querySelector('ul li').textContent,
      btns: [...s.querySelectorAll('ul li button')].map(b => b.getAttribute('aria-label') || b.textContent),
      bold: lv.querySelectorAll('b').length, html: lv.innerHTML.indexOf('<b ') }; })()",
    sv_lv_table(nm), sv_lv))
  expect_true(r$found)
  expect_true(grepl(nm, r$h3, fixed = TRUE))
  expect_identical(r$cap, paste(nm, "rows"))
  expect_true(grepl("x <y>", r$item, fixed = TRUE))
  expect_true(all(c("Sort x <y>", "Filter x <y>", "Inspect x <y>") %in% unlist(r$btns)))
  expect_equal(r$bold, 0)
  expect_equal(r$html, -1)
})

test_that("a table with more than 30 columns starts closed", {
  skip_if_no_browser()
  app <- sv_start_app(paste0(
    "sideview(list(wide = as.data.frame(setNames(as.list(1:40), paste0('v', 1:40))), narrow = data.frame(a = 1:3)), run = FALSE)"))
  b <- sv_open_page(app$url, 1360, 820, wait_for = sv_wait_eng)
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  r <- sv_js(b, sprintf("(() => { const d = %s.querySelector('details');
    return { open: d.open, sum: d.querySelector('summary').textContent, n: d.querySelectorAll('li').length,
      narrow: !%s.querySelector('details') }; })()", sv_lv_table("wide"), sv_lv_table("narrow")))
  expect_false(r$open)
  expect_identical(r$sum, "Columns (40)")
  expect_equal(r$n, 40)
  expect_true(r$narrow)
})

test_that("Inspect writes the profile sentences", {
  skip_if_no_browser()
  fx <- sv_set_fixture()
  b <- sv_open_gadget()
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  sv_js(b, sprintf("%s.click(); true", sv_lv_btn("patients", "Inspect age")))
  expect_true(sv_wait_js(b, sprintf("%s.querySelectorAll('li p').length > 2", sv_lv_table("patients"))))
  got <- sv_js(b, sprintf("[...%s.querySelectorAll('li p')].map(p => p.textContent)", sv_lv_table("patients")))
  expect_identical(unlist(got), sv_say_profile(sv_column_profile(fx$patients$age), "age"))
  item <- sv_js(b, sprintf("%s.querySelector('ul li').textContent", sv_lv_table("patients")))
  expect_match(item, "^patient_id, text")
})

test_that("list view updates keep the sections, the page and the open details", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  sv_js(b, sprintf("%s.click(); true", sv_lv_btn("labs", "Next rows")))
  sv_js(b, paste0("window.__marker = ", sv_lv_table("labs"), "; true"))
  # a hand-off to the canvas and back, and an llm message, must not rebuild the sections
  sv_js(b, paste0(sv_eng, ".setView('canvas'); ", sv_eng, ".setView('list'); true"))
  sv_js(b, sprintf("%s.listView.updateSections(); true", sv_eng))
  expect_true(sv_js(b, paste0("window.__marker === ", sv_lv_table("labs"))))
  r <- sv_js(b, sv_lv_rows_js("labs"))
  expect_identical(r$rows[[1]]$i, "27")
})

test_that("column counts: full in-memory cards show them, sampled and preview cards do not guess", {
  skip_if_no_browser()
  fx <- sv_set_fixture()
  app <- sv_start_app(paste0(
    "sideview(list(patients = patients, bigcat = data.frame(k = sprintf('k%d', seq_len(30000)), n = c(rep(NA, 10), seq_len(29990)))), run = FALSE)"))
  b <- sv_open_page(app$url, 1360, 820, wait_for = sv_wait_eng)
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  txt <- function(tbl, i) sv_js(b, sprintf("%s.querySelectorAll('ul li .sideview-lv-col-text')[%d].textContent", sv_lv_table(tbl), i))
  sex <- txt("patients", 1)
  expect_identical(sex, sprintf("sex, text, %d values, %d missing",
                                length(unique(stats::na.omit(fx$patients$sex))), sum(is.na(fx$patients$sex))))
  # a sampled categorical (30,000 values): "~N distinct" is never read as exact
  k <- txt("bigcat", 0)
  expect_false(grepl("values", k))
  # the bare-title case: a title in an unexpected format gives no count
  r <- sv_js(b, "(() => { const lv = window._sideviewInstance.listView; const st = lv.tableState('patients');
    const th = st.meta.element.querySelectorAll('thead th')[1];
    const cat = th.querySelector('.sideview-cat-profile'); cat.setAttribute('title', 'Top: x | about 4 distinct');
    const na = th.querySelector('.sideview-na-badge'); if (na) na.setAttribute('title', 'lots missing');
    return lv.columnText(st, 1); })()")
  expect_identical(r, "sex, text")
})

# ---- list view join and Merge SUPP (Task 14) ----

sv_lv_join <- "document.querySelector('.sideview-listview [data-sv-lv-body=\"join\"]')"
# Pick a value in a labelled select of the Join form (first match of a field id) and fire change.
sv_lv_pick <- function(b, field, value, idx = 0) {
  sv_js(b, sprintf("(() => { const s = %s.querySelectorAll('select[data-sv-field=%s]')[%d];
    s.value = %s; s.dispatchEvent(new Event('change', { bubbles: true })); return s.value; })()",
                   sv_lv_join, sv_js_str(field), idx, sv_js_str(value)))
}
sv_lv_join_form <- function(b, left = "patients", lcol = "patient_id", right = "visits", rcol = "pid") {
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  sv_lv_pick(b, "left-table", left)
  sv_lv_pick(b, "right-table", right)
  sv_lv_pick(b, "left-column", lcol)
  sv_lv_pick(b, "right-column", rcol)
}
sv_lv_join_paras <- function(b) {
  as.character(unlist(sv_js(b, sprintf(
    "[...%s.querySelectorAll('[data-sv-join-result] p')].map(p => p.textContent)", sv_lv_join))))
}
sv_lv_join_btn <- function(label) {
  sprintf("[...%s.querySelectorAll('button')].find(x => x.textContent === %s)", sv_lv_join, sv_js_str(label))
}

test_that("list join check speaks the R sentence", {
  skip_if_no_browser()
  fx <- sv_set_fixture()
  b <- sv_open_gadget()
  sv_lv_join_form(b)
  sv_js(b, paste0(sv_lv_join_btn("Check join"), ".click(); true"))
  want <- sv_say_join(sv_join_diagnostics(fx$patients, fx$visits, by = c(patient_id = "pid")),
                      "patients", "visits")
  expect_true(sv_wait_js(b, sprintf("%s.querySelectorAll('[data-sv-join-result] p').length === %d",
                                    sv_lv_join, length(want)), timeout = 30))
  expect_identical(sv_lv_join_paras(b), want)
  expect_true(want[1] %in% sv_announce_log(b))
  expect_false(sv_js(b, paste0(sv_lv_join_btn("Add join step"), ".disabled")))
})

test_that("Add join step adds one step and draws its spline", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_lv_join_form(b)
  sv_js(b, paste0(sv_lv_join_btn("Check join"), ".click(); true"))
  expect_true(sv_wait_js(b, sprintf("!%s.disabled", sv_lv_join_btn("Add join step")), timeout = 30))
  sv_js(b, paste0(sv_lv_join_btn("Add join step"), ".click(); true"))
  expect_equal(sv_js(b, paste0(sv_eng, ".pipeline.enabledCount()")), 1)
  expect_equal(sv_js(b, "document.querySelectorAll('.sideview-connector-svg path').length"), 1)
  foc <- sv_js(b, "(() => { const a = document.activeElement;
    return { step: a.getAttribute('data-step-id'), tag: a.tagName, text: a.textContent.slice(0, 40) }; })()")
  want_id <- sv_js(b, paste0(sv_eng, ".pipeline.steps[0].id"))
  expect_true(identical(foc$step, want_id) ||
                (grepl("^H[1-6]$", foc$tag) && grepl("Pipeline", foc$text)))
})

test_that("a failing check keeps Add disabled", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_lv_join_form(b)
  sv_lv_pick(b, "rule-shape", "before")
  # text columns are not dates
  sv_lv_pick(b, "rule-xCol", "patient_id")
  sv_lv_pick(b, "rule-yCol", "pid")
  sv_js(b, paste0(sv_lv_join_btn("Check join"), ".click(); true"))
  expect_true(sv_wait_js(b, sprintf("%s.querySelector('[data-sv-join-result] p') &&
    %s.querySelector('[data-sv-join-result] p').textContent !== 'Checking the join.'", sv_lv_join, sv_lv_join),
    timeout = 30))
  paras <- sv_lv_join_paras(b)
  expect_gt(length(paras), 0)
  expect_match(paras[1], "(?i)(not|cannot|can't|no |error|date)")
  expect_true(sv_js(b, paste0(sv_lv_join_btn("Add join step"), ".disabled")))
})

test_that("key pairs add and remove, the last one stays, input survives view switches", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_lv_join_form(b)
  n <- function() sv_js(b, sprintf("%s.querySelectorAll('.sideview-lv-pair').length", sv_lv_join))
  sv_js(b, paste0(sv_lv_join_btn("Add another key pair"), ".click(); true"))
  expect_equal(n(), 2)
  sv_js(b, sprintf("%s.querySelectorAll('[data-sv-lv-action=\"remove-pair\"]')[1].click(); true", sv_lv_join))
  expect_equal(n(), 1)
  expect_true(sv_js(b, sprintf("%s.querySelector('[data-sv-lv-action=\"remove-pair\"]').disabled", sv_lv_join)))
  for (i in 1:3) {
    sv_js(b, paste0(sv_eng, ".setView('canvas'); ", sv_eng, ".setView('list'); true"))
  }
  got <- sv_js(b, sprintf("[...%s.querySelectorAll('select[data-sv-field]')].slice(0, 4).map(s => s.value)", sv_lv_join))
  expect_identical(as.character(unlist(got)), c("patients", "visits", "patient_id", "pid"))
  expect_equal(sv_js(b, "document.querySelectorAll('.sideview-listview').length"), 1)
})

sv_lv_cdisc_page <- function() {
  skip_if_no_browser()
  root <- sv_pkg_root()
  if (!nzchar(root)) skip("CDISC browser tests need the source tree (helper-cdisc.R)")
  helper <- normalizePath(file.path(root, "tests", "testthat", "helper-cdisc.R"), winslash = "/")
  app <- sv_start_app(app_expr = sprintf(
    "{ source('%s'); f <- sv_cdisc_fixtures(); sideview(dm = f$dm, ae = f$ae, adae = f$adae_pfx, suppae = f$suppae, run = FALSE) }",
    helper))
  b <- sv_open_page(app$url, 1360, 820, wait_for = sv_wait_eng)
  withr::defer_parent({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  b
}

test_that("CDISC group adds as one undo step", {
  b <- sv_lv_cdisc_page()
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  sv_js(b, paste0(sv_lv_join_btn("Suggest joins"), ".click(); true"))
  expect_true(sv_wait_js(b, sprintf("%s.querySelectorAll('[data-sv-suggestions] li').length > 0", sv_lv_join),
                         timeout = 30))
  idx <- sv_js(b, sprintf("[...%s.querySelectorAll('[data-sv-suggestions] li')].findIndex(
    l => /^adae to ae by/.test(l.textContent))", sv_lv_join))
  expect_gte(idx, 0)
  sv_js(b, sprintf("%s.querySelectorAll('[data-sv-suggestions] li')[%d].querySelector('button').click(); true",
                   sv_lv_join, idx))
  n <- sv_js(b, paste0(sv_eng, ".pipeline.steps.filter(s => s.kind === 'join').reduce((a, s) => a + s.by.length, 0)"))
  expect_gt(n, 1)
  sv_js(b, paste0(sv_eng, ".pipeline.undo(); true"))
  expect_equal(sv_js(b, paste0(sv_eng, ".pipeline.steps.length")), 0)
})

test_that("SUPP check and merge from the list", {
  b <- sv_lv_cdisc_page()
  f <- (function() { source(file.path(sv_pkg_root(), "tests", "testthat", "helper-cdisc.R"), local = TRUE)
    sv_cdisc_fixtures() })()
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  sel <- "document.querySelector('.sideview-listview [data-sv-supp=\"suppae\"]')"
  expect_identical(sv_js(b, paste0(sel, ".querySelector('h3').textContent")),
                   "suppae into ae, 1 QNAM")
  btn <- function(l) sprintf("[...%s.querySelectorAll('button')].find(x => x.textContent === %s)", sel, sv_js_str(l))
  sv_js(b, paste0(btn("Check"), ".click(); true"))
  want <- sv_say_supp(sv_supp_check(f$ae, f$suppae, parent_name = "ae", supp_name = "suppae"), "ae", "suppae")
  expect_true(sv_wait_js(b, sprintf("%s.querySelectorAll('[data-sv-supp-result] p').length === %d", sel, length(want)),
                         timeout = 30))
  got <- as.character(unlist(sv_js(b, sprintf("[...%s.querySelectorAll('[data-sv-supp-result] p')].map(p => p.textContent)", sel))))
  expect_identical(got, want)
  sv_js(b, paste0(btn("Merge"), ".click(); true"))
  expect_true(sv_wait_js(b, paste0(sv_eng, ".pipeline.steps.some(s => s.kind === 'supp')"), timeout = 30))
})

test_that("reply lands after a view switch", {
  skip_if_no_browser()
  fx <- sv_set_fixture()
  b <- sv_open_gadget()
  sv_lv_join_form(b)
  sv_js(b, paste0(sv_lv_join_btn("Check join"), ".click(); ", sv_eng, ".setView('canvas'); true"))
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  want <- sv_say_join(sv_join_diagnostics(fx$patients, fx$visits, by = c(patient_id = "pid")),
                      "patients", "visits")
  expect_true(sv_wait_js(b, sprintf("%s.querySelectorAll('[data-sv-join-result] p').length === %d",
                                    sv_lv_join, length(want)), timeout = 30))
  expect_identical(sv_lv_join_paras(b), want)
})

test_that("hostile names are literal text in the join form, suggestions and SUPP sections", {
  skip_if_no_browser()
  root <- sv_pkg_root()
  if (!nzchar(root)) skip("needs the source tree (helper-cdisc.R)")
  helper <- normalizePath(file.path(root, "tests", "testthat", "helper-cdisc.R"), winslash = "/")
  app <- sv_start_app(app_expr = sprintf(r"({ source('%s'); f <- sv_cdisc_fixtures();
    a <- f$ae; names(a)[names(a) == 'AETERM'] <- 'te<b>x"t é';
    s <- list(`ae<i>"é x` = a, `supp <u>"é` = f$suppae);
    do.call(sideview, c(s, list(cdisc = c(`ae<i>"é x` = 'AE', `supp <u>"é` = 'SUPPAE'), run = FALSE))) })", helper))
  b <- sv_open_page(app$url, 1360, 820, wait_for = sv_wait_eng)
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  sv_js(b, "window.__errs = []; window.addEventListener('error', e => window.__errs.push(String(e.message))); true")
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  sv_js(b, paste0(sv_lv_join_btn("Suggest joins"), ".click(); true"))
  expect_true(sv_wait_js(b, sprintf("%s.querySelectorAll('[data-sv-suggestions] li').length > 0", sv_lv_join), timeout = 30))
  r <- sv_js(b, sprintf("(() => { const j = %s, s = document.querySelector('.sideview-listview [data-sv-lv-body=\"supp\"]');
    return { inj: j.querySelectorAll('b, i, u, img').length + s.querySelectorAll('b, i, u, img').length,
      opts: [...j.querySelectorAll('select')[0].options].map(o => o.textContent),
      cols: [...j.querySelectorAll('select[data-sv-field=\"left-column\"] option')].map(o => o.textContent),
      sug: [...j.querySelectorAll('[data-sv-suggestions] li')].map(l => l.textContent),
      h3: [...s.querySelectorAll('h3')].map(h => h.textContent), errs: window.__errs }; })()", sv_lv_join))
  expect_equal(r$inj, 0)
  expect_true(any(grepl("ae<i>\"é x", unlist(r$opts), fixed = TRUE)))
  expect_true(any(grepl("supp <u>\"é", unlist(r$h3), fixed = TRUE)))
  expect_length(r$errs, 0)
  # pick the hostile left table: its hostile column shows as text
  sv_lv_pick(b, "left-table", "ae<i>\"é x")
  cols <- unlist(sv_js(b, sprintf("[...%s.querySelectorAll('select[data-sv-field=\"left-column\"] option')].map(o => o.textContent)", sv_lv_join)))
  expect_true('te<b>x"t é' %in% cols)
})

# ---- list view transform, pipeline, code and Copilot via pane moves (Task 15) ----

sv_lv_sections <- function(b) {
  unlist(sv_js(b, "[...document.querySelectorAll('.sideview-listview h2')].map(h => h.textContent)"))
}

test_that("moved panes keep input and fire once", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_js(b, paste0(sv_eng, ".activateDrawerTab('filter'); document.querySelector('.sideview-drawer').classList.remove('collapsed'); true"))
  sv_js(b, "(() => { const i = document.querySelector('[data-pane=\"filter\"] [data-field=\"val\"]');
    i.value = 'age > 5'; i.setAttribute('data-test-id', 'keep'); return true; })()")
  idx <- sv_js(b, "[...document.querySelector('.sideview-drawer-content').children].indexOf(document.querySelector('[data-pane=\"filter\"]'))")
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  r <- sv_js(b, "(() => { const i = document.querySelector('[data-test-id=\"keep\"]');
    return { inside: !!i.closest('.sideview-listview'), v: i.value,
             h3: i.closest('[data-sv-lv-builder]').querySelector('h3').textContent,
             hidden: document.querySelector('.sideview-drawer').hidden,
             actions: !!document.querySelector('.sideview-listview .sideview-drawer-actions'),
             steps: !!document.querySelector('.sideview-listview [data-pane=\"pipeline\"] .sideview-step-list') }; })()")
  expect_true(r$inside)
  expect_identical(r$v, "age > 5")
  expect_identical(r$h3, "Filter")
  expect_true(r$hidden)
  expect_true(r$actions)
  expect_true(r$steps)
  # the builder's Add, from the keyboard, adds exactly one step
  before <- sv_js(b, paste0(sv_eng, ".pipeline.enabledCount()"))
  sv_js(b, "document.querySelector('.sideview-listview [data-builder=\"filter\"] [data-builder-action=\"submit\"]').focus(); true")
  sv_key(b, "Enter", text = "\r")
  expect_true(sv_wait_js(b, sprintf("%s.pipeline.enabledCount() === %d", sv_eng, before + 1L)))
  # settle by a condition (one more round trip through the page), then it is still before + 1
  expect_true(sv_wait_js(b, "new Promise(r => requestAnimationFrame(() => setTimeout(() => r(true), 0)))"))
  expect_equal(sv_js(b, paste0(sv_eng, ".pipeline.enabledCount()")), before + 1L)
  # canvas <-> list again: still one handler
  sv_js(b, paste0(sv_eng, ".setView('canvas'); ", sv_eng, ".setView('list'); true"))
  sv_js(b, "document.querySelector('.sideview-listview [data-builder=\"filter\"] [data-field=\"val\"]').value = '1'; true")
  sv_js(b, "document.querySelector('.sideview-listview [data-builder=\"filter\"] [data-builder-action=\"submit\"]').click(); true")
  expect_true(sv_wait_js(b, sprintf("%s.pipeline.enabledCount() === %d", sv_eng, before + 2L)))
  expect_true(sv_wait_js(b, "new Promise(r => requestAnimationFrame(() => setTimeout(() => r(true), 0)))"))
  expect_equal(sv_js(b, paste0(sv_eng, ".pipeline.enabledCount()")), before + 2L)
  sv_js(b, paste0(sv_eng, ".setView('canvas'); true"))
  r <- sv_js(b, "(() => { const i = document.querySelector('[data-pane=\"filter\"]');
    return { inDrawer: !!i.closest('.sideview-drawer-content'),
             idx: [...document.querySelector('.sideview-drawer-content').children].indexOf(i),
             hidden: document.querySelector('.sideview-drawer').hidden,
             code: !!document.querySelector('.sideview-drawer > .sideview-drawer-actions'),
             pre: !!document.querySelector('[data-pane=\"pipeline\"] > .sideview-code-block') }; })()")
  expect_true(r$inDrawer)
  expect_equal(r$idx, idx)
  expect_false(r$hidden)
  expect_true(r$code)
  expect_true(r$pre)
})

test_that("Filter from a column opens the builder preset", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  expect_null(sv_js(b, sprintf("%s.getAttribute('aria-disabled')", sv_lv_btn("patients", "Filter age"))))
  sv_js(b, sprintf("%s.click(); true", sv_lv_btn("patients", "Filter age")))
  r <- sv_js(b, "(() => { const a = document.activeElement, bd = document.querySelector('.sideview-listview [data-builder=\"filter\"]');
    return { inBuilder: !!a.closest('[data-sv-lv-builder=\"filter\"]'), tag: a.tagName,
             table: bd.querySelector('[data-field=\"table\"]').value, col: bd.querySelector('[data-field=\"col\"]').value }; })()")
  expect_true(r$inBuilder)
  expect_identical(r$table, "patients")
  expect_identical(r$col, "age")
})

test_that("canvas header sort and filter update the list's rows and count", {
  skip_if_no_browser()
  fx <- sv_set_fixture()
  b <- sv_open_gadget()
  # build the list once and go back, so the list DOM exists while the canvas changes
  sv_js(b, paste0(sv_eng, ".setView('list'); ", sv_eng, ".setView('canvas'); true"))
  card <- "document.querySelector('.sideview-card[data-card-name=\"labs\"]')"
  first_js <- sprintf("%s.querySelector('tbody tr td:nth-child(3)').textContent", sv_lv_table("labs"))
  rc_js <- sprintf("%s.querySelector('table').getAttribute('aria-rowcount')", sv_lv_table("labs"))
  # header sort, descending (two clicks), then the list shows that order
  sv_js(b, sprintf("(() => { const b = %s.querySelector('[data-action=\"sort-col\"][data-col-name=\"value\"]');
    b.click(); b.click(); return true; })()", card))
  desc <- dplyr::arrange(fx$labs, dplyr::desc(value))
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  expect_true(sv_wait_js(b, sprintf("%s === %s", first_js, sv_js_str(as.character(desc$value[1]))), timeout = 30))
  r <- sv_js(b, sv_lv_rows_js("labs"))
  expect_identical(vapply(r$rows, function(x) x$c[[3]], ""), as.character(desc$value[1:25]))
  # a header filter, through the real popover, on the canvas
  sv_js(b, paste0(sv_eng, ".setView('canvas'); true"))
  sv_js(b, sprintf("%s.querySelector('[data-action=\"filter-col\"][data-col-name=\"value\"]').click(); true", card))
  sv_js(b, "(() => { document.querySelector('.sideview-filter-select').value = 'gt';
    document.querySelector('.sideview-filter-input').value = '10';
    document.querySelector('.sideview-filter-apply').click(); return true; })()")
  kept <- dplyr::filter(desc, value > 10)
  expect_lt(nrow(kept), nrow(desc))
  expect_true(sv_wait_js(b, sprintf("%s === '%d'", rc_js, nrow(kept) + 1L), timeout = 30))
  expect_identical(sv_js(b, first_js), as.character(kept$value[1]))
  # clearing it brings every row back
  sv_js(b, sprintf("%s.querySelector('[data-action=\"filter-col\"][data-col-name=\"value\"]').click(); true", card))
  sv_js(b, "document.querySelector('.sideview-filter-clear').click(); true")
  expect_true(sv_wait_js(b, sprintf("%s === '%d'", rc_js, nrow(fx$labs) + 1L), timeout = 30))
  expect_identical(sv_js(b, first_js), as.character(desc$value[1]))
})

test_that("hostile names are literal text in the builders", {
  skip_if_no_browser()
  app <- sv_start_app(paste0(
    "sideview(list(`a<b \"c\" é` = data.frame(`x <y> \"z\" ü` = 1:3, `p q` = c('a','b','c'), check.names = FALSE)), run = FALSE)"))
  b <- sv_open_page(app$url, 1360, 820, wait_for = sv_wait_eng)
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  sv_js(b, "window.__errs = []; window.addEventListener('error', e => window.__errs.push(String(e.message))); true")
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  nm <- "a<b \"c\" é"
  cl <- "x <y> \"z\" ü"
  sv_js(b, sprintf("%s.openBuilder('filter', { table: %s, column: %s }); true", sv_eng, sv_js_str(nm), sv_js_str(cl)))
  r <- sv_js(b, "(() => { const lv = document.querySelector('.sideview-listview');
    const bd = lv.querySelector('[data-builder=\"filter\"]');
    return { table: bd.querySelector('[data-field=\"table\"]').value, col: bd.querySelector('[data-field=\"col\"]').value,
      inj: lv.querySelectorAll('b, u, img, script, svg[onload]').length,
      opts: [...bd.querySelectorAll('[data-field=\"col\"] option')].map(o => o.textContent),
      errs: window.__errs }; })()")
  expect_identical(r$table, nm)
  expect_identical(r$col, cl)
  expect_equal(r$inj, 0)
  expect_true(cl %in% unlist(r$opts))
  expect_length(r$errs, 0)
  # the step it adds, its element id and the Copilot / code surfaces stay literal too
  sv_js(b, "document.querySelector('.sideview-listview [data-builder=\"filter\"] [data-field=\"val\"]').value = 'q\"<i>x'; true")
  sv_js(b, "document.querySelector('.sideview-listview [data-builder=\"filter\"] [data-builder-action=\"submit\"]').click(); true")
  expect_true(sv_wait_js(b, sprintf("%s.pipeline.enabledCount() === 1", sv_eng)))
  r <- sv_js(b, "(() => { const lv = document.querySelector('.sideview-listview');
    return { inj: lv.querySelectorAll('b, i, u, img, script').length,
      ids: [...lv.querySelectorAll('.sideview-step')].map(l => l.id),
      errs: window.__errs }; })()")
  expect_equal(r$inj, 0)
  expect_true(length(r$ids) >= 1 && all(grepl("^[A-Za-z0-9_-]+$", unlist(r$ids))))
  expect_length(r$errs, 0)
})

test_that("step element ids are collision-safe", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  r <- sv_js(b, sprintf("[%s.stepElId({id: 'a b'}), %s.stepElId({id: 'a_b'}), %s.stepElId({id: 'a.b'}), %s.stepElId({id: 'a_b'})]",
                        sv_eng, sv_eng, sv_eng, sv_eng))
  r <- unlist(r)
  expect_equal(length(unique(r[1:3])), 3)
  expect_identical(r[2], r[4])
  expect_true(all(grepl("^[A-Za-z0-9_-]+$", r)))
})

test_that("a builder keeps typed values and focus when its table list changes", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  sv_js(b, sprintf("%s.openBuilder('filter', { table: 'patients', column: 'age' }); true", sv_eng))
  sv_js(b, "(() => { const v = document.querySelector('.sideview-listview [data-builder=\"filter\"] [data-field=\"val\"]');
    v.value = '42'; v.setAttribute('data-test-id', 'old'); v.focus(); return true; })()")
  sv_js(b, sprintf("%s.removeCard('labs'); true", sv_eng))
  expect_true(sv_wait_js(b, "!document.querySelector('[data-test-id=\"old\"]')"))
  r <- sv_js(b, "(() => { const bd = document.querySelector('.sideview-listview [data-builder=\"filter\"]');
    const v = bd.querySelector('[data-field=\"val\"]');
    return { tables: [...bd.querySelectorAll('[data-field=\"table\"] option')].map(o => o.value),
      val: v.value, col: bd.querySelector('[data-field=\"col\"]').value, focused: document.activeElement === v }; })()")
  expect_false("labs" %in% unlist(r$tables))
  expect_identical(r$val, "42")
  expect_identical(r$col, "age")
  expect_true(r$focused)
})

test_that("a module list view has no code-execution buttons and no Copilot without an LLM", {
  skip_if_no_browser()
  app <- sv_start_app(app_file = sv_example_app("proxy"))
  ready <- "(() => { const c = document.querySelector('[data-sv-ns=\"a-\"]'); return !!c && c.querySelectorAll('.sideview-card').length >= 2 && !!c._sideviewInstance; })()"
  b <- sv_open_page(app$url, 1400, 900, wait_for = ready)
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  # the sideview_llm message (no llm_fn) has been processed once the container says so
  expect_true(sv_wait_js(b, "document.querySelector('[data-sv-ns=\"a-\"]').classList.contains('sv-no-llm')"))
  sv_js(b, "document.querySelector('[data-sv-ns=\"a-\"]')._sideviewInstance.setView('list'); true")
  expect_true(sv_wait_js(b, "!!document.querySelector('[data-sv-ns=\"a-\"] .sideview-listview h2')"))
  r <- sv_js(b, "(() => { const lv = document.querySelector('[data-sv-ns=\"a-\"] .sideview-listview');
    return { btns: [...lv.querySelectorAll('button')].map(b => b.textContent.trim()),
             h2: [...lv.querySelectorAll('h2')].map(h => h.textContent),
             code: !!lv.querySelector('.sideview-code-block') }; })()")
  btns <- unlist(r$btns)
  expect_false(any(c("Insert Script", "Run & Exit", "Run in R", "Run Console") %in% btns))
  expect_true("Copy" %in% btns)
  expect_true(r$code)
  expect_false("Copilot" %in% unlist(r$h2))
  expect_true("Code" %in% unlist(r$h2))
})

# ---- card changes, keyboard walkthrough and AX facts in the list view (Task 16) ----

test_that("replacing a card re-renders only its section", {
  skip_if_no_browser()
  app <- sv_start_app(app_file = sv_example_app("proxy"))
  ready <- "(() => { const c = document.querySelector('[data-sv-ns=\"a-\"]'); return !!c && c.querySelectorAll('.sideview-card').length >= 2 && !!c._sideviewInstance; })()"
  b <- sv_open_page(app$url, 1400, 900, wait_for = ready)
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  eng <- "document.querySelector('[data-sv-ns=\"a-\"]')._sideviewInstance"
  sv_js(b, paste0(eng, ".setView('list'); true"))
  sec <- function(n) sprintf("document.querySelector('[data-sv-ns=\"a-\"] .sideview-listview [data-sv-table=\"%s\"]')", n)
  expect_true(sv_wait_js(b, paste0("!!", sec("visits"), " && !!", sec("labs"))))
  before <- sv_js(b, paste0(sec("labs"), ".querySelector('h3').textContent"))
  expect_match(before, "^labs, 90 rows by 4 columns")
  sv_js(b, paste0(sec("visits"), ".setAttribute('data-test-mark', 'keep'); true"))
  sv_js(b, "Shiny.setInputValue('refresh', 'drop'); true")
  sv_js(b, "document.querySelector('#replace').click(); true")
  expect_true(sv_wait_js(b, paste0(eng, ".announceLog.indexOf('Table labs replaced.') >= 0")))
  expect_true(sv_wait_js(b, paste0(sec("labs"), ".querySelector('h3').textContent.indexOf('by 3 columns') > 0")))
  expect_identical(sv_js(b, paste0(sec("visits"), ".getAttribute('data-test-mark')")), "keep")
  # add and remove announce, and the Tables section says so when empty
  sv_js(b, "document.querySelector('#add').click(); true")
  expect_true(sv_wait_js(b, paste0(eng, ".announceLog.indexOf('Table extra1 added.') >= 0")))
  expect_true(sv_wait_js(b, paste0("!!", sec("extra1"))))
  sv_js(b, "document.querySelector('#remove').click(); true")
  expect_true(sv_wait_js(b, paste0(eng, ".announceLog.indexOf('Table extra1 removed.') >= 0")))
  expect_true(sv_wait_js(b, paste0("!", sec("extra1"))))
  expect_identical(sv_js(b, paste0(sec("visits"), ".getAttribute('data-test-mark')")), "keep")
  sv_js(b, paste0("['visits', 'labs'].forEach(n => ", eng, ".removeCard(n)); true"))
  expect_true(sv_wait_js(b, "(document.querySelector('[data-sv-ns=\"a-\"] .sideview-listview [data-sv-lv-body=\"tables\"]') || {}).textContent === 'No tables yet.'"))
})

# Tab until focus lands on an element that `pred` (JS on `e`) accepts.
sv_tab_to <- function(b, pred, max = 400L) {
  for (i in seq_len(max)) {
    sv_tab(b)
    if (isTRUE(sv_js(b, sprintf("(e => !!(%s))(document.activeElement)", pred)))) return(invisible(TRUE))
  }
  stop("Tab never reached: ", pred)
}
sv_press <- function(b, key, n = 1L) {
  for (i in seq_len(n)) {
    if (key == "Enter") sv_key(b, "Enter", text = "\r")
    else if (key == "Space") sv_key(b, " ", code = "Space", text = " ")
    else sv_key(b, key)
  }
  invisible(b)
}
sv_type <- function(b, text) {
  for (ch in strsplit(text, "")[[1]]) sv_key(b, ch, text = ch)
  invisible(b)
}

sv_walk_open <- function() {
  root <- sv_pkg_root()
  if (!nzchar(root)) skip("the walkthrough needs the source tree (helper-cdisc.R)")
  helper <- normalizePath(file.path(root, "tests", "testthat", "helper-cdisc.R"), winslash = "/")
  app <- sv_start_app(app_expr = sprintf(
    "{ source('%s'); f <- sv_cdisc_fixtures(); sideview(patients = patients, visits = visits, ae = f$ae, suppae = f$suppae, view = 'list', run = FALSE) }",
    helper))
  b <- sv_open_page(app$url, 1360, 820, wait_for = sv_wait_eng)
  attr(b, "sv_app") <- app
  sv_wait_js(b, "!!document.querySelector('.sideview-listview h2') && document.querySelectorAll('.sideview-listview [data-sv-table]').length === 4")
  b
}

test_that("keyboard-only walkthrough gives the canvas code", {
  skip_if_no_browser()
  b <- sv_walk_open()
  app <- attr(b, "sv_app")
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  expect_identical(sv_js(b, paste0(sv_eng, ".view")), "list")
  J <- ".sideview-listview [data-sv-lv-body=\"join\"]"
  # 1. the join patients.patient_id to visits.pid
  sv_tab_to(b, "e.matches && e.matches('select[data-sv-field=\"left-table\"]')")
  sv_press(b, "ArrowDown")
  sv_tab(b); sv_press(b, "ArrowDown", 2)
  sv_tab(b); sv_press(b, "ArrowDown")
  sv_tab(b); sv_press(b, "ArrowDown", 2)
  got <- sv_js(b, sprintf("[...document.querySelectorAll('%s select[data-sv-field]')].slice(0, 4).map(s => s.value)", J))
  expect_identical(as.character(unlist(got)), c("patients", "visits", "patient_id", "pid"))
  sv_tab_to(b, "e.tagName === 'BUTTON' && e.textContent === 'Check join'")
  sv_press(b, "Space")
  expect_true(sv_wait_js(b, sprintf("(b => !!b && !b.disabled)([...document.querySelectorAll('%s button')].find(x => x.textContent === 'Add join step'))", J), timeout = 30))
  sv_tab_to(b, "e.tagName === 'BUTTON' && e.textContent === 'Add join step'")
  sv_press(b, "Enter")
  expect_true(sv_wait_js(b, paste0(sv_eng, ".pipeline.steps.some(s => s.kind === 'join')")))
  # 2. the filter age > 30 on patients
  F <- ".sideview-listview [data-builder=\"filter\"]"
  sv_tab_to(b, "e.matches && e.matches('select[data-field=\"table\"]') && e.closest('[data-builder=\"filter\"]')")
  expect_identical(sv_js(b, "document.activeElement.value"), "patients")
  sv_tab(b)                                # combine
  sv_tab(b); sv_press(b, "ArrowDown", 2)   # column: age
  sv_tab(b); sv_press(b, "ArrowDown", 2)   # operator: >
  sv_tab(b); sv_type(b, "30")
  vals <- sv_js(b, sprintf("[...document.querySelectorAll('%s [data-field=\"col\"], %s [data-field=\"op\"], %s [data-field=\"val\"]')].map(f => f.value)", F, F, F))
  expect_identical(as.character(unlist(vals)), c("age", "gt", "30"))
  sv_tab_to(b, "e.matches && e.matches('[data-builder-action=\"submit\"]') && e.closest('[data-builder=\"filter\"]')")
  sv_press(b, "Enter")
  expect_true(sv_wait_js(b, paste0(sv_eng, ".pipeline.steps.some(s => s.kind === 'filter')")))
  # 3. merge SUPPAE into AE
  sv_tab_to(b, "e.tagName === 'BUTTON' && e.textContent === 'Merge' && e.closest('[data-sv-supp=\"suppae\"]')")
  sv_press(b, "Enter")
  expect_true(sv_wait_js(b, paste0(sv_eng, ".pipeline.steps.some(s => s.kind === 'supp')"), timeout = 30))
  expect_true(sv_wait_js(b, paste0(sv_eng, ".generatedCode === ", sv_eng, ".pipeline.compose()")))
  code <- sv_js(b, paste0(sv_eng, ".generatedCode"))
  expect_no_error(parse(text = code))
  expect_identical(sv_js(b, paste0(sv_eng, ".pipeline.steps.map(s => s.kind).join(',')")), "join,filter,supp")

  # the same three steps through the engine calls, in a second session
  b2 <- sv_walk_open()
  app2 <- attr(b2, "sv_app")
  withr::defer({ try(b2$close(), silent = TRUE); try(app2$proc$kill(), silent = TRUE) })
  sv_js(b2, paste0(sv_eng, ".addConnections([{fromTable: 'patients', fromCol: 'patient_id', toTable: 'visits', toCol: 'pid', type: 'left_join'}]); true"))
  sv_js(b2, paste0(sv_eng, ".pipeline.add({ kind: 'filter', table: 'patients', conds: ['age > 30'], combine: 'and', specs: [null], condCols: ['age'] }, 'filter'); true"))
  sv_js(b2, paste0(sv_eng, ".requestSuppCheck('ae', 'suppae', null, { mode: 'add', rdomain: 'AE', list: true }); true"))
  expect_true(sv_wait_js(b2, paste0(sv_eng, ".pipeline.steps.some(s => s.kind === 'supp')"), timeout = 30))
  expect_true(sv_wait_js(b2, paste0(sv_eng, ".generatedCode === ", sv_eng, ".pipeline.compose()")))
  expect_identical(sv_js(b2, paste0(sv_eng, ".generatedCode")), code)
})

test_that("with shortcuts off, f, t and d on a list heading change nothing", {
  skip_if_no_browser()
  b <- sv_walk_open()
  app <- attr(b, "sv_app")
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  sv_js(b, paste0(sv_eng, ".setShortcuts(false); true"))
  state <- function() sv_js(b, sprintf("(() => { const c = document.querySelector('.sideview-container');
    return { scale: %s.panzoom.getScale(), collapsed: c.querySelector('.sideview-drawer').classList.contains('collapsed'),
             cls: c.className, theme: document.documentElement.getAttribute('data-theme') || '' }; })()", sv_eng))
  sv_js(b, "document.querySelector('.sideview-listview h2').focus(); true")
  before <- state()
  for (k in c("f", "t", "d")) sv_key(b, k, text = k)
  expect_true(sv_wait_js(b, "new Promise(r => requestAnimationFrame(() => setTimeout(() => r(true), 0)))"))
  expect_identical(state(), before)
})

test_that("AX facts in the list view: row counts and every control named", {
  skip_if_no_browser()
  b <- sv_a11y_pages()$gadget$open("light", 1360, 820)
  app <- attr(b, "sv_app")
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  sv_js(b, paste0(sv_eng, ".setView('list'); true"))
  expect_true(sv_wait_js(b, "document.querySelectorAll('.sideview-listview [data-sv-table]').length === 3"))
  r <- sv_js(b, "[...document.querySelectorAll('.sideview-listview [data-sv-table]')].map(s => {
    const t = s.querySelector('table');
    const card = document.querySelector('.sideview-card[data-card-name=\"' + CSS.escape(s.getAttribute('data-sv-table')) + '\"]');
    return { rc: parseInt(t.getAttribute('aria-rowcount'), 10), total: card._virtualTable.getRowCount(),
             shown: t.querySelectorAll('tbody tr').length }; })")
  for (x in r) {
    expect_equal(x$rc, x$total + 1)
    expect_gt(x$shown, 0)
  }
  bad <- sv_ax_unnamed(sv_ax_tree(b))
  expect_equal(nrow(bad), 0, info = paste(bad$role, collapse = ", "))
})

test_that("the toolbar List view toggle stays inside the container at the narrow width", {
  skip_if_no_browser()
  b <- sv_a11y_pages()$gadget$open("light", 375, 812)
  app <- attr(b, "sv_app")
  withr::defer({ try(b$close(), silent = TRUE); try(app$proc$kill(), silent = TRUE) })
  expect_true(sv_wait_js(b, "document.querySelector('.sideview-container').classList.contains('sv-narrow')"))
  r <- sv_js(b, "(() => { const c = document.querySelector('.sideview-container').getBoundingClientRect();
    const t = document.querySelector('.sideview-toolbar [data-sv-view-toggle]'); const r = t.getBoundingClientRect();
    const tb = document.querySelector('.sideview-toolbar');
    return { left: r.left - c.left, right: c.right - r.right, w: r.width, h: r.height,
             scroll: tb.scrollWidth - tb.clientWidth }; })()")
  expect_gte(r$left, 0)
  expect_gte(r$right, 0)
  expect_gt(r$w, 0)
  expect_lte(r$scroll, 0)
})
