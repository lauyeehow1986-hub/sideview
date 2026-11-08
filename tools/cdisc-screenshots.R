# Capture the CDISC screenshots for vignettes/articles/cdisc.Rmd with headless Chrome.
# Needs chromote, callr, pkgload, magick and Chrome. Synthetic data only.
# Usage: Rscript tools/cdisc-screenshots.R . vignettes/articles/cdisc [shot names...]
args <- commandArgs(TRUE)
root <- normalizePath(args[1], winslash = "/")
out <- args[2]
only <- args[-(1:2)]
dir.create(out, showWarnings = FALSE, recursive = TRUE)
`%||%` <- function(a, b) if (is.null(a)) b else a

fixture <- '
n <- 12
sid <- rep("SV-001", n)
usub <- paste0("SV-001-", sprintf("%03d", seq_len(n)))
dm <- data.frame(STUDYID = sid, DOMAIN = "DM", USUBJID = usub, SUBJID = sprintf("%03d", seq_len(n)),
                 AGE = c(34, 51, 62, 45, 58, 39, 47, 66, 53, 41, 60, 36),
                 SEX = rep(c("F", "M"), 6), ARM = rep(c("Drug A", "Placebo"), each = 6), stringsAsFactors = FALSE)
attr(dm$USUBJID, "label") <- "Unique Subject Identifier"
attr(dm$AGE, "label") <- "Age"
attr(dm, "label") <- "Demographics"
who <- usub[c(1, 2, 3, 3, 5, 7, 8, 11)]
seqs <- c(1, 1, 1, 2, 1, 1, 1, 1)
ae <- data.frame(STUDYID = "SV-001", DOMAIN = "AE", USUBJID = who, AESEQ = seqs,
                 AETERM = c("Headache", "Nausea", "Rash", "Cough", "Dizziness", "Fatigue", "Nausea", "Headache"),
                 AEDECOD = c("HEADACHE", "NAUSEA", "RASH", "COUGH", "DIZZINESS", "FATIGUE", "NAUSEA", "HEADACHE"),
                 AESEV = c("MILD", "MODERATE", "MILD", "SEVERE", "MILD", "MODERATE", "MILD", "MILD"),
                 AESTDTC = c("2024-01-02", "2024-01-05", "2024-02-01", "2024-02-09", "2024-02-11", "2024-03-02", "2024-03-05", "2024-03-18"),
                 stringsAsFactors = FALSE)
attr(ae$AETERM, "label") <- "Reported Term for the Adverse Event"
attr(ae, "label") <- "Adverse Events"
suppae <- data.frame(STUDYID = "SV-001", RDOMAIN = "AE", USUBJID = rep(who, 2),
                     IDVAR = "AESEQ", IDVARVAL = as.character(rep(seqs, 2)),
                     QNAM = rep(c("AETRTEM", "AESOSP"), each = 8),
                     QLABEL = rep(c("Treatment Emergent", "Serious Outcome Specified"), each = 8),
                     QVAL = c("Y", "Y", "N", "Y", "Y", "Y", "N", "Y", "N", "N", "N", "Y", "N", "N", "N", "N"),
                     stringsAsFactors = FALSE)
adsl <- data.frame(STUDYID = "SV-001", USUBJID = usub, TRT01P = rep(c("Drug A", "Placebo"), each = 6),
                   AGE = dm$AGE, SAFFL = "Y", stringsAsFactors = FALSE)
'

app_expr <- '
mock_llm <- function(prompt, ...) paste0(
  "Mean systolic BP by site, for patients over 50. Only column names and types were sent, never the rows.\\n\\n",
  "```r\\n",
  "patients %>%\\n",
  "  dplyr::filter(age > 50) %>%\\n",
  "  dplyr::inner_join(visits, by = c(patient_id = \\"pid\\")) %>%\\n",
  "  dplyr::group_by(site) %>%\\n",
  "  dplyr::summarise(mean_sbp = mean(sbp), n = dplyr::n())\\n",
  "```\\n")
cards <- list(sv_normalize(dm, name = \"dm\"), sv_normalize(ae, name = \"ae\"),
              sv_normalize(suppae, name = \"suppae\"), sv_normalize(adsl, name = \"adsl\"))
cards <- sideview:::sv_cdisc_finalize(cards)
shiny::shinyApp(sideview_ui(cards, title = "Sideview Canvas", gadget = TRUE, theme = sideview:::sv_resolve_theme("light")),
                sideview_server(cards, gadget = TRUE, run_env = new.env()))
'

port <- httpuv::randomPort()
proc <- callr::r_bg(function(root, fixture, app_expr, port) {
  suppressMessages(pkgload::load_all(root, quiet = TRUE, export_all = FALSE))
  eval(parse(text = fixture), envir = globalenv())
  app <- eval(parse(text = app_expr), envir = globalenv())
  shiny::runApp(app, port = port, launch.browser = FALSE)
}, args = list(root, fixture, app_expr, port), stdout = "|", stderr = "|")
on.exit(proc$kill(), add = TRUE)
url <- sprintf("http://127.0.0.1:%d", port)
for (i in 1:160) {
  if (!proc$is_alive()) stop(proc$read_all_error())
  ok <- tryCatch({ con <- url(url); on.exit(close(con), add = TRUE); length(readLines(con, 1, warn = FALSE)) > 0 },
                 error = function(e) FALSE)
  if (isTRUE(ok)) break
  Sys.sleep(0.25)
}

W <- 1360; H <- 820
b <- chromote::ChromoteSession$new(width = W, height = H)
b$Emulation$setDeviceMetricsOverride(width = W, height = H, deviceScaleFactor = 1.5, mobile = FALSE)
js <- function(expr) {
  r <- b$Runtime$evaluate(expr, returnByValue = TRUE, awaitPromise = TRUE)
  if (!is.null(r$exceptionDetails)) stop("JS: ", r$exceptionDetails$exception$description %||% r$exceptionDetails$text)
  r$result$value
}
b$Page$navigate(url, wait_ = FALSE); b$Page$loadEventFired()
for (i in 1:80) { if (isTRUE(tryCatch(js("window.sideviewInitialized === true"), error = function(e) FALSE))) break; Sys.sleep(0.25) }
Sys.sleep(1.5)

key <- function(k, code, vk, modifiers = 0) {
  b$Input$dispatchKeyEvent(type = "rawKeyDown", key = k, code = code, windowsVirtualKeyCode = vk, modifiers = modifiers)
  b$Input$dispatchKeyEvent(type = "keyUp", key = k, code = code, windowsVirtualKeyCode = vk, modifiers = modifiers)
}
click_at <- function(x, y) for (t in c("mouseMoved", "mousePressed", "mouseReleased"))
  b$Input$dispatchMouseEvent(type = t, x = x, y = y, button = "left", clickCount = if (t == "mouseMoved") 0 else 1)
shot <- function(name, crop = NULL) {
  Sys.sleep(0.6)
  png <- b$Page$captureScreenshot(format = "png")$data
  img <- magick::image_read(jsonlite::base64_dec(png))
  if (identical(crop, "drawer")) crop <- c(W - 860, 0, 860, H)
  if (!is.null(crop)) img <- magick::image_crop(img, magick::geometry_area(crop[3] * 1.5, crop[4] * 1.5, crop[1] * 1.5, crop[2] * 1.5))
  img <- magick::image_quantize(img, max = 256, dither = FALSE)
  magick::image_write(img, file.path(out, paste0(name, ".png")), format = "png")
  cat("saved", name, "
")
}

H_JS <- "
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const sv = window._sideviewInstance;
  const q = s => document.querySelector(s);
  const card = n => [...document.querySelectorAll('.sideview-card')].find(c => c.getAttribute('data-card-name') === n);
  const fire = el => { const x = el.getBoundingClientRect(); ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(t => el.dispatchEvent(new MouseEvent(t, {bubbles: true, button: 0, clientX: x.x + 2, clientY: x.y + 2}))); };
  const setVal = (el, v) => { el.value = v; el.dispatchEvent(new Event('input', {bubbles: true})); el.dispatchEvent(new Event('change', {bubbles: true})); };
  const tab = name => q('.sideview-drawer-tabs [data-tab=\"' + name + '\"]').click();
  const until = async (f, ms) => { for (let t = 0; t < ms; t += 50) { if (f()) return true; await sleep(50); } return false; };
  const openDrawer = () => { const d = q('.sideview-drawer'); if (d.classList.contains('collapsed')) q('[data-action=\"toggle-drawer\"]').click(); };
  const closeDrawer = () => { const d = q('.sideview-drawer'); if (!d.classList.contains('collapsed')) q('[data-action=\"toggle-drawer\"]').click(); };
  const toasts = () => document.querySelectorAll('.sideview-toast').forEach(t => t.remove());
"
run <- function(body) js(paste0("(async () => {", H_JS, body, "})()"))
reset <- function() {
  run("q('[data-action=\"clear-operation\"]').click(); await sleep(300);
       document.querySelectorAll('.sideview-filter-popover, .sideview-search-scrim, .sideview-shortcuts-scrim').forEach(e => e.remove());
       closeDrawer(); toasts(); return 1;")
  js("(() => { document.activeElement && document.activeElement.blur(); return 1; })()")
  key("f", "KeyF", 70); Sys.sleep(0.6)
}
want <- function(n) !length(only) || n %in% only


if (want("canvas")) { reset(); shot("canvas") }

if (want("automap")) {
  reset()
  run("q('[data-action=\"suggest-mappings\"]').click(); await sleep(1500); toasts(); return 1;")
  shot("automap")
}

if (want("merge")) {
  reset()
  p <- run("const r = card('suppae').querySelector('[data-action=\"supp-merge\"]').getBoundingClientRect(); return {x: r.x + r.width / 2, y: r.y + r.height / 2};")
  click_at(p$x, p$y); Sys.sleep(2.5)
  run("openDrawer(); tab('pipeline'); await sleep(2500); toasts(); return 1;")
  shot("merge", crop = "drawer")
}

if (want("mergecheck")) {
  reset()
  p <- run("const r = card('suppae').querySelector('[data-action=\"supp-merge\"]').getBoundingClientRect(); return {x: r.x + r.width / 2, y: r.y + r.height / 2};")
  click_at(p$x, p$y); Sys.sleep(2.5)
  run("openDrawer(); tab('discrepancy'); await sleep(2500); toasts(); return 1;")
  shot("mergecheck", crop = "drawer")
}

errs <- proc$read_error()
if (nzchar(errs)) cat("APP STDERR:\n", substr(errs, 1, 3000), "\n")
b$close()
