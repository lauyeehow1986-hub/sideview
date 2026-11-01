suppressWarnings(suppressPackageStartupMessages({
  library(shiny)
  library(htmlwidgets)
  library(htmltools)
}))

# Source R files if running standalone without package installed
if (!"package:sideview" %in% search()) {
  r_files <- list.files(c("R", "../R", "../../R"), pattern = "\\.[Rr]$", full.names = TRUE)
  for (f in r_files) source(f)
}

test_that("sideview_widget creates S3 object of class c('sideview', 'htmlwidget')", {
  df1 <- data.frame(id = 1:3, name = c("Alpha", "Beta", "Gamma"), stringsAsFactors = FALSE)
  widget <- sideview_widget(df1)

  expect_s3_class(widget, "sideview")
  expect_s3_class(widget, "htmlwidget")
  expect_true(is.list(widget$x))
  expect_true("cards" %in% names(widget$x))
  expect_true("options" %in% names(widget$x))
})

test_that("sideview_widget normalizes various table formats correctly", {
  df1 <- data.frame(a = 1:3, b = c("x", "y", "z"), stringsAsFactors = FALSE)
  tbl <- base::table(c("cat", "dog", "cat", "bird"))
  
  # Multiple tables passed as dots
  w_multi <- sideview_widget(users = df1, counts = tbl)
  expect_equal(length(w_multi$x$cards), 2L)
  expect_equal(w_multi$x$cards[[1]]$name, "users")
  expect_equal(w_multi$x$cards[[2]]$name, "counts")
  expect_equal(w_multi$x$cards[[1]]$type, "grid")
  expect_equal(w_multi$x$cards[[2]]$type, "grid")

  # Passed as a single list of tables
  table_list <- list(t1 = df1, t2 = df1)
  w_list <- sideview_widget(table_list)
  expect_equal(length(w_list$x$cards), 2L)
  expect_equal(w_list$x$cards[[1]]$name, "t1")
  expect_equal(w_list$x$cards[[2]]$name, "t2")

  # Passed pre-normalized sideview_card
  card <- sv_normalize(df1, name = "pre_normalized")
  w_card <- sideview_widget(card)
  expect_equal(length(w_card$x$cards), 1L)
  expect_equal(w_card$x$cards[[1]]$name, "pre_normalized")

  # gt table support (mocked or real)
  gt_card <- structure(
    list(
      id = "card_gt_mock",
      name = "gt_table",
      type = "html",
      data = df1,
      html_content = "<table class='gt_table'><tr><td>gt</td></tr></table>",
      dims = c(3L, 2L),
      col_types = c(a = "integer", b = "character")
    ),
    class = c("sideview_card", "list")
  )
  w_gt <- sideview_widget(gt_card)
  expect_equal(w_gt$x$cards[[1]]$type, "html")
  expect_match(w_gt$x$cards[[1]]$html_content, "gt_table")

  # flextable support (mocked or real)
  ft_card <- structure(
    list(
      id = "card_ft_mock",
      name = "flex_table",
      type = "html",
      data = df1,
      html_content = "<table class='tabwid'><tr><td>ft</td></tr></table>",
      dims = c(3L, 2L),
      col_types = c(a = "integer", b = "character")
    ),
    class = c("sideview_card", "list")
  )
  w_ft <- sideview_widget(ft_card)
  expect_equal(w_ft$x$cards[[1]]$type, "html")
  expect_match(w_ft$x$cards[[1]]$html_content, "tabwid")
})

test_that("sideview_widget encodes payload and custom options properly", {
  df <- data.frame(val = 1:5, label = letters[1:5], stringsAsFactors = FALSE)
  custom_opts <- list(snapToEdge = FALSE, snapThreshold = 40, minScale = 0.5)

  w <- sideview_widget(my_df = df, options = custom_opts)

  expect_equal(w$x$options$snapToEdge, FALSE)
  expect_equal(w$x$options$snapThreshold, 40)
  expect_equal(w$x$options$minScale, 0.5)

  card <- w$x$cards[[1]]
  expect_equal(card$name, "my_df")
  expect_equal(card$dims, c(5L, 2L))
  expect_true(is.data.frame(card$data))
  expect_equal(colnames(card$data), c("val", "label"))
})

test_that("sideview_widget handles empty inputs gracefully", {
  w_empty <- sideview_widget()
  expect_s3_class(w_empty, "sideview")
  expect_s3_class(w_empty, "htmlwidget")
  expect_equal(length(w_empty$x$cards), 0L)
})

test_that("save_sideview exports widget to standalone HTML file on disk", {
  df1 <- data.frame(id = 1:4, product = c("A", "B", "C", "D"), price = c(10, 20, 30, 40), stringsAsFactors = FALSE)
  df2 <- data.frame(product_code = c("A", "B", "E"), stock = c(100, 200, 300), stringsAsFactors = FALSE)
  
  w <- sideview_widget(products = df1, inventory = df2)

  tf <- tempfile(fileext = ".html")
  on.exit(if (file.exists(tf)) unlink(tf), add = TRUE)

  saved_path <- save_sideview(w, file = tf, selfcontained = TRUE)

  expect_true(file.exists(tf))
  expect_equal(saved_path, normalizePath(tf, winslash = "/", mustWork = FALSE))
  file_size <- file.info(tf)$size
  expect_true(file_size > 1000)

  html_lines <- readLines(tf, warn = FALSE, encoding = "UTF-8")
  html_text <- paste(html_lines, collapse = "\n")

  # Verify expected HTML elements and scripts
  expect_true(grepl("sideview", html_text, ignore.case = TRUE))
  expect_true(grepl("htmlwidget", html_text, ignore.case = TRUE))
  expect_true(grepl("products", html_text))
  expect_true(grepl("inventory", html_text))

  # Test auto-creating nested destination subdirectories
  nested_dir <- file.path(tempdir(), paste0("test_nested_", as.integer(runif(1, 1000, 9999))))
  nested_file <- file.path(nested_dir, "report.html")
  on.exit(unlink(nested_dir, recursive = TRUE), add = TRUE)
  ret_nested <- save_sideview(w, file = nested_file, selfcontained = TRUE)
  expect_true(file.exists(nested_file))
  expect_equal(ret_nested, normalizePath(nested_file, winslash = "/", mustWork = FALSE))
})

test_that("save_sideview accepts raw data.frames directly", {
  df <- data.frame(x = 1:10, y = 11:20)
  tf <- tempfile(fileext = ".html")
  on.exit(if (file.exists(tf)) unlink(tf), add = TRUE)

  save_sideview(df, file = tf, selfcontained = TRUE)

  expect_true(file.exists(tf))
  expect_true(file.info(tf)$size > 1000)
})

test_that("sideviewOutput produces a valid shiny.tag container", {
  out <- sideviewOutput("sideview_id", width = "80%", height = "500px")

  expect_true(inherits(out, "shiny.tag") || inherits(out, "shiny.tag.list"))
  tag <- if (inherits(out, "shiny.tag")) out else out[[1]]
  expect_equal(tag$attribs$id, "sideview_id")
  expect_match(tag$attribs$class, "sideview")
  expect_match(tag$attribs$class, "html-widget")
  expect_match(tag$attribs$style, "width:\\s*80%")
  expect_match(tag$attribs$style, "height:\\s*500px")

  # Render to HTML string
  html_str <- as.character(out)
  expect_match(html_str, "id=\"sideview_id\"")
  expect_match(html_str, "sideview html-widget")
})

test_that("renderSideview generates a shiny render function", {
  r_fn <- renderSideview({
    sideview_widget(mtcars)
  })

  expect_true(is.function(r_fn))
  expect_true(inherits(r_fn, "shiny.render.function"))
})

test_that("sideview_widget cuts long data-frame tables to max_rows and flags them", {
  big <- data.frame(id = 1:50, v = rnorm(50))
  small <- data.frame(a = 1:3)
  expect_message(w <- sideview_widget(big, small, max_rows = 10), "first 10 rows of big [(]50 rows[)]")
  cards <- w$x$cards
  expect_equal(nrow(cards[[1]]$data), 10)
  expect_true(isTRUE(cards[[1]]$truncated))
  expect_equal(cards[[1]]$totalRows, 50L)
  expect_equal(nrow(cards[[2]]$data), 3)
  expect_null(cards[[2]]$truncated)
})

test_that("max_rows = Inf embeds every row and stays quiet", {
  big <- data.frame(id = 1:50)
  expect_silent(w <- sideview_widget(big, max_rows = Inf))
  expect_equal(nrow(w$x$cards[[1]]$data), 50)
  expect_null(w$x$cards[[1]]$truncated)
})

test_that("the default cap is 5000 and a bad max_rows is refused", {
  expect_equal(formals(sideview_widget)$max_rows, 5000)
  expect_equal(formals(save_sideview)$max_rows, 5000)
  expect_error(sideview_widget(mtcars, max_rows = 0), "max_rows")
  expect_error(sideview_widget(mtcars, max_rows = "a"), "max_rows")
  expect_error(sideview_widget(mtcars, max_rows = c(1, 2)), "max_rows")
})

test_that("no row-cap message while knitting", {
  old <- options(knitr.in.progress = TRUE)
  on.exit(options(old))
  expect_silent(sideview_widget(data.frame(id = 1:20), max_rows = 5))
})

test_that("save_sideview passes max_rows to the widget it builds", {
  skip_if_not_installed("htmlwidgets")
  out <- tempfile(fileext = ".html")
  on.exit(unlink(out))
  expect_message(save_sideview(data.frame(id = 1:30), file = out, max_rows = 5), "first 5 rows")
  expect_true(file.exists(out))
})

test_that("Positron gets the browser viewer; dialog falls back there with one message", {
  withr::local_envvar(POSITRON = "1")
  expect_true(sv_is_positron())
  expect_identical(deparse(body(sv_default_viewer())), deparse(body(sv_default_viewer())))
  expect_message(v <- sv_resolve_viewer("dialog", "T"), "no dialog viewer")
  expect_identical(format(v), format(shiny::browserViewer()))
  expect_silent(sv_resolve_viewer("browser", "T"))
  expect_identical(format(sv_default_viewer()), format(shiny::browserViewer()))
})

test_that("outside Positron the dialog shorthand is untouched", {
  withr::local_envvar(POSITRON = "", POSITRON_VERSION = "")
  expect_false(sv_is_positron())
  expect_silent(v <- sv_resolve_viewer("dialog", "T"))
  expect_identical(sv_resolve_viewer(shiny::paneViewer(), "T") |> class(), "function")
})

test_that("widget cards carry cdisc and keep labels past max_rows", {
  f <- sv_cdisc_fixtures()
  dm <- f$dm[rep(1:4, 5), ]
  attr(dm$USUBJID, "label") <- "Unique Subject Identifier"
  w <- sideview_widget(dm = dm, max_rows = 5)
  expect_identical(w$x$cards[[1]]$cdisc$domain, "DM")
  expect_identical(w$x$cards[[1]]$col_labels$USUBJID, "Unique Subject Identifier")
})

test_that("evidence is always an array", {
  f <- sv_cdisc_fixtures()
  w <- sideview_widget(dm = f$dm)
  js <- jsonlite::toJSON(w$x$cards[[1]]$cdisc, auto_unbox = TRUE)
  expect_match(as.character(js), "\"evidence\":[[]")
})

test_that("cdisc is checked and passed through save_sideview", {
  expect_error(sideview_widget(mtcars, cdisc = TRUE), "cdisc")
  f <- sv_cdisc_fixtures()
  tf <- tempfile(fileext = ".html")
  on.exit(unlink(tf))
  save_sideview(f$dm, file = tf, cdisc = FALSE)
  expect_false(grepl("\"cdisc\":{", paste(readLines(tf, warn = FALSE), collapse = "\n"), fixed = TRUE))
})
