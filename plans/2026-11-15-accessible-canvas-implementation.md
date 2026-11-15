# Accessible canvas (keyboard and low vision) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One opt-in switch ("Accessible canvas") that makes the sideview canvas usable by keyboard alone and at low
vision, with the default canvas unchanged when it is off.

**Architecture:** The switch is a container class `sv-access` set by the engine from a stored browser choice or the R
`access` argument (same precedence as the shortcuts switch). Low vision is CSS under `.sideview-container.sv-access`
plus a zoom floor of 1.0 in the engine. The keyboard model lives in a new file, `inst/www/sv-access.js`
(`SideviewAccess`, one per engine, like `ListView`), so `sideview.js` only gains the switch, the floor and hooks.
The operating-system blocks (`forced-colors`, `prefers-contrast: more`) are always-on CSS.

**Tech Stack:** R 4.5.2, Shiny, htmlwidgets, plain ES5-style JS (no build step), testthat + chromote, axe-core.

**Spec:** `plans/2026-11-15-accessible-canvas-design.md` (read it with this plan; the spec wins on any conflict).

**Branch:** implement on `a11y/b-canvas`, cut from `a11y/b-spec`, in `C:\src\sv-a11y`.

## Global Constraints

- With the switch off, the canvas is unchanged: look, density, zoom range (`minScale` 0.15, `maxScale` 3.5), Tab
  order, keys. Only section 7 of the spec (OS signals) may change it, and only when the OS asks.
- Keys never fire while typing (`isTypingTarget`) or when the canvas does not own the keyboard (`ownsKeyboard()`).
- Focus-scoped access keys work whether the shortcuts switch is on or off. Global shortcuts keep their rule.
- Every rule is scoped under `.sideview-container`; CSS uses `--sv-*` tokens, no hard-coded colours; every token
  used is defined; `.sv-theme-dark` and the `@media (prefers-color-scheme: dark) .sv-theme-auto` blocks stay equal.
- Contrast with the switch on: text >= 7:1; splines, borders, ports, focus ring >= 4.5:1, light and dark.
- Sizes with the switch on: every text in the container >= 16 CSS px; every control >= 24 x 24 CSS px on screen.
- Zoom floor with the switch on: scale >= 1.0 from every path (wheel, `-`, `0`, toolbar, `fitAll`, `zoomToCard`,
  restored state).
- Not in workspace state; no new Shiny inputs or messages; module mode unchanged apart from the class.
- localStorage key `sideview.access`, values `on` / `off`, every access in try/catch (memory fallback).
- Announcements (exact copy): `Accessible canvas on.`, `Accessible canvas off.`, `<Card> moved.`,
  `Connecting from <Card>.<col>. Choose a column.`, `Connecting cancelled.`, `Removed <n> join(s) on <Card>.<col>.`
- Escape all table-derived text (`escapeHtml` / `textContent`); `CSS.escape` in selectors; every global listener
  removed in `destroy()`; inline SVG icons only.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push or merge unasked.
- Edit files with CRLF/LF preserved (Python `newline=''` or the Edit tool); never commit `tests/testthat/_problems/`
  or `testthat-problems.rds`.

## Review Focus

1. **Switch turned off while a card or column has focus, or mid-connect:** connect mode is cancelled, the card's
   `tabindex` is removed, focus moves to the container (never to `body`). Test in Task 6.
2. **A card removed (module `sv_remove_card`) while it is focused or is the connect source:** focus moves to the
   next card in Tab order (else the container) and connect mode is cancelled. Test in Task 7.
3. **Leaving the canvas mid-connect (view switch to the list, `?` dialog, Ctrl+K):** connect mode is cancelled and no
   `sv-kb-connect-source` class is left behind. Test in Task 7.
4. **Hostile card and column names** (`<img src=x onerror=...>`) in announcements, the Delete menu and the `?` list:
   literal text. Test in Task 7.
5. **Maximized or minimized cards:** Arrows do not move a maximized card; a minimized card still moves and its
   splines stay on the header ports. Test in Task 6.

---

### Task 1: The `access` argument in R

**Files:**
- Modify: `R/sideview.R` (`sideview()` signature near line 175, roxygen options list near line 136)
- Modify: `R/app_ui.R` (`sideview_ui()` near line 397; container attributes near line 624)
- Modify: `R/module.R` (`sideviewUI()` near line 60)
- Modify: `R/widget.R` (`options$access` default near line 147; `@param options` near line 47)
- Test: `tests/testthat/test-access.R` (new)

**Interfaces:**
- Produces: container attribute `data-sv-access="true"` (absent when FALSE); widget `options.access` (logical).
- Produces: `sv_check_access(x)` (internal) returns `TRUE`/`FALSE` or errors.

- [ ] **Step 1: Write the failing tests** in `tests/testthat/test-access.R`:

```r
test_that("access defaults to the option and renders data-sv-access", {
  withr::local_options(sideview.access = NULL)
  expect_false(grepl("data-sv-access", as.character(sideview_ui(list(a = mtcars)))))
  expect_match(as.character(sideview_ui(list(a = mtcars), access = TRUE)), 'data-sv-access="true"', fixed = TRUE)
  withr::local_options(sideview.access = TRUE)
  expect_match(as.character(sideview_ui(list(a = mtcars))), 'data-sv-access="true"', fixed = TRUE)
  expect_match(as.character(sideviewUI("m")), 'data-sv-access="true"', fixed = TRUE)
})

test_that("the widget carries options$access from the option", {
  withr::local_options(sideview.access = TRUE)
  expect_true(sideview_widget(mtcars)$x$options$access)
  expect_false(sideview_widget(mtcars, options = list(access = FALSE))$x$options$access)
})

test_that("access must be TRUE or FALSE", {
  for (bad in list(NA, "yes", c(TRUE, FALSE), 1)) {
    expect_error(sideview_ui(list(a = mtcars), access = bad), "`access` must be TRUE or FALSE.", fixed = TRUE)
  }
})
```

(Match the real first argument of `sideview_ui()` / where the widget keeps `options`; adjust the call shape only.)

- [ ] **Step 2: Run** `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" -e "devtools::test(filter='^access$')"`.
  Expected: FAIL (unused argument `access`).
- [ ] **Step 3: Implement** `access = getOption("sideview.access", FALSE)` on `sideview()` (passed through to
  `sideview_ui()`), `sideview_ui()` and `sideviewUI()`; `if (is.null(options$access)) options$access <-
  getOption("sideview.access", FALSE)` in the widget, validated by `sv_check_access()`. Document
  `sideview.access` in the options list of `?sideview` beside `sideview.shortcuts`: "`TRUE` starts with the
  Accessible canvas switch on (default `FALSE`). It is the default only: the switch in the `?` list is remembered
  in the browser and wins." Run `devtools::document()`.
- [ ] **Step 4: Run** the filter again. Expected: PASS.
- [ ] **Step 5: Commit** `feat(access): access argument and sideview.access option`.

### Task 2: The switch in the engine

**Files:**
- Modify: `inst/www/sideview.js` (beside `shortcutsOn()` / `setShortcuts()` near line 1810; `toggleShortcuts()`
  near line 1831; engine init and `destroy()`)
- Modify: `tests/testthat/helper-a11y.R` (`sv_a11y_pages()` open functions take `access = FALSE`)
- Test: `tests/testthat/test-access-browser.R` (new; `skip_if_no_browser()` in every test)

**Interfaces:**
- Produces: `engine.accessOn() -> boolean`; `engine.setAccess(on) -> boolean`; container class `sv-access`;
  `engine.onAccessChange(fn)` (internal subscriber list, called with the new boolean after the class changes;
  Tasks 3, 4, 6 subscribe).
- Produces: in the `?` dialog a second switch `button.sideview-shortcuts-switch[role=switch][data-sv-access-switch]`
  with label `Accessible canvas`.
- Produces (tests): `sv_a11y_pages()[[mode]]$open(theme, width, height, access = FALSE)`; `access = TRUE` adds
  `access = TRUE` to the gadget/module expression and `options = list(access = TRUE)` to the widget.

- [ ] **Step 1: Write the failing tests** in `test-access-browser.R`, one per line below, each in gadget mode unless
  named:
  - `"access is off by default and the default canvas is unchanged"`: no `sv-access` class; `accessOn()` false;
    `panzoom` zoom to 0.2 gives scale 0.2 (floor 0.15 kept); no `.sideview-card[tabindex]`.
  - `"R access = TRUE turns it on; a stored off wins"`: open with `access = TRUE` -> class present; then
    `localStorage.setItem('sideview.access','off')`, reload, wait ready -> class absent.
  - `"a stored on wins over R FALSE"` (widget mode).
  - `"the ? switch toggles, announces and keeps focus"`: open `?` (`toggleShortcuts(true)`), real click on
    `[data-sv-access-switch]`; expect `aria-checked="true"`, class present, last `announceLog` entry
    `Accessible canvas on.`, `document.activeElement` is the switch; click again -> `Accessible canvas off.`.
  - `"the switch works when localStorage throws"`: stub `Storage.prototype.getItem/setItem` to throw (as the
    shortcuts test at test-a11y-browser.R:400), `setAccess(true)` -> class present, `accessOn()` true.
- [ ] **Step 2: Run** `$env:NOT_CRAN='true'; & "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" -e "devtools::test(filter='access-browser')"`.
  Expected: FAIL.
- [ ] **Step 3: Implement** `accessOn()` with the order: stored `on`/`off`, then `this._accessMem`, then
  `data-sv-access === 'true' || this.options.access === true`, else `false` (no view fallback). `setAccess(on)`
  writes memory and storage, toggles the class, updates every `[data-sv-access-switch]`'s `aria-checked`,
  announces, calls subscribers. Apply the class once at init from `accessOn()`. Add the switch to the dialog
  under the shortcuts switch, same markup pattern.
- [ ] **Step 4: Run** the filter. Expected: PASS. Also run `devtools::test(filter='a11y-browser')` (shortcuts
  tests unchanged).
- [ ] **Step 5: Commit** `feat(access): Accessible canvas switch, precedence and ? dialog control`.

### Task 3: Zoom floor

**Files:**
- Modify: `inst/www/sv-panzoom.js` (returned API near line 225)
- Modify: `inst/www/sideview.js` (`fitAll()` line 1299, `zoomToCard()` line 1331, first-fit calls at lines 1190 and
  7233, state restore at line 6174)
- Test: `tests/testthat/test-access-browser.R`

**Interfaces:**
- Consumes: `onAccessChange(fn)`, `accessOn()` (Task 2).
- Produces: `panzoom.setMinScale(n)` (also clamps the current scale up if below `n`, keeping the point given by the
  optional second argument `{clientX, clientY}`); `engine.minScaleNow() -> number` (1 with access on, else
  `options.minScale`); `ACCESS_MIN_SCALE = 1`; `engine.focusedCard() -> Element|null` (the card holding
  `document.activeElement`, else null).

- [ ] **Step 1: Write the failing test** `"the zoom floor holds on every path"` (access on): after each of wheel
  zoom-out (real `b$Input$dispatchMouseEvent` wheel, 10 ticks), key `-` x10, key `0`, toolbar zoom-out x10,
  `fitAll()`, `zoomToCard(card)` on the largest card, and `applyState()` of a state whose `view.zoom` is 0.5,
  `panzoom.getScale() >= 1` (tolerance 1e-9). Also `"switching on below 1.0 zooms to 1 around the focused card;
  switching off keeps the zoom"`: zoom 0.5, focus card `visits`, `setAccess(true)` -> scale 1 and the visits card's
  centre is within 2 px of where it was on screen; `setAccess(false)` -> scale still 1, `minScaleNow()` 0.15.
- [ ] **Step 2: Run** the filter. Expected: FAIL.
- [ ] **Step 3: Implement** `setMinScale` in the panzoom closure (mutates `opts.minScale`); route every clamp in
  `fitAll`, `zoomToCard`, the first fit (`READABLE_SCALE` becomes `Math.max(READABLE_SCALE, this.minScaleNow())`)
  and state restore through `minScaleNow()`. With access on, `fitAll()` centres on `focusedCard()` if there is one,
  else keeps today's top-left pan. Subscribe: on → `setMinScale(1, centre of focusedCard() or the view)`;
  off → `setMinScale(options.minScale)` with no zoom change.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(access): zoom floor of 1.0 with the switch on`.

### Task 4: Low-vision styling (whole container)

**Files:**
- Modify: `inst/www/sideview.css` (new blocks after the theme blocks near line 194; rules at the end of the file)
- Modify: `inst/www/sideview.js` (`VirtualTable` near line 39: `setRowHeight`; card resize path: user-sized flag)
- Test: `tests/testthat/test-theme.R`, `tests/testthat/test-layout-browser.R`

**Interfaces:**
- Consumes: class `sv-access`, `onAccessChange` (Task 2).
- Produces: CSS blocks with these exact selector lines (each on its own line, so `sv_css_block()` finds them):
  `.sideview-container.sv-access {`, `.sideview-container.sv-access.sv-theme-dark {`, and inside
  `@media (prefers-color-scheme: dark)`: `.sideview-container.sv-access.sv-theme-auto {`.
- Produces: `VirtualTable.prototype.setRowHeight(px)` (re-renders); row height 28 off, 36 on.
- Produces: `data-sv-user-sized="true"` on a card the user resized.

- [ ] **Step 1: Write the failing R tests** in `test-theme.R`:
  - `"access tokens override existing tokens only, and auto mirrors dark"`: as the test at line 68, for the three
    access selectors; `setdiff(names(access), names(light))` empty.
  - `"access text meets 7:1 and non-text 4.5:1, light and dark"`: reuse the `pairs` list at line 95 with
    threshold 7, plus non-text pairs at 4.5: `--sv-connector-color`, `--sv-connector-hover`, `--sv-port`,
    `--sv-border`, `--sv-focus-ring` each on `--sv-surface` and `--sv-canvas-bg`. Theme maps: light = light <-
    access; dark = light <- dark <- access <- access-dark.
- [ ] **Step 2: Write the failing browser tests** in `test-layout-browser.R` (access on, at 1360x820, 1024x700 and
  375x812): `"access: every text is >= 16px and every control >= 24px"` with the drawer open on each tab in turn,
  the AI bar focused, a filter popover open, the `?` dialog and the search dialog (every element with a non-empty
  own text node: computed `font-size >= 16`; every `button, [role=switch], input, select, a[href], .sideview-col-port`
  visible rect >= 24 x 24); `"access: chrome does not overlap"` (the existing check at line 151 with access on);
  `"access: splines stay on their ports after the switch flips"` (the check at line 319 after `setAccess(true)`
  and after `setAccess(false)`); `"access: a user-sized card keeps its size; switching off restores the layout"`
  (resize one card by real drag on its corner; flip on: that card's rect unchanged, another card grew; flip off:
  every card's left/top/width/height equal the values before); `"access: the contrast tokens beat theme ="`
  (gadget with `theme = sv_theme(primary = "#ffcc00")`, access on: computed `--sv-primary-text`,
  `--sv-connector-color` and `--sv-focus-ring` on the container equal the access block's values, and the mode
  class is still `sv-theme-<mode>`); `"access: colour-only badges carry text or a shape"` (a CDISC tag, a
  key-check state and a discrepancy mark each have non-empty text or a non-`none` `::before` content).
- [ ] **Step 3: Run** `devtools::test(filter='theme')` and the layout filter with `NOT_CRAN=true`. Expected: FAIL.
- [ ] **Step 4: Implement** the access token blocks (values are the builder's, within the ratios). The gadget writes
  `theme =` overrides as inline `--sv-*` on the container, which beat class rules, so every declaration in the three
  access token blocks is `!important` (the spec: the contrast theme overrides `theme =` colours). Text, target and
  focus-ring rules under `.sideview-container.sv-access` for cards, chrome, drawer (all tabs, code), AI bar,
  Copilot, popovers, dialogs, toasts; focus ring `3px solid var(--sv-focus-ring)` with `outline-offset: 2px`;
  at `sv-narrow` the drawer stays a bottom sheet and scrolls. Auto-frozen cards (`sv-sized` without
  `data-sv-user-sized`) get `width: auto !important; height: auto !important` under `.sv-access`; set
  `data-sv-user-sized` from the card resize path (pointerdown on the card's bottom-right 16 px resize corner,
  then a size change). Subscribe to `onAccessChange` to call `setRowHeight(36|28)` on every table and
  `scheduleConnectorUpdate()`. Badges that differ only by colour (CDISC tags, key-check states, discrepancy
  marks) gain a text label or shape under `.sv-access`.
- [ ] **Step 5: Run** both filters. Expected: PASS. Run `test-theme.R` whole (existing equality and AA checks).
- [ ] **Step 6: Commit** `feat(access): high-contrast tokens, 16px text and 24px targets across the container`.

### Task 5: Spline patterns and markers; OS signals

**Files:**
- Modify: `inst/www/sideview.js` (`addConnections` line 3757 and the path creation at 3764/3799; suggested paths at
  3548/3724; connector SVG creation)
- Modify: `inst/www/sideview.css` (connector rules near line 963; new `@media (forced-colors: active)` and
  `@media (prefers-contrast: more)` blocks)
- Test: `tests/testthat/test-access-browser.R`

**Interfaces:**
- Produces: every accepted connector path carries `data-sv-pat="<0..5>"` (join order mod 6, always set; only styled
  under `.sv-access` and forced-colors); SVG `<marker>` defs with ids `sv-mk-<engineSeq>-solid` and
  `sv-mk-<engineSeq>-hollow`, applied as `marker-end` under `.sv-access` / forced-colors (hollow on suggested).
- Pattern cycle (exact): `0: none`, `1: 12 4`, `2: 12 4 2 4`, `3: 2 4`, `4: 12 4 2 4 2 4`, `5: 20 4 6 4`. Never
  `6,6` or `4 4`. Width 3 px; hover/active: width 5 px and the marker, pattern unchanged (no `6 4` active dash
  under `.sv-access`).

- [ ] **Step 1: Write the failing tests:** `"access: six joins get six distinct dash patterns and an end marker"`
  (add 6 joins with `addConnections`, read computed `stroke-dasharray`, `stroke-width` and `marker-end`: 6
  distinct dasharrays, none equal to `6px, 6px` or `4px, 4px`, width `3px`, marker set; with access off the
  computed dasharray of the six is today's value); `"forced colours and more contrast keep splines, ports and the
  focus ring visible"` with `b$Emulation$setEmulatedMedia(features = list(list(name = "forced-colors", value =
  "active")))` and separately `prefers-contrast: more`, access on and off: the computed stroke of a connector,
  the border of a port and the outline of a focused button each differ from the canvas background; under
  forced-colors the six patterns are distinct; with no emulation and access off the computed values equal a
  baseline read before emulation (default unchanged).
- [ ] **Step 2: Run** the filter. Expected: FAIL.
- [ ] **Step 3: Implement** the attribute, the marker defs (one per engine, removed in `destroy()`), the CSS for
  `[data-sv-pat]` under `.sv-access` and forced-colors, and both media blocks (system colours `CanvasText`,
  `Highlight`, `ButtonText` under forced-colors; the access tokens for borders, ports and focus ring under
  `prefers-contrast: more`, no layout or zoom change). All scoped under `.sideview-container`.
- [ ] **Step 4: Run** the filter, then `devtools::test(filter='theme')` (token rules). Expected: PASS.
- [ ] **Step 5: Commit** `feat(access): spline dash patterns and markers; forced-colors and more-contrast support`.

### Task 6: Keyboard on cards

**Files:**
- Create: `inst/www/sv-access.js` (`SideviewAccess`, exported as `global.SideviewAccess`)
- Modify: `R/app_ui.R` (`sv_asset_version()` files at line 31 and the script list at line 55: `sv-access.js`
  before `sideview.js`), `inst/htmlwidgets/sideview.yaml` (same script), `inst/www/sideview.js` (create
  `this.access = new SideviewAccess(this)` when defined, `destroy()` calls `this.access.destroy()`)
- Test: `tests/testthat/test-access-browser.R`

**Interfaces:**
- Consumes: `accessOn()`, `onAccessChange`, `minScaleNow()`, `focusedCard()`, `send()`, `scheduleSnapshot()`,
  `scheduleConnectorUpdate()`, `announce()`, `chromeTop()`, `chromeBottom()`, `ownsKeyboard()`, `isTypingTarget`
  (export it on the engine as `engine.isTypingTarget(el)` if not reachable).
- Produces: `SideviewAccess(engine)` with `enable()`, `disable()`, `destroy()`, `ensureVisible(el)`,
  `cardSentence(cardEl) -> string` (`<name>, <rows> rows, <cols> columns.`), `cancelConnect(silent)` (Task 7 fills
  it in), constant `JUMP_MODS = 'alt'` (one place to change to `'ctrl+alt'`).
- One keydown listener on the container (runs before the engine's document listeners; handled keys call
  `preventDefault()`, which the global shortcut handler already respects).

- [ ] **Step 1: Write the failing tests** (access on, gadget, real keys via `sv_key()`; add `PageUp`/`PageDown`
  codes 33/34 and `Delete` 46 to `sv_key()`'s `vk` table):
  - `"cards are Tab stops in reading order only with the switch on"`: from the container, `sv_tab()` until focus
    leaves the cards; the focused cards' names follow top-to-bottom then left-to-right by `style.top`/`left`;
    with access off no card ever takes focus (Tab order equals a baseline read with access off before).
  - `"inside a card Tab reaches its actions, then leaves to the next card"`: from a focused card, collect Tab stops
    until focus leaves the card: every stop is inside the card, the three action buttons are among them, at most one
    `th` is among them (none in this task, the roving one from Task 7), and the next stop is the next card.
  - `"Arrows move 20px, Shift+Arrows 100px; one card_moved and one announcement per pause"`: 3 x ArrowRight then
    1 x Shift+ArrowDown -> `left` +60, `top` +100; after the pause, `announceLog` ends with `patients moved.` once;
    a test spy on `engine.send` saw exactly one `sideview_card_moved` with the new x/y.
  - `"Alt+Arrows focus the nearest card and the browser does not go Back"`: `history.pushState({}, '', '#x')`
    first; Alt+ArrowRight from `patients` focuses the card to its right, announces its `cardSentence()`;
    Alt+ArrowLeft returns; `location.hash` still `#x`.
  - `"PageDown/End scroll the card body"`: body `scrollTop` grows, End reaches `scrollHeight - clientHeight`.
  - `"focus follows: a focused card is fully visible, outside drawer, AI bar and minimap"`: pan so `labs` is off
    screen, Alt+Arrow to it; its rect (24 px margin) is inside the container minus the top chrome, AI bar,
    open drawer and minimap rects; scale still >= 1.
  - `"keys are silent while typing and outside an embedded widget"` (widget page with an `<input>` outside the
    container: Arrow keys there change no card position).
  - `"with shortcuts off, card keys still work"`: `setShortcuts(false)`, ArrowRight still moves.
  - Review Focus 1: `"switching off mid-connect or on a focused card"`: focus a card, `setAccess(false)` -> no
    `tabindex` on cards, `document.activeElement` is the container. (Connect half added in Task 7.)
  - Review Focus 5: `"a maximized card does not move; a minimized one does and keeps its splines on ports"`.
- [ ] **Step 2: Run** the filter. Expected: FAIL.
- [ ] **Step 3: Implement** `SideviewAccess`: `enable()` gives cards `tabindex="0"`, `role="group"` and
  `aria-label` = card name; card action buttons get `tabindex="-1"` except while focus is inside that card
  (focusin/focusout); column-header buttons stay `tabindex="-1"` while the switch is on (Task 7 opens the focused
  `th`'s own buttons); `disable()` restores every original `tabindex` exactly (none were set before); moves change `style.left/top` and the card meta, call
  `scheduleConnectorUpdate()`, and after a 500 ms pause send one `sideview_card_moved` `{card_id, x, y}`, call
  `scheduleSnapshot()` and announce `<name> moved.`; maximized cards ignore moves. Nearest card: centre distance
  within a 90-degree cone in the key's direction, ties by distance on the cross axis. `ensureVisible(el)` pans
  (never zooms) with no animation. `disable()` reverses every attribute it set and moves focus to the container
  if it was on a card. Focus with `focus({preventScroll: true})` then `ensureVisible`.
- [ ] **Step 4: Run** the filter and `devtools::test(filter='a11y-browser')`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(access): keyboard moves, card jumps and focus following`.

### Task 7: Keyboard on column headers and joins

**Files:**
- Modify: `inst/www/sv-access.js`, `inst/www/sideview.css` (connect-source and menu styles under `.sv-access`)
- Test: `tests/testthat/test-access-browser.R`

**Interfaces:**
- Consumes: Task 6 API; `engine.addConnections(list)` (line 3757), `engine.removeConnection(connId)` (line 4122),
  the engine's connection list (read the field `removeConnection` uses), `engine.setView`.
- Produces: roving `tabindex` on `th` (one `th` at 0 inside the focused card, the rest -1; the focused `th`'s own
  tool buttons at 0); class `sv-kb-connect-source` on the source `th`; menu `div.sideview-kb-menu[role=menu]` with
  `button[role=menuitem]` items `Remove join to <Card>.<col>` and `All joins on this column`.

- [ ] **Step 1: Write the failing tests:**
  - `"Enter goes into the headers, Left/Right move, Escape goes back"`.
  - `"C then Enter on another card's column creates one join, one step, one column_mapped"`: from
    `patients.patient_id`, C, Alt+ArrowRight to `visits`, Enter, Right to `pid`, Enter -> one new connection,
    pipeline step count +1, spy saw one `column_mapped`, `announceLog` has
    `Connecting from patients.patient_id. Choose a column.` then the existing join-added sentence; Ctrl+Z
    removes it.
  - `"Escape cancels connecting"`: `Connecting cancelled.`, no `sv-kb-connect-source` left.
  - `"Delete removes one join; with several a menu lists each plus all"`: one join -> Delete removes it,
    `Removed 1 join on patients.patient_id.`; two joins -> Delete opens the menu, focus on its first item, Escape
    closes it with focus back on the `th`, `All joins on this column` removes both with
    `Removed 2 joins on patients.patient_id.`; no joins -> `No joins on patients.patient_id.`
  - `"J moves to the joined column and cycles"`.
  - Review Focus 1 (connect half): mid-connect `setAccess(false)` cancels silently.
  - Review Focus 2: module page, `sv_remove_card()` on the focused / source card -> focus on the next card, connect
    cancelled.
  - Review Focus 3: mid-connect, `setView('list')`, opening `?` and Ctrl+K each cancel connect.
  - Review Focus 4: a card and column named `<img src=x onerror="window.__x=1">`: announcements and menu items
    show the literal text, `window.__x` undefined.
- [ ] **Step 2: Run** the filter. Expected: FAIL.
- [ ] **Step 3: Implement.** The join type is whatever a mouse click-to-connect creates (read it from the
  click-to-connect path, do not hard-code a new default). Enter on a column of the source card while connecting
  announces `Choose a column in another table.` and stays in connect mode. Menu items use `textContent`.
- [ ] **Step 4: Run** the filter, the a11y filter and the layout filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(access): keyboard joins on column headers (C, Enter, Delete, J)`.

### Task 8: The `?` key list, axe with the switch on, mock DOM

**Files:**
- Modify: `inst/www/sideview.js` (`SHORTCUTS` near line 1800, `toggleShortcuts()`)
- Modify: `tests/testthat/test-a11y-browser.R` (axe matrix near line 54; the `SV_AXE_ACCEPTED` comment)
- Modify: `tests/testthat/gui-test-runner.js` (new DOM: switch, `sv-access`, `tabindex`, menu)

**Interfaces:**
- Produces: an `ACCESS_SHORTCUTS` array rendered as a second `<dl>` headed `Accessible canvas keys`, shown only
  while `accessOn()`, re-rendered by `setAccess()` when the dialog is open.

- [ ] **Step 1: Write the failing tests:** `"the ? list shows the access keys only with the switch on"` (a11y file);
  `"axe-core: no violation with the switch on (modes x themes x sizes x panels)"`: for each mode, theme and size
  in `c(1360, 820)`, `c(1024, 700)`, `c(375, 812)`, open once with `access = TRUE` and run `sv_axe_run()` in each
  state: canvas, drawer open on each tab, AI bar and Copilot open, a filter popover open, the `?` dialog, the
  search dialog. No `SV_AXE_ACCEPTED` filtering for these runs; `expect_equal(nrow(v), 0, info = ...)` naming
  mode, theme, size and state.
- [ ] **Step 2: Run** the a11y filter. Expected: FAIL on the list test (and on any remaining axe issue; fix those
  in the task that owns the rule).
- [ ] **Step 3: Implement** the rows (Arrows, Shift+Arrows, Alt+Arrows, Enter, Left/Right, Escape, C, Delete, J,
  PageUp/PageDown/Home/End, with the effects as in the spec table). Change the `SV_AXE_ACCEPTED` comment to say it
  covers the default canvas only and the switch-on runs accept nothing. Update `gui-test-runner.js`.
- [ ] **Step 4: Run** the a11y filter, `node tests/testthat/gui-test-runner.js`, and
  `node --check inst/www/sideview.js inst/www/sv-access.js inst/www/sv-panzoom.js`. Expected: PASS / no output.
- [ ] **Step 5: Commit** `test(access): axe with the switch on; ? lists the access keys`.

### Task 9: Docs, manual script, full check

**Files:**
- Create: `plans/2026-11-15-access-manual-script.md` (Windows Magnifier 200% and 400%, Windows High Contrast, in
  Edge, then RStudio dialog and Viewer; includes the Alt+Left check in Edge and RStudio and the fallback rule)
- Modify: `CLAUDE.md` (the switch, `sv-access`, `sv-access.js`, the new keys, the OS blocks, the precedence),
  `NEWS.md`, `vignettes/` screen-reader article (short "Keyboard and low vision" section), `MEMORY.md` (log entry;
  close the `target-size` backlog item), `_pkgdown.yml` only if a new export appears (none is planned)

- [ ] **Step 1:** Write the docs and the manual script.
- [ ] **Step 2: Run** `devtools::document()`, `devtools::test()` with `NOT_CRAN=true`, `devtools::check()`.
  Expected: 0 failures; check with 0 errors, 0 warnings.
- [ ] **Step 3:** Rebuild the site (`RSTUDIO_PANDOC` set, `pkgdown::check_pkgdown()` then `build_site()`), scrub
  `docs/CLAUDE.*` / `docs/MEMORY.*` and their `sitemap.xml` / `search.json` entries.
- [ ] **Step 4: Commit** `docs(access): accessible canvas docs, manual script and site`.
- [ ] **Step 5:** Run the manual script with the user present (driven by Claude). If Alt+Arrows navigate away in
  any host, change `JUMP_MODS` to `'ctrl+alt'`, update the `?` rows, the tests and the docs, and commit
  `fix(access): card jumps on Ctrl+Alt+Arrows`. Record the results in `MEMORY.md`.
