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

# One value as it is spoken: "missing" for NA or NaN; TRUE or FALSE for a logical; a number
# as format_key() writes it (up to 15 significant digits, no exponent, no thousands marks);
# a string as it is, wrapped in parentheses when it holds ", ".
sv_say_value <- function(v) {
  if (length(v) == 0L || is.na(v)) return("missing")
  if (is.logical(v)) return(if (v) "TRUE" else "FALSE")
  if (is.numeric(v)) return(format_key(v))
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
# at 6 significant digits. Not a number: NA gives "NA", other values their text.
sv_say_num <- function(v) {
  if (!is.numeric(v)) return(if (length(v) == 0L || is.na(v)) "NA" else as.character(v))
  if (is.finite(v) && v == round(v)) return(fmt_n(v))
  format_key(signif(v, 6))
}

# Check lines are kept whole: a line over 100 characters is not truncated (the tests
# report such lines so a long one is noticed, not cut).
sv_say_check_lines <- function(x) as.character(x)

# A sentence ends in ".", "!" or "?"; add a "." when it does not.
sv_say_sentence <- function(s) {
  s <- as.character(s)
  ifelse(grepl("[.!?]$", s), s, paste0(s, "."))
}

# A join check as plain sentences (twin of sayJoin() in sv-pipeline.js). `d` is the result of
# sv_join_diagnostics() or an `{error}` list. A count of a table's rows is "<n> NAME rows".
sv_say_join <- function(d, x_name = "x", y_name = "y") {
  if (!is.null(d$error)) return(paste0("Join check failed: ", sv_say_sentence(d$error)))
  X <- x_name
  Y <- y_name
  by <- d$by
  key <- sv_say_list(ifelse(by$x == by$y, by$x, paste0(by$x, " = ", by$y)))
  out <- paste0("Join of ", X, " and ", Y, " by ", key, " is ", gsub("-", " ", d$relationship, fixed = TRUE), ".")
  if (!is.null(d$rule)) {
    out <- c(out, paste0("Date rule: ", sv_join_rule_label(d$rule, d$rule_kind), "."))
    if (d$rule_dropped_x + d$rule_dropped_y > 0) {
      out <- c(out, paste0("The rule drops ", sv_say_num(d$rule_dropped_x), " ", X, " rows and ",
                           sv_say_num(d$rule_dropped_y), " ", Y, " rows."))
    }
  }
  match_line <- function(m, n, nm) {
    pct <- sv_say_pct(m, n)
    paste0(sv_say_num(m), " of ", sv_say_num(n), " ", nm, " rows match", if (!is.na(pct)) paste0(", ", pct), ".")
  }
  out <- c(out, match_line(d$matched_x, d$n_x, X), match_line(d$matched_y, d$n_y, Y))
  miss_line <- function(n, matched, dup, samples, nm) {
    k <- n - matched
    if (k <= 0) return(character())
    eg <- if (length(samples) == 0L) "" else if (dup == 0) {
      paste0(", for example ", sv_say_samples(samples, total = k))
    } else {
      paste0(", for example keys ", sv_say_samples(samples))
    }
    paste0(sv_say_num(k), " ", nm, " rows have no match", eg, ".")
  }
  out <- c(out, miss_line(d$n_x, d$matched_x, d$dup_keys_x, d$unmatched_x, X),
           miss_line(d$n_y, d$matched_y, d$dup_keys_y, d$unmatched_y, Y))
  if (d$na_x > 0) out <- c(out, paste0(sv_say_num(d$na_x), " ", X, " rows have a missing key."))
  if (d$na_y > 0) out <- c(out, paste0(sv_say_num(d$na_y), " ", Y, " rows have a missing key."))
  types <- c(left = "left_join", inner = "inner_join", right = "right_join", full = "full_join",
             semi = "semi_join", anti = "anti_join")
  parts <- character()
  for (nm in names(types)) {
    v <- d$rows[[types[[nm]]]]
    if (!is.null(v) && !is.na(v)) parts <- c(parts, paste0(nm, " ", sv_say_num(v)))
  }
  out <- c(out, paste0("Rows by join type: ", paste(parts, collapse = ", "), "."))
  for (h in d$hints) {
    gain <- c(if (h$extra_x > 0) paste0(sv_say_num(h$extra_x), " more ", X, " rows"),
              if (h$extra_y > 0) paste0(sv_say_num(h$extra_y), " more ", Y, " rows"))
    out <- c(out, paste0(toupper(substr(h$label, 1L, 1L)), substring(h$label, 2L), " would match ",
                         paste(gain, collapse = " and "), "."))
  }
  c(out, sv_say_sentence(unlist(c(d$type_issues, d$warnings))))
}
