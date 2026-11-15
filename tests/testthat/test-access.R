test_that("access defaults to the option and renders data-sv-access", {
  withr::local_options(sideview.access = NULL)
  expect_false(grepl("data-sv-access", as.character(sideview_ui(list(a = mtcars)))))
  expect_match(as.character(sideview_ui(list(a = mtcars), access = TRUE)), 'data-sv-access="true"', fixed = TRUE)
  withr::local_options(sideview.access = TRUE)
  expect_match(as.character(sideview_ui(list(a = mtcars))), 'data-sv-access="true"', fixed = TRUE)
  expect_match(as.character(sideviewUI("m")), 'data-sv-access="true"', fixed = TRUE)
})

test_that("the widget carries options$access from the option", {
  withr::local_options(sideview.access = TRUE)
  expect_true(sideview_widget(mtcars)$x$options$access)
  expect_false(sideview_widget(mtcars, options = list(access = FALSE))$x$options$access)
})

test_that("access must be TRUE or FALSE", {
  for (bad in list(NA, "yes", c(TRUE, FALSE), 1)) {
    expect_error(sideview_ui(list(a = mtcars), access = bad), "`access` must be TRUE or FALSE.", fixed = TRUE)
  }
})

test_that("an alt-text content declaration is preceded by a plain one (older Chromium drops the alt syntax)", {
  css_path <- system.file("www/sideview.css", package = "sideview")
  if (!nzchar(css_path)) css_path <- test_path("..", "..", "inst", "www", "sideview.css")
  skip_if_not(file.exists(css_path))
  css <- readLines(css_path, warn = FALSE)
  alt <- grep('content:[^;]*" */ *"', css)
  expect_gt(length(alt), 0)
  for (i in alt) {
    expect_match(css[i], 'content: *"[^"]*"; *content:', info = css[i])
  }
})
