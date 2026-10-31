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
                                    "summarise", "inspect", "discrepancy", "chat"))
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

test_that("a join step keeps its label and buttons on one line, its options on the next, and the key check below", {
  b <- sv_shared_page()
  on.exit(sv_set_viewport(b, 1400, 900), add = TRUE)
  for (w in c(1400, 1000)) {
    sv_set_viewport(b, w, 800)
    r <- sv_js(b, sprintf(paste0("(async () => {", sv_pipeline_helpers_js, "
      const pat = %s, vis = %s;
      const until = async (f, ms) => { for (let t = 0; t < ms; t += 50) { if (f()) return true; await sleep(50); } return false; };
      q('[data-action=\"clear-operation\"]').click(); await sleep(300);
      fire(pat.querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(150);
      fire(vis.querySelector('.sideview-col-port[data-col-name=\"pid\"]')); await sleep(100);
      await until(() => q('.sideview-step-diag:not(.is-pending)'), 8000);
      tab('pipeline'); await sleep(100);
      const li = q('.sideview-step.has-diag');
      const top = el => el.getBoundingClientRect().top;
      const out = {
        drawer: q('.sideview-drawer').getBoundingClientRect().width,
        toggle: top(li.querySelector('.sideview-step-toggle')),
        del: top(li.querySelector('[data-step-action=\"delete\"]')),
        select: top(li.querySelector('.sideview-step-jointype')),
        rule: top(li.querySelector('.sideview-step-rule')),
        strict: top(li.querySelector('.sideview-step-strict-label')),
        diag: top(li.querySelector('.sideview-step-diag')),
        textW: li.querySelector('.sideview-step-text').getBoundingClientRect().width,
        overflow: li.scrollWidth - li.clientWidth
      };
      q('[data-action=\"clear-operation\"]').click(); await sleep(300);
      return out;
    })()"), sv_card_js("patients"), sv_card_js("visits")))
    info <- sprintf("window %d, drawer %.0fpx", w, r$drawer)
    expect_lt(abs(r$del - r$toggle), 8, label = info)      # delete sits on the first line
    expect_gt(r$select, r$toggle + 8, label = info)        # the options sit on their own line
    expect_lt(abs(r$rule - r$select), 8, label = info)    # the rule button and Strict share it
    expect_lt(abs(r$strict - r$select), 8, label = info)
    expect_gt(r$diag, r$toggle + 8, label = info)          # the key check wraps below
    expect_gt(r$textW, 20, label = info)                   # the label still shows something
    expect_lte(r$overflow, 1, label = info)
  }
})

test_that("a copilot reply keeps prose after the code below the code", {
  b <- sv_shared_page()
  r <- sv_js(b, paste0("(async () => {", sv_pipeline_helpers_js, "
    const box = q('.sideview-chat-messages');
    const n0 = box.children.length;
    const send = (text, code) => Shiny.shinyapp.dispatchMessage(JSON.stringify(
      { custom: { sideview_copilot_reply: { text: text, code: code } } }));
    const parts = () => [...box.lastElementChild.children].map(e =>
      e.classList.contains('sideview-chat-code') ? 'CODE' :
      e.classList.contains('sideview-chat-code-actions') ? 'BUTTONS' : e.textContent);
    send('Join them first.\\n\\n```r\\nx |> f()\\n```\\n\\nThen check the counts.', 'x |> f()');
    await sleep(100);
    const out = { both: parts() };
    send('```r\\ny\\n```', 'y'); await sleep(100); out.codeOnly = parts();
    send('No code needed here.', ''); await sleep(100); out.prose = parts();
    out.added = box.children.length - n0;
    while (box.children.length > n0) box.lastElementChild.remove();
    return out;
  })()"))
  expect_identical(unlist(r$both), c("Join them first.", "CODE", "BUTTONS", "Then check the counts."))
  expect_identical(unlist(r$codeOnly), c("Here is the requested tidyverse transformation:", "CODE", "BUTTONS"))
  expect_identical(unlist(r$prose), "No code needed here.")
  expect_equal(r$added, 3)
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

test_that("a new join shows R's key check, and the Discrepancy tab explains it", {
  b <- sv_shared_page()
  env <- new.env()
  eval(parse(text = sv_fixture_code), envir = env)
  want <- sv_join_diagnostics(env$patients, env$visits, c(patient_id = "pid"))
  mm <- sv_join_diagnostics(env$visits, env$labs, c(pid = "patient_id"), x_name = "visits", y_name = "labs")

  r <- sv_js(b, sprintf(paste0("(async () => {", sv_pipeline_helpers_js, "
    const pat = %s, vis = %s, labs = %s;
    const until = async (f, ms) => { for (let t = 0; t < ms; t += 50) { if (f()) return true; await sleep(50); } return false; };
    q('[data-action=\"clear-operation\"]').click(); await sleep(300);
    document.querySelectorAll('.sideview-toast').forEach(t => t.remove());
    fire(pat.querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(150);
    fire(vis.querySelector('.sideview-col-port[data-col-name=\"pid\"]')); await sleep(100);
    const out = {};
    out.resolved = await until(() => q('.sideview-step-diag.is-ok, .sideview-step-diag.is-warn, .sideview-step-diag.is-error'), 8000);
    const diag = q('.sideview-step-diag');
    out.diagClass = diag.className; out.diagText = diag.textContent;
    out.toastsAfterOk = document.querySelectorAll('.sideview-toast-warning, .sideview-toast-danger').length;
    diag.click(); await sleep(200);
    out.tab = (q('.sideview-drawer-tabs [aria-selected=\"true\"]') || {}).dataset.tab;
    const box = q('.sideview-joincheck');
    out.boxVisible = box.offsetParent !== null && box.getBoundingClientRect().height > 40;
    out.title = box.querySelector('.sideview-joincheck-title').textContent;
    out.rows = Object.fromEntries([...box.querySelectorAll('.sideview-joincheck-rows tbody tr')]
      .map(tr => [tr.cells[0].textContent, tr.cells[1].textContent]));
    out.current = (box.querySelector('tr.is-current td') || {}).textContent;
    out.text = box.textContent;
    fire(vis.querySelector('.sideview-col-port[data-col-name=\"pid\"]')); await sleep(150);
    fire(labs.querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(100);
    out.mmResolved = await until(() => document.querySelectorAll('.sideview-step-diag.is-warn').length > 0, 8000);
    out.toasts = [...document.querySelectorAll('.sideview-toast')].map(t => ({ text: t.textContent, cls: t.className }));
    out.mmBox = q('.sideview-joincheck').className;
    out.mmWarn = (q('.sideview-joincheck-warnings li') || {}).textContent;
    const bw = q('.sideview-drawer').getBoundingClientRect(), jb = q('.sideview-joincheck').getBoundingClientRect();
    out.fits = jb.left >= bw.left - 1 && jb.right <= bw.right + 1;
    q('[data-action=\"clear-operation\"]').click(); await sleep(300);
    tab('pipeline');
    return out;
  })()"), sv_card_js("patients"), sv_card_js("visits"), sv_card_js("labs")))

  expect_true(r$resolved)
  expect_match(r$diagClass, paste0("is-", want$status))
  expect_match(r$diagText, "1:m", fixed = TRUE)
  expect_match(r$diagText, sprintf("%.0f%% of patients matched", 100 * want$match_rate_x), fixed = TRUE)
  expect_equal(r$toastsAfterOk, if (want$status == "ok") 0 else 1)
  expect_identical(r$tab, "discrepancy")
  expect_true(r$boxVisible)
  expect_match(r$title, "Join check: patients → visits by patient_id = pid", fixed = TRUE)
  fmt <- function(n) formatC(n, big.mark = ",", format = "d")
  expect_identical(unlist(r$rows), vapply(want$rows, function(n) fmt(n), character(1)))
  expect_identical(r$current, "left_join")
  # The fixture's " P00001" and "p00002" are the kind of near-miss keys the hints catch.
  expect_match(r$text, "Not in patients:", fixed = TRUE)
  expect_match(r$text, "trimming whitespace would match 6 more visits rows.", fixed = TRUE)
  expect_false(grepl("would match 0 ", r$text, fixed = TRUE))
  expect_match(r$text, "ignoring case would match", fixed = TRUE)

  expect_identical(mm$relationship, "many-to-many")
  expect_true(r$mmResolved)
  toast <- Filter(function(t) grepl("visits → labs", t$text, fixed = TRUE), r$toasts)
  expect_length(toast, 1)
  expect_match(toast[[1]]$cls, "sideview-toast-warning")
  expect_match(toast[[1]]$text, "Many-to-many", fixed = TRUE)
  expect_match(r$mmBox, "is-warn")
  expect_identical(r$mmWarn, mm$warnings[1])
  expect_true(r$fits)
})

test_that("the saved widget checks join keys in the browser without R", {
  skip_if_no_browser()
  env <- new.env()
  eval(parse(text = sv_fixture_code), envir = env)
  dir <- withr::local_tempdir()
  file <- file.path(dir, "joins.html")
  w <- local(sideview_widget(patients, visits), envir = env)
  suppressMessages(save_sideview(w, file, selfcontained = FALSE))
  url <- paste0("file:///", gsub("\\\\", "/", normalizePath(file)))
  b <- sv_open_page(url, wait_for = "!!document.querySelector('.sideview-card .sideview-col-port')")
  withr::defer(try(b$close(), silent = TRUE))
  expect_true(attr(b, "sv_ready"))
  want <- sv_join_diagnostics(env$patients, env$visits, c(patient_id = "pid"))

  r <- sv_js(b, sprintf(paste0("(async () => {", sv_pipeline_helpers_js, "
    const eng = document.querySelector('.sideview-container')._sideviewInstance;
    const pat = %s, vis = %s;
    fire(pat.querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(150);
    fire(vis.querySelector('.sideview-col-port[data-col-name=\"pid\"]')); await sleep(300);
    const s = eng.pipeline.steps.filter(x => x.kind === 'join')[0];
    const d = s && eng.joinDiag[eng.joinDiagSig(s)];
    const diag = q('.sideview-step-diag');
    return { mode: eng.options.mode, steps: eng.pipeline.steps.length, d: d || null,
             diag: diag ? diag.textContent : null };
  })()"), sv_card_js("patients"), sv_card_js("visits")))

  expect_identical(r$mode, "embedded")
  expect_equal(r$steps, 1)
  for (f in c("n_x", "n_y", "matched_x", "matched_y", "distinct_matched", "dup_keys_y")) {
    expect_equal(r$d[[f]], want[[f]], info = f)
  }
  expect_identical(r$d$relationship, want$relationship)
  expect_equal(unlist(r$d$rows), unlist(want$rows))
  expect_match(r$diag, "1:m", fixed = TRUE)
  # a column that is not in a table reads as it does in the gadget: Not in <table>: <col>
  miss <- sv_js(b, "(() => {
    const eng = document.querySelector('.sideview-container')._sideviewInstance;
    return {
      key: eng.localJoinDiagnostics({ left: 'patients', right: 'visits', by: [{ left: 'patient_id', right: 'nope' }] }).error,
      rule: eng.localJoinDiagnostics({ left: 'patients', right: 'visits', by: [{ left: 'patient_id', right: 'pid' }],
        rule: { shape: 'before', xCol: 'patient_id', yCol: 'nope', inclusive: true } }).error
    };
  })()")
  expect_identical(miss$key, "Not in visits: nope")
  expect_identical(miss$rule, "Not in visits: nope")
  expect_length(attr(b, "sv_errors")(), 0)
})

test_that("the header inspect button profiles the full column in R", {
  b <- sv_shared_page()
  env <- new.env()
  eval(parse(text = sv_fixture_code), envir = env)
  want <- sv_column_profile(env$labs$value)
  want_test <- sv_column_profile(env$labs$test)
  want_sex <- sv_column_profile(env$patients$sex)

  # A real click on the button, so overlays and the header's own handlers are exercised.
  p <- sv_js(b, sprintf("(() => {
    const card = %s;
    const btn = card.querySelector('th[data-col-name=\"value\"] [data-action=\"inspect-col\"]');
    btn.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    const r = btn.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width,
             hit: document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2) === btn ||
                  btn.contains(document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2)) };
  })()", sv_card_js("labs")))
  expect_gt(p$w, 8)
  expect_true(p$hit)
  steps_before <- sv_js(b, "window._sideviewInstance.pipeline.steps.length")
  for (type in c("mouseMoved", "mousePressed", "mouseReleased")) {
    b$Input$dispatchMouseEvent(type = type, x = p$x, y = p$y, button = "left",
                               clickCount = if (type == "mouseMoved") 0 else 1)
  }

  r <- sv_js(b, paste0("(async () => {", sv_pipeline_helpers_js, "
    const until = async (f, ms) => { for (let t = 0; t < ms; t += 50) { if (f()) return true; await sleep(50); } return false; };
    const out = {};
    out.open = !q('.sideview-drawer').classList.contains('collapsed');
    out.tab = (q('.sideview-drawer-tabs [aria-selected=\"true\"]') || {}).dataset.tab;
    out.resolved = await until(() => q('.sideview-inspect-stats'), 8000);
    const pane = q('[data-pane=\"inspect\"]');
    out.stats = Object.fromEntries([...pane.querySelectorAll('.sideview-inspect-stats > div')]
      .map(d => [d.querySelector('dt').textContent, d.querySelector('dd').textContent]));
    out.prof = sv.colProfiles[JSON.stringify(['labs', 'value'])];
    out.bars = pane.querySelectorAll('.sideview-inspect-bar').length;
    out.drafting = !!document.querySelector('.sideview-connector-draft[d]:not([d=\"\"])');
    out.steps = sv.pipeline.steps.length;
    out.overflow = pane.scrollWidth - pane.clientWidth;
    const bw = q('.sideview-drawer').getBoundingClientRect(), ib = q('.sideview-inspect-body').getBoundingClientRect();
    out.fits = ib.left >= bw.left - 1 && ib.right <= bw.right + 1;
    setVal(pane.querySelector('[data-inspect=\"column\"]'), 'test');
    out.testResolved = await until(() => q('[data-pane=\"inspect\"] .sideview-inspect-top'), 8000);
    out.top = [...q('[data-pane=\"inspect\"]').querySelectorAll('.sideview-inspect-top li')].map(li => ({
      value: li.querySelector('.sideview-inspect-value').textContent,
      n: li.querySelector('.sideview-inspect-n').textContent }));
    setVal(q('[data-pane=\"inspect\"] [data-inspect=\"table\"]'), 'patients');
    await sleep(50);
    setVal(q('[data-pane=\"inspect\"] [data-inspect=\"column\"]'), 'sex');
    out.sexResolved = await until(() => q('[data-pane=\"inspect\"] .sideview-inspect-issues'), 8000);
    out.issues = [...q('[data-pane=\"inspect\"]').querySelectorAll('.sideview-inspect-issues li')].map(li => li.textContent);
    out.exportBtn = !!q('[data-pane=\"inspect\"] [data-action=\"export-codebook\"]');
    tab('pipeline');
    return out;
  })()"))

  expect_true(r$open)
  expect_identical(r$tab, "inspect")
  expect_true(r$resolved)
  expect_identical(r$stats$Rows, "5,000")                 # the full table, not the 500-row preview
  expect_equal(r$prof$n, 5000)
  expect_equal(r$prof$stats$median, want$stats$median)
  expect_equal(r$prof$stats$q3, want$stats$q3)
  # Display rounds to about 4 significant digits; the profile keeps full precision.
  expect_match(r$stats$Mean, "^[0-9,]+\\.[0-9]{1,3}$")
  expect_equal(as.numeric(gsub(",", "", r$stats$Mean)), want$stats$mean, tolerance = 1e-3)
  expect_equal(unlist(r$prof$histogram$counts), want$histogram$counts)
  expect_equal(r$bars, 20)
  expect_false(r$drafting)                              # the click did not start a connection
  expect_equal(r$steps, steps_before)
  expect_lte(r$overflow, 1)
  expect_true(r$fits)
  expect_true(r$testResolved)
  expect_identical(vapply(r$top, `[[`, "", "value"), want_test$top$value)
  expect_identical(sub(" .*", "", vapply(r$top, `[[`, "", "n")), formatC(want_test$top$n, big.mark = ",", format = "d"))
  expect_true(r$sexResolved)
  expect_identical(unlist(r$issues), want_sex$issues)
  expect_true(r$exportBtn)
})

test_that("the saved widget inspects columns and exports the codebook without R", {
  skip_if_no_browser()
  env <- new.env()
  eval(parse(text = sv_fixture_code), envir = env)
  attr(env$patients$age, "label") <- "Age at enrolment (years)"
  dir <- withr::local_tempdir()
  file <- file.path(dir, "inspect.html")
  w <- local(sideview_widget(patients, visits), envir = env)
  suppressMessages(save_sideview(w, file, selfcontained = FALSE))
  url <- paste0("file:///", gsub("\\\\", "/", normalizePath(file)))
  b <- sv_open_page(url, wait_for = "!!document.querySelector('.sideview-card .sideview-col-port')")
  withr::defer(try(b$close(), silent = TRUE))
  expect_true(attr(b, "sv_ready"))
  want <- sv_column_profile(env$patients$age)
  cb <- sv_codebook(list(patients = env$patients, visits = env$visits))
  f <- tempfile(fileext = ".csv")
  utils::write.csv(cb, f, row.names = FALSE, na = "")
  want_csv <- paste0(paste(readLines(f), collapse = "\n"), "\n")

  r <- sv_js(b, sprintf(paste0("(async () => {", sv_pipeline_helpers_js, "
    const eng = document.querySelector('.sideview-container')._sideviewInstance;
    const pat = %s;
    pat.querySelector('th[data-col-name=\"age\"] [data-action=\"inspect-col\"]').click();
    await sleep(100);
    const pane = q('[data-pane=\"inspect\"]');
    const out = { prof: eng.colProfiles[JSON.stringify(['patients', 'age'])] || null,
                  label: (pane.querySelector('.sideview-inspect-label') || {}).textContent || null,
                  bars: pane.querySelectorAll('.sideview-inspect-bar').length };
    pane.querySelector('[data-action=\"export-codebook\"]').click();
    await sleep(100);
    out.csv = eng.lastCodebookCsv || null;
    out.toast = [...document.querySelectorAll('.sideview-toast')].map(t => t.textContent).join(' | ');
    return out;
  })()"), sv_card_js("patients")))

  expect_equal(r$prof$n, 200)
  expect_equal(r$prof$stats$median, want$stats$median)
  expect_equal(r$prof$stats$sd, want$stats$sd)
  expect_identical(unlist(r$prof$issues) %||% character(0), want$issues)
  expect_identical(r$label, "Age at enrolment (years)")
  expect_equal(r$bars, 20)
  expect_identical(r$csv, want_csv)
  expect_match(r$toast, "Codebook downloaded (7 columns)", fixed = TRUE)
  expect_length(attr(b, "sv_errors")(), 0)
})

test_that("the saved widget hides the buttons that need R and never claims they ran", {
  skip_if_no_browser()
  env <- new.env()
  eval(parse(text = sv_fixture_code), envir = env)
  dir <- withr::local_tempdir()
  file <- file.path(dir, "ronly.html")
  w <- local(sideview_widget(patients, visits), envir = env)
  suppressMessages(save_sideview(w, file, selfcontained = FALSE))
  url <- paste0("file:///", gsub("\\\\", "/", normalizePath(file)))
  b <- sv_open_page(url, wait_for = "!!document.querySelector('.sideview-card .sideview-col-port')")
  withr::defer(try(b$close(), silent = TRUE))
  r <- sv_js(b, paste0("(async () => {", sv_pipeline_helpers_js, "
    const eng = document.querySelector('.sideview-container')._sideviewInstance;
    eng.activateDrawerTab('pipeline');
    q('.sideview-drawer').classList.remove('collapsed');
    await sleep(50);
    const shown = a => { const el = q('.sideview-drawer-actions [data-action=\"' + a + '\"]');
                         return !!el && getComputedStyle(el).display !== 'none' && el.offsetWidth > 0; };
    const acts = ['inject-script', 'send-console-exit', 'eval-env', 'send-console', 'copy-code', 'clear-operation'];
    const out = {}; acts.forEach(a => out[a] = shown(a));
    eng.generatedCode = 'patients';
    q('.sideview-drawer-actions [data-action=\"inject-script\"]').click();
    await sleep(50);
    out.toast = [...document.querySelectorAll('.sideview-toast')].map(t => t.textContent).join(' | ');
    return out;
  })()"))
  expect_false(r[["inject-script"]])
  expect_false(r[["send-console-exit"]])
  expect_false(r[["eval-env"]])
  expect_false(r[["send-console"]])
  expect_true(r[["copy-code"]])
  expect_true(r[["clear-operation"]])
  expect_no_match(r$toast, "inserted", fixed = TRUE)
  expect_match(r$toast, "needs the R session", fixed = TRUE)
  expect_length(attr(b, "sv_errors")(), 0)

  g <- sv_shared_page()
  vis <- sv_js(g, "(() => [...document.querySelectorAll('.sideview-drawer-actions [data-r-only]')].map(e => e.dataset.action))()")
  expect_setequal(unlist(vis), c("inject-script", "send-console-exit", "eval-env", "send-console"))
  expect_false(sv_js(g, "document.querySelector('.sideview-container').classList.contains('sv-embedded')"))
})

# --- Workspace save / open (#18) -----------------------------------------------

# JS: build a workspace on the open canvas with the real controls.
sv_build_workspace_js <- function() sprintf(paste0("(async () => {", sv_pipeline_helpers_js, "
  sv.clearOperations(true); await sleep(300);
  const pat = %s, labs = %s;
  pat.style.left = '40px'; pat.style.top = '140px';
  labs.style.left = '760px'; labs.style.top = '180px';
  const sortBtn = labs.querySelector('[data-action=\"sort-col\"][data-col-name=\"value\"]');
  sortBtn.click(); await sleep(300); sortBtn.click(); await sleep(600);
  pat.querySelector('[data-action=\"filter-col\"][data-col-name=\"age\"]').click(); await sleep(200);
  const pop = q('.sideview-filter-popover');
  setVal(pop.querySelector('.sideview-filter-select'), 'gt');
  setVal(pop.querySelector('.sideview-filter-input'), '50');
  pop.querySelector('.sideview-filter-apply').click(); await sleep(600);
  fire(pat.querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(150);
  fire(labs.querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(500);
  sv.panzoom.zoom(0.8); sv.panzoom.pan(30, 40); await sleep(200);
  return JSON.stringify(sv.getState());
})()"), sv_card_js("patients"), sv_card_js("labs"))

# JS: what the canvas shows now.
sv_canvas_now_js <- function() sprintf("(async () => {
  await new Promise(r => setTimeout(r, 1500));
  const sv = window._sideviewInstance, labs = %s, pat = %s;
  const firstVals = c => [...c.querySelectorAll('tbody tr[data-row-index]')].slice(0, 3).map(r => r.cells[2].textContent.trim());
  const conn = sv.connections[0];
  return {
    state: sv.getState(), code: sv.generatedCode, conns: sv.connections.length,
    d: conn ? conn.path.getAttribute('d') : '',
    sortState: labs.querySelector('th[data-col-name=\"value\"]').dataset.sortState,
    sortActive: labs.querySelector('[data-action=\"sort-col\"][data-col-name=\"value\"]').classList.contains('active'),
    filterActive: pat.querySelector('[data-action=\"filter-col\"][data-col-name=\"age\"]').classList.contains('active'),
    labsTop: firstVals(labs), patAges: [...pat.querySelectorAll('tbody tr[data-row-index]')].slice(0, 20).map(r => +r.cells[2].textContent.trim()),
    toasts: [...document.querySelectorAll('.sideview-toast')].map(t => t.textContent).join(' | ')
  };
})()", sv_card_js("labs"), sv_card_js("patients"))

sv_card_state <- function(st, name) Filter(function(c) identical(c$name, name), st$cards)[[1]]

test_that("a saved workspace reopens with cards, view, sorts, filters, joins and pipeline", {
  b <- sv_shared_page()
  json <- sv_js(b, sv_build_workspace_js())
  saved <- sv_state_from_json(json)
  expect_equal(saved$canvas$zoom, 0.8)
  expect_equal(sv_card_state(saved, "labs")$sorts[[1]], list(col = "value", dir = "desc"))
  expect_equal(sv_card_state(saved, "patients")$filters[[1]], list(col = "age", op = "gt", val = "50"))
  expect_length(saved$connections, 1)
  expect_gte(length(saved$pipeline$steps), 3)
  sv_js(b, "(async () => { window._sideviewInstance.clearOperations(true); await new Promise(r => setTimeout(r, 300)); return 1; })()")

  dir <- withr::local_tempdir()
  path <- file.path(dir, "ws.json")
  sv_save_state(saved, path)
  app <- sv_start_app(sprintf('{ setwd("%s"); sideview(patients, visits, labs, state = "%s", run = FALSE) }',
                              gsub("\\\\", "/", dir), gsub("\\\\", "/", path)))
  withr::defer(try(app$proc$kill(), silent = TRUE))
  g <- sv_open_page(app$url)
  withr::defer(try(g$close(), silent = TRUE))
  now <- sv_js(g, sv_canvas_now_js())

  env <- new.env()
  eval(parse(text = sv_fixture_code), envir = env)
  st <- now$state
  expect_equal(st$canvas$zoom, 0.8)
  expect_equal(c(st$canvas$pan_x, st$canvas$pan_y), c(30, 40))
  for (nm in c("patients", "labs")) {
    a <- sv_card_state(st, nm)
    e <- sv_card_state(saved, nm)
    expect_equal(c(a$x, a$y, a$width, a$height), c(e$x, e$y, e$width, e$height), info = nm)
  }
  expect_identical(now$sortState, "desc")
  expect_true(now$sortActive)
  expect_equal(as.numeric(unlist(now$labsTop)), head(sort(env$labs$value, decreasing = TRUE), 3))
  expect_true(now$filterActive)
  expect_true(all(unlist(now$patAges) > 50))
  expect_equal(now$conns, 1)
  expect_match(now$d, "^M")
  expect_identical(now$code, saved$pipeline$code)
  expect_true(!is.null(parse(text = now$code)))
  expect_length(attr(g, "sv_errors")(), 0)

  # Save from the gadget: no RStudio here, so R writes a new file in getwd().
  msg <- sv_js(g, "(async () => {
    document.querySelector('[data-action=\"save-workspace\"]').click();
    for (let i = 0; i < 40; i++) {
      await new Promise(r => setTimeout(r, 100));
      const t = [...document.querySelectorAll('.sideview-toast')].map(t => t.textContent).join(' | ');
      if (/Workspace saved to/.test(t)) return t;
    }
    return 'timeout';
  })()")
  expect_match(msg, "Workspace saved to .*sideview-workspace\\.json")
  out <- file.path(dir, "sideview-workspace.json")
  expect_true(file.exists(out))
  resaved <- sv_load_state(out)
  expect_equal(resaved$canvas$zoom, 0.8)
  expect_identical(resaved$pipeline$code, saved$pipeline$code)
  expect_equal(sv_card_state(resaved, "labs")$sorts[[1]]$dir, "desc")
})

test_that("Open replaces the running workspace and names cards it cannot place", {
  b <- sv_shared_page()
  json <- sv_js(b, sv_build_workspace_js())
  st <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  st$cards[[length(st$cards) + 1]] <- list(name = "not_here", x = 1, y = 1)
  r <- sv_js(b, sprintf("(async () => {
    const sv = window._sideviewInstance;
    sv.clearOperations(true); sv.panzoom.zoom(1); sv.panzoom.pan(0, 0); await new Promise(r => setTimeout(r, 300));
    const before = sv.pipeline.steps.length;
    const out = sv.openState(JSON.parse(%s));
    await new Promise(r => setTimeout(r, 800));
    const res = { before: before, after: sv.pipeline.steps.length, missing: out.missing, zoom: sv.panzoom.getScale(),
      conns: sv.connections.length, canUndo: sv.pipeline.canUndo(),
      toasts: [...document.querySelectorAll('.sideview-toast')].map(t => t.textContent).join(' | ') };
    sv.openState(JSON.parse(%s)); await new Promise(r => setTimeout(r, 300));
    res.connsAgain = sv.connections.length;
    sv.clearOperations(true); sv.fitAll(); await new Promise(r => setTimeout(r, 300));
    return res;
  })()", jsonlite::toJSON(sv_state_json(st), auto_unbox = TRUE), jsonlite::toJSON(json, auto_unbox = TRUE)))
  expect_equal(r$before, 0)
  expect_equal(r$after, length(st$pipeline$steps))
  expect_identical(unlist(r$missing), "not_here")
  expect_equal(r$zoom, 0.8)
  expect_equal(r$conns, 1)
  expect_false(r$canUndo)
  expect_match(r$toasts, "not on this canvas: not_here", fixed = TRUE)
  # Opening twice does not stack joins.
  expect_equal(r$connsAgain, 1)
})

test_that("the saved widget restores a state and downloads its own", {
  skip_if_no_browser()
  env <- new.env()
  eval(parse(text = sv_fixture_code), envir = env)
  st <- new_sideview_state(
    canvas = list(zoom = 0.7, pan_x = 15, pan_y = 25),
    cards = list(list(name = "patients", x = 500, y = 300, width = 420, height = 330, minimized = FALSE,
                      sorts = list(list(col = "age", dir = "asc")), filters = list()),
                 list(name = "visits", x = 20, y = 300, minimized = TRUE)),
    connections = list(list(from_table = "visits", from_col = "pid", to_table = "patients",
                            to_col = "patient_id", join_type = "left_join")),
    pipeline = list(code = "", active_tab = "pipeline", pipe = "|>",
                    steps = list(list(kind = "join", key = '["join","visits","patients"]', table = "visits",
                                      right = "patients", type = "left_join", id = "s1", enabled = TRUE,
                                      by = list(list(left = "pid", right = "patient_id")))))
  )
  dir <- withr::local_tempdir()
  file <- file.path(dir, "restored.html")
  w <- local(sideview_widget(patients, visits, state = st), envir = env)
  suppressMessages(save_sideview(w, file, selfcontained = FALSE))
  url <- paste0("file:///", gsub("\\\\", "/", normalizePath(file)))
  b <- sv_open_page(url, wait_for = "!!document.querySelector('.sideview-card .sideview-col-port')")
  withr::defer(try(b$close(), silent = TRUE))
  r <- sv_js(b, sprintf("(async () => {
    await new Promise(r => setTimeout(r, 600));
    const sv = document.querySelector('.sideview-container')._sideviewInstance;
    const pat = %s, vis = %s;
    const ages = [...pat.querySelectorAll('tbody tr[data-row-index]')].slice(0, 5).map(r => +r.cells[2].textContent.trim());
    const out = { zoom: sv.panzoom.getScale(), pan: sv.panzoom.getPan(), left: pat.style.left, top: pat.style.top,
      width: pat.offsetWidth, visMin: vis.classList.contains('is-minimized'), conns: sv.connections.length,
      code: sv.generatedCode, pipe: sv.pipeline.pipe, ages: ages };
    document.querySelector('[data-action=\"save-workspace\"]').click();
    await new Promise(r => setTimeout(r, 100));
    out.saved = sv.lastStateJson;
    out.toasts = [...document.querySelectorAll('.sideview-toast')].map(t => t.textContent).join(' | ');
    out.openBtn = !!document.querySelector('[data-action=\"open-workspace\"] svg');
    return out;
  })()", sv_card_js("patients"), sv_card_js("visits")))
  expect_equal(r$zoom, 0.7)
  expect_equal(c(r$pan$x, r$pan$y), c(15, 25))
  expect_identical(c(r$left, r$top), c("500px", "300px"))
  expect_equal(r$width, 420)
  expect_true(r$visMin)
  expect_equal(r$conns, 1)
  expect_identical(r$pipe, "|>")
  expect_match(r$code, "dplyr::left_join(patients, by = c(\"pid\" = \"patient_id\"))", fixed = TRUE)
  ages <- unlist(r$ages)
  expect_equal(ages, head(sort(env$patients$age), 5))
  expect_match(r$toasts, "Workspace downloaded", fixed = TRUE)
  expect_true(r$openBtn)
  back <- sv_state_from_json(r$saved)
  expect_equal(back$canvas$zoom, 0.7)
  expect_true(sv_card_state(back, "visits")$minimized)
  expect_equal(sv_card_state(back, "patients")$sorts[[1]]$col, "age")
  expect_length(attr(b, "sv_errors")(), 0)
})

# ---- canvas navigation: zoom-to-card, Ctrl+K search, minimap -----------------

sv_mouse <- function(b) {
  ev <- function(type, p, count = 1) {
    b$Input$dispatchMouseEvent(type = type, x = p$x, y = p$y, button = "left",
                               clickCount = if (type == "mouseMoved") 0 else count)
  }
  list(
    click = function(p) { ev("mouseMoved", p); ev("mousePressed", p); ev("mouseReleased", p) },
    dblclick = function(p) {
      ev("mouseMoved", p); ev("mousePressed", p, 1); ev("mouseReleased", p, 1)
      ev("mousePressed", p, 2); ev("mouseReleased", p, 2)
    },
    drag = function(from, to) {
      ev("mouseMoved", from); ev("mousePressed", from)
      for (t in seq(0.25, 1, by = 0.25)) {
        ev("mouseMoved", list(x = from$x + (to$x - from$x) * t, y = from$y + (to$y - from$y) * t))
      }
      ev("mouseReleased", to)
    }
  )
}

sv_key <- function(b, key, code, vk, modifiers = 0) {
  b$Input$dispatchKeyEvent(type = "rawKeyDown", key = key, code = code, windowsVirtualKeyCode = vk, modifiers = modifiers)
  b$Input$dispatchKeyEvent(type = "keyUp", key = key, code = code, windowsVirtualKeyCode = vk, modifiers = modifiers)
}

# JS: a card's screen rect and the free canvas area it should sit in.
sv_card_view_js <- function(name) sprintf("(() => {
  const sv = window._sideviewInstance || document.querySelector('.sideview-container')._sideviewInstance;
  const el = %s, r = el.getBoundingClientRect(), c = sv.container.getBoundingClientRect();
  return { card: r.toJSON(), scale: sv.panzoom.getScale(), focus: el.classList.contains('sv-card-focus'),
    free: { left: c.left + 24, right: c.right - 24, top: c.top + sv.chromeTop() + 16, bottom: c.bottom - sv.chromeBottom() } };
})()", sv_card_js(name))

sv_expect_card_in_view <- function(v, label) {
  expect_gte(v$card$left, v$free$left - 1, label = paste(label, "left"))
  expect_lte(v$card$right, v$free$right + 1, label = paste(label, "right"))
  expect_gte(v$card$top, v$free$top - 1, label = paste(label, "top"))
  expect_lte(v$card$bottom, v$free$bottom + 1, label = paste(label, "bottom"))
  expect_lt(abs((v$card$left + v$card$right) / 2 - (v$free$left + v$free$right) / 2), 2, label = paste(label, "centred"))
  expect_true(v$focus, label = paste(label, "flashed"))
}

test_that("double-clicking a card title zooms to that card", {
  b <- sv_shared_page()
  m <- sv_mouse(b)
  sv_js(b, "(async () => { const sv = window._sideviewInstance; sv.panzoom.zoom(0.6); sv.panzoom.pan(-300, 40);
    await new Promise(r => setTimeout(r, 200)); return 1; })()")
  title <- sv_js(b, sprintf("(() => { const r = %s.querySelector('.sideview-card-title').getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()", sv_card_js("visits")))
  m$dblclick(title)
  Sys.sleep(0.3)
  v <- sv_js(b, sv_card_view_js("visits"))
  sv_expect_card_in_view(v, "visits")
  expect_gte(v$scale, 0.5)
  expect_lte(v$scale, 1.5)

  # A double-click on a header button keeps its own meaning (no zoom).
  btn <- sv_js(b, sprintf("(() => { const r = %s.querySelector('[data-action=\"sync-scroll\"]').getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()", sv_card_js("visits")))
  sv_js(b, "(() => { window._sideviewInstance.panzoom.zoom(0.7); return 1; })()")
  m$dblclick(btn)
  Sys.sleep(0.2)
  expect_equal(sv_js(b, "window._sideviewInstance.panzoom.getScale()"), 0.7)
  sv_js(b, "(async () => { window._sideviewInstance.fitAll(); return 1; })()")
  expect_length(attr(b, "sv_errors")(), 0)
})

test_that("Ctrl+K finds cards and columns and Enter zooms to the match", {
  b <- sv_shared_page()
  sv_js(b, "(() => { document.activeElement && document.activeElement.blur(); return 1; })()")
  sv_key(b, "k", "KeyK", 75, modifiers = 2)
  Sys.sleep(0.2)
  open <- sv_js(b, "(() => {
    const dlg = document.querySelector('.sideview-search'), inp = document.querySelector('.sideview-search-input');
    return { open: !!dlg, role: dlg && dlg.getAttribute('role'), focused: document.activeElement === inp,
      options: [...document.querySelectorAll('.sideview-search-list [role=option]')].map(o => o.textContent),
      selected: document.querySelectorAll('.sideview-search-list [aria-selected=true]').length,
      active: inp && inp.getAttribute('aria-activedescendant') };
  })()")
  expect_true(open$open)
  expect_identical(open$role, "dialog")
  expect_true(open$focused)
  expect_length(open$options, 3)
  expect_equal(open$selected, 1)
  expect_match(open$active, "^sv-search-opt-")

  b$Input$insertText(text = "pa")
  Sys.sleep(0.2)
  pa <- sv_js(b, "[...document.querySelectorAll('.sideview-search-list [role=option]')].map(o => o.textContent)")
  # Card name first, then the two patient_id columns.
  expect_length(pa, 3)
  expect_match(pa[[1]], "^patients")
  expect_true(all(grepl("patient_id", unlist(pa[2:3]))))

  # Arrow keys move the selection and wrap.
  sv_key(b, "ArrowDown", "ArrowDown", 40)
  sv_key(b, "ArrowUp", "ArrowUp", 38)
  sv_key(b, "ArrowUp", "ArrowUp", 38)
  sel <- sv_js(b, "[...document.querySelectorAll('.sideview-search-list [role=option]')].findIndex(o => o.getAttribute('aria-selected') === 'true')")
  expect_equal(sel, 2)

  sv_js(b, "(() => { document.querySelector('.sideview-search-input').value = ''; return 1; })()")
  b$Input$insertText(text = "SBP")
  Sys.sleep(0.2)
  sbp <- sv_js(b, "[...document.querySelectorAll('.sideview-search-list [role=option]')].map(o => o.textContent)")
  expect_length(sbp, 1)
  expect_match(sbp[[1]], "visits.*sbp")
  sv_js(b, "(() => { window._sideviewInstance.panzoom.zoom(0.55); window._sideviewInstance.panzoom.pan(900, 600); return 1; })()")
  sv_key(b, "Enter", "Enter", 13)
  Sys.sleep(0.3)
  after <- sv_js(b, sprintf("(() => ({ closed: !document.querySelector('.sideview-search-scrim'),
    colFocus: %s.querySelector('th[data-col-name=\"sbp\"]').classList.contains('sv-col-focus') }))()", sv_card_js("visits")))
  expect_true(after$closed)
  expect_true(after$colFocus)
  sv_expect_card_in_view(sv_js(b, sv_card_view_js("visits")), "search visits")

  # Toolbar button opens it; Esc closes it without touching anything else.
  sv_js(b, "(() => { document.querySelector('[data-action=\"open-search\"]').click(); return 1; })()")
  b$Input$insertText(text = "zzz")
  Sys.sleep(0.2)
  empty <- sv_js(b, "(document.querySelector('.sideview-search-empty') || {}).textContent")
  expect_identical(empty, "No card or column matches")
  sv_key(b, "Escape", "Escape", 27)
  Sys.sleep(0.2)
  expect_false(sv_js(b, "!!document.querySelector('.sideview-search-scrim')"))
  sv_js(b, "(async () => { window._sideviewInstance.fitAll(); return 1; })()")
  expect_length(attr(b, "sv_errors")(), 0)
})

# JS: minimap geometry, and a point on it that is not over a card.
sv_minimap_js <- "(() => {
  const mm = document.querySelector('.sideview-minimap');
  const svg = mm.querySelector('.sideview-minimap-svg'), vis = getComputedStyle(mm).display !== 'none';
  const r = vis ? mm.getBoundingClientRect().toJSON() : null;
  const cards = [...svg.querySelectorAll('.sideview-minimap-card')].map(e => e.getBoundingClientRect());
  let empty = null;
  if (vis) {
    const s = svg.getBoundingClientRect();
    for (let y = s.top + 6; y < s.bottom - 6 && !empty; y += 4) for (let x = s.left + 6; x < s.right - 30 && !empty; x += 4) {
      if (!cards.some(c => x >= c.left - 3 && x <= c.right + 3 && y >= c.top - 3 && y <= c.bottom + 3)) empty = { x: x, y: y };
    }
  }
  const toCanvas = p => { const pt = svg.createSVGPoint(); pt.x = p.x; pt.y = p.y; const c = pt.matrixTransform(svg.getScreenCTM().inverse()); return { x: c.x, y: c.y }; };
  const first = svg.querySelector('.sideview-minimap-card');
  const fr = first && first.getBoundingClientRect();
  return { visible: vis, rect: r, n: cards.length, view: !!svg.querySelector('.sideview-minimap-view'),
    empty: empty, emptyCanvas: empty ? toCanvas(empty) : null,
    firstCard: fr ? { x: fr.x + fr.width / 2, y: fr.y + fr.height / 2, id: first.getAttribute('data-card-id') } : null,
    collapsed: mm.classList.contains('is-collapsed') };
})()"

# JS: the canvas point at the centre of the free area.
sv_view_centre_js <- "(() => {
  const sv = window._sideviewInstance, s = sv.panzoom.getScale(), p = sv.panzoom.getPan();
  const cy = (sv.chromeTop() + sv.container.clientHeight - sv.chromeBottom()) / 2;
  return { x: (sv.container.clientWidth / 2 - p.x) / s, y: (cy - p.y) / s };
})()"

test_that("the minimap shows the cards, moves the view and stays clear of the chrome", {
  b <- sv_shared_page()
  m <- sv_mouse(b)
  mm <- sv_js(b, sv_minimap_js)
  expect_true(mm$visible)
  expect_equal(mm$n, 3)
  expect_true(mm$view)

  # Click empty map: the view centres there at the same zoom.
  scale <- sv_js(b, "window._sideviewInstance.panzoom.getScale()")
  m$click(mm$empty)
  Sys.sleep(0.3)
  ctr <- sv_js(b, sv_view_centre_js)
  expect_lt(abs(ctr$x - mm$emptyCanvas$x), 2)
  expect_lt(abs(ctr$y - mm$emptyCanvas$y), 2)
  expect_equal(sv_js(b, "window._sideviewInstance.panzoom.getScale()"), scale)

  # Drag: the view follows the pointer.
  mm <- sv_js(b, sv_minimap_js)
  to <- list(x = mm$rect$left + 40, y = mm$rect$top + 30)
  to_canvas <- sv_js(b, sprintf("(() => { const svg = document.querySelector('.sideview-minimap-svg');
    const pt = svg.createSVGPoint(); pt.x = %f; pt.y = %f; const c = pt.matrixTransform(svg.getScreenCTM().inverse());
    return { x: c.x, y: c.y }; })()", to$x, to$y))
  m$drag(mm$empty, to)
  Sys.sleep(0.3)
  ctr <- sv_js(b, sv_view_centre_js)
  expect_lt(abs(ctr$x - to_canvas$x), 2)
  expect_lt(abs(ctr$y - to_canvas$y), 2)

  # Click a card on the map: zoom to that card.
  mm <- sv_js(b, sv_minimap_js)
  m$click(mm$firstCard)
  Sys.sleep(0.3)
  name <- sv_js(b, sprintf("document.querySelector('.sideview-card[data-card-id=\"%s\"]').dataset.cardName", mm$firstCard$id))
  sv_expect_card_in_view(sv_js(b, sv_card_view_js(name)), "minimap card")

  # M collapses it, its button brings it back.
  sv_js(b, "(() => { document.activeElement && document.activeElement.blur(); return 1; })()")
  sv_key(b, "m", "KeyM", 77)
  Sys.sleep(0.2)
  expect_true(sv_js(b, sv_minimap_js)$collapsed)
  sv_js(b, "(() => { document.querySelector('.sideview-minimap-toggle').click(); return 1; })()")
  Sys.sleep(0.2)
  expect_false(sv_js(b, sv_minimap_js)$collapsed)

  for (sz in list(c(1400, 900), c(1024, 700), c(560, 520))) {
    sv_set_viewport(b, sz[1], sz[2])
    r <- sv_js(b, "(async () => {
      const d = document.querySelector('.sideview-drawer');
      const was = d.classList.contains('collapsed');
      if (was) document.querySelector('[data-action=\"toggle-drawer\"]').click();
      await new Promise(r => setTimeout(r, 400));
      const box = s => { const e = document.querySelector(s); if (!e || getComputedStyle(e).display === 'none') return null;
        const x = e.getBoundingClientRect(); return x.width && x.height ? x.toJSON() : null; };
      const out = { mm: box('.sideview-minimap'), ai: box('.sideview-ai-bar'), toolbar: box('.sideview-toolbar'),
        palette: box('.sideview-palette'), drawer: box('.sideview-drawer'), vw: innerWidth, vh: innerHeight };
      if (was) document.querySelector('[data-action=\"toggle-drawer\"]').click();
      await new Promise(r => setTimeout(r, 300));
      return out;
    })()")
    label <- paste(sz, collapse = "x")
    if (sz[1] < 720) {
      expect_null(r$mm, label = paste("minimap hidden", label))
      next
    }
    expect_false(is.null(r$mm), info = label)
    for (nm in c("ai", "toolbar", "palette", "drawer")) {
      expect_false(rect_overlap(r$mm, r[[nm]]), info = paste("minimap", nm, label))
    }
    expect_true(r$mm$left >= 0 && r$mm$bottom <= r$vh + 1, info = paste("minimap inside", label))
  }
  sv_set_viewport(b, 1400, 900)
  sv_js(b, "(async () => { window._sideviewInstance.fitAll(); return 1; })()")
  expect_length(attr(b, "sv_errors")(), 0)
})

test_that("the saved widget has the minimap, search and zoom-to-card", {
  skip_if_no_browser()
  env <- new.env()
  eval(parse(text = sv_fixture_code), envir = env)
  dir <- withr::local_tempdir()
  file <- file.path(dir, "nav.html")
  w <- local(sideview_widget(patients, visits, labs), envir = env)
  suppressMessages(save_sideview(w, file, selfcontained = FALSE))
  url <- paste0("file:///", gsub("\\\\", "/", normalizePath(file)))
  b <- sv_open_page(url, wait_for = "!!document.querySelector('.sideview-card .sideview-col-port')")
  withr::defer(try(b$close(), silent = TRUE))
  r <- sv_js(b, "(async () => {
    await new Promise(r => setTimeout(r, 600));
    const sv = document.querySelector('.sideview-container')._sideviewInstance;
    const mm = document.querySelector('.sideview-minimap');
    const out = { mmCards: mm.querySelectorAll('.sideview-minimap-card').length,
      searchBtn: !!document.querySelector('[data-action=\"open-search\"] svg') };
    document.querySelector('[data-action=\"open-search\"]').click(); await new Promise(r => setTimeout(r, 50));
    const inp = document.querySelector('.sideview-search-input');
    inp.value = 'value'; inp.dispatchEvent(new Event('input', { bubbles: true }));
    out.options = [...document.querySelectorAll('.sideview-search-list [role=option]')].map(o => o.textContent);
    inp.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
    await new Promise(r => setTimeout(r, 100));
    const labs = [...document.querySelectorAll('.sideview-card')].find(c => c.dataset.cardName === 'labs');
    out.closed = !document.querySelector('.sideview-search-scrim');
    out.labsFocus = labs.classList.contains('sv-card-focus');
    const cr = sv.container.getBoundingClientRect(), lr = labs.getBoundingClientRect();
    out.inside = lr.left >= cr.left && lr.right <= cr.right && lr.top >= cr.top && lr.bottom <= cr.bottom;
    return out;
  })()")
  expect_equal(r$mmCards, 3)
  expect_true(r$searchBtn)
  expect_length(r$options, 1)
  expect_match(r$options[[1]], "labs.*value")
  expect_true(r$closed)
  expect_true(r$labsFocus)
  expect_true(r$inside)
  expect_length(attr(b, "sv_errors")(), 0)
})

# ---- date rules of joins: edit from the join step, code and panel ------------

test_that("a window rule edits from the join step and shows in code and panel", {
  skip_if_no_browser()
  setup <- paste0(
    "{ set.seed(7); ",
    "visits <- data.frame(id = rep(1:6, each = 2), visit_date = as.Date('2024-03-01') + rep(c(0, 20), 6) + rep(0:5, each = 2)); ",
    "labs <- data.frame(id = rep(1:6, each = 3), lab_date = as.Date('2024-03-01') + rep(c(-5, 1, 21), 6) + rep(0:5, each = 3), ",
    "value = round(rnorm(18), 2)); ",
    "sideview(visits, labs, run = FALSE) }")
  app <- sv_start_app(setup)
  b <- sv_open_page(app$url)
  withr::defer({
    try(b$close(), silent = TRUE)
    try(app$proc$kill(), silent = TRUE)
  })
  expect_true(attr(b, "sv_ready"))

  visits <- data.frame(id = rep(1:6, each = 2),
                       visit_date = as.Date("2024-03-01") + rep(c(0, 20), 6) + rep(0:5, each = 2))
  set.seed(7)
  labs <- data.frame(id = rep(1:6, each = 3),
                     lab_date = as.Date("2024-03-01") + rep(c(-5, 1, 21), 6) + rep(0:5, each = 3))
  labs$value <- round(rnorm(18), 2)
  rule <- list(shape = "window", xCol = "visit_date", yCol = "lab_date", from = -3, to = 3)
  want <- sv_join_diagnostics(visits, labs, c(id = "id"), x_name = "visits", y_name = "labs", rule = rule)
  expect_gt(want$rule_dropped_x + want$rule_dropped_y, 0)

  m <- sv_mouse(b)
  centre <- function(sel) {
    r <- sv_js(b, sprintf("(() => { const e = document.querySelector(%s); e.scrollIntoView({block: 'nearest'});
      const r = e.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()",
      jsonlite::toJSON(sel, auto_unbox = TRUE)))
    list(x = r$x, y = r$y)
  }
  wait_for <- function(js, tries = 60) {
    for (i in seq_len(tries)) { if (isTRUE(sv_js(b, js))) return(TRUE); Sys.sleep(0.25) }
    FALSE
  }
  type_into <- function(sel, text) {
    m$click(centre(sel))
    sv_key(b, "a", "KeyA", 65, modifiers = 2)
    b$Input$insertText(text = text)
  }

  # connect id to id, and wait for the join step with its key check
  sv_js(b, paste0("(async () => {", sv_pipeline_helpers_js, "
    const vis = ", sv_card_js("visits"), ", labs = ", sv_card_js("labs"), ";
    fire(vis.querySelector('.sideview-col-port[data-col-name=\"id\"]')); await sleep(150);
    fire(labs.querySelector('.sideview-col-port[data-col-name=\"id\"]')); await sleep(150);
    return true; })()"))
  expect_true(wait_for("!!document.querySelector('.sideview-step.is-join')"))
  sv_js(b, paste0("(() => {", sv_pipeline_helpers_js, "
    if (q('.sideview-drawer').classList.contains('collapsed')) q('[data-action=\"toggle-drawer\"]').click();
    tab('pipeline'); return true; })()"))
  expect_true(wait_for("(() => { const r = document.querySelector('button.sideview-step-rule').getBoundingClientRect(); return r.left >= 0 && r.right <= innerWidth; })()"))

  # real click on the rule button, then pick the window shape and its two columns
  m$click(centre("button.sideview-step-rule[data-step-action='rule']"))
  expect_true(wait_for("!!document.querySelector('.sideview-rule-row')"))
  sv_js(b, paste0("(async () => {", sv_pipeline_helpers_js, "
    setVal(q('.sideview-rule-shape'), 'window'); await sleep(150);
    setVal(q('.sideview-rule-col[data-slot=\"xCol\"]'), 'visit_date'); await sleep(150);
    setVal(q('.sideview-rule-col[data-slot=\"yCol\"]'), 'lab_date'); await sleep(150);
    return true; })()"))
  type_into(".sideview-rule-from", "-3")
  type_into(".sideview-rule-to", "3")

  geometry <- paste0("(() => {
    const row = document.querySelector('.sideview-rule-row'), li = row.closest('.sideview-step');
    const dr = document.querySelector('.sideview-drawer').getBoundingClientRect(), rr = row.getBoundingClientRect();
    const others = ['.sideview-step-toggle', '.sideview-step-joinopts', '[data-step-action=\"delete\"]']
      .map(s => li.querySelector(s)).filter(Boolean).map(e => e.getBoundingClientRect().toJSON());
    return { row: rr.toJSON(), drawer: dr.toJSON(), others: others,
             overflow: li.scrollWidth - li.clientWidth,
             from: document.querySelector('.sideview-rule-from').value,
             to: document.querySelector('.sideview-rule-to').value };
  })()")
  check_geometry <- function(label) {
    g <- sv_js(b, geometry)
    expect_equal(g$from, "-3", label = label)
    expect_equal(g$to, "3", label = label)
    expect_gte(g$row$left, g$drawer$left - 1)
    expect_lte(g$row$right, g$drawer$right + 1)
    expect_gte(g$row$top, g$drawer$top - 1)
    expect_lte(g$row$bottom, g$drawer$bottom + 1)
    expect_gt(length(g$others), 0)
    for (o in g$others) expect_false(rect_overlap(g$row, o), info = label)
    expect_lte(g$overflow, 1, label = label)
  }
  check_geometry("1400x900")
  sv_set_viewport(b, 560, 700)
  expect_true(wait_for("!!document.querySelector('.sideview-rule-row')"))
  check_geometry("560x700")
  sv_set_viewport(b, 1400, 900)

  # Ctrl+Enter in the To field applies the rule
  m$click(centre(".sideview-rule-to"))
  sv_key(b, "Enter", "Enter", 13, modifiers = 2)
  expect_true(wait_for("!document.querySelector('.sideview-rule-row')"))

  code <- sv_js(b, "document.querySelector('.sideview-code-text').closest('pre').textContent")
  expect_match(code, ".sv_lo = visit_date - 3", fixed = TRUE)
  expect_match(code, ".sv_hi = visit_date + 3", fixed = TRUE)
  expect_no_error(parse(text = code))

  # the join check panel reports the rows the rule dropped, as R computes them
  sv_js(b, "document.querySelector('.sideview-step-diag').click()")
  expect_true(wait_for("!!document.querySelector('.sideview-joincheck-dropped')", 80))
  txt <- sv_js(b, "document.querySelector('.sideview-joincheck-dropped').nextElementSibling.textContent")
  expect_identical(txt, sprintf("%s visits rows / %s labs rows",
                                formatC(want$rule_dropped_x, big.mark = ",", format = "d"),
                                formatC(want$rule_dropped_y, big.mark = ",", format = "d")))

  # Strict: a filter before the join greys the box with the reason (in the step and in the panel),
  # a real click on it changes nothing; without the filter a real click turns Strict on
  expect_false(is.null(want$strict_args$left_join))
  join_strict <- "!!window._sideviewInstance.pipeline.steps.find(s => s.kind === 'join').strict"
  sv_js(b, "(() => { const e = window._sideviewInstance;
    const f = e.pipeline.add({ kind: 'filter', table: 'visits', conds: ['id > 1'], combine: 'and' }, 'filter');
    e.pipeline.move(f.id, -1); window._svFilterId = f.id; return true; })()")
  expect_true(wait_for("document.querySelector('.sideview-step-strict').disabled"))
  reason <- "Strict applies only to a join on the original tables: an earlier step changes the rows"
  # a new step brings the Pipeline tab forward; the panel is drawn when its tab opens
  m$click(centre('.sideview-drawer-tab[data-tab="discrepancy"]'))
  expect_true(wait_for("!!document.querySelector('.sideview-joincheck-strict')"))
  g <- sv_js(b, "({ title: document.querySelector('.sideview-step-strict').title,
                    line: document.querySelector('.sideview-joincheck-strict').textContent })")
  expect_identical(g$title, reason)
  expect_identical(g$line, reason)
  m$click(centre('.sideview-drawer-tab[data-tab="pipeline"]'))
  expect_true(wait_for("document.querySelector('.sideview-step-strict').offsetParent !== null"))
  m$click(centre(".sideview-step-strict"))
  Sys.sleep(0.4)
  expect_false(isTRUE(sv_js(b, join_strict)))
  sv_js(b, "window._sideviewInstance.pipeline.remove(window._svFilterId)")
  expect_true(wait_for("!document.querySelector('.sideview-step-strict').disabled"))
  m$click(centre(".sideview-step-strict"))
  expect_true(wait_for(join_strict))
  code <- sv_js(b, "document.querySelector('.sideview-code-text').closest('pre').textContent")
  expect_match(code, 'relationship = "', fixed = TRUE)
  expect_no_error(parse(text = code))
  expect_length(attr(b, "sv_errors")(), 0)
})
