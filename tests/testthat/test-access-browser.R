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
