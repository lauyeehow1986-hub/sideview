# CLAUDE.md — sideview

## What this is
`sideview` is an R package (v0.2.x) that puts many tables side by side on a **2D pan/zoom canvas**.
It runs either as an interactive **Shiny gadget** (`sideview()`, RStudio addin `sideview_addin()`) or as an
exportable **htmlwidget** (`sideview_widget()`, `save_sideview()`, Quarto/Rmd). Users drag table cards,
sort/filter from headers, connect columns with SVG splines to generate `dplyr` joins, inspect
discrepancies, and ask an LLM copilot (Ollama / OpenAI-compatible) for tidyverse code. Generated code is
inserted into RStudio via `rstudioapi`.

Research/education tool — **not for clinical decisions**. Never commit real patient data; fixtures are synthetic.

## Architecture
```
R side                                         Browser side (inst/www)
------                                         -----------------------
sv_normalize() (R/normalize.R)  ->  sideview_card objects
  |-- gadget:  sideview() (R/sideview.R)
  |      sideview_ui()  (R/app_ui.R)   ->  server-rendered HTML cards  ->  sideview.js  initSideview()
  |      sideview_server() (R/app_server.R)  <->  Shiny.setInputValue / sendCustomMessage
  |-- widget:  sideview_widget() (R/widget.R)  ->  JSON cards  ->  inst/htmlwidgets/sideview.js
                                                                   -> new Sideview.Engine(el, opts)
codegen: R/codegen.R (sv_code_* generators)    engine: SideviewEngine + VirtualTable (sideview.js)
llm/copilot: R/llm.R, R/copilot.R              pan/zoom: inst/www/panzoom.min.js (small in-house impl)
state: R/state.R (sv_save_state/sv_load_state) styles: inst/www/sideview.css (--sv-* tokens)
rstudio bridge: R/rstudio.R
```
- Shiny inputs (client → R): `column_mapped`, `column_disconnected`, `column_sorted`, `column_filtered`,
  `column_renamed`, `clear_operations`, `discrepancy_check`, `request_suggested_mappings`,
  `apply_auto_clean`, `run_ai_prompt`, `send_copilot_chat`, `inject_script`, `send_console`,
  `send_console_and_exit`, `eval_env`, `sideview_card_moved`, `sideview_highlight_changed`.
- Custom messages (R → client): `sideview_code_update`, `sideview_discrepancies`,
  `sideview_suggested_mappings`, `sideview_copilot_reply`, `sideview_inject_result`,
  `sideview_console_result`, `sideview_eval_result`.
- Keep this list in sync when adding inputs/messages.

## Build, test, run (Windows, R 4.5.2)
- R: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"`
- Tests: `Rscript -e "devtools::test()"`; full check: `Rscript -e "devtools::check()"`
- JS syntax: `node --check inst/www/sideview.js`
- Docs: `Rscript -e "devtools::document()"` (roxygen → `man/`, `NAMESPACE`); site: `pkgdown::build_site()`
- Try it: `devtools::load_all(); sideview(mtcars, iris, viewer = "browser")` (also `"dialog"`, `"pane"`)

## Conventions
- Exported R functions use the `sv_` prefix (except `sideview*` entry points), `snake_case`, roxygen docs.
- Heavy/optional packages (`arrow`, `duckdb`, `gt`, `flextable`, `bslib`) stay in `Suggests:` behind
  `requireNamespace()` guards.
- CSS: use `--sv-*` design tokens, no hard-coded colours in rules; every token used must be defined.
  Scope all rules under `.sideview-container` — the widget must not restyle a host page.
- Icons: inline SVG icons only — **no emoji/Unicode glyph icons** (they render inconsistently on Windows RStudio).
- JS: escape any user/table-derived text before `innerHTML`; use `CSS.escape` for attribute selectors;
  batch connector redraws with `requestAnimationFrame`; every global listener must be removed in `destroy()`.
- Generated R code must `parse()` — add a test for every new code generator.
- Privacy: only schema summaries go to the LLM, never raw rows.

## Verification rule (important)
`tests/testthat/gui-test-runner.js` runs against a **mock DOM** and cannot catch layout bugs.
Every UI change must also be checked in a **real browser** (shinytest2/chromote layout tests in
`tests/testthat/test-layout-browser.R`) and, for gadget behaviour, **in RStudio itself**
(dialog, Viewer pane, external browser). Record what was verified in `MEMORY.md`.

## Tracking
- `MEMORY.md` — running change log, decisions, open issues, backlog. Update it with every change.
- `plans/` — design specs; `plans/2026-10-24-ui-qa-checklist.md` — the feature QA checklist.
- `NEWS.md` — user-facing release notes.
