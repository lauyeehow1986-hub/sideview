# sideview accessible canvas (keyboard and low vision): design

- **Date:** 2026-11-15
- **Sub-project:** accessibility **B** (keyboard and low vision). Follows A and C (0.8.0,
  `plans/2026-11-14-accessibility-text-first-design.md`). Release number decided at merge time.
- **Status:** design agreed in chat, item by item; builder check done; this written spec awaits review.
  Points I settled after the builder check are marked **(my call)**.

## 1. Intent

0.8.0 gave blind users a list view. B is for the other half of the audience: people who see the screen, at least
partly, and people who cannot use a mouse. They should be able to use **the canvas itself**: move cards, follow
joins, connect columns and read tables, at a size they can see, by keyboard alone.

The user's rule: all of this sits behind **one switch**. Someone who never turns it on gets today's canvas
unchanged: same look, density, zoom range and keys.

## 2. What the user decided

- Make the canvas itself usable by keyboard and at low vision (not only the list view).
- It is opt-in: an "additional" mode usual users do not meet unless the switch is on.
- **One switch**, covering keyboard and low vision together.
- **Who flips it:** R sets the starting state (argument plus option); a switch in the page lets the user change it;
  the browser remembers the user's choice, and that choice wins over R.
- **Placement of the page switch:** inside the existing `?` keyboard-shortcuts dialog, beside the shortcuts switch.
  Not on the toolbar.
- **Readable size:** a zoom floor (approach 1 below).
- **Scope of the low-vision treatment:** the whole sideview area, not only the canvas: cards, splines, ports,
  minimap and toolbar, plus the drawer (every tab), the AI bar and Copilot, filter popovers, the `?` and search
  dialogs, and toasts (the user took my pick).
- Agreed as proposed: the key table (section 5), the low-vision list (section 6), the testing plan (section 9), and
  that Windows High Contrast and "increase contrast" are followed even with the switch off (section 7).

## 3. Goals, non-goals, anti-goals

**Goals**
- With the switch on, every control in the sideview container (canvas and all chrome listed in section 2) is at
  least 24 x 24 CSS px **on screen** (WCAG 2.5.8), and axe passes on the whole container with no exemption.
- With the switch on, a keyboard-only user can move cards, move between cards and columns, create a join and
  remove joins, and the view keeps the focused item on screen (WCAG 2.4.11 focus not obscured).
- With the switch on, text and non-text contrast meet 7:1 (text) and 4.5:1 (splines, borders, focus ring).
- With or without the switch, the canvas stays usable under Windows High Contrast (`forced-colors: active`) and
  `prefers-contrast: more`.

**Non-goals**
- Large "tile" cards when zoomed out (approach 3). A possible later addition on top of the zoom floor.
- Reflow of the canvas at 400% (WCAG 1.4.10 exempts content that needs a 2D layout; the list view is the
  reflow path).
- Screen-reader work on the canvas (A covers screen readers through the list view).
- Two switches; a toolbar button; detecting low vision automatically.
- Undo for card moves (positions are not pipeline steps; a card is moved back by moving it).

**Anti-goals (a failure even if it works)**
- The default canvas changes look, layout, zoom range or keys for a user who never turns the switch on
  (the only exception is section 7, which only fires when the operating system asks for it).
- Canvas keys fire while the user is typing, or outside the container in an embedded widget.
- The widget's styles leak onto a host page (all rules stay scoped under `.sideview-container`).

## 4. Approaches considered (readable size at "Fit all")

Today "Fit all" at 1360 px wide scales cards to about 0.5-0.71, so 24 px buttons render at 12-17 px.

1. **Zoom floor (chosen).** With the switch on the canvas never goes below scale 1.0. "Fit all" fits what it can
   at 1.0; the minimap, Alt+Arrow card jumps, Ctrl+K search and focus-following give the overview. One number
   changes; card layout does not, so it cannot break the default canvas. Cost: fewer cards visible at once.
2. **Counter-scaled chrome.** Layout zooms, card chrome is scaled back up. Keeps the overview, but at low zoom
   headers overflow their cards, overlap neighbours and move spline anchors: the 0.3.0 layout-bug class.
   Rejected.
3. **Semantic zoom tiles.** Below a threshold each card becomes a large tile. Best overview, most work (second
   card rendering, splines on tiles). Deferred (non-goal).

## 5. Keyboard on the canvas (switch on)

Cards join the Tab order (one stop per card, in reading order: top-to-bottom, then left-to-right by card position).
Keys act only on the focused card or column; they never fire while typing (`isTypingTarget`) and only when the
canvas owns the keyboard (`ownsKeyboard()`).

| Focus on | Key | Effect | Announcement |
|---|---|---|---|
| card | Arrows | move the card 20 px | (on key-up/pause) `AE moved.` |
| card | Shift+Arrows | move the card 100 px | as above |
| card | Alt+Arrows | focus the nearest card in that direction | the card's name sentence |
| card | Enter | focus the card's first column header | |
| column header | Left / Right | previous / next column header in the card | |
| column header | Escape | back to the card | |
| column header | C | start connecting from this column | `Connecting from AE.USUBJID. Choose a column.` |
| connecting | Alt+Arrows, Enter, Left/Right | move to another card, into its headers, along them | |
| connecting, on a column | Enter | create the join (same path as a mouse spline: `addConnections`, one `column_mapped`, one pipeline step) | the existing join-added sentence |
| connecting | Escape | cancel | `Connecting cancelled.` |
| column header | Delete | one join: remove it; several: a small menu lists each join plus `All joins on this column` (`removeConnection` per join) | `Removed 2 joins on AE.USUBJID.` |
| column header | J | focus the column it is joined to (cycles if several) | the joined column's name |
| card | PageUp / PageDown / Home / End | scroll the card's table body | |

- **Shortcuts switch:** these are focus-scoped keys, so they work whether the single-key shortcuts are on or off
  (WCAG 2.1.4 exempts keys that act only on the focused component). This corrects the chat summary, which said
  they sit under the shortcuts rule: with shortcuts off (the list view's default), a keyboard user would otherwise
  be unable to move a card. The global shortcuts (F, 0, +/-, T, D, M, L, /, ?) keep their current rule.
- **Focus following:** whenever focus lands on a card or a column header that is not fully on screen, the view pans
  (never zooms below the floor) so the item is visible, with 24 px margin, outside the drawer, AI bar and minimap.
  `prefers-reduced-motion` makes it a jump.
- Moves send the existing `sideview_card_moved` input, once per pause (debounced), as a mouse drag does.
- **Card body (my call):** the table body is not a Tab stop and there is no cell-by-cell grid navigation (the list
  view is the path for reading cells); PageUp/PageDown/Home/End on a focused card scroll its body.
- **Alt+Arrows (my call):** Alt+Left is the browser's Back key. The builder first checks that `preventDefault()`
  stops it in Edge, Chrome, the RStudio dialog and the Viewer; if any of them navigates away, the card jump moves
  to Ctrl+Alt+Arrows everywhere.
- All new keys are listed in the `?` dialog (only while the switch is on).
- Joins created or removed this way are pipeline steps and undo/redo like any other.

## 6. Low vision (switch on)

- **Zoom floor:** `minScale` becomes 1.0. Turning the switch on while below 1.0 zooms to 1.0 around the focused
  card (else the view centre). `fitAll()` clamps to 1.0 and centres on the focused card, else the top-left of the
  arrangement. Turning the switch off restores the normal range (no zoom change at that moment).
- **Text:** every text in the container at least 16 CSS px (today 8-14 px): cards and canvas chrome, the drawer
  (code, pipeline, join options, column inspector, every builder tab), the AI bar and Copilot, filter popovers,
  the `?` and search dialogs, and toasts. Code in the drawer uses the same floor.
- **Targets:** every control in the container at least 24 x 24 CSS px (card and column-header controls render
  24 px at scale >= 1.0; drawer and dialogs are not scaled).
- **Layout at the narrow sizes:** the chrome keeps its no-overlap rule at the three layout sizes with the larger
  text; at `sv-narrow` the drawer stays a bottom sheet and scrolls rather than covering the AI bar.
- **Card growth on switch flip (my call):** CSS only, no inline geometry writes. Cards the user sized
  (`freezeCardSize` / `sv-sized`) keep their size and scroll inside. Neighbours are not moved automatically
  (cards may overlap after growth). Changed 2026-11-16 at the user's request: switching on arranges the cards
  when any overlap, and switching off puts back every card the user has not moved since, so the exact old layout
  returns. Workspace state is untouched.
- **Contrast theme:** a high-contrast token set for light and dark (`.sv-access` overrides `--sv-*`), with text
  >= 7:1 and splines, borders, ports and the focus ring >= 4.5:1 against their background. When on, it overrides
  colours from `theme =` (a custom bslib theme may not meet these ratios); the light/dark mode still follows the
  theme.
- **Splines:** 3 px wide; each join gets a dash pattern from a fixed cycle of at least 6 distinct patterns (by join
  order) and an end marker, so crossing joins can be told apart without colour. Selected/hover state is shown by
  width and marker, not colour alone.
- **Pattern cycle (my call):** solid plus dot-dash variants; never `6,6` (today's suggested-join dash) or `4 4`
  (the draft line), so accepted, suggested and draft joins stay distinct. Suggested joins get a hollow end marker.
  Accepting suggestions by keyboard stays in the drawer and the list view (no canvas key for it). The same
  patterns apply under `forced-colors` (section 7).
- **Focus ring:** 3 px solid plus 2 px offset, on cards, column headers and every control.
- Badges and states that use colour today (CDISC tags, key-check states, discrepancy marks) also carry text or a
  shape.

## 7. Operating-system signals (always on, switch or not)

- `@media (forced-colors: active)`: splines, ports, card borders and the focus ring use system colours
  (`CanvasText`, `Highlight`, `ButtonText`); no information is lost when backgrounds and colours are replaced
  (dash patterns from section 6 also apply here so joins stay distinguishable).
- `@media (prefers-contrast: more)`: borders, ports and the focus ring move to the stronger tokens of section 6;
  layout and zoom range are unchanged.
- Both blocks are scoped under `.sideview-container`. Default users without these OS settings see no change.

## 8. The switch

- **R:** `access = getOption("sideview.access", FALSE)` on `sideview()`, `sideview_ui()` and `sideviewUI()`;
  `sideview_widget(options = list(access = ))` with the same option as default (as `shortcuts` is today), so
  `save_sideview()` carries it. Rendered as `data-sv-access="true"` on the container / `options.access` in the
  widget. Documented with the other options in `?sideview`.
- **Page:** a second switch in the `?` dialog, `Accessible canvas` (`role="switch"`, like the shortcuts switch).
  Toggling announces `Accessible canvas on.` / `Accessible canvas off.`; focus stays on the switch.
- **Precedence:** a stored browser choice (`localStorage` key `sideview.access`, `on`/`off`, wrapped in try/catch)
  wins over R, as `sideview.shortcuts` does today. `engine.accessOn()` / `engine.setAccess(on)` mirror
  `shortcutsOn()` / `setShortcuts()`.
- **Effect:** the container gets the class `sv-access`; the engine applies the zoom floor and the keyboard model.
- **Not in workspace state:** it is a viewer preference, not part of the analysis (as the shortcuts choice).
- **Several canvases on one page (my call):** as the shortcuts switch: the stored choice is shared by origin, so
  flipping it in one canvas changes that canvas now and the others on their next load.
- Works the same in gadget, widget, saved HTML and module mode (module: no new inputs or messages; nothing in it
  is code execution).

## 9. Testing

- **Real browser** (`test-a11y-browser.R`, `NOT_CRAN=true`, real input via `b$Input`):
  every key in section 5; Tab order of cards; focus following (focused card's rect inside the visible canvas,
  outside drawer, AI bar and minimap); zoom floor (wheel, `-`, `0`, `fitAll`, a restored state with zoom 0.5 all
  give >= 1.0); keys silent while typing and with focus outside an embedded widget; switch precedence (option vs
  stored choice); a switch-off run proving the default canvas is unchanged (zoom range, Tab order, no `sv-access`).
- **axe matrix:** add the switch-on runs, light and dark, at the three layout sizes, with an empty
  `SV_AXE_ACCEPTED`, scanning the whole container in each state: canvas only, drawer open on each tab, AI bar and
  Copilot open, a filter popover open, the `?` dialog and the search dialog. The default canvas keeps its
  `target-size` acceptance.
- **Layout with the switch on** (`test-layout-browser.R`): the existing chrome no-overlap and spline-to-port checks
  at the three sizes; every text node in the container computes to >= 16 px and every control's rect is >= 24 px.
- **Contrast** (`test-theme.R`): the `.sv-access` tokens meet 7:1 text and 4.5:1 non-text, light and dark; the
  existing light/dark-block equality check extended to the access blocks.
- **Forced colours:** chromote `Emulation.setEmulatedMedia` with `forced-colors: active` and
  `prefers-contrast: more`: splines, ports and the focus ring are visible (computed colour differs from the
  background), with the switch on and off.
- **Manual pass:** a script in `plans/` like the NVDA script, run with Windows Magnifier (200% and 400%) and
  Windows High Contrast in Edge, then in RStudio (dialog and Viewer), driven by Claude with the user present.
- `gui-test-runner.js` updated for the new DOM; `node --check` on changed JS.

## 10. Left to the builder

- Exact token values for the access theme (within the ratios above) and the 6+ dash patterns.
- Debounce time for move announcements and `sideview_card_moved`.
- Whether column headers use a roving `tabindex` or `aria-activedescendant`, as long as Tab leaves the card in
  one step after its headers and the existing sort/filter buttons stay reachable.
- How "nearest card in a direction" is scored (centre distance with a cone is fine).
- How the list of new keys is grouped in the `?` dialog.

## 11. Docs

`CLAUDE.md` (the switch, `sv-access`, new keys, the forced-colors blocks), `NEWS.md`, `?sideview` options,
the screen-reader article gains a short "Keyboard and low vision" section, `MEMORY.md` (and remove the
`target-size` backlog item once the switch-on axe run passes).
