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
