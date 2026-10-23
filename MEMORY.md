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
| 19 | Server | "Run in R" result is evaluated then thrown away | open |
| 20 | Server | No `onSessionEnded → stopApp`; closing the browser tab leaves the console busy | open |
| 21 | Gadget | "Cannot launch in external browser": reproduced. The browser opens, but the page is broken by #12 (init crash) and #26 (card width) | fixed in browser harness; RStudio re-walk pending |
| 22 | Security | Card and column names inserted unescaped into `innerHTML` and attribute selectors | fixed (Phase 2.1) |
| 23 | Icons | Emoji/Unicode glyph icons render inconsistently on Windows RStudio | open |
| 24 | Packaging | No `.Rbuildignore`; `panzoom.min.js` is an in-house stub labelled 4.5.1; README zoom range ≠ code | open |
| 25 | Tests | GUI suite uses a mock DOM, so layout is never exercised in a real browser | fixed (Phase 2.1) |
| 26 | Card | **Blocker:** cards have no width, so they shrink-wrap to the 10000px viewport (~9960px) and each column is ~900px; only the first column shows and numbers look empty | fixed (Phase 2.1) |
| 27 | Canvas | Zoom % label never updates; zoom isn't centred on the view | fixed (Phase 2.1) |
| 28 | Discrepancy | "undefined fuzzy": `fuzzy_matches` data.frame is serialised column-wise; fuzzy cells never highlight | fixed (Phase 2.1) |
| 29 | AI | LLM errors only appear as a code comment; missing model gives no toast or hint; no busy indicator | open |
| 30 | Gadget | Closing the dialog raises Shiny's "User cancel" error → debugger under RStudio "Break on error"; no Done/Cancel | open |
| 31 | Filter | Numeric operators offered for character columns | fixed (Phase 2.1) |

## Backlog (future rounds, not yet scheduled)
- Table version diff by key (data-lock comparisons between dataset versions).
- Validation rules (ranges, allowed values, ID uniqueness) exporting `pointblank`-style checks.
- PHI/PII column tagging that excludes tagged columns from the LLM schema context.
- Export the pipeline as a reproducible Quarto report.

---

## Log

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
