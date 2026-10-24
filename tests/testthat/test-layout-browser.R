# Real-browser layout & interaction regression tests (headless Chrome).
# These cover what the mock-DOM suite cannot: geometry, overlap, sticky
# headers, connector alignment and real event handling.

.sv_browser <- new.env()

sv_shared_page <- function() {
  skip_if_no_browser()
  if (is.null(.sv_browser$page)) {
    .sv_browser$app <- sv_start_app()
    .sv_browser$page <- sv_open_page(.sv_browser$app$url)
    withr::defer({
      try(.sv_browser$page$close(), silent = TRUE)
      try(.sv_browser$app$proc$kill(), silent = TRUE)
      .sv_browser$page <- NULL
    }, envir = testthat::teardown_env())
  }
  b <- .sv_browser$page
  sv_set_viewport(b, 1400, 900)
  b
}

rect_overlap <- function(a, b) {
  if (is.null(a) || is.null(b)) return(FALSE)
  a$left < b$right && b$left < a$right && a$top < b$bottom && b$top < a$bottom
}

test_that("engine initialises without JavaScript errors", {
  b <- sv_shared_page()
  expect_true(attr(b, "sv_ready"))
  expect_equal(attr(b, "sv_errors")(), character())
})

test_that("cards have a sensible width and show several columns", {
  b <- sv_shared_page()
  info <- sv_js(b, sprintf("(() => {
    const c = %s; const r = c.getBoundingClientRect();
    const ths = [...c.querySelectorAll('thead th')];
    const visible = ths.filter(t => t.getBoundingClientRect().right <= r.right + 1).length;
    return { width: r.width, visible: visible, total: ths.length };
  })()", sv_card_js("patients")))
  expect_gt(info$width, 300)
  expect_lt(info$width, 1000)
  expect_gte(info$visible, 3)
})

sv_launch_layout <- function(b) {
  sv_js(b, "(() => {
    const c = document.querySelector('.sideview-container').getBoundingClientRect();
    const box = s => [...document.querySelectorAll(s)].map(e => e.getBoundingClientRect())
      .filter(r => r.width && r.height && r.top - c.top < c.height / 3).map(r => r.bottom);
    const chrome = Math.max(0, ...box('.sideview-toolbar'), ...box('.sideview-palette'));
    const cards = [...document.querySelectorAll('.sideview-card')].map(e => e.getBoundingClientRect().toJSON());
    const code = document.querySelector('.sideview-code-text').closest('pre').textContent;
    return { chrome: chrome, cards: cards, code: code, vw: innerWidth,
             scale: window._sideviewInstance.panzoom.getScale(),
             auto: document.querySelectorAll('[data-auto-place]').length };
  })()")
}

sv_expect_tidy_launch <- function(r, label) {
  n <- length(r$cards)
  expect_gte(n, 3)
  for (i in seq_len(n - 1)) for (j in (i + 1):n) {
    expect_false(rect_overlap(r$cards[[i]], r$cards[[j]]), info = paste(label, "cards", i, j))
  }
  for (cd in r$cards) {
    expect_gte(cd$top, r$chrome, label = paste(label, "card top below chrome"))
    # Overflow is vertical only: no sideways panning needed to see a card.
    expect_lte(cd$right, r$vw + 1, label = paste(label, "card right edge inside window"))
  }
  expect_gte(r$scale, 0.5 - 1e-6)
  expect_lte(r$scale, 1 + 1e-6)
  expect_equal(r$auto, 0)
  # htmltools must not indent the server-rendered placeholder inside <pre>.
  expect_identical(r$code, "# Connect two columns to generate pipeline code")
}

test_that("cards are laid out without overlap below the chrome on launch", {
  b <- sv_shared_page()
  sv_expect_tidy_launch(sv_launch_layout(b), "1400x900")

  # A narrow window, as in the RStudio Viewer pane: the toolbar wraps.
  nb <- sv_open_page(.sv_browser$app$url, 420, 700)
  on.exit(try(nb$close(), silent = TRUE), add = TRUE)
  expect_true(attr(nb, "sv_ready"))
  sv_expect_tidy_launch(sv_launch_layout(nb), "420x700")
})

test_that("Fit and Arrange keep every card visible and apart", {
  b <- sv_shared_page()
  r <- sv_js(b, "(async () => {
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const cards = [...document.querySelectorAll('.sideview-card')];
    const saved = cards.map(c => [c.style.left, c.style.top]);
    const pz = window._sideviewInstance.panzoom;
    const savedPz = [pz.getScale(), pz.getPan()];
    cards[1].style.left = '3000px'; cards[1].style.top = '2000px';
    document.querySelector('[data-action=\"fit-all\"]').click(); await sleep(200);
    const inView = () => cards.every(c => { const r = c.getBoundingClientRect(); return r.left >= 0 && r.top >= 0 && r.right <= innerWidth + 1 && r.bottom <= innerHeight + 1; });
    const fit = inView();
    document.querySelector('[data-action=\"arrange-cards\"]').click(); await sleep(200);
    const rects = cards.map(c => c.getBoundingClientRect().toJSON());
    cards.forEach((c, i) => { c.style.left = saved[i][0]; c.style.top = saved[i][1]; });
    pz.zoom(savedPz[0]); pz.pan(savedPz[1].x, savedPz[1].y);
    return { fit: fit, rects: rects };
  })()")
  expect_true(r$fit)
  n <- length(r$rects)
  for (i in seq_len(n - 1)) for (j in (i + 1):n) {
    expect_false(rect_overlap(r$rects[[i]], r$rects[[j]]), info = paste("arranged", i, j))
  }
})

test_that("icons render as inline SVG with no emoji or glyph text", {
  b <- sv_shared_page()
  r <- sv_js(b, "(() => {
    const root = document.querySelector('.sideview-container');
    const slots = [...root.querySelectorAll('[data-sv-icon]')];
    const empty = slots.filter(el => !el.querySelector('svg.sv-icon')).map(el => el.dataset.svIcon);
    const btns = [...root.querySelectorAll('button, .sideview-ai-icon')];
    const glyphs = btns.map(el => el.textContent).filter(t => /[^\\x00-\\x7F]/.test(t));
    const unlabeled = [...root.querySelectorAll('.sideview-icon-btn, .sideview-th-btn')]
      .filter(el => !el.getAttribute('aria-label')).length;
    const svg = root.querySelector('.sideview-th-btn svg.sv-icon').getBoundingClientRect();
    return { slots: slots.length, empty: empty, glyphs: glyphs, unlabeled: unlabeled, w: svg.width };
  })()")
  expect_gt(r$slots, 10)
  expect_length(r$empty, 0)
  expect_length(r$glyphs, 0)
  expect_equal(r$unlabeled, 0)
  expect_gt(r$w, 6)
})

test_that("sort and card toggles swap their SVG icon", {
  b <- sv_shared_page()
  r <- sv_js(b, sprintf("(async () => {
    const c = %s;
    const sb = c.querySelector('[data-action=\"sort-col\"][data-col-name=\"value\"]');
    sb.click(); await new Promise(r => setTimeout(r, 400)); const a = sb.dataset.svIcon;
    sb.click(); await new Promise(r => setTimeout(r, 400)); const d = sb.dataset.svIcon;
    sb.click(); await new Promise(r => setTimeout(r, 400)); const n = sb.dataset.svIcon;
    const mb = c.querySelector('[data-action=\"minimize-card\"]');
    mb.click(); const m1 = mb.dataset.svIcon; mb.click(); const m2 = mb.dataset.svIcon;
    return [a, d, n, m1, m2, !!sb.querySelector('svg'), !!mb.querySelector('svg')];
  })()", sv_card_js("labs")))
  expect_equal(unlist(r[1:5]), c("sortAsc", "sortDesc", "sort", "plus", "minus"))
  expect_true(isTRUE(r[[6]]) && isTRUE(r[[7]]))
})

test_that("chrome elements do not overlap at common window sizes", {
  b <- sv_shared_page()
  for (sz in list(c(1400, 900), c(1024, 700), c(560, 520))) {
    sv_set_viewport(b, sz[1], sz[2])
    rects <- sv_js(b, "(() => {
      const r = s => { const e = document.querySelector(s); if (!e || getComputedStyle(e).display === 'none' || getComputedStyle(e).visibility === 'hidden') return null; const x = e.getBoundingClientRect(); return x.width && x.height ? x.toJSON() : null; };
      return { toolbar: r('.sideview-toolbar'), palette: r('.sideview-palette'), ai: r('.sideview-ai-bar'), vw: innerWidth, vh: innerHeight };
    })()")
    label <- paste(sz, collapse = "x")
    expect_false(rect_overlap(rects$toolbar, rects$palette), info = paste("toolbar/palette", label))
    expect_false(rect_overlap(rects$toolbar, rects$ai), info = paste("toolbar/ai", label))
    for (nm in c("toolbar", "palette", "ai")) {
      r <- rects[[nm]]
      if (is.null(r)) next
      expect_true(r$left >= 0 && r$right <= rects$vw + 1 && r$bottom <= rects$vh + 1,
                  info = paste(nm, "inside window", label))
    }
  }
  sv_set_viewport(b, 1400, 900)
})

test_that("open drawer does not cover the toolbar and fits the window", {
  b <- sv_shared_page()
  for (sz in list(c(1400, 900), c(1024, 700), c(560, 520))) {
    sv_set_viewport(b, sz[1], sz[2])
    r <- sv_js(b, "(async () => {
      const d = document.querySelector('.sideview-drawer');
      if (d.classList.contains('collapsed')) document.querySelector('[data-action=\"toggle-drawer\"]').click();
      await new Promise(r => setTimeout(r, 400));
      const out = { drawer: d.getBoundingClientRect().toJSON(), toolbar: document.querySelector('.sideview-toolbar').getBoundingClientRect().toJSON(), vw: innerWidth, vh: innerHeight, scrollW: d.querySelector('.sideview-drawer-tabs').scrollWidth, clientW: d.querySelector('.sideview-drawer-tabs').clientWidth };
      document.querySelector('[data-action=\"toggle-drawer\"]').click();
      await new Promise(r => setTimeout(r, 300));
      return out;
    })()")
    label <- paste(sz, collapse = "x")
    expect_false(rect_overlap(r$drawer, r$toolbar), info = paste("drawer/toolbar", label))
    expect_true(r$drawer$bottom <= r$vh + 1 && r$drawer$right <= r$vw + 1, info = paste("drawer inside", label))
    expect_lte(r$scrollW, r$clientW + 1, label = paste("drawer tabs not clipped", label))
  }
  sv_set_viewport(b, 1400, 900)
})

test_that("column headers stay sticky while the card body scrolls", {
  b <- sv_shared_page()
  r <- sv_js(b, sprintf("(async () => {
    const c = %s; const body = c.querySelector('.sideview-card-body');
    body.scrollTop = 2000; body.dispatchEvent(new Event('scroll'));
    await new Promise(r => setTimeout(r, 200));
    const out = { th: c.querySelector('thead th').getBoundingClientRect().top, body: body.getBoundingClientRect().top, scrolled: body.scrollTop };
    body.scrollTop = 0; body.dispatchEvent(new Event('scroll'));
    return out;
  })()", sv_card_js("labs")))
  expect_gt(r$scrolled, 0)
  expect_lt(abs(r$th - r$body), 3)
})

test_that("zoom label tracks the canvas scale", {
  b <- sv_shared_page()
  r <- sv_js(b, "(async () => {
    const zin = document.querySelector('[data-action=\"zoom-in\"]');
    zin.click(); await new Promise(r => setTimeout(r, 300));
    const label = document.querySelector('[data-action=\"zoom-reset\"]').textContent.trim();
    document.querySelector('[data-action=\"zoom-reset\"]').click(); await new Promise(r => setTimeout(r, 300));
    return { label: label, after: document.querySelector('[data-action=\"zoom-reset\"]').textContent.trim() };
  })()")
  expect_false(identical(r$label, "100%"))
  expect_equal(r$after, "100%")
})

test_that("click-to-connect creates exactly one join per pair (no phantom draft)", {
  b <- sv_shared_page()
  r <- sv_js(b, sprintf("(async () => {
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const port = (card, col) => card.querySelector('.sideview-col-port[data-col-name=\"' + col + '\"]');
    const fire = el => { const x = el.getBoundingClientRect(); ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(t => el.dispatchEvent(new MouseEvent(t, {bubbles: true, button: 0, clientX: x.x + 2, clientY: x.y + 2}))); };
    const pat = %s, labs = %s, vis = %s;
    fire(port(pat, 'patient_id')); await sleep(150); fire(port(labs, 'patient_id')); await sleep(400);
    fire(port(vis, 'pid')); await sleep(150); fire(port(pat, 'patient_id')); await sleep(400);
    const n = document.querySelectorAll('.sideview-connector-path:not(.sideview-connector-draft)').length;
    const drafting = !!document.querySelector('.sideview-connector-draft[d]:not([d=\"\"])');
    document.querySelector('[data-action=\"clear-operation\"]').click(); await sleep(300);
    return { n: n, drafting: drafting };
  })()", sv_card_js("patients"), sv_card_js("labs"), sv_card_js("visits")))
  expect_equal(r$n, 2)
  expect_false(r$drafting)
})

test_that("real mouse clicks connect ports through the draft and existing splines", {
  b <- sv_shared_page()
  centre <- function(card, col) sv_js(b, sprintf("(() => {
    const r = %s.querySelector('.sideview-col-port[data-col-name=\"%s\"]').getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  })()", sv_card_js(card), col))
  mouse <- function(type, p) {
    b$Input$dispatchMouseEvent(type = type, x = p$x, y = p$y, button = "left",
                               clickCount = if (type == "mouseMoved") 0 else 1)
  }
  click <- function(p) { mouse("mouseMoved", p); mouse("mousePressed", p); mouse("mouseReleased", p) }
  glide <- function(from, to) {
    for (t in seq(0.2, 1, by = 0.2)) {
      mouse("mouseMoved", list(x = from$x + (to$x - from$x) * t, y = from$y + (to$y - from$y) * t))
    }
  }
  n_links <- function() sv_js(b, "document.querySelectorAll('.sideview-connector-path:not(.sideview-connector-draft):not(.sideview-spline-suggested)').length")

  p1 <- centre("patients", "patient_id")
  p2 <- centre("labs", "patient_id")
  click(p1)
  glide(p1, p2) # the draft end now sits under the cursor, on top of p2
  click(p2)
  Sys.sleep(0.3)
  expect_equal(n_links(), 1)

  # Clicking a port where a spline ends starts a new link instead of deleting it
  click(p1)
  Sys.sleep(0.2)
  expect_equal(n_links(), 1)
  expect_equal(sv_js(b, "window._sideviewInstance.activePort && window._sideviewInstance.activePort.colName"), "patient_id")
  b$Input$dispatchKeyEvent(type = "keyDown", key = "Escape", code = "Escape", windowsVirtualKeyCode = 27)

  # Where the spline crosses a card, the card gets the click; over empty canvas
  # the spline is clickable and disconnects. Move visits out of the way and
  # labs right so the spline spans empty canvas too.
  saved <- sv_js(b, "(() => {
    const eng = window._sideviewInstance, card = n => document.querySelector('.sideview-card[data-card-name=\"' + n + '\"]');
    const saved = ['visits', 'labs'].map(n => ({ n, left: card(n).style.left, top: card(n).style.top }));
    card('visits').style.top = '600px';
    card('labs').style.left = (parseFloat(card('labs').style.left) + 150) + 'px';
    eng.updateConnectors();
    return saved;
  })()")
  on.exit(sv_js(b, sprintf("(() => { const s = %s;
    s.forEach(x => { const c = document.querySelector('.sideview-card[data-card-name=\"' + x.n + '\"]');
      c.style.left = x.left; c.style.top = x.top; });
    window._sideviewInstance.updateConnectors(); return true; })()", jsonlite::toJSON(saved, auto_unbox = TRUE))), add = TRUE)
  pts <- sv_js(b, "(() => {
    const path = document.querySelector('.sideview-connector-path:not(.sideview-connector-draft)');
    const m = path.getScreenCTM(), len = path.getTotalLength(), out = { card: [], canvas: [] };
    for (let i = 1; i < 60; i++) {
      const sp = path.getPointAtLength(len * i / 60), p = new DOMPoint(sp.x, sp.y).matrixTransform(m);
      const below = document.elementsFromPoint(p.x, p.y).find(el => !el.closest('svg'));
      if (!below) continue;
      const top = document.elementFromPoint(p.x, p.y);
      const pt = { x: p.x, y: p.y, top_in_card: !!top.closest('.sideview-card') };
      if (below.closest('.sideview-card')) {
        if (!below.closest('button, [data-action], .sideview-col-port, .sideview-col-resizer')) out.card.push(pt);
      } else if (below.closest('.sideview-canvas')) out.canvas.push(pt);
    }
    return out;
  })()")
  expect_gt(length(pts$card), 0)
  expect_true(all(vapply(pts$card, function(p) isTRUE(p$top_in_card), TRUE)))
  click(pts$card[[ceiling(length(pts$card) / 2)]])
  Sys.sleep(0.2)
  expect_equal(n_links(), 1)
  expect_gt(length(pts$canvas), 0)
  click(pts$canvas[[ceiling(length(pts$canvas) / 2)]])
  Sys.sleep(0.2)
  expect_equal(n_links(), 0)
  expect_equal(sv_js(b, "document.querySelectorAll('.sideview-connector-hit').length"), 0)
  # With nothing connected there is no code: the placeholder is display text only
  Sys.sleep(0.3)
  expect_identical(sv_js(b, "window._sideviewInstance.generatedCode"), "")
  sv_js(b, "(async () => { document.querySelector('[data-action=\"clear-operation\"]').click(); await new Promise(r => setTimeout(r, 300)); return true; })()")
})

test_that("connector endpoints sit on their ports after zoom and scroll", {
  b <- sv_shared_page()
  r <- sv_js(b, sprintf("(async () => {
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const pat = %s, labs = %s;
    const p1 = pat.querySelector('.sideview-col-port[data-col-name=\"patient_id\"]');
    const p2 = labs.querySelector('.sideview-col-port[data-col-name=\"patient_id\"]');
    const fire = el => { const x = el.getBoundingClientRect(); ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(t => el.dispatchEvent(new MouseEvent(t, {bubbles: true, button: 0, clientX: x.x + 2, clientY: x.y + 2}))); };
    fire(p1); await sleep(150); fire(p2); await sleep(300);
    document.querySelector('[data-action=\"zoom-in\"]').click(); await sleep(300);
    labs.querySelector('.sideview-card-body').scrollTop = 600; labs.querySelector('.sideview-card-body').dispatchEvent(new Event('scroll'));
    await sleep(300);
    const path = document.querySelector('.sideview-connector-path:not(.sideview-connector-draft)');
    const len = path.getTotalLength();
    const svg = path.ownerSVGElement; const m = path.getScreenCTM();
    const pt = p => { const q = svg.createSVGPoint(); q.x = p.x; q.y = p.y; return q.matrixTransform(m); };
    const a = pt(path.getPointAtLength(0)), z = pt(path.getPointAtLength(len));
    const c = el => { const x = el.getBoundingClientRect(); return { x: x.x + x.width / 2, y: x.y + x.height / 2 }; };
    const c1 = c(p1), c2 = c(p2);
    const d = (u, v) => Math.hypot(u.x - v.x, u.y - v.y);
    const out = { start: Math.min(d(a, c1), d(a, c2)), end: Math.min(d(z, c1), d(z, c2)) };
    document.querySelector('[data-action=\"zoom-reset\"]').click();
    document.querySelector('[data-action=\"clear-operation\"]').click(); await sleep(300);
    return out;
  })()", sv_card_js("patients"), sv_card_js("labs")))
  expect_lt(r$start, 6)
  expect_lt(r$end, 6)
})

test_that("maximized card fits inside the window", {
  b <- sv_shared_page()
  r <- sv_js(b, sprintf("(async () => {
    const c = %s; const btn = c.querySelector('[data-action=\"maximize-card\"]');
    btn.click(); await new Promise(r => setTimeout(r, 400));
    const x = c.getBoundingClientRect().toJSON();
    btn.click(); await new Promise(r => setTimeout(r, 300));
    return { r: x, vw: innerWidth, vh: innerHeight, after: c.getBoundingClientRect().width };
  })()", sv_card_js("patients")))
  expect_gte(r$r$left, 0)
  expect_gte(r$r$top, 0)
  expect_lte(r$r$right, r$vw + 1)
  expect_lte(r$r$bottom, r$vh + 1)
  expect_gt(r$r$width, r$vw * 0.6)
  expect_lt(r$after, 1000)
})

test_that("sort uses the full data, not just the HTML preview", {
  b <- sv_shared_page()
  r <- sv_js(b, sprintf("(async () => {
    const c = %s; c.querySelector('[data-action=\"sort-col\"][data-col-name=\"value\"]').click();
    await new Promise(r => setTimeout(r, 1500));
    const cells = [...c.querySelectorAll('tbody tr[data-row-index]')].slice(0, 3).map(r => r.cells[2].textContent.trim());
    c.querySelector('[data-action=\"sort-col\"][data-col-name=\"value\"]').click();
    c.querySelector('[data-action=\"sort-col\"][data-col-name=\"value\"]').click();
    await new Promise(r => setTimeout(r, 800));
    return cells;
  })()", sv_card_js("labs")))
  env <- new.env()
  eval(parse(text = sv_fixture_code), envir = env)
  expect_equal(as.numeric(unlist(r)), head(sort(env$labs$value), 3))
})

test_that("discrepancy summary reports numeric fuzzy counts", {
  b <- sv_shared_page()
  r <- sv_js(b, sprintf("(async () => {
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const fire = el => { const x = el.getBoundingClientRect(); ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(t => el.dispatchEvent(new MouseEvent(t, {bubbles: true, button: 0, clientX: x.x + 2, clientY: x.y + 2}))); };
    const vis = %s, pat = %s;
    fire(vis.querySelector('.sideview-col-port[data-col-name=\"pid\"]')); await sleep(150);
    fire(pat.querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(400);
    document.querySelector('[data-tab=\"discrepancy\"]').click(); await sleep(2000);
    const t = document.querySelector('.sideview-discrepancy-pane').innerText;
    document.querySelector('[data-action=\"clear-operation\"]').click(); await sleep(300);
    return t;
  })()", sv_card_js("visits"), sv_card_js("patients")))
  expect_false(grepl("undefined", r))
  expect_match(r, "[1-9][0-9]* fuzzy")
})

# --- Pipeline drawer (#15/#16) -------------------------------------------------

sv_pipeline_helpers_js <- "
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const sv = window._sideviewInstance;
  const q = s => document.querySelector(s);
  const fire = el => { const x = el.getBoundingClientRect(); ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(t => el.dispatchEvent(new MouseEvent(t, {bubbles: true, button: 0, clientX: x.x + 2, clientY: x.y + 2}))); };
  const setVal = (el, v) => { el.value = v; el.dispatchEvent(new Event('input', {bubbles: true})); el.dispatchEvent(new Event('change', {bubbles: true})); };
  const steps = () => document.querySelectorAll('.sideview-step-list li.sideview-step').length;
  const badge = () => (q('[data-action=\"toggle-drawer\"] .sideview-step-badge') || {}).textContent || '';
  const tab = name => { q('.sideview-drawer-tabs [data-tab=\"' + name + '\"]').click(); };
"

test_that("each drawer tab shows only its own pane and builders render forms", {
  b <- sv_shared_page()
  r <- sv_js(b, paste0("(async () => {", sv_pipeline_helpers_js, "
    const tabs = [...document.querySelectorAll('.sideview-drawer-tabs [data-tab]')].map(t => t.dataset.tab);
    const out = {};
    for (const t of tabs) {
      tab(t); await sleep(30);
      const shown = [...document.querySelectorAll('.sideview-drawer-content > .sideview-tab-pane')]
        .filter(p => getComputedStyle(p).display !== 'none').map(p => p.dataset.pane || p.className);
      const sel = q('.sideview-drawer-tabs [data-tab=\"' + t + '\"]').getAttribute('aria-selected');
      const form = !!q('.sideview-drawer-content > [data-pane=\"' + t + '\"] [data-builder-action=\"submit\"]');
      out[t] = { shown: shown, selected: sel, form: form };
    }
    tab('pipeline');
    return { tabs: tabs, panes: out };
  })()"))
  expect_setequal(unlist(r$tabs), c("pipeline", "filter", "arrange", "mutate", "recode",
                                    "summarise", "discrepancy", "chat"))
  for (t in unlist(r$tabs)) {
    p <- r$panes[[t]]
    expect_length(p$shown, 1)
    expect_match(p$shown[[1]], t, info = t)
    expect_identical(p$selected, "true", info = t)
    expect_identical(p$form, t %in% c("filter", "arrange", "mutate", "recode", "summarise"), info = t)
  }
})

test_that("header sort, header filter and a join compose into one runnable script", {
  b <- sv_shared_page()
  r <- sv_js(b, sprintf(paste0("(async () => {", sv_pipeline_helpers_js, "
    const pat = %s, labs = %s;
    const drawer = q('.sideview-drawer');
    const wasCollapsed = drawer.classList.contains('collapsed');
    labs.querySelector('[data-action=\"sort-col\"][data-col-name=\"value\"]').click(); await sleep(600);
    pat.querySelector('[data-action=\"filter-col\"][data-col-name=\"age\"]').click(); await sleep(200);
    const pop = q('.sideview-filter-popover');
    setVal(pop.querySelector('.sideview-filter-select'), 'gt');
    setVal(pop.querySelector('.sideview-filter-input'), '50');
    pop.querySelector('.sideview-filter-apply').click(); await sleep(600);
    fire(pat.querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(150);
    fire(labs.querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(500);
    const out = { code: sv.generatedCode, shown: q('.sideview-code-text').textContent, steps: steps(), badge: badge(),
                  collapsed: wasCollapsed && drawer.classList.contains('collapsed') };
    q('[data-action=\"pipeline-undo\"]').click(); await sleep(50);
    out.afterUndo = steps(); out.undoCode = sv.generatedCode;
    q('[data-action=\"pipeline-redo\"]').click(); await sleep(50);
    out.afterRedo = steps();
    const items = () => [...document.querySelectorAll('.sideview-step-list li.sideview-step')];
    const joinLi = items().find(li => li.querySelector('.sideview-step-jointype'));
    setVal(joinLi.querySelector('.sideview-step-jointype'), 'inner_join'); await sleep(50);
    out.inner = sv.generatedCode;
    const filterLi = items().find(li => /filter/i.test(li.textContent));
    const tog = filterLi.querySelector('.sideview-step-toggle');
    tog.checked = false; tog.dispatchEvent(new Event('change', {bubbles: true})); await sleep(50);
    out.toggled = sv.generatedCode;
    const off = q('.sideview-step-list li.is-disabled');
    out.disabledClass = !!off;
    off.querySelector('[data-step-action=\"delete\"]').click(); await sleep(50);
    out.afterDelete = steps();
    q('[data-action=\"clear-operation\"]').click(); await sleep(300);
    out.cleared = steps(); out.clearedBadge = badge();
    return out;
  })()"), sv_card_js("patients"), sv_card_js("labs")))

  expect_true(r$collapsed)            # the drawer no longer pops open on every step
  expect_equal(r$steps, 3)
  expect_identical(r$badge, "3")
  expect_identical(r$shown, r$code)
  expect_match(r$code, "labs_prep <- labs %>%\n  dplyr::arrange(value)", fixed = TRUE)
  expect_match(r$code, "dplyr::filter(age > 50)", fixed = TRUE)
  expect_match(r$code, 'dplyr::left_join(labs_prep, by = "patient_id")', fixed = TRUE)

  env <- new.env()
  eval(parse(text = sv_fixture_code), envir = env)
  env$`%>%` <- dplyr::`%>%`
  got <- eval(parse(text = r$code), envir = env)
  want <- dplyr::left_join(dplyr::filter(env$patients, age > 50),
                           dplyr::arrange(env$labs, value), by = "patient_id")
  expect_equal(as.data.frame(got), as.data.frame(want))

  expect_equal(r$afterUndo, 2)
  expect_false(grepl("join", r$undoCode))
  expect_equal(r$afterRedo, 3)
  expect_match(r$inner, "dplyr::inner_join(", fixed = TRUE)
  expect_false(grepl("filter", r$toggled))
  expect_true(r$disabledClass)
  expect_equal(r$afterDelete, 2)
  expect_equal(r$cleared, 0)
  expect_identical(r$clearedBadge, "")
})

test_that("builder tabs add steps, reject empty input, and Ctrl+Z undoes", {
  b <- sv_shared_page()
  r <- sv_js(b, paste0("(async () => {", sv_pipeline_helpers_js, "
    const root = q('.sideview-container');
    const pick = async kind => {
      tab(kind); await sleep(50);
      setVal(q('[data-pane=\"' + kind + '\"] [data-field=\"table\"]'), 'patients'); await sleep(30);
      return q('[data-pane=\"' + kind + '\"]');
    };
    let pane = await pick('mutate');
    pane.querySelector('[data-builder-action=\"submit\"]').click(); await sleep(50);
    const emptyRejected = steps() === 0;
    setVal(pane.querySelector('[data-field=\"name\"]'), 'decade');
    setVal(pane.querySelector('[data-field=\"expr\"]'), 'age %/% 10');
    pane.querySelector('[data-builder-action=\"submit\"]').click(); await sleep(50);
    const afterMutate = { steps: steps(), code: sv.generatedCode,
      active: q('.sideview-drawer-tabs [data-tab=\"pipeline\"]').getAttribute('aria-selected') };

    pane = await pick('recode');
    setVal(pane.querySelector('[data-field=\"col\"]'), 'sex');
    setVal(pane.querySelector('[data-field=\"map\"]'), 'male = Male\\nF = Female\\nNA = Unknown');
    pane.querySelector('[data-builder-action=\"submit\"]').click(); await sleep(50);

    pane = await pick('summarise');
    const g = pane.querySelector('[data-field=\"groups\"]');
    [...g.options].forEach(o => { o.selected = o.value === 'sex'; });
    setVal(pane.querySelector('.sideview-builder-row [data-field=\"fn\"]'), 'mean');
    setVal(pane.querySelector('.sideview-builder-row [data-field=\"col\"]'), 'age');
    pane.querySelector('[data-builder-action=\"submit\"]').click(); await sleep(50);
    const full = sv.generatedCode;

    root.dispatchEvent(new MouseEvent('mousedown', {bubbles: true}));
    document.dispatchEvent(new KeyboardEvent('keydown', {key: 'z', ctrlKey: true, bubbles: true})); await sleep(50);
    const undone = steps();
    document.dispatchEvent(new KeyboardEvent('keydown', {key: 'y', ctrlKey: true, bubbles: true})); await sleep(50);
    const redone = steps();
    q('[data-action=\"clear-operation\"]').click(); await sleep(300);
    return { emptyRejected: emptyRejected, afterMutate: afterMutate, full: full, undone: undone, redone: redone };
  })()"))
  expect_true(r$emptyRejected)
  expect_equal(r$afterMutate$steps, 1)
  expect_identical(r$afterMutate$active, "true")
  expect_match(r$afterMutate$code, "dplyr::mutate(decade = age %/% 10)", fixed = TRUE)
  expect_match(r$full, "dplyr::case_when(", fixed = TRUE)
  expect_match(r$full, "dplyr::group_by(sex)", fixed = TRUE)
  expect_equal(r$undone, 2)
  expect_equal(r$redone, 3)

  env <- new.env()
  eval(parse(text = sv_fixture_code), envir = env)
  env$`%>%` <- dplyr::`%>%`
  got <- NULL
  expect_silent(got <- eval(parse(text = r$full), envir = env))
  expect_setequal(got$sex, c("Male", "Female", "Unknown"))
  expect_named(got, c("sex", "mean_age"))
})

test_that("narrow bottom-sheet drawer keeps undo/redo still as steps change", {
  b <- sv_shared_page()
  sv_set_viewport(b, 560, 700)
  r <- sv_js(b, paste0("(async () => {", sv_pipeline_helpers_js, "
    const d = q('.sideview-drawer');
    if (d.classList.contains('collapsed')) q('[data-action=\"toggle-drawer\"]').click();
    await sleep(400); tab('pipeline'); await sleep(50);
    const top = () => q('[data-action=\"pipeline-undo\"]').getBoundingClientRect().top;
    const before = top();
    sv.pipeline.add({kind: 'mutate', table: 'patients', name: 'a', expr: '1'});
    sv.pipeline.add({kind: 'mutate', table: 'patients', name: 'b', expr: '2'});
    sv.pipeline.add({kind: 'mutate', table: 'patients', name: 'c', expr: '3'});
    await sleep(50);
    const after = top();
    const narrow = q('.sideview-container').classList.contains('sv-narrow');
    q('[data-action=\"clear-operation\"]').click(); await sleep(300);
    q('[data-action=\"toggle-drawer\"]').click(); await sleep(300);
    return { before: before, after: after, narrow: narrow };
  })()"))
  sv_set_viewport(b, 1400, 900)
  expect_true(r$narrow)
  expect_lt(abs(r$after - r$before), 1)
})

sv_key_js <- "
  const key = (k, opts, el) => (el || document).dispatchEvent(new KeyboardEvent('keydown',
    Object.assign({key: k, bubbles: true, cancelable: true}, opts || {})));
"

test_that("theme toggle swaps to dark tokens and T flips it back", {
  b <- sv_shared_page()
  r <- sv_js(b, paste0("(async () => {", sv_pipeline_helpers_js, sv_key_js, "
    const root = q('.sideview-container');
    const tok = n => getComputedStyle(root).getPropertyValue(n).trim();
    const cardBg = () => getComputedStyle(q('.sideview-card')).backgroundColor;
    const btn = q('[data-action=\"toggle-theme\"]');
    const start = { cls: root.className, attr: root.getAttribute('data-sv-theme'),
                    canvas: tok('--sv-canvas-bg'), card: cardBg(), label: btn.getAttribute('aria-label') };
    btn.click(); await sleep(50);
    const dark = { dark: root.classList.contains('sv-theme-dark'), canvas: tok('--sv-canvas-bg'),
                   card: cardBg(), label: btn.getAttribute('aria-label'),
                   scheme: getComputedStyle(root).colorScheme };
    document.activeElement && document.activeElement.blur();
    key('t'); await sleep(50);
    const back = { light: root.classList.contains('sv-theme-light'), canvas: tok('--sv-canvas-bg') };
    sv.applyTheme('auto');
    return { start: start, dark: dark, back: back, auto: root.classList.contains('sv-theme-auto') };
  })()"))
  expect_match(r$start$cls, "sv-theme-auto", fixed = TRUE)
  expect_identical(r$start$attr, "auto")
  expect_identical(r$start$canvas, "#f8fafc")
  expect_identical(r$start$card, "rgb(255, 255, 255)")
  expect_true(r$dark$dark)
  expect_identical(r$dark$canvas, "#0b1220")
  expect_identical(r$dark$card, "rgb(23, 32, 51)")
  expect_identical(r$dark$scheme, "dark")
  expect_false(identical(r$start$label, r$dark$label))
  expect_true(r$back$light)
  expect_identical(r$back$canvas, "#f8fafc")
  expect_true(r$auto)
})

test_that("single-key shortcuts drive zoom, fit and drawer but not while typing", {
  b <- sv_shared_page()
  r <- sv_js(b, paste0("(async () => {", sv_pipeline_helpers_js, sv_key_js, "
    const pz = sv.panzoom; const s = () => Math.round(pz.getScale() * 1000) / 1000;
    const drawer = q('.sideview-drawer'); const collapsed = () => drawer.classList.contains('collapsed');
    document.activeElement && document.activeElement.blur();
    key('0'); await sleep(30); const reset = s();
    key('+'); await sleep(30); const zin = s();
    key('-'); await sleep(30); const zout = s();
    key('0', {ctrlKey: true}); key('+', {ctrlKey: true}); await sleep(30); const ctrlIgnored = s();
    const d0 = collapsed(); key('d'); await sleep(30); const d1 = collapsed(); key('d'); await sleep(30);
    key('f'); await sleep(60);
    const c = q('.sideview-container').getBoundingClientRect();
    const inView = [...document.querySelectorAll('.sideview-card')].every(e => {
      const r = e.getBoundingClientRect();
      return r.left >= c.left - 1 && r.right <= c.right + 1 && r.top >= c.top - 1 && r.bottom <= c.bottom + 1; });
    key('0'); await sleep(30);
    const ai = q('.sideview-ai-input');
    key('/'); await sleep(30); const slashFocus = document.activeElement === ai;
    key('+', {}, ai); key('d', {}, ai); await sleep(30);
    const typing = { scale: s(), drawer: collapsed() };
    ai.blur();
    sv.options.mode = 'embedded'; key('+'); await sleep(30); const embedded = s(); sv.options.mode = 'standalone';
    return { reset: reset, zin: zin, zout: zout, ctrlIgnored: ctrlIgnored, d0: d0, d1: d1, inView: inView,
             slashFocus: slashFocus, typing: typing, embedded: embedded, d2: collapsed() };
  })()"))
  expect_equal(r$reset, 1)
  expect_equal(r$zin, 1.25)
  expect_equal(r$zout, 1)
  expect_equal(r$ctrlIgnored, 1)
  expect_false(identical(r$d0, r$d1))
  expect_identical(r$d2, r$d0)
  expect_true(r$inView)
  expect_true(r$slashFocus)
  expect_equal(r$typing$scale, 1)
  expect_identical(r$typing$drawer, r$d0)
  expect_equal(r$embedded, 1)
})

test_that("? opens an accessible shortcut list that Esc and the scrim close", {
  b <- sv_shared_page()
  r <- sv_js(b, paste0("(async () => {", sv_pipeline_helpers_js, sv_key_js, "
    document.activeElement && document.activeElement.blur();
    key('?'); await sleep(30);
    const dlg = q('.sideview-shortcuts');
    const open = { role: dlg && dlg.getAttribute('role'), modal: dlg && dlg.getAttribute('aria-modal'),
      title: dlg && document.getElementById(dlg.getAttribute('aria-labelledby')).textContent,
      focused: document.activeElement === dlg, rows: dlg ? dlg.querySelectorAll('dt').length : 0 };
    const scale = sv.panzoom.getScale(); key('+'); await sleep(30);
    const blocked = sv.panzoom.getScale() === scale;
    key('Escape'); await sleep(30); const escClosed = !q('.sideview-shortcuts-scrim');
    q('[data-action=\"show-shortcuts\"]').click(); await sleep(30);
    const viaButton = !!q('.sideview-shortcuts-scrim');
    q('.sideview-shortcuts-scrim').click(); await sleep(30);
    return { open: open, blocked: blocked, escClosed: escClosed, viaButton: viaButton,
             scrimClosed: !q('.sideview-shortcuts-scrim') };
  })()"))
  expect_identical(r$open$role, "dialog")
  expect_identical(r$open$modal, "true")
  expect_identical(r$open$title, "Keyboard shortcuts")
  expect_true(r$open$focused)
  expect_gte(r$open$rows, 8)
  expect_true(r$blocked)
  expect_true(r$escClosed)
  expect_true(r$viaButton)
  expect_true(r$scrimClosed)
})

test_that("swatches are buttons with pressed state and controls show a focus ring", {
  b <- sv_shared_page()
  r <- sv_js(b, paste0("(async () => {", sv_pipeline_helpers_js, "
    const sw = [...document.querySelectorAll('.sideview-palette .sideview-swatch')];
    const tags = [...new Set(sw.map(e => e.tagName))];
    const named = sw.every(e => (e.getAttribute('aria-label') || '').length > 0);
    q('.sideview-swatch-green').click(); await sleep(30);
    const pressed = sw.filter(e => e.getAttribute('aria-pressed') === 'true').map(e => e.dataset.color);
    q('.sideview-swatch-clear').click(); await sleep(30);
    const unnamed = [...document.querySelectorAll('.sideview-container button')]
      .filter(e => e.offsetParent && !(e.getAttribute('aria-label') || e.textContent.trim() || e.title))
      .map(e => e.className);
    return { tags: tags, named: named, pressed: pressed, unnamed: unnamed,
             palette: q('.sideview-palette').getAttribute('role') };
  })()"))
  expect_identical(unlist(r$tags), "BUTTON")
  expect_true(r$named)
  expect_identical(unlist(r$pressed), "green")
  expect_length(r$unnamed, 0)
  expect_identical(r$palette, "group")

  # :focus-visible applies to keyboard focus, so Tab onto a toolbar button.
  sv_js(b, "(() => { document.activeElement && document.activeElement.blur();
    document.querySelector('[data-action=\"zoom-in\"]').focus(); return true; })()")
  b$Input$dispatchKeyEvent(type = "keyDown", key = "Tab", code = "Tab", windowsVirtualKeyCode = 9)
  b$Input$dispatchKeyEvent(type = "keyUp", key = "Tab", code = "Tab", windowsVirtualKeyCode = 9)
  Sys.sleep(0.4) # .sideview-btn transitions all properties, the outline included
  ring <- sv_js(b, "(() => { const e = document.activeElement; const s = getComputedStyle(e);
    return { tag: e.tagName, style: s.outlineStyle, width: s.outlineWidth }; })()")
  expect_identical(ring$tag, "BUTTON")
  expect_identical(ring$style, "solid")
  expect_identical(ring$width, "2px")
  sv_js(b, "(() => { document.activeElement && document.activeElement.blur(); return true; })()")
})

test_that("Ctrl+Enter in a builder adds the step", {
  b <- sv_shared_page()
  r <- sv_js(b, paste0("(async () => {", sv_pipeline_helpers_js, sv_key_js, "
    tab('mutate'); await sleep(50);
    const pane = q('[data-pane=\"mutate\"]');
    setVal(pane.querySelector('[data-field=\"table\"]'), 'patients'); await sleep(30);
    setVal(pane.querySelector('[data-field=\"name\"]'), 'k');
    const expr = pane.querySelector('[data-field=\"expr\"]');
    setVal(expr, 'age * 2'); expr.focus();
    const before = steps();
    key('Enter', {ctrlKey: true}, expr); await sleep(60);
    const after = steps();
    q('[data-action=\"clear-operation\"]').click(); await sleep(300);
    tab('pipeline'); expr.blur();
    return { before: before, after: after };
  })()"))
  expect_equal(r$after, r$before + 1)
})
