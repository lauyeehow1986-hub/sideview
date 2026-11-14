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
