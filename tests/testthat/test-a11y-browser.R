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

test_that("typing never fires shortcuts", {
  skip_if_no_browser()
  b <- sv_open_gadget()
  before <- sv_canvas_state(b)
  sv_js(b, "document.querySelector('.sideview-ai-input').focus()")
  sv_key(b, "f", text = "f")
  sv_key(b, "d", text = "d")
  after <- sv_canvas_state(b)
  expect_equal(after$scale, before$scale)
  expect_identical(after$collapsed, before$collapsed)
  expect_identical(sv_js(b, "document.querySelector('.sideview-ai-input').value"), "fd")
})

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
