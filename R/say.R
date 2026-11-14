# Plain-sentence helpers for text-first output. Each has a JS twin in
# inst/www/sv-pipeline.js (sayPct, sayList, saySamples, sayValue, sayNum, sayCheckLines);
# test-say.R holds them to each other byte for byte.

# "93.3 percent". Integer arithmetic so half rounds up exactly; NA when den is 0.
sv_say_pct <- function(num, den) {
  if (is.na(den) || den == 0) return(NA_character_)
  tenths <- floor((2000 * num + den) / (2 * den))
  paste0(tenths %/% 10, ".", tenths %% 10, " percent")
}

# "A", "A and B", "A, B, and C"; "" when empty.
sv_say_list <- function(x) {
  x <- as.character(x)
  n <- length(x)
  if (n == 0L) return("")
  if (n == 1L) return(x)
  if (n == 2L) return(paste(x, collapse = " and "))
  paste0(paste(x[-n], collapse = ", "), ", and ", x[n])
}

# One value as it is spoken: missing, or the text; a value holding ", " is wrapped.
sv_say_value <- function(v) {
  if (length(v) == 0L || is.na(v)) return("missing")
  s <- as.character(v)
  if (grepl(", ", s, fixed = TRUE)) s <- paste0("(", s, ")")
  s
}

# The first `max` values, with "and N more" when `total` says there are more.
sv_say_samples <- function(x, total = NULL, max = 3) {
  shown <- vapply(utils::head(x, max), sv_say_value, "", USE.NAMES = FALSE)
  if (!is.null(total) && total > length(shown)) {
    return(paste0(paste(shown, collapse = ", "), ", and ", fmt_n(total - length(shown)), " more"))
  }
  sv_say_list(shown)
}

# A whole number with thousands separators; any other number as its codebook key text
# at 6 significant digits.
sv_say_num <- function(v) {
  if (is.finite(v) && v == round(v)) return(fmt_n(v))
  format_key(signif(v, 6))
}

# Check lines are kept whole: a line over 100 characters is not truncated (the tests
# report such lines so a long one is noticed, not cut).
sv_say_check_lines <- function(x) as.character(x)
