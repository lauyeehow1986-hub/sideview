# sideview Shiny module and proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `sideviewUI(id)` + `sideviewServer(id, ...)` put an R-backed sideview canvas into any Shiny app (several per
page), driven from server code through a `sideview_proxy` (add / replace / remove cards, set state, highlight) and read
back through `$code()`, `$pipeline()`, `$state()`, `$cards()`.

**Architecture:** The module wraps the existing `sideview_server_impl()` in `shiny::moduleServer()`, so every R-backed
feature (row windows, lazy cards, join check, inspector, codebook) is the gadget's code. Cards live in a mutable R store
(`sv_card_store()`) that is the single source of truth; the browser gets a 500-row preview plus `totalRows` and pages the
rest from R. In the browser, every engine input is prefixed with its namespace and one global set of custom-message
handlers routes messages by `ns` to an engine registry; the pipeline gains one pure function that disables steps whose
columns are gone.

**Tech Stack:** R 4.5.2, shiny (moduleServer, testServer), htmltools, jsonlite; plain JS (no build step); Node for the
pipeline tests; mock-DOM `gui-test-runner.js`; chromote/callr real-browser tests.

**Spec:** `plans/2026-10-31-sideview-proxy-design.md`

## Global Constraints

- R: `"/c/Program Files/R/R-4.5.2/bin/Rscript.exe"`. Browser tests need `NOT_CRAN=true`. Never run two browser runs at
  once (they share Chrome's port).
- The gadget and the widget behave exactly as today: `test-app.R`, `test-widget.R`, `test-lazy*.R`, `test-layout-browser.R`
  and every existing `gui-test-runner.js` scenario pass **without edits** to their assertions.
- Module mode never runs browser-sent code: `inject_script`, `send_console`, `send_console_and_exit`, `eval_env`,
  `sideview_done`, `sideview_cancel`, `cancel` have no observer, and the four `data-r-only` buttons are not rendered.
- Full data never goes to the browser from a module: payloads carry at most **500** preview rows plus `totalRows`.
- Snapshot limit: **1 MB** (`1e6` bytes over `code` + `pipeline` + `state`); debounce **300 ms**.
- Exact user-visible texts (spec sections 6 and 9) are copied verbatim from the spec; the remove toast is
  `labs removed: 2 steps disabled` (ruling R8).
- `source` of a lazy card is never serialised (CLAUDE.md); `sv_card_payload()` drops it.
- JS: escape table-derived text before `innerHTML`, `CSS.escape` in selectors, global listeners only via
  `listenGlobal()` (removed in `destroy()`), connector redraws batched with rAF. CSS: `--sv-*` tokens only, scoped under
  `.sideview-container`. Inline SVG icons only.
- New exports: `sideviewUI`, `sideviewServer`, `sideviewProxy`, `sv_add_card`, `sv_replace_card`, `sv_remove_card`,
  `sv_set_state`, `sv_highlight`, roxygen-documented, in a "Shiny module" group of `_pkgdown.yml`.
- Synthetic data only. Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No push, merge or PR
  without the user's yes.

## Rulings on the spec (made while planning; binding for the tasks)

- **R1. R-backed vs gadget-only in the browser.** A new `engine.hasR()` is true for the gadget and for a module
  (`options.ns` is a string) when `Shiny` exists. Row paging, the join check and the column inspector use `hasR()`
  (today they test `mode !== 'embedded'` / `isGadget()`). `isGadget()` keeps gating code execution (`sendToR`) and
  the R file dialog. In a module, Save/Open use the browser download/picker (as the widget).
- **R2. Codebook in a module stays R-backed but downloads in the browser:** the `codebook_export` handler, in module
  mode, writes the CSV to text (same `sv_write_codebook` columns) and replies `sideview_codebook_saved` with
  `{csv, filename: "codebook.csv"}`; the engine downloads a Blob when `csv` is present. Gadget unchanged.
- **R3. Router membership.** Only engines with `options.ns` (module, key = that string) or `mode: 'standalone'`
  (gadget, key `""`) join the registry. Embedded htmlwidget engines never register, so a `renderSideview()` widget on
  the same page never receives or steals R messages.
- **R4. `ns` value** is the full prefix `session$ns("")` (e.g. `"review-"`, nested `"outer-review-"`); the gadget's is `""`.
  Inputs are named `ns + name`; R handlers inside `moduleServer` need no change (Shiny strips the prefix).
- **R5. Queue.** Before `sideview_ready`, only **non-card** messages (`sideview_state_set`, `sideview_highlight`) are
  queued. Cards are never queued: on every `sideview_ready`, R sends `sideview_card_add` for every card in the store
  (store order), then flushes the queue in order. The `state =` argument is queued at start.
- **R6. Spline removal on replace/remove is visual only:** remove the path and hit path; do not call
  `pipeline.removeJoinKey()` and do not send `column_disconnected` (the join step is disabled by the pipeline instead).
- **R7. Column tracking for the missing-column check** (per table chain, in step order): start from the card's new
  columns; `rename` maps `from`→`to`; `mutate` adds `name`. After an enabled `join` (this table on the left),
  `summarise`, `reshape` or `custom` step on that table, the column set is unknown and later steps on that table are
  **kept unchecked**. Columns each step needs: arrange `cols[].col`; filter `conds[].col`; recode `col`; rename `from`;
  summarise `groups[]` + `aggs[].col` (where present); reshape `namesFrom`, `valuesFrom` (wider) or `cols[]` (longer);
  join as left `by[].left` + rule `xCol`/`xFrom`/`xTo`; join as right `by[].right` + rule `yCol`/`yFrom`/`yTo`, checked
  against the right table's columns at the end of its own chain (unknown → kept). `mutate` expressions are not parsed.
- **R8. Toasts.** Replace: `<name> refreshed: <n> step(s) disabled (<cols> not found)` with `<cols>` the unique missing
  columns joined by `", "`, e.g. `labs refreshed: 2 steps disabled (lab_dt not found)`; singular `1 step`. Remove:
  `<name> removed: <n> step(s) disabled`. No toast when `n = 0`.
- **R9. `sv_highlight()` colour** is the canvas's selected swatch, or `"blue"` when none/clear. Columns not on the card
  are ignored.
- **R10. `sideview_server_impl()`** gains `module = FALSE` and returns `invisible(list(store = <sv_card_store>, send =
  <function(type, message)>))`. `send` adds `ns` to every message in module mode.
- **R11. One lazy connection per session:** `sv_session_lazy_env(session)` creates the duckdb env once in
  `session$userData$sv_lazy_env` and registers one `onSessionEnded` close; the gadget and every module use it.
- **R12. Duplicate DOM ids.** The chat input/send button lose their `id`s (classes `.sideview-chat-input` /
  `.sideview-chat-send` remain); `sideview.js` selects by class.

## Review Focus

1. **Keyboard isolation:** with two canvases, pressing `F` while canvas A has focus fits only A (B's transform
   unchanged). Test in Task 6.
2. **Zero-row replace:** `sv_replace_card()` with a 0-row data frame gives `totalRows = 0`, an empty card, no JS error.
   Tests in Task 5 (payload) and Task 6 (browser).
3. **Hostile names:** a card named `a"b <i>x</i>` added through the proxy shows that exact text as its title (escaped),
   and replace/remove find it. Test in Task 4.
4. **Nested modules:** a canvas started inside module `outer` is reached by `sideviewProxy("review")` from inside `outer`
   and its messages carry `ns = "outer-review-"`. Test in Task 5.
5. **Widget beside a module:** an embedded engine without `ns` does not join the registry and ignores routed messages.
   Test in Task 2.

---

### Task 1: R card store, card payload, shared normalisation and lazy env

**Files:**
- Create: `R/card_store.R`
- Modify: `R/app_server.R` (card normalisation lines 21-53, every `cards_by_name[[...]] %||% cards_by_id[[...]]`,
  `normalized_cards`, the codebook `Filter(...)`, `con_env <- sv_lazy_env()` + its `onSessionEnded`), `R/widget.R:105-127`,
  `R/app_ui.R:383-409`
- Test: `tests/testthat/test-card-store.R`

**Interfaces:**
- Produces:
  - `sv_normalize_cards(cards) -> list<sideview_card>`: the normalisation both `sideview_server_impl()` and
    `sideview_ui()` do today (single object → list; unnamed → `Table_<i>`; unnormalisable elements dropped).
  - `sv_card_store(cards = list()) -> environment` with `add(card)`, `replace(name, card)`, `remove(name)`,
    `get(key)` (by name, then by id; `NULL` if absent), `names()` (character, insertion order; a replace keeps the slot),
    `all()` (named list by card name, in order), `has(name)` (logical).
  - `sv_card_payload(card, preview_rows = NULL) -> list`: the widget's card list (labels, `col_types` as list,
    `source` dropped, `lazy`, `codeRef`, `totalRows`); when `preview_rows` is a number, `data` is cut to
    `head(data, preview_rows)` and `remote = TRUE` is added; `totalRows` always the true count.
  - `sv_session_lazy_env(session) -> environment` (ruling R11).

- [ ] **Step 1: Write the failing tests** in `test-card-store.R`:
  `store keeps order and finds by name or id` (add a, b; `get("b")` and `get(<b's id>)` identical; `names()` == `c("a","b")`;
  replace a → `names()` still `c("a","b")` and `get("a")$data` is the new data; remove a → `names()` == `"b"`, `get("a")` NULL);
  `payload cuts to the preview and keeps the true row count` (`mtcars[rep(1:32, 20), ]`, `preview_rows = 500` →
  `nrow(p$data) == 500`, `p$totalRows == 640L`, `isTRUE(p$remote)`; `preview_rows = NULL` → 640 rows, `remote` NULL);
  `payload of a zero-row frame` (`mtcars[0, ]` → `p$totalRows == 0L`, 0 rows);
  `payload never carries source` (duckdb card, `skip_if_not_installed("duckdb")`: `is.null(p$source)`, `p$lazy == "duckdb"`);
  `sv_normalize_cards names unnamed tables` (`list(mtcars, b = iris)` → names `Table_1`, `b`);
  `one lazy env per session` (`session <- shiny::MockShinySession$new()`; two calls return `identical()` envs).
- [ ] **Step 2: Run** `"/c/Program Files/R/R-4.5.2/bin/Rscript.exe" -e "devtools::test(filter='card-store')"` — Expected: FAIL (functions not found).
- [ ] **Step 3: Implement** `R/card_store.R`; replace `R/widget.R:105-127` with a call to `sv_card_payload(card)`;
  make `sideview_ui()` and `sideview_server_impl()` use `sv_normalize_cards()`; route every card lookup in
  `sideview_server_impl()` through one `card_store <- sv_card_store(sv_normalize_cards(cards))`; use
  `sv_session_lazy_env(session)` instead of `sv_lazy_env()` + its own `onSessionEnded`.
- [ ] **Step 4: Run** the new tests, then `devtools::test()` — Expected: all PASS, existing suites unchanged.
- [ ] **Step 5: Commit** `refactor(server): one mutable card store, shared card payload and lazy env`.

### Task 2: Browser transport: namespaces, engine registry, `hasR()`

**Files:**
- Modify: `inst/www/sideview.js` (`sendToShiny` callers inside the engine, `registerShinyHandlers` ~5475, the R-backed
  checks at ~4010 / 4329 / `attachRemoteRows` ~3076, `destroy` ~1478, chat selectors ~2169/2197, `initSideview` ~5743),
  `R/app_ui.R` (drop the two chat `id`s, ruling R12)
- Test: `tests/testthat/gui-test-runner.js` (new scenario block), `tests/testthat/test-computer-use-gui.R` (assertions)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - Engine option `ns` (string or absent); `engine.ns` = `options.ns` if a string, else the container's `data-sv-ns`
    attribute if present, else `""`.
  - `SideviewEngine.prototype.send(name, value) -> boolean` = `sendToShiny(this.ns + name, value)`; every engine-side
    `sendToShiny(` call becomes `this.send(` / `self.send(` (including the VirtualTable remote request closure).
  - `SideviewEngine.prototype.hasR() -> boolean` (ruling R1).
  - `SideviewEngine.prototype.onMessage(type, fn)`: stores `fn` in `this._handlers[type]` and makes sure one global
    `Shiny.addCustomMessageHandler(type, router)` exists (flag map on `global.__sideviewRouted`); `router(data)` looks up
    `global.__sideviewEngines[(data && data.ns) || '']` and calls its handler, else `console.warn` and returns.
    `registerShinyHandlers` registers every existing handler through `onMessage` (bodies unchanged).
  - Registry `global.__sideviewEngines` (ruling R3): on construction, a registering engine destroys any engine already
    under its key; `destroy()` unregisters (only if the entry is itself). The router drops entries whose
    `container.isConnected === false` before routing.

- [ ] **Step 1: Write the failing scenario** in `gui-test-runner.js` (results keys asserted in `test-computer-use-gui.R`):
  `module_input_prefix` (engine with `{ns: 'a-'}`: a sort click records an input named `a-column_sorted`);
  `gadget_input_unprefixed` (standalone engine: `column_sorted`);
  `route_by_ns` (two module engines `a-`/`b-`; `shinyHandlers.sideview_toast({ns:'b-', text:'hi'})` shows a toast in B only);
  `unknown_ns_ignored` (`{ns:'zz-'}` → no throw, a `console.warn` captured);
  `reregister_destroys_old` (new engine with `ns:'a-'` → old A's `destroy` ran, registry holds the new one);
  `widget_not_registered` (`{mode:'embedded'}` without `ns` → `__sideviewEngines` has no entry for it; a routed
  `{ns:''}` toast does not reach it) — Review Focus 5;
  `module_hasR` (`{mode:'embedded', ns:'a-'}` → `hasR() === true`, `isGadget() === false`).
- [ ] **Step 2: Run** `"/c/Program Files/R/R-4.5.2/bin/Rscript.exe" -e "devtools::test(filter='computer-use-gui')"` — Expected: the new assertions FAIL.
- [ ] **Step 3: Implement** the interfaces above; `node --check inst/www/sideview.js`.
- [ ] **Step 4: Run** the GUI test file, then `devtools::test()` — Expected: all PASS, old scenarios unchanged.
- [ ] **Step 5: Commit** `feat(js): namespaced inputs and an ns-routed message registry`.

### Task 3: Pipeline: disable steps whose columns are gone

**Files:**
- Modify: `inst/www/sv-pipeline.js`
- Test: `tests/testthat/test-pipeline.R`

**Interfaces:**
- Produces: `Pipeline.prototype.disableMissing(table, columns) -> { disabled: [{ id, kind, missing: [col] }], missing: [col] }`
  — `columns` is the table's new column array, or `null` meaning "the table is gone" (every step on it, and every join
  with it on either side, is disabled with `missing: []`). One undoable change labelled `'refresh'`; if anything was
  disabled, `undoStack` and `redoStack` are then emptied; if nothing was, history is untouched and no event fires.
  Already-disabled steps are skipped. Column tracking and per-kind fields: ruling R7.

- [ ] **Step 1: Write the failing tests** (`run_pipeline_js`), each asserting the returned ids and `p.steps[i].enabled`:
  `disableMissing keeps steps whose columns exist` (arrange on `id`, filter on `val`; new columns `id,val` → nothing
  disabled, `p.undoStack.length` unchanged);
  `disableMissing disables a filter on a dropped column` (`missing == ['lab_dt']`, step disabled, undo/redo emptied);
  `disableMissing follows renames and mutates` (rename `lab_dt`→`d`, then arrange on `d`; new columns contain `lab_dt` →
  kept; mutate `z` then filter on `z` → kept);
  `disableMissing stops checking after a summarise` (filter on `nope` after a summarise → kept);
  `disableMissing checks both sides of a join` (join visits→labs `by id=pid`; `disableMissing('labs', ['id','val'])` →
  join disabled, `missing == ['pid']`);
  `disableMissing with null disables everything on the table` (steps on labs + the join → all disabled);
  `compose skips disabled steps and still parses` (`expect_parses(p.compose())`).
- [ ] **Step 2: Run** `devtools::test(filter='pipeline')` — Expected: FAIL (`disableMissing is not a function`).
- [ ] **Step 3: Implement** `disableMissing` in `sv-pipeline.js` (pure, no DOM).
- [ ] **Step 4: Run** the pipeline tests — Expected: PASS.
- [ ] **Step 5: Commit** `feat(pipeline): disableMissing() for refreshed or removed tables`.

### Task 4: Engine: card add/replace/remove, state, highlight, ready, snapshot

**Files:**
- Modify: `inst/www/sideview.js`
- Test: `tests/testthat/gui-test-runner.js`, `tests/testthat/test-computer-use-gui.R`

**Interfaces:**
- Consumes: `engine.send`, `engine.onMessage`, `engine.hasR()` (Task 2); `pipeline.disableMissing` (Task 3); card
  payload fields from `sv_card_payload()` (Task 1: `name`, `data`, `col_types`, `totalRows`, `remote`, `lazy`, `codeRef`).
- Produces (all on `SideviewEngine.prototype`):
  - `addCard(cardData, index)`: when `cardData.remote` is true, set the card element's `data-total-rows` and call
    `attachRemoteRows` (as `initExistingCards` does).
  - `replaceCard(cardData) -> {disabled, missing}`: keep x/y/width/height/minimized; rebuild the card under the same name
    (remove element + VirtualTable, `addCard` at the kept geometry); then `pipeline.disableMissing(name, columns)`; remove
    splines whose column on this card is gone (ruling R6); clear highlights on missing columns; `pipeline.clearJoinChecks()`
    and `this.joinDiag = {}`, `this.joinDiagPending = {}`; re-run checks for enabled joins; toast (ruling R8);
    `scheduleConnectorUpdate()`.
  - `removeCard(name) -> {disabled}`: remove element, VirtualTable, its splines (R6); `disableMissing(name, null)`; toast (R8).
  - `highlightColumns(name, cols)`: the header-click highlight (extracted from the click handler ~2280) for each column
    present, colour per ruling R9.
  - Message handlers via `onMessage`: `sideview_card_add` (`addCard(data.card, this.cards.size)`),
    `sideview_card_replace`, `sideview_card_remove` (`data.name`), `sideview_state_set` (`applyState(JSON.parse(data.state))`,
    then clear undo, as Open does), `sideview_highlight` (`data.name`, `data.cols`). Unknown card → `console.warn`, no-op.
  - Module mode only (`typeof options.ns === 'string'`): `send('sideview_ready', {nonce: Date.now()})` once the Shiny
    session is connected (retry like `requestJoinDiag` until `send` returns true); `scheduleSnapshot()` debounced
    **300 ms**, called from the pipeline `onChange` (except label `'checks'`) and after card move / resize / minimize /
    add / replace / remove, sending `sideview_snapshot` =
    `{code: <pipeline.compose(), '' when isNoCode>, pipeline: JSON.stringify(pipeline.steps), state: JSON.stringify(getState()), cards: [names]}`.
  - `codebook_export` reply with `csv` → Blob download (ruling R2). In module mode, Save/Open take the browser path.

- [ ] **Step 1: Write the failing scenario** (module engine `ns:'m-'`, mock Shiny), result keys:
  `module_sends_ready` (an `m-sideview_ready` input was set);
  `card_add_remote` (routed `sideview_card_add` with a 500-row `data`, `totalRows: 5000`, `remote: true` → card exists and its
  VirtualTable is remote, an `m-sideview_rows_request` is sent);
  `replace_keeps_geometry` (move card to 300,200, replace → same x/y);
  `replace_disables_and_toasts` (filter on `lab_dt`, replace without `lab_dt` → step disabled, toast text exactly
  `labs refreshed: 1 step disabled (lab_dt not found)`, spline on `lab_dt` gone, no `m-column_disconnected` sent);
  `replace_clears_join_checks` (`engine.joinDiag` empty right after);
  `remove_card` (card gone, its join disabled, toast `labs removed: 1 step disabled`);
  `hostile_name` (add a card named `a"b <i>x</i>` → title `textContent` equals the name, no `<i>` element; replace and
  remove find it) — Review Focus 3;
  `snapshot_debounced` (three pipeline changes within 100 ms → after 350 ms exactly one `m-sideview_snapshot`, whose
  `JSON.parse(state)` has the cards);
  `gadget_no_snapshot` (standalone engine: no `sideview_snapshot` and no `sideview_ready` input).
  Use the runner's fake timers if present; otherwise advance with the runner's existing timeout helper.
- [ ] **Step 2: Run** the GUI test file — Expected: new assertions FAIL.
- [ ] **Step 3: Implement**; `node --check inst/www/sideview.js`.
- [ ] **Step 4: Run** the GUI test file, then `devtools::test()` — Expected: all PASS.
- [ ] **Step 5: Commit** `feat(js): add/replace/remove cards, state and highlight from R; ready and snapshot inputs`.

### Task 5: R module, proxy and verbs

**Files:**
- Create: `R/module.R`
- Modify: `R/app_server.R` (`module = FALSE` argument, skip the gadget-only observers when `module`, `send` adds `ns`,
  codebook text reply per R2, return value per R10), `R/app_ui.R` (extract the container builder so `sideviewUI()` reuses
  the chrome without cards, without `sv-standalone`, without the `data-r-only` buttons, with `data-sv-ns` and a
  per-container init script), `NAMESPACE`/`man/` via `devtools::document()`
- Test: `tests/testthat/test-module.R`

**Interfaces:**
- Consumes: `sv_card_store`, `sv_card_payload`, `sv_normalize_cards`, `sv_normalize_arg(val, nm)` (Task 1); input/message
  names from Tasks 2 and 4.
- Produces (exported, signatures from spec section 4):
  - `sideviewUI(id, height = "600px", title = NULL, theme = "auto") -> tagList`; the container has class
    `sideview-container sv-theme-<mode>`, `data-sv-ns = shiny::NS(id)("")`, style `height: <height>; position: relative`,
    and its init script calls `initSideview(<this container>, {mode: 'embedded', ns: '<ns>'})`, selecting the container
    by `[data-sv-ns="<CSS.escape(ns)>"]`. `title = NULL` shows no brand text.
  - `sideviewServer(id, cards = list(), state = NULL, llm_fn = NULL) -> sideview_proxy`.
  - `sideviewProxy(id, session = shiny::getDefaultReactiveDomain()) -> sideview_proxy`.
  - `sv_add_card(proxy, x, name)`, `sv_replace_card(proxy, name, x)`, `sv_remove_card(proxy, name)`,
    `sv_set_state(proxy, state)`, `sv_highlight(proxy, name, cols)`: each returns `invisible(proxy)`.
  - `sideview_proxy`: a list of class `"sideview_proxy"` with `id`, `ns`, `session`, reactives `code`, `pipeline`,
    `state`, `cards`, and `ctl` (environment: `store`, `send`, `ready` (logical), `queue` (list)). Registered at
    `session$userData$sideview[[ns]]` (the root session's `userData`). Payloads use `preview_rows = 500L`.
  - Snapshot parsing: `sv_parse_snapshot(x) -> list(code, pipeline, state) | NULL` (NULL = drop: over `1e6` bytes total,
    or JSON that fails to parse); non-string or length ≠ 1 `code` becomes `""`.

- [ ] **Step 1: Write the failing tests** in `test-module.R` with `shiny::testServer(sideviewServer, args = list(id = "cv", cards = list(visits = visits, labs = labs)), {...})`
  and a helper `msgs(type)` filtering `session$userData$custom_messages`:
  `nothing is sent before ready` (no `sideview_card_add` yet);
  `ready sends every card in store order with ns` (`session$setInputs(sideview_ready = list(nonce = 1))` → two
  `sideview_card_add`, names `visits`,`labs`, every message's `ns` identical to `session$ns("")` (testServer picks the
  prefix, so never hard-code it), payload `remote` TRUE and ≤ 500 rows);
  `a second ready resends the cards` (four `sideview_card_add` in total);
  `state is queued until ready, after the cards` (with `state = <state object>`: the `sideview_state_set` comes after the
  card adds);
  `verbs update the store before sending` (after ready: `sv_replace_card(px, "labs", labs[0, ])` → `ctl$store$get("labs")`
  has 0 rows and the last message is `sideview_card_replace` with `totalRows == 0L`) — Review Focus 2;
  `cards() updates right after a verb` (`sv_add_card(px, mtcars, "cars")` → `px$cards()` == `c("visits","labs","cars")`);
  `reactive cards are diffed by name` (`cards = reactive(rv())`; changing `rv` from (a, b) to (b', c) sends replace b,
  add c, remove a; setting `rv` to an identical list sends nothing);
  each spec section 9 error with `expect_error(..., "<exact message>", fixed = TRUE)`: `Card 'labs' already exists; use
  sv_replace_card()`, `No card 'labz'. Cards: visits, labs`, `sideviewProxy() needs a Shiny session: call it inside a
  server function` (called with `session = NULL`), `sideviewServer("nope") has not been started in this session`,
  `'name' must be a single string`, `'cols' must be a character vector`;
  `refused inputs in module mode` (`session$setInputs(eval_env = list(code = "stop('ran')"))` and `inject_script`,
  `send_console`, `send_console_and_exit` → no error, no `sideview_eval_result`/`sideview_inject_result`/
  `sideview_console_result` message);
  `snapshot sets the reactives` (`sideview_snapshot = list(code = "x <- 1", pipeline = "[]", state = <json>, cards = list())`
  → `px$code() == "x <- 1"`, `px$pipeline()` is `list()`, `px$state()` is a state object);
  `bad snapshots are dropped` (2e6-char `code`; `pipeline = "{"`; `code = list(1, 2)` → first two keep the previous
  values with a `warning`, the third gives `px$code() == ""`);
  `nested modules` (`testServer` on an outer module that calls `sideviewServer("review", ...)` and then
  `sideviewProxy("review")` → `identical(px1$ctl, px2$ctl)`, and every message's `ns` equals
  `session$ns("review-")` of the outer session, i.e. it ends in `outer-review-` style nesting) — Review Focus 4;
  `lazy card replaced in a module` (`skip_if_not_installed("duckdb")`: replace with a duckdb table → payload `lazy ==
  "duckdb"`, a following `sideview_rows_request` answers from the new table);
  `module UI has no code-running buttons and no html-level rules` (`as.character(sideviewUI("cv"))` contains
  `data-sv-ns="cv-"`, no `data-r-only`, no `sv-standalone`, no `id="sideview-chat-input"`);
  `codebook in a module replies with csv` (`codebook_export` input → `sideview_codebook_saved` has a non-empty `csv`
  that `utils::read.csv(text =)` reads with a `rows_profiled` column).
- [ ] **Step 2: Run** `devtools::test(filter='module')` — Expected: FAIL (functions not found).
- [ ] **Step 3: Implement** `R/module.R` and the `app_server.R` / `app_ui.R` changes; `devtools::document()`.
- [ ] **Step 4: Run** `devtools::test()` — Expected: all PASS (gadget suites unchanged).
- [ ] **Step 5: Commit** `feat: sideviewUI()/sideviewServer() module with sideviewProxy() verbs and read-back reactives`.

### Task 6: Example app, real-browser test, docs, check

**Files:**
- Create: `inst/examples/proxy/app.R`
- Modify: `tests/testthat/helper-browser.R` (`sv_start_app()` accepts an app file path), `tests/testthat/test-layout-browser.R`,
  `README.md`, `NEWS.md`, `_pkgdown.yml`, `CLAUDE.md` (architecture line for `R/module.R`; inputs `sideview_ready`,
  `sideview_snapshot`; messages `sideview_card_add`, `sideview_card_replace`, `sideview_card_remove`, `sideview_state_set`,
  `sideview_highlight`; the `ns` routing rule; the `codebook_saved` `csv` field), `MEMORY.md` (entry + replace the
  roadmap line 112 per spec section 3), committed `docs/` rebuild

**Interfaces:**
- Consumes: everything above. The example app: two canvases `"a"` and `"b"` on one `bslib::page_fillable` (or
  `fluidPage` when bslib is absent), synthetic `visits`/`labs`, action buttons `add`, `replace`, `remove`, `state`,
  `highlight` driving canvas `"a"` through `sideviewProxy("a")`, and `verbatimTextOutput("code")` showing `px$code()`.

- [ ] **Step 1: Write the failing browser tests** in `test-layout-browser.R` (real mouse via `b$Input$dispatchMouseEvent`):
  `module: two canvases start with their cards and no JS errors`;
  `module: replace keeps the card's position and splines stay on their ports` (connect `visits.id`↔`labs.id` by real
  clicks, click `replace`; card rect unchanged ±1px; every spline endpoint within 2px of its port centre);
  `module: replace that drops a column shows the disabled-step toast`;
  `module: canvases are independent` (connect in A; B has no connector; `F` with focus in A changes only A's transform) —
  Review Focus 1;
  `module: the page scrolls past the canvases` (`window.scrollY` grows after a wheel event outside them);
  `module: the code output parses` (read `#code` text, `parse(text = )` succeeds);
  `module: zero-row replace shows an empty card` (no JS errors, card shows 0 rows) — Review Focus 2.
- [ ] **Step 2: Run** `NOT_CRAN=true` + `devtools::test(filter='layout-browser')` — Expected: new tests FAIL (no app).
- [ ] **Step 3: Implement** the example app and helper change.
- [ ] **Step 4: Run** the browser file — Expected: PASS.
- [ ] **Step 5: Docs:** README section "In your own Shiny app" (the example's core 15 lines and the untrusted-`$code()`
  sentence from spec section 4); NEWS 0.4.0 bullet; `_pkgdown.yml` "Shiny module" group; CLAUDE.md and MEMORY.md as
  listed. Run `pkgdown::check_pkgdown()` (clean), `devtools::check()` (0 errors, 0 warnings; notes as before), rebuild
  the site per CLAUDE.md and drop `docs/CLAUDE.*` / `docs/MEMORY.*`.
- [ ] **Step 6: Commit** `feat(example): two-canvas proxy app; browser tests; docs`.

### Task 7: RStudio check (controller, with computer use)

- [ ] Run `shiny::runApp(system.file("examples/proxy", package = "sideview"))` from RStudio (after `devtools::load_all()`
  run `shiny::runApp("inst/examples/proxy")`) in the Viewer and in the external browser: every button, a spline, a
  replace that disables a step, the code output. Then a quick gadget pass (`sideview(visits, labs)`: connect, Done returns
  code). Record results in `MEMORY.md` and commit `docs(memory): RStudio check of the module`.
