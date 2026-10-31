# Fixtures for the date rules of joins (sideview 0.4.0), shared by test-diagnostics.R and test-lazy.R.

# Synthetic tables with ties, NA dates and NA keys; the date columns are Date, date-time or numeric.
rule_tables <- function(kind, seed) {
  set.seed(seed)
  conv <- function(v) switch(kind,
    Date = as.Date("2024-01-01") + v,
    `date-time` = as.POSIXct("2024-01-01", tz = "UTC") + v * 86400,
    numeric = as.numeric(v))
  nx <- 14L
  ny <- 20L
  vx <- sample(c(0:40, NA), nx, replace = TRUE)
  vy <- sample(c(0:40, NA), ny, replace = TRUE)
  x <- data.frame(id = sample(c(1:5, NA), nx, replace = TRUE), .i = seq_len(nx))
  x$xd <- conv(vx)
  x$xe <- conv(vx + sample(0:6, nx, replace = TRUE))
  y <- data.frame(id = sample(c(1:6, NA), ny, replace = TRUE))
  y$yd <- conv(vy)
  y$ys <- conv(vy)
  y$ye <- conv(vy + sample(0:6, ny, replace = TRUE))
  list(x = x, y = y, unit = if (kind == "date-time") 86400 else 1)
}

# One rule of each shape (three windows, both nearest matches with and without ties allowed).
rule_cases <- function() {
  list(
    list(shape = "between", xCol = "xd", yFrom = "ys", yTo = "ye"),
    list(shape = "overlaps", xFrom = "xd", xTo = "xe", yFrom = "ys", yTo = "ye"),
    list(shape = "window", xCol = "xd", yCol = "yd", from = -7, to = 7),
    list(shape = "window", xCol = "xd", yCol = "yd", from = 0, to = 3),
    list(shape = "window", xCol = "xd", yCol = "yd", from = -10, to = -2),
    list(shape = "before", xCol = "xd", yCol = "yd", inclusive = TRUE),
    list(shape = "before", xCol = "xd", yCol = "yd", inclusive = FALSE),
    list(shape = "after", xCol = "xd", yCol = "yd", inclusive = TRUE),
    list(shape = "after", xCol = "xd", yCol = "yd", inclusive = FALSE)
  )
}
