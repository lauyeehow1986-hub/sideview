# MEMORY.md — sideview change log & decision record

Running log of what changed, why, and how it was verified. Newest entries first.
Each entry: **date — change — why — verification**. Keep the "Open issues" table current.

---

## Open issues (from the 2026-10-24 code audit)

Status: `open` · `fixed` (with commit) · `wontfix`.

| # | Area | Issue | Status |
|---|------|-------|--------|
| 1 | CSS | Sticky `th` cancelled by a later `position: relative` (`sideview.css`) → headers and ports scroll away | open |
| 2 | Card | Maximize uses `position: fixed` inside the transformed viewport → ~10000px card in the wrong place; no VirtualTable re-render | open |
| 3 | Card | Minimize hides the body without redrawing connectors → splines jump to the origin | open |
| 4 | Canvas | Fullscreen marks itself active even when the request fails (RStudio Viewer iframe) | open |
| 5 | Layout | Toolbar, palette, drawer, AI bar and toast overlap in narrow windows; no responsive layout, no ResizeObserver | open |
| 6 | Card | `resize: both` doesn't grow the 380px max-height body | open |
| 7 | Perf | `updateConnectors` runs with no rAF; drag handlers bound 3–4× per move | open |
| 8 | Popover | Filter popover appended to `body`, positioned once; doesn't follow pan/zoom/scroll; no vertical clamp | open |
| 9 | CSS | Duplicate conflicting rules; undefined `--sv-radius-md`; missing `.sideview-toast-info` | open |
| 10 | Widget | CSS sets `html, body {overflow: hidden !important}` and absolute container → breaks Quarto/Rmd pages; wheel hijacks page scroll; binding JS loaded twice; both dependencies named `sideview` | open |
| 11 | Codegen | Sort generates `%>` instead of `%>%` | open |
| 12 | JS | `initSideview('.sideview-container')` throws in strict mode (sets a property on a string) | open |
| 13 | JS | Click-to-connect leaves a dangling draft after completing | open |
| 14 | JS | `stopPropagation` between sibling delegated handlers has no effect → sort/filter clicks also highlight or connect | open |
| 15 | Drawer | Join/Filter/Arrange/Mutate/Recode tabs all show the same pane; drawer re-opens on every update | open |
| 16 | Pipeline | Each operation overwrites the code; nothing composes | open |
| 17 | Data | Sort/filter run only on the ≤500-row HTML preview → wrong for big tables; numbers re-parsed from text | open |
| 18 | State | `sv_load_state(launch = TRUE)` ignores the loaded state; `sideview()` has no `state` argument | open |
| 19 | Server | "Run in R" result is evaluated then thrown away | open |
| 20 | Server | No `onSessionEnded → stopApp`; closing the browser tab leaves the console busy | open |
| 21 | Gadget | "Cannot launch in external browser": reproduced. The browser opens, but the page is broken by #12 (init crash) and #26 (card width) | open |
| 22 | Security | Card and column names inserted unescaped into `innerHTML` and attribute selectors | open |
| 23 | Icons | Emoji/Unicode glyph icons render inconsistently on Windows RStudio | open |
| 24 | Packaging | No `.Rbuildignore`; `panzoom.min.js` is an in-house stub labelled 4.5.1; README zoom range ≠ code | open |
| 25 | Tests | GUI suite uses a mock DOM, so layout is never exercised in a real browser | open |
| 26 | Card | **Blocker:** cards have no width, so they shrink-wrap to the 10000px viewport (~9960px) and each column is ~900px; only the first column shows and numbers look empty | open |
| 27 | Canvas | Zoom % label never updates; zoom isn't centred on the view | open |
| 28 | Discrepancy | "undefined fuzzy": `fuzzy_matches` data.frame is serialised column-wise; fuzzy cells never highlight | open |
| 29 | AI | LLM errors only appear as a code comment; missing model gives no toast or hint; no busy indicator | open |
| 30 | Gadget | Closing the dialog raises Shiny's "User cancel" error → debugger under RStudio "Break on error"; no Done/Cancel | open |
| 31 | Filter | Numeric operators offered for character columns | open |

## Backlog (future rounds, not yet scheduled)
- Table version diff by key (data-lock comparisons between dataset versions).
- Validation rules (ranges, allowed values, ID uniqueness) exporting `pointblank`-style checks.
- PHI/PII column tagging that excludes tagged columns from the LLM schema context.
- Export the pipeline as a reproducible Quarto report.

---

## Log

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
