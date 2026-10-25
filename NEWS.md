# sideview 0.3.0

A full pass over the user interface, tested in a real browser and in RStudio
(dialog, Viewer pane, external browser, the addin, a saved HTML file and a
Quarto page), plus new features for clinical data work.

## New features

* **Pipeline with history.** Each sort, filter, join, rename, recode, mutate,
  reshape or summarise is a step in the drawer's Pipeline tab. Steps can be
  turned off, reordered or deleted, with undo/redo (`Ctrl+Z` / `Ctrl+Y`) and
  a choice of `%>%` or `|>`. The drawer has real builder tabs: Join, Filter
  (several conditions, AND/OR), Arrange, Mutate, Recode, Reshape and Summarise.
* **Join diagnostics before you join.** Connecting two columns shows the match
  rate in each direction, unmatched keys with examples, the key relationship
  (1:1, 1:m, m:m warning), rows produced by each join type, and NA, spacing or
  case problems in the keys. Also available as `sv_join_diagnostics()`.
* **Column inspector and codebook.** Click a column's inspect icon for type,
  missingness, distinct values, a key check, summary statistics or top levels
  and a histogram. **Export codebook** writes a data dictionary for every card;
  `sv_column_profile()` and `sv_codebook()` do the same from R.
* **Save and open the workspace** from the toolbar. `sideview(..., state =)`
  and `sideview_widget(..., state =)` restore card positions, zoom, sorts,
  filters, joins and the pipeline, and `sv_load_state(launch = TRUE)` now
  really launches.
* **Canvas navigation.** A minimap (bottom-left; `M` hides it), `Ctrl+K` to
  find a card or column, and double-click a card title to zoom to it. **Fit**
  and **Arrange** buttons, and a tidy grid layout at launch.
* **Themes.** `theme = "auto"` (follows RStudio or the browser), `"light"`,
  `"dark"`, `sv_theme()` or a `bslib::bs_theme()`. Every text colour meets
  WCAG AA contrast.
* **Keyboard and accessibility.** Shortcuts (`?` lists them), real buttons with
  labels and visible focus rings, and the OS "reduce motion" setting is
  respected.
* `sv_llm_models()` lists the models an Ollama or OpenAI-compatible server
  offers. AI errors now say how to fix them, and `options(sideview.llm_think)`
  controls Ollama reasoning models. See `?sideview` for all options.

## Bug fixes

* `viewer = "browser"` works again. Closing or reloading the tab no longer
  leaves the console busy or kills the app (`options(sideview.session_grace)`).
* Sort and filter now run on the full data, not just the first 500 rows shown.
  Sort code used `%>` instead of `%>%`.
* Column headers stay put while a table scrolls, so splines stay attached.
  Maximize, minimize, fullscreen (including in the Viewer pane) and card resize
  now behave; the toolbar, palette, drawer and AI bar no longer overlap at any
  window size.
* Click-to-connect no longer starts a stray second connection; sort/filter
  clicks no longer also connect columns; drawer tabs show their own content.
* **Done** returns the generated code and **Cancel** returns `NULL`;
  "Run in R" keeps its result in a named object (`sv_result` by default), in
  the environment `sideview()` was called from (new `env` argument; the
  workspace when called from the console).
* Card and column names are escaped everywhere, so odd names cannot break the
  page.
* Recode and auto-clean emit `dplyr::case_when()` (`case_match()` is deprecated
  in dplyr 1.2).
* A saved or embedded widget hides buttons that need an R session.
* A widget in Quarto or R Markdown no longer stops the page from scrolling or
  restyles the host page.
* Emoji icons are replaced by inline SVG icons that render the same everywhere.

## Internal

* One `sideview-core` HTML dependency with a content-based version, so browsers
  never use stale JavaScript or CSS. The bundled pan/zoom code is now honestly
  named `sv-panzoom.js`.
* New real-browser test suite (`tests/testthat/test-layout-browser.R`, run with
  `NOT_CRAN=true`) checks layout and behaviour with real mouse and keyboard
  input.

# sideview 0.2.0

### Pillar 1: Big Data Scalability & CRAN Readiness
* **DOM Virtualization Engine**: Added `VirtualTable` in `sideview.js` and `sideview.css`, bounding active table DOM nodes to ~30 rows with dynamic spacer elements and supporting 100k+ rows at 60 FPS scrolling.
* **Arrow & DuckDB Lazy Ingestion**: Added zero-copy schema extraction methods (`sv_normalize.arrow_table()`, `sv_normalize.Dataset()`, `sv_normalize.tbl_duckdb_connection()`) with soft-dependency guards in `Suggests:`.
* **Multi-Key Composite Joins**: Enhanced `sv_code_join()` and server reactivity to support vector keys (`by = c("key1" = "key1", "key2" = "key2")`) and relational multi-table pipeline chaining.

### Pillar 2: Advanced Visual Wrangling & Profiling
* **Visual Pivoting Codegen**: Added `sv_code_pivot_longer()` and `sv_code_pivot_wider()` with full syntactic backtick escaping and custom `values_fn` aggregation.
* **Group & Summarize Builder**: Added `sv_code_group_summarize()` generating reproducible `dplyr::group_by(...) %>% dplyr::summarise(..., .groups = 'drop')` workflows.
* **Header Column Profiling**: Embedded inline SVG 5-bin distribution sparklines (`<svg class="sideview-sparkline">`), categorical frequency distribution bars (`.sideview-cat-profile`), and color-coded missingness badges (`.sideview-na-badge`) with 25k-sample performance optimization.

### Pillar 3: Canvas State Persistence & Cloud Sharing
* **State Serialization APIs**: Added `new_sideview_state()`, `sv_save_state()`, and `sv_load_state()` supporting both portable `.json` and native R `.rds` workspace serialization for canvas pan/zoom, card coordinates, splines, and pipelines.

### Pillar 4: Intelligent Copilot & Auto-Mapping
* **Heuristic Foreign Key Detection**: Added `sv_suggest_mappings()` computing 3-part composite scores (name similarity with ID suffix detection, type compatibility, and Jaccard overlap) with precomputed unique sets and logical column exclusion.
* **Suggested Splines & Discrepancy Auto-Clean**: Added animated dashed suggested splines (`.sideview-spline-suggested dashMove`) with click-to-accept join mapping, and `sv_auto_clean_rules()` / `sv_code_auto_clean()` for automatic `dplyr::case_match()` crosswalk synthesis.
* **Conversational AI Copilot Drawer**: Added multi-turn chat tab with context retention (`sv_build_chat_prompt()`), turn-based history sliding window (20 turns), and active pipeline code guards.

### Pillar 5: Automated Computer Use & GUI Verification
* **Automated GUI Test Suite**: Added `tests/testthat/test-computer-use-gui.R` and headless DOM test runner `gui-test-runner.js` verifying 6 core interaction scenarios (canvas coordinates, dragging, port click / spline connect, suggested spline acceptance, sorting/filtering, drawer action dispatch) with diagnostic dumps in `tempdir()`.

# sideview 0.1.0

## Recent Features & Enhancements

### Interactive Canvas & Navigation
* **Dual Synchronized Scrolling**: The sync scroll feature (`[🔗]` link icon in card headers) now synchronously locks both vertical rows (`scrollTop`) and horizontal columns (`scrollLeft`) in proportional lockstep across wide datasets.
* **Interactive Column Spline Disconnection**:
  * Hovering over any connection spline displays a red highlight glow.
  * Direct click or right-click on any spline or connection port immediately removes the connection.
  * Shiny reactivity now dispatches `column_disconnected` to dynamically update code generation and downstream operations.
* **Port State Reset & Clearing**: Enhanced `clearOperations()` to reliably purge active connecting port states (`this.activePort`) and strip visual `.connecting` classes when resetting the canvas.
* **Table Card Snapping & Dragging**: Improved magnetic guideline alignment when dragging cards near each other.
* **Syntax Validation Suite**: Added automated Node.js syntax parsing in `tests/testthat/test-assets.R` to ensure zero runtime script syntax errors.

### Data Manipulation & Code Generation
* **Interactive Column Sorting**:
  * Tri-state toggle on column header sort indicators (`▲` Ascending, `▼` Descending, `original`).
  * Live in-memory row reordering across table cards.
  * Synthesizes and previews corresponding `dplyr::arrange()` pipelines in the Action Drawer.
* **Interactive Column Filtering**:
  * Floating popover activated by column filter icon (`🔍`).
  * Supports numeric comparisons (`>`, `>=`, `<`, `<=`), exact matches (`==`, `!=`), and text substring filters (`contains`).
  * Filters rows in real time and synthesizes `dplyr::filter()` pipelines.
* **Non-Syntactic Identifier Escaping**: Added client-side `escapeColIdentifier()` in `sideview.js` so column names with spaces or symbols (e.g. `Patient ID`, `Glucose (mg/dL)`) are safely wrapped in backticks across filter and arrange pipelines.
* **List-Column & Vector Safeguard**: Hardened HTML grid table rendering in `sideview_ui()` to handle nested list-columns and vectors safely with a `[list]` placeholder, avoiding length > 1 evaluation errors under R 4.2+.

### Action Drawer & Workflow Controls
* **Four Execution Modes**:
  1. `Insert Script`: Pastes code at the current cursor location in the active RStudio script document via `rstudioapi::insertText()`.
  2. `Run & Exit`: Sends code to the R console and closes the gadget immediately.
  3. `Run in R`: Evaluates code directly inside the current R environment (`.GlobalEnv`) with live row/column toast feedback.
  4. `Run Console`: Previews and buffers code for the RStudio console.
* **Clearing Controls**:
  * Added a dedicated `Clear` button in the Action Drawer to reset all active splines, sort orders, and filters.
  * Added an `[✓] Auto-clear` toggle to automatically reset canvas interactions upon code insertion or copy.

### LLM Assistance & Privacy Context
* **Local Ollama Integration**: Full support for local models such as `gemma4:26b` and `llama3.2` with zero data leakage (`http://localhost:11434`).
* **Cloud OpenAI-Compatible Support**: Connect to OpenAI, OpenRouter, Groq, LM Studio, or vLLM.
* **Privacy-Safe Schema Synthesis**: Prompts contain table names, column types, and high-level distribution ranges without exposing confidential raw records.

### Testing & Verification
* **705 Automated Tests**: Full test suite across 9 contexts with 100% pass rate covering universal normalization, codegen, LLM prompts, RStudio bridges, reactive gadget events, HTML widgets, and static asset syntax.

---

# sideview 0.1.0

* Initial release of **`sideview`**: Multi-Table 2D Infinite Canvas for interactive data exploration, visual field mapping, and LLM-assisted Tidyverse code generation.
* Universal S3 normalization engine (`sv_normalize()`) supporting `data.frame`, `tibble`, `base::table`, `matrix`, `gt`, `flextable`, and `htmlwidgets`.
* Standalone self-contained HTML widget export via `save_sideview()`.
* Interactive Shiny Gadget and RStudio Addin (`sideview()`, `sideview_addin()`).
