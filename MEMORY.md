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
| 15 | Drawer | Join/Filter/Arrange/Mutate/Recode tabs all show the same pane; drawer re-opens on every update | fixed (Phase 4.1) |
| 16 | Pipeline | Each operation overwrites the code; nothing composes | fixed (Phase 4.1) |
| 17 | Data | Sort/filter run only on the ≤500-row HTML preview → wrong for big tables; numbers re-parsed from text | fixed (Phase 2.1) |
| 18 | State | `sv_load_state(launch = TRUE)` ignores the loaded state; `sideview()` has no `state` argument | fixed (Phase 4.5) |
| 19 | Server | "Run in R" result is evaluated then thrown away | fixed (Phase 2.2) |
| 20 | Server | No `onSessionEnded → stopApp`; closing the browser tab leaves the console busy | fixed (Phase 2.2) |
| 21 | Gadget | "Cannot launch in external browser": reproduced. The browser opens, but the page is broken by #12 (init crash) and #26 (card width) | fixed (Phase 2.1–2.3; verified live in RStudio browser mode) |
| 22 | Security | Card and column names inserted unescaped into `innerHTML` and attribute selectors | fixed (Phase 2.1) |
| 23 | Icons | Emoji/Unicode glyph icons render inconsistently on Windows RStudio | fixed (Phase 2.5) |
| 24 | Packaging | No `.Rbuildignore`; `panzoom.min.js` is an in-house stub labelled 4.5.1; README zoom range ≠ code | fixed (Phase 2.6) |
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
| 40 | Layout | Initial cards are 640px wide but spaced 360px apart → they overlap on launch in every mode | fixed (Phase 2.4) |
| 41 | Drawer | Code preview text is centred and truncated | fixed (Phase 2.4) |
| 42 | Pane | In the narrow Viewer pane the toolbar covers card headers and the palette overlaps cards | fixed (Phase 2.4) |
| 43 | Codegen | R-side `sv_code_recode()` and `sv_auto_clean_rules()` emit `dplyr::case_match()`, deprecated in dplyr 1.2.0 (installed: 1.2.1). The new JS pipeline already uses `case_when(..., .default = col)` | fixed (Phase 4.1b) |
| 44 | Widget | A saved/embedded widget shows the R-only buttons (Insert Script, Run & Exit, Run in R, Run Console); Insert Script toasts "Code inserted" though nothing happened | fixed (Phase 4.4b) |

## Next release (0.4.0), agreed 2026-10-25 after the Gemini review
Each sub-project gets its own spec, plan and build, in this order:
1. **Full data for arrow/duckdb cards** (in design): duckdb runs sort/filter, join check, inspector and
   codebook on the whole table; generated code stays lazy and uses `collect()`.
2. **Join rules**: `relationship` / `unmatched` arguments from the join check; date-window and
   nearest-match joins (`join_by()` with `between()` / `closest()`), with R and JS join-check twins.
3. **`sideviewProxy()`**: update a `sideviewOutput()` canvas from server code in the user's own Shiny app
   (add/remove/replace cards, set state, read the pipeline). Wanted by the user.
4. **Small items**: `save_sideview()` row cap and message, Positron check plus a `viewer = "dialog"`
   fallback, workspace-version warning and migration slot, r-universe.

## Backlog (future rounds, not yet scheduled)
- **CDISC / pharmaverse support** (later stage, after 0.4.0 is solid; requested 2026-10-25, do not drop):
  recognise `USUBJID` / `STUDYID` as join keys, show SDTM/ADaM domain labels (DM, AE, LB, ADSL, ...).
- Table version diff by key (data-lock comparisons between dataset versions).
- Validation rules (ranges, allowed values, ID uniqueness) exporting `pointblank`-style checks.
- PHI/PII column tagging that excludes tagged columns from the LLM schema context.
- Export the pipeline as a reproducible Quarto report.

---

## Log

### 2026-10-25 - Three UI quirks from the tour fixed
- Copilot bubble: new pure `SideviewPipeline.splitReply()` (sv-pipeline.js) splits the reply at the first
  fence; the bubble renders before-text, code, buttons, then after-text (middle prose kept, fences removed).
- Pipeline join step: `.sideview-step-text` uses `flex: 1 1 0`. With `flex-wrap` on `.has-diag` steps an
  `auto` basis sized the label to its full text, so the buttons wrapped to a second line.
- Inspector `fmtNum()`: integers in full, else ~4 significant digits with every integer digit and at least
  one decimal. Display only: profiles and codebook CSV keep full precision (R/JS parity unchanged).
- Tests: node test for `splitReply` (test-copilot.R); browser tests for join-step row at 1400 and 1000 px
  windows, copilot bubble order (via `Shiny.shinyapp.dispatchMessage`), and the inspector's Mean text.
  Full suite with `NOT_CRAN=true`: 2350 passed, 0 failed, 0 skipped. Re-captured copilot/pipeline/inspect
  tour screenshots and checked them by eye.

### 2026-10-25 - Visual tour on the site
- New article `vignettes/articles/tour.Rmd` ("Visual tour" in the navbar): 10 screenshots, one per feature
  (canvas, joins, join check, filter, pipeline, inspector, Ctrl+K search, copilot, dark theme, shortcuts).
- Screenshots come from `tools/tour-screenshots.R` (headless chromote against the gadget with real
  mouse/key input, synthetic `patients`/`visits`/`labs`/`adverse_events`, mocked LLM). Re-run it after UI
  changes and copy `tour/overview.png` to `man/figures/overview.png` (README hero image).
- README hero uses an HTML `<img>`: Markdown alt text became a visible caption on the pkgdown home page.
- `.Rbuildignore` drops `vignettes/articles` and `tools`; the tarball gains only `man/figures/overview.png`.
- Verified: home and tour pages at 375 px (images 351 px wide, no horizontal overflow) and desktop; site scrubbed.
- Noticed, not fixed: copilot bubble shows prose that follows a code block above the code; narrow drawer
  wraps the pipeline step's delete button; inspector mean is unrounded (5.33789).

### 2026-10-25 - Submitted 0.3.0 to CRAN
- win-builder R-release (4.6.1) and R-devel (r90762): 1 note each (new submission). GitHub Actions
  `--as-cran` on Ubuntu (devel/release/oldrel), macOS, Windows: OK. mac-builder failed on its own missing deps.
- Uploaded without prompts: `pkgbuild::build(manual = TRUE)` then `devtools:::upload_cran()`; CRAN said
  "Package submission successful". `flag_release()` skips git worktrees (`.git` is a file), so
  `CRAN-SUBMISSION` was written by hand.
- Pending: maintainer clicks the CRAN confirmation email (lauyeehow1986@gmail.com); tag `v0.3.0` once accepted.

### 2026-10-25 - CRAN readiness (0.3.0)
- `R CMD check --as-cran` (R 4.5.2, Windows, incoming + remote URL checks): 0 errors, 0 warnings, 2 notes.
  "New submission" is expected. `''NULL''` in the check dir is local only: check sets `R_LIBS_USER='NULL'`
  and R 4.5 on Windows creates a missing user library at startup (`Rscript --vanilla -e 1` reproduces it).
  Bisected: examples stage only; a debug `.onLoad` task callback showed it exists right after load.
- Run in R no longer defaults to `globalenv()` (CRAN policy): `sideview(env = parent.frame())`,
  `sideview_server(run_env = parent.frame())`, `sideview_addin()` passes its `env`. Both `force()` the default:
  a lazy `parent.frame()` forced after `sideview()` returns falls back to the global env (a new test caught it).
- Tests use a local env for Run in R; Node.js-based tests now `skip_on_cran()`.
- Examples: `\dontrun` file writes became `tempfile()` (`sv_codebook`) and `\donttest` (`save_sideview`).
- DESCRIPTION: CRAN-style Title and Description (quoted software names, LLM spelled out); dropped the
  placeholder "sideview contributors" ctb entry. Added `cran-comments.md` (build-ignored with `CRAN-SUBMISSION`).

### 2026-10-24 - Maintainer email fixed; site and logo workflow published as skills
- DESCRIPTION maintainer email was `lauyeehow1986@gmail.com.sg` (typo). It is now `lauyeehow1986@gmail.com`.
- The dicomtk-style site procedure and the AI-image-to-hex-logo script are now reusable, agent-agnostic skills in
  https://github.com/lauyeehow1986-hub/Personal_skills (`building-r-package-sites`, `making-hex-logos-from-ai-images`).
- **Verified:**
  - The skill's logo script auto-detects the same hexagon that was fitted by hand for sideview, within 1 px.
  - The script was also tested on synthetic white, checkerboard, flat-top, caption, glow and wide images.
  - The scrub script and the CI step were tested on a seeded copy of this site's `docs/`, and both left `search.json` identical.

### 2026-10-24 — Site and README adopt the dicomtk layout
- **What:**
  - At the user's request the GitHub Pages site now follows the sister package dicomtk (https://lauyeehow1986-hub.github.io/dicomtk/).
  - `_pkgdown.yml` is reduced to `url`, `template: bootstrap: 5` (the default light navbar, no bootswatch or bslib colours, no custom navbar or authors block) and the reference index.
  - `README.md` was rewritten in the dicomtk shape: an H1 "sideview: Title" with the logo on the right (height 150), three badges, one intro paragraph, Installation, Key Features (bold-label bullets, nested where useful) and a Quick Start.
  - Dropped from the README: the emoji comparison table, the architecture diagram, the per-capability sections, the API and options tables. That detail lives in the reference pages and `?sideview`.
- **Why:** the user found the old bootswatch site and the long README hard to read on a phone.
- **Verified:**
  - The Quick Start code runs.
  - `check_pkgdown()` is clean.
  - The site was rebuilt locally and checked at 375x812 (light navbar, logo beside the title, readable sections, code blocks scroll sideways).
  - The CLAUDE/MEMORY pages were scrubbed from `docs/`.

### 2026-10-24 — New hex logo (README, pkgdown site, favicons)
- **What:**
  - The user supplied a new 1024px hex artwork (spline-connected tables, "sideview" wordmark). The hex was cut out with a transparent background: a regular pointy-top hexagon fitted at the 30-degree edges, a 4x supersampled mask and a 1.5px inset so no background fringe survives.
  - `man/figures/logo.png`: 598x693, 256 colours (58 KB instead of 394 KB, identical at the 139px display size). `man/figures/logo.svg` (the old logo) was removed, because pkgdown prefers an SVG over the PNG.
  - `pkgdown/favicon/*` were regenerated locally from the same cut-out, with no realfavicongenerator upload:
    - a transparent 96px PNG and a 16/32/48 `.ico`;
    - a `favicon.svg` that embeds a 64px PNG;
    - opaque dark apple-touch (180) and maskable manifest icons (192/512, artwork kept in the 80% safe zone).
  - `site.webmanifest` gained a name and a dark background colour.
  - A 1280x640 GitHub social preview card was made for the user to upload in Settings. It is not in the repo.
- **Verified:** served `docs/` locally. The home page header shows the new hex (loads at 598x693, shown at 120x139) and links the new favicons. Favicons were checked at 16/32/48/96/180px. The logo was checked on white and on dark backgrounds.

### 2026-10-24 — Pushed 0.3.0 to main and rebuilt the GitHub Pages site
- `_pkgdown.yml`: added `sv_theme` and `sv_llm_models` (`check_pkgdown()` failed without them).
- `docs/` rebuilt with pkgdown 2.2.0 (Pages serves `main:/docs`). The generated `CLAUDE`/`MEMORY` pages were removed from the site, the sitemap and the search index.
- **Found after the push:** the live site still had `CLAUDE.html`. The pkgdown workflow rebuilds the site in CI and deploys it after the legacy `docs/` build, so the CI build wins. Added a "Drop dev notes from the site" step (rm, `sed` on the sitemap, `jq` on the search index).
- **Verified:** served `docs/` locally. The home page, reference index (with the 5 new topics) and the 0.3.0 changelog all render with styles.

### 2026-10-24 — Wrap-up: 0.3.0, addin and Quarto QA, docs
- **What:**
  - Version 0.3.0, with a NEWS.md entry covering every phase.
  - README: navigation, pipeline/builders/join diagnostics, inspector/codebook, themes/keyboard, real-browser testing, a new **Options** table, and API rows for the 8 exports it was missing.
  - `?sideview` gained "Keyboard and navigation" and "Options" sections (all `sideview.*` options and their environment-variable fallbacks).
  - `sideview_addin()` returns invisibly when run, so Cancel no longer prints `NULL` in the console.
- **Verified:**
  - **RStudio addin:** Addins menu, then "Sideview Canvas". It opened as a dialog with the four global tables (labs, patients, sv_result, visits) in a grid. Ctrl+K `visit_d` + Enter zoomed to `visits` and flashed `visit_date`. Cancel closed it (before the fix it printed `NULL`).
  - **Quarto:** Rendered a `.qmd` with RStudio's bundled Quarto (R 4.5.2) and checked it in headless Chrome:
    - `html`/`body` overflow stays `visible`, and a wheel over the page text scrolls the page (scrollY 400).
    - Ctrl+K does nothing until the widget has focus, then opens the search.
    - Both cards and both minimap rectangles render, and the minimap stays inside the 799px widget, lifted above the AI bar (`sv-compact`).
  - `devtools::check()`: 0 errors, 0 warnings, 1 note (the environmental 'NULL' folder below).
- **Check fixes (found only by `devtools::check()`, which sets `NOT_CRAN=true` and runs the browser tests from the installed package):**
  - `helper-browser.R`: `sv_pkg_root()` returns "" unless it finds `DESCRIPTION` and `inst/`. The callr child then runs `library(sideview)` instead of `pkgload::load_all()`.
  - `gui-test-runner.js` finds `sideview.js` through `SIDEVIEW_JS`, which `test-computer-use-gui.R` sets from `system.file("www", ...)`.
  - The DuckDB normalize test skips without `dbplyr`. Suggests gained bslib, dbplyr, callr, chromote, httpuv and pkgload.
  - Run in R no longer writes to `.GlobalEnv` directly. `sideview_server(run_env = globalenv())` is passed through to `eval()`/`assign()`, which removes the NOTE.
  - `.Rbuildignore` ignores `CONTRIBUTORS.md` and `.git`.
  - **Remaining NOTE ("non-standard things in the check directory: 'NULL'"):** this is environmental. A one-function dummy package with a single example gets the same empty `NULL` folder on this machine. It appears at the start of the examples run, and there is no user `.Rprofile`/`.Renviron`.
- **Known trade-off:** the minimap floats over the canvas, so after Fit it can cover a corner of the bottom-left card in small windows. It can be collapsed (M), and Fit does not reserve space for it.

### 2026-10-24 — Phase 4.6: canvas navigation (minimap, Ctrl+K search, zoom-to-card)
- **What:**
  - **Minimap** (bottom-left, both gadget and widget): every card as a rectangle plus the current view.
    - Clicking a card zooms to it; clicking empty space centres the view there; dragging pans.
    - It hides under 720px (`sv-narrow`) and when there are no cards. It can be collapsed with its close button or **M**, and the choice is remembered in `localStorage` (inside try/catch).
  - **Ctrl+K card search:** a dialog that matches card names first, then column names.
    - Arrow keys and Enter go to a match, and Escape closes it.
    - A column match zooms to the card, scrolls the column into view and flashes its header.
    - There is also a toolbar search button.
  - **Zoom-to-card:** double-click a card title. It fits the card below the toolbar at 50–150% and flashes a focus ring.
  - The `?` dialog lists Ctrl+K, M and the title double-click.
- **Decisions:**
  - The minimap sits at z 105, below the overlay (110), the drawer (120) and the AI bar (130), so it never covers working controls.
  - New container class `sv-compact` (width under 1040px):
    - lifts the minimap above the AI bar;
    - hides the "Fullscreen" text label, so the toolbar with the new search button stays on one row.
  - The minimap re-renders from the existing rAF-batched `scheduleConnectorUpdate()`. A signature string skips unchanged frames.
  - Ctrl+K only fires when the canvas owns the keyboard, and only when Alt and Shift are not held.
- **Bugs caught while testing:**
  - The node mock-DOM GUI tests failed with "trailing garbage" JSON. Node now warns on stderr when `localStorage` is touched, and the harness merged stderr into stdout. Fixed by reading stderr separately, and showing it on failure.
  - At 1024px the toolbar wrapped Done onto a second row after the search button was added. Fixed with `sv-compact`.
  - A test selector `.sideview-minimap svg` matched the toggle button's icon instead of the map.
- **Tests:**
  - New browser tests in `test-layout-browser.R` use real CDP mouse and key input:
    - title double-click zooms to the card;
    - Ctrl+K finds cards and columns, and Enter zooms;
    - the minimap renders, a click moves the view, and it doesn't overlap the toolbar, palette, drawer or AI bar at 1400 and 1024 (hidden at 560);
    - the saved widget has all three features.
  - Results: `layout-browser` 399 checks, 0 failed. Full suite 2325 checks, 0 failed.
- **Verified in RStudio (Viewer pane zoomed, R 4.5.1), `sideview(patients, visits, labs, viewer = 'pane')`:**
  - The minimap showed the three cards bottom-left.
  - Double-clicking the visits title zoomed it to 150%.
  - Ctrl+K inside the Viewer opened the search (RStudio did not take the shortcut). Typing `test` and pressing Enter zoomed to labs with the `test` header flashed.
  - Clicking the patients rectangle in the minimap jumped to patients.
  - M collapsed the minimap to its button and M restored it. `?` listed the new shortcuts.
  - Cancel closed the gadget and freed the console.

### 2026-10-24 — Phase 4.5: save and open the workspace (#18)
- **What:**
  - `sideview(..., state =)` and `sideview_widget(..., state =)` take a `sideview_state` or a file path and restore everything: card positions, sizes and minimized state, zoom and pan, per-card sorts and filters, joins (splines), and the pipeline (steps, `pipe`, active drawer tab).
  - `sv_load_state(launch = TRUE)` now really launches. It finds the saved tables by name in the caller's environment, or takes `tables =`. If none are found, it fails with a message naming them.
  - The toolbar has new **Save** and **Open** buttons (inline SVG):
    - In the gadget with RStudio, they go through R and `rstudioapi::selectFile` (new inputs `state_save` / `state_open_request`, messages `sideview_state_saved` / `sideview_state_loaded`).
    - Without the RStudio dialog, Save writes a new `sideview-workspace*.json` in `getwd()`.
    - In the widget, Save downloads a JSON file and Open uses the browser file picker.
- **Decisions:**
  - The state schema is now 0.3.0. 0.2.0 files still load, and their code comes back as a custom step.
  - State crosses the wire as JSON text (`sv_state_json()` / `sv_state_from_json()`), so one-element arrays and nulls survive.
  - Cards are matched by name. Names that are missing are listed in a warning toast.
  - A restored view skips the first auto-fit.
  - Open replaces the joins and the pipeline and starts a fresh undo history, so opening twice never stacks joins.
  - The embedded JSON escapes `</` so it cannot close its `<script>`.
- **Tests:**
  - `test-state.R`: JSON round trip, `sv_as_state`, UI embedding and escaping, the file-dialog flag, pass-through from `sideview()`/`sideview_widget()`, `sv_load_state(launch = TRUE)`, `sv_choose_state_path`, and server save/open/cancel/error.
  - Three new browser tests:
    - A workspace built with real header sort, filter popover and port clicks reopens in a fresh app with identical positions, view, sort (top rows equal `max(labs$value)`), filter, spline and code, and Save writes the file.
    - Open on a running canvas replaces it, names the missing card, and does not stack joins.
    - A saved widget restores its state and downloads its own.
  - Results: `layout-browser` 328 checks, 0 failed. Full suite 2254 checks, 0 failed.
- **Verified in RStudio (Viewer pane, R 4.5.1):**
  - Sorted labs descending, moved visits, and joined patients and labs.
  - **Save** opened RStudio's "Save sideview workspace" dialog, and the toast showed the saved path.
  - After Arrange, **Open** (its dialog shows the "Sideview workspace" filter) restored all 3 cards ("Restored 3 cards").
  - Then `with(jc, sv_load_state(path, launch = TRUE, viewer = 'pane'))` reopened the same canvas, and Done returned `labs_prep <- labs %>% arrange(desc(value))` + `patients %>% left_join(labs_prep, by = "patient_id")`.
  - Note: the Save dialog shows "All Files" because RStudio's save dialog ignores the filter; Open uses it.

### 2026-10-24 — Phase 4.4b: the saved widget hides buttons that need R (#44)
- **Why:** found while checking 4.4 in RStudio. In a saved or embedded widget, Insert Script / Run & Exit / Run in R / Run Console have no R session to talk to, yet Insert Script toasted "Code inserted into script!".
- **Fix:**
  - The four buttons carry `data-r-only` in both drawer templates (the JS template for the widget, `R/app_ui.R` for the gadget).
  - A scoped CSS rule hides them under `.sv-embedded`.
  - The handlers go through a new `sendToR()`, which warns "... needs the R session (run sideview() from R). Use Copy instead." and never shows a success toast when nothing was sent. This matches the AI bar.
- **Tests:** a new browser test. In the saved widget the four buttons are hidden, Copy and Clear are visible, and Insert Script warns rather than claiming success. In the gadget the same four buttons are present. The test was written before the fix, but it was not run red first; its assertions could not pass on the old markup. `layout-browser`: 281, 0 failed. Full suite: 2164, 0 failed.
- **Verified in the RStudio Viewer pane:**
  - The saved widget's drawer shows only Copy, Clear and Auto-clear.
  - The gadget's drawer still shows Insert Script, Run & Exit, Run in R and Run Console.

### 2026-10-24 — Phase 4.4: column inspector and `sv_codebook()` data dictionary
- **Why:** before analysis a biostatistician wants each variable's type, missingness, distinct count, key check, quartiles and messy-text problems, plus a codebook to file with the analysis plan. Previously you had to leave the canvas and run `summary()` / `table()` by hand.
- **R API (new `R/codebook.R`):**
  - `sv_column_profile(x, top_n, bins)`: kind, class, label (haven/labelled `label` attribute), n, missing, distinct, unique key, type-7 quartiles, mean, SD (or earliest/median/latest for dates), a 20-bin equal-width histogram, top values with `n_other`, and plain-language checks:
    - all missing; only one distinct value
    - leading/trailing spaces; empty strings that aren't NA
    - values that differ only in case or spacing
    - numbers stored as text
    - values beyond 3 IQR of the quartiles
  - `sv_codebook(..., top_n, file)`: one row per column of every table. It writes `.csv`, or `.xlsx` through writexl (Suggests).
- **JS twin:** `SideviewPipeline.columnProfile()`, `codebookRow()` and `codebookCsv()` in sv-pipeline.js. The widget profiles in the browser and downloads `codebook.csv`. The gadget asks R (`column_profile_request` → `sideview_column_profile`, using the full data, not the 500-row preview) and writes the file through `sv_choose_codebook_path()`, which uses RStudio's save dialog (`codebook_export` → `sideview_codebook_saved`).
- **UI:**
  - A new header button (bar-chart icon) opens a new **Inspect** drawer tab with Table/Column pickers, a stats grid, an SVG histogram, a top-values bar list, Checks, and **Export codebook**.
  - Variable labels show under the name in the widget.
  - Profiles are cached per table/column.
- **Bugs found while building, then fixed:**
  - `observeEvent(ignoreInit = TRUE)` dropped the first `codebook_export` in testServer, so it now uses `ignoreInit = FALSE`.
  - Wording such as "1 values have": a plural helper now handles counts.
  - Variant groups were ordered by locale, so R and JS disagreed; both now sort by radix.
  - `format()` on a whole numeric vector padded digits; values are now formatted one at a time.
- **Tests:**
  - New `test-codebook.R` (204 expectations): numeric, text and date profiles; codebook columns; CSV/xlsx/errors; JS/R parity over 10 column types; the JS CSV is byte-equal to `write.csv(sv_codebook())`; and a server test of the full-data profile, export and cancel.
  - Browser (2 new tests):
    - gadget: a real click on the labs `value` inspect button shows "5,000" rows, and the quartiles and histogram equal R
    - saved widget: the label shows, the profile equals R, and the downloaded CSV equals R's codebook
  - `layout-browser`: 270 expectations, 0 failed. Full suite: 2122, 0 failed.
- **Verified in the RStudio Viewer pane (R 4.5.1), with real clicks:**
  - The header with four buttons is not cramped, and the nine drawer tabs wrap onto two clean rows.
  - `age` shows the stats, a histogram and "No problems found". `sex` shows 39 missing (19.5%), top values Male/Female/F/male, and the case-variant check.
  - Export codebook opened RStudio's native Save dialog from inside the running gadget. Saving `rstudio_codebook.xlsx` toasted the path, and the file reads back as 10 rows × 19 columns.
  - Dark mode: the inspector, selects and histogram are legible.
  - Saved widget (`save_sideview` → `rstudioapi::viewer`): the visits `sbp` profile (median 132) matches R's xlsx.
- **Found in RStudio:** the saved widget still showed the R-only buttons (#44), so it was fixed in 4.4b.

### 2026-10-24 — Phase 4.3: join diagnostics before you join
- **Why:** in clinical data the costly join mistakes are silent: duplicated visit rows, IDs with stray spaces or case, keys of different types. A spline used to give code with no hint of what the join would do.
- **R API (new `R/diagnostics.R`):** exported `sv_join_diagnostics(x, y, by, sample_n, x_name, y_name)`. `by` works as in dplyr. It returns:
  - row counts for every join type, equal to dplyr (NA matches NA, `na_matches = "na"`); 1e6 and "1000000" compare equal
  - match rate both ways, distinct/repeated/missing keys
  - relationship (1:1, 1:m, m:1, m:m, no matches), on matched keys only
  - samples of unmatched keys
  - hints: trimming, ignoring case or dropping leading zeros, each measured on its own, shown only when it gains rows
  - type issues (status `error`, since dplyr refuses the join); warnings for m:m, no matches, under 50% matched, missing keys
  - a `print()` method
- **JS twin:** `SideviewPipeline.joinDiagnostics()` and `describeDiagnostics()` in sv-pipeline.js, with the same fields. The widget has every row in the browser, so it computes locally. The gadget sends `join_diagnostics_request` and R answers `sideview_join_diagnostics` from the full data frame, not the 500-row preview.
- **UI:**
  - Each join step in the Pipeline tab gets a status line, e.g. "1:m · 96% of patients matched · 590 rows" (green ok, amber warn, red error).
  - A warning or error also raises one toast per set of keys.
  - Clicking the line opens the Discrepancy tab with the join check: relationship, matched rows on each side, distinct/repeated/missing keys, a rows-per-join-type table with the current type marked, unmatched samples and possible fixes.
  - A new join becomes the one shown.
- **Found only in a real browser, then fixed:** the gadget's drawer is rendered by R (`R/app_ui.R`), not by the JS template, so it had no `.sideview-joincheck` box. The panel stayed empty in the gadget while the widget worked.
- **Found in RStudio, then fixed:** hints read "would match 0 more patients rows and 6 more visits rows". Zero sides are now left out, in both JS and `print()`.
- **Tests:**
  - New `test-diagnostics.R` (145+ expectations): dplyr row-count parity over random seeds (single and multi-key), relationships, fields, samples, warnings, print, hints, type errors, input errors, JS/R parity, and the server observer through `testServer`.
  - `helper-node.R` now holds `run_pipeline_js()`, shared with test-pipeline.
  - Browser (2 new tests):
    - gadget: real clicks on ports, the line resolves from R, the panel's rows table matches R, no warning toast for an ok join, an m:m join raises a warning toast and an amber panel, and the panel fits the drawer
    - saved widget (`save_sideview`, file://): the local diagnostics equal R's
  - `layout-browser`: 235 expectations, 0 failed. Full suite: 1910, 0 failed.
- **Verified in the RStudio Viewer pane (R 4.5.1), with real clicks:**
  - light mode, patients→visits: green "1:m · 96% of patients matched · 590 rows". The panel shows 590/582/608/600/192/8 rows, "Not in patients: P00001, P99999, p00002", and trim/case hints.
  - dark mode, then visits→labs: amber toast "Many-to-many … gives 14,604 rows from 600 visits rows". The m:m line and panel are legible on dark. The composed code builds `visits_prep` first.

### 2026-10-24 — Phase 3: light/dark theme, keyboard shortcuts, accessible controls
- **Theme API (new `R/theme.R`):**
  - `sv_theme(mode, primary, font, font_mono, radius, ...)` builds token overrides. Names and values are validated, so no `;{}<>` can reach the inline style.
  - `theme =` on `sideview()`, `sideview_widget()` and `sideview_ui()` accepts `"auto"`/`"light"`/`"dark"`, an `sv_theme()` or a `bslib::bs_theme()`. A `_brand.yml` theme works through bslib. The bslib theme supplies primary, body-bg (which picks the mode) and the fonts.
  - In the gadget, `"auto"` follows `rstudioapi::getThemeInfo()$dark`. In the widget, or outside RStudio, it follows `prefers-color-scheme`.
- **One custom `primary` drives all the derived tokens:**
  - hover, tint, focus ring and splines
  - `text-inverse`: white or near-black, whichever contrasts more
  - `primary-text-light` / `primary-text-dark`: darkened or lightened until ≥ 4.5:1 on that mode's surfaces and tints
- **CSS:**
  - A full dark token set (in `.sv-theme-dark` and the auto media query).
  - `color-scheme`, a 2px `:focus-visible` ring and `prefers-reduced-motion`.
  - Seven rules that used `--sv-primary` as a text colour now use `--sv-primary-text`.
- **JS:**
  - Theme toggle (moon/sun) and shortcuts (keyboard) toolbar buttons.
  - Shortcuts: `T` theme, `F` fit, `0` reset, `+`/`-` zoom, `D` drawer, `/` AI box, `?` shortcut dialog (`role=dialog`, `aria-modal`, closed by Esc or the scrim).
  - Ctrl+Enter submits a drawer builder.
  - Shortcuts are ignored while typing, with Ctrl/Meta held, or when an embedded widget doesn't have focus.
- **Accessibility:**
  - Palette swatches are real `<button>`s with `aria-label` and `aria-pressed` inside a `role=group`.
  - Every visible button has an accessible name.
  - Toolbar titles show their shortcut.
- **Found only in RStudio, then fixed:**
  - **Problem 1:** with `primary = "#f59e0b"` (amber), "Done" had white text on amber (about 2:1).
    - **Fix:** `text-inverse` is now picked by contrast, and the hover shade moves away from the label.
  - **Problem 2:** "Snap" (active) was amber text on white (about 2:1).
    - **Fix:** the new mode-aware `--sv-primary-text`.
- **Found in the browser tests:**
  - `.sideview-btn { transition: all }` animates the focus outline from `medium` (3px), so the test waits 0.4s before reading it. The ring itself is 2px.
- **Tests:**
  - New `test-theme.R` (123 expectations):
    - every token used is defined, and dark equals auto-dark
    - no hard-coded colours in declarations
    - WCAG ≥ 4.5 for 20 text/background pairs in light and dark
    - `sv_theme` validation, and the derived contrast for 6 custom primaries
    - `sv_resolve_theme` (with RStudio mocked, and bslib)
    - the UI and widget carry the theme
  - Browser (5 new tests):
    - the toggle and `T`
    - shortcuts, including the typing, Ctrl and embedded cases
    - the `?` dialog
    - swatch buttons and `aria-pressed`, no unnamed buttons, and a 2px ring after a real Tab
    - Ctrl+Enter
  - `layout-browser|assets|theme`: 408 expectations, 0 failed.
- **Verified in the RStudio Viewer pane (R 4.5.1), with real clicks and keys:**
  - The default gadget opens in light/auto with the new buttons. The toggle switches to dark and the icon becomes a sun.
  - `0` resets to 100%. `?` opens the dialog with 10 rows, and Esc closes it. `f` fits (47%). `t` switches back to light.
  - `sv_theme('dark', primary = '#f59e0b')` launches dark with amber accents.
  - `sv_theme('light', primary = '#f59e0b')`: "Done" has dark text and "Snap" is dark amber, both legible. After `t`, "Snap" is bright amber on dark.
  - Note for computer-use QA: the first click into the Viewer iframe can be swallowed while it takes focus, so click Cancel again if the gadget stays open.

### 2026-10-24 — Phase 4.1b: R recode generators move off deprecated `case_match()` (#43)
- **Change:** `sv_code_recode()` now defaults to `method = "case_when"`. It emits one `case_when()` arm per target, so several sources that map to one target become `col %in% c(...)` and an NA source becomes `is.na(col)`. The default becomes `.default = ...`. With no default, unmatched values become NA, the same as `case_match()`. `sv_auto_clean_rules()` uses the same method. `method = "case_match"` is still accepted for older pipelines. README and roxygen/`man/` are updated; `man/sideview_server.Rd` also picks up the `sideview.session_grace` doc from Phase 2.2 that had not been regenerated.
- **Why:** dplyr 1.2.0 deprecated `case_match()`, so every Auto-Clean and recode script printed a lifecycle warning when run. That would also break once the function is removed.
- **Verified:**
  - Updated 6 expectations (test-app, test-codegen auto-clean). The auto-clean evaluations now use `expect_no_warning`, where they used to need `suppressWarnings`.
  - New test: an NA source, multi-value `%in%`, `.default`, the no-default case giving NA, a backticked non-syntactic column, and the legacy method.
  - `codegen|app|e2e|features-verification`: 692 expectations, 0 failed.
  - Not a UI change, so there was no RStudio re-walk. The client recode tab was already on `case_when` and is covered by the browser test.

### 2026-10-24 — Phase 4.1: composable pipeline and real drawer tabs (#15, #16)
- **Decision: the pipeline lives in the browser, not in R.**
  - The plan said "R-side pipeline list". Instead, a new pure-JS module, `inst/www/sv-pipeline.js` (`window.SideviewPipeline`), holds the typed steps and composes the R code.
  - **Why:** the htmlwidget (`save_sideview()`, Quarto) has no R session, but it still needs working sort/filter/join code. One composer serves both modes, and the R server only needs to be told what changed.
  - The R `sv_code_*` generators stay as they are, for direct use and for the AI and auto-clean paths.
- **Step model:**
  - Step kinds: join, filter, arrange, rename, mutate, recode, summarise and custom.
  - **Keyed steps replace and move to the end.** One header sort per table shares a key with the Arrange builder, so the last sort wins. There is also one header filter per table, which matches the VirtualTable preview, since it holds one filter.
  - **Joins:** every spline between the same pair of tables becomes one multi-key `by = c("a", "b" = "c")`.
  - **Chain order:** chains are grouped per base table. A joined table that has its own steps is written first as `<table>_prep <- ...` (DFS order, with a cycle guard).
  - **Pipe choice:** `%>%` or `|>`.
  - **Undo/redo:** covers pipeline steps only (up to 100). The toolbar buttons and Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z apply to the last-used widget and are skipped while typing in a field.
- **Drawer tabs:** Pipeline, Filter, Arrange, Mutate, Recode, Summarise, Discrepancy and Copilot each show only their own pane (`role="tab"`, `aria-selected`).
  - The Pipeline tab has the step list (enable checkbox, join-type select, move up/down, delete), undo/redo, the pipe select and the code.
  - Filter (AND/OR, multi-condition, `in`, missing), Arrange (multi-column), Mutate (expression with column chips), Recode (`old = new` lines) and Summarise (group-by plus several summaries) are form builders that add a step.
- **The drawer no longer pops open on every operation.** The Drawer button shows a step-count badge instead.
- **Server `sideview_code_update` now carries `source`:**
  - `event` (sort/filter/join/rename echoes) is ignored by the client, which already composed the step.
  - `auto_clean` is appended as a custom step.
  - `ai` or no source replaces the pipeline (undoable).
  - `copilot` no longer overwrites anything: the user clicks "Replace pipeline" in the chat bubble, and that is undoable.
- **dplyr 1.2:** `case_match()` is deprecated. The pipeline's recode uses `case_when(..., .default = col)`. The R generators now do the same (#43, Phase 4.1b).
- **Tests:**
  - `test-pipeline.R` (34 expectations): Node drives `sv-pipeline.js`. Every script `parse()`s, keyed replace, join-key merge/removal, undo/redo, identifier escaping, the cycle guard, and a filter → arrange → join → recode → summarise chain that equals hand-written dplyr with no warnings.
  - Browser (3 new tests, 61 expectations):
    - Each tab shows exactly its pane, and the builder panes render forms.
    - Header sort, header filter and a spline compose into one script that runs on the fixture and equals dplyr.
    - The drawer stays collapsed and the badge reads 3.
    - Undo/redo, join type, step toggle, delete and Clear all work.
    - The builders reject empty input. Mutate, recode and summarise steps run.
    - Ctrl+Z / Ctrl+Y work.
  - Layout browser suite: 159 expectations, 0 failed. Full `devtools::test()`: 1552 expectations, 0 failed (before the bottom-sheet fix and its 2-expectation test).
- **Verified in the RStudio Viewer pane (R 4.5.1), with real mouse clicks:**
  - Sort age plus a patients→visits spline gave Drawer badge "2", and the drawer stayed closed.
  - The Pipeline tab lists both steps with the join-type select, and shows the composed code.
  - The Filter builder (age >= 60) added a third step.
  - Undo → 2 steps, redo → 3. Moving the filter step up reorders the code.
  - **Done** returned `patients %>% dplyr::arrange(age) %>% dplyr::filter(age >= 60) %>% dplyr::left_join(visits, by = "patient_id")`.
  - Cancel → returns.
- **Found in RStudio and fixed:**
  - **Problem:** the narrow-pane bottom sheet only had a `max-height`, so it grew upward as steps were added. Undo/redo moved under the cursor.
  - **Fix:** it now has a fixed `height`, and its content scrolls.
  - **Regression test:** the undo button stays within 1px after 3 steps are added at 560px wide.

### 2026-10-24 — Phase 2.6: packaging (#24)
- **Pan/zoom helper:** `panzoom.min.js` is renamed `sv-panzoom.js`. Its header now says it is sideview's own helper and not the `@panzoom/panzoom` 4.5.1 package.
- **One shared dependency:** the gadget and the widget both load a single `sideview-core` dependency (`sideview_html_dependency()`), holding the CSS, `sv-panzoom.js` and `sideview.js`.
  - Its version is the package version plus an asset fingerprint.
  - `inst/htmlwidgets/sideview.yaml` no longer lists its own stale `panzoom` 4.5.1 and `sideview-assets` 0.2.0 dependencies (`dependencies: []`).
- **README:** the zoom range now matches the code (15%–350%).
- **Verified:**
  - `save_sideview()` output in headless Chrome: 2 cards, 42 SVG icons, no empty icon slots, `window.Panzoom` present, 0 console errors.
  - Full suite: 1453 expectations, 0 failed.

### 2026-10-24 — Phase 2.5: inline SVG icons (#23)
- **What:** every emoji or Unicode glyph icon (maximize, sync-scroll link, collapse, sort, filter, fullscreen, AI sparkles, close, highlight-clear) is now an inline SVG.
- **How:** one icon set in `sideview.js`: `ICONS`, `icon(name)`, `setIcon(el, name)` and `hydrateIcons(root)`. Paths follow Lucide (ISC/MIT) and are bundled, with no network.
  - The R UI emits empty `data-sv-icon="name"` placeholders (`sv_icon_slot()` for icon + label buttons), and the engine fills them on start-up.
  - JS-built cards and chrome call `icon()` directly.
  - Sort state swaps `sort` → `sortAsc` → `sortDesc`; collapse swaps `minus`/`plus`; maximize swaps `maximize`/`restore`.
  - The current icon name is kept in `data-sv-icon`, which the tests read.
- **Accessibility:** every icon button now has an `aria-label` (and toggles update it), and SVGs are `aria-hidden`. The CSS `::after "×"` on the clear swatch is gone.
- **CSS:** `.sv-icon` uses the new tokens `--sv-icon-size` and `--sv-icon-size-sm`.
- **Tests:**
  - R: no glyph entities or non-ASCII characters in buttons, and every `data-sv-icon` name exists in `ICONS`.
  - Browser: every placeholder holds an SVG, no glyph text, no unlabelled icon button, and sort/collapse swap icons.
  - Mock: sort cycle checks `data-sv-icon`.
  - Result: **1453 expectations, 0 failed**.
- **Verified in RStudio Viewer pane:** the card header, column sort/filter, fullscreen, AI sparkles, palette clear and drawer/filter close icons all render as crisp SVG. Sort-ascending shows the blue up-arrow. Collapse and expand work. Cancel → `NULL`.
- **Seen again:** a sort auto-opens the drawer bottom sheet over the card in the narrow pane. That is #15, next up.

### 2026-10-24 — Phase 2.4: launch layout, Fit/Arrange, code preview
- **Launch layout (#40, #42):**
  - Cards with no saved position (`data-auto-place`, from R or `addCard`) are laid out on first real layout by `arrangeCards()`.
  - Layout runs once the container has a size, so a widget hidden in a tab still works.
  - It tries every column count and keeps the one that fits largest. Below `READABLE_SCALE` (0.5) it prefers a layout whose width fits, so panning is vertical only.
  - Cards start under the measured toolbar and palette (`chromeTop()`), and `fitAll()` zooms between 0.5 and 1.
- **Toolbar:** new **Fit** (`fit-all`) and **Arrange** (`arrange-cards`) buttons in both the gadget and widget toolbars.
- **Code preview (#41):** htmltools indented the server-rendered `<pre>`, so the placeholder showed leading spaces and looked centred; fixed with `.noWS`. Long lines now wrap (`pre-wrap`) instead of being clipped in the narrow drawer.
- **Mock-DOM suite:** cards pinned to fixed positions, since its drag/dock arithmetic assumes them.
- **Tests:** browser tests "cards are laid out without overlap below the chrome on launch" (1400×900 and 420×700) and "Fit and Arrange keep every card visible and apart". `devtools::test()` → **1430 expectations, 0 failed, 0 errors**.
- **Verified in RStudio Viewer pane (~400px):** the toolbar wraps; cards sit below the toolbar and palette in one column at 50% with no sideways overflow; the drawer is a bottom sheet with a left-aligned placeholder; Cancel → `NULL`; Done with no code → `NULL`.

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
