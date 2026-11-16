# Manual script for the accessible canvas (2026-11-15)

Manual pass for the Accessible canvas switch (keyboard and low vision). Windows 11, Edge, then RStudio. **Status: Edge, Magnifier and High Contrast run 2026-11-16; RStudio dialog and Viewer reported OK (see Results).** Run it with the user present, driven by Claude, and record the
outcome in `MEMORY.md`.

Synthetic data only. Not for clinical use.

## Launch

Run from the package root (`C:/src/sv-a11y`):

```r
devtools::load_all(".")
source("tests/testthat/helper-nvda.R")
fx <- sv_nvda_fixtures()
sideview(DM = fx$DM, AE = fx$AE, SUPPAE = fx$SUPPAE, labs = fx$labs, viewer = "browser")
```

- Edge passes: `viewer = "browser"` (set the default browser to Edge, or paste the URL into Edge).
- RStudio passes: the same call with `viewer = "dialog"`, then `viewer = "pane"`.
- Each pass starts from a fresh launch. Before it, clear the stored choices in the browser console:
  `localStorage.removeItem('sideview.access'); localStorage.removeItem('sideview.shortcuts')`.
  In RStudio there is no console for the page: restart the gadget with a new session instead, or open the `?` dialog and
  turn the switch off.
- To start with the switch on from R, add `access = TRUE` to `sideview()` (or set `options(sideview.access = TRUE)`).
  A widget has no `access` argument: use `sideview_widget(..., options = list(access = TRUE))` or the option. A stored
  browser choice wins over this.

## Checks (every pass)

| # | Setup | Do | Expect |
|---|---|---|---|
| 1 | Fresh launch, switch off | Press `?` | The dialog has two switches: "Keyboard shortcuts" and "Accessible canvas". The access one is off and no "Accessible canvas keys" list is shown. The canvas looks as in 0.8.0 |
| 2 | Continue | Press Tab through the page | Tab reaches toolbar buttons and card header buttons as before (cards are not stops) |
| 3 | Continue | Open `?`, turn "Accessible canvas" on (Space on the switch) | "Accessible canvas on." is announced, focus stays on the switch, the keys list appears, text and buttons grow |
| 4 | Continue | Close the dialog; press `0` and `-` several times | The zoom never goes below 100% |
| 5 | Continue | Tab to a card, then keep pressing Tab | Each card is a stop, in reading order (top to bottom, then left to right). Inside it Tab reaches the card's buttons, one column header and the table body ("patients rows"), then the next card. A 3 px focus ring shows. The card is fully visible, clear of the drawer, AI bar and minimap |
| 6 | Card focused | Arrow keys, then Shift+Arrow | The card moves 20 px, then 100 px. After a pause "AE moved." is announced |
| 7 | Card focused | Alt+Arrow toward another card | Focus goes to the nearest card in that direction and its name sentence is announced. **The page does not navigate back or forward** (see "Alt+Left check") |
| 8 | Card focused | Enter | Focus goes to the first column header |
| 9 | Header focused | Left, Right, Escape | Previous, next column header; Escape returns to the card |
| 10 | On DM.USUBJID | `C`, Alt+Arrow to AE, Enter, Right to USUBJID, Enter | "Connecting from DM.USUBJID. Choose a column." then a join is added (one spline, one pipeline step) with the join sentence announced |
| 11 | Continue | Escape during a second `C` | "Connecting cancelled." |
| 12 | Joined column focused | `J` | Focus moves to the joined column; its name is announced. `J` again cycles back |
| 13 | Joined column focused | Delete | One join: removed, "Removed 1 join on DM.USUBJID." Several: a menu lists each join plus "All joins on this column" |
| 14 | Continue | Make three joins; look at the splines | Each has a different dash pattern and an arrowhead; they can be told apart without colour |
| 15 | Card focused | PageDown, PageUp, End, Home | The card's table body scrolls |
| 16 | Typing in the AI bar or a filter box | Press `C`, `J`, Delete, Arrows | The text field gets them; no canvas action |
| 17 | Open the drawer on each tab, the AI bar, a filter popover, `?` and Ctrl+K search | Look and Tab | Text at least 16 px, no overlap, every control at least 24 px on screen |
| 18 | Switch off in `?`, then reload | Look | The canvas is as in check 1; zoom range back to the normal range |
| 19 | Reload with the switch on | Look | The choice is remembered (stored choice wins over R) |

## Alt+Left check (decides the jump keys)

Alt+Left and Alt+Right are the browser's Back and Forward keys. The card jump uses Alt+Arrows, so each host must let the
page cancel them.

1. Switch on. In Edge, press Alt+Left and Alt+Right on a focused card (check 7).
2. Repeat in the RStudio dialog and the Viewer pane.
3. **Fallback rule:** if any host navigates away (page goes back, the Viewer reloads or goes blank) the card jump moves
   to Ctrl+Alt+Arrows everywhere. In code: set `JUMP_MODS = 'ctrl+alt'` in `inst/www/sv-access.js` (the only place),
   change the `?` rows and `ACCESS_SHORTCUTS` in `sideview.js`, the tests and the docs, and commit
   `fix(access): card jumps on Ctrl+Alt+Arrows`.

## Pass A: Windows Magnifier, 200% and 400% (Edge)

Turn Magnifier on with Win+Plus. Set the zoom with Win+Plus / Win+Minus (200%, then 400%). Use full-screen mode.

- Run checks 3 to 15 at 200%, then 3, 5, 6, 8, 10 at 400%.
- Expect: the focused card or header stays in view as Magnifier follows the keyboard focus; focus ring and splines are
  visible; no control is clipped; the zoom floor keeps the text readable.
- At 400% the canvas is not required to reflow (WCAG 1.4.10 exempts 2D layouts); the list view is the reflow path. Note
  anything that cannot be reached by keyboard.

## Pass B: Windows High Contrast (Edge)

Settings, Accessibility, Contrast themes. Run once with "Aquatic" or "Desert" and once with "Night sky". Test with the
switch off, then on.

- Expect: splines, ports, card borders and the focus ring use the system colours and stay visible (this is the
  `forced-colors: active` block); on a 3-join canvas the dash patterns and arrowheads still tell the joins apart; the
  suggested join (check by asking for suggestions) and the draft line (start `C` with the mouse by clicking a port) are
  distinct from accepted joins.
- Also try Settings, Accessibility, "Increase contrast" if offered, or `prefers-contrast: more` in Edge flags: borders
  and the focus ring are stronger; layout and zoom range unchanged with the switch off.

## Pass C: RStudio dialog and Viewer pane

- Dialog (`viewer = "dialog"`) and Viewer (`viewer = "pane"`): run checks 1, 3 to 13 and the Alt+Left check.
- Expect the same as in Edge. The Viewer pane is small: with the switch on the drawer is a bottom sheet that scrolls and
  does not cover the AI bar. Note any key RStudio keeps for itself.

## Results

| Pass | Date | Result | Notes |
|---|---|---|---|
| Edge, checks 1 to 19 | 2026-11-16 | pass | Partly: 1, 3, 4, 6, 7 checked by Claude in a Chromium pane; 5 and 8 to 13 by the user |
| Alt+Left in Edge | 2026-11-16 | pass | Jump keys work, page does not navigate |
| Magnifier 200% | 2026-11-16 | pass | OK, reported by the user |
| Magnifier 400% | 2026-11-16 | pass | OK, reported by the user |
| High Contrast | 2026-11-16 | pass | OK, reported by the user (checks on and off) |
| RStudio dialog | 2026-11-16 | pass | reported OK by the user |
| RStudio Viewer | 2026-11-16 | pass | reported OK by the user |
| Alt+Left in RStudio dialog and Viewer | 2026-11-16 | pass | reported OK by the user |
