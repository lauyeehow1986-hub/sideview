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
  sv_js(b, "localStorage.removeItem('sideview.access')")
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

# ---- keyboard on cards (spec section 5) ----

# Put the cards at fixed canvas positions (name -> c(x, y)) at zoom 1, no pan.
sv_place_cards <- function(b, pos) {
  sv_js(b, sprintf("(() => { const e = %s; const pos = %s;
    e.panzoom.zoomToPoint(1, {clientX: 0, clientY: 0}); e.panzoom.pan(0, 0);
    e.cards.forEach(m => { const p = pos[m.name]; if (!p) return;
      m.element.style.left = p[0] + 'px'; m.element.style.top = p[1] + 'px'; m.x = p[0]; m.y = p[1];
      delete m.element.dataset.autoPlace; });
    e.updateConnectors(); return true; })()", sv_acc_eng, jsonlite::toJSON(pos, auto_unbox = FALSE)))
}

sv_card_pos <- function(b, name) {
  sv_js(b, sprintf("(() => { const c = %s; return { left: parseFloat(c.style.left), top: parseFloat(c.style.top) }; })()",
                   sv_card_js(name)))
}

sv_focus_card <- function(b, name) {
  sv_js(b, sprintf("(() => { const c = %s; c.focus({preventScroll: true}); return document.activeElement === c; })()",
                   sv_card_js(name)))
}

# '' outside the cards, the card name on a card, '~name' inside a card.
sv_focus_where_js <- "(() => { const a = document.activeElement; if (!a || !a.closest) return '';
  if (a.classList.contains('sideview-card')) return a.getAttribute('data-card-name');
  const c = a.closest('.sideview-card'); return c ? '~' + c.getAttribute('data-card-name') : ''; })()"

sv_focus_sig_js <- "(() => { const a = document.activeElement || {}; const c = a.closest ? a.closest('.sideview-card') : null;
  return [(a.tagName || '').toLowerCase(), (a.getAttribute && (a.getAttribute('aria-label') || a.getAttribute('data-action'))) || '',
          typeof a.className === 'string' ? a.className : '', c ? c.getAttribute('data-card-name') : '',
          a.classList && a.classList.contains('sideview-card') ? 'CARD' : ''].join('|'); })()"

sv_last_ann <- function(b) sv_js(b, sprintf("(() => { const l = %s.announceLog; return l[l.length - 1]; })()", sv_acc_eng))

ALT <- 1L
SHIFT <- 8L

test_that("cards are Tab stops in reading order only with the switch on", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  # DOM order is patients, visits, labs; reading order differs
  pos <- list(labs = c(40, 120), patients = c(760, 120), visits = c(40, 900))
  sv_place_cards(b, pos)
  sv_js(b, sprintf("%s.container.focus(); true", sv_acc_eng))
  seen <- character(); entered <- FALSE
  for (i in 1:150) {
    sv_tab(b)
    w <- sv_js(b, sv_focus_where_js)
    if (nzchar(w)) entered <- TRUE
    if (entered && !nzchar(w)) break
    if (nzchar(w) && !startsWith(w, "~")) seen <- c(seen, w)
  }
  expect_true(entered)
  expect_equal(seen, c("labs", "patients", "visits"))
  expect_equal(sv_js(b, "document.querySelectorAll('.sideview-card[tabindex=\"0\"][role=\"group\"]').length"), 3)
  expect_equal(sv_js(b, sprintf("%s.getAttribute('aria-label')", sv_card_js("labs"))), "labs")
  sv_js(b, "localStorage.removeItem('sideview.access')")

  b0 <- sv_acc_open("gadget", access = FALSE)
  read_order <- function() {
    sv_js(b0, sprintf("%s.container.focus(); true", sv_acc_eng))
    vapply(1:60, function(i) { sv_tab(b0); sv_js(b0, sv_focus_sig_js) }, "")
  }
  base <- read_order()
  expect_false(any(grepl("\\|CARD$", base)))
  sv_js(b0, paste0(sv_acc_eng, ".setAccess(true)"))
  sv_js(b0, paste0(sv_acc_eng, ".setAccess(false)"))
  sv_js(b0, "localStorage.removeItem('sideview.access')")
  again <- read_order()
  expect_equal(again, base)
})

test_that("inside a card Tab reaches its actions, then leaves to the next card", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, list(patients = c(40, 120), visits = c(760, 120), labs = c(40, 900)))
  expect_true(sv_focus_card(b, "patients"))
  stops <- list()
  for (i in 1:40) {
    sv_tab(b)
    w <- sv_js(b, sv_focus_where_js)
    if (w != "~patients") break
    stops[[length(stops) + 1]] <- sv_focus_info(b)
    stops[[length(stops)]]$action <- sv_js(b, "document.activeElement.getAttribute('data-action') || ''")
    stops[[length(stops)]]$th <- sv_js(b, "(() => { const t = document.activeElement.closest('th'); return t ? t.getAttribute('data-col-name') : ''; })()")
    stops[[length(stops)]]$is_th <- sv_js(b, "document.activeElement.tagName === 'TH'")
  }
  actions <- vapply(stops, function(s) s$action, "")
  expect_true(all(c("maximize-card", "sync-scroll", "minimize-card") %in% actions))
  # one roving column header (plus its own tool buttons), not every column
  ths <- vapply(stops, function(s) s$th, "")
  expect_equal(sum(vapply(stops, function(s) isTRUE(s$is_th), TRUE)), 1)
  expect_length(unique(ths[nzchar(ths)]), 1)
  expect_identical(w, "visits")
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("Arrows move 20px, Shift+Arrows 100px; one card_moved and one announcement per pause", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, list(patients = c(40, 120), visits = c(760, 120), labs = c(40, 900)))
  sv_js(b, sprintf("(() => { const e = %s; e._sent = []; const orig = e.send;
    e.send = function (n, v) { e._sent.push([n, v]); return orig.apply(e, arguments); }; return true; })()", sv_acc_eng))
  expect_true(sv_focus_card(b, "patients"))
  for (i in 1:3) sv_key(b, "ArrowRight")
  sv_key(b, "ArrowDown", modifiers = SHIFT)
  p <- sv_card_pos(b, "patients")
  expect_equal(p$left, 100)
  expect_equal(p$top, 220)
  expect_true(sv_js(b, sv_focus_where_js) == "patients")
  Sys.sleep(1.2)
  expect_identical(sv_last_ann(b), "patients moved.")
  expect_equal(sv_js(b, sprintf("%s.announceLog.filter(t => t === 'patients moved.').length", sv_acc_eng)), 1)
  moved <- sv_js(b, sprintf("%s._sent.filter(x => x[0] === 'sideview_card_moved').map(x => x[1])", sv_acc_eng))
  expect_length(moved, 1)
  expect_equal(moved[[1]]$x, 100)
  expect_equal(moved[[1]]$y, 220)
  m <- sv_js(b, sprintf("(() => { const m = [...%s.cards.values()].find(c => c.name === 'patients'); return {x: m.x, y: m.y}; })()", sv_acc_eng))
  expect_equal(c(m$x, m$y), c(100, 220))
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("Alt+Arrows focus the nearest card and the browser does not go Back", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, list(patients = c(40, 120), visits = c(760, 120), labs = c(40, 900)))
  sv_js(b, "history.pushState({}, '', '#x'); true")
  expect_true(sv_focus_card(b, "patients"))
  sv_key(b, "ArrowRight", modifiers = ALT)
  expect_identical(sv_js(b, sv_focus_where_js), "visits")
  expect_match(sv_last_ann(b), "^visits, [0-9,]+ rows, [0-9]+ columns\\.$")
  expect_identical(sv_last_ann(b), sv_js(b, sprintf("%s.access.cardSentence(%s)", sv_acc_eng, sv_card_js("visits"))))
  sv_key(b, "ArrowLeft", modifiers = ALT)
  expect_identical(sv_js(b, sv_focus_where_js), "patients")
  sv_key(b, "ArrowDown", modifiers = ALT)
  expect_identical(sv_js(b, sv_focus_where_js), "labs")
  # nothing further down: focus stays
  sv_key(b, "ArrowDown", modifiers = ALT)
  expect_identical(sv_js(b, sv_focus_where_js), "labs")
  Sys.sleep(0.3)
  expect_identical(sv_js(b, "location.hash"), "#x")
  # a jump moves no card
  expect_equal(unlist(sv_card_pos(b, "patients")), c(left = 40, top = 120))
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("PageDown/End scroll the card body", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, list(patients = c(40, 120), visits = c(760, 120), labs = c(40, 900)))
  body <- sprintf("%s.querySelector('.sideview-card-body')", sv_card_js("patients"))
  expect_true(sv_focus_card(b, "patients"))
  expect_equal(sv_js(b, sprintf("%s.scrollTop", body)), 0)
  sv_key(b, "PageDown")
  Sys.sleep(0.2)
  t1 <- sv_js(b, sprintf("%s.scrollTop", body))
  expect_gt(t1, 0)
  sv_key(b, "PageDown")
  Sys.sleep(0.2)
  expect_gt(sv_js(b, sprintf("%s.scrollTop", body)), t1)
  sv_key(b, "End")
  Sys.sleep(0.2)
  r <- sv_js(b, sprintf("(() => { const x = %s; return { t: x.scrollTop, max: x.scrollHeight - x.clientHeight }; })()", body))
  expect_gt(r$max, 0)
  expect_lte(abs(r$t - r$max), 1)
  sv_key(b, "PageUp")
  Sys.sleep(0.2)
  expect_lt(sv_js(b, sprintf("%s.scrollTop", body)), r$t)
  sv_key(b, "Home")
  Sys.sleep(0.2)
  expect_equal(sv_js(b, sprintf("%s.scrollTop", body)), 0)
  expect_identical(sv_js(b, sv_focus_where_js), "patients")
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("focus follows: a focused card is fully visible, outside drawer, AI bar and minimap", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, list(patients = c(40, 120), visits = c(760, 120), labs = c(2200, 1400)))
  sv_js(b, "(() => { const d = document.querySelector('.sideview-drawer'); if (d) d.classList.remove('collapsed'); return true; })()")
  sv_js(b, sprintf("(() => { const e = %s; if (!document.querySelector('.sideview-minimap') || getComputedStyle(document.querySelector('.sideview-minimap')).display === 'none') e.toggleMinimap(); return true; })()", sv_acc_eng))
  Sys.sleep(0.5)  # the drawer's slide-in
  off <- sv_js(b, sprintf("(() => { const r = %s.getBoundingClientRect(); const c = document.querySelector('.sideview-container').getBoundingClientRect();
    return r.left > c.right || r.top > c.bottom; })()", sv_card_js("labs")))
  expect_true(off)
  expect_true(sv_focus_card(b, "visits"))
  # labs' centre is 1440 px right and 1280 px down of visits': inside the Right cone
  sv_key(b, "ArrowRight", modifiers = ALT)
  expect_identical(sv_js(b, sv_focus_where_js), "labs")
  Sys.sleep(0.2)
  chk <- sv_js(b, sprintf("(() => { const e = %s; const c = e.container.getBoundingClientRect();
    const r = %s.getBoundingClientRect(); const m = 24;
    const box = { l: r.left - m, t: r.top - m, r: r.right + m, b: r.bottom + m };
    const top = c.top + e.chromeTop();
    const ai = document.querySelector('.sideview-ai-bar');
    const bottom = ai && ai.offsetHeight ? ai.getBoundingClientRect().top : c.bottom;
    const hit = (sel) => { const el = document.querySelector(sel); if (!el || !el.offsetWidth) return false;
      const o = el.getBoundingClientRect(); return !(box.r <= o.left || box.l >= o.right || box.b <= o.top || box.t >= o.bottom); };
    return { inside: box.l >= c.left && box.r <= c.right && box.t >= top && box.b <= bottom,
             drawer: hit('.sideview-drawer:not(.collapsed)'), minimap: hit('.sideview-minimap'),
             scale: e.panzoom.getScale(), mm: !!document.querySelector('.sideview-minimap') }; })()",
    sv_acc_eng, sv_card_js("labs")))
  expect_true(chk$inside)
  expect_false(chk$drawer)
  expect_false(chk$minimap)
  expect_gte(chk$scale, 1 - 1e-9)
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("keys are silent while typing and outside an embedded widget", {
  skip_if_no_browser()
  b <- sv_acc_open("widget", access = TRUE)
  sv_place_cards(b, list(patients = c(40, 120), visits = c(760, 120), labs = c(40, 900)))
  sv_js(b, "(() => { const i = document.createElement('input'); i.id = 'outside'; document.body.insertBefore(i, document.body.firstChild);
    i.focus(); return document.activeElement === i; })()")
  before <- sv_card_pos(b, "patients")
  for (k in c("ArrowRight", "ArrowDown")) {
    sv_key(b, k)
    sv_key(b, k, modifiers = ALT)
    sv_key(b, k, modifiers = SHIFT)
  }
  expect_equal(sv_card_pos(b, "patients"), before)
  expect_true(sv_js(b, "document.activeElement.id === 'outside'"))
  # a text field inside the container
  sv_js(b, "document.querySelector('.sideview-ai-input').focus(); true")
  sv_key(b, "ArrowRight")
  sv_key(b, "ArrowRight", modifiers = ALT)
  expect_equal(sv_card_pos(b, "patients"), before)
  expect_true(sv_js(b, "document.activeElement.classList.contains('sideview-ai-input')"))
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("with shortcuts off, card keys still work", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, list(patients = c(40, 120), visits = c(760, 120), labs = c(40, 900)))
  sv_js(b, paste0(sv_acc_eng, ".setShortcuts(false)"))
  expect_true(sv_focus_card(b, "patients"))
  sv_key(b, "ArrowRight")
  expect_equal(sv_card_pos(b, "patients")$left, 60)
  sv_key(b, "ArrowRight", modifiers = ALT)
  expect_identical(sv_js(b, sv_focus_where_js), "visits")
  sv_js(b, "localStorage.removeItem('sideview.access'); localStorage.removeItem('sideview.shortcuts')")
})

test_that("switching off mid-connect or on a focused card", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = FALSE)
  marked_js <- "document.querySelectorAll('.sideview-card[tabindex], .sideview-card[role], .sideview-card[aria-label], .sideview-card [tabindex]').length"
  base <- sv_js(b, marked_js)
  sv_js(b, paste0(sv_acc_eng, ".setAccess(true)"))
  expect_gt(sv_js(b, marked_js), base)
  expect_true(sv_focus_card(b, "visits"))
  sv_js(b, paste0(sv_acc_eng, ".setAccess(false)"))
  expect_equal(sv_js(b, "document.querySelectorAll('.sideview-card[tabindex]').length"), 0)
  expect_equal(sv_js(b, marked_js), base)
  expect_true(sv_js(b, "document.activeElement === document.querySelector('.sideview-container')"))
  # off: arrows on the container do nothing to the cards
  before <- sv_card_pos(b, "visits")
  sv_key(b, "ArrowRight")
  expect_equal(sv_card_pos(b, "visits"), before)
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("a maximized card does not move; a minimized one does and keeps its splines on ports", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, list(patients = c(40, 120), visits = c(760, 120), labs = c(40, 900)))
  card <- sv_card_js("patients")
  sv_js(b, sprintf("(() => { const c = %s; %s.toggleMaximizeCard(c, c.querySelector('[data-action=\"maximize-card\"]')); return true; })()",
                   card, sv_acc_eng))
  expect_true(sv_focus_card(b, "patients"))
  sv_key(b, "ArrowRight")
  sv_key(b, "ArrowDown", modifiers = SHIFT)
  expect_equal(sv_card_pos(b, "patients"), list(left = 40, top = 120))
  sv_js(b, sprintf("(() => { const c = %s; %s.toggleMaximizeCard(c, c.querySelector('[data-action=\"maximize-card\"]')); return true; })()",
                   card, sv_acc_eng))

  sv_js(b, sprintf("(() => { const e = %s; const p = %s, v = %s;
    const port = (c, col) => c.querySelector('th[data-col-name=\"' + col + '\"] .sideview-col-port');
    e.addConnections([{fromCard: p.dataset.cardId, fromTable: 'patients', fromCol: 'patient_id', fromElement: port(p, 'patient_id'),
      toCard: v.dataset.cardId, toTable: 'visits', toCol: 'pid', toElement: port(v, 'pid'), type: 'left_join'}]); return true; })()",
    sv_acc_eng, card, sv_card_js("visits")))
  sv_js(b, sprintf("(() => { const c = %s; %s.toggleMinimizeCard(c, c.querySelector('[data-action=\"minimize-card\"]')); return true; })()",
                   card, sv_acc_eng))
  expect_true(sv_focus_card(b, "patients"))
  sv_key(b, "ArrowRight")
  sv_key(b, "ArrowDown", modifiers = SHIFT)
  expect_equal(sv_card_pos(b, "patients"), list(left = 60, top = 220))
  Sys.sleep(0.3)
  d <- sv_js(b, sprintf("(() => { const e = %s; const conn = e.connections[0];
    const h = %s.querySelector('.sideview-card-header').getBoundingClientRect();
    const v = e.viewport.getBoundingClientRect(); const s = e.panzoom.getScale();
    const n = conn.path.getAttribute('d').match(/-?[0-9.]+/g).map(Number);
    return { x: n[0], y: n[1], ex: (h.left + h.width / 2 - v.left) / s, ey: (h.top + h.height / 2 - v.top) / s }; })()",
    sv_acc_eng, card))
  expect_lt(abs(d$x - d$ex), 1.5)
  expect_lt(abs(d$y - d$ey), 1.5)
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

# ---- keyboard on column headers and joins (spec section 5, Task 7) ----

sv_th_js <- function(card, col) {
  sprintf("[...%s.querySelectorAll('thead th[data-col-name]')].find(t => t.getAttribute('data-col-name') === %s)",
          sv_card_js(card), jsonlite::toJSON(col, auto_unbox = TRUE))
}

# 'card.col' when a column header has focus, else ''.
sv_focus_th_js <- "(() => { const a = document.activeElement; if (!a || a.tagName !== 'TH') return '';
  return a.closest('.sideview-card').getAttribute('data-card-name') + '.' + a.getAttribute('data-col-name'); })()"

sv_th_tabindex <- function(b, card) {
  unlist(sv_js(b, sprintf("[...%s.querySelectorAll('thead th[data-col-name]')].map(t => t.getAttribute('tabindex'))",
                          sv_card_js(card))))
}

sv_focus_th <- function(b, card, col) {
  sv_js(b, sprintf("(() => { const t = %s; t.focus({preventScroll: true}); return document.activeElement === t; })()",
                   sv_th_js(card, col)))
}

sv_join_js <- function(pairs) {
  sprintf("(() => { const e = %s; %s.forEach(x => e.addConnections([{fromTable: x[0], fromCol: x[1], toTable: x[2], toCol: x[3], type: 'left_join'}]));
    return e.connections.length; })()", sv_acc_eng, jsonlite::toJSON(pairs))
}

sv_ann_log <- function(b) unlist(sv_js(b, paste0(sv_acc_eng, ".announceLog.slice()")))

sv_spy_send <- function(b) {
  sv_js(b, sprintf("(() => { const e = %s; e._sent = []; const orig = e.send;
    e.send = function (n, v) { e._sent.push([n, v]); return orig.apply(e, arguments); }; return true; })()", sv_acc_eng))
}

sv_key_c <- function(b) sv_key(b, "c", code = "KeyC", text = "c")
sv_key_j <- function(b) sv_key(b, "j", code = "KeyJ", text = "j")
CTRL <- 2L

sv_source_n <- function(b) sv_js(b, "document.querySelectorAll('.sv-kb-connect-source').length")

sv_std_cards <- list(patients = c(40, 120), visits = c(760, 120), labs = c(40, 900))

test_that("Enter goes into the headers, Left/Right move, Escape goes back", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, sv_std_cards)
  # with focus elsewhere no header is a Tab stop
  expect_true(all(sv_th_tabindex(b, "patients") == "-1"))
  expect_true(sv_focus_card(b, "patients"))
  expect_equal(sv_th_tabindex(b, "patients"), c("0", "-1", "-1", "-1"))
  sv_key(b, "Enter")
  expect_identical(sv_js(b, sv_focus_th_js), "patients.patient_id")
  expect_equal(sv_th_tabindex(b, "patients"), c("0", "-1", "-1", "-1"))
  btns <- function(col) unlist(sv_js(b, sprintf("[...%s.querySelectorAll('button')].map(x => x.getAttribute('tabindex'))",
                                                 sv_th_js("patients", col))))
  expect_true(all(btns("patient_id") == "0"))
  expect_true(all(btns("sex") == "-1"))
  expect_true(all(sv_th_tabindex(b, "visits") == "-1"))
  sv_key(b, "ArrowRight")
  expect_identical(sv_js(b, sv_focus_th_js), "patients.sex")
  expect_equal(sv_th_tabindex(b, "patients"), c("-1", "0", "-1", "-1"))
  expect_true(all(btns("sex") == "0"))
  expect_true(all(btns("patient_id") == "-1"))
  sv_key(b, "ArrowRight")
  sv_key(b, "ArrowRight")
  sv_key(b, "ArrowRight")  # the last column: stays
  expect_identical(sv_js(b, sv_focus_th_js), "patients.site")
  sv_key(b, "ArrowLeft")
  expect_identical(sv_js(b, sv_focus_th_js), "patients.age")
  # headers keys never move the card
  expect_equal(unlist(sv_card_pos(b, "patients")), c(left = 40, top = 120))
  # Tab from the header reaches its own tool buttons
  sv_tab(b)
  expect_identical(sv_js(b, "document.activeElement.getAttribute('data-action')"), "sort-col")
  expect_identical(sv_js(b, "document.activeElement.closest('th').getAttribute('data-col-name')"), "age")
  sv_tab(b, shift = TRUE)
  expect_identical(sv_js(b, sv_focus_th_js), "patients.age")
  sv_key(b, "Escape")
  expect_identical(sv_js(b, sv_focus_where_js), "patients")
  # the card remembers nothing odd: Enter goes to the first header again
  sv_key(b, "Enter")
  expect_identical(sv_js(b, sv_focus_th_js), "patients.patient_id")
  # switch off: every header attribute is back
  sv_js(b, paste0(sv_acc_eng, ".setAccess(false)"))
  expect_equal(sv_js(b, "document.querySelectorAll('thead th[tabindex], thead button[tabindex]').length"), 0)
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("C then Enter on another card's column creates one join, one step, one column_mapped", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, sv_std_cards)
  sv_spy_send(b)
  n0 <- sv_js(b, paste0(sv_acc_eng, ".connections.length"))
  s0 <- sv_js(b, paste0(sv_acc_eng, ".pipeline.steps.length"))
  expect_true(sv_focus_card(b, "patients"))
  sv_key(b, "Enter")
  sv_key_c(b)
  expect_identical(sv_last_ann(b), "Connecting from patients.patient_id. Choose a column.")
  expect_true(sv_js(b, sprintf("%s.classList.contains('sv-kb-connect-source')", sv_th_js("patients", "patient_id"))))
  # a column of the same card does not complete
  sv_key(b, "ArrowRight")
  sv_key(b, "Enter")
  expect_identical(sv_last_ann(b), "Choose a column in another table.")
  expect_equal(sv_source_n(b), 1)
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".connections.length")), n0)
  sv_key(b, "ArrowRight", modifiers = ALT)
  expect_identical(sv_js(b, sv_focus_where_js), "visits")
  sv_key(b, "Enter")
  sv_key(b, "ArrowRight")
  expect_identical(sv_js(b, sv_focus_th_js), "visits.pid")
  sv_key(b, "Enter")
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".connections.length")), n0 + 1)
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".pipeline.steps.length")), s0 + 1)
  mapped <- sv_js(b, sprintf("%s._sent.filter(x => x[0] === 'column_mapped').map(x => x[1])", sv_acc_eng))
  expect_length(mapped, 1)
  expect_identical(mapped[[1]]$from_table, "patients")
  expect_identical(mapped[[1]]$from_col, "patient_id")
  expect_identical(mapped[[1]]$to_table, "visits")
  expect_identical(mapped[[1]]$to_col, "pid")
  # the join type a mouse click-to-connect creates
  expect_identical(mapped[[1]]$join_type, sv_js(b, paste0(sv_acc_eng, ".CLICK_JOIN_TYPE")))
  log <- sv_ann_log(b)
  i_conn <- max(which(log == "Connecting from patients.patient_id. Choose a column."))
  i_join <- which(log == "Join step added. 1 step.")
  expect_length(i_join, 1)
  expect_gt(i_join, i_conn)
  expect_equal(sv_source_n(b), 0)
  expect_identical(sv_js(b, sv_focus_th_js), "visits.pid")
  # the generated code parses in R
  code <- sv_js(b, paste0(sv_acc_eng, ".generatedCode"))
  expect_match(code, "left_join")
  expect_silent(parse(text = code))
  # one undo step
  sv_key(b, "z", code = "KeyZ", modifiers = CTRL)
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".pipeline.steps.length")), s0)
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("Escape cancels connecting", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, sv_std_cards)
  expect_true(sv_focus_card(b, "patients"))
  sv_key(b, "Enter")
  sv_key_c(b)
  expect_equal(sv_source_n(b), 1)
  sv_key(b, "Escape")
  expect_identical(sv_last_ann(b), "Connecting cancelled.")
  expect_equal(sv_source_n(b), 0)
  expect_identical(sv_js(b, sv_focus_th_js), "patients.patient_id")
  # cancelled from another card too
  sv_key_c(b)
  sv_key(b, "ArrowRight", modifiers = ALT)
  expect_identical(sv_js(b, sv_focus_where_js), "visits")
  sv_key(b, "Escape")
  expect_identical(sv_last_ann(b), "Connecting cancelled.")
  expect_equal(sv_source_n(b), 0)
  # nothing is joined afterwards
  sv_key(b, "Enter")
  sv_key(b, "Enter")
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".connections.length")), 0)
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("Delete removes one join; with several a menu lists each plus all", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, sv_std_cards)
  conns <- function() sv_js(b, paste0(sv_acc_eng, ".connections.length"))
  menu_js <- "document.querySelector('.sideview-kb-menu[role=\"menu\"]')"
  # none
  expect_true(sv_focus_th(b, "patients", "patient_id"))
  sv_key(b, "Delete")
  expect_identical(sv_last_ann(b), "No joins on patients.patient_id.")
  # one
  expect_equal(sv_js(b, sv_join_js(list(c("patients", "patient_id", "visits", "pid")))), 1)
  sv_key(b, "Delete")
  expect_equal(conns(), 0)
  expect_identical(sv_last_ann(b), "Removed 1 join on patients.patient_id.")
  expect_identical(sv_js(b, sv_focus_th_js), "patients.patient_id")
  expect_false(sv_js(b, sprintf("!!%s", menu_js)))
  # several: a menu
  sv_js(b, sv_join_js(list(c("patients", "patient_id", "visits", "pid"), c("labs", "patient_id", "patients", "patient_id"))))
  expect_equal(conns(), 2)
  sv_key(b, "Delete")
  expect_true(sv_js(b, sprintf("!!%s", menu_js)))
  items <- unlist(sv_js(b, sprintf("[...%s.querySelectorAll('button[role=\"menuitem\"]')].map(x => x.textContent)", menu_js)))
  expect_equal(items, c("Remove join to visits.pid", "Remove join to labs.patient_id", "All joins on this column"))
  expect_true(sv_js(b, sprintf("document.activeElement === %s.querySelector('button[role=\"menuitem\"]')", menu_js)))
  sv_key(b, "ArrowDown")
  expect_identical(sv_js(b, "document.activeElement.textContent"), "Remove join to labs.patient_id")
  sv_key(b, "ArrowUp")
  expect_identical(sv_js(b, "document.activeElement.textContent"), "Remove join to visits.pid")
  sv_key(b, "Escape")
  expect_false(sv_js(b, sprintf("!!%s", menu_js)))
  expect_identical(sv_js(b, sv_focus_th_js), "patients.patient_id")
  expect_equal(conns(), 2)
  # one item removes that join only
  sv_key(b, "Delete")
  sv_key(b, "Enter")
  expect_equal(conns(), 1)
  expect_identical(sv_last_ann(b), "Removed 1 join on patients.patient_id.")
  expect_identical(sv_js(b, sv_focus_th_js), "patients.patient_id")
  expect_identical(sv_js(b, paste0(sv_acc_eng, ".connections[0].fromTable")), "labs")
  # All joins on this column
  sv_js(b, sv_join_js(list(c("patients", "patient_id", "visits", "pid"))))
  sv_key(b, "Delete")
  sv_key(b, "End")
  expect_identical(sv_js(b, "document.activeElement.textContent"), "All joins on this column")
  sv_key(b, "Enter")
  expect_equal(conns(), 0)
  expect_identical(sv_last_ann(b), "Removed 2 joins on patients.patient_id.")
  expect_false(sv_js(b, sprintf("!!%s", menu_js)))
  expect_identical(sv_js(b, sv_focus_th_js), "patients.patient_id")
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".pipeline.steps.filter(s => s.kind === 'join').length")), 0)
  # switch off closes an open menu
  sv_js(b, sv_join_js(list(c("patients", "patient_id", "visits", "pid"), c("patients", "patient_id", "labs", "patient_id"))))
  sv_key(b, "Delete")
  expect_true(sv_js(b, sprintf("!!%s", menu_js)))
  sv_js(b, paste0(sv_acc_eng, ".setAccess(false)"))
  expect_false(sv_js(b, sprintf("!!%s", menu_js)))
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("J moves to the joined column and cycles", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, sv_std_cards)
  sv_js(b, sv_join_js(list(c("patients", "patient_id", "visits", "pid"), c("labs", "patient_id", "patients", "patient_id"))))
  # the join checks announce their relationship asynchronously; let them land first
  expect_true(sv_wait_js(b, "document.querySelectorAll('.sideview-step-diag').length >= 2 && !document.querySelector('.sideview-step-diag.is-pending')", timeout = 30))
  expect_true(sv_focus_th(b, "patients", "patient_id"))
  sv_key_j(b)
  expect_identical(sv_js(b, sv_focus_th_js), "visits.pid")
  expect_identical(sv_last_ann(b), "visits.pid")
  sv_key_j(b)
  expect_identical(sv_js(b, sv_focus_th_js), "labs.patient_id")
  expect_identical(sv_last_ann(b), "labs.patient_id")
  sv_key_j(b)
  expect_identical(sv_js(b, sv_focus_th_js), "patients.patient_id")
  sv_key_j(b)
  expect_identical(sv_js(b, sv_focus_th_js), "visits.pid")
  # the landing header is the card's roving stop
  expect_equal(sv_th_tabindex(b, "visits"), c("-1", "0", "-1"))
  # no joins: focus stays
  expect_true(sv_focus_th(b, "patients", "sex"))
  sv_key_j(b)
  expect_identical(sv_js(b, sv_focus_th_js), "patients.sex")
  expect_identical(sv_last_ann(b), "No joins on patients.sex.")
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("switching the access off mid-connect cancels it silently", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, sv_std_cards)
  expect_true(sv_focus_th(b, "patients", "patient_id"))
  sv_key_c(b)
  expect_equal(sv_source_n(b), 1)
  sv_js(b, paste0(sv_acc_eng, ".setAccess(false)"))
  expect_equal(sv_source_n(b), 0)
  expect_false("Connecting cancelled." %in% sv_ann_log(b))
  expect_identical(sv_last_ann(b), "Accessible canvas off.")
  sv_js(b, paste0(sv_acc_eng, ".setAccess(true)"))
  expect_true(sv_focus_th(b, "visits", "pid"))
  sv_key(b, "Enter")
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".connections.length")), 0)
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("list view, the ? dialog and Ctrl+K each cancel connecting", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, sv_std_cards)
  sv_js(b, paste0(sv_acc_eng, ".setShortcuts(true)"))
  start <- function() {
    expect_true(sv_focus_th(b, "patients", "patient_id"))
    sv_key_c(b)
    expect_equal(sv_source_n(b), 1)
  }
  start()
  sv_js(b, paste0(sv_acc_eng, ".setView('list')"))
  expect_equal(sv_source_n(b), 0)
  expect_true("Connecting cancelled." %in% sv_ann_log(b))
  sv_js(b, paste0(sv_acc_eng, ".setView('canvas')"))
  start()
  sv_key(b, "?", code = "Slash", modifiers = SHIFT, text = "?")
  expect_true(sv_js(b, "!!document.querySelector('.sideview-shortcuts-scrim')"))
  expect_equal(sv_source_n(b), 0)
  sv_key(b, "Escape")
  expect_false(sv_js(b, "!!document.querySelector('.sideview-shortcuts-scrim')"))
  start()
  sv_key(b, "k", code = "KeyK", modifiers = CTRL)
  expect_true(sv_js(b, "!!document.querySelector('.sideview-search-scrim')"))
  expect_equal(sv_source_n(b), 0)
  sv_key(b, "Escape")
  # a cancelled connect makes no join on the next Enter
  expect_true(sv_focus_th(b, "visits", "pid"))
  sv_key(b, "Enter")
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".connections.length")), 0)
  sv_js(b, "localStorage.removeItem('sideview.access'); localStorage.removeItem('sideview.shortcuts')")
})

test_that("module: sv_remove_card() on the focused or source card moves focus and cancels connecting", {
  skip_if_no_browser()
  app <- sv_start_app(paste0(
    "shiny::shinyApp(shiny::fluidPage(sideview::sideviewUI('m', height = '780px', access = TRUE)),",
    "function(input, output, session) { px <- sideview::sideviewServer('m', cards = list(",
    "patients = patients, visits = visits, labs = labs));",
    "shiny::observeEvent(input$rm, sideview::sv_remove_card(px, input$rm)) })"))
  b <- sv_open_page(app$url, 1360, 820, wait_for = sv_acc_ready)
  withr::defer({
    try(b$close(), silent = TRUE)
    try(app$proc$kill(), silent = TRUE)
  })
  expect_true(sv_wait_js(b, "document.querySelectorAll('.sideview-card').length === 3", timeout = 60))
  sv_place_cards(b, sv_std_cards)
  # the focused card is also the source
  expect_true(sv_focus_th(b, "visits", "pid"))
  sv_key_c(b)
  expect_equal(sv_source_n(b), 1)
  sv_js(b, "Shiny.setInputValue('rm', 'visits', {priority: 'event'}); true")
  expect_true(sv_wait_js(b, "document.querySelectorAll('.sideview-card').length === 2", timeout = 30))
  expect_equal(sv_source_n(b), 0)
  expect_true("Connecting cancelled." %in% sv_ann_log(b))
  expect_identical(sv_js(b, sv_focus_where_js), "labs")
  # the source card goes while focus is on another card
  expect_true(sv_focus_th(b, "labs", "patient_id"))
  sv_key_c(b)
  sv_key(b, "ArrowUp", modifiers = ALT)
  expect_identical(sv_js(b, sv_focus_where_js), "patients")
  n_cancel <- sum(sv_ann_log(b) == "Connecting cancelled.")
  sv_js(b, "Shiny.setInputValue('rm', 'labs', {priority: 'event'}); true")
  expect_true(sv_wait_js(b, "document.querySelectorAll('.sideview-card').length === 1", timeout = 30))
  expect_equal(sv_source_n(b), 0)
  expect_equal(sum(sv_ann_log(b) == "Connecting cancelled."), n_cancel + 1)
  expect_identical(sv_js(b, sv_focus_where_js), "patients")
  sv_key(b, "Enter")
  sv_key(b, "Enter")
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".connections.length")), 0)
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("card and column names are shown as literal text in announcements and the menu", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  x <- "<img src=x onerror=\"window.__x=1\">"
  xj <- jsonlite::toJSON(x, auto_unbox = TRUE)
  sv_js(b, sprintf("(() => { const e = %s; const n = %s; const d = {}; d[n] = ['a', 'b']; d.other = [1, 2];
    e.addCardFromR({name: n, data: d}); return true; })()", sv_acc_eng, xj))
  expect_true(sv_wait_js(b, "document.querySelectorAll('.sideview-card').length === 4"))
  pos <- sv_std_cards
  pos[[x]] <- c(760, 900)
  sv_place_cards(b, pos)
  sv_js(b, sv_join_js(list(c("patients", "patient_id", x, x), c("patients", "patient_id", "visits", "pid"))))
  expect_true(sv_focus_th(b, x, x))
  sv_key_c(b)
  expect_identical(sv_last_ann(b), paste0("Connecting from ", x, ".", x, ". Choose a column."))
  sv_key(b, "Escape")
  expect_true(sv_focus_th(b, "patients", "patient_id"))
  sv_key_j(b)
  expect_identical(sv_last_ann(b), paste0(x, ".", x))
  expect_true(sv_focus_th(b, "patients", "patient_id"))
  sv_key(b, "Delete")
  items <- unlist(sv_js(b, "[...document.querySelectorAll('.sideview-kb-menu button[role=\"menuitem\"]')].map(x => x.textContent)"))
  expect_identical(items[1], paste0("Remove join to ", x, ".", x))
  expect_equal(sv_js(b, "document.querySelectorAll('.sideview-kb-menu img').length"), 0)
  sv_key(b, "Escape")
  sv_key(b, "Delete")
  sv_key(b, "End")
  sv_key(b, "Enter")
  expect_identical(sv_last_ann(b), "Removed 2 joins on patients.patient_id.")
  expect_true(sv_focus_th(b, x, x))
  sv_key(b, "Delete")
  expect_identical(sv_last_ann(b), paste0("No joins on ", x, ".", x, "."))
  Sys.sleep(0.3)
  expect_true(sv_js(b, "typeof window.__x === 'undefined'"))
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("Alt+Arrow with no card in that direction says so", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, sv_std_cards)
  expect_true(sv_focus_card(b, "patients"))
  sv_key(b, "ArrowLeft", modifiers = ALT)
  expect_identical(sv_last_ann(b), "No card to the left.")
  expect_identical(sv_js(b, sv_focus_where_js), "patients")
  sv_key(b, "ArrowUp", modifiers = ALT)
  expect_identical(sv_last_ann(b), "No card above.")
  expect_true(sv_focus_card(b, "labs"))
  sv_key(b, "ArrowDown", modifiers = ALT)
  expect_identical(sv_last_ann(b), "No card below.")
  expect_true(sv_focus_card(b, "visits"))
  sv_key(b, "ArrowRight", modifiers = ALT)
  expect_identical(sv_last_ann(b), "No card to the right.")
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("a header Delete with one join removes it and sends column_disconnected", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_place_cards(b, sv_std_cards)
  sv_js(b, sv_join_js(list(c("patients", "patient_id", "visits", "pid"))))
  sv_spy_send(b)
  expect_true(sv_focus_th(b, "patients", "patient_id"))
  sv_key(b, "Delete")
  expect_equal(sv_js(b, paste0(sv_acc_eng, ".connections.length")), 0)
  sent <- sv_js(b, sprintf("%s._sent.filter(x => x[0] === 'column_disconnected').map(x => x[1])", sv_acc_eng))
  expect_length(sent, 1)
  expect_identical(sent[[1]]$from_table, "patients")
  expect_identical(sent[[1]]$to_table, "visits")
  expect_equal(sent[[1]]$remaining_count, 0)
  expect_identical(sv_last_ann(b), "Removed 1 join on patients.patient_id.")
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("switching the access flips the row height and keeps the first visible row", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = FALSE)
  sv_js(b, sprintf("(() => { const e = %s; const d = {n: []}; for (let i = 0; i < 600; i++) d.n.push(i);
    e.addCardFromR({name: 'tall', data: d}); return true; })()", sv_acc_eng))
  expect_true(sv_wait_js(b, "document.querySelectorAll('.sideview-card').length === 4"))
  first <- "(() => { const t = %s; const vt = t._virtualTable; const sc = vt.scrollContainer;
    return { top: sc.scrollTop, h: vt.rowHeight, row: Math.floor(sc.scrollTop / vt.rowHeight) }; })()"
  tbl <- sprintf("[...%s.cards.values()].find(m => m.name === 'tall').element.querySelector('table')", sv_acc_eng)
  sv_js(b, sprintf("(() => { const vt = %s._virtualTable; vt.scrollContainer.scrollTop = 28 * 100; vt.render(); return true; })()", tbl))
  before <- sv_js(b, sprintf(first, tbl))
  expect_equal(before$row, 100)
  sv_js(b, paste0(sv_acc_eng, ".setAccess(true)"))
  after <- sv_js(b, sprintf(first, tbl))
  expect_gt(after$h, before$h)
  expect_equal(after$row, 100, tolerance = 0.01)
  sv_js(b, paste0(sv_acc_eng, ".setAccess(false)"))
  back <- sv_js(b, sprintf(first, tbl))
  expect_equal(back$row, 100, tolerance = 0.01)
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

# ---- final review fixes (I1, I2, I3, M8) ----

test_that("two canvases on one page: switching one leaves the other as it was until the next load", {
  skip_if_no_browser()
  app <- sv_start_app(paste0(
    "shiny::shinyApp(shiny::fluidPage(sideview::sideviewUI('a', height = '420px'),",
    " sideview::sideviewUI('b', height = '420px')),",
    " function(input, output, session) { sideview::sideviewServer('a', cards = list(patients = patients, visits = visits));",
    " sideview::sideviewServer('b', cards = list(visits = visits, labs = labs)) })"))
  ready <- "document.querySelectorAll('.sideview-container').length === 2 &&
    Array.from(document.querySelectorAll('.sideview-container')).every(c => !!c._sideviewInstance &&
      c.querySelectorAll('.sideview-card').length >= 2)"
  b <- sv_open_page(app$url, 1360, 1000, wait_for = ready)
  withr::defer({
    try(b$close(), silent = TRUE)
    try(app$proc$kill(), silent = TRUE)
  })
  sv_js(b, "localStorage.removeItem('sideview.access'); true")
  sv_navigate(b, sv_js(b, "location.href"))
  expect_true(sv_wait_js(b, ready, timeout = 60))
  eng <- function(i) sprintf("document.querySelectorAll('.sideview-container')[%d]._sideviewInstance", i)
  look <- function(i) sv_js(b, sprintf("(() => { const e = %s;
    return { cls: e.container.classList.contains('sv-access'), on: e.accessOn(), row: e.rowHeightNow(),
             min: e.minScaleNow() }; })()", eng(i)))
  b0 <- look(1)
  expect_false(b0$cls)
  expect_false(b0$on)
  sv_js(b, paste0(eng(0), ".setAccess(true)"))
  a1 <- look(0)
  expect_true(a1$cls)
  expect_true(a1$on)
  expect_equal(a1$row, 36)
  expect_equal(a1$min, 1)
  # b is unchanged: class, row height, zoom floor, a new card's table, and its ? switch
  b1 <- look(1)
  expect_identical(b1, b0)
  expect_equal(b1$row, 28)
  expect_equal(b1$min, 0.15)
  sv_js(b, sprintf("(() => { const e = %s; e.addCardFromR({name: 'extra', data: {n: [1, 2, 3]}}); return true; })()", eng(1)))
  expect_true(sv_wait_js(b, "document.querySelectorAll('.sideview-container')[1].querySelectorAll('.sideview-card').length === 3"))
  expect_equal(sv_js(b, sprintf("[...%s.cards.values()].find(m => m.name === 'extra').element.querySelector('table')._virtualTable.rowHeight", eng(1))), 28)
  sv_js(b, sprintf("%s.toggleShortcuts(true)", eng(1)))
  bsw <- "document.querySelectorAll('.sideview-container')[1].querySelector('[data-sv-access-switch]')"
  expect_identical(sv_js(b, sprintf("%s.getAttribute('aria-checked')", bsw)), "false")
  # clicking b's switch turns b on and leaves a on
  p <- sv_js(b, sprintf("(() => { const r = %s.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()", bsw))
  for (type in c("mouseMoved", "mousePressed", "mouseReleased")) {
    b$Input$dispatchMouseEvent(type = type, x = p$x, y = p$y, button = "left", clickCount = if (type == "mouseMoved") 0 else 1)
  }
  expect_identical(sv_js(b, sprintf("%s.getAttribute('aria-checked')", bsw)), "true")
  expect_true(look(1)$cls)
  expect_true(look(0)$on)
  expect_true(look(0)$cls)
  sv_js(b, sprintf("%s.toggleShortcuts(false)", eng(1)))
  sv_js(b, paste0(eng(1), ".setAccess(false)"))
  # a still shows on until a reload; after the reload both follow the stored choice
  expect_true(look(0)$on)
  sv_js(b, "localStorage.setItem('sideview.access', 'on'); true")
  sv_navigate(b, sv_js(b, "location.href"))
  expect_true(sv_wait_js(b, ready, timeout = 60))
  for (i in 0:1) {
    r <- look(i)
    expect_true(r$cls)
    expect_true(r$on)
    expect_equal(r$row, 36)
    expect_equal(r$min, 1)
  }
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

sv_state_sizes <- function(st) {
  stats::setNames(lapply(st$cards, function(c) c(c$width, c$height)), vapply(st$cards, function(c) c$name, ""))
}

sv_card_sizes_js <- "(() => { const o = {}; document.querySelectorAll('.sideview-card').forEach(c => {
  o[c.getAttribute('data-card-name')] = [c.offsetWidth, c.offsetHeight]; }); return o; })()"

sv_state_arg <- function(st) {
  jsonlite::toJSON(as.character(jsonlite::toJSON(st, auto_unbox = TRUE, null = "null", digits = NA)), auto_unbox = TRUE)
}

test_that("state saved with the switch on keeps the default card sizes", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = FALSE)
  expect_true(sv_wait_js(b, "Array.from(document.querySelectorAll('.sideview-card')).every(c => c.classList.contains('sv-sized'))"))
  off <- sv_js(b, sprintf("%s.getState()", sv_acc_eng))
  sv_js(b, paste0(sv_acc_eng, ".setAccess(true)"))
  Sys.sleep(0.3)
  grown <- sv_js(b, sv_card_sizes_js)
  expect_true(any(vapply(names(grown), function(n) !identical(as.numeric(unlist(grown[[n]])),
                                                              as.numeric(sv_state_sizes(off)[[n]])), TRUE)))
  on <- sv_js(b, sprintf("%s.getState()", sv_acc_eng))
  expect_equal(sv_state_sizes(on), sv_state_sizes(off))
  expect_true(all(vapply(on$cards, function(c) is.null(c$user_sized), TRUE)))
  # open the switch-on save with the switch off: the old layout
  sv_js(b, paste0(sv_acc_eng, ".setAccess(false)"))
  sv_js(b, sprintf("%s.applyState(JSON.parse(%s)); true", sv_acc_eng, sv_state_arg(on)))
  Sys.sleep(0.2)
  now <- sv_js(b, sv_card_sizes_js)
  for (n in names(now)) expect_equal(as.numeric(unlist(now[[n]])), as.numeric(sv_state_sizes(off)[[n]]), label = n)
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("a card the user sized keeps its size through save and open with the switch on", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  expect_true(sv_wait_js(b, "Array.from(document.querySelectorAll('.sideview-card')).every(c => c.classList.contains('sv-sized'))"))
  corner <- sv_js(b, sprintf("(() => { const r = %s.getBoundingClientRect(); return { x: r.right - 3, y: r.bottom - 3 }; })()",
                             sv_card_js("patients")))
  mouse <- function(type, x, y) b$Input$dispatchMouseEvent(type = type, x = x, y = y, button = "left",
                                                          clickCount = if (type == "mouseMoved") 0 else 1)
  mouse("mouseMoved", corner$x, corner$y)
  mouse("mousePressed", corner$x, corner$y)
  for (t in seq(0.25, 1, by = 0.25)) mouse("mouseMoved", corner$x + 60 * t, corner$y - 60 * t)
  mouse("mouseReleased", corner$x + 60, corner$y - 60)
  Sys.sleep(0.3)
  expect_identical(sv_js(b, sprintf("%s.getAttribute('data-sv-user-sized')", sv_card_js("patients"))), "true")
  sized <- sv_js(b, sv_card_sizes_js)$patients
  st <- sv_js(b, sprintf("%s.getState()", sv_acc_eng))
  pc <- Filter(function(c) c$name == "patients", st$cards)[[1]]
  expect_true(isTRUE(pc$user_sized))
  expect_equal(c(pc$width, pc$height), as.numeric(unlist(sized)))
  arg <- sv_state_arg(st)
  # a fresh load (the stored choice keeps the switch on), then Open
  sv_navigate(b, sv_js(b, "location.href"))
  expect_true(sv_wait_js(b, sv_acc_ready, timeout = 60))
  expect_true(sv_acc_class(b))
  expect_null(sv_js(b, sprintf("%s.getAttribute('data-sv-user-sized')", sv_card_js("patients"))))
  sv_js(b, sprintf("%s.applyState(JSON.parse(%s)); true", sv_acc_eng, arg))
  Sys.sleep(0.2)
  expect_identical(sv_js(b, sprintf("%s.getAttribute('data-sv-user-sized')", sv_card_js("patients"))), "true")
  expect_equal(as.numeric(unlist(sv_js(b, sv_card_sizes_js)$patients)), as.numeric(unlist(sized)))
  # the other cards were not sized by the user and are not marked
  expect_null(sv_js(b, sprintf("%s.getAttribute('data-sv-user-sized')", sv_card_js("visits"))))
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

sv_linecap_js <- "Array.from(document.querySelectorAll('.sideview-connector-svg .sideview-connector-path[data-sv-pat]'))
  .map(p => getComputedStyle(p).strokeLinecap)"

test_that("dash patterns use butt caps, so their gaps stay open at 3 and 5 px", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  sv_js(b, sv_six_joins_js(sv_acc_eng))
  expect_equal(unique(unlist(sv_js(b, sv_linecap_js))), "butt")
  sv_js(b, "document.querySelectorAll('.sideview-connector-svg .sideview-connector-path[data-sv-pat]')[2].classList.add('is-hover', 'active'); true")
  expect_equal(unique(unlist(sv_js(b, sv_linecap_js))), "butt")
  # off: the default canvas keeps its round caps; forced colours turn the patterns, and butt caps, on
  b0 <- sv_acc_open("gadget", access = FALSE)
  sv_js(b0, sv_six_joins_js(sv_acc_eng))
  expect_equal(unique(unlist(sv_js(b0, sv_linecap_js))), "round")
  sv_emulate(b0, "forced-colors", "active")
  Sys.sleep(0.3)
  expect_equal(unique(unlist(sv_js(b0, sv_linecap_js))), "butt")
  sv_emulate(b0, "forced-colors", "none")
  sv_emulate(b0, "prefers-contrast", "more")
  Sys.sleep(0.3)
  expect_equal(unique(unlist(sv_js(b0, sv_linecap_js))), "round")
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

# Focus is on something that can hold it: the container, or an element that is still focusable.
sv_focus_ok_js <- "(() => { const a = document.activeElement; const c = a && a.closest ? a.closest('.sideview-container') : null;
  if (!c) return 'outside';
  const focusable = a === c || a.hasAttribute('tabindex') || a.matches('button:not([disabled]), a[href], input, select, textarea');
  return focusable ? 'ok' : 'stranded:' + a.tagName; })()"

test_that("switching off never strands focus on a header, its button or a card body", {
  skip_if_no_browser()
  b <- sv_acc_open("gadget", access = TRUE)
  # a column header
  expect_true(sv_focus_th(b, "patients", "age"))
  sv_js(b, paste0(sv_acc_eng, ".setAccess(false)"))
  expect_identical(sv_js(b, sv_focus_ok_js), "ok")
  expect_true(sv_js(b, "document.activeElement === document.querySelector('.sideview-container')"))
  # a card body
  sv_js(b, paste0(sv_acc_eng, ".setAccess(true)"))
  expect_true(sv_js(b, sprintf("(() => { const t = %s.querySelector('.sideview-card-body'); t.focus({preventScroll: true});
    return document.activeElement === t; })()", sv_card_js("visits"))))
  sv_js(b, paste0(sv_acc_eng, ".setAccess(false)"))
  expect_identical(sv_js(b, sv_focus_ok_js), "ok")
  # a sort button inside a header keeps its focus: it is a button
  sv_js(b, paste0(sv_acc_eng, ".setAccess(true)"))
  expect_true(sv_focus_th(b, "patients", "age"))
  expect_true(sv_js(b, "(() => { const t = document.activeElement.querySelector('.sideview-sort-btn');
    t.focus({preventScroll: true}); return document.activeElement === t; })()"))
  sv_js(b, paste0(sv_acc_eng, ".setAccess(false)"))
  expect_identical(sv_js(b, sv_focus_ok_js), "ok")
  expect_true(sv_js(b, "document.activeElement.classList.contains('sideview-sort-btn')"))
  sv_js(b, "localStorage.removeItem('sideview.access')")
})

test_that("widget: switching off in the ? dialog from a header returns focus inside the canvas", {
  skip_if_no_browser()
  b <- sv_acc_open("widget", access = TRUE)
  sv_js(b, "localStorage.removeItem('sideview.access'); true")
  expect_true(sv_acc_class(b))
  expect_true(sv_focus_th(b, "patients", "age"))
  sv_key(b, "?", code = "Slash", modifiers = 8L, text = "?")
  expect_true(sv_wait_js(b, "!!document.querySelector('.sideview-shortcuts-scrim')"))
  sw <- "document.querySelector('[data-sv-access-switch]')"
  p <- sv_js(b, sprintf("(() => { const r = %s.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()", sw))
  for (type in c("mouseMoved", "mousePressed", "mouseReleased")) {
    b$Input$dispatchMouseEvent(type = type, x = p$x, y = p$y, button = "left", clickCount = if (type == "mouseMoved") 0 else 1)
  }
  expect_false(sv_acc_class(b))
  sv_key(b, "Escape")
  expect_false(sv_js(b, "!!document.querySelector('.sideview-shortcuts-scrim')"))
  Sys.sleep(0.2)
  expect_identical(sv_js(b, sv_focus_ok_js), "ok")
  expect_true(sv_js(b, paste0(sv_acc_eng, ".ownsKeyboard()")))
  sv_js(b, "localStorage.removeItem('sideview.access')")
})
