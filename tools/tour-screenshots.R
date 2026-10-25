# Capture the screenshots for vignettes/articles/tour.Rmd with headless Chrome.
# Needs chromote, callr, pkgload, magick and Chrome. Synthetic data only.
# Usage: Rscript tools/tour-screenshots.R . vignettes/articles/tour [shot names...]
# then copy tour/overview.png to man/figures/overview.png for the README.
args <- commandArgs(TRUE)
root <- normalizePath(args[1], winslash = "/")
out <- args[2]
only <- args[-(1:2)]
dir.create(out, showWarnings = FALSE, recursive = TRUE)
`%||%` <- function(a, b) if (is.null(a)) b else a

fixture <- '
set.seed(2026)
n <- 240
patients <- data.frame(
  patient_id = sprintf("P%04d", seq_len(n)),
  sex = sample(c("Male", "Female", "male", "F", "M", NA), n, TRUE, prob = c(.4, .4, .05, .06, .06, .03)),
  age = round(rnorm(n, 57, 13)),
  site = sample(c("North", "South", "East", "West"), n, TRUE),
  enrolled = as.Date("2025-01-06") + sample(0:300, n, TRUE),
  stringsAsFactors = FALSE
)
visits <- data.frame(
  visit_id = seq_len(720),
  pid = sample(c(patients$patient_id, " P0001", "p0002", "P9999"), 720, TRUE),
  visit = sample(c("Baseline", "Week 4", "Week 12"), 720, TRUE),
  sbp = round(rnorm(720, 132, 17)),
  dbp = round(rnorm(720, 81, 10)),
  stringsAsFactors = FALSE
)
labs <- data.frame(
  patient_id = sample(patients$patient_id, 6000, TRUE),
  test = sample(c("HbA1c", "LDL", "eGFR", "CRP"), 6000, TRUE),
  value = round(rlnorm(6000, 1.5, 0.6), 2),
  stringsAsFactors = FALSE
)
adverse_events <- data.frame(
  patient_id = sample(patients$patient_id, 150, TRUE),
  term = sample(c("Headache", "Nausea", "Dizziness", "Fatigue", "Rash"), 150, TRUE),
  grade = sample(1:3, 150, TRUE, prob = c(.6, .3, .1)),
  serious = sample(c(TRUE, FALSE), 150, TRUE, prob = c(.1, .9)),
  stringsAsFactors = FALSE
)
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
cards <- list(sv_normalize(patients, name = "patients"), sv_normalize(visits, name = "visits"),
              sv_normalize(labs, name = "labs"), sv_normalize(adverse_events, name = "adverse_events"))
shiny::shinyApp(sideview_ui(cards, title = "Sideview Canvas", gadget = TRUE, theme = sideview:::sv_resolve_theme("light")),
                sideview_server(cards, gadget = TRUE, llm_fn = mock_llm, run_env = new.env()))
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

connect <- "
  fire(card('patients').querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(200);
  fire(card('visits').querySelector('.sideview-col-port[data-col-name=\"pid\"]')); await sleep(300);
  await until(() => q('.sideview-step-diag.is-ok, .sideview-step-diag.is-warn, .sideview-step-diag.is-error'), 8000);
  await sleep(300); toasts();
"

if (want("overview")) { reset(); shot("overview") }

if (want("join")) {
  reset()
  run(paste0(connect, "
    fire(card('patients').querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(200);
    fire(card('labs').querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(600);
    fire(card('patients').querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(200);
    fire(card('adverse_events').querySelector('.sideview-col-port[data-col-name=\"patient_id\"]')); await sleep(900);
    closeDrawer(); toasts(); return 1;"))
  shot("join")
}

if (want("joincheck")) {
  reset()
  run(paste0(connect, "openDrawer(); tab('discrepancy'); await sleep(2500); toasts(); return 1;"))
  shot("joincheck", crop = "drawer")
}

if (want("filter")) {
  reset()
  run("card('labs').querySelector('[data-action=\"sort-col\"][data-col-name=\"value\"]').click(); await sleep(600);
       card('patients').querySelector('[data-action=\"filter-col\"][data-col-name=\"age\"]').click(); await sleep(300);
       const pop = q('.sideview-filter-popover');
       setVal(pop.querySelector('.sideview-filter-select'), 'gt');
       setVal(pop.querySelector('.sideview-filter-input'), '50'); toasts(); return 1;")
  shot("filter", crop = c(0, 70, 760, 560))
}

if (want("pipeline")) {
  reset()
  run(paste0("card('labs').querySelector('[data-action=\"sort-col\"][data-col-name=\"value\"]').click(); await sleep(600);
       card('patients').querySelector('[data-action=\"filter-col\"][data-col-name=\"age\"]').click(); await sleep(300);
       const pop = q('.sideview-filter-popover');
       setVal(pop.querySelector('.sideview-filter-select'), 'gt');
       setVal(pop.querySelector('.sideview-filter-input'), '50');
       pop.querySelector('.sideview-filter-apply').click(); await sleep(700);", connect,
       "openDrawer(); tab('pipeline'); await sleep(400); toasts(); return 1;"))
  shot("pipeline", crop = "drawer")
}

if (want("inspect")) {
  reset()
  p <- run("const btn = card('labs').querySelector('th[data-col-name=\"value\"] [data-action=\"inspect-col\"]');
            const r = btn.getBoundingClientRect(); return {x: r.x + r.width / 2, y: r.y + r.height / 2};")
  click_at(p$x, p$y); Sys.sleep(1.5)
  run("toasts(); return 1;")
  shot("inspect", crop = "drawer")
}

if (want("search")) {
  reset()
  key("k", "KeyK", 75, modifiers = 2); Sys.sleep(0.3)
  b$Input$insertText(text = "pat"); Sys.sleep(0.4)
  shot("search")
  key("Escape", "Escape", 27)
}

if (want("copilot")) {
  reset()
  run("openDrawer(); tab('chat'); await sleep(200);
       const inp = q('#sideview-chat-input'); setVal(inp, 'Mean systolic BP by site for patients over 50');
       q('.sideview-chat-send').click();
       await until(() => document.querySelectorAll('.sideview-chat-assistant').length > 1, 8000);
       await sleep(400); toasts(); return 1;")
  shot("copilot", crop = "drawer")
}

if (want("shortcuts")) {
  reset()
  key("?", "Slash", 191, modifiers = 8); Sys.sleep(0.4)
  shot("shortcuts")
  key("Escape", "Escape", 27)
}

if (want("dark")) {
  reset()
  run(paste0(connect, "q('[data-action=\"toggle-theme\"]').click(); await sleep(400); toasts(); return 1;"))
  shot("dark")
  run("q('[data-action=\"toggle-theme\"]').click(); return 1;")
}

errs <- proc$read_error()
if (nzchar(errs)) cat("APP STDERR:\n", substr(errs, 1, 3000), "\n")
b$close()
