# sideview UI QA checklist

Walk this list in every run mode after each phase. Record results in the table at the bottom
(and summarise in `MEMORY.md`). Screenshots go to a scratch folder, never the repo.

**Fixture:** synthetic only. `patients` (2,000 rows; messy `sex` values), `visits` (6,000 rows;
`pid` contains `" P00001"`, `"p00002"`, `"P99999"`), and `labs` (120,000 rows, which exercises the
>500-row path).

**Modes:**
- **D** dialog (`sideview(...)` in RStudio)
- **P** Viewer pane (`viewer = "pane"`)
- **B** external browser (`viewer = "browser"`)
- **A** addin
- **W** `save_sideview()` HTML
- **Q** widget embedded in a long Rmd/Quarto page

## Checklist
1. **Launch:** opens with no JS console errors; every card shows several columns with visible values.
2. **Close:**
   - The Done button returns the code; the Cancel button or closing the window returns quietly. No error and no debugger.
   - In browser mode, closing the tab frees the console.
3. **Canvas:**
   - Wheel zoom and toolbar zoom; the % label tracks the scale; reset works.
   - Pan by dragging the background.
4. **Cards:**
   - Drag; snap toggles; resize grows the body.
   - Maximize fills the visible window and restores.
   - Minimize keeps the splines attached.
5. **Fullscreen** works, or falls back gracefully inside the RStudio Viewer.
6. **Table:**
   - The header stays sticky while the body scrolls.
   - Virtual scrolling stays smooth on 120k rows.
   - Sync-scroll locks two cards.
7. **Sort** (asc, desc, reset) is correct on the *full* data (>500 rows), and the code parses.
8. **Filter:**
   - The popover is anchored to the column and follows pan/zoom.
   - Operators suit the column type; the result is correct on the full data; the code parses.
9. **Connect:**
   - Click-to-connect and drag-to-connect; no phantom joins.
   - The spline stays on its ports after zoom, pan, scroll and minimize; disconnect works.
10. **Discrepancy tab:** matched, fuzzy and diff counts are correct; fuzzy and diff cells highlight; auto-clean code parses.
11. **Drawer tabs:** each tab shows its own UI; the drawer doesn't cover cards or chrome at 1024×700 or 560×520.
12. **Actions:**
    - Insert Script, Run & Exit, Run in R (result kept), Run Console, Copy, Clear, Auto-clear.
13. **AI bar:**
    - Works with a mocked `llm_fn`.
    - With Ollama absent or the model missing, shows a clear message with a fix hint.
14. **Keyboard:** Esc cancels a connect or closes a popover; shortcuts work.
15. **Embedding (Q):** the page still scrolls; the widget stays inside its box; two widgets on one page are independent.

## Results — 2026-10-24 baseline audit (before fixes)

RStudio 2025.05.1+513, R 4.5.1 (RStudio) / 4.5.2 (Rscript), Windows 11. Driven with computer use in
RStudio, plus the DOM-level browser for the browser/widget modes.

| # | Item | Mode | Result | Finding |
|---|------|------|--------|---------|
| 1 | Launch | D B | **FAIL** | `initSideview` throws `Cannot create property '_sideviewInstance' on string` (strict mode). Cards stretch to ~9,960px wide, so only the first column is visible and numeric columns look empty. **This is the "can't use it in the browser" report:** the browser does open; the page is broken. |
| 2 | Close | D | **FAIL** | Closing the dialog window → Shiny `stopOnCancel` raises an error → with RStudio's "Break on error" the console drops into `Browse[1]>`. No Done/Cancel buttons. |
| 2 | Close | B | **FAIL** | The console stays busy after launch, and closing the tab doesn't free it (no `onSessionEnded`). |
| 3 | Zoom | D B | **FAIL** | Zoom works, but the % label stays at "100%". Zoom doesn't keep the view centre. |
| 4 | Toolbar overlap | D | **FAIL** | The toolbar and highlight palette float over the cards; the drawer covers the cards; drawer tab strip and code box are clipped with horizontal scrollbars. |
| 7 | Sort | B | **FAIL** | Sorted only the 500-row preview: shown min 0.66, true min 0.34. Client code `labs %>\n` is invalid (the server regenerates valid code). |
| 8 | Filter | B | **FAIL** | Popover appended to `<body>`; numeric operators (`>`, `<=`) offered for character columns. |
| 9 | Connect | B | **FAIL** | After a connection completes, a draft stays active, so the next port click creates a phantom join (3 connectors from 2 intended). Each new join replaces the code, so steps don't compose. |
| 10 | Discrepancy | B | **FAIL** | Shows "undefined fuzzy": `fuzzy_matches` is a data.frame serialised column-wise, so `.length` is undefined and fuzzy cells never highlight. |
| 11 | Drawer tabs | D B | **FAIL** | Join/Filter/Arrange/Mutate/Recode all show the same pipeline pane. |
| 12 | Run in R | B | partial | Evaluates OK ("6000 rows x 9 cols") but the result is thrown away. |
| 12 | Clear | B | pass | Code reset, connectors removed. |
| 13 | AI bar | B | **FAIL** | Model `llama3.2` missing → the error only appears as a code comment; no toast, no hint, no busy indicator. |
| 15 | Embedding | Q | **FAIL** | `html, body {overflow:hidden}` locks page scroll (document height = window height); the container is `position:absolute` at 0,0 over the page content. Engine JS loaded 3×. |
| — | Startup | RStudio | n/a | `Error in if (totalCols == 0)` at RStudio start comes from RStudio's data viewer restoring a tab for `df` (now `stats::df`), not sideview. |

## Results — 2026-10-24 re-walk after Phase 2.1–2.3 (browser mode)

RStudio 2025.05.1 (R 4.5.1), `viewer = "browser"`, page driven with real mouse input via Claude in Chrome.

| # | Item | Mode | Result | Note |
|---|------|------|--------|------|
| 1 | Launch | B | pass | No console errors; columns and values visible. Cards overlap on launch (#40). |
| 2 | Close | B | pass | Done returns the code; Clear → Done returns `NULL`; a reload keeps the app alive (#35). |
| 8 | Filter | B | pass | Popover opens under a spline without deleting the join; Done returned `patients %>% dplyr::filter(age == 65)`. |
| 9 | Connect | B | pass | Real-click connect works (#36); clicks on cells under a spline reach the card (#37). |
| 11 | Drawer | B | **open** | Drawer auto-opens over cards; code preview centred/truncated (#41); tabs still shared (#15). |
| 12 | Clear | B | pass | Code reset to "", connectors and hit paths removed. |
| — | Assets | B | pass | JS/CSS served from the fingerprinted URL (#38), so updates aren't hidden by the cache. |
| 4 | Toolbar overlap | P | **open** | Toolbar covers card headers; palette overlaps cards in the narrow pane (#42). |
