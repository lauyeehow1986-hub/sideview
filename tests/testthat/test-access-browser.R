# Real-browser tests of the Accessible canvas switch (spec section 8).

sv_acc_eng <- "document.querySelector('.sideview-container')._sideviewInstance"
sv_acc_ready <- "!!document.querySelector('.sideview-container')._sideviewInstance && document.querySelectorAll('.sideview-card').length >= 2"

sv_acc_open <- function(mode = "gadget", access = FALSE) {
  b <- sv_a11y_pages()[[mode]]$open("light", 1360, 820, access = access)
  app <- attr(b, "sv_app")
  withr::defer_parent({
    try(b$close(), silent = TRUE)
    if (!is.null(app)) try(app$proc$kill(), silent = TRUE)
  })
  b
}

sv_acc_class <- function(b) {
  sv_js(b, "document.querySelector('.sideview-container').classList.contains('sv-access')")
}

test_that("access is off by default and the default canvas is unchanged", {
  skip_if_no_browser()
  b <- sv_acc_open()
  expect_false(sv_acc_class(b))
  expect_false(sv_js(b, paste0(sv_acc_eng, ".accessOn()")))
  scale <- sv_js(b, sprintf("(() => { const e = %s; e.panzoom.zoomToPoint(0.2, {clientX: 600, clientY: 400});
    return e.panzoom.getScale(); })()", sv_acc_eng))
  expect_equal(scale, 0.2, tolerance = 1e-6)
  expect_equal(sv_js(b, "document.querySelectorAll('.sideview-card[tabindex]').length"), 0)
})

test_that("R access = TRUE turns it on; a stored off wins", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  expect_true(sv_acc_class(b))
  expect_true(sv_js(b, paste0(sv_acc_eng, ".accessOn()")))
  sv_js(b, "localStorage.setItem('sideview.access', 'off')")
  sv_navigate(b, sv_js(b, "location.href"))
  expect_true(sv_wait_js(b, sv_acc_ready, timeout = 60))
  expect_false(sv_acc_class(b))
  expect_false(sv_js(b, paste0(sv_acc_eng, ".accessOn()")))
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("a stored on wins over R FALSE", {
  skip_if_no_browser()
  b <- sv_acc_open("widget", access = FALSE)
  expect_false(sv_acc_class(b))
  sv_js(b, "localStorage.setItem('sideview.access', 'on')")
  sv_navigate(b, sv_js(b, "location.href"))
  expect_true(sv_wait_js(b, sv_acc_ready, timeout = 60))
  expect_true(sv_acc_class(b))
  expect_true(sv_js(b, paste0(sv_acc_eng, ".accessOn()")))
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("the ? switch toggles, announces and keeps focus", {
  skip_if_no_browser()
  b <- sv_acc_open()
  sv_js(b, paste0(sv_acc_eng, ".toggleShortcuts(true)"))
  sel <- "document.querySelector('[data-sv-access-switch]')"
  expect_identical(sv_js(b, sprintf("%s.getAttribute('role')", sel)), "switch")
  expect_match(sv_js(b, sprintf("%s.textContent", sel)), "Accessible canvas")
  click <- function() {
    p <- sv_js(b, sprintf("(() => { const r = %s.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()", sel))
    for (type in c("mouseMoved", "mousePressed", "mouseReleased")) {
      b$Input$dispatchMouseEvent(type = type, x = p$x, y = p$y, button = "left",
                                 clickCount = if (type == "mouseMoved") 0 else 1)
    }
  }
  last_ann <- function() sv_js(b, sprintf("(() => { const l = %s.announceLog; return l[l.length - 1]; })()", sv_acc_eng))
  click()
  expect_identical(sv_js(b, sprintf("%s.getAttribute('aria-checked')", sel)), "true")
  expect_true(sv_acc_class(b))
  expect_identical(last_ann(), "Accessible canvas on.")
  expect_true(sv_js(b, sprintf("document.activeElement === %s", sel)))
  click()
  expect_identical(sv_js(b, sprintf("%s.getAttribute('aria-checked')", sel)), "false")
  expect_false(sv_acc_class(b))
  expect_identical(last_ann(), "Accessible canvas off.")
  expect_true(sv_js(b, sprintf("document.activeElement === %s", sel)))
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("the switch works when localStorage throws", {
  skip_if_no_browser()
  b <- sv_acc_open()
  b$Page$enable()
  b$Page$addScriptToEvaluateOnNewDocument(
    "Object.defineProperty(window, 'localStorage', {get: function () { throw new Error('blocked'); }})")
  sv_navigate(b, sv_js(b, "location.href"))
  expect_true(sv_wait_js(b, sv_acc_ready, timeout = 60))
  expect_true(sv_js(b, "(() => { try { window.localStorage; return false; } catch (e) { return true; } })()"))
  expect_false(sv_js(b, paste0(sv_acc_eng, ".accessOn()")))
  expect_true(sv_js(b, paste0(sv_acc_eng, ".setAccess(true)")))
  expect_true(sv_acc_class(b))
  expect_true(sv_js(b, paste0(sv_acc_eng, ".accessOn()")))
})

test_that("the zoom floor holds on every path", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  scale <- function() sv_js(b, paste0(sv_acc_eng, ".panzoom.getScale()"))
  expect_gte(scale(), 1 - 1e-9)
  sv_js(b, sprintf("%s.container.focus(); true", sv_acc_eng))
  # wheel zoom-out, real input
  for (i in 1:10) {
    b$Input$dispatchMouseEvent(type = "mouseWheel", x = 680, y = 400, deltaX = 0, deltaY = 120)
  }
  Sys.sleep(0.3)
  expect_gte(scale(), 1 - 1e-9)
  # key -
  for (i in 1:10) sv_key(b, "-", code = "Minus", text = "-")
  expect_gte(scale(), 1 - 1e-9)
  # key 0
  sv_key(b, "0", code = "Digit0", text = "0")
  expect_gte(scale(), 1 - 1e-9)
  # toolbar zoom-out
  sv_js(b, "(() => { const t = document.querySelector('[data-action=\"zoom-out\"]');
    for (let i = 0; i < 10; i++) t.click(); return true; })()")
  expect_gte(scale(), 1 - 1e-9)
  # fitAll
  sv_js(b, paste0(sv_acc_eng, ".fitAll(); true"))
  expect_gte(scale(), 1 - 1e-9)
  # zoomToCard on the largest card
  sv_js(b, sprintf("(() => { const e = %s; let best = null, a = 0;
    document.querySelectorAll('.sideview-card').forEach(c => { const v = c.offsetWidth * c.offsetHeight; if (v > a) { a = v; best = c; } });
    e.zoomToCard(best); return true; })()", sv_acc_eng))
  expect_gte(scale(), 1 - 1e-9)
  # state restore with a zoom of 0.5
  sv_js(b, sprintf("(() => { const e = %s; const s = e.getState(); s.canvas = Object.assign({}, s.canvas, { zoom: 0.5 });
    e.applyState(s); return true; })()", sv_acc_eng))
  expect_gte(scale(), 1 - 1e-9)
})

test_that("switching on below 1.0 zooms to 1 around the focused card; switching off keeps the zoom", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = FALSE)
  sv_js(b, sprintf("%s.panzoom.zoomToPoint(0.5, {clientX: 680, clientY: 400}); true", sv_acc_eng))
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".panzoom.getScale()")), 0.5, tolerance = 1e-6)
  centre <- function() sv_js(b, "(() => { const r = document.querySelector('.sideview-card[data-card-name=\"visits\"]').getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()")
  sv_js(b, "(() => { const c = document.querySelector('.sideview-card[data-card-name=\"visits\"]');
    c.setAttribute('tabindex', '-1'); c.focus(); return true; })()")
  before <- centre()
  sv_js(b, paste0(sv_acc_eng, ".setAccess(true)"))
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".panzoom.getScale()")), 1, tolerance = 1e-9)
  after <- centre()
  expect_lt(abs(after$x - before$x), 2)
  expect_lt(abs(after$y - before$y), 2)
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".minScaleNow()")), 1)
  sv_js(b, paste0(sv_acc_eng, ".setAccess(false)"))
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".panzoom.getScale()")), 1, tolerance = 1e-9)
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".minScaleNow()")), 0.15)
  sv_js(b, sprintf("%s.panzoom.zoomToPoint(0.2, {clientX: 680, clientY: 400}); true", sv_acc_eng))
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".panzoom.getScale()")), 0.2, tolerance = 1e-6)
})
