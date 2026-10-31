# CLAUDE.md — sideview

## What this is
`sideview` is an R package (v0.3.x) that puts many tables side by side on a **2D pan/zoom canvas**.
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
pipeline: inst/www/sv-pipeline.js (SideviewPipeline: typed steps -> composed R code, undo/redo;
          pure JS, no DOM — the single source of generated code in both gadget and widget)
llm/copilot: R/llm.R, R/copilot.R              pan/zoom: inst/www/sv-panzoom.js (small in-house impl)
state: R/state.R (sv_save_state/sv_load_state) styles: inst/www/sideview.css (--sv-* tokens)
rstudio bridge: R/rstudio.R
```
- Shiny inputs (client → R): `column_mapped`, `column_disconnected`, `column_sorted`, `column_filtered`,
  `column_renamed`, `clear_operations`, `discrepancy_check`, `request_suggested_mappings`,
  `apply_auto_clean`, `run_ai_prompt`, `send_copilot_chat`, `inject_script`, `send_console`,
  `send_console_and_exit`, `eval_env`, `sideview_card_moved`, `sideview_highlight_changed`,
  `sideview_rows_request`, `join_diagnostics_request`, `column_profile_request`, `codebook_export`,
  `state_save`, `state_open_request`,
  `sideview_done`, `sideview_cancel`,
  `cancel` (miniUI dialog close).
- Custom messages (R → client): `sideview_code_update`, `sideview_discrepancies`,
  `sideview_suggested_mappings`, `sideview_copilot_reply`, `sideview_inject_result`,
  `sideview_console_result`, `sideview_eval_result`, `sideview_rows`, `sideview_ai_status`,
  `sideview_join_diagnostics`, `sideview_column_profile`, `sideview_codebook_saved`,
  `sideview_state_saved`, `sideview_state_loaded`,
  `sideview_toast` (`{text, type, id?, card?}`: a notice from R, e.g. the lazy-to-preview fallback; a toast with the same `id` is updated in place, as for codebook progress; `card` is the id of the card the notice is about: the browser then sets that card's `data-rows-basis` to `preview`, as for a lost link).
- `sideview_code_update` carries `source`: `event` (echo of a client step; ignored), `auto_clean`
  (appended as a custom step), `copilot` (offered in the chat bubble only), `ai`/absent (replaces the pipeline).
- Keep this list in sync when adding inputs/messages.
- **Lazy (arrow / duckdb) cards:** `new_sideview_card()` keeps the user's object as `source` (plus `code_ref`,
  `is_lazy`, `lazy_source`); `card$data` stays the 50-row preview and `dims[1]` the true row count. **`source` is
  never serialised**: not in widget JSON, state or card attributes (test-lazy.R checks this). All lazy logic is
  in `R/lazy.R`: the `sv_lazy_*` functions are twins of the in-memory ones (`sv_lazy_rows_window` /
  `sv_rows_window`, `sv_lazy_join_diagnostics`, `sv_lazy_column_profile`), and test-lazy.R holds them to the data
  frame result with `expect_equal(tolerance = 1e-12)` over duckdb and arrow fixtures. Change a twin together
  with its in-memory function. Lazy tables are never collected: only summaries, row windows and
  `collect(head(tbl, 0))` (for R classes) come back. One private duckdb connection per Shiny session
  (`sv_lazy_env()`), closed in `onSessionEnded`; a user's connection is left clean. A lost link or a missing
  duckdb falls back to the preview with one `sideview_toast`. Do not use `is.nan()`/`is.infinite()` in lazy
  expressions (dbplyr turns them into `PRINTF('%f', col)`, which fails on integer types): use `isnan()`/`isinf()`.
  Lazy "contains" is `str_detect(col, "<escaped literal>")`, never `stringr::fixed()`.
- **Codebook:** `sv_codebook()` has a `rows_profiled` column after `n` (`n` = true row count, `rows_profiled` =
  rows profiled; equal except for a preview-only card). `SideviewPipeline.codebookRow()`/`codebookCsv()` write the
  same column, so the byte-equal CSV test still holds.
- **Join diagnostics:** `sv_join_diagnostics()` (R/diagnostics.R) and `SideviewPipeline.joinDiagnostics()`
  (sv-pipeline.js) are twins with the same snake_case fields; `test-diagnostics.R` checks parity and that row
  counts equal dplyr (NA matches NA, as `na_matches = "na"`). The gadget asks R (`join_diagnostics_request`,
  full data); the widget computes in the browser. Change both together. The date-rule check is a third twin:
  `sv_join_diagnostics(rule =)` (R/join_rules.R), `sv_lazy_join_diagnostics(rule =)` (R/lazy.R) and
  `joinDiagnostics(..., { rule })` (sv-pipeline.js) agree with dplyr's `join_by()`; a rule that does not hold
  gives `{error}` with none of the usual fields, and the engine shows that as the key-check error state.
  `join_diagnostics_request` is `{id, left, right, by, rule?}` (`id` = `pipeline.joinSig()`; a rule column missing
  from a table answers `Not in <table>: <col>` like a key); the reply adds `rule`, `rule_kind`, `rule_dropped_x/y`
  and `strict_args`, which the engine hands to `pipeline.setJoinCheck(id, strict_args)` for Strict.
- **Join check cache:** a path that replaces a card's data (none exists today) must call `clearJoinChecks()` and reset `joinDiag`, or stale checks (and rule drops) stay on screen.
- **Column inspector / codebook:** same twin rule. `sv_column_profile()` / `sv_codebook()` (R/codebook.R) and
  `SideviewPipeline.columnProfile()` / `codebookRow()` / `codebookCsv()` (sv-pipeline.js); `test-codebook.R`
  checks the fields, the issue texts and that the JS CSV is byte-equal to `write.csv(sv_codebook(...))`.
  The gadget profiles in R (`column_profile_request`) and writes the codebook via `sv_choose_codebook_path()`
  (RStudio save dialog, else a new `codebook*.csv` in `getwd()`); the widget downloads a CSV Blob.
- **Workspace state (v0.3.0 schema):** `engine.getState()` / `applyState()` (sideview.js) and `R/state.R`.
  State crosses the wire as **JSON text** (`sv_state_json()` / `sv_state_from_json()`), never as a Shiny
  list, so one-element arrays and nulls survive. `sideview(state =)` embeds it in
  `<script class="sideview-state">`; the widget passes `options.state`. Cards match by **name**; a restored
  view skips the first auto-fit. Open replaces joins and pipeline and clears undo. Save/Open use
  `rstudioapi::selectFile` only in the gadget when `data-sv-file-dialog="r"`; otherwise browser download/file picker.
- **"No code"** is `""` on the wire. The drawer placeholder (`# Connect two columns ...`) is display text only;
  test with `sv_is_no_code()` (R) / `isNoCode()` (JS). Done with no code returns `NULL`.
- **Gadget lifecycle:** `sv_new_lifecycle()` counts sessions; the app stops only after
  `getOption("sideview.session_grace", 5)` seconds with no session, so a browser reload survives.
- **Splines:** visible paths (`.sideview-connector-svg`, z 25) are `pointer-events: none`. Clicks go to invisible
  hit paths in `.sideview-connector-hitlayer` (z 5, below the cards at z 10). Create a hit path for every new
  connector (`attachHitPath`) and prune it on removal (`pruneHitPaths`).
- **Theme:** `theme =` on `sideview()`/`sideview_widget()`/`sideview_ui()` takes `"auto"|"light"|"dark"`,
  `sv_theme()` or a `bslib::bs_theme()` (R/theme.R → `sv_resolve_theme()`). The gadget carries it as the
  container class `sv-theme-<mode>` plus inline `--sv-*` overrides; the widget passes `options.theme` /
  `options.themeVars` to `Engine.applyTheme()` / `applyThemeVars()`. Dark tokens live in
  `.sv-theme-dark` and in `@media (prefers-color-scheme: dark) .sv-theme-auto` — keep the two blocks equal
  (test-theme.R checks it, plus WCAG ≥ 4.5:1 for every text/background pair).
- **Mode-aware overrides:** a custom colour that must differ by mode uses `-light`/`-dark` variables:
  the base block has `--sv-primary-text: var(--sv-primary-text-light, #...)`, the dark blocks use
  `var(--sv-primary-text-dark, #...)`. Use `--sv-primary-text` (not `--sv-primary`) for primary-coloured *text*.
- **Keyboard:** single-key shortcuts (F, 0, +/-, T, D, M, /, ?) and Ctrl+K (card search) only fire when the
  canvas owns the keyboard (`ownsKeyboard()`: standalone, or focus inside an embedded widget) and never while
  typing. Ctrl+Enter submits a drawer builder. Add new shortcuts to the `?` dialog list too.
- **Navigation:** `zoomToCard()` (title double-click, minimap click, Ctrl+K result), the minimap (`renderMinimap()`,
  redrawn from `scheduleConnectorUpdate()`) and the search dialog live in `sideview.js`. Chrome z-order: minimap 105 <
  overlay 110 < drawer 120 < AI bar 130 < search/shortcut scrims 140. The container gets `sv-narrow` (< 720px) and
  `sv-compact` (< 1040px) from `initLayoutObserver()`; use them for responsive chrome rules.
- **Assets:** dependency versions come from `sv_asset_version()` (package version + content fingerprint),
  so browsers never serve stale JS/CSS. Don't hard-code a version for `sideview.js`/`sideview.css`.

## Build, test, run (Windows, R 4.5.2)
- R: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"`
- Tests: `Rscript -e "devtools::test()"`; full check: `Rscript -e "devtools::check()"`.
  Real-browser tests are skipped "on CRAN": set `NOT_CRAN=true` to run them.
- Prefer real input (`b$Input$dispatchMouseEvent` via chromote) over `dispatchEvent` in browser tests —
  synthetic events skip hit-testing, which is how overlay bugs slipped through.
- JS syntax: `node --check inst/www/sideview.js`
- Docs: `Rscript -e "devtools::document()"` (roxygen → `man/`, `NAMESPACE`); site: `pkgdown::build_site()`
  (set `RSTUDIO_PANDOC` to RStudio's `resources/app/bin/quarto/bin/tools`). Every push to `main` deploys the site twice:
  Pages' legacy build serves the committed `docs/` folder, and `.github/workflows/pkgdown.yaml` rebuilds it in CI
  and deploys that (usually last). Keep the committed `docs/` current too. Run
  `pkgdown::check_pkgdown()` first: every export must be in the `_pkgdown.yml` reference index. pkgdown renders
  every root `.md`, so delete `docs/CLAUDE.*` / `docs/MEMORY.*` and their `sitemap.xml` / `search.json` entries
  (the workflow does this in CI with its "Drop dev notes" step).
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
