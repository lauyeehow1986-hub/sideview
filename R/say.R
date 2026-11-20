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

# "1 row of NAME" or "N rows of NAME" (twin of sayRows).
sv_say_rows <- function(n, nm) paste0(sv_say_num(n), if (n == 1) " row of " else " rows of ", nm)

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
    paste0(sv_say_rows(k, nm), if (k == 1) " has" else " have", " no match", eg, ".")
  }
  out <- c(out, miss_line(d$n_x, d$matched_x, d$dup_keys_x, d$unmatched_x, X),
           miss_line(d$n_y, d$matched_y, d$dup_keys_y, d$unmatched_y, Y))
  if (d$na_x > 0) out <- c(out, paste0(sv_say_rows(d$na_x, X), if (d$na_x == 1) " has" else " have", " a missing key."))
  if (d$na_y > 0) out <- c(out, paste0(sv_say_rows(d$na_y, Y), if (d$na_y == 1) " has" else " have", " a missing key."))
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

# "1 row has" / "N rows have" for a count of NAME's rows: `one` and `many` are the verb phrases.
sv_say_n_rows <- function(n, nm, one, many) {
  paste0(sv_say_num(n), " ", nm, if (n == 1) paste0(" row ", one) else paste0(" rows ", many))
}

# One "USUBJID IDVAR IDVARVAL" per sample row; an empty or missing part is left out.
sv_say_supp_samples <- function(s) {
  if (is.null(s) || NROW(s) == 0L) return(character())
  vapply(seq_len(nrow(s)), function(i) {
    parts <- as.character(c(s$USUBJID[i], s$IDVAR[i], s$IDVARVAL[i]))
    paste(parts[!is.na(parts) & nzchar(parts)], collapse = " ")
  }, "")
}

# A SUPP merge check as plain sentences (twin of saySupp() in sv-pipeline.js). `chk` is the
# result of sv_supp_check() or an `{error}` list; S is the SUPP table name and P the parent.
sv_say_supp <- function(chk, parent_name = chk$parent_name %||% "parent",
                        supp_name = chk$supp_name %||% "supp") {
  if (!is.null(chk$error)) return(paste0("SUPP check failed: ", sv_say_sentence(chk$error)))
  S <- supp_name
  P <- parent_name
  cols <- vapply(chk$columns, function(c) as.character(c$name), "")
  nc <- length(cols)
  out <- paste0("Merging ", S, " into ", P, " adds ", sv_say_num(nc), if (nc == 1) " column" else " columns",
                if (nc > 0) paste0(": ", sv_say_list(cols)), ".")
  out <- c(out, paste0(sv_say_num(chk$n_matched), " of ", sv_say_num(chk$n_supp), " ", S,
                       " rows match a ", P, " row."))
  if (chk$n_orphan > 0) {
    eg <- sv_say_supp_samples(chk$orphan_samples)
    out <- c(out, paste0(sv_say_n_rows(chk$n_orphan, S, paste0("has no ", P, " row"),
                                       paste0("have no ", P, " row")),
                         if (length(eg)) paste0(", for example ", sv_say_samples(eg, total = chk$n_orphan)), "."))
  }
  if (chk$bad_idvarval$n > 0) {
    eg <- sv_say_supp_samples(chk$bad_idvarval$samples)
    out <- c(out, paste0(sv_say_n_rows(chk$bad_idvarval$n, S, "has an IDVARVAL that does not convert",
                                       "have an IDVARVAL that does not convert"),
                         if (length(eg)) paste0(", for example ", sv_say_samples(eg, total = chk$bad_idvarval$n)), "."))
  }
  if (chk$n_other_rdomain > 0) {
    out <- c(out, paste0(sv_say_n_rows(chk$n_other_rdomain, S, "is for another domain and is left out",
                                       "are for another domain and are left out"), "."))
  }
  if (chk$repeats$n > 0) {
    out <- c(out, paste0(sv_say_n_rows(chk$repeats$n, S, paste0("repeats a QNAM for the same ", P, " row"),
                                       paste0("repeat a QNAM for the same ", P, " row")), "."))
  }
  if (length(chk$clashes)) {
    out <- c(out, paste0("These QNAMs clash with ", P, " columns: ", sv_say_list(chk$clashes), "."))
  }
  if (length(chk$two_level)) {
    out <- c(out, paste0("These QNAMs use more than one IDVAR: ", sv_say_list(chk$two_level), "."))
  }
  if (isTRUE(chk$drift$stale)) {
    out <- c(out, paste0("Merge needs refreshing: ", sv_say_list(chk$drift$reasons), "."))
  }
  out
}

# A column profile as plain sentences (twin of sayProfile() in sv-pipeline.js). `name` is the
# column name; the label, when there is one, follows it after a comma.
sv_say_profile <- function(p, name = p$name %||% "Column") {
  lab <- p$label
  nl <- if (is.character(lab) && length(lab) == 1L && !is.na(lab) && nzchar(lab)) paste0(name, ", ", lab) else name
  word <- switch(p$kind, numeric = "number", character = "text", logical = "true or false",
                 date = "date", datetime = "date-time", p$class %||% "other")
  out <- paste0(nl, " is a ", word, " column.")
  out <- c(out, if (p$n_missing == 0) "No values are missing." else {
    paste0(sv_say_num(p$n_missing), " of ", sv_say_num(p$n), " values are missing, ",
           sv_say_pct(p$n_missing, p$n), ".")
  })
  out <- c(out, paste0("It has ", sv_say_num(p$n_distinct),
                       if (p$n_distinct == 1) " distinct value." else " distinct values."))
  if (isTRUE(p$unique_key)) out <- c(out, "Every value is unique, so it can be a key.")
  st <- p$stats
  if (p$kind == "numeric" && !is.null(st)) {
    out <- c(out, paste0("Minimum ", sv_say_num(st$min), ", median ", sv_say_num(st$median),
                         ", maximum ", sv_say_num(st$max), "."),
             paste0("Mean ", sv_say_num(st$mean), ", standard deviation ", sv_say_num(st$sd), "."))
  } else if (p$kind %in% c("date", "datetime") && !is.null(st)) {
    out <- c(out, paste0("Earliest ", st$min, ", latest ", st$max, "."))
  }
  top <- p$top
  if (p$kind != "numeric" && NROW(top) > 0L) {
    shown <- utils::head(seq_len(nrow(top)), 5L)
    out <- c(out, paste0("Most common values: ",
                         paste0(vapply(top$value[shown], sv_say_value, ""), " (",
                                vapply(top$n[shown], sv_say_num, ""), ")", collapse = ", "), "."))
    left <- p$n_other + (nrow(top) - length(shown))
    if (left > 0) {
      out <- c(out, paste0(sv_say_num(left), if (left == 1) " other value is" else " other values are", " not listed."))
    }
  }
  c(out, sv_say_sentence(as.character(unlist(p$issues))))
}

# "1 value matches" / "N values match": the verb phrases are for one and for many.
sv_say_n_values <- function(n, one, many) paste0(sv_say_num(n), if (n == 1) " value " else " values ", if (n == 1) one else many)

# The result of sv_detect_discrepancies() as plain sentences (R only; the browser has its own panel).
sv_say_discrepancies <- function(d) {
  st <- d$stats
  only <- function(n, samples, nm) {
    paste0(sv_say_n_values(n, "is only in", "are only in"), " ", nm,
           if (n > 0 && length(samples)) paste0(", for example ", sv_say_samples(samples, total = n)), ".")
  }
  out <- c(paste0(sv_say_n_values(st$exact_count, "matches exactly", "match exactly"), "."),
           paste0(sv_say_n_values(st$fuzzy_count, "nearly matches", "nearly match"), "."),
           only(st$only_x_count, d$only_in_x, "x"), only(st$only_y_count, d$only_in_y, "y"))
  pct <- sv_say_pct(st$exact_count, st$unique_x)
  if (!is.na(pct)) out <- c(out, paste0("Match rate ", pct, "."))
  out
}

# The result of sv_suggest_mappings() as plain sentences (R only): a count, then one line per
# suggested join; the rows of a CDISC group name the group.
sv_say_mappings <- function(m) {
  m <- as.data.frame(m)
  n <- nrow(m)
  if (n == 0L) return("No suggested joins.")
  grp <- if ("group" %in% names(m)) m$group else rep(NA_character_, n)
  lines <- vapply(seq_len(n), function(i) {
    sv_say_sentence(paste0(if (!is.na(grp[i])) paste0("Group ", grp[i], ": "),
                           m$from_table[i], ".", m$from_col[i], " to ", m$to_table[i], ".", m$to_col[i],
                           ", confidence ", sprintf("%.2f", m$confidence[i]), ": ", m$reason[i]))
  }, "")
  c(paste0(sv_say_num(n), if (n == 1) " suggested join." else " suggested joins."), lines)
}

# The text of a derive offer button (R writes it). `kept` is the table whose rows are opened;
# `other` is the table it is compared with (not used in the label).
sv_say_derive_offer <- function(op, n, kept, other = NULL) {
  num <- sv_say_num(n)
  rows <- if (n == 1) " row" else " rows"
  switch(op,
    unmatched = paste0("Open ", num, " unmatched ", kept, rows, " as a card"),
    outside_window = paste0("Open ", num, " ", kept, rows, " outside the date window as a card"),
    supp_orphans = paste0("Open ", num, " orphan ", kept, rows, " as a card"),
    supp_bad_idvarval = paste0("Open ", num, " ", kept, rows, " with a bad IDVARVAL as a card"),
    stop(sprintf("Unknown derive op: %s", op), call. = FALSE))
}

# The status strings of one stack column (R writes them). `col` is a plan column, `plan` the stack plan.
sv_say_stack_status <- function(col, plan) {
  inp <- plan$inputs
  out <- character()
  present <- !is.na(col$types)
  fn <- c(lgl = "as.logical", int = "as.integer", num = "as.numeric", chr = "as.character",
          date = "as.Date", dttm = "as.POSIXct")
  if (any(!is.na(col$cast)) && !identical(col$target, "fct")) {
    out <- c(out, paste0("type differs -> ", fn[[col$target]] %||% "as.character"))
  } else if (identical(col$target, "fct") && isTRUE(col$levels_differ)) {
    out <- c(out, "factor levels joined")
  }
  labs <- col$labels[!is.na(col$labels)]
  if (length(unique(labs)) > 1L) {
    out <- c(out, paste0("label differs (", inp[which(!is.na(col$labels))[1]], " label kept)"))
  }
  if (!all(present)) {
    if (!is.na(col$near_miss_of)) {
      out <- c(out, paste0("near-miss for ", col$near_miss_of, "? (case)"))
    } else {
      out <- c(out, paste0("only in ", paste(inp[present], collapse = ", "),
                           " (NA in ", paste(inp[!present], collapse = ", "), ")"))
    }
  }
  zn <- col$zones[!is.na(col$zones)]
  if (length(unique(zn)) > 1L) {
    out <- c(out, paste0("time zone differs (", inp[which(!is.na(col$zones))[1]], " zone kept)"))
  }
  for (i in which(!is.na(col$na) & col$na > 0L)) {
    out <- c(out, if (col$na[i] == 1L) paste0("1 value in ", inp[i], " becomes NA")
                  else paste0(sv_say_num(col$na[i]), " values in ", inp[i], " become NA"))
  }
  if (!length(out)) "ok" else out
}

# The number of values a stack's casts turn into NA, and the columns that change type.
sv_say_stack_counts <- function(plan) {
  list(na = sum(unlist(lapply(plan$columns, function(c) c$na)), na.rm = TRUE),
       typed = sum(vapply(plan$columns, function(c) any(!is.na(c$cast)), NA)),
       near = sum(vapply(plan$columns, function(c) !is.na(c$near_miss_of), NA)))
}

# The summary lines of a stack check.
sv_say_stack_text <- function(plan) {
  n <- sv_say_stack_counts(plan)
  cols <- length(plan$columns) + 1L
  out <- paste0("Stack ", length(plan$inputs), " tables: ", sv_say_num(plan$n_rows),
                if (plan$n_rows == 1) " row, " else " rows, ", sv_say_num(cols),
                if (cols == 1L) " column." else " columns.")
  if (n$typed > 0L) {
    out <- c(out, paste0(sv_say_num(n$typed), if (n$typed == 1L) " column changes type" else " columns change type",
                         if (n$na > 0) paste0("; ", sv_say_n_values(n$na, "becomes NA", "become NA")), "."))
  } else if (n$na > 0) {
    out <- c(out, paste0(sv_say_n_values(n$na, "becomes NA", "become NA"), "."))
  }
  if (n$near > 0L) {
    out <- c(out, paste0(sv_say_num(n$near), if (n$near == 1L) " near-miss name left apart." else " near-miss names left apart."))
  }
  out
}

# The label of the Open button of a stack.
sv_say_stack_open <- function(plan) {
  n <- sv_say_stack_counts(plan)
  paste0("Open stacked card (", sv_say_num(plan$n_rows), if (plan$n_rows == 1) " row" else " rows",
         if (n$na > 0) paste0("; ", sv_say_n_values(n$na, "becomes NA", "become NA")), ")")
}
