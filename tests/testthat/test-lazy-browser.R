# Real-browser tests for lazy (duckdb / arrow) cards: the card uses the whole table when
# it can, and says so when it only holds a preview. Set SIDEVIEW_SHOT_DIR to also save
# screenshots (nothing is written otherwise).

sv_big_code <- '
set.seed(1)
big_df <- data.frame(id = 1:200000, x = round(rnorm(200000), 4))
'

# The same values in the test process.
sv_big_x <- function() {
  set.seed(1)
  round(rnorm(200000), 4)
}

sv_shot <- function(b, name) {
  dir <- Sys.getenv("SIDEVIEW_SHOT_DIR", "")
  if (!nzchar(dir)) return(invisible(NULL))
  b$screenshot(file.path(dir, paste0(name, ".png")), selector = "html")
  invisible(NULL)
}

# A real mouse click at the centre of the element a JS expression returns.
sv_click <- function(b, el_js) {
  p <- sv_js(b, sprintf("(() => {
    const el = %s;
    el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    const r = el.getBoundingClientRect();
    const x = r.x + r.width / 2, y = r.y + r.height / 2;
    const hit = document.elementFromPoint(x, y);
    return { x: x, y: y, ok: hit === el || el.contains(hit) };
  })()", el_js))
  testthat::expect_true(p$ok)
  for (type in c("mouseMoved", "mousePressed", "mouseReleased")) {
    b$Input$dispatchMouseEvent(type = type, x = p$x, y = p$y, button = "left",
                               clickCount = if (type == "mouseMoved") 0 else 1)
  }
  invisible(p)
}

sv_lazy_helpers_js <- paste0("
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const sv = window._sideviewInstance;
  const q = s => document.querySelector(s);
  const until = async (f, ms) => { for (let t = 0; t < ms; t += 50) { if (f()) return true; await sleep(50); } return false; };
  const setVal = (el, v) => { el.value = v; el.dispatchEvent(new Event('input', {bubbles: true})); el.dispatchEvent(new Event('change', {bubbles: true})); };
")

sv_with_app <- function(app_expr) {
  skip_if_no_browser()
  app <- sv_start_app(app_expr)
  b <- sv_open_page(app$url)
  withr::defer({
    try(b$close(), silent = TRUE)
    try(app$proc$kill(), silent = TRUE)
  }, envir = parent.frame())
  b
}

test_that("lazy duckdb card uses the whole table", {
  skip_if_no_browser()
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  x <- sv_big_x()
  b <- sv_with_app('{
    con <- DBI::dbConnect(duckdb::duckdb())
    set.seed(1)
    DBI::dbWriteTable(con, "big", data.frame(id = 1:200000, x = round(rnorm(200000), 4)))
    big <- dplyr::tbl(con, "big")
    sideview(patients, big, run = FALSE)
  }')
  expect_true(attr(b, "sv_ready"))
  card <- sv_card_js("big")

  badge <- sv_js(b, sprintf("%s.querySelector('.sideview-badge:not(.sideview-badge-type)').textContent", card))
  expect_match(badge, "200000|200,000")
  expect_false(grepl("First", badge))
  expect_identical(sv_js(b, sprintf("%s.dataset.rowsBasis", card)), "full")

  # A real click on the header sort button: ascending, then descending.
  btn <- sprintf("%s.querySelector('[data-action=\"sort-col\"][data-col-name=\"x\"]')", card)
  sv_click(b, btn)
  Sys.sleep(1.5)
  sv_click(b, btn)
  ok <- sv_js(b, paste0("(async () => {", sv_lazy_helpers_js, sprintf("
    const c = %s;
    const firstCell = () => { const r = c.querySelector('tbody tr[data-row-index]'); return r ? r.cells[1].textContent.trim() : null; };
    await until(() => firstCell() === %s, 8000);
    return firstCell();
  })()", card, jsonlite::toJSON(as.character(max(x)), auto_unbox = TRUE))))
  expect_identical(ok, as.character(max(x)))
  sv_click(b, btn)                                    # reset
  Sys.sleep(1)

  # Filter x > 2 from the header filter popover.
  sv_click(b, sprintf("%s.querySelector('[data-action=\"filter-col\"][data-col-name=\"x\"]')", card))
  sv_js(b, paste0("(() => {", sv_lazy_helpers_js, "
    const pop = q('.sideview-filter-popover');
    setVal(pop.querySelector('.sideview-filter-select'), 'gt');
    setVal(pop.querySelector('.sideview-filter-input'), '2');
    return true;
  })()"))
  sv_click(b, "document.querySelector('.sideview-filter-popover .sideview-filter-apply')")
  r <- sv_js(b, paste0("(async () => {", sv_lazy_helpers_js, sprintf("
    const vt = %s._virtualTable;
    await until(() => vt.remote && vt.remote.count < 200000 && vt.remote.blocks[0], 8000);
    return { count: vt.remote.count, total: vt.remote.total };
  })()", card)))
  expect_equal(r$count, sum(x > 2))
  expect_equal(r$total, 200000)

  # The inspector profiles the whole column, with no "first N rows" note.
  sv_click(b, sprintf("%s.querySelector('th[data-col-name=\"x\"] [data-action=\"inspect-col\"]')", card))
  p <- sv_js(b, paste0("(async () => {", sv_lazy_helpers_js, "
    await until(() => q('.sideview-inspect-stats'), 10000);
    const pane = q('[data-pane=\"inspect\"]');
    return { prof: sv.colProfiles[JSON.stringify(['big', 'x'])], note: !!pane.querySelector('.sideview-basis-note') };
  })()"))
  expect_equal(p$prof$n, 200000)
  expect_equal(p$prof$stats$median, stats::median(x), tolerance = 1e-12)
  expect_false(p$note)
  sv_shot(b, "lazy-full-card-inspector")

  # The discrepancy summary compares the rows R holds (the preview) and says so,
  # even for a card whose other checks use the whole table.
  d <- sv_js(b, paste0("(async () => {", sv_lazy_helpers_js, "
    Shiny.setInputValue('discrepancy_check', { table1: 'patients', col1: 'age', table2: 'big', col2: 'id' },
                        { priority: 'event' });
    await until(() => q('.sideview-discrepancy-card .sideview-btn-auto-clean'), 8000);
    const n = q('.sideview-discrepancy-card .sideview-basis-note');
    const btn = q('.sideview-discrepancy-card .sideview-btn-auto-clean');
    return { note: n ? n.textContent : null, title: btn ? btn.title : null };
  })()"))
  expect_identical(d$note, "Based on the first 50 rows")
  expect_identical(d$title, "Cleanups suggested from the first 50 rows")

  expect_length(attr(b, "sv_errors")(), 0)
})

test_that("preview-only labels", {
  skip_if_no_browser()
  skip_if_not_installed("arrow")
  x <- sv_big_x()
  b <- sv_with_app('{
    options(sideview.use_duckdb = FALSE)
    set.seed(1)
    big <- arrow::arrow_table(id = 1:200000, x = round(rnorm(200000), 4))
    sideview(patients, big, run = FALSE)
  }')
  expect_true(attr(b, "sv_ready"))
  card <- sv_card_js("big")
  badge <- sv_js(b, sprintf("%s.querySelector('.sideview-badge:not(.sideview-badge-type)').textContent", card))
  expect_identical(badge, "First 50 of 200,000 rows")
  expect_identical(sv_js(b, sprintf("%s.dataset.rowsBasis", card)), "preview")

  sv_click(b, sprintf("%s.querySelector('th[data-col-name=\"x\"] [data-action=\"inspect-col\"]')", card))
  p <- sv_js(b, paste0("(async () => {", sv_lazy_helpers_js, "
    await until(() => q('.sideview-inspect-stats'), 10000);
    const note = q('[data-pane=\"inspect\"] .sideview-basis-note');
    return { n: sv.colProfiles[JSON.stringify(['big', 'x'])].n, note: note ? note.textContent : null };
  })()"))
  expect_equal(p$n, 50)
  expect_identical(p$note, "Based on the first 50 rows")
  sv_shot(b, "preview-only-badge-and-banner")

  # A join check on a preview-only card carries the banner too.
  r <- sv_js(b, paste0("(async () => {", sv_lazy_helpers_js, "
    sv.pipeline.add({ kind: 'join', table: 'patients', right: 'big', type: 'left_join',
                      by: [{ left: 'age', right: 'id' }] });
    q('.sideview-drawer-tabs [data-tab=\"discrepancy\"]').click();
    await until(() => q('.sideview-joincheck .sideview-basis-note'), 10000);
    const n = q('.sideview-joincheck .sideview-basis-note');
    return n ? n.textContent : null;
  })()"))
  expect_identical(r, "Based on the first 50 rows")

  # Auto Map suggestions involving the preview card say what they were based on.
  m <- sv_js(b, paste0("(async () => {", sv_lazy_helpers_js, "
    sv.renderSuggestedSplines({ candidates: [{ from_table: 'patients', from_col: 'age',
                                               to_table: 'big', to_col: 'id', confidence: 0.9 }] });
    await until(() => [...document.querySelectorAll('.sideview-toast')].some(t => /Suggested joins/.test(t.textContent)), 5000);
    const path = sv.suggestedConnections.length ? sv.suggestedConnections[0].path : null;
    const tip = path && (path.querySelector('title') || (path._svHit && path._svHit.querySelector('title')));
    return { title: tip ? tip.textContent : null, basis: path ? path.dataset.basis : null,
             toasts: [...document.querySelectorAll('.sideview-toast')].map(t => t.textContent) };
  })()"))
  expect_match(m$title, "Based on the first 50 rows", fixed = TRUE)
  expect_identical(m$basis, "preview")
  expect_true(any(grepl("Suggested joins: based on the first 50 rows.", unlist(m$toasts), fixed = TRUE)))

  # The gadget toolbar's Auto Map button asks R and always answers with a toast.
  sv_js(b, "document.querySelectorAll('.sideview-toast').forEach(t => t.remove())")
  sv_click(b, "document.querySelector('.sideview-toolbar [data-action=\"suggest-mappings\"]')")
  a <- sv_js(b, paste0("(async () => {", sv_lazy_helpers_js, "
    await until(() => document.querySelector('.sideview-toast'), 10000);
    return [...document.querySelectorAll('.sideview-toast')].map(t => t.textContent);
  })()"))
  expect_true(any(grepl("Suggested joins|No suggested joins found", unlist(a))))
  expect_length(attr(b, "sv_errors")(), 0)
})

test_that("a lost connection turns a full card into a preview card", {
  skip_if_no_browser()
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dbplyr")
  b <- sv_with_app('{
    con <- DBI::dbConnect(duckdb::duckdb())
    DBI::dbWriteTable(con, "big", data.frame(id = 1:200000, x = seq_len(200000) / 7))
    big <- dplyr::tbl(con, "big")
    app <- sideview(patients, big, run = FALSE)
    # the test can close the connection from the browser
    server <- app$serverFuncSource()
    app$serverFuncSource <- function() function(input, output, session) {
      server(input, output, session)
      shiny::observeEvent(input$kill_con, DBI::dbDisconnect(con, shutdown = TRUE))
    }
    app
  }')
  expect_true(attr(b, "sv_ready"))
  card <- sv_card_js("big")
  expect_identical(sv_js(b, sprintf("%s.dataset.rowsBasis", card)), "full")

  sv_js(b, "Shiny.setInputValue('kill_con', 1, { priority: 'event' }); true")
  Sys.sleep(1)
  btn <- sprintf("%s.querySelector('[data-action=\"sort-col\"][data-col-name=\"x\"]')", card)
  sv_click(b, btn)
  r <- sv_js(b, paste0("(async () => {", sv_lazy_helpers_js, sprintf("
    const c = %s;
    await until(() => c.dataset.rowsBasis === 'preview', 10000);
    const badge = c.querySelector('.sideview-badge:not(.sideview-badge-type)');
    const toasts = [...document.querySelectorAll('.sideview-toast')].map(t => t.textContent);
    return { basis: c.dataset.rowsBasis, badge: badge.textContent, toasts: toasts };
  })()", card)))
  expect_identical(r$basis, "preview")
  expect_identical(r$badge, "First 50 of 200,000 rows")
  expect_true(any(grepl("Lost the link to big; showing the first 50 rows.", unlist(r$toasts), fixed = TRUE)))

  # The inspector now carries the banner, and the app keeps answering.
  sv_click(b, sprintf("%s.querySelector('th[data-col-name=\"x\"] [data-action=\"inspect-col\"]')", card))
  n <- sv_js(b, paste0("(async () => {", sv_lazy_helpers_js, "
    await until(() => q('[data-pane=\"inspect\"] .sideview-basis-note'), 10000);
    return q('[data-pane=\"inspect\"] .sideview-basis-note').textContent;
  })()"))
  expect_identical(n, "Based on the first 50 rows")
  sv_shot(b, "lost-link-fallback")
  expect_length(attr(b, "sv_errors")(), 0)
})

test_that("a saved widget labels a lazy card as a preview and says so in the inspector", {
  skip_if_no_browser()
  skip_if_not_installed("arrow")
  env <- new.env()
  eval(parse(text = sv_fixture_code), envir = env)
  env$big <- arrow::arrow_table(id = 1:5000, x = seq_len(5000) / 8)
  env$wide <- data.frame(id = 1:12345)
  dir <- withr::local_tempdir()
  file <- file.path(dir, "lazy.html")
  w <- local(sideview_widget(patients, big, wide), envir = env)
  suppressMessages(save_sideview(w, file, selfcontained = FALSE))
  url <- paste0("file:///", gsub("\\\\", "/", normalizePath(file)))
  b <- sv_open_page(url, wait_for = "!!document.querySelector('.sideview-card .sideview-col-port')")
  withr::defer(try(b$close(), silent = TRUE))
  expect_true(attr(b, "sv_ready"))

  card <- sv_card_js("big")
  r <- sv_js(b, sprintf("(() => ({
    badge: %s.querySelector('.sideview-badge-dims').textContent,
    basis: %s.dataset.rowsBasis, rows: %s.dataset.tableRows,
    patients: %s.querySelector('.sideview-badge-dims').textContent,
    patientsBasis: %s.dataset.rowsBasis
  }))()", card, card, card, sv_card_js("patients"), sv_card_js("patients")))
  expect_identical(r$badge, "First 50 of 5,000 rows")
  expect_identical(r$basis, "preview")
  expect_identical(r$rows, "5000")
  expect_identical(r$patients, "200 \u00d7 4")                 # a data frame card is unchanged
  expect_identical(r$patientsBasis, "full")
  # a data frame card's badge has thousands separators (M4)
  expect_identical(sv_js(b, sprintf("%s.querySelector('.sideview-badge-dims').textContent", sv_card_js("wide"))),
                   "12,345 × 1")
  # an unknown row count (R NA, sent as null) shows "?", not "0"
  expect_identical(sv_js(b, "(() => { const eng = document.querySelector('.sideview-container')._sideviewInstance;
    eng.addCard({ id: 'unknown_rows', name: 'unknown_rows', dims: [null, 2], columns: [], data: {} }, 9);
    return document.querySelector('.sideview-card[data-card-id=\"unknown_rows\"] .sideview-badge-dims').textContent; })()"),
    "? × 2")

  # The codebook of a lazy card reports the whole table's size and the rows profiled (I4).
  csv <- sv_js(b, "(() => { const eng = document.querySelector('.sideview-container')._sideviewInstance;
    eng.exportCodebook(); return eng.lastCodebookCsv; })()")
  cb <- utils::read.csv(text = csv, stringsAsFactors = FALSE)
  expect_equal(cb$n[cb$table == "big"], c(5000, 5000))
  expect_equal(cb$rows_profiled[cb$table == "big"], c(50, 50))
  expect_equal(cb$n[cb$table == "patients"], rep(200, 4))
  expect_equal(cb$rows_profiled[cb$table == "patients"], rep(200, 4))

  sv_click(b, sprintf("%s.querySelector('th[data-col-name=\"x\"] [data-action=\"inspect-col\"]')", card))
  note <- sv_js(b, paste0("(async () => {", sv_lazy_helpers_js, "
    await until(() => q('.sideview-inspect-stats'), 8000);
    const n = q('[data-pane=\"inspect\"] .sideview-basis-note');
    return n ? n.textContent : null;
  })()"))
  expect_identical(note, "Based on the first 50 rows")

  # No note on a data frame card.
  sv_js(b, paste0("(async () => {", sv_lazy_helpers_js, "
    setVal(q('[data-pane=\"inspect\"] [data-inspect=\"table\"]'), 'patients'); await sleep(100); return true; })()"))
  none <- sv_js(b, paste0("(async () => {", sv_lazy_helpers_js, "
    await until(() => q('[data-pane=\"inspect\"] .sideview-inspect-stats'), 8000);
    return !q('[data-pane=\"inspect\"] .sideview-basis-note'); })()"))
  expect_true(none)
  expect_length(attr(b, "sv_errors")(), 0)
})
