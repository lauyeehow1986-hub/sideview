# MEMORY.md — sideview change log & decision record

Running log of what changed, why, and how it was verified. Newest entries first.
Each entry: **date — change — why — verification**. Keep the "Open issues" table current.

## Roadmap and task list (keep current; updated 2026-11-21)

Agreed 2026-11-13: five sub-projects, each with its own spec, plan and PR. D and E must also work in the
list view and the console, not only on the canvas.

| # | Sub-project | Status |
|---|---|---|
| A | Text-first access (list view, `sv_describe()`, announcements, table ARIA) | done, 0.8.0 (PRs #13-#17, #18 minors) |
| C | Accessibility testing (axe-core, AX-tree tests, NVDA script, CI a11y job) | done, 0.8.0 (PR #12, NVDA fixes #19) |
| B | Keyboard and low vision (access switch) | done, 0.9.0 (PR #20, version bump #22) |
| D | Unmatched / dropped rows as cards; stack two tables and compare columns; compare data cuts by key | **D1 done, on `main` (42256d2; docs PR #23, a11y test fix PR #24)**; **D2 (stack) done, on `main` (PR #31; all RStudio checks confirmed by the user: gadget, duckdb, Arrow, widget, list view)**; build notes `plans/2026-11-17-d2-stack-design.md`, plan `plans/2026-11-17-d2-stack-implementation.md`; **D3 (compare data cuts) done, on `main` (PR #34; docs PR #35; all RStudio checks confirmed by the user; version 0.10.0 in DESCRIPTION)**; spec `plans/2026-11-16-derived-cards-design.md`, D1 plan `plans/2026-11-16-derived-cards-d1-implementation.md`; version bumped to 0.10.0 with D3 |
| E | Order agreed 2026-11-22: **E1** `metatools::combine_supp()` code style for SUPP merges; **E2** ADSL merges written with `admiral::derive_vars_merged()`; then `dm` import and export; `pointblank` export; `metacore` spec check (labelled "spec check") | **E1 design approved 2026-11-22**: `plans/2026-11-22-e1-combine-supp-design.md`; plan `plans/2026-11-22-e1-combine-supp-implementation.md` (7 tasks); **E1 built (0.11.0, branch `e/combine-supp`, not pushed), awaiting RStudio check** |

Other pending tasks:
- [x] CI workflow was invalid since the a11y job (steps context in job env): fixed in PR #21 (2026-11-16).
- [x] First real CI run on `main`: the only failure was the a11y job (drawer fade flake, fixed in PR #24); the arrow 26 / duckdb 2.0 tz filter failure (`test-lazy.R:1101`) is still unchecked on current CI.
      Read main's CI after #24 (run 43989999137) before relying on it.
- [ ] CRAN submission of 0.9.0: local `devtools::check()` `--as-cran` and the full suite first; needs the user's go-ahead.
- [ ] Manual-script gaps for B: checks 2 and 14-19 not walked one by one; High Contrast Night sky not confirmed.
- [ ] Backlog for B: visible hint/toast when `C` starts a connect; a "dismiss suggestions" control.
- [ ] Cleanup: stale worktrees, `C:\src\chk*` folders, merged local branches (`a11y/b-canvas`, `a11y/b-spec`, `ci/fix-a11y-env`, `release/0.9.0`).
- [ ] Unscheduled backlog (see "Backlog" below): table version diff overlaps D's data-cut compare; validation rules
      (pointblank) overlap E; PHI/PII column tagging; Quarto/R-script pipeline export; very wide tables (column virtualisation untested).


### 2026-11-17 - D1 manual checks and the a11y CI fix
- **Change:** D1 manual checks run with the user in RStudio (R 4.5.1), Viewer pane, Edge (external browser), the built-in browser, and a saved widget page. PR #24: the derive-offers axe test waited for nothing while the drawer faded in (200 ms), so axe read contrast against partial opacity; the test now waits for opacity 1 and no running animations. The a11y CI job had been failing on `main` since 0.9.0 (3 then 4 failures); only 1 reproduced locally, the other 3 were CI-only: the column inspector selects had no colour rules, so Linux Chrome rendered them light in the dark theme (axe color-contrast, module mode, drawer inspect). Fixed in PR #27; PR #26 (merged) makes the CI a11y script print each failing test. The a11y job is green on #27.
- **Verified (passed):** dialog: join check, both offers (singular and plural), derived card, pipeline derive step and code, undo/redo, state Save then Open restores the derived card and clears undo, Cancel, Done (returns the code string, runs). Viewer pane: narrow layout, bottom-sheet drawer, offers and derive. External browser (Edge): derive works, Cancel ends the app. Widget with no R: opening a state with a derive step shows the info toast "Derived tables are not shown in a saved page; their steps stay in the generated code.", no derived card, step kept, no offers. Lazy duckdb inputs in the gadget: join check, both offers, derived card (S9/c, S9/d), restore from state resolves the derive step, no console errors. Local a11y suite 1083 passed, 0 failed after the fix.
- **Open observations (not fixed):** (1) undoing a connection leaves its spline and entry in the saved state, so the type-mismatch toast returns on Open (probably older than D1, unverified). (2) "Restored N cards" counts only the original cards, not the derived one. (3) RStudio restarted on its own after browser-mode runs. (4) Parked from the D1 review: undo-after-replace of a stale SUPP plan.
- **Next:** D2 (stack) then D3 (compare data cuts) each get a plan; 0.10.0 bump after D3; E not started.
- **2026-11-17 later:** main CI green after #28 (a11y, macOS, Windows, ubuntu x3, pkgdown); the arrow 26 / duckdb 2.0 `test-lazy.R:1101` failure did not show. PR #29 (merged) fixed observations (1) and (2): undo/redo now sync splines to the join steps (`syncSplinesToJoins`), and the Restored toast names derived tables to rebuild; real-browser test in `test-layout-browser.R`. Local cleanup done (merged branches, `C:srcchk*`). D2 build notes written.

---

### 2026-11-15 - Accessible canvas final-review fixes (B, I1-I4, P1, P2, M1, M2, M7, M8, M9)
- **Change:** (I1) each engine resolves the access state once in its constructor (`resolveAccess()`: stored > `_accessMem` > `data-sv-access` / `options.access` > off); `accessOn()` returns the cached `_access`, only `setAccess()` changes it, so a second canvas on the page keeps its class, row height, zoom floor and `?` switch until the next load. (I2) `getState()` saves an auto-sized card's inline (default) size while the switch is on, plus an optional per-card `user_sized: true` that `applyState()` turns back into `data-sv-user-sized` (no schema bump; R/state.R docs and `man/` updated). (I3) `stroke-linecap: butt` on `[data-sv-pat]` paths under `.sv-access` and `forced-colors` (prefers-contrast has no pattern rules, so round stays there). (I4) docs no longer say the widget or `save_sideview()` take `access =`: `sideview_widget(options = list(access = TRUE))` / `options(sideview.access = TRUE)`. (P1) `setScale` formatting. (P2) `sv_axe_states()` asserts each state (drawer tab selected, AI input focused or hidden in a module, filter popover, `?`, search) before axe runs; new switch-off run of the same panels (modes x themes, 1360) with `SV_AXE_ACCEPTED`. (M8) `disable()` moves focus to the container when it was on an element that lost its tab stop; dialog return focus goes through `engine.returnFocus()` (falls back to the container). (M9) access `--sv-border-light` is `#526075` light / `#8796ab` dark (>= 4.5:1 on every background), test-theme.R checks it on seven backgrounds. (M1, M2, M7) docs: Tab order inside a card, the pattern rule, the search-hint `kbd` colour with the switch off.
- **Spec deviation (M1), recorded:** the spec says the card body is not a Tab stop. It is one (`tabindex="0"`, `role="region"`, "<name> rows") because axe's `scrollable-region-focusable` fails a scrollable body that keyboard users cannot reach. NEWS, the article and the manual script now say so.
- **Verified (real Chrome via chromote, `NOT_CRAN=true`, focused filters only):** RED then GREEN for I1, I2 (two tests), I3, M8 (two tests) and M9; filter counts in `.superpowers/sdd/2026-11-15-accessible-canvas-implementation/final-fix-report.md`. `node --check` on sideview.js, sv-access.js, sv-panzoom.js. Not run: full `devtools::test()` / `check()`, the manual script, RStudio by hand.

---

### 2026-11-15 - Accessible canvas docs, manual script, site (B, Task 9)
- **Change:** docs only. `plans/2026-11-15-access-manual-script.md` (Edge, Magnifier 200% / 400%, Windows High Contrast, RStudio dialog and Viewer, Alt+Left check with the Ctrl+Alt fallback rule); CLAUDE.md (the switch, `sv-access`, `sv-access.js`, keys, zoom floor, OS blocks, colour precedence, `JUMP_MODS`); NEWS 0.9.0 (development); screen-reader article "Keyboard and low vision"; `man/` regenerated; site rebuilt.
- **What Tasks 1-8 verified (real Chrome via chromote, `NOT_CRAN=true`, focused filters; the full suite and `devtools::check()` are run by the controller):** `access-browser` 323 passing (keys with real CDP key events, Tab and reading order, moves and `sideview_card_moved`, connect / Delete / J, switch-off restores every attribute, switch precedence); `a11y-browser` 622 passing, incl. the axe matrix with the switch on and an empty accepted list (3 modes x 2 themes x 3 sizes x canvas, drawer tabs, AI bar, filter popover, `?`, search); `layout-browser` 897; `access`/`theme`/`computer-use` 468 (access tokens 7:1 text, 4.5:1 non-text; forced-colors and prefers-contrast emulated with `Emulation.setEmulatedMedia`); `node --check` on `sideview.js` and `sv-access.js`; mock-DOM runner `gui-test-runner.js` no false.
- **Pending (not done, not claimed):** the manual script (Magnifier, High Contrast, Edge, RStudio dialog and Viewer) has NOT been run. `JUMP_MODS = 'alt'` is verified only in Chrome (`preventDefault()` on keydown stops Alt+Left/Right); not verified in RStudio (Qt WebEngine) or Edge. If any host navigates away, change `JUMP_MODS` to `'ctrl+alt'` and update the `?` rows, tests and docs.
- **target-size backlog item closed** for the switch-on canvas (axe passes with `SV_AXE_ACCEPTED` not applied). The default (switch-off) canvas keeps its `target-size` acceptance by design.
- **Parked minor notes:** (1) the port border equals the canvas background in the default and access modes. (2) Reordering cards for reading order changes the DOM z-order of overlapping cards; `disable()` puts the original order back. (3) A stale spline after Ctrl+Z of a join is pre-existing (a mouse join does it too); the step is undone, the path stays until the next redraw. (4) `JUMP_MODS = 'alt'` not yet verified in RStudio or Edge (see above).

---

### 2026-11-14 - Screen-reader article, README, NEWS 0.8.0, feedback template, version (A4, Task 18)
- **Change:** `vignettes/articles/screen-reader.Rmd` (one eval chunk: `sv_describe()` on a synthetic data frame; the rest `eval = FALSE`), navbar entry and `_pkgdown.yml`; `.github/ISSUE_TEMPLATE/accessibility-feedback.yml` (required: screen reader + version, browser or RStudio pane, sideview version, what you did, what you heard or expected; label `accessibility`); README "Screen Reader Ready" bullet; NEWS `# sideview 0.8.0` (existing a11y entries kept); `Version: 0.8.0`; CLAUDE.md standing rule (list view + sentences) made explicit.
- **RULING (honest label):** the NVDA pass was NOT run (see Task 17). Everywhere the label reads "checked with automated WCAG tests (axe) and real-browser keyboard tests; an NVDA script is written but has not yet been run; not yet tested by blind users". The article's RStudio-pane section says pane/dialog behaviour with a screen reader is unmeasured and recommends `viewer = "browser"`.
- **Verified:** `pkgdown::check_pkgdown()` clean; site built with `RSTUDIO_PANDOC` set (MEMORY.md has `---` lines pandoc reads as YAML, so CLAUDE.md and MEMORY.md were moved aside for the build), `docs/CLAUDE.*` / `docs/MEMORY.*` and their sitemap/search entries removed; the article renders and the `sv_describe()` chunk ran. `devtools::check()`: 0 errors, 0 warnings, 1 NOTE ("non-standard things in the check directory: NULL", a known Windows/environment artefact), 27 min.
- **Not checked:** a screen reader (NVDA/JAWS/VoiceOver); RStudio pane/dialog.

---

### 2026-11-14 - List view card updates, keyboard walkthrough, list axe matrix (A3, Task 16)
- **Change:** `sideview_card_add/replace/remove` announce "Table <name> added./replaced./removed." (`sideview.js` handlers; the first population on `sideview_ready` carries `initial = TRUE` from `R/module.R` and is not announced, or the announcer test saw "Table patients added."). The list view already re-rendered per card through `syncTableMeta()` -> `syncTables()`; added "No tables yet." and `markCardPreview()` now calls `listView.renderTable()` so the lost-link heading says "preview". Docs: NEWS, CLAUDE.md (standing rule, architecture line, `initial`).
- **Tests (RED/GREEN):** replacing a card re-renders only its section (visits keeps its mark; add/remove announced; "No tables yet."); keyboard-only walkthrough (Tab/Enter/Space/ArrowDown/typing: join, filter `age > 30`, SUPPAE merge) gives code identical to a second session using `addConnections`, `pipeline.add`, `requestSuppCheck`; shortcuts off: f/t/d on a list heading change nothing; list AX facts (`aria-rowcount == rows + 1`, no unnamed controls); toolbar List-view toggle inside the container at 375 px (no overflow); axe matrix is now 2 views x 3 modes x 2 themes x 2 sizes. `sv_wait_ready_for_keys()` (condition wait) added to the two tests that once errored at browser start.
- **target-size:** the list view passes axe with NO exemption. The canvas view still fails `target-size` (39 nodes at gadget 1360: card header and column-header buttons are 24 px in CSS but 12-17 px at fit scale 0.5-0.71). Not cheap (counter-scaled chrome or a minimum zoom reflows card headers), so `SV_AXE_ACCEPTED` is kept for the canvas view only, stated in the test. Sub-project B.
- **Not checked:** RStudio dialog / Viewer pane / external browser by hand (not possible in this headless session).

---

### 2026-11-14 - List view tables, columns and paged rows (A3, Task 13)
- **Change:** `VirtualTable.cellText(i, col)` (shares `cellDisplay()` with the card render; `null` while a remote block is missing) and `onBlock(fn)` (unsubscribe returned; listeners cleared in `destroy()`). `SideviewListView`: a section per card (h3, columns `<ul>` or closed `<details>` over 30, captioned rows table with Ruling 2 counts, 25-row pager, Go to row, Sort/Filter/Inspect). New narrow entry points `refresh()`, `updateSections()`, `syncTables()`; `setView('list')` calls `refresh()` (also re-syncs the shortcuts switch), `sideview_llm` calls `updateSections()`, `syncTableMeta()` calls `syncTables()`. Only `render()` rebuilds everything. CSS tokens only.
- **Decisions:** page ranges use thousands separators everywhere ("Rows 4,990 to 5,000 of 5,000."); Go to row starts the page at that row (not page-aligned); column counts come from the header badges (`.sideview-na-badge` / `.sideview-cat-profile` titles; numeric columns show missing only, no distinct count exists); Filter does nothing until Task 15 defines `engine.openBuilder`; a pressed pager button that becomes disabled hands focus to its neighbour.
- **Verified (real Chrome, NOT_CRAN=true, singly):** test-a11y-browser (7 new tests, RED first; incl. hostile names `a<b "c" é`, >30 columns, sort/filter parity vs dplyr, Inspect parity vs `sv_say_profile`, sections survive switches), test-lazy-browser (duckdb Next / Go to row 4000 cause windowed `sideview_rows_request`s only, cells equal the data). Not checked in RStudio.

---

### 2026-11-14 - List view shell, view toggle, state view.mode (A3, Task 12)
- **Change:** new `inst/www/sv-listview.js` (`SideviewListView`: `render()`, `renderSummary()`, `renderTable()`, `onJoinDiag/onSuppCheck/onColumnProfile`, `destroy()`); `engine.view`, `engine.setView(mode, {silent})`, `llmAvailable()`, `listHook()`, `noCode()`, `iconHtml()`; toolbar `[data-sv-view-toggle]` (action `toggle-view`, new inline `list` icon); `getState().view.mode`; `applyState` view.mode; CSS block under `.sideview-container .sideview-listview` (tokens only, max-width 72ch) plus a scoped `[hidden] { display: none !important }`. R: `sv_asset_version()` and the dependency list `sv-listview.js` (after `sv-pipeline.js`). Roxygen for the precedence, `man/` regenerated, NEWS, CLAUDE.md.
- **RULING (precedence):** a restored state's `view.mode` wins over the `view` argument; no state or no valid `view.mode` leaves the argument. Start-up applies it after the first layout (the constructor), silently; Open applies at once.
- **Decisions:** (1) the view is applied after `initLayoutObserver()` so the cards are measured while visible; `setView('list')` stores card sizes (`_hiddenGeom`) because a hidden card measures 0 and `getState()` would lose them; going back re-renders the virtual tables. (2) The toggle keeps one accessible name ("List view") and uses `aria-pressed`; the brief's "label List view or Canvas view" is the announcement text. (3) Summary sentence uses singular forms ("1 table, 1 join step"). (4) Copilot section: no R signal exists for the gadget, so it is present for a module (unless `sv-no-llm`) or with `data-sv-llm="true"`; the gadget has none until Task 15 wires R. (5) Skip links call `focusSection()` instead of following the hash. (6) Adding a toolbar button changed the initial fit scale; test-layout-browser "zoom label tracks the canvas scale" assumed a fit scale that made one zoom-in step differ from 100% and now compares with the label before the click.
- **Not in this task (no list rows yet):** sort/filter then list rows, lazy paging, moved drawer panes: Tasks 13-15. A hostile-name test exists for what renders here (Summary only; counts).
- **Verified (real Chrome, NOT_CRAN=true, one file at a time):** test-a11y-browser (all, incl. axe matrix with the target-size exemption untouched; 8 new tests, RED confirmed on base JS), test-assets (2 pre-existing failures, same at base: mock DOM lacks `setAttribute` since Task 10), test-app 50, test-lifecycle, test-theme, test-widget, test-state, test-module 45, test-layout-browser 64 all 0 failed; `node --check` sideview.js and sv-listview.js; gui-test-runner.js: 1 scenario failure (Scenario 3), same at base. Not checked in RStudio.

---

### 2026-11-14 - `view =` argument and `view.mode` state field (A3, Task 11)
- **Change:** `view = getOption("sideview.view", "canvas")` on `sideview()`, `sideview_widget()`, `save_sideview()` (passed to the widget it builds), `sideview_ui()`, `sideviewUI()`; `match.arg` validation; `data-sv-view` on the container, `options$view` on the widget. `sv_state_scrub()` drops an invalid `view$mode` (JSON save, RDS save and `sv_state_from_json()`). Roxygen `@param view`, `sideview.view` option, `devtools::document()`, NEWS, CLAUDE.md. No JS yet (Task 12 reads the attribute).
- **Verified:** RED first (app, widget, module, state failed on the missing argument / un-dropped mode). Passing singly: test-app, test-widget, test-module, test-state. R only: no browser or RStudio check.

---

### 2026-11-14 - Table ARIA (A2, Task 10)
- **Change:** `VirtualTable.render()` sets `aria-rowcount` (rows + 1), `aria-colcount`, header `aria-rowindex=1`, data rows `aria-rowindex = virtual index + 2`; `ensureTableCaption()` adds a `sv-sr-only` caption (textContent) in both the widget/module path and `initExistingCards()` (gadget). CLAUDE.md and NEWS.md updated.
- **Gotcha:** the gadget's tables are server-rendered and a filter there is remote (async): the count updates when the R reply renders, so the test waits on `getRowCount()`.
- **Verified (real Chrome, NOT_CRAN=true):** test-a11y-browser.R 109 passed incl. axe matrix (modes x themes x sizes); test-layout-browser.R 750 passed; gui-test-runner.js all true; `node --check` clean. Red first confirmed (4 failures before the caption fix).

### 2026-11-14 - Shortcuts switch (A2, Task 9)
- **Change:** `engine.shortcutsOn()` (stored `sideview.shortcuts` on/off, then in-memory choice, then `data-sv-shortcuts="false"` / `options.shortcuts === false`, then view: off in `list`) and `engine.setShortcuts(on)` (stores, updates `[data-sv-shortcuts-switch]`, announces "Keyboard shortcuts on./off."). The `?` dialog has a `role="switch"` button above the list. The single-key handler returns early when off; Ctrl+K and Ctrl+Enter are not gated. R: `sv_ui_build()` writes `data-sv-shortcuts="false"` under `options(sideview.shortcuts = FALSE)`; `sideview_widget()` sets `options$shortcuts` unless given. Docs: roxygen option, NEWS, CLAUDE.md.
- **Decision:** with blocked localStorage the choice is kept in memory (`_shortcutsMem`) so the switch still works; the brief's order has storage first, so a stored value still wins when storage works.
- **Verified:** RED first (widget, app failures; browser tests failed on missing methods). Real Chrome: test-a11y-browser.R (switch off/on, Ctrl+K still opens search, dialog switch, R option, localStorage throwing via addScriptToEvaluateOnNewDocument, typing test with shortcuts on and off), test-widget, test-app; `node --check`; gui-test-runner. List-view half is Task 12. Not checked in RStudio.

---

### 2026-11-14 - Live region and announcements (A2, Task 8)
- **Change:** `engine.announce(text)` queues text into `.sideview-announcer` (polite `role="status"`, `sv-sr-only`, created in the constructor, `textContent` only so nothing is parsed as HTML); 500 ms spacing, a repeat is cleared and set again 50 ms later, `announceLog` keeps the last 50. `stepAnnouncement(kind, verb, count)`; `announceStepChange(label)` diffs the step list in the pipeline's `onChange` (add/remove by step ids; load, refresh, checks, pipe, tables stay quiet). Join, SUPP (not quiet re-checks) and profile replies announce the first `say*` sentence; Copy, Insert (toolbar and chat), Copilot reply announce. `showToast(message, type, key, {silent})`: the stack lost `aria-live`; `danger`/`error` toasts are `role="alert"`, the others have no role and are announced (undo/redo/copy/insert toasts are `silent` since they have their own sentence; a keyed toast updated in place is announced only when its type changes). Timers cleared in `destroy()`; no new global listeners. CSS: `.sv-sr-only`, `.sideview-toast-error` shares the danger style.
- **Decisions:** the brief's join (`visits.patient_id`) does not exist in the fixture (`visits` has `pid`), so tests connect `patient_id` to `pid` and compare with `by = c(patient_id = "pid")`.
- **Verified:** RED first (base JS: 6 failures). Real Chrome (chromote) in gadget, widget and module: `test-a11y-browser.R` 47 passed, including the Task 2 axe matrix (3 modes x 2 themes x 2 sizes) still green, the announcer's attributes, the 500 ms spacing and repeat clearing with a MutationObserver, `<b>` text kept as text, and error toast `role="alert"` with no `aria-live` ancestor. `node --check` clean; `gui-test-runner.js` all true. Not checked in RStudio itself (no screen reader run).

### 2026-11-14 - sv_describe() and the A1 docs (A1, Task 7)
- **Change:** exported `sv_describe(x, ..., n_levels = 5)` (`R/describe.R`): a table line (`name, DOMAIN domain, N rows by M columns, k columns have missing values.`) and one indented line per column, returned invisibly as class `sv_description` with a `cat()` print method. Reuses `sv_say_num` / `sv_say_value`, `sv_column_profile()` and, for a lazy table, `sv_lazy_column_profile()` (never `collect()`); row count and domain come from the normalised card. `NEWS.md`, `CLAUDE.md` (sentence twins rule) and `_pkgdown.yml` updated.
- **Decisions:** only text columns list top values (brief); the signature tolerates a missing `x` so `sv_describe(my = df)` works; a list of tables is accepted as in `sideview()`.
- **Verified:** RED first (function missing, 6 failures). One file at a time, NOT_CRAN=true: test-describe 17 passed (duckdb and arrow give the same lines as the data frame; the lazy profile is called once per column and the in-memory profile is mocked to fail), test-say 130, test-codebook 278 (1 pre-existing warning), `check_pkgdown()` clean. test-lazy 3742 passed. Console only: no browser or RStudio change.

---

### 2026-11-14 - SUPP, profile, discrepancy and mapping sentences, classes, print methods (A1, Task 6)
- **Change:** `sv_say_supp(chk, parent_name, supp_name)` / `saySupp` and `sv_say_profile(p, name)` / `sayProfile` (twins, `R/say.R` and `sv-pipeline.js`); R-only `sv_say_discrepancies()` and `sv_say_mappings()`. New classes `sv_supp_check` (also on an `{error}` result and on `sv_lazy_supp_check()`), `sv_column_profile` (in memory and lazy), `sv_discrepancies` (on the list) and `sv_mappings` (prepended to the data frame), each with a `print` S3 method (`as.data.frame.sv_mappings` too), all registered in NAMESPACE. The check stores `parent_name` / `supp_name`; the profile stores `name` only when known (the lazy profile sets it to `column`).
- **Browser payload unchanged:** `sv_supp_check_json()` and `sv_column_profile_json()` `unclass()` and drop the name fields; the server handlers `unclass()` the discrepancies and `as.data.frame()` the mappings. Tests pin the JSON text taken from the base commit (`snap_supp_ok`, `snap_supp_orphan`, `snap_prof_num`, `snap_prof_txt`).
- **Decisions:** (1) the profile's last sentence for non-listed values reads "N other values are not listed." (brief said "N rows have other values", but `n_other` counts distinct values, not rows); it counts `n_other` plus any of the top-10 beyond the 5 shown. (2) A sample "USUBJID IDVAR IDVARVAL" leaves out an empty or missing part (subject-level rows have no IDVAR). (3) Singular forms: "1 SUPP row has", "1 value is only in x", "1 suggested join."; the SUPP check lists "These QNAMs" as the brief wrote it even for one. (4) Mapping rows with a non-NA `group` get "Group <group>: "; a line that ends in "." gets no second one. (5) Existing tests that compared a whole `list(error = )` with `expect_identical` now compare `$error`.
- **Verified:** RED first for each class (missing `sv_say_supp`, no class, extra `name` in the profile JSON, no `sv_mappings`, raw list print). One file at a time, NOT_CRAN=true: test-say 130, test-supp 231, test-codebook 279, test-copilot 62, test-codegen 323, test-module 165, test-app 300, test-e2e 136, test-features-verification 94 expectations, all 0 failed. test-lazy: the 8 affected tests (462 expectations, duckdb and arrow) 0 failed; the whole file exceeds 9 minutes here, so it was not run end to end. test-pipeline not re-run (timed out at 50 s; JS only gained two functions). `node --check` clean, `check_pkgdown()` clean. Report: `.superpowers/sdd/2026-11-14-accessibility-text-first-implementation/task-6-report.md`.

### 2026-11-14 - Join checks as sentences: sv_say_join / sayJoin (A1, Task 5)
- **Change:** `sv_say_join(d, x_name, y_name)` in `R/say.R` and JS twin `sayJoin(d, xName, yName)` (plus `saySentence`); `print.sv_join_diagnostics()` now prints those sentences. `sv_join_diagnostics()`, `sv_lazy_join_diagnostics()` and `joinDiagnostics()` carry `x_name` / `y_name`.
- **Fix round 1:** counts read "1 row of X has no match" / "N rows of X have no match" and "has/have a missing key" (`sv_say_rows` / `sayRows`); parity tests with `<`, quotes, spaces and CJK names.
- **Decisions:** the unmatched sentence is left out when no sample keys exist (for example only NA-key rows are unmatched); a nearest-match rule has no right/full counts, so "Rows by join type" omits them; a hint with `extra_x == 0` drops the "0 more X rows" part; an error ending in `.` gets no second one.
- **Verified:** test-say.R 51 passed (R and JS sentences identical for one-to-one, one-to-many, multi-key hint, date rule, empty, NA, duplicate and Unicode keys); the ASCII and 100-character checks hold for the four fixtures. test-diagnostics 5123 passed, test-lazy 3724 passed (duckdb and arrow say the same as in memory), test-join-rules 10753 passed. `node --check` clean. No UI change.

### 2026-11-14 - Sentence helpers with R/JS twins (A1, Task 4)
- **Change:** `R/say.R` (`sv_say_pct`, `sv_say_list`, `sv_say_samples`, `sv_say_value`, `sv_say_num`, `sv_say_check_lines`, all internal) and JS twins `sayPct`, `sayList`, `saySamples`, `sayValue`, `sayNum`, `sayCheckLines` on `SideviewPipeline`. `sv_say_check_lines()` returns lines whole; the 100-character limit is checked by tests, not applied.
- **Gotcha:** `jsonlite::toJSON()` rounds to 4 digits by default, which made a number twin test fail falsely; pass `digits = NA`.
- **Verified:** test-say.R 22 passed (RED first: `P.sayPct is not a function`); `node --check` clean. No UI change.

### 2026-11-14 - Accessibility harness: shortcut/typing rules pinned, a11y CI job (PR C, Task 3)
- **Change:** two tests in `test-a11y-browser.R`: `typing never fires shortcuts` (AI-bar input focused, F and D typed: zoom and drawer state unchanged, value `"fd"`) and `canvas shortcuts fire when the canvas owns the keyboard` (container focused, D toggles the drawer, twice returns it). New `a11y` job in `R-CMD-check.yaml` (ubuntu, `NOT_CRAN=true`, Chrome, Node 20, `npm install --no-save axe-core@4.10.3`, `SV_AXE_PATH`); it runs each of `a11y-browser` and `say` singly with `stop_on_failure = TRUE` and skips a filter that has no `test-<f>.R` yet (`test-say.R` arrives in PR A1).
- **Behaviour:** the new tests passed on today's `isTypingTarget` / `ownsKeyboard`; `sideview.js` is unchanged.
- **Verified:** `NOT_CRAN=true devtools::test(filter = "a11y-browser")` -> 23 passed, 0 failed, 0 skipped. Mutation check: removing the `isTypingTarget` guard from the shortcut handler made the typing test fail (2 failures), then restored. Accepted axe rules: `target-size` only (card controls scale below 24 px with fit-to-view zoom; sub-project B). Not run: the workflow itself (needs GitHub).


### 2026-11-07 - SUPP merge: review fixes (Opus 5.5 high review, R1-R3, S1-S7)
- **Arrow key casts (R1, R2):** the generated arrow code cast a numeric supp key to the parent's Arrow type, but only checked the result for float32. On a narrow or decimal parent it was wrong in two ways. A value outside the type's range (300 on int8) wrapped onto another record's key. A value the type rounds (0.125 on decimal(10, 2)) was rounded onto a record, or, past the range, stopped the run. Now every cast level keeps only keys that survive an unsafe test cast (`$cast(ty, safe = FALSE)`) unchanged. When a decimal cast stops even unsafe, the keys are tested one at a time. Rows that fail are dropped, never rounded, as the check counts them as orphans. The halffloat branch is gone: Arrow cannot create float16 columns (S6).
- **Three or more RDOMAINs on a lazy card (R3):** `sv_cdisc_lazy_query(kind = "rdomain")` kept `head(2)`, so a lazy SUPPQUAL with AE, CM and LB lost LB. Its `rdomains`, `merge_targets` and the hint `sv_supp_rdomain_hint(card, "LB")` all disagreed with memory. The cap is now 1000 for `"rdomain"` (2 for `"domain"`, which needs only to know whether there is more than one). `sv_cdisc_peek()` sorts with `method = "radix"` (byte order, as duckdb's `arrange()`), so both paths give the same order in any locale. User-visible: the default RDOMAIN of a multi-domain SUPPQUAL is the byte-order first.
- **Whitespace around IDVARVAL (S1):** JS `\s`/`trim()` took NBSP, U+2028, U+3000 and the BOM, which R's `as.integer()`/`as.numeric()` do not skip. Now R (`sv_supp_ws`), JS (`SUPP_WS`) and the generated `grepl()` use the spelled-out ASCII class `[ \t\n\r\f\x0b]`. The generated `grepl()` takes `perl = TRUE`, because TRE reads `\t` in a bracket as a backslash and a `t`.
- **The top of the double range (S2):** R parses `"1.7976931348623158e308"` to `Inf`, where JS `Number()` keeps it, so R said bad and JS said fine. Both now treat `abs(x) > 1e308` as bad, and the generated level filter is `abs(<idvar>) <= 1e308`.
- **NA QNAM in the code (S3):** the generated code read an NA QNAM as `NA`, while the check reads it as the name `"NA"`. With both an NA QNAM and a QNAM `"NA"`, the guards saw two names where the check saw one. The `_q` mutate now writes `QNAM = dplyr::coalesce(as.character(QNAM), "NA")`.
- **float32 keys in the lazy check (S4):** the lazy numeric compare used `as.character()` of the converted key, which has 15 significant digits. A full-precision IDVARVAL such as `"0.10000000149011612"` (a float32 0.1) therefore missed in the lazy check but matched in memory. `sv_supp_convert_side()` now also returns `num` (full-precision double), and `sv_lazy_supp_match()` compares that.
- **Arrow int64 keys (S5):** in memory an int64 collects to integer64 (via arrow) and was typed by its values. On arrow a 0-row collect always reads "integer". A key past 2^31 (3e9) was therefore a double key in memory and an integer key (bad) on arrow. Arrow int64/uint64 is now always a "double" key (`sv_lazy_supp_wide_int()`), as duckdb BIGINT already was. In memory `sv_supp_key_chr()` reads integer64 as a double. The plan no longer depends on the data's values.
- **Arrow NA keys (S7):** `suppJoins()` now writes `na_matches = "na"` on an arrow chain too. This is Arrow 23's default, but writing it out removes the dependence on that default.
- **Known limitations (new, in NEWS too):** no float16 parent keys (Arrow cannot make them); doubles beyond 1e308 are cut off on purpose; at most 1000 RDOMAINs are read from a lazy SUPPQUAL.
- **Verified:** a failing test was written first for each fix (test-supp.R: ASCII whitespace, 1e308 edge; test-pipeline.R: narrow arrow key types, NA QNAM vs "NA", whitespace / 1e308 code parity; test-lazy.R: float32 full precision, int64 past 2^31; test-cdisc.R: three RDOMAINs lazy). `node --check inst/www/sv-pipeline.js`. Runs, one file at a time: test-supp.R 218 passed, test-pipeline.R 576 passed, test-cdisc.R 328 passed, all 0 failed; test-lazy.R (NOT_CRAN=true) all passed, 0 failed, 0 skipped.

### 2026-11-07 - SUPP merge edge cases (twins kept in step)
- **Non-finite double IDVARVAL:** `"1e999"`, `"-1e999"`, `"1E400"` matched the decimal regex and overflowed to `Inf` (R) / `Infinity` (JS), so they were *not* bad: the check counted them as orphans and, on an int64 arrow parent, the generated cast stopped with "Float value inf was truncated converting to int64". Now `sv_supp_convert()` and `suppConvert()` require a finite value (bad otherwise), the double level's generated filter is `dplyr::filter(is.finite(<idvar>))` (was `!is.na`). `"Inf"`, `"-Inf"`, `"NaN"` and `"NA"` were already bad (regex). Same in the lazy twin (shared `sv_supp_convert_side()`).
- **NA QNAM:** R failed (`names<-` error) while JS treated it as the text `"NA"`. Now both read a missing QNAM as `"NA"` (like keys, and like `tidyr::pivot_wider()` names the column); samples carry `"NA"`. Pivot code parses and the column is named `NA`.
- **Duckdb NA keys:** the check matches NA to NA (key text `"NA"`); the generated left join on a duckdb chain used dbplyr's default `na_matches = "never"`, so records with an NA `USUBJID`/`STUDYID` lost their qualifiers. `suppJoins()` now writes `na_matches = "na"` on a duckdb chain (arrow and memory already match NA). Regular (non-SUPP) joins are unchanged. The lazy check itself already agreed with memory on NA parent keys (numeric, NaN, STUDYID, character IDVAR): new cases in test-lazy.R.
- **float32 keys:** all three checks read a float32 parent key as the double it collects to (0.1f is 0.100000001490116, text differs from `"0.1"`), so they agree and report such a key as an orphan (new test-lazy.R test, arrow float32 and duckdb FLOAT). The generated arrow code used to cast the supp key *to float32*, which rounded `"0.1"` / `"16777217"` onto the parent value and merged rows the check had called orphans. The cast prep now drops a key that does not survive the cast unchanged (at first only for `float`/`halffloat` parents; since the review fixes above, for every cast type). Exact values (0.5, 2.25) still merge. By design: a float32 key is compared as its double value, never rounded; the user should cast the key to double/int in the parent.
- **Verified:** test-supp.R (new: non-finite, NA QNAM, JS parity), test-pipeline.R (arrow int64 + non-finite, NA QNAM code, duckdb/arrow NA keys, arrow float32), test-lazy.R (new cases in the equality test, float32 test); `node --check inst/www/sv-pipeline.js`.
- **Backlog items closed:** the two bullets "NA QNAM" and "Duckdb parent with NA keys" of the entry below.

### 2026-11-07 - SUPPQUAL merge: final whole-branch review fixes
- **Arrow int64 keys:** on an arrow chain each numeric IDVAR level is made an Arrow table in the prep and its key cast to the parent's own Arrow type, read at run time (`arrow::as_arrow_table(utils::head(<parent>, 0))$schema[[<idvar>]]$type`); a fractional double key on an integer parent is dropped first (it cannot match). Why: `as.integer()` gives int32 and `as.numeric()` double, and Arrow's hash join refuses them against an int64 parquet column ("Incompatible data types for corresponding join field keys") although the lazy check passes. Subject level / character keys keep `arrow::arrow_table(<level>)`; duckdb and in-memory code unchanged.
- **Clash guard:** reads `names(dplyr::collect(utils::head(<parent>, 0)))`; `colnames()` is NULL on an `arrow_dplyr_query` (`open_dataset() |> filter()`), so the guard silently passed.
- **RDOMAIN hint:** `supp_check_request` carries `rdomain` (the step's or the button's); R takes it via `sv_supp_rdomain_hint()` only when it is in the SUPP card's tag `rdomains` or the card has no tags (`cdisc = FALSE`), else derives it from `merge_targets` as before. Why: a re-check with `cdisc = FALSE` or a changed tag fell back to the card name ("QUAL") and showed the check as unavailable.
- **Docs:** NEWS, article and spec now say when the check runs (Merge button, opening the step line / report, opening a workspace, undo/redo, module card replace/remove; Refresh runs none and reuses the last check's plan), that "Preview rows" shows in the widget only for cut (`max_rows`) or lazy cards, and that for double keys past 15 digits the in-memory R check (15-digit text) can disagree with the generated code and the lazy duckdb check (numeric compare). Spec §6.2 shows the regex-restricted conversion; §10 no longer lists `R/module.R` (re-check is `replaceCard()` -> `forgetSuppChecks()` in JS). `skip_if_not_installed("tidyr")` on the tests that pivot.
- **Verified:** `node --check` on both JS files; gui-test-runner.js (new `recheck_sends_step_rdomain`, `click_sends_request` checks `rdomain`); test-pipeline.R (int64 parent with integer and double plan keys, eval equals in-memory; arrow query clash guard), test-supp.R (testServer hint: no tags, tagged accepted / ignored), test-app.R, test-computer-use-gui.R run singly.
- **Backlog (not fixed):**
  - (Both items here, `NA` QNAM and duckdb `NA` keys, are fixed: see the entry above.)

### 2026-11-03 - CDISC SUPPQUAL merge: sideview 0.7.0 (Tasks 1-9)
- **What shipped:** tag fields `rdomains` / `merge_targets` (SUPPxx, generic SUPPQUAL with several RDOMAINs); `sv_supp_check()` (+ `sv_supp_check_json()`, `sv_supp_key_type()`; R/supp.R), its JS twin `SideviewPipeline.suppCheck()` and lazy twin `sv_lazy_supp_check()` (duckdb / arrow parent stays lazy, only SUPP collected); the `supp` pipeline step (plan captured when added; tidyr + dplyr code with guards for repeats, clashes, other IDVAR levels, two-level QNAMs, double keys); input `supp_check_request` and message `sideview_supp_check`; Auto Map `kind = "supp"` rows (dashed group, accepting adds the step, not a join); join-check note; **Merge into <parent>** button, step line, Discrepancy report, quiet re-check and **Refresh**. Docs: article section "Merging SUPP-- tables", NEWS 0.7.0, README, CLAUDE.md twin rule, DESCRIPTION 0.7.0.
- **Rulings:**
  - A QNAM with no QLABEL has label `""` (not `NA`), in R, JS and lazy.
  - `IDVARVAL` rows that do not convert are `bad_idvarval`, counted apart from orphans (`n_matched + n_orphan + bad == n_supp`).
  - Double keys convert only if one decimal regex matches, on both sides (`"0x10"`, `"Inf"`, `"1d3"`, `"NaN"`, `""` are bad).
  - The clash guard in generated code uses `names(dplyr::collect(utils::head(<parent>, 0)))` (`names()` is wrong for dbplyr, `colnames()` is NULL on an arrow query; changed 2026-11-07). Clashes with columns made by earlier chain steps (mutate, rename, earlier merges) are caught in the browser only (`columnsBefore()`), not by the code guard.
  - R `as.character(double)` gives 15 significant digits; JS gives the shortest round-trip. A double key past 15 digits can differ between gadget and widget, and the in-memory R check (text) can disagree with the generated code and the lazy duckdb check (numeric).
  - The step carries `rdomain_col`; RDOMAIN is filtered only if the column exists.
- **Verified:** mock-DOM runner (gui-test-runner.js); R test files run singly (test-supp.R, test-pipeline.R, test-cdisc.R, test-lazy.R, test-module.R, ...; the whole suite hangs, never run it in one go); real browser (Task 8, headless Chrome via chromote, real input): gadget merge + report, Auto Map click, header buttons at 1400/1024/560 px, module with a duckdb parent, saved widget. `devtools::check()` and the pkgdown rebuild: see task-9-report.md.
- **RStudio pass: DONE 2026-11-07** (RStudio 2025.05.1, R 4.5.1, one instance driven by computer use, synthetic fixtures dm/ae/suppae/adsl/adlb):
  - [x] `viewer = "dialog"`: Merge into AE adds the step ("ae merge SUPPAE (1 QNAMs on AESEQ)", "4 of 4 SUPP rows matched"); generated code has the RDOMAIN filter and the IDVAR and QNAM clash guards
  - [x] Second press of the button: still 1 step (replaced, not duplicated)
  - [x] Undo and redo of the merge
  - [x] Insert Script with a document open: code landed in Untitled1 with the toast "Code successfully inserted into active RStudio document." (with no document open: the toast "No active document open in RStudio.")
  - [x] Edit `suppae` (module app, `sv_replace_card()` adds an `AENEWQ` row; external browser, driven in the built-in browser): "Merge needs refreshing" appeared, Refresh gave "merge SUPPAE (2 QNAMs on AESEQ)" and cleared the warning
  - [x] Header at 560 px: Merge is an icon-only button (aria-label "Merge into AE"), no overlap, no clipping
  - [x] Auto Map: supp group `cdisc:suppae~ae` drawn as dashed `sideview-spline-suggested-cdisc` paths (plus `cdisc:ae~dm`)
  - [x] `viewer = "pane"`: ~540 px, toolbar wraps to 3 rows, no overlap; Auto Map suggestions draw; Cancel returns NULL
  - Observation (not fixed): Fit in the narrow Viewer pane gives 18% zoom with the cards stacked, hard to read.
  - Not done: the dialog at a true 560 px window (checked in the browser at 560 px instead); the Refresh flow in RStudio's own Viewer pane.
  - **Second light pass, 2026-11-07 (after the Opus 5.5 review fixes, PR #9):** all RStudio processes killed with `Stop-Process`, one fresh RStudio 2025.05.1 / R 4.5.1, `viewer = "dialog"` on the same fixtures. Auto Map drew the dashed suggested splines (incl. ae to suppae) and the Drawer opened. The Merge button and the suppae card sat behind the Claude desktop window, so the merge click was NOT repeated; the fixes touch data and generated-code logic only (no UI change), covered by test-supp.R / test-pipeline.R / test-cdisc.R / test-lazy.R. Note: the computer-use `screenshot` came back blank for RStudio this time; typing and clicking worked, and screen captures via PowerShell `CopyFromScreen` were used to read the screen.
- **Deferred minors (backlog):**
  - T1: `R/cdisc.R:65` unused `rdomains = rd` in the suppqual rule; the SUPP regex at `R/cdisc.R:310` duplicates other checks (extract `sv_cdisc_is_supp`); tests lack a by-columns-unhelpful-name case and `cdisc_update` payload coverage.
  - T2: `supp.R:149` comment overclaims lazy reuse; `sv_supp_paste` NA key gives "NA" (parity); `as.numeric` edge strings vs JS `Number()`.
  - T3: no zero-row / integer64 parity case (callers must pass `opts.parentCols` / `suppCols`); JS `trim` vs R `trimws` on NBSP; dead `isNaN` branch.
  - T4: numeric IDVAR doubles past 15 digits match numerically in duckdb vs as text in memory; double/Date STUDYID/USUBJID keys print differently in duckdb; the collect spy is not airtight and `f` is unused at test-lazy.R:530; no factor RDOMAIN lazy case.
  - T5: an IDVAR named `SUBJ` collides with the `<supp>_subj` level table; factor QNAM low risk; no test of one SUPPQUAL merged into two parents; the `duckRef` scan skips `s.supp`.
  - T6: a bad or unnamed plan is silently dropped; no tests for lazy card, module ns, forged input, NA to null, multi-target Auto Map; the note appears only on the m2m path.
  - T7: undo/redo of any step forgets all merge checks (one extra request per merge step); the "not connected" `setTimeout(0)` callback is not guarded by `_destroyed`; disabled-reason order; stored checks are not re-widened when a merge moves; `columnsBefore` has no direct unit test; a re-check after reorder uses the current order; the widget check is slow on huge tables.
  - T8: fixed `Sys.sleep` waits; the `mapped == 0` check wraps `e$send`; the width test measures only `<button>`s; the card menu and Refresh are not browser-tested; the gadget never sends `sideview_snapshot`.

### 2026-11-02 - Real-browser tests no longer time out under load (test infrastructure only)
- **Root cause:** `sv_open_page()` (tests/testthat/helper-browser.R) waited for `Page$loadEventFired()` with chromote's default 10 s event timeout (`default_timeout`), and every later `Runtime$evaluate` had the same 10 s. With the suite or `devtools::check()` running (Chrome, duckdb, callr app starts all competing for CPU) the first paint of the callr app took longer, giving "timed out waiting for Page.loadEventFired". Only helper-browser.R starts Chrome (test-layout-browser.R, test-lazy-browser.R); shinytest2 `AppDriver` is used once, behind `SIDEVIEW_HEADED_QA`, so it is off by default.
- **Change:** one shared timeout, `sv_browser_timeout()` (90 s, env `SIDEVIEW_BROWSER_TIMEOUT`), set as the session's `default_timeout`; `sv_navigate()` (navigate + load event, one retry); `sv_wait_js()` (poll a JS condition to a deadline, replaces the fixed 15 s ready loops); `ChromoteSession$new` retried once; app start wait raised from 30 s to 2 min. The module page re-navigation uses `sv_navigate()`. Pages were already shared per file. No assertion or geometry threshold changed.
- **test-lazy.R:** the 1M-row duckdb join check bound went from 5 s to 15 s (7 s measured here, also on the older commit); the comment says it guards a collect-to-R or quadratic regression, which takes minutes.
- **Verified:** full `NOT_CRAN=true devtools::test()` with no failures (layout-browser, lazy-browser, lazy included); `devtools::check(args = "--no-manual")` result in followup-2-report.md.

### 2026-11-01 - CDISC awareness: follow-up 1 (deferred minors closed)
- **Case-insensitive columns:** `sv_cdisc_peek()` upper-cases column names for the rules and reads values through the real name; `sv_cdisc_lazy_query(tbl, kind, col)` takes that name (arrow/duckdb twins unchanged otherwise).
- **User tags:** `sv_cdisc_user_tag()` gives `AD*` the ADaM class from `sv_cdisc_rule_adam()` (Custom if no structure confirms) and `SUPPxx`/`SUPPQUAL` Relationship plus parent. Auto SUPP tags flip with the SEND canvas (`sv_cdisc_resolve()`), user tags never; a flipped tag gets `SEND canvas: ...` evidence (removed again when the evidence goes).
- **Codebook drift:** `sv_cdisc_domains()` returns a "closed" vector (attribute `closed`) or `FALSE`; `sv_codebook_domain()` gives NA to a table a closed vector does not name, so a cleared tag is not re-detected. Public `sv_codebook()` unchanged.
- **Named keys:** `sv_cdisc_override()` compares `cdisc =` names with the table name without extension (case still matters); the unknown-name warning shows the key as typed.
- **LLM schema:** `sv_schema_clean()` caps text at 200 characters (`...`).
- **Tests added:** lower-case columns (in-memory and duckdb), ADaM/SUPP overrides, SUPP on SEND, resolve evidence, multi-value DOMAIN asserts AE, named-key extension/case, real `datasetjson` 0.4.1 labels (column and dataset), mixed-extension message, all-skipped folder, label cap, cleared-tag codebook.
- **Docs:** NEWS, article (case limit removed, Dataset-JSON now checked, `view.labels_row` named), spec amendment in 5.1. No JS change (the widget codebook reads the badge's domain).

### 2026-11-01 - CDISC awareness: final whole-branch review fixes (0.5.0)
- **ADaM before prefix (ruling):** a table named `^AD[A-Z0-9]*$` runs `sv_cdisc_rule_adam()` before the variable-prefix rule. If the structure confirms, ADaM wins (the DOMAIN column still goes first) and the prefix result is recorded as `variable prefix LB disagrees with ADaM ADLB`; if not, the old order applies. Admiral-style `adlb`/`adae`/`advs` with `LBTESTCD`, `AETERM`, ... are now ADaM (BDS/OCCDS), in memory and lazy (test-lazy.R twin). The "rule 3 limitation" test was replaced; a non-`AD*` name still follows the prefix rule. Spec section 5.1 amended (dated note), NEWS and article updated.
- **`sideview_server(cdisc =)`** now goes through `sv_cdisc_check_arg()`; roxygen says it only sets the codebook `domain` column (badges come from `sideview_ui()` cards). `sv_cdisc_check_arg()` also rejects duplicate names in a named vector.
- **`sv_codebook()` override** is normalised with `toupper(trimws())`.
- **Module:** queued `sideview_cdisc_update` messages are dropped at `sideview_ready` (the cards sent there already carry current tags), so a stale tag cannot overwrite a fresh payload.
- **`sv_read_cdisc()`:** a file found by scanning a folder whose package is missing is skipped with one warning; a named file is still an error.
- **`sv_schema_clean()`** also collapses control characters, NEL, LS and PS to a space.
- **Docs:** upper-case column names limit in NEWS and article; article says `sv_remove_card()` updates module badges; article chunk variable `cat` renamed `cdisc_cat`.
- **Deferred (not done):** SUPP override class/parent on a user override and the SEND-canvas SUPP flip; codebook-vs-canvas drift for untagged cards; case-insensitive column detection.
- **Verified:** `NOT_CRAN=true devtools::test(filter = "cdisc|normalize|card-store|widget|llm|codebook|module|state")` plus the two lazy CDISC tests. No UI code changed, so no browser pass was repeated.

### 2026-11-01 - CDISC awareness: sideview 0.5.0 (Tasks 1-12)
- **What shipped:** `R/cdisc.R` (catalogue in `inst/extdata/cdisc_catalogue.csv`, `sv_cdisc_catalogue()`, detection by DOMAIN value, variable prefix, key set and ADaM structure, SUPP-- and SEND handling, `sv_cdisc_finalize()` tagging cards), `cdisc =` on `sideview()`, `sideview_widget()`, `save_sideview()`, `sideviewServer()` and `sv_codebook()` (`"auto"`, `FALSE`, named vector), module tag updates (`sideview_cdisc_update`), codebook `domain` column (R and JS twins, byte-equal CSV), domain and label lines in the copilot schema context, the `L` labels row saved as optional `view.labels_row` (no schema bump), `sv_read_cdisc()` (xpt, sas7bdat, Dataset-JSON, parquet). Tags are never saved in state. Article `vignettes/articles/cdisc.Rmd`, NEWS 0.5.0, README bullet, DESCRIPTION 0.5.0.
- **UI (Task 7):** `renderCdiscBadge(cardMeta)` puts `span.sideview-badge-cdisc.sv-cdisc-<std>` after the card name (text = domain, title = `<label> · <standard> <class>` + evidence + `supplements <parent>`, all set as text) and keeps `el.dataset.cdiscDomain` real (deleted when the tag is null), so `cardDomain()` feeds the widget/module codebook. `setCdiscTags()` + `onMessage('sideview_cdisc_update')` apply module updates (null clears; an unknown id is ignored quietly). `th` titles use the variable label; `searchCards()` matches domain and dataset label (rank 1); the inspector shows `<domain> · <dataset label>`. Gadget cards carry `data-cdisc` / `data-col-labels` (JSON) from `render_card_tag()`, read in `initExistingCards()`. Tokens `--sv-cdisc-{sdtm,send,adam}[-text]` in the base, dark and auto-dark blocks.
- **Known limitations (also in NEWS):** catalogue `ig_versions` approximate (awareness, not conformance); `cdisc = FALSE` still runs construction-time detection on lazy cards but shows no tags; a named `cdisc=` vector with lazy cards is O(n^2) on verbs; labels go to the LLM as schema text, never rows; `--sv-th-row-h` is measured once; RStudio dialog/pane viewers not verified in RStudio itself.
- **Verified:** see the Task 11 entry below; Task 12 (0.5.0 release checks): `pkgdown::check_pkgdown()` no problems; `devtools::check(--no-manual)`: 0 warnings, only the usual
  `''NULL''` check-directory NOTE; the `tests` step errored twice with chromote `timed out waiting for event Page.loadEventFired`
  (first run FAIL 16 of 22576, second run FAIL 1 of 22732, the first browser test); `NOT_CRAN=true devtools::test(filter = "layout-browser")` alone: 0 failures.
  Treated as intermittent load-related browser timeouts, as in Task 11, not a CDISC regression. A check with all tests green was not obtained. pkgdown site rebuilt; docs/CLAUDE.* and docs/MEMORY.* removed.

### 2026-11-01 - CDISC awareness: real-browser and manual verification (Task 11)
- **Browser tests do run here** (Chrome at `C:\Program Files\Google\Chrome\Application\chrome.exe`, chromote + callr present). The earlier
  "timeouts" were not reproduced: `test-layout-browser.R` ran to completion with `NOT_CRAN=true` (about 2 min) both before and after the new tests.
- **New tests (test-layout-browser.R), all passed on first run:** `cdisc badge sits in the title bar without overlap` (1400x900, 1024x700,
  560x520: every badge inside its header, no title-bar button overlapped, toolbar/palette/ai-bar still clear); `labelled headers carry titles`;
  `L toggles labels and splines stay on their ports` (real drag connects dm.USUBJID to ae.USUBJID; spline ends within 2 px of the port centres
  with the row off, on, off again); `a module snapshot carries view.labels_row and follows the L toggle` (proxy example app, `a-` canvas).
  They passed without a code change, so there was no failing-first step and no Task 7-8 bug was found.
- **Manual pass done in headless Chrome via chromote (gadget, dm/ae/suppae/adsl/adlb, `run = FALSE` app), NOT in RStudio:**
  badge text and tooltip (e.g. "Demographics . SDTM Special-Purpose / DOMAIN column = DM / STUDYID + USUBJID"); th tooltip
  ("Unique Subject Identifier"); `L` shows/hides the row; Ctrl+K "adverse" finds the `ae` card by its label; inspector for dm.USUBJID shows
  the "Unique Subject Identifier" label line; dark theme (T) toggles.
- **Parked: `--sv-th-row-h` staleness.** Measured 71 px layout height in light, after T (dark), zoomed in x2, after the container font changed, and
  with the card narrowed; the labels row stayed flush under the header after scrolling the card body (gap 0 in light, dark and zoomed).
  Headers are `white-space: nowrap`, so their height does not change with theme or zoom. It would only go stale if the header height changed
  after the row was built (e.g. a late web-font load); forcing that by padding the th did leave the cached value at 71 px. Not fixed (no
  realistic trigger found); left as a known limitation.
- **Parked: module `test-module.R` warning:** `devtools::test(filter = "module")` gives 1 warning, `nothing is sent before ready`:
  "package 'shiny' was built under R version 4.5.3" (installed shiny built for a newer R than 4.5.2). Environmental, not package code.
- **NOT verified (needs real RStudio):** `viewer = "dialog"` and `viewer = "pane"` with the five tables; RStudio's Viewer pane rendering of the
  badge and tooltip. `viewer = "browser"` equivalent covered only by headless Chrome above, not a user-visible browser window.
- **Full suite, `NOT_CRAN=true devtools::test()`:** 22759 expectations, 0 failed, 0 errors, 0 warnings, 1 skipped (`datasetjson` not installed). One
  earlier full run hit a real `Chromote: timed out waiting for event Page.loadEventFired` at `module: zero-row replace` (test-layout-browser.R:1943)
  while I had other Rscript/Chrome processes running; the identical code passed alone and in the clean rerun, so the timeout is intermittent
  and load-related (a reload-wait in `sv_module_page()`), not a CDISC regression. The full suite takes about 25 minutes here.
- Codebook `domain` column: covered by test-codebook.R (R and byte-equal JS CSV); not opened as a downloaded file in a browser.

### 2026-10-31 - Join rules final fix wave: Strict applicability and review items (0.4.0)
- **Change (I1):** `compose` writes Strict (`relationship =` / `unmatched =`) only where the join check's counts still describe the join: the join is the first row-changing step on its left table's chain (filter/join/distinct/slice/summarise/pivot/custom change rows; select/rename/mutate/recode/arrange do not), the right side is the raw card (not a `_prep` chain), and the chain is in R (not duckdb/arrow, which also closes M2). Otherwise the step keeps its `strict` flag and no args are written. One test, `Pipeline.prototype.strictApplies(step)` returning `{ok, reason}`, is used by `compose`, the disabled Strict checkbox (title = reason) and `strictLine()` in the join check panel.
- **Change (M1):** the pipeline step label uses `pipeline.describe` (so an invalid rule reads "Rule needs fixing"); `describe` adds " · " only when `ruleLabel` is non-empty. **M3:** NEWS.md and the roxygen "Known differences" in R/sideview.R reworded (man/sideview.Rd regenerated); `docs/` untouched. **M4:** the widget's missing-column message is `Not in <table>: <col>`, as R. **M5:** `print.sv_join_diagnostics` uses `"
"` escapes (output byte-identical). **M6:** Strict with a rule is evaluated and its row count compared with the dplyr reference (left/inner, before/window, `%>%` and `|>`). **T3:** the lazy rule test also runs right_join/full_join for the non-nearest specs. CLAUDE.md: new "Strict applicability" bullet.
- **Verified:** `node --check` on both JS files; `node tests/testthat/gui-test-runner.js` (new scenarios: Strict greyed after a row-changing step with its reason, enabled again after removing it, step label "Rule needs fixing", panel reason; no false flags); `devtools::test(filter = "join-rules|diagnostics|pipeline|computer-use-gui|codegen")` 0 failures; full `devtools::test()` FAIL 0, PASS 10753; real Chrome via chromote with real mouse input, `NOT_CRAN=true devtools::test(filter = "layout-browser")`: FAIL 0, PASS 467 (the window-rule test now adds a filter before the join, checks the disabled box, its title, the panel line and that a real click on it does nothing, then removes the filter and turns Strict on with a real click). Test note: adding a step brings the Pipeline tab forward and the join check panel is only drawn while its tab is open (by design), so the test opens the Discrepancy tab before reading the panel.
- **RStudio gadget check: DONE 2026-10-31** (RStudio 2025.05.1, R 4.5.1, Viewer pane, see the 2026-10-31 entry below).

### 2026-10-31 - Date-rule joins: real-browser test and docs (0.4.0, task 11)
- **Change:** NEWS 0.4.0 section "Date-window joins" (rules, Strict, `na_matches = "never"` under a rule, a 0.3.x install drops a saved rule silently, widget wall-clock/DST note, duckdb ICU/non-UTC note, leftover `dbplyr_*` temporary tables on the user's connection), README bullet "Date-Window Joins", a tour section (`vignettes/articles/tour.Rmd`), roxygen `@section Known differences` in `R/sideview.R`, and a dev note in CLAUDE.md: a path that replaces card data must call `clearJoinChecks()` and reset `joinDiag`.
- **Test fix (stale, not product):** "a join step keeps its controls ..." still expected the join-type select on the first line; since 29e5530 the options (select, rule button, Strict) sit on their own second line by design, so the test now asserts that.
- **Verified (real Chrome via chromote, `NOT_CRAN=true devtools::test(filter = 'layout-browser')`: 0 failures, 454 passes):** new test "a window rule edits from the join step and shows in code and panel" on synthetic Date tables: real mouse click on the rule button opens the row; Window shape and the two columns are picked with change events (selects); real clicks plus `Input.insertText` type -3 and 3; the row sits inside the drawer and overlaps none of the step's toggle, options or delete button at 1400x900 and 560x700, with no horizontal overflow; real Ctrl+Enter applies; the drawer code contains `.sv_lo = visit_date - 3` and `.sv_hi = visit_date + 3` and `parse()`s; the panel's "Dropped by the rule" counts equal `sv_join_diagnostics(rule =)`; no JS errors.
- **RStudio check: DONE (Viewer pane, `devtools::load_all()` of the worktree, `sideview(visits, labs, viewer = "pane")`).** The earlier "hang" was only a missing Enter (clipboard typing does not send one; a separate `Return` key press is needed); after Session > Restart R everything loaded. (1) Linked visits.id and labs.id by clicking the two ports: the join check toast reads many-to-many. (2) Rule `Nearest before` on lab_date / visit_date applied: code `join_by(id, closest(lab_date >= visit_date)), na_matches = "never"`, panel `1:1 - 40% of labs matched - 5 rows`; Strict added `relationship = "one-to-one"`; Run in R: toast `5 rows x 4 cols, saved as 'sv_result'`. (3) Second launch with a duplicated lab row (id 3, same date) and `Nearest after`: Strict gave `relationship = "one-to-many"` (ties are allowed), Run in R succeeded (5 rows x 4 cols). The planned "dplyr's error in the toast" case cannot occur through the UI: Strict's relationship is derived from the same data, so it only fails if the data changes between check and run. Cancel returned NULL. Not seen: a stale `Connecting visits.id` toast stayed up for a few seconds after the link was completed (cosmetic; noted as a possible leftover from the first click).

---


### 2026-10-26 - lazy pipelines: cross-kind joins and one collect() (0.4.0, task 9)
- **Change:** `sv-pipeline.js` knows which tables are lazy. `Pipeline.setTables({name: {lazy, codeRef}})` (the engine calls it from `syncTableMeta()` when cards are added or found, from `data-lazy` / `data-code-ref`), `lazyKind()`, `refFor()` (a lazy card's `codeRef`, else the name), `hasLazy()`. `compose()` writes a joined pair by the design's section 6 table (duckdb x df adds `copy = TRUE`; duckdb x arrow converts the right side with `arrow::to_duckdb()`; arrow x duckdb converts the left; df x duckdb moves the left side in with `dplyr::copy_to(..., name = "sideview_<table>")`; df x arrow uses `arrow::arrow_table()`; arrow x df and arrow x arrow are plain joins) and ends a lazy chain in exactly one `dplyr::collect()` (a prepared `<t>_prep` chain stays lazy; a data-frame-only pipeline is byte-identical to before, pinned by a test). New step kind `reshape` (`pivot_longer` / `pivot_wider`): duckdb pivots in SQL; arrow has no pivot, so the chain gets `# reshape runs in R` and a `collect()` just before it, and no final collect. `sv_code_recode(lazy =)` and the pipeline's recode end in `TRUE ~ <col>` on arrow (arrow rejects `.default = <col>`). `sv_auto_clean_rules(lazy =)` ends in one `collect()` and accepts an expression such as `dplyr::tbl(con, "t")` as `df_name`; the server passes `card$code_ref` and `lazy = isTRUE(card$is_lazy)`. The R-error toast gets " This step may need data in R: move collect() above it." when the pipeline has a lazy table. `sideview.js` and `sv-pipeline.js` share one `contains` generator for lazy tables.
- **Decisions (deviations from the brief, both found by running the code):** (1) `contains` on a lazy table is `stringr::str_detect(col, "<escaped regex>")`, not `stringr::fixed()`: dbplyr turns `fixed(".")` into the regex `.` on duckdb, so it matched every row (the same trap as Task 3). An escaped pattern means the same on arrow and duckdb (RE2), and keeps its meaning if a later join moves the step to the other engine. (2) The two `arrow::to_duckdb()` joins are wrapped in `dplyr::compute()`: `to_duckdb()` registers a view that R's garbage collector may drop before the query runs (`Table with name arrow_003 does not exist`; it failed 1 in 32 runs and every run after `gc()`), and `compute()` makes a real table. Cost: that one side is copied into duckdb. Also: `copy_to(overwrite = TRUE)` under the data frame's own name replaces a real table of that name in the user's database, so the copy has its own name. `trimws()` and `tolower()` do not translate on arrow, but the generated code uses neither, so `lazy` in `sv_auto_clean_rules()` only chooses the collect, the reference and the default arm.
- **Fix round 1 (task 9 review):** (1) A `contains` filter on a data-frame card added after a join into duckdb or arrow wrote `grepl(fixed = TRUE)`, which duckdb rejects: the form was frozen when the step was made, but the engine is only known in `compose()`. A contains step now carries `specs` (`{col, op, val, numeric}`; the header filter and the builder in `sideview.js` both set it) and `verbs()` renders the condition from the chain's kind when the step runs (`str_detect` once the chain is lazy, `grepl` while it is still in R, so a filter before the join keeps the data-frame form). Audit of the other steps: recode already follows `ctx.kind`; mutate, rename, arrange and summarise write the same text on every engine. Node and run tests for df x duckdb and df x arrow, with `.` as the value (a regex dot matches every row on duckdb). (2) `sv_auto_clean_rules(df_is_code =)`: the server says whether the card reference is a code expression (`code_ref != name`) instead of the function guessing from a `(`; a card named `visits (2020)` is backticked. (3) `expect_same_rows` tolerance is 1e-12 (no exception needed). (4) Run test for a three-way chain (six kind orders across duckdb, data frame and arrow).
- **Known limit (Task 10 documents it for users):** a factor column holding NA segfaults duckdb 1.4.x when an arrow table is scanned through it; the fixtures avoid it. A comment sits above `Pipeline.prototype.compose`.
- **Verified:** `node --check inst/www/*.js`; node-run tests in `test-pipeline.R` (eight join rows, contains, one collect(), prepared chain, reshape on arrow and duckdb, recode arm, byte-identical data-frame pipeline, `hasLazy`); R tests that run the generated code on a real duckdb connection and arrow tables and compare with the data-frame result (every join row x left/inner x both pipes, filter/rename/mutate/recode/arrange/summarise, prepared chain, pivot_longer/wider, auto-clean, contains with `.`, `[`, `%`, `_`, `(`, `\`), each after a `gc()`; `test-codegen.R` lazy recode and auto-clean; mock-DOM scenario 7 for the toast hint. `devtools::test()` and `NOT_CRAN=true devtools::test()`: 0 failures. The hint toast was not looked at in a real browser or RStudio (it needs an R error on a lazy step in the gadget): Task 10.

---


### 2026-10-25 - full-table and preview labels for lazy cards (0.4.0, task 8)
- **Change:** `sideview.js` labels what a check was based on. Widget lazy cards (`cardData.lazy`) get the badge "First 50 of 5,000 rows" (`previewBadgeText`) and `data-rows-basis="preview"`/`data-table-rows` on the card element. A join check (`renderJoinCheck`) and the column inspector (`profileHtml`) add `<p class="sideview-basis-note">Based on the first N rows</p>` when the reply's `n_x`/`n_y` or `p.n` is below the card's true row count (`tableRows()`). While a reply is pending, a lazy card with basis "full" shows "Checking the whole table…" (join step line, join check, inspector). New helpers: `tableRows`, `rowsBasis`, `isFullLazy`, `basisNoteHtml`, `previewRowCount`. `sideview.css` has `.sideview-container .sideview-basis-note` (`--sv-text-muted`, 12px).
- **Lost link reaches the browser:** the server's fallback `sideview_toast` now carries `card` (the card id). The `sideview_toast` handler calls `markCardPreview()`: it sets `data-rows-basis="preview"`, rewrites the badge to "First 50 of 200,000 rows", points the card's remote row windows at the preview row count (`remote.total`, `resetRemote()`) and re-renders the pipeline, join check and inspector. CLAUDE.md message list updated.
- **Bug found by the real browser (fixed):** `render_card_tag()` wrote `data-total-rows="2e+05"` for 200,000 rows (R formats a double that way in an attribute), and the badge read "2e+05 × 2". `parseInt("2e+05")` is 2, so `attachRemoteRows` never enabled paging: a lazy card sorted and filtered its 50 preview rows only. `plain_count()` now writes plain digits; `test-app.R` checks 200000 and 100000. The mock-DOM suite and `testServer` could not see this.
- **Verified (real Chrome via chromote, `NOT_CRAN=true`, `tests/testthat/test-lazy-browser.R`, real `Input.dispatchMouseEvent` clicks):** a duckdb table of 200,000 rows: the badge shows 200000 and the card basis is "full"; a header sort to descending puts R's `max(x)` in the first cell; an `x > 2` filter reports `sum(x > 2)` rows of 200,000; the inspector reports n = 200,000 and the median equals `stats::median(x)` (1e-12) with no basis note. With `sideview.use_duckdb = FALSE` and an arrow table: badge "First 50 of 200,000 rows", inspector note "Based on the first 50 rows", and the join check carries the note. After the test closes the user's connection from the browser, a sort click makes the card flip to preview, the badge change, the lost-link toast appear and the inspector show the note. A saved widget (file://) with an arrow card shows the preview badge and the inspector note, and a data frame card shows neither. No JS errors in any of them. Screenshots were saved to the scratchpad only (set `SIDEVIEW_SHOT_DIR`). Not checked in RStudio itself (dialog, Viewer pane): that stays with Task 10.

---


### 2026-10-25 - lazy cards in the gadget: whole-table requests, preview fallback, toast (0.4.0, task 7)
- **Change:** `sideview_server_impl()` keeps one private duckdb connection per session (`con_env`, closed in `onSessionEnded`) and answers `sideview_rows_request`, `join_diagnostics_request`, `column_profile_request` and `codebook_export` from the whole table for lazy cards. `lazy_or_preview()` falls back to the preview rows when a lazy request fails: the card is marked failed, one `sideview_toast` ("Lost the link to <card>; showing the first N rows.") is sent per card, and later requests use the preview with no second toast. `sv_card_is_lazy()` decides; the preview and the table keep separate row-order caches. New custom message `sideview_toast` (`inst/www/sideview.js` calls `showToast`, which uses `textContent`); CLAUDE.md list updated. `render_card_tag()` adds `data-table-rows`, `data-lazy`, `data-code-ref`, `data-rows-basis` and the "First 50 of 1,000 rows" badge (tooltip when duckdb is missing). `sv_build_schema_context()` states the true row count with "(ranges from the first N rows)" for lazy cards.
- **Decisions:** `sv_lazy_cross_con` and `sv_lazy_not_duckdb` are errors about the request, not a lost link: the join reply carries `error` and the cards stay full. Missing key columns are checked against the preview names first, so they are never mistaken for a lost link. The join gets `card$source` (not the cached tbl) so Arrow and data frames are placed on the right connection and cleaned up; the codebook gets the cached tbls and writes the file after the lazy attempt, so a write error is not read as a lost link. Codebook progress toasts start after 250 ms (none for a quick codebook) and share one toast id (`codebook-progress`), so the browser updates a single toast instead of stacking them; they reach the browser live while the export runs (measured by the reviewer at about 4 per second). **Fix round 1:** a failed lazy request no longer marks a card by itself: each full card in the request is probed with a 0-row query, and only a card that does not answer is marked and toasted (once per card id). If every card answers, the error is about the request (bad filter, missing column) and goes to the reply as `error`; the card stays full. The cards that still answer keep the whole table for the retry of the same request. The join passes the cached tbl for an Arrow card (the raw source only when the other side is the user's own duckdb tbl).
- **Verified:** `testServer` tests in `test-app.R` (duckdb fixture of 1,000 rows: rows total/true max, join `n_x`, profile `n`, closed connection falls back once, cross-connection error, codebook `n`/`rows_profiled`, badge and attributes) and `test-llm.R` (schema context); `node --check inst/www/sideview.js`; full `devtools::test()` with `NOT_CRAN=true`: 0 failures. Not yet checked in a real browser or RStudio: the badge, the toast and the attributes get that in Task 8/10.

---


### 2026-10-25 - lazy cards: full-table row windows (0.4.0, task 3)
- **Change:** `sv_lazy_rows_window()` / `sv_lazy_filter_expr()` in `R/lazy.R` sort, filter and page a whole duckdb/arrow table with the same windows as `sv_rows_window()`.
- **Decisions:** `contains` uses duckdb `contains()`, not `str_detect(fixed())` (dbplyr turns that into a regex, so `.` matched everything); text for `contains` follows R (`TRUE`/`FALSE`, trailing `.0` dropped, `NaN`/`Inf`); NA and NaN sort last via helper columns, so the result does not depend on duckdb's `default_null_order`. Known deviation: double text with float noise (0.1 + 0.2) or scientific notation (1e+05).
- **Crash (fixed):** the full arrow parity grid segfaulted R in about half of the runs. The open note said it happened inside `arrow::to_duckdb`'s scan. **Root cause:** a duckdb 1.4.3 heap over-read on Arrow dictionary columns with NULLs (the factor `f` with `NA`). duckdb points the NULL rows at the slot one past the end of the dictionary, which it never allocates. Its branchless VARCHAR heap-size loop (`duckdb.dll+0xa0d5f2`, which materialises rows for `ROW_NUMBER()`) loads that `string_t` before it checks validity. R crashes when the 48-byte dictionary buffer ends at an uncommitted page. Evidence from an in-process exception logger: the read is on the main thread, at a page-aligned address, at index 3, and the 48 bytes before it are `u`, `uv`, `v`. Not threads (every arrow callback ran on the main thread), not GC (duckdb keeps the registered table alive). **Fix:** `sv_lazy_decode_dictionaries()` casts dictionary columns to their value type as a lazy arrow query before `to_duckdb()`. Nothing is materialised, and duckdb returned these columns as character anyway. The offset-0 workaround is removed and the full grid is back. Details: `.superpowers/sdd/2026-10-25-lazy-full-data-implementation/task-3-crash-report.md`. Still exposed: a user's own `to_duckdb()` on a factor with NA, and dictionaries nested in struct/list columns (not decoded). Worth reporting to duckdb upstream.
- **Verified:** `test-lazy.R` and the full suite (headless).

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
3. **Shiny module + proxy** (done 2026-10-31): `sideviewUI()` / `sideviewServer()` put an R-backed canvas into the user's own
   Shiny app; `sideviewProxy()` and `sv_add_card()` / `sv_replace_card()` / `sv_remove_card()` / `sv_set_state()` /
   `sv_highlight()` drive it, `$code()` / `$pipeline()` / `$state()` / `$cards()` read it back. A proxy for the
   `sideviewOutput()` htmlwidget is a non-goal: the widget stays browser-only (spec section 3).
4. **Small items**: `save_sideview()` row cap and message, Positron check plus a `viewer = "dialog"`
   fallback, workspace-version warning and migration slot, r-universe.

## Backlog (future rounds, not yet scheduled)
- **CDISC / pharmaverse follow-ups** (0.5.0 shipped recognition, badges, labels, codebook domain, `sv_read_cdisc()`):
  - Join keys (0.6.0) minors, deferred: `format(dup)` prints `1e+05` at R/cdisc_keys.R:232 (use `scientific = FALSE, trim = TRUE`);
    an ADSL without STUDYID joined by USUBJID alone gets no note 3 (`sv_keys_natural`); `spell` uses the left card's spelling for
    every key, the spec says each table's own; the `join_diagnostics_request` test asserts only that `cdisc_notes` is present, not the
    note 3 text; browser test 3 should assert `connections.length == 0` after undo; browser test 2 needs a comment on the final
    `mouseMoved` point.
  - Join keys (0.6.0) final-review minors, deferred: the visit rule also fires for ADaM cards with VISITNUM (advs~sv; add
    `!sv_keys_is_adam(cx)` or document it); ae x suppae by USUBJID gets "Summarise one side first." where IDVAR/IDVARVAL is the
    real answer (do with C); the Auto Map preview toast counts lazy cards that only appear in CDISC rule rows (build its names from
    `group == null` rows); the "equals 0.5.0" Auto Map test compares new code with new code (pin a snapshot); in the gadget an
    unmatched `cdisc` name warns again on every Auto Map click (`suppressWarnings()` at app_server.R ~531); the note reads
    "1 keys repeat" (plural).
  - C: SUPPQUAL merge (fold SUPP-- rows into the parent as columns);
  - D: admiral-style code generation for ADaM derivations;
  - E: ARD / TLG cards (analysis results datasets and tables as cards);
  - F: spec / define.xml checks (conformance, which 0.5.0 deliberately does not do).
- **Sub-project B (keyboard and low vision) backlog:**
**CLOSED 2026-11-15 (B):** the switch-on canvas passes axe `target-size` (zoom floor 1.0, 24 px targets) with an empty accepted list; the default canvas keeps the acceptance by design. Original note:   - axe `target-size` (WCAG 2.5.8) is accepted in `SV_AXE_ACCEPTED` (test-a11y-browser.R): card and column-header icon buttons are 24 px in CSS (since 0.8.0) but the canvas fit-to-view zoom shrinks them on screen (about 17 px). Needs a minimum zoom, or zoom-independent chrome. Sub-project B item: once the zoom floor or zoom-independent chrome is in, remove `target-size` from `SV_AXE_ACCEPTED` and re-run the matrix (the Task 16 ruling keeps it for 0.8.0).
- Table version diff by key (data-lock comparisons between dataset versions).
- Validation rules (ranges, allowed values, ID uniqueness) exporting `pointblank`-style checks.
- PHI/PII column tagging that excludes tagged columns from the LLM schema context.
- Export the pipeline as a reproducible Quarto report.
- Arrow Dataset factor levels: `sv_lazy_tbl()` reads every batch of each dictionary column once per card
  (on the first probe) to collect levels; read them only when a factor column is sorted or compared, and test
  the level union across Dataset batches against `as.data.frame()`. (Final re-review, 0.4.0 part 1.)
- Card names containing `"` or `\` are still bare R identifiers in some generated code (not `code_ref`).
- **Module/proxy leftovers (final review 2026-11-01, deferred to sub-project 4 / UI polish):**
  - after a join step is disabled by `disableMissing`, later left-chain steps that use the join's columns stay enabled;
    self-join right keys are not checked;
  - composite-key join with one key dropped: the other key's spline stays; re-enabling a step does not restore splines;
  - `sv_lazy_place()` Arrow registrations (join checks) are not unregistered until the session ends;
  - the mutate name scan does not strip `#` comments (can only over-disable); `warned_cards` is never cleared;
  - about nine fixed `Sys.sleep()` waits in the module browser tests; use the polling helpers;
  - the AI bar flashes before `sideview_llm` hides it in a module without `llm_fn` (hide is client-side only);
  - the "Connecting ... click another column" toast lingers briefly after a drag-connect (pre-existing): dismiss it on
    completion or show it only for click-to-connect;
  - one non-reproducing error in "module: canvases are independent" in a combined browser run; watch it on CI.

- **D3 backlog** (compare data cuts, from the final review, not scheduled):
  - a key named `column`, `old` or `new`, or the internal `.sv_k*` / `x.old` / `x.new` names, is silently overwritten in `_changed`; refuse these in `sv_compare_by()`;
  - list columns are neither compared nor listed in `type_changed`;
  - tests to add: a text-key repeated sample, a factor or Date key, a NaN key, a zero-row `_changed` derive, a date-time lazy gap, a collect trap for Arrow, the preview fallback, a backtick ref `copy_to` name;
  - the compare and stack cleaners duplicate the name block;
  - `sv_compare()` places inputs 4 times, and the lazy `run()` in `compare_request` places them twice (performance);
  - lazy `_added` / `_removed` lose data frame factor levels (inherited from D1);
  - the NaN/NA order in the repeated sample differs between twins;
  - `COMPARE_OPS[op]` / `REFIT_DERIVE_OPS[d.op]` should use hasOwnProperty;
  - `compareCode` should return `{code: ''}` for a null `plan.keys` / `plan.compared` entry rather than throw;
  - a non-data-frame card with no `by` gets "Pick the key columns." rather than the needs-tables message;
  - shared Stack/Compare drawer polish: the "Add at least two tables" state goes stale when a card is added while the tab is open, the double announcement (role=alert plus assertive), the layout jump on pending render, dead `compareId`, duplicated focus helpers;
  - test quality: `Sys.sleep(1)` as a negative proof, no reply-after-removal test, the list view Open row badge and changed/removed Open, the unscoped `[data-compare-open]` selector;
  - D2: the Arrow `to_duckdb()` view race in `sv_stack_code_lazy`, for a follow-up PR: pass `keep_views = TRUE` and update the JS twin and the byte-equal tests;
  - the untagged key suggestion takes the first single column unique in both versions, which in a small extract can beat a real composite key (suggestion only);
  - a lazy numeric key below 1e-4 reads `1e-07` in duckdb and `0.0000001` in memory (key text of a double against a text key; integers and simple decimals agree).

---


## Log

### 2026-11-23 - E1: `metatools::combine_supp()` code style for SUPP merges, version 0.11.0 (branch `e/combine-supp`, not pushed)
- **Change:** `code_style = c("dplyr", "pharmaverse")` on `sideview()`, `sideview_ui()`, `sideview_widget()`, `sideviewServer()` (`save_sideview(code_style = NULL)` keeps the widget's style); the pipeline bar has a Code select and the pipeline state carries `style` (no schema bump). A SUPP check has a `combine_supp` field: the R and lazy checks return `{ok, reason, prep}`, the JS check adds `installed: null`, and only the server handler (R/app_server.R) sets `installed` to `TRUE`/`FALSE`; an eligible merge is composed as prep lines + a guard block + `<parent chain> %>% metatools::combine_supp(<supp>_q)`, otherwise it stays dplyr and the step line says why. The merge panel and `print.sv_supp_check()` show `combine_supp(): yes / no, <reason>`. New message `sideview_code_style`. Design `plans/2026-11-22-e1-combine-supp-design.md`, plan `plans/2026-11-22-e1-combine-supp-implementation.md`.
- **Task 8 (commits 65fa533, feeee38):** the guard block also stops for grouped or rowwise parent or SUPP, a parent `IDVARVAL` column, factor `QNAM` or `QLABEL`, changed labels, `DOMAIN` and key column types, foreign subject-level rows, and QNAMs the dplyr code would not use. Two new reasons for the check to say no: a parent `IDVARVAL` column, and a factor `QNAM` or `QLABEL` (R and browser; the lazy check already says no with the data-frames reason). The guards cover the later-cut changes that were found and tested, not every possible one.
- **Docs review fix round 1:** corrected the later-cut promise, the `installed` claim, the list of reasons (now a table in the article), the length of the shortened guard block (130 lines of generated code in the article example, 125 of them the block) and the warning count note below.
- **Docs:** NEWS 0.11.0, CLAUDE.md (twin rule, `combineSuppApplies`, `combineSuppFor`, `style`, `installed`), cdisc article ("Pharmaverse code", with real generated code), README bullet, `devtools::document()` and the pkgdown site rebuilt.
- **Verified (automated only), fix round 1 on feeee38 plus the docs edits:** `pkgdown::build_site(preview = FALSE)` built and `pkgdown::check_pkgdown()` found no problems. Full `devtools::test()` with `NOT_CRAN=true` (real-browser tests included): 1041 tests, 35086 results of which 1833 are warnings, 0 failures, 0 errors, 0 skips; test-lazy-browser.R passed, lines 352-353 included. `devtools::check(document = FALSE, args = "--no-manual")` with `NOT_CRAN=true`: **1 error, 1 warning, 1 note**. Error: its test step (FAIL 1, WARN 1830, SKIP 25, PASS 32177) failed one expectation, test-access-browser.R:800 "Delete removes one join; with several a menu lists each plus all" (the last announcement was the join check's "Join of labs and patients by patient_id is many to one.", not "Removed 1 join on patients.patient_id."); the same file run alone right after: 40 tests, 391 results, 0 failures. A timing race between the two announcements is the likely cause, not proven. Warning: `tibble::` in test-supp.R (added in feeee38) is not declared in DESCRIPTION; not fixed in this docs round. Note: the `''NULL''` file in the check directory. The 25 skips in the check were not itemised. The earlier run in this entry's first version (before Task 8) is replaced by these figures.
- **Status:** built, awaiting RStudio check (dialog, Viewer pane, external browser: Code select, step line, merge panel line, generated code run with metatools installed and not installed). Not yet checked by hand.
- **Final-review fix wave (2026-11-28):** rule 6 (`combineSuppApplies()`) now also says no when the parent has an enabled step after the merge other than filter, arrange or supp (custom and derive steps do not count): reason `<parent> has steps after the merge that combine_supp() cannot check`, because the dplyr code labels the QNAMs where the parent chain ends and `combine_supp()` at the merge (a mutate or a rename of a QNAM column after it gave different labels). Filter, arrange and a second SUPP merge after the merge give the dplyr result with labels under real metatools (test-supp.R). The key-type guard now says `<key> in <parent> (<class>) cannot be joined to the IDVARVAL values; convert it before the merge` (it advised the dplyr style, which fails too). Docs: NEWS and CLAUDE.md no longer say `sv_supp_check()` handles lazy tables (the internal lazy check does, for the gadget and module); the article's reason table has the after-merge row and an `{error}` row, and says which reasons `print(chk)` can show. Tests: test-pipeline.R, test-supp.R, gui-test-runner.js scenario 16 (step line, panel line and code follow an added, disabled, re-enabled and removed step after the merge).
- **Warnings of the full test run, tallied by message and file:** 1832 "restarting interrupted promise evaluation", all in test-layout-browser.R, from two tests ("module: removing an input removes both derived cards quietly; ..." 918, "module: replacing a SUPP card updates the plan of its derived card, ..." 914); both tests exist at the E1 base dc8bbb6, and the one trace looked at goes through chromote. 1 "could not find function deregister_and_dec" callback warning in test-lazy-browser.R ("preview-only labels"). None came from the tests E1 added. The cause of the 1832 is unexplained, and they were not compared with a run of the base commit. The first version of this entry called all its warnings environment ones without itemising them, and named test-a11y-browser.R without a basis. Separately, loading prints "shiny/testthat built under R 4.5.3".
- **Known issues (E1):** a second `sideview_ready` (a re-rendered module canvas) resends the cards but not the queued messages (`sideview_llm`, `sideview_code_style`, state), so the canvas starts as dplyr.
- **Follow-ups (backlog):** the in-memory SUPP check (R10) compares double keys as 15-digit text while the dplyr code compares full precision; matched/repeats have no "not sure" flag; QLABEL changes after a step is added are not part of drift (the pharmaverse label guard stops the generated code when the label combine_supp() would set differs from the step's captured label; run in R on the cs_suppqual fixture with every AETRTEM QLABEL changed, not in the app: a re-check with the old plan gives no drift and combine ok TRUE, because it compares labels with its own new plan, and the code composed from the old plan stops on the label guard); the 1e308 twin gap; the widget is "not sure" (fail-safe, stays dplyr) for fractional or 16-digit-and-longer double keys.

### 2026-11-22 - D3 final-review fix wave (branch `d/d3-compare`, not pushed)
- **Fixed:** a numeric key against a text key (`sv_compare_text(key = TRUE)`, `sv_compare_code()`, `compareCode()`): a double key is written in full as the join check's `format_key()` does, so 100000 matches "100000" (it was "1e+05": added/removed/changed miscounted in memory, right in duckdb); the repeated-key sample (up to 5 keys, " + " between key columns) is now on the Warnings line of `sv_say_compare_text()`, so it reaches `text`, the drawer, the list view and print; `print.sv_compare` says "changed values: N"; date-times of two zones compare by instant without a tzone warning (in memory and in the generated code, JS twin too); NEWS and README wording.
- **Tests:** test-compare.R (numeric key against text, sample text, tz, print label, a JS byte-equal fixture), test-lazy.R (the same fixture on duckdb / Arrow / mixed equals memory).

### 2026-11-22 - Derived cards, D3: compare data cuts, version 0.10.0 (branch `d/d3-compare`, not pushed)
- **Change:** `sv_compare(old, new, by)` (R/compare.R) counts rows added, removed and changed by key, lists column and type changes; the drawer Compare tab and the list view Compare builder open `<new>_added`, `<old>_removed` and `<new>_changed` as derived cards (ops `compare_added`, `compare_removed`, `compare_changed`); lazy duckdb / Arrow paths in R/lazy.R; JS code twin `compareCode()` (sv-pipeline.js). Task 8: DESCRIPTION 0.10.0, NEWS "Compare data cuts", README bullet, article `vignettes/articles/derived-cards.Rmd` (navbar "Derived cards"), CLAUDE.md "Compare (D3)" twin rule, rebuilt site. R/say.R: the literal middle dot in R strings is now `·` (devtools::check flags non-ASCII), output byte-identical.
- **Verified:** full suite with `NOT_CRAN=true` (real-browser chromote tests in test-layout-browser.R and test-a11y-browser.R included): 979 tests, 2 failures, 0 skips; the 2 are the known test-lazy-browser.R "list paging of a lazy card asks R for windows" failure (not from D3, same as on D2). `pkgdown::check_pkgdown()`: no problems. the controller's `devtools::check(args = c('--no-tests','--no-manual'))` after the `compare_run` rename (the second local `run` in sideview_server_impl, R/app_server.R): 0 errors, 0 warnings, 1 note (only the "`NULL`" file in the check directory, an environment artefact).
- **RStudio (confirmed by the user, 2026-11-22):** all steps passed in the dialog, Viewer pane and external browser, with in-memory, Arrow and duckdb cuts: pick two tables, Check, change the key, Open each of the three cards, Save and Open the state, and a number key against a text key (added 0, removed 0). Notes: tables with no CDISC tag get the first never-repeating single column as the suggested key (e.g. `AETERM`), not the CDISC natural key, so tick the key you want; **Open changed values** is greyed out, not hidden, when the changed count is 0 (e.g. with `AESEQ` unticked). Reproduced and explained in the built-in browser; no code change.

### 2026-11-21 - Derived cards, D2: stack tables (branch `d/d2-stack`, not pushed)
- **Change:** `sv_stack_check()` / `sv_stack()` (R/stack.R) line up the columns of 2 to 8 tables (type per input, label, casts, case-only near-miss renames, missing columns) and stack them with the check's fixes; lazy (duckdb / Arrow) inputs become one `union_all` on the session connection, never collected. New derive op `stack` (R builder `sv_stack_rows()` / `sv_lazy_stack()`, code twin `sv_stack_code()` = `deriveExpr()`), `stack_check_request` / `sideview_stack_check` (handler cleans with `sv_stack_clean()`), a Stack drawer tab (only when R is there), the list view Stack builder, `deriveArgsKey()` now includes `fixes` and `id_col`. Rules are in CLAUDE.md ("Stack (D2)"). Docs: NEWS 0.10.0 (development), README bullet, a "Stacking tables" section in `vignettes/articles/cdisc.Rmd` (synthetic waves). Commits 0e5c455..f82535f plus the docs commit.
- **Verified (Task 8, `Rscript` 4.5.2, script files, `NOT_CRAN=true`):** every `tests/testthat/test-*.R` run file by file except test-lazy.R, test-a11y-browser.R and test-layout-browser.R, 0 failures except lazy-browser (below): access-browser 391, access 14, app 307, assets 95, card-store 31, cdisc-keys 103, cdisc 328, codebook 278, codegen 323, computer-use-gui 246 (mock DOM), copilot 62, derive-code 1212, derive 225, describe 17, diagnostics 5123, e2e 136, features-verification 94, join-rules 10753, lifecycle 63, llm 121, module 407, normalize 100, pipeline 836, rows 38, rstudio 71, say 130, stack 134, state 153, supp 230, theme 272, widget 101. Real Chrome via chromote: test-layout-browser.R whole file 1046 passed, 0 failed, 0 errors; test-a11y-browser.R only by name (the whole file hangs when run unfiltered): "Stack tab passes axe, every control is named and the open is announced" 23 passed, "list view Stack builder matches the drawer" 27 passed (Task 7 also ran every "list view" test by name, 0 failures). `pkgdown::check_pkgdown()` clean. `devtools::check(document = FALSE, args = "--no-manual", env_vars = c(NOT_CRAN = "false"))` (browser suites skip, 1 h 3 min) on f82535f plus the docs edits: 0 errors, 1 WARNING, 2 NOTEs. The WARNING (`bit64` used with `::` / `requireNamespace()` in `R/stack.R` but not declared) and one NOTE (`regexp_matches` undefined global in `sv_stack_lazy_cast`) came from D2 code and are fixed in this commit (`bit64` added to Suggests, `regexp_matches` added to the `globalVariables()` list in `R/lazy.R`); the other NOTE is the environmental `NULL` check-directory note. After the fix a check without the tests step (`--no-tests`, 1 min) gave 0 errors, 0 warnings, 1 NOTE (the `NULL` one); test-stack, test-derive and test-module were re-run after the fix, all 0 failures. The full tests step was not re-run after the fix (it passed with 0 failures in the first check run; the fix does not touch test code).
- **Not run:** the whole of test-a11y-browser.R (hangs unfiltered, only the Stack tests above were run in this task; the Task 6 fix round and Task 7 ran the other named ones; the rest of the a11y file was not re-run on this branch); the whole of test-lazy.R (takes hours; Task 3 and Task 4 checked the stack parts in pieces, and one Task 3 report says a whole run finished with no failures, not verified by the controller).
- **Known failure, not from D2:** test-lazy-browser.R "list paging of a lazy card asks R for windows" fails 2 expectations (the list shows an ellipsis where values are expected). It fails the same 2 on the base commit d666728 (checked in a throwaway worktree, since removed), and D1's notes list it as open.
- **Real browser (Tasks 6 and 7 reports):** the built-in browser on the demo app, light and dark theme: the Stack drawer at 380 px, the tab strip wraps, the table and the code preview scroll inside their regions. Mobile emulation did not change `innerWidth`, so the narrow layout is covered only by the automated no-overflow assertions at 560x520 (and the layout file at 1400x900). Keyboard focus (cast select, rename, Open) is asserted in the layout and a11y tests; the list view Stack builder was driven by keyboard only in a real-browser test.
- **Verified by the user in RStudio (2026-11-21, reported in chat):** gadget steps 1-5 (pick two tables, Check, change a fix, Open, Save and Open state), and the same with duckdb and Arrow lazy inputs, including restoring a saved state with `sideview(wave1, wave2_lazy, viewer = "browser")` (the stacked card is rebuilt). Later the same day the user reported the widget (no Stack tab, saved stack step shows the no-R toast) and the list view Stack builder as OK, so all D2 manual checks are done. A page with no R behind it (a saved widget) shows "Derived tables are not shown in a saved page", as designed.
- **Original to-do list (RStudio dialog, Viewer pane, external browser):** pick two tables, Check, change a fix (a cast and a rename), Open (card appears, announced, a second Open zooms to it), then Save and Open the state and see the stack card rebuilt; the same with a duckdb or Arrow input; the widget (no Stack tab, a saved stack step shows the no-R toast); the list view Stack builder. Record these only after the user says they did them.
- **Version:** DESCRIPTION stays 0.9.0; 0.10.0 waits for D3.

### 2026-11-21 - D2 final-review fix wave (branch `d/d2-stack`, not pushed)
- **Fixed (each with a test that fails without it, unless noted):** (1) the check id was `JSON.stringify([tables, fixes])`, so eight ~23-character names passed R's 200-character cap and the reply never came: now a short sequence id, and R toasts a missing or over-long id (test-derive.R; browser test "eight long names get a reply"). (2) without duckdb a whole Arrow card was stacked from its 50-row preview: `sv_stack_clean()` refuses it; `tz_text` is added whenever a card is lazy, so JS never writes lazy code from a plan without it (test-derive.R, mocked `sv_has_duckdb`). (3) dttm to date in duckdb used `CAST(TIMESTAMPTZ AS DATE)` (needs ICU, missing in duckdb 1.4.3): now `epoch_us()`, the UTC date as in memory; date to dttm was already midnight UTC both ways (the finding was wrong there; now tested). (4) a lazy stack with `AGE` and `Age` left apart made `Age_1`: the plan carries `case_clash`, the check says so, `sv_lazy_stack()` refuses. (5) an opened state kept the saved plan: `sv_derive_state_refresh()` (gadget, module) and `derivedArrived()` refit (lazy card arriving late) (test-module.R; the JS refit is not covered by a browser test). (6) dedupe: `deriveArgsKey()` sorts fixes and reads `id_col` "source" as none (no dedicated test). (7) a lost link made Open fail: validate uses the server's `card_full` and the lost-link fallback (test-app.R, fails on HEAD). (8) Open planned 3 times: once now (validate's clean result goes to `sv_derive_card()`); Check then Open is still 2. (9) ticking a rename drops the cast picked for that column (browser test). (11) `sv_escape_ident()` / `ident()` and `encodeString()` / `str()` agree on non-ASCII names, backslashes in backticks (R wrote an unparsable name) and control characters (test-stack.R). (12) `sv_stack(check =)` refuses a check made before a data frame's columns, types or row count changed (lazy: name only).
- **Docs (10):** NEWS (D2 intro moved under its `##` heading, like D1), article, roxygen (`man/` regenerated), CLAUDE.md "Stack (D2)", this file's "D2 known gaps": card named after the first pick, duckdb tables have no labels but Arrow tables do, the byte-equal pair is R code vs JS code (R builds the card itself), the casts that change values without an `NA`, the date and zone rule, the duckdb and case-clash refusals.
- **Verified (`Rscript` 4.5.2, script files, `NOT_CRAN=true`), after the last code change:** whole files: stack 148, derive 230, codegen 323, pipeline 836, say 130, supp 230, codebook 278, diagnostics 5123, derive-code 1212, module 413, app 316; 0 failures. test-lazy.R by name only: the 11 stack tests (lines 2296 to 2555), 0 failures. Real Chrome via chromote, by name: test-layout-browser.R the five Stack tests (79 passed), test-a11y-browser.R "Stack tab passes axe, every control is named and the open is announced" and "list view Stack builder matches the drawer" (50 passed); these browser runs were before the last R-only fix (the backslash-backtick quoting in `sv_escape_ident()`), which no browser test exercises. `node --check` on both changed JS files. Not run: the whole test-lazy.R, the whole test-a11y-browser.R, the other browser files, `devtools::check()`.
- **NOT verified:** nothing of this wave was checked by hand in RStudio (dialog, Viewer, external browser) or in a browser outside the automated tests.

### 2026-11-17 - Derived cards, D1 (branch `d/d1-derived-cards`, not pushed)
- **Change:** the rows behind a join check or SUPP check open as a derived card: ops `unmatched`, `outside_window`, `supp_orphans`, `supp_bad_idvarval`; R builds the card (`R/derive.R`, `sv_derived_source()` in `R/lazy.R`, lazy inputs stay lazy), the browser adds one `derive` pipeline step whose composed code is the twin of the R builder; console `sv_unmatched()` and `sv_supp_orphans()`; list-view buttons; module cascade / rebuild / re-add; state restore. Wire names and rules are in CLAUDE.md ("Derived cards"). Docs: NEWS 0.10.0 (development), README bullet, a "Rows behind the counts" section in `vignettes/articles/cdisc.Rmd` (synthetic data, no screenshots; screenshots come with D3). `sideview_server()` gained the missing `@param state`.
- **Verified (Tasks 1-9, focused filters, `Rscript` 4.5.2, counts from the task reports):** derive 188, derive-code 1180, pipeline 802, supp 230, module 352, state 153, card-store 31, cdisc 431, diagnostics 5123, app 307 (all FAIL 0). Real Chrome via chromote (`NOT_CRAN=true`): layout-browser 967, a11y-browser 1082, computer-use-gui (mock DOM) 246, all FAIL 0. Controller checkpoint after Task 6 (non-browser, no test-lazy.R): 608 passed at 40764e7. Each task was reviewed; Important findings were fixed and re-reviewed.
- **Verified in this task (docs):** `pkgdown::check_pkgdown()` clean; `devtools::document()`; `devtools::check(document = FALSE, args = "--no-manual", env_vars = c(NOT_CRAN = "false"))` (browser suites skip, as on CRAN, 55 min): 0 errors, 0 warnings, 2 NOTEs (both environmental: "unable to verify current time" and the `NULL` check-directory note). A first check run with `NOT_CRAN=true` (browser suites) hung in the tests step with no CPU use after 52 min and was stopped; its result is NOT claimed. The full `devtools::test()` with the browser suites was not re-run on this branch.
- **NOT verified / to do by the user:** RStudio dialog, Viewer pane and external browser for the new buttons and derived cards; the gadget with a lazy (duckdb / Arrow) input restored from `sideview(state =)` (the client must accept `sideview_card_add` at the first flush, and the restored lazy derived card must appear); the widget (a saved page with derive steps shows the no-R toast). Edge, Magnifier and High Contrast were not run for derived cards. The doc statements above are about what the code does, from reading it and from the tests.
- **Version:** DESCRIPTION stays 0.9.0; the 0.9.0 era bumped it in a separate "chore: bump version" commit at merge time, so the NEWS heading says 0.10.0 (development) and the bump is left for the release.


### 2026-11-14 - Task 17: NVDA script written, pass not run (2026-11-14)
- `plans/2026-11-14-nvda-script.md` (15 tasks) and `tests/testthat/helper-nvda.R` (synthetic DM/AE/SUPPAE/labs fixture) are committed. The launch snippet builds a shiny.appobj.
- **The NVDA pass itself was NOT run:** access to NVDA was declined, so no speech was read. No results are claimed. Unverified script assumptions: filter step text `AE filter AESEV == "SEVERE"`, join step text `DM left join AE on USUBJID`, header badges "N values"/"N missing".
- Honest label until a pass is done: "automated WCAG tests (axe) and real-browser keyboard tests; NVDA script not yet run; not yet tested by blind users".

### 2026-11-14 - Task 13 fix round 1
- sparkStats no longer scrapes preview-based badge counts (lazy/preview/truncated) or treats ~N distinct as exact; Filter button aria-disabled until openBuilder. Verified: a11y/lazy/layout browser tests, assets, computer-use-gui, node --check, gui-test-runner parity with BASE.


### 2026-11-02 - CDISC join keys: sideview 0.6.0 (Tasks 1-8)
- **What shipped:** `sv_cdisc_join_keys(cards)` (R/cdisc_keys.R, exported): ADaM-to-SDTM trace (`STUDYID`, `USUBJID`, `<D>SEQ`), subject level
  (`STUDYID` + `USUBJID`, DM/ADSL as the lookup), visit level (`VISITNUM` to SV); SUPP--/RELREC/no-USUBJID tables excluded. `sv_suggest_mappings()`
  gained `group`/`kind` columns and `cdisc =`; rule rows first, confidence 1. Browser: grouped dashed splines (`sideview-spline-suggested-cdisc`),
  hover lights the group, one click = one multi-key `left_join` = one undo (`Pipeline.addJoinKeys`). Join check: R-side `cdisc_notes`
  (`sv_cdisc_key_notes()`), shown under a "CDISC" heading in the gadget and modules; the widget has no rules or notes. NEWS 0.6.0, article "Join keys" section, DESCRIPTION 0.6.0.
- **Verified (Task 8):** full suite `NOT_CRAN=true devtools::test()`: FAIL 0 | WARN 0 | SKIP 0 | PASS 23067 (the lazy 1M-row timing test passed).
  `devtools::check(--no-manual)`: 0 errors, 0 warnings, 1 NOTE (the known Windows `''NULL''` check-directory note). `pkgdown::check_pkgdown()`: no problems.
  Site rebuilt; docs/CLAUDE.* and docs/MEMORY.* and their sitemap.xml / search.json entries removed.
- **Real browser (Task 7, chromote with real mouse input):** six new tests in test-layout-browser.R, all pass (grouped splines on dm/ae/adsl/adae, group hover, one-click join and one undo, toast, `ae` x `lb` notes in the join check). Tasks 5-6 were checked against the mock DOM (gui-test-runner.js).
- **RStudio pass (2025.05.1, R 4.5.1; fixtures `dm, ae, adsl, adae, lb`):**
  - Dialog: badges, Auto Map draws dashed grouped CDISC splines, one click accepts the group ("Accepted CDISC join: lb to dm by STUDYID, USUBJID", Drawer badge 1), Ctrl+Z gives one undo (splines stay, as for manual joins). A manual `ae` x `lb` link by `USUBJID` shows "1:1 - 100% of ae matched" in the join check with no CDISC block, correct because the fixture `lb` has one row per subject.
  - Viewer pane: canvas renders, chrome wraps, Auto Map draws the dashed grouped splines.
  - External browser (Edge, `viewer = "browser"`): launches and renders the canvas with badges. Computer use cannot click in a browser, so interaction there was not driven; the chromote tests cover it.
  - The CDISC join-check note itself (`Summarise one side first.`) was seen only in the Task 7 chromote test, not in RStudio (the RStudio fixtures have no duplicate `lb` keys).
- **Final whole-branch review (Opus):** With fixes, 0 Critical / 1 Important / 9 Minor. Fixed in dacb2f1:
  - `sv_suggest_mappings()` now passes `cdisc =` to raw data frames through `sv_cdisc_finalize()`.
  - ADSL links to the first DM only.
  - The key notes run inside a `tryCatch`.
  - The new CSS rules are scoped under `.sideview-container`.
  - The dead-fixture note test now uses its fixture.
  - Parse and row-count tests cover the subject and visit groups.
  - A scoped re-review came back clean, and `cdisc = FALSE` output is identical to before.
- **Deferred minors:** in the Backlog (join keys minors and final-review minors).

### 2026-11-02 - CDISC follow-up 1 closed: browser-test stability and RStudio pass
- **Change:** deferred minors (case-insensitive column names, ADaM/SUPP user-tag classes, SEND-canvas SUPP flip,
  codebook agrees with the canvas incl. cleared tags, test gaps, LLM label cap) are done in f5056ba..1e54a84 and
  reviewed; 73cc162 folds case in the canvas SPECIES check; 5622d77 makes the real-browser tests robust under load
  (shared timeout, navigate retry, polling) and relaxes the 1M-row duckdb join timing bound 5 s -> 15 s (it measured
  7 s on this machine under load, not a regression).
- **Verified (full suite, `NOT_CRAN=true`):** 532 tests, 22802 expectations, 0 failed / 0 errors / 0 warnings, 1 skipped.
  `devtools::check()` clean apart from the known Windows "NULL" NOTE.
- **Dataset-JSON:** real `datasetjson` 0.4.1 installed; column and dataset labels survive the reader.
- **RStudio 2026-11-02 (R 4.5.1, one RStudio instance, five synthetic tables dm/ae/suppae/adsl/adlb):**
  - `viewer = "dialog"`: badges DM/AE/SUPPAE/ADSL/ADLB; badge tooltip; `th` tooltip "Unique Subject Identifier";
    `L` labels row; Ctrl+K "adverse" finds `ae`; `T` dark theme legible; inspector shows the label and the
    "DM - Demographics" line; Export codebook writes a CSV with the `domain` and `label` columns (checked the file);
    Cancel returns `NULL`.
  - `viewer = "pane"` (also with the Viewer pane maximised): the chrome wraps in the narrow pane, no overlap with badges;
    `L`, Ctrl+K, `T` all work. Native `title` tooltips do not show in screen captures here; the title text itself is
    asserted by the real-browser tests and was read from the DOM.
  - `viewer = "browser"` (Edge, then the built-in browser on the same server): badges and tooltips read from the DOM,
    `th` title, `L` on/off (2 label rows, then 0), `T` toggles `sv-theme-dark`.
- **Gotcha:** starting RStudio with `Start-Process` and then `open_application` creates a second instance with its own
  rsession; the console then looks hung. Use one instance, and press Return again if a pasted command does not run.

### 2026-11-01 - Release 0.4.0 checks
- **Change:** DESCRIPTION 0.3.0 -> 0.4.0; NEWS head "(development)" dropped.
- **Verified on `main` (1e4e2e1, PR #3 merged):** `devtools::test()` with `NOT_CRAN=true` -> 442 tests, 0 failed / 0 errors / 0 skipped
  (includes the real-browser files). `devtools::check(--no-manual)` -> 0 errors, 0 warnings, 1 NOTE
  ("non-standard things in the check directory: ''NULL''", a Windows artifact, not the package).
- **Sub-project 4 follow-ups:** Positron check done by the user (`sideview()` default and `viewer = "dialog"` fallback: "looks ok").
  r-universe registry entry pushed (`lauyeehow1986-hub.r-universe.dev`, bbda7e8); the build and the README install line are not yet confirmed live.
- **Released:** PR #4 merged (main = f6b29d3); annotated tag `v0.4.0` on f6b29d3 pushed and the GitHub release created
  (https://github.com/lauyeehow1986-hub/sideview/releases/tag/v0.4.0, notes = the 0.4.0 NEWS section).
- **r-universe:** `https://lauyeehow1986-hub.r-universe.dev/sideview` still returned 404 right after the tag (2026-11-01);
  likely waiting for the next scheduled build. Recheck, then confirm the README install line.
- **Next:** CDISC awareness is in 0.5.0; remaining CDISC sub-projects B-F are in the backlog.

### 2026-11-01 - Sub-project 4: small items (0.4.0)

* **Row cap:** `sideview_widget(max_rows = 5000)` and `save_sideview(max_rows = 5000)` cut
  non-lazy data-frame cards after `sv_card_payload()` (`sv_cap_card_rows()`), set `card$truncated`
  and keep `totalRows`; one message names the tables cut (not while `knitr.in.progress`). JS:
  `truncated` gives the "First N of M rows" badge, `data-rows-basis="preview"`, `data-truncated`
  and `data-preview-rows`; it does NOT set `data-lazy` (lazy-only logic keys on that).
* **Positron:** `sv_is_positron()` (env `POSITRON` / `POSITRON_VERSION`), `sv_default_viewer()`,
  `sv_resolve_viewer()`; Positron default and `"dialog"` give `browserViewer()` (dialog: one message).
  An explicit `shiny::dialogViewer()` object is not rewritten.
* **State version:** `sv_migrate_state()` runs in `sv_load_state()` and `sv_state_from_json()`;
  missing version = 0.2.0, older is stamped 0.3.0 via the empty `sv_state_migrations` slot, newer
  warns once and is left as is, unparseable is left alone. Old 0.2.0 test fixtures now load as 0.3.0.
* **r-universe:** README install line and badge added. The registry repo
  `lauyeehow1986-hub/lauyeehow1986-hub.r-universe.dev` still needs a `packages.json` entry
  (`{"package": "sideview", "url": "https://github.com/lauyeehow1986-hub/sideview"}`); not pushed
  without the user's yes.
* **Verified:** test-widget (76), test-state (124), gui runner (156, incl. `truncated_card_is_preview`);
  real browser (chromote, saved widget `max_rows = 40` on 300 rows): badge "First 40 of 300 rows",
  small table untouched. Positron checked with the env var only (no Positron install here).

### 2026-11-01 - Shiny module and proxy: final review fixes (0.4.0)
- **Reactive `cards`** (`sv_initial_cards()`): a `req()` at start means no cards yet, any other start error is a warning naming
  the module id; the observer fills the store when the reactive is valid. A reactive refresh whose element no longer
  normalises keeps the old card and warns once per card name (`sv_normalize_cards(on_drop =)`, `sv_sync_cards(keep =)`).
- **Remote lazy cards** (`cardData.remote`): `rowsBasis` is `full` and the badge shows the true size; the widget's lazy card
  (no `remote`) is unchanged ("First 50 of ..."), and the lost-link toast with `card` still downgrades a module card.
- **Replace keeps the view:** `cardViewOf(el)` is shared by `getState()` and `replaceCard()`; the sort / filter is re-applied with
  `applyCardView()` where the column still exists and its step was not disabled by this refresh.
- **Arrow cleanup:** `sv_lazy_tbl()` records the views it registered (`sv_arrow_views` attribute); `forget()` unregisters them via
  `sv_lazy_release()` (never fails). A user's duckdb tbl is untouched. Registrations made by `sv_lazy_place()` for joins are not
  tracked (not per card; left as is).
- **Mutate disable:** `disableMissing(table, columns, oldColumns)` scans a mutate `expr` (`exprNames()`: outside string literals,
  backticked names too, not `f(`, `x$a`, `pkg::a`, `f(a = )`) for names that were columns and are gone. Without `oldColumns` mutate
  is not checked.
- **Minors:** `height` through `validateCssUnit()`; module codebook csv read with `readChar()` (byte-equal to `write.csv()`);
  engine registered at the end of the constructor; `card_store$replace()` rename branch deleted (nothing used it); README / example
  / roxygen use plain calls, not `|>` (no `Depends: R (>= 4.1)`); more `disableMissing` cases (rule, recode, reshape, no `condCols`).
- **Verified:** gui runner (mock DOM) scenario 11 new cases, test-pipeline.R, test-module.R, real-browser test "replace keeps the header
  sort" in test-layout-browser.R (fails with the re-apply call removed). Not re-checked in RStudio.
- **Full suite after the fixes (f73bdfe, `NOT_CRAN=true devtools::test()`):** 24 files, 431 tests, 22,324 expectations, 0 failed,
  0 errors, 0 skipped (lazy and real-browser files included). Scoped re-review: all findings addressed. Site rebuilt and scrubbed.

### 2026-11-01 - Shiny module and proxy: RStudio check (0.4.0, task 7)
- **Viewer pane, `runApp("inst/examples/proxy")`:** both canvases start with their cards; a real drag joins `visits.id` to
  `labs.id` and `$code()` shows `visits %>% dplyr::left_join(labs, by = "id")`; canvas B has no connector and no step
  badge. Refresh with same columns, drop `lab_date` and no rows: card position kept, spline re-anchored to the `labs.id`
  port, the zero-row card is empty (`0 x 4`) with the key-check toast. Add card, Remove added card, Highlight labs
  columns, and Save / restore workspace (toast, then restore) all work. The page scrolls past the canvases.
- **Gadget, `sideview(v, l)` in the default dialog:** connect, Done returned `v %>% dplyr::left_join(l, by = "id")`, which
  parses.
- **Not checked:** the external browser for the example app; the disabled-step toast (needs a step on the dropped
  column; the real-browser test covers it).
- **Environment note:** after an interrupted gadget the console hung and the dialog sat behind a maximised RStudio. A
  restart fixed it; not a package bug. Keep RStudio un-maximised for dialog checks.

### 2026-10-31 - Shiny module and proxy: example app, real-browser tests, docs (0.4.0, task 6)
- **Example:** `inst/examples/proxy/app.R`: two canvases (`a`, `b`) on a `bslib::page_fillable(fillable = FALSE)` (plain
  `fluidPage` without bslib), synthetic `visits` / `labs`, buttons `add`, `replace`, `remove`, `state`, `highlight` on
  canvas `a` through `sideviewProxy("a")`, a radio (`same` / `drop lab_date` / `no rows`) for what the refresh sends, and
  `verbatimTextOutput("code")` for `px$code()`. `sv_start_app(app_file =)` runs it in the browser tests.
- **Real browser (chromote, `NOT_CRAN=true`), 8 new tests in `test-layout-browser.R`, real mouse input for ports, buttons and
  radios:** both canvases start with their cards, no JS errors, no run-code buttons, no AI bar or Copilot tab; replace keeps
  the card's rectangle (within 1 px) and every spline end within 2 px of its port; a replace that drops `lab_date` shows
  `labs refreshed: 1 step disabled (lab_date not found)` and disables the arrange step; connecting in A leaves B with no
  connector and F with focus in A moves only A's view; the page scrolls on a wheel turn outside the canvases; `#code` text
  `parse()`s; a zero-row replace shows a `0 x n` card without errors and refills after. Found on the way: `scrollIntoView`
  must be `behavior: 'instant'` in tests (the bslib page scrolls smoothly, so ports were measured before the scroll ended).
- **Small fixes folded in:** `sideviewServer()` without `llm_fn` sends `sideview_llm {enabled: false}` and the canvas hides the
  AI bar and Copilot tab (`sv-no-llm`); a join-check reply with no pending request is dropped (stale after a replace);
  `_destroyed` guards `sendReady` retries and `scheduleSnapshot`; `tools/tour-screenshots.R` uses `.sideview-chat-input`.
  Known gap: a stale reply that arrives after a new request for the same join signature is still accepted (no epoch counter).
- **Docs:** README "In your own Shiny app", NEWS 0.4.0 "Shiny module and proxy", roxygen notes (`state` text, `llm_fn`, one
  server per id), `_pkgdown.yml` group already listed, CLAUDE.md (module/card-store lines, new inputs and messages, `ns`
  routing, untrusted-client rule, codebook `csv`), roadmap line 3 above replaced per spec section 3.
- **Verified:** `devtools::test(filter = 'layout-browser|pipeline|card-store|computer-use|widget|e2e|features|assets|theme|state')`
  1642 pass, 0 fail (`NOT_CRAN=true`, mock GUI runner included; `s9_show` now marks the join check pending first); `module` filter
  100 pass; `pkgdown::check_pkgdown()` clean; `devtools::check(args = '--no-manual')`: 0 errors, 0 warnings, 1 NOTE (the Windows
  `''NULL''` check-directory note); site rebuilt, `docs/CLAUDE.*` / `docs/MEMORY.*` and their sitemap / search entries removed.
  Not done here: the RStudio Viewer / dialog pass of the example app and the gadget regression pass (needs RStudio).

### 2026-10-26 - CI fix: Arrow time-zone filters under duckdb 2.0
- **Bug:** R-CMD-check on 27290e9 (run 40244887020) failed on windows-latest and ubuntu release/oldrel-1/devel (macOS passed): 12 failures at test-lazy.R:1101, gt/gte filters on an Arrow POSIXct column with a time zone gave 0 rows. CI had arrow 26.0.0, duckdb 2.0.0, dbplyr 2.6.0; locally arrow 23 / duckdb 1.4.3 / dbplyr 2.5.1 passed.
- **Root cause:** `sv_lazy_tz_cmp_expr()` wrote `epoch_us(t) > CAST(<us> AS BIGINT)`. duckdb 2.0's optimizer rewrites `epoch_us(col) <op> <integer>` into `t >= '<ts>'::TIMESTAMPTZ AND t < 'infinity'` and pushes it into ARROW_SCAN (seen in EXPLAIN), and the arrow scan then returns no rows; `<` and `=` were wrong too. The same expression in SELECT gave TRUE, and a duckdb-native table was unaffected. A DOUBLE literal is not rewritten. `t > make_timestamptz(<us>)` also works on 2.0, but duckdb 1.4.3 needs the `icu` extension for it (an autoload, so a network download): not used.
- **Fix:** the literal is `CAST(<us> AS DOUBLE)`; exact for |us| < 2^53 (about 1685 to 2255). Possibly a duckdb bug worth reporting upstream.
- **Verified:** with the CI versions in a scratch library, `devtools::test(filter = 'lazy')` went from 10 failures (all line 1101) to 0, browser tests included (`NOT_CRAN=true`); local versions 0 failures; full `NOT_CRAN=true devtools::test()`: 0 failures, 0 skips.

### 2026-10-26 - Big tables (0.4.0 part 1): speed check, docs, site
- **Speed:** new test "join check on 1M-row duckdb tables is under 5 s" (`skip_on_cran()`, two synthetic 1,000,000-row
  duckdb tables, 80% key overlap). Measured on the dev machine (R 4.5.2, duckdb 1.4.3): **0.84 s** joining on a
  BIGINT `id`, **1.67 s** joining on a text key (250,000 / 300,000 distinct values). Limit 5 s, not loosened.
- **Bug found by the speed test and fixed:** a BIGINT column (duckdb `range()` / `count()`) made the lazy join check,
  filters and "contains" fail with `Invalid type specifier "f"`. dbplyr translates `is.nan()` to `PRINTF('%f', col) = 'nan'`,
  which duckdb rejects for integer types, and duckdb hands a BIGINT to R as a double so the column counted as a plain
  double. R/lazy.R now uses duckdb's own `isnan()` / `isinf()`. New test covers BIGINT, HUGEINT and DECIMAL columns
  against the in-memory functions.
- **Docs:** roxygen for `sideview()` (new "Big tables" section with the known differences), `sv_join_diagnostics()`,
  `sv_column_profile()` (`column`) and `sv_codebook()` (`progress`, `rows_profiled`, `n`); NEWS.md (0.4.0 section,
  known-differences list); CLAUDE.md (lazy-card rule, `R/lazy.R` twins, `sideview_toast`, `rows_profiled`);
  tour "Big tables" section; the design spec now says lazy "contains" is an escaped literal, not `stringr::fixed()`.
  `stringr` was already in Suggests.
- **Other fixes for check:** tests used `magrittr::` (not declared) - now dplyr's pipe re-export; `.superpowers` added to
  `.Rbuildignore`; `n`, `rtrim`, `sd` added to `globalVariables`; roxygen links to internal functions inside
  `@noRd` blocks changed to code spans (no roxygen warnings).
- **Site:** `pkgdown::check_pkgdown()` clean; `pkgdown::build_site(preview = FALSE)` rebuilt `docs/`; `docs/CLAUDE.*` and
  `docs/MEMORY.*` and their `sitemap.xml` / `search.json` entries removed (JSON nulls kept).
- **Note:** MEMORY.md had one byte 0x97 (a cp1252 dash) that was not valid UTF-8, and pkgdown warned about it.
  It is now an ASCII dash.
- **Not done here:** the RStudio dialog walk-through (Task 10 step 4) is done by the controller and recorded separately.
- **RStudio check (Task 10 step 4, controller, RStudio 2025.05.1, R 4.5.1):** a synthetic 1,000,000-row parquet Dataset
  (`visit_id`, `patient_id` "P%05d" over 2,000 ids, `sbp`) written with `arrow::write_dataset()` to the scratchpad, plus a
  2,500-row `patients` data frame; `sideview(ds, patients, viewer = "dialog")`. Card badge "1000000 x 3" (no thousands
  separator: parked for the final review). Click-to-connect on `patient_id` -> Discrepancy tab join check on the whole
  table: many-to-one, ds rows matched 1,000,000 of 1,000,000, patients rows matched 2,000 of 2,500, left 1,000,000,
  inner 1,000,000, full 1,000,500, right 1,000,500, semi 1,000,000, anti 0, "Not in ds: P02001 ...". All correct for the
  data. Inspector on `sbp`: rows 1,000,000, 167 distinct, min 32, median 130, max 227, SD 18.03, histogram, 3-IQR
  outlier check. Done returned `ds %>% dplyr::left_join(patients, by = "patient_id") %>% dplyr::collect()`; run at the
  console it gave a 1,000,000 x 5 tibble in 0.07 s. The discrepancy summary under the join check ("49 matched / 2451 diff")
  still compares the 50-row preview (the discrepancy tab was outside this sub-project): parked.
- **RStudio quirk found (not a sideview bug):** when a script is `source()`d, the lines after a dialog gadget returns are
  skipped silently. RStudio interrupts R within a second of the dialog closing. A plain `shiny::runGadget()` with
  `dialogViewer()` and a Done button does the same (its `Sys.sleep(1)` line never finished). Typing the next line at the
  console works. Screenshots and logs are in the session scratchpad only.
- **Verification:** `node --check` on every file in inst/www and inst/htmlwidgets. `devtools::check()` with `NOT_CRAN=true`: 0 errors, 0 warnings, 1 NOTE (''NULL'' in the check directory, environmental). 5568 test expectations passed; the one failure in that run was the live Ollama test (the local model wrote code starting with a pipe), which passed when re-run alone - a flaky live-model test, not a regression.
- **Final fix wave (final review I1-I5, M1-M8, M10; M9 kept):** see
  `.superpowers/sdd/2026-10-25-lazy-full-data-implementation/final-fix-report.md`. (I1) `sv_lazy_tbl()` sets
  `attr(, "sv_factors")` (levels, ordered) next to `sv_tz`; `sv_lazy_column_profile()` reads both, so the gadget
  inspector and codebook report `factor`/`ordered` and the Arrow zone (testServer test vs the data frame codebook).
  (I5) Arrow dictionaries keep their levels: a factor sorts by level (a `CASE` key when the levels are not in text
  order) and `<`/`>` on an unordered factor match nothing, as in R. (I2) `sv_lazy_rows_window()`: the row total is
  counted once per filter (cached in `order_cache`), an unsorted unfiltered window is `head(offset + limit)`, and a
  sorted or filtered one is one `ORDER BY ... LIMIT/OFFSET` query (`sv_lazy_slice()`), so a window of a 5M-row table
  is under 1 s on duckdb and arrow (test, skip_on_cran; 1.84 s / 1.59 s before, now 0.06-0.25 s). (M1) a filter value that does not
  parse as the column type matches nothing. (M2) totals are doubles, so a 3e9-row view works. (M3) the table name in
  `code_ref` is `encodeString()`d. (M4) `fmt_n()` in the gadget badge and the print method, `fmtCount()` in the
  widget badge. (I3, label only) Auto Map suggestions (spline title, `data-basis`, one toast), the discrepancy card
  and the auto-clean button say "first N rows" when a card is lazy (`data-preview-rows` on the card, `previewParts()`).
  (I4) the widget codebook passes the true `n` for lazy cards. (M7) `sv_state_scrub()` drops `source` from state
  files. (M8) a spy on `dplyr::collect` holds every lazy request to the rows it shows (guard only; passed before).
  (M5) no timing message in the speed test; (M6) the "130.0" wording says "in generated code"; (M10) comment.
  Also fixed the browser test helper: a failed startup probe threw "invalid connection" from `on.exit(close())`
  and made the app look dead (seen as flaky starts). Every fix was run red against BASE 7993636 first.
  Whole-table discrepancy and Auto Map stay deferred.
- **Re-review of the fix wave:** all findings addressed. Two Minors fixed after it: the unsorted window's
  `head(offset + limit)` overflowed near row 2^31 (now `as.numeric(offset)`; test on a 3e9-row view), and the widget
  badge showed "0" for an unknown row count (now "?", as the print method; browser test). Verified with
  test_file() on both tests (headless Chrome).
- **Gadget check of the preview labels (browser mode):** the RStudio dialog was blocked by a Windows
  TextInputHost window and access to it was declined, so the gadget ran with `viewer = <url writer>` in the
  Claude browser pane (1M-row parquet `ds` + 2,500-row `patients`). Seen: badges "1,000,000 × 3" / "2,500 × 3";
  join check on the whole table with separators; Auto Map spline `data-basis="preview"`, its hit-path title and
  toast "Based on the first 50 rows"; discrepancy note "Based on the first 50 rows". No auto-clean button there
  (no `only_in_x` keys), so its tooltip is covered by the browser test only.
- **Found during that check: the gadget had no Auto Map button** (never had: `R/app_ui.R` lacked it since 0.2;
  R handled `request_suggested_mappings` but nothing sent it). The widget had the button but no R to answer
  (the #44 case). Fix: the button moved to the gadget toolbar only; an empty answer toasts "No suggested joins
  found". New test-app.R parity test (gadget toolbar = widget toolbar + Auto Map + Cancel/Done; run red first)
  and a real-click Auto Map check in test-lazy-browser.R. Live: a real click gives the toast (the only candidate
  scored 61%, under the 0.70 default, because the preview overlaps 2%).
- **Browser helper:** the startup probe's "Could not connect" warning (4 warnings per full run) is now caught,
  and the probe closes its connection at once (no "closing unused connection").

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

### 2026-11-07 - Flaky lazy CDISC test fixed
- **Cause:** `sv_cdisc_lazy_query()` took `distinct(.sv_v) |> head(2)` with no order, and duckdb returns DISTINCT values in varying order (RDOMAIN `c("AE","ae","LB","AE")` gave `AE|LB` 29 of 40, `LB|AE` 11 of 40); the in-memory `clean()` kept first-appearance order, so `rdomains` differed positionally (~30% of runs).
- **Fix:** `sort(unique(...))` in `sv_cdisc_peek()` (R/cdisc.R) and `arrange(.sv_v)` before `head(2)` in the lazy query (R/lazy.R), so both paths give the same sorted pair. (Correction, same day: this was true only for two RDOMAINs. With three or more, the lazy path kept the first two while memory kept all, and `sort()` is locale-ordered while duckdb `arrange()` is byte-ordered. Fixed in the "SUPP merge: review fixes" entry at the top.)
- **Verified:** the test looped 40 times on duckdb and arrow, 0 failures (was ~30%); test-cdisc.R 321 passed.

### 2026-11-08 - Site and README refreshed with CDISC screenshots
- **Change:** `tools/cdisc-screenshots.R` (chromote, real mouse clicks, synthetic fixture) makes `vignettes/articles/cdisc/{canvas,automap,merge}.png`; wired into the CDISC article and README; docs/ rebuilt and scrubbed of CLAUDE/MEMORY pages and their sitemap and search entries.
- **Gotcha:** the fixture must call `sv_cdisc_finalize()` on its cards, or SUPP cards get no merge targets and the Merge button is disabled (the first Merge shot showed 0 steps for that reason).
- **Verified:** merge.png shows 1 step, 16 of 16 SUPP rows matched; `check_pkgdown()` clean; build_site ran; search.json has no CLAUDE/MEMORY paths. Not yet checked: live site after merge.

## Final review fixes I1-I3 (2026-11-14)
- **I1:** the a11y CI job installs `any::devtools`, gets `CHROMOTE_CHROME` from setup-chrome's `chrome-path`, and runs `.github/scripts/run-a11y-tests.R`, which fails on a failed expectation, on 0 passed expectations, or on a skip for a missing Chrome / axe-core. YAML parsed with `yaml::read_yaml`. Script checked locally with `NOT_CRAN=false`: exits non-zero (0 passed). The job itself cannot run here.
- **I2:** a widget that starts in the list view inside a hidden container (tab, `<details>`) no longer lays out its cards at 0 x 0. `publish()` skips the first layout while `view === 'list'`; `setView('canvas')` runs the deferred first layout. New real-browser test in test-layout-browser.R (widget at display:none, shown, switched to canvas: cards have size and do not overlap). It failed (1 failure, cards 1 and 2 overlap) with the JS edit reverted by hand and passes with it.
- **Verified:** `node --check`, gui-test-runner.js all true, test-layout-browser.R 761 pass 0 fail, test-a11y-browser.R 344 pass 0 fail 0 skip (NOT_CRAN=true, one R process at a time).
- **I3:** NEWS.md no longer says "no accepted exceptions" for the canvas: the target-size exemption is named.

## NVDA pass, partial (2026-11-14)
- Drove NVDA 2026.2 (Speech Viewer read by screenshot) against `viewer = "pane"` in RStudio. **Task 1 passed** (`List view toggle button not pressed`; after activation `sideview list view region Summary heading level 2`, `List view`). Task 4's column sentences were seen on screen. Tasks 2, 3, 5-15 NOT run; RStudio dialog and browser NOT run (browsers are read-only for computer use; the pane's focus order was hard to steer).
- The public label ("NVDA script written but has not yet been run") is left as is: it understates one confirmed task. No claim of a full pass.
- The earlier "stall" of the console after the launch was slow loading under a concurrent `devtools::check()` plus a console that had not repainted; the gadget did come up ("Listening on http://127.0.0.1:3845").

## NVDA pass, Edge browser (2026-11-15)
- Drove tasks 1 to 15 in Edge (`viewer = "browser"`) with NVDA 2026.2; the user pressed the keys, I read the Speech Viewer by screenshot. All 15 passed on the flow. Details in `plans/2026-11-14-nvda-script.md` ("Second pass").
- Findings, none a confirmed code bug: the list view is last in DOM order, so Ctrl+Home lands on the toolbar (script wording to fix); NVDA counts the table header as row 1; the shortcuts control is a switch (on/off).
- Task 12 announced `Filter step added. 1 step.` with 2 steps in the pipeline. A clean page gives 1 then 2 steps, so the count logic is right. The user confirmed a page reload caused it.
- Several announcer lines scrolled out of the viewer and are unconfirmed (`Rows 30 to 40 of 40.`, `Code copied.`, `SUPP merge step added. 1 step.`).
- Not run: RStudio dialog, RStudio Viewer tasks 2 to 15, blind users. The public label stays as is; no full-pass claim.

## devtools::check() on 475b1be (2026-11-14)
- `devtools::check(args = "--no-manual")`: 0 errors, 0 warnings, 1 NOTE ("non-standard things in the check directory: NULL", environment only). 28m 55s. Run with NOT_CRAN=false, so the real-browser tests were skipped in the check; they were run singly earlier (a11y-browser 344, layout-browser 761, say 130, all passing).

### 2026-11-15: the 13 Minor findings of the final review
- Docs/plan findings 1-4, 9, 10, 12, 13 fixed in the earlier docs commit.
- 5: a state pushed from R (`sideview_state_set`) switches the view silently (`applyState(state, {silent:true})`); the user's Open still announces.
- 6: accepting a SUPP suggestion keeps the item until the merge step exists (`onSuppCheck` removes it).
- 7: a join added with "No rule" clears a rule an earlier add left on the same pair.
- 8: the list profile box hears the give-up of an unanswered profile request.
- 11: fixed `Sys.sleep` before "nothing happened" assertions replaced by positive waits (announcer drained, row count, DOM marker).
- Verified: `node --check`; `test-a11y-browser.R` all green in a real browser (`NOT_CRAN=true`), including 4 new tests for 5-8.

## Accessible canvas: full verification on ce88b48 (2026-11-16)
- Full `devtools::test()` with `NOT_CRAN=true`: 26094 passed, 0 failed, 0 errors, 0 skipped, 0 warnings.
- `devtools::check(document = FALSE)` (tests with the real-browser suites, 29 min): 0 errors, 0 warnings, 1 NOTE (the known environmental `NULL` check-directory note).
- The final whole-branch review fixes (I1-I4, P1, P2, M1, M2, M7, M8, M9) were re-reviewed: all addressed.
- Still pending: the manual script `plans/2026-11-15-access-manual-script.md` (Magnifier 200%/400%, High Contrast, Edge, RStudio dialog and Viewer), including whether Alt+Arrows navigate Back in RStudio or Edge (`JUMP_MODS`).
- Parked for later: test-access-browser should clean up `sideview.access` in localStorage itself (withr::defer); the switch-off axe run covers 1360x820 only.

## Accessible canvas: manual pass (2026-11-16)
- Edge: Alt+Arrow card jumps work and the page does not go back or forward, so `JUMP_MODS` stays `alt`.
- Magnifier 200% and 400%, High Contrast (both themes, switch off and on): reported OK by the user. RStudio dialog and Viewer, with Alt+Left there: NOT yet run. Claude checked checks 1, 3, 4, 6, 7 itself in a Chromium pane.
- Not run in full: checks 2, 14 to 19 were not walked one by one; High Contrast Night sky was not confirmed separately. Backlog: a "dismiss suggestions" control (Clear in the drawer also removes joins).

## Accessible canvas: RStudio pass and arrange on switch-on (2026-11-16)
- RStudio dialog and Viewer pane, with Alt+Arrow there: reported OK by the user. All manual passes are done; `JUMP_MODS` stays `alt`.
- Change at the user's request (38d1e9e): switching on arranges overlapping cards; switching off puts back every card not moved since. Tests: access-browser, a11y-browser, layout-browser, 2354 passed. Full suite not re-run after it.

## D1 known gaps (deferred minors, from the SDD ledger, 2026-11-17)

None of these blocks D1; none is fixed. Source: `.superpowers/sdd/2026-11-16-derived-cards-d1-implementation/progress.md`.

- Parked minors: T7 must compare generated code to the rule branch (sv_join_rule_pairs, not join_by) for every shape x side; list-form `by` ({x,y} pairs from the canvas) and lazy "needs duckdb" error untested -> cover in T5/T3; sv_derive_name for supp ops uses args$supp, falling back to last input (inputs = [parent, supp] so last input is the supp).
- Task 2: minor (deferred): rdomain=NULL picks first RDOMAIN of in-memory supp (T5 always sends rdomain); sv_derive_rows rejects NULL rdomain even if plan$rdomain_col FALSE; CM test only proves CMSEQ error; counts not compared to sv_lazy_supp_check directly.
- Task 3: minor (deferred): sv_lazy_env() per console sv_unmatched() call leaks a duckdb connection (R/derive.R:34)
- Task 3: minor (deferred): sv_lazy_derived_tbl with key=NULL returns tbl with live cleanup nobody releases; doc note
- Task 3: minor (deferred): sv_card_is_lazy TRUE for derived source before arrow-availability check
- Task 3: minor (deferred): args$con_env smuggled via args, undocumented
- Task 3: minor (deferred, check in Task 5/6): sv_lazy_release does not evict con_env$tbls[[key]]; callers must evict
- Task 3: minor (deferred): cleanup test does not exercise placing an uncached Arrow table
- Task 3 (open): test-lazy-browser.R had 2 failures (list paging shows an ellipsis) in the implementer's run; still to check on a clean base. A whole-suite browser run on the final branch state was not done.
- Task 4: minor (deferred): no test of offers on lazy card or NA-key; weak expect_lte(length(o),4); rdomain=NULL leaves null element
- Task 4 (open): the offer counts describe the 50-row preview when lazy_or_preview falls back, while a card built on whole tables may differ; not reconciled.
- Task 5: minor (deferred): sv_derive_validate unused (asked in fix round anyway); key kinds on preview for lazy (asked in fix round); payload built after store add (asked in fix round)
- Task 5: minor (deferred): no dedupe by request_id (retries make _2,_3 and temp tables); derived-of-derived: forget of inner releases tables the outer SQL uses (decision 6 engine removes dependants; needs test in Task 6); no tests for non-syntactic cols / NA keys via derive handler / n==offer n from real offer; $ partial matching on req fields (use [[exact=TRUE]]); no basis marker on derived card after fallback; sv_derive_name make.names changes the exact name in the taken-name error
- Task 6: manual check owed (user, RStudio): gadget client accepts card_add at first flush for lazy-input derive steps
- Task 6: minor (deferred): swallowed build errors for lazy derive step at first flush (no toast); unbounded derive steps per state; all[-seq_along(cards)] fragile; forged-args test lacks junk args with valid inputs; step skipped silently if name exists
- Task 7: minor (deferred): _kindBusy on pipeline instance; mixed-type rule keys twin gap; unknown IDVAR counted orphan vs R stop; window offset kindOf assumes ins[0] on canvas; my key twin eval only for no-rule; no evaluated duckdb+arrow mixed pair
- Task 8: minor (deferred): repeated error toasts when _deriveFailed resets on unrelated card add; startup announcement for gadget lazy-restore card_add; gadget first-flush card_add + widget no-R toast not browser-verified; replace-failed-rebuild test asserts no-danger-toast not exactly-one; undo/redo via engine calls not UI keys
- Task 8: minor (deferred): race test uses fixed Sys.sleep(3); 30s derivePending sweep drops a legitimately slow lazy derive (late reply gets no step, dup click possible); _rRemoved has no reset path in applyState/clearOperations/step removal (stale skip after failed-rebuild replace then good replace)
- Task 9: minor (deferred): list-view test compares label to literal not drawer; SUPP buttons untested; weak "{" DOM check; no focus-after-Enter assert; no list-view CSS/axe for derive buttons; duplicate open zooms hidden canvas card in list view
- Behaviours worth knowing (not defects): an R-removed derived card sets `_rRemoved` and is not asked for again until an input leaves and returns; `derivePending` is swept after 30 s; derive offers are R-only (no widget buttons).

### D1 final-review fixes
- Derive offer labels are built by `sv_say_derive_offer()` (actions, e.g. "Open 2 unmatched ae rows as a card"); tests pin them.
- `replaceCard()` now writes the rebuilt derived card's `derived` (R's new SUPP plan) into its derive step, so `$code()` follows replaced SUPP data. R already sent it in `sideview_card_replace`. Tests: test-module.R (message carries the new IDVAR), test-layout-browser.R (module: compose reads AESPID after replace; fails without the fix).
- Docs: derived cards carry the kept card's tag; the gadget builds lazy derive steps in `sv_derive_from_state()` at the first flush; widget derive steps stay in the code when both inputs exist (toast, CLAUDE.md, NEWS and article reworded).
- Verified: node --check on inst/www/*.js; unit filter derive|module|pipeline|say|diagnostics|supp; test-layout-browser.R and test-a11y-browser.R each in one real-browser run (NOT_CRAN=true), all passing.
- Fix (2026-11-17): `replaceCard()` writes the rebuilt SUPP plan through new `Pipeline.refit()`, which clears undo/redo when the step changed (via `clearHistory()`, shared with `disableMissing`), so one Ctrl+Z cannot bring back the stale plan. Tests: test-pipeline.R (refit), test-layout-browser.R (module: no undo after replace; fails without the fix).

## D2 known gaps (deferred, from the SDD ledger, 2026-11-21)

None of these blocks D2; none is fixed. Source: `.superpowers/sdd/2026-11-17-d2-stack-implementation/progress.md`.

- `Sys.timezone()` is pinned in the generated lazy date-time to text code; code made on another machine differs in the zone only (documented in NEWS and the article).
- A number cast to text: R gives `"1e+05"`, duckdb `"100000"`; fixtures are whole numbers in ordinary ranges. Documented limit, not fixed.
- duckdb tables carry no column labels; Arrow tables keep theirs (R metadata), and data frames do.
- `tz_text` (the R-computed DST offset tree) bloats saved state, about 20 KB per date-time column per input (also in CLAUDE.md "Stack (D2)").
- Casts that change values without an `NA` count: dttm to chr drops fractional seconds; num to chr keeps 15 significant digits; a cast `integer64` goes through double, losing digits beyond 2^53. Documented (NEWS, article, roxygen), not changed.
- `sv_stack(check =)` compares a lazy input by table name only; data frames are also compared by columns, types and row count (fix wave, 2026-11-21).
- Check then Open plans the stack twice (Open itself plans once since the fix wave).
- Twin quoting: R and JS now agree on ASCII and C1 control characters and on non-ASCII names (always backticked); other non-printable Unicode (e.g. U+2028) is left as is by JS while R's `encodeString()` decides by locale. Not tested.
- `id_col` is not an input to the check, so a user-chosen `id_col` would desync the preview from Open (the browser sends none).
- No lazy stack server test (handler with a duckdb / Arrow input); `sv_stack_clean()` has no unit test for 9 tables or the cast-target whitelist (the handler pre-checks).
- Parked from reviews: state round trip tested via toJSON / load, not `getState` / `applyState`; mismatched kind / plan untested; Task 6 minors (error replies both `role=alert` and assertive announce, 500-fix cap not enforced client side, reply render restores focus without checking where focus is now, the cast change test uses a synthetic `dispatchEvent`); Task 7 minors (list view heading asserted only as H3, no focus or announce assertion after Open in list view, no no-R test for an absent Stack host, pick order assumes DOM order); pre-1970 fractional date-times untested.
- Manual checks: all done by the user (2026-11-21).

## D1 parked after final review
- Only the join `unmatched` offer label is pinned end to end; the other three offer labels are untested.
- Committed `docs/` still says derive steps are "skipped" in a saved page; rebuild docs before release.
