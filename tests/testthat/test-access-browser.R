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

sv_six_joins_js <- function(eng) {
  sprintf("(() => { const e = %s;
    const j = [['patients','patient_id','visits','pid'], ['patients','patient_id','labs','patient_id'],
      ['patients','age','visits','sbp'], ['patients','age','labs','value'],
      ['visits','visit_id','labs','value'], ['visits','sbp','labs','value']];
    j.forEach(x => e.addConnections([{fromTable: x[0], fromCol: x[1], toTable: x[2], toCol: x[3], type: 'left_join'}]));
    return true; })()", eng)
}

sv_conn_style_js <- "(() => Array.from(document.querySelectorAll('.sideview-connector-svg .sideview-connector-path:not(.sideview-spline-suggested)'))
  .map(p => { const s = getComputedStyle(p);
    return { dash: s.strokeDasharray, width: s.strokeWidth, marker: s.markerEnd, pat: p.getAttribute('data-sv-pat'),
             stroke: s.stroke }; }))()"

test_that("access: six joins get six distinct dash patterns and an end marker", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_js(b, sv_six_joins_js(sv_acc_eng))
  st <- sv_js(b, sv_conn_style_js)
  dash <- vapply(st, function(x) x$dash, "")
  expect_length(st, 6)
  expect_equal(length(unique(dash)), 6)
  expect_false(any(dash %in% c("6px, 6px", "4px, 4px")))
  expect_equal(vapply(st, function(x) x$pat, ""), as.character(0:5))
  expect_true(all(vapply(st, function(x) x$width, "") == "3px"))
  expect_true(all(grepl("url.*#sv-mk-[0-9]+-solid", vapply(st, function(x) x$marker, ""))))
  # hover: wider, same pattern, still a marker
  sv_js(b, "document.querySelectorAll('.sideview-connector-svg .sideview-connector-path')[1].classList.add('is-hover', 'active'); true")
  Sys.sleep(0.5)  # the 150 ms stroke transition
  h <- sv_js(b, "(() => { const s = getComputedStyle(document.querySelectorAll('.sideview-connector-svg .sideview-connector-path')[1]);
    return { dash: s.strokeDasharray, width: s.strokeWidth, marker: s.markerEnd }; })()")
  expect_equal(h$width, "5px")
  expect_equal(h$dash, dash[2])
  expect_match(h$marker, "sv-mk-")
  # the marker defs live in the engine's svg and go away on destroy
  expect_equal(sv_js(b, "document.querySelectorAll('marker[id^=\"sv-mk-\"]').length"), 2)
  sv_js(b, paste0(sv_acc_eng, ".destroy(); true"))
  expect_equal(sv_js(b, "document.querySelectorAll('marker[id^=\"sv-mk-\"]').length"), 0)

  b0 <- sv_acc_open("gadget", access = FALSE)
  sv_js(b0, sv_six_joins_js(sv_acc_eng))
  st0 <- sv_js(b0, sv_conn_style_js)
  expect_true(all(vapply(st0, function(x) x$dash, "") == "none"))
  # the marker is referenced but its shapes are hidden: nothing is drawn with access off
  expect_true(all(sv_js(b0, "Array.from(document.querySelectorAll('.sideview-marker-shape')).map(s => getComputedStyle(s).display === 'none')") == TRUE))
  expect_equal(vapply(st0, function(x) x$pat, ""), as.character(0:5))
})

sv_emulate <- function(b, name, value) {
  b$Emulation$setEmulatedMedia(features = list(list(name = name, value = value)))
}

sv_a11y_visuals_js <- "(() => {
  const c = document.querySelector('.sideview-container');
  const canvas = getComputedStyle(document.querySelector('.sideview-canvas') || c).backgroundColor;
  const path = document.querySelector('.sideview-connector-svg .sideview-connector-path');
  const port = document.querySelector('.sideview-col-port');
  const btn = document.activeElement;
  const ps = getComputedStyle(path), pt = getComputedStyle(port), bs = getComputedStyle(btn);
  return { canvas: canvas, stroke: ps.stroke, port: pt.borderTopColor, portBg: pt.backgroundColor,
           outline: bs.outlineColor, outlineStyle: bs.outlineStyle, outlineW: bs.outlineWidth }; })()"

test_that("forced colours and more contrast keep splines, ports and the focus ring visible", {
  skip_if_no_browser()
  for (access in c(TRUE, FALSE)) {
    b <- sv_acc_open("gadget", access = access)
    sv_js(b, sv_six_joins_js(sv_acc_eng))
    sv_js(b, sprintf("%s.renderSuggestedSplines([{from_table: 'patients', from_col: 'sex', to_table: 'labs', to_col: 'test', confidence: 0.9}]); true", sv_acc_eng))
    sv_key(b, "Tab")  # keyboard focus, so :focus-visible applies and persists across the reads
    base <- sv_js(b, sv_a11y_visuals_js)
    base_dash <- vapply(sv_js(b, sv_conn_style_js), function(x) x$dash, "")
    for (feat in list(c("forced-colors", "active"), c("prefers-contrast", "more"))) {
      sv_emulate(b, feat[1], feat[2])
      Sys.sleep(0.4)
      v <- sv_js(b, sv_a11y_visuals_js)
      info <- paste(feat[1], "access", access)
      expect_false(identical(v$stroke, v$canvas), info = info)
      expect_false(identical(v$port, v$canvas), info = info)
      expect_false(identical(v$outline, v$canvas), info = info)
      expect_false(v$outlineStyle == "none", info = info)
      if (feat[1] == "forced-colors") {
        d <- vapply(sv_js(b, sv_conn_style_js), function(x) x$dash, "")
        expect_equal(length(unique(d)), 6, info = info)
        sg <- sv_js(b, "(() => { const p = document.querySelector('.sideview-spline-suggested'); const s = getComputedStyle(p);
          const h = document.querySelector('.sideview-marker-hollow');
          return { dash: s.strokeDasharray, marker: s.markerEnd, hollow: getComputedStyle(h).display }; })()")
        expect_false(sg$dash == "none", info = info)
        expect_match(sg$marker, "-hollow", info = info)
        expect_equal(sg$hollow, "inline", info = info)
      }
    }
    sv_emulate(b, "forced-colors", "none")
    sv_emulate(b, "prefers-contrast", "no-preference")
    Sys.sleep(0.4)
    after <- sv_js(b, sv_a11y_visuals_js)
    expect_equal(after[c("stroke", "port", "outline")], base[c("stroke", "port", "outline")])
    expect_equal(vapply(sv_js(b, sv_conn_style_js), function(x) x$dash, ""), base_dash)
  }
})

sv_live_pats_js <- "Array.from(document.querySelectorAll('.sideview-connector-svg .sideview-connector-path:not(.sideview-spline-suggested)')).map(p => p.getAttribute('data-sv-pat'))"

test_that("no two live joins share a pattern while six or fewer are live, even after remove and re-add", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_js(b, sv_six_joins_js(sv_acc_eng))
  expect_equal(unlist(sv_js(b, sv_live_pats_js)), as.character(0:5))
  ids <- unlist(sv_js(b, sprintf("%s.connections.map(c => c.id)", sv_acc_eng)))
  for (id in ids[1:5]) sv_js(b, sprintf("%s.removeConnection('%s'); true", sv_acc_eng, id))
  expect_equal(unlist(sv_js(b, sv_live_pats_js)), "5")
  sv_js(b, sprintf("%s.addConnections([{fromTable: 'patients', fromCol: 'patient_id', toTable: 'visits', toCol: 'pid', type: 'left_join'}]); true", sv_acc_eng))
  p <- unlist(sv_js(b, sv_live_pats_js))
  expect_length(p, 2)
  expect_equal(length(unique(p)), 2)
  # a key set added in one call shares one pattern
  sv_js(b, sprintf("%s.addConnections([{fromTable: 'patients', fromCol: 'age', toTable: 'labs', toCol: 'value', type: 'left_join'},
    {fromTable: 'patients', fromCol: 'site', toTable: 'labs', toCol: 'test', type: 'left_join'}]); true", sv_acc_eng))
  p <- unlist(sv_js(b, sv_live_pats_js))
  expect_length(p, 4)
  expect_equal(p[3], p[4])
  expect_equal(length(unique(p)), 3)
})

test_that("saved state restores the same dash patterns in the same order", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_js(b, sprintf("%s.addConnections([{fromTable: 'patients', fromCol: 'patient_id', toTable: 'visits', toCol: 'pid', type: 'left_join'}]); true", sv_acc_eng))
  sv_js(b, sprintf("%s.addConnections([{fromTable: 'patients', fromCol: 'age', toTable: 'labs', toCol: 'value', type: 'left_join'},
    {fromTable: 'patients', fromCol: 'site', toTable: 'labs', toCol: 'test', type: 'left_join'}]); true", sv_acc_eng))
  sv_js(b, sprintf("%s.addConnections([{fromTable: 'visits', fromCol: 'sbp', toTable: 'labs', toCol: 'value', type: 'left_join'}]); true", sv_acc_eng))
  before <- unlist(sv_js(b, sv_live_pats_js))
  expect_equal(before, c("0", "1", "1", "2"))
  state <- sv_js(b, sprintf("JSON.stringify(%s.getState())", sv_acc_eng))
  sv_js(b, sprintf("%s.clearOperations(true); true", sv_acc_eng))
  expect_length(unlist(sv_js(b, sv_live_pats_js)), 0)
  sv_js(b, sprintf("%s.openState(JSON.parse(%s)); true", sv_acc_eng, jsonlite::toJSON(state, auto_unbox = TRUE)))
  expect_equal(unlist(sv_js(b, sv_live_pats_js)), before)
})
