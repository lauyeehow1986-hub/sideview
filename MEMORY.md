# MEMORY.md — sideview change log & decision record

Running log of what changed, why, and how it was verified. Newest entries first.
Each entry: **date — change — why — verification**. Keep the "Open issues" table current.

---

## Open issues (from the 2026-10-24 code audit)

Status: `open` · `fixed` (with commit) · `wontfix`.

| # | Area | Issue | Status |
|---|------|-------|--------|
| 1 | CSS | Sticky `th` cancelled by a later `position: relative` (`sideview.css`) → headers and ports scroll away | fixed (Phase 2.1) |
| 2 | Card | Maximize uses `position: fixed` inside the transformed viewport → ~10000px card in the wrong place; no VirtualTable re-render | fixed (Phase 2.1) |
| 3 | Card | Minimize hides the body without redrawing connectors → splines jump to the origin | fixed (Phase 2.1) |
| 4 | Canvas | Fullscreen marks itself active even when the request fails (RStudio Viewer iframe) | fixed (Phase 2.1) |
| 5 | Layout | Toolbar, palette, drawer, AI bar and toast overlap in narrow windows; no responsive layout, no ResizeObserver | fixed (Phase 2.1) |
| 6 | Card | `resize: both` doesn't grow the 380px max-height body | fixed (Phase 2.1) |
| 7 | Perf | `updateConnectors` runs with no rAF; drag handlers bound 3–4× per move | fixed (Phase 2.1) |
| 8 | Popover | Filter popover appended to `body`, positioned once; doesn't follow pan/zoom/scroll; no vertical clamp | fixed (Phase 2.1) |
| 9 | CSS | Duplicate conflicting rules; undefined `--sv-radius-md`; missing `.sideview-toast-info` | fixed (Phase 2.1) |
| 10 | Widget | CSS sets `html, body {overflow: hidden !important}` and absolute container → breaks Quarto/Rmd pages; wheel hijacks page scroll; binding JS loaded twice; both dependencies named `sideview` | fixed (Phase 2.1) |
| 11 | Codegen | Sort generates `%>` instead of `%>%` | fixed (Phase 2.1) |
| 12 | JS | `initSideview('.sideview-container')` throws in strict mode (sets a property on a string) | fixed (Phase 2.1) |
| 13 | JS | Click-to-connect leaves a dangling draft after completing | fixed (Phase 2.1) |
| 14 | JS | `stopPropagation` between sibling delegated handlers has no effect → sort/filter clicks also highlight or connect | fixed (Phase 2.1) |
| 15 | Drawer | Join/Filter/Arrange/Mutate/Recode tabs all show the same pane; drawer re-opens on every update | open |
| 16 | Pipeline | Each operation overwrites the code; nothing composes | open |
| 17 | Data | Sort/filter run only on the ≤500-row HTML preview → wrong for big tables; numbers re-parsed from text | fixed (Phase 2.1) |
| 18 | State | `sv_load_state(launch = TRUE)` ignores the loaded state; `sideview()` has no `state` argument | open |
| 19 | Server | "Run in R" result is evaluated then thrown away | fixed (Phase 2.2) |
| 20 | Server | No `onSessionEnded → stopApp`; closing the browser tab leaves the console busy | fixed (Phase 2.2) |
| 21 | Gadget | "Cannot launch in external browser": reproduced. The browser opens, but the page is broken by #12 (init crash) and #26 (card width) | fixed (Phase 2.1–2.3; verified live in RStudio browser mode) |
| 22 | Security | Card and column names inserted unescaped into `innerHTML` and attribute selectors | fixed (Phase 2.1) |
| 23 | Icons | Emoji/Unicode glyph icons render inconsistently on Windows RStudio | open |
| 24 | Packaging | No `.Rbuildignore`; `panzoom.min.js` is an in-house stub labelled 4.5.1; README zoom range ≠ code | open |
| 25 | Tests | GUI suite uses a mock DOM, so layout is never exercised in a real browser | fixed (Phase 2.1) |
| 26 | Card | **Blocker:** cards have no width, so they shrink-wrap to the 10000px viewport (~9960px) and each column is ~900px; only the first column shows and numbers look empty | fixed (Phase 2.1) |
| 27 | Canvas | Zoom % label never updates; zoom isn't centred on the view | fixed (Phase 2.1) |
| 28 | Discrepancy | "undefined fuzzy": `fuzzy_matches` data.frame is serialised column-wise; fuzzy cells never highlight | fixed (Phase 2.1) |
| 29 | AI | LLM errors only appear as a code comment; missing model gives no toast or hint; no busy indicator | fixed (Phase 2.2) |
| 30 | Gadget | Closing the dialog raises Shiny's "User cancel" error → debugger under RStudio "Break on error"; no Done/Cancel | fixed (Phase 2.2) |
| 31 | Filter | Numeric operators offered for character columns | fixed (Phase 2.1) |
| 32 | AI | Default model `llama3.2` 404s when only a tagged build (`llama3.2:3b`) is installed | fixed (Phase 2.2) |
| 33 | AI | Reasoning models (qwen3) think for minutes → 180s timeout; error said only "Failed to perform HTTP request" | fixed (Phase 2.2) |
| 34 | AI | Small models can return R that does not parse; no warning | fixed (Phase 2.2) |
| 35 | Gadget | Browser mode: a page reload ends the only session → `stopApp` → the reloaded page can't reconnect | fixed (b8d2d8e) |
| 36 | JS | Real mouse clicks on a port while a draft spline is showing hit the draft SVG, not the port → connect fails (synthetic `dispatchEvent` tests passed) | fixed (b8d2d8e) |
| 37 | JS | Splines (z 25, above cards) swallow clicks on table cells/headers under them; a click on a spline over a card deleted the join | fixed (84bb482) |
| 38 | Assets | Dependency version was fixed at 0.2.0, so browsers served stale cached JS/CSS after an update | fixed (84bb482) |
| 39 | Gadget | Done with no operations returned the placeholder `# Connect two columns ...` as code | fixed (84bb482) |
| 40 | Layout | Initial cards are 640px wide but spaced 360px apart → they overlap on launch in every mode | open |
| 41 | Drawer | Code preview text is centred and truncated | open |
| 42 | Pane | In the narrow Viewer pane the toolbar covers card headers and the palette overlaps cards | open |

## Backlog (future rounds, not yet scheduled)
- Table version diff by key (data-lock comparisons between dataset versions).
- Validation rules (ranges, allowed values, ID uniqueness) exporting `pointblank`-style checks.
- PHI/PII column tagging that excludes tagged columns from the LLM schema context.
- Export the pipeline as a reproducible Quarto report.

---

## Log

### 2026-10-24 — Phase 2.3: bugs only a real browser found (RStudio browser mode + Claude in Chrome)
- **How:** launched `sideview(patients, visits, labs, viewer = "browser")` from the user's RStudio
  (R 4.5.1) and drove the page with real mouse input through Claude in Chrome. Five bugs had passed
  the mock-DOM and synthetic-event tests (#35–#39).
- **Reload (#35):** a per-app `sv_new_lifecycle()` counts sessions; `onSessionEnded` stops the app only
  after `getOption("sideview.session_grace", 5)` seconds with no session (via `later::later`), so a reload
  reconnects. `stop_gadget` runs once.
- **Connect (#36):** `portFromEvent()` / `portAtPoint()` look through the connector layer, and the draft
  spline has `pointer-events: none`.
- **Spline hit layer (#37):** visible splines are `pointer-events: none`. Invisible 14px hit paths live in
  `.sideview-connector-hitlayer` (z 5, *below* the cards at z 10), so splines are clickable over the canvas
  but never over a card. Hit paths forward hover (`is-hover`), click and context menu; `pruneHitPaths()` keeps
  them in step with connections.
- **Cache busting (#38):** `sv_asset_version()` = package version + md5 fingerprint of the JS/CSS
  (e.g. `0.2.0.6030027`), used by both the gadget and the widget dependency.
- **No-code (#39):** the placeholder is display text only. `sv_is_no_code()` (R) / `isNoCode()` (JS);
  Done returns `NULL`, and disconnect/clear send `""`.
- **Tests:** new real-mouse browser test (CDP `Input.dispatchMouseEvent`: connect, re-click, 59 points sampled
  along a spline over a card hit the card, canvas click disconnects); lifecycle multi-tab test;
  asset-version test. `devtools::test()` (with `NOT_CRAN=true`) → **1397 expectations, 0 failed, 0 errors**.
- **Verified live in RStudio browser mode:** reload keeps the app alive; click-to-connect; the filter popover
  opens under a spline without breaking the join; filter → Done returned `patients %>% dplyr::filter(age == 65)`;
  join → Done returned the join code; join → Clear → Done returned `NULL`; assets load from the versioned URL.
  Dialog and pane modes were checked in Phase 2.2.
- **Still open from this walk:** #40 card overlap on launch, #41 code preview alignment, #42 pane-mode overlap,
  and filter code replacing join code (#16, pipeline).

### 2026-10-24 — Phase 2.2: gadget lifecycle, Run in R, AI feedback, live LLM check
- **Gadget lifecycle:**
  - Toolbar **Done** returns the generated code (invisibly) from `sideview()`; **Cancel** returns `NULL`.
  - `runGadget(stopOnCancel = FALSE)`, plus a server handler for `input$cancel`, means closing the RStudio dialog no longer raises "User cancel".
  - `onSessionEnded` frees the console when the browser tab closes.
  - All of this is opt-in through `sideview_server(gadget = TRUE)`, so a multi-user Shiny app that embeds the server isn't stopped.
  - `stopApp` runs once, so a session end after Done keeps the returned code.
- **Run in R** keeps the value of the last expression as `sv_result` (or `assign_to`).
- **AI:**
  - Busy state on the AI bar and Copilot (`is-busy`, disabled Send showing "Thinking...", 180s safety reset).
  - `sideview_ai_status` toasts. Errors no longer overwrite the user's code; they carry a fix hint from `sv_llm_error_message()` (`ollama pull`, `ollama serve`, API key, installed models).
  - Code that doesn't parse gets a warning.
- **LLM client:**
  - Sends `think = false` to Ollama by default (`options(sideview.llm_think = TRUE)` to opt in).
  - Retries an untagged missing model with an installed tag.
  - Reports the underlying httr2 cause (timeout or refused).
  - Strips `<think>` blocks.
  - New exported `sv_llm_models()` lists Ollama or OpenAI-compatible models.
- **Live check (the user's local Ollama 0.40.10):**
  - Native `/api/chat` and OpenAI-compatible `/v1` both produce parseable, runnable dplyr code (qwen2.5-coder:7b, llama3.2:3b, qwen3:14b).
  - Driven end to end in headless Chrome: AI bar → busy → code → toast → Done → code returned to R.
  - The missing-model and unreachable-server cases show the hint toasts.
  - `qwen3:14b`: 180s timeout before, 15s after.
  - Repeatable test: `test-lifecycle.R` "live: ..." (skipped when no local Ollama; pick a model with `SIDEVIEW_TEST_OLLAMA_MODEL`).
- **Verification:** `devtools::test()` → **1372 expectations, 0 failed, 0 errors**. Closing the browser tab ends the R process.

### 2026-10-24 — Phase 2.1: layout, rendering and full-data sort/filter
- **Layout (CSS):**
  - `html, body` rules are scoped to `html.sv-standalone` (the gadget page), and the container is `position: relative`, so embedded widgets no longer lock page scroll.
  - Toolbar and palette sit in one wrapping `.sideview-topbar`.
  - The drawer and AI bar are placed from `--sv-topbar-h`/`--sv-aibar-h`; under 720px the drawer becomes a bottom sheet (`.sv-narrow`).
  - Toasts stack above the AI bar.
  - Sticky `th` restored; duplicate rules removed; `--sv-radius-md` and `.sideview-toast-info` defined.
- **Cards:**
  - Width is `max-content`, clamped to 320–640px (fixes the ~9,960px cards), then frozen after first layout (`sv-sized`) so `resize: both` grows the body.
  - Maximize moves the card into the untransformed `.sideview-overlay`.
  - Minimize collapses to the header and redraws the splines.
  - Fullscreen falls back to `sv-pseudo-fullscreen` when the API is blocked (RStudio Viewer).
- **Engine:**
  - Connector redraws are rAF-batched and driven by a ResizeObserver.
  - The zoom % label tracks the scale.
  - Connect has no phantom draft; one drag binding per press.
  - Explicit target checks replace the sibling `stopPropagation`.
  - `initSideview` no longer crashes in strict mode.
  - Card and column names are HTML-escaped and `CSS.escape`d in selectors.
  - Discrepancy payloads are normalised (data.frames arrive column-wise), so fuzzy counts and highlights work.
- **Full-data sort/filter (#17):**
  - Cards with more rows than the 500-row preview page from R. The client sends `sideview_rows_request` (offset/limit/sort/filter/version).
  - The server answers with `sv_rows_window()` (`R/rows.R`: radix order, NAs last, filter drops NA, matching `dplyr`), memoised per spec.
  - Stale versions are ignored. Requests made before Shiny connects are retried.
  - Sorting or filtering scrolls to the first row.
- **Filter popover:**
  - Lives in the overlay layer, follows pan/zoom/scroll and is clamped on both axes.
  - Text columns get text operators only; generated R code is quoted and escaped (`filterConditionCode` / `sv_filter_condition`).
- **Widget:** the binding JS is no longer loaded twice; `renderValue` destroys the previous engine; embedded mode zooms only on Ctrl/Cmd+wheel.
- **Tests:**
  - New `test-layout-browser.R` (real headless Chrome via chromote + callr: overlap at 3 window sizes, drawer fit, sticky headers, zoom label, connect, connector endpoints, maximize fit, full-data sort, discrepancy counts).
  - New `test-rows.R`, checked against `dplyr` and `testServer`.
- **Verification:** `node --check` on all JS. Browser harness 46/46. `devtools::test()` → **1326 expectations, 0 failed, 0 errors** (baseline 1236).
- **Still to do in Phase 2:** Done/Cancel and `onSessionEnded` (#20, #30), Run in R result (#19), AI error toasts (#29), drawer tabs (#15), SVG icons (#23), packaging renames (#24), RStudio re-walk.

### 2026-10-24 — Phase 1: QA audit (before fixes)
- **Change:** none to code. Added `plans/2026-10-24-ui-qa-checklist.md` (checklist + baseline results).
- **How:** drove RStudio 2025.05.1 (R 4.5.1) with computer use in dialog and browser modes, plus a
  DOM-level browser for the live session and the saved/embedded widget. Synthetic fixture only.
- **Root cause of "can't launch in external browser":** the browser *does* open. The page is broken:
  `initSideview()` crashes in strict mode (#12), and cards render ~9,960px wide (#26), so tables look
  empty. Closing also misbehaves: the browser tab never frees the console (#20), and the dialog
  drops into the debugger (#30).
- **New issues:** #26–#31.

### 2026-10-24 — Phase 0: tracking and baseline
- **Change:** added `CLAUDE.md` (project guide for Claude sessions), `MEMORY.md` (this file) and `.Rbuildignore`
  (excludes `plans/`, `docs/`, `pkgdown/`, `.github/`, `CLAUDE.md`, `MEMORY.md` from the built package).
- **Why:** start of the UI overhaul (plan: full RStudio QA → layout/functional fixes → polish → features).
- **Baseline:** `devtools::test()` → **1236 expectations, 0 failed / 0 skipped / 0 warnings / 0 errors**
  across 12 files (codegen 275, app 159, e2e 136, llm 103, normalize 100, features 91, assets 76,
  rstudio 71, state 68, computer-use-gui 64, widget 50, copilot 43). R 4.5.2.
  Available for real-browser tests: shinytest2 0.5.1, chromote 0.5.1, Chrome; Node v25.1.0.
- **Note:** `C:\Users\lauye\CLAUDE.md` (home folder) describes an unrelated de-identification project and
  is loaded into every Claude session under the home folder. Suggest moving it into that project's folder.
