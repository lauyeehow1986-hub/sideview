# Real-browser accessibility tests: the AX tree and the keyboard (spec section 9).

test_that("every control has an accessible name (canvas, all modes)", {
  skip_if_no_browser()
  for (mode in names(sv_a11y_pages())) {
    b <- sv_a11y_pages()[[mode]]$open(theme = "light", width = 1360, height = 820)
    bad <- sv_ax_unnamed(sv_ax_tree(b))
    expect_equal(nrow(bad), 0, info = paste(mode, paste(bad$role, collapse = ", ")))
    b$close()
  }
})

test_that("Tab reaches the toolbar, then the drawer tabs, in DOM order", {
  skip_if_no_browser()
  b <- sv_a11y_pages()$gadget$open("light", 1360, 820)
  # Cards come first in the DOM (about 40 stops), then the toolbar, then the drawer.
  seen <- vapply(1:80, function(i) { sv_tab(b); sv_focus_info(b)$name }, "")
  b$close()
  expect_true(any(grepl("Fit", seen)))
  expect_true(which(grepl("Fit", seen))[1] < which(grepl("Pipeline", seen))[1])
})
