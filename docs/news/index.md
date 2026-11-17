# Changelog

## sideview 0.10.0 (development)

Derived cards, first part (D1): the rows behind a check count become a
card of their own. Development version; the release number is decided at
merge time. Checked with real-browser tests (headless Chrome) and unit
tests; the manual RStudio pass is still to do.

### Open the rows behind a count

- A join check or a SUPP check offers buttons that open the rows behind
  its counts as a new card: the rows of either table with no match
  (`unmatched`), the rows a date rule dropped (`outside_window`), and
  the SUPP rows with no parent row (`supp_orphans`) or with an
  `IDVARVAL` that does not convert (`supp_bad_idvarval`). The card is
  named for what it holds (`ae_unmatched_dm`), sits near its first
  input, and is built by R from the tables as loaded, so a duckdb or
  Arrow input stays lazy. The same buttons appear in the list view as
  real buttons, and the result is announced.
- `sv_unmatched(x, y, by, rule, side, what)` and
  `sv_supp_orphans(parent, supp, rdomain, what)` return the same rows
  from the console.
- A derived card is one pipeline step (`kind: "derive"`) and its
  generated R code rebuilds the rows with `dplyr`, so a script
  reproduces the card. The step is part of workspace state.
- In a Shiny module, removing an input removes the cards derived from it
  (their steps stay); replacing an input rebuilds them in place; adding
  it back brings them back. A state saved with derived cards is restored
  with them.
- New inputs `derive_request` and `derive_forget`, new message
  `sideview_derive_result`, and a `derive_offers` field on the
  join-check and SUPP-check replies (see CLAUDE.md). The widget has no
  R: it shows no buttons, and a saved state’s derive steps stay in the
  code (when both inputs are there) but the tables are not shown, with a
  notice.

## sideview 0.9.0

Accessible canvas: one switch that makes the canvas itself usable by
keyboard and at low vision. Off by default; with it off the canvas is
unchanged. Checked with automated WCAG tests (axe, switch on and off)
and real-browser keyboard tests; a manual pass (Windows Magnifier at
200% and 400%, High Contrast, Edge, RStudio dialog and Viewer, Alt+Arrow
card jumps) found no problems. The release number is decided at merge
time.

### Accessible canvas switch

- Switching it on arranges the cards when the larger text makes them
  overlap; switching it off puts every card you have not moved since
  back where it was.
- [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md),
  [`sideview_ui()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_ui.md)
  and
  [`sideviewUI()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md)
  take `access = FALSE`, set for a session by
  `options(sideview.access = TRUE)`. The widget has no `access`
  argument: use `sideview_widget(..., options = list(access = TRUE))`,
  or the same option, which
  [`sideview_widget()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md)
  and
  [`save_sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/save_sideview.md)
  also follow. It sets the starting state only: the `?` dialog has an
  “Accessible canvas” switch beside the shortcuts switch, and the
  browser remembers the choice (`localStorage` key `sideview.access`),
  which wins over R. Each canvas reads its state once when it starts, so
  switching one of two canvases on a page leaves the other as it is
  until the next load. The container carries `data-sv-access` and the
  class `sv-access` while on. The choice is not part of workspace state.
- Workspace state saved with the switch on keeps the default card sizes
  (the switch only enlarges cards on screen), so opening it with the
  switch off gives the same layout. A card the user resized is saved
  with an optional `user_sized: true` (no schema bump) and keeps its
  size when the state is opened with the switch on.
- Switching off never leaves focus on a header or a card body that has
  lost its Tab stop: focus goes to the canvas, also when the switch is
  turned off in the `?` dialog.

### Low vision

- With the switch on the zoom never goes below 100% (wheel, `-`, `0`,
  Fit all and a restored view are all clamped). Turning it on below 100%
  zooms to 100% around the focused card. Text is at least 16 px, every
  control is at least 24 by 24 px on screen, the focus ring is 3 px, and
  a high-contrast colour set (text 7:1, lines and ports 4.5:1) replaces
  the theme colours. Splines are 3 px wide with one of six dash patterns
  (butt caps, so the gaps stay open) and an arrowhead, so crossing joins
  can be told apart without colour; suggested joins end in a hollow
  marker. Badges that used only colour (CDISC, key-check state,
  discrepancies) carry text.
- Windows High Contrast (`forced-colors: active`) and
  `prefers-contrast: more` are followed even with the switch off: system
  colours for splines, ports, borders and the focus ring, stronger
  borders under more contrast.
- One change applies with the switch off too: the key names in the
  search dialog’s hint (`.sideview-search-hint kbd`) now use the text
  colour (`--sv-text`) rather than the hint’s muted colour, for
  contrast.
- The axe matrix now also runs with the switch on (light and dark, three
  sizes, canvas, drawer tabs, AI bar, filter popover, `?` and search
  dialogs) with no accepted rules, so `target-size` passes there. The
  default (switch off) canvas keeps its `target-size` exemption: its
  buttons are 24 px in CSS but the fit zoom shrinks them on screen.

### Keyboard on the canvas

- With the switch on, each card is a Tab stop (reading order). Inside it
  Tab reaches the card’s buttons, one roving column header and the table
  body (a region named “ rows”, for scrolling with the keys below), then
  the next card, and the view follows focus so the item is never under
  the drawer, AI bar or minimap. On a card: Arrows move it 20 px,
  Shift+Arrows 100 px (one `sideview_card_moved` per pause, announced
  “AE moved.”), Alt+Arrows focus the nearest card, Enter goes to the
  first header, PageUp/PageDown/Home/End scroll the table. On a column
  header: Left/Right, Esc, `C` to start connecting (Enter completes the
  join as a click does: one `column_mapped`, one undoable step), Delete
  to remove a join (a menu when there are several), `J` to jump to the
  joined column. These keys work with the shortcuts switch off and never
  fire while typing. They are listed in the `?` dialog while the switch
  is on.
- If Alt+Left navigates away in a host, the jump moves to
  Ctrl+Alt+Arrows (`JUMP_MODS` in `sv-access.js`).

## sideview 0.8.0

Text-first accessibility: a list view that reads top to bottom, results
printed as plain sentences, live announcements and an accessibility test
suite. sideview 0.8.0 is checked with automated WCAG tests (axe) and
real-browser keyboard tests; the NVDA script was run once in Edge with
NVDA 2026.2 (all 15 tasks as written; the RStudio dialog and Viewer pane
were not covered); not yet tested by blind users. See the new article
“Using sideview with a screen reader” and the accessibility feedback
issue template.

### List view: card changes and the keyboard walk

- A table added, replaced or removed from R
  ([`sv_add_card()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md),
  [`sv_replace_card()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md),
  [`sv_remove_card()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md))
  updates only that table’s section of the list view and is announced
  (“Table labs replaced.”). With no tables the Tables section reads “No
  tables yet.” A table that falls back to its preview now says so in its
  heading.
- Everything the canvas does for a join, a filter or a SUPP merge can be
  done from the keyboard in the list view, and the code it composes is
  the same. The accessibility tests run axe-core over the canvas and the
  list view in all three modes, both themes and a phone width, with no
  accepted exceptions in the list view; on the canvas, axe’s target-size
  rule is accepted because the fit zoom shrinks the 24 px icon buttons
  (to be fixed in sub-project B).

### List view argument

- [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md),
  [`sideview_widget()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md),
  [`save_sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/save_sideview.md),
  [`sideview_ui()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_ui.md)
  and
  [`sideviewUI()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md)
  take `view = "canvas"` (default) or `"list"`, set for a session by
  `options(sideview.view = "list")`. The container carries
  `data-sv-view` and the widget `options$view`. A saved workspace may
  now carry `view.mode`; an invalid value is dropped.

### List view

- The toolbar has a “List view” toggle (and the Summary section repeats
  it). The list view shows the tables as text in a normal-flow column
  that keyboard and screen-reader users can read: a Summary (counts of
  tables, join steps and pipeline steps, whether code is ready, skip
  links, Save, Open and the keyboard shortcuts switch) and the headings
  Tables, Join, Merge SUPP, Transform, Pipeline and Code (and Copilot
  when a model is set up). The canvas leaves the accessibility tree
  while the list is shown. Switching is announced (“List view” / “Canvas
  view”) and moves focus to the list’s first heading. The single-key
  shortcuts default to off in the list view.
- `view = "list"` starts in it. A saved workspace now records the view
  (`view.mode`) and wins over the `view` argument when it is opened.

### List view tables

- The Tables section lists every table: a heading (“labs, 5,000 rows by
  3 columns, full table.”, or “preview of the first 50 rows”), one line
  per column (name, label, kind, and the distinct and missing counts
  when the card shows them) with Sort, Filter and Inspect buttons, and
  the rows as a captioned table, 25 a page, with Previous rows, Next
  rows and Go to row. A page change is announced (“Rows 26 to 50 of
  5,000.”) and focus stays on the button. Rows follow the canvas sort
  and filter; a large (lazy) table is read a window at a time from R.
  Sort announces its result; Inspect writes the profile as sentences
  under the column. A table with more than 30 columns starts with its
  columns closed. List view columns no longer state counts taken from
  the canvas badges on lazy, preview or truncated cards (they come from
  the 50-row preview); a sampled “~N distinct” is never shown as exact.

### Table ARIA

- Each table on the canvas has a (screen-reader-only) caption with the
  card name and announces its full size: `aria-rowcount` (rows plus the
  header), `aria-colcount`, and a row index on every rendered row, so a
  screen reader says “row 2002 of 5001” while the table shows only a
  window of it. The counts follow sort and filter.

### Keyboard shortcuts switch

- The `?` list has a “Keyboard shortcuts” switch that turns the
  single-key shortcuts off (WCAG 2.1.4). The choice is remembered in the
  browser; if the browser blocks storage it holds for the session.
  `Ctrl+K` and `Ctrl+Enter` always work.
- New option `sideview.shortcuts` (default `TRUE`): `FALSE` starts the
  gadget, widget and module with the shortcuts off.
  `sideview_widget(options = list(shortcuts = FALSE))` does the same for
  one widget.

### Live announcements

- The canvas has a polite live region (`.sideview-announcer`,
  `role="status"`) that says what happened: a finished join, SUPP or
  column check reads its first sentence, a step added, removed, undone
  or redone reads “Join step added. 3 steps.”, Copy and Insert read
  “Code copied.” / “Code inserted.”, and a Copilot reply reads “Copilot
  replied, 4 lines of code.” It works in the gadget, the widget and a
  module.
- Toasts are no longer a live region of their own. Error toasts are
  `role="alert"`; the other toasts are spoken through the announcer.

### Accessibility test harness

- New real-browser accessibility tests (`test-a11y-browser.R`): every
  canvas control has an accessible name in the gadget, widget and
  module; Tab reaches the toolbar before the drawer; axe-core (WCAG 2.2
  A/AA) finds no violation across the three modes, two themes and two
  sizes (the list view with none; the canvas has one documented
  `target-size` exception); and today’s single-key shortcut and typing
  rules are pinned (typing in the AI bar never fires a shortcut).
- Contrast and control-size fixes found by the matrix. A new `a11y` CI
  job runs these tests with axe-core 4.10.3 pinned.
- Internal sentence helpers (`sv_say_*` in R, `say*` on
  `SideviewPipeline`) for plain-text output, with R and JS twins held
  equal by `test-say.R`.
- [`print()`](https://rdrr.io/r/base/print.html) of a join check
  ([`sv_join_diagnostics()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_join_diagnostics.md))
  now reads as plain sentences: “Join of patients and visits by
  patient_id is one to many.”, match counts with percentages, sample
  unmatched keys, rows by join type, and each hint or warning as its own
  sentence. The result also carries `x_name` and `y_name`.
- [`print()`](https://rdrr.io/r/base/print.html) of a SUPP merge check
  ([`sv_supp_check()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_supp_check.md)),
  a column profile
  ([`sv_column_profile()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_column_profile.md)),
  discrepancies
  ([`sv_detect_discrepancies()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_detect_discrepancies.md))
  and suggested joins
  ([`sv_suggest_mappings()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_suggest_mappings.md))
  now reads as plain sentences, for example “Merging suppae into ae adds
  1 column: AETRTEM.” These results have the classes `sv_supp_check`,
  `sv_column_profile`, `sv_discrepancies` and `sv_mappings`; they are
  still a list or data frame, and
  [`as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html) on the
  mappings gives the plain data frame. The data the browser receives is
  unchanged.
- Results print as sentences. Use
  [`as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html)
  (mappings) or [`unclass()`](https://rdrr.io/r/base/class.html)
  (discrepancies, checks, profiles) for the raw object.
- New
  [`sv_describe()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_describe.md)
  writes a table sentence and one line per column (label, kind, missing,
  distinct, ranges, top values) as plain text. It reads lazy duckdb and
  Arrow tables through their summaries and never collects them.

## sideview 0.7.0

### Merging SUPP– tables

- **Merge into AE.** A tagged `SUPPAE`, `SUPPDM` or `SUPPQUAL` card gets
  a **Merge into** button. It adds a merge step that folds the qualifier
  rows into the parent as one column per `QNAM`, with its `QLABEL` as
  the column label (`""` when there is none). The step writes tidyr +
  dplyr code with guards that stop when the data no longer fits.
  Pressing the button again replaces the step, and one undo takes it
  back. A `SUPPQUAL` with several `RDOMAIN`s gets one merge per parent
  on the canvas.
- **Merge check.** The Discrepancy tab shows parent, SUPP, matched and
  orphan counts, rows of other `RDOMAIN`s, a `QNAM` that repeats for one
  record, a clash with a parent column, a `QNAM` at two `IDVAR` levels,
  `IDVARVAL` values that do not convert (counted apart from orphans),
  the new columns and a 5-row preview. The step line in the Pipeline tab
  carries a one-line summary.
- **Refresh.** When a re-check finds that the data no longer fit the
  plan (for example after editing `suppae`), the step reads “Merge needs
  refreshing” and **Refresh** takes the plan that check found, as one
  undo step (Refresh itself runs no new check).
- **Auto Map** offers a SUPP card’s merge as a dashed spline group to
  its parent; accepting it adds the merge step instead of a join. The
  join check mentions the merge when you join a SUPP table by hand.
- **Lazy cards.** An arrow or duckdb parent stays lazy; only the SUPP
  table is collected.
- **[`sv_supp_check()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_supp_check.md)**
  (new, exported) runs the merge check on two data frames or cards.
  [`sv_supp_check_json()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_supp_check.md)
  and
  [`sv_supp_key_type()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_supp_check.md)
  are exported with it.
  [`sv_suggest_mappings()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_suggest_mappings.md)
  gains rows with `kind = "supp"`.
- New Shiny wire items: the input `supp_check_request`
  (`{id, parent, supp, plan?, rdomain?}`) and the message
  `sideview_supp_check`.

#### Edge cases fixed in the merge

- An `IDVARVAL` such as `1e999` (too large for a number) is now counted
  as “does not convert”, not as an orphan, and no longer stops the
  generated code on an Arrow int64 parent.
- A missing `QNAM` is read as the text `NA` in the gadget and the widget
  alike (the merged column is named `NA`).
- On a duckdb parent, records whose `USUBJID` or `STUDYID` is `NA` now
  receive their qualifiers, as the check says they do.
- A float32 parent key is compared as the double it holds (0.1 stored as
  float32 is not `"0.1"`): such rows are orphans in the check, and the
  generated Arrow code no longer rounds them onto the parent.
- On an Arrow parent with a narrow or decimal key (int8, int16,
  decimal), the generated code drops supp keys that the parent’s type
  cannot hold exactly. Before, 300 on int8 wrapped onto another record,
  and 0.125 on decimal(10, 2) was rounded onto one. The check already
  called such rows orphans.
- A lazy `SUPPQUAL` with three or more `RDOMAIN`s now offers a merge for
  every one, as in memory (only the first two were seen before). The
  default `RDOMAIN` is the first in byte order (`AE` before `CM`), the
  same in any locale and on every backend.
- Only ASCII whitespace around a numeric `IDVARVAL` is ignored, as R
  does. A no-break space, BOM or ideographic space makes the value “does
  not convert”, in the gadget and the widget alike (the widget ignored
  them before).
- A double `IDVARVAL` past 1e308 “does not convert” in the gadget and
  the widget alike. Before, R and the widget disagreed at the very top
  of the range.
- With both a missing `QNAM` and a `QNAM` of `"NA"`, the generated code
  now treats them as one name, as the check does.
- A full-precision `IDVARVAL` of a float32 key (`0.10000000149011612`)
  matches in the lazy check as it does in memory.
- An Arrow int64 key is a double key whatever its values (as a duckdb
  `BIGINT` already was), so a key past 2^31 no longer reads as “does not
  convert” on Arrow.

#### Limits to know about

- The merge needs the exact upper-case column names `USUBJID`, `IDVAR`,
  `IDVARVAL`, `QNAM` and `QVAL`.
- A second merge into one parent is checked for clashes in the browser;
  the guard in the generated code checks the source parent table only.
- The check runs when you press the Merge button, open the step line or
  report, open a workspace, undo or redo, and after a module card is
  replaced or removed; Refresh runs none. Only the guards in the code
  stop a rerun on new data.
- A double key with more than 15 significant digits can match
  differently: the in-memory R check compares 15-significant-digit text,
  while the generated code and the lazy duckdb check compare the
  doubles, so the gadget’s own report can disagree with its code for
  such keys (and the widget reads the shortest round-trip text).
- With an arrow parent the code casts a numeric key to the parent’s
  Arrow type (an int64 parquet column joins); the clash guard reads the
  parent’s columns with `collect(head(x, 0))`, so arrow queries work.
- A re-check sends the step’s `RDOMAIN`, so a step loaded with
  `cdisc = FALSE`, or after a tag changed, keeps its domain.
- `RELREC` tables are still not merged or suggested.
- A float16 parent key is not supported (Arrow cannot create float16
  columns).
- A double key beyond 1e308 is always “does not convert”, on purpose: R
  and JavaScript read the largest doubles differently.
- At most 1000 `RDOMAIN`s are read from a lazy `SUPPQUAL`.

## sideview 0.6.0

### CDISC join keys

- **Auto Map knows CDISC keys.** For tables tagged SDTM, SEND or ADaM it
  suggests the keys a study programmer would use, instead of guessing
  from column names:
  - *ADaM to SDTM trace:* `STUDYID`, `USUBJID` and `<D>SEQ` (`adae` to
    `ae` by `AESEQ`).
  - *Subject level:* `STUDYID` + `USUBJID`, with `DM` (SDTM, SEND) or
    `ADSL` (ADaM) as the lookup table.
  - *Visit level:* a table with `VISITNUM` to `SV`, by the subject key
    and `VISITNUM`. Where a table has no `STUDYID`, the subject key is
    `USUBJID` alone, and the reason says so.
- **One click, one join, one undo.** A key set is drawn as a group of
  dashed splines (class `sideview-spline-suggested-cdisc`). Hovering one
  lights up the group, and a click accepts all of it as one `left_join`
  (one undo step). A partial key set is never offered, because it would
  give a many-to-many join.
- **Key checks in the join check.** The join check panel gets a “CDISC”
  note list: a missing key for a pair with a rule (`Add AESEQ: ...`), a
  many-to-many join with no rule (for example two Findings tables), and
  a natural key that repeats
  (`STUDYID, USUBJID, AESEQ should identify one AE record, but 3 keys repeat`).
  The notes are worked out in R, so they appear in the gadget and in
  Shiny modules; the widget has none.
- **`sv_cdisc_join_keys(cards)`** (new, exported) returns the suggested
  key sets for a list of cards.
- **[`sv_suggest_mappings()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_suggest_mappings.md)**
  gains the columns `group` and `kind` (both `NA` for heuristic rows)
  and a `cdisc` argument (`"auto"`, `FALSE` or a named vector, as in
  [`sv_codebook()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_codebook.md)).
  Rule rows come first with confidence 1 and are never dropped by
  `min_confidence`. Between two tagged tables the old `DOMAIN` and
  lone-`STUDYID` guesses are gone.

#### Limits to know about

- `SUPP--` and `RELREC` tables are not suggested as joins (folding them
  into their parent is future work). Neither are tables without a
  `USUBJID` column (for example `TS`, `TA`, `TE`).
- A sponsor sequence variable that is not called `<D>SEQ` is not traced;
  the pair still gets the subject rule.
- Two Findings tables (`LB` with `VS`) get no suggestion, only a note:
  that join is many-to-many by nature.
- The widget has no Auto Map rules and no key-check notes; they need R.
- `cdisc = FALSE` turns the rules and the notes off.

## sideview 0.5.0

### CDISC awareness

- **Domain badges.** Tables that look like SDTM, SEND or ADaM datasets
  get a small badge after the card name (`DM`, `AE`, `ADSL`, …). Hover
  for the dataset label, the standard and class, and why sideview thinks
  so. Supplemental qualifier tables (`SUPPAE`) say which parent they
  supplement. Other tables are never touched.

- **Variable labels.** Column headers show a variable’s label as a
  tooltip, `L` shows a row of labels under the headers (saved with the
  workspace as `view.labels_row`), `Ctrl+K` also finds a card by its
  domain or dataset label, and the column inspector shows the label.

- **`cdisc =`** on
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md),
  [`sideview_widget()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md),
  [`save_sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/save_sideview.md),
  [`sideviewServer()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md)
  and
  [`sv_codebook()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_codebook.md):
  `"auto"` (default), `FALSE`, or a named vector such as
  `c(my_ae = "AE")`. Module canvases update their badges when a card is
  added or replaced.

- **[`sv_codebook()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_codebook.md)
  has a `domain` column.** The widget’s CSV download matches it byte for
  byte.

- **[`sv_cdisc_catalogue()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_cdisc_catalogue.md)**
  returns the dataset catalogue the detection uses.

- **[`sv_read_cdisc()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_read_cdisc.md)**
  reads a folder or a set of `.xpt`, `.sas7bdat`, Dataset-JSON and
  `.parquet` files into a named list for
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md),
  keeping variable labels. Nothing goes over the network.

- **Copilot.** The schema text sent to the LLM now includes column
  labels and a domain line. Row data is still never sent.

- **Overrides.** A table you tag yourself
  (`cdisc = c(my_adae = "ADAE")`) gets the same class as an
  auto-detected one: ADaM tags take BDS, OCCDS, TTE or ADSL from the
  table’s columns, and `SUPPAE`-style tags get Relationship and their
  parent. On a SEND canvas an auto-detected SUPP table is SEND too; your
  own tags are never flipped. The hover text says why a table is SEND.
  Names in `cdisc =` ignore a file extension (`"lab.csv"` names the
  table `lab`); case still matters.

- **Codebook and canvas agree.** The gadget’s codebook uses the badges
  on the canvas, so a tag you cleared stays cleared in the CSV. Labels
  sent to the Copilot are cut to 200 characters.

#### Limits to know about

- The `ig_versions` column of the catalogue (SDTM, SEND and ADaM
  implementation guide versions) is approximate. It is for awareness,
  not conformance checking: sideview does not validate a dataset against
  an implementation guide.
- A table named `AD...` (`ADLB`, `ADAE`, `ADVS`) whose columns confirm
  an ADaM structure is tagged ADaM even when it keeps SDTM-prefixed
  columns (`LBTESTCD`, `AETERM`, …); the tooltip notes the prefix as a
  disagreement. A table with any other name and SDTM-prefixed columns is
  still tagged by its prefix.
- Column names are matched whatever their case (`STUDYID`, `studyid`,
  `StudyID`), so tables cleaned with
  [`janitor::clean_names()`](https://sfirke.github.io/janitor/reference/clean_names.html)
  are still recognised. A `STUDYID` column is still required.
- `sideview_server(cdisc =)`, used with your own
  [`sideview_ui()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_ui.md),
  only sets the `domain` column of the codebook; the badges come from
  the cards given to
  [`sideview_ui()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_ui.md).
- [`sv_read_cdisc()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_read_cdisc.md)
  skips a file found by scanning a folder, with one warning, when its
  reading package is not installed; a file named explicitly is still an
  error.
- `cdisc = FALSE` shows no tags but, for lazy (arrow / duckdb) cards,
  detection at construction time still runs, with its cost. A named
  `cdisc =` vector with several lazy cards costs more on every verb
  (quadratic in the number of cards).
- [`sv_read_cdisc()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_read_cdisc.md)
  reads Dataset-JSON with the `datasetjson` package (checked against
  datasetjson 0.4.1, with column and dataset labels); if a file’s
  structure differs, it is skipped with a warning.
- The row of labels is placed using one measurement of the header
  height; it could sit off only if a header later grows taller (for
  example after a late font load).
- Checked in headless Chrome. `viewer = "dialog"` and `"pane"` were not
  checked in RStudio for this release.
- Workspace files gain an optional `view.labels_row` field without a new
  schema version; older sideview versions ignore it.

## sideview 0.4.0

### Smaller items

- **Row cap for widgets.**
  [`sideview_widget()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md)
  and
  [`save_sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/save_sideview.md)
  take `max_rows = 5000`. A longer data-frame table is cut to its first
  rows, its card says “First N of M rows” and one message names the
  tables cut (silent while knitting). `max_rows = Inf` embeds
  everything. Lazy tables are unchanged.
- **Positron.** Without `viewer =`,
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)
  and
  [`sideview_addin()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_addin.md)
  open the browser in Positron, which has no dialog viewer;
  `viewer = "dialog"` there also opens the browser, with one message.
- **State files carry a schema version.**
  [`sv_load_state()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_load_state.md)
  and `state =` read a file without a `version` as 0.2.0 and upgrade
  older files (stamped 0.3.0); a file from a newer sideview loads with
  one warning.
- **Install from r-universe:** see the README.

### Shiny module and proxy

- **[`sideviewUI()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md)
  /
  [`sideviewServer()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewUI.md)**
  put an R-backed canvas into your own Shiny app, several per page. The
  server returns a proxy with the reactives
  [`code()`](https://rstudio.github.io/htmltools/reference/builder.html),
  `pipeline()`, `state()` and `cards()`, and `sideviewProxy(id)` reaches
  the same canvas from elsewhere in the session. `cards =` can be a
  reactive; [`req()`](https://rdrr.io/pkg/shiny/man/req.html) in it
  means “no cards yet”. Lazy (arrow / duckdb) cards in a module show
  their true size, not “First 500 of …”, because R serves the whole
  table.
- **Verbs:**
  [`sv_add_card()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md),
  [`sv_replace_card()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md),
  [`sv_remove_card()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md),
  [`sv_set_state()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md)
  and
  [`sv_highlight()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_add_card.md),
  which pipe. A replace keeps the card’s place and size, re-checks the
  join keys, and **disables, not deletes**, any pipeline step that names
  a column the new table lacks (a `mutate` expression that uses it
  included), with one toast. A replace also keeps the card’s header sort
  and filter, so the canvas still agrees with the code.
- **Code execution is off in a module** (Insert Script, Run & Exit, Run
  in R, Run Console). `$code()` is composed in the browser: treat it as
  untrusted text.
- A module takes no AI settings from the browser, and shows the AI bar
  and the Copilot tab only when `llm_fn` is given.
- The example app `inst/examples/proxy/app.R` has two canvases and a
  button for each verb. The gadget and the widget are unchanged.

### Date-window joins

A join step can carry a **date rule**, so “labs within 7 days of the
visit” is a join and not a hand-written filter. Click the calendar
button on a join step to open the rule row. The shapes are **Between**
(a date inside the other table’s start and end), **Window** (within a
number of days before and after), **Nearest before**, **Nearest after**
and **Overlaps**. Date, date-time and numeric columns work. The code
uses `join_by()` and, for a window, two helper columns (`.sv_lo`,
`.sv_hi`) that it drops again.

- **The join check knows the rule.** The panel shows the rule and the
  rows it dropped (“Dropped by the rule”: rows that match on the key but
  not the rule), and the counts equal what dplyr returns.
  [`sv_join_diagnostics()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_join_diagnostics.md)
  has a new `rule` argument, and the gadget, the saved widget and
  duckdb/arrow cards all agree.
- **Strict** (a checkbox on the join step) adds `relationship =` and
  `unmatched =` arguments taken from the join check, so the join stops
  with dplyr’s own error if the data changes under it. Strict is R-only
  for duckdb and arrow tables. The check looks at the two original
  tables, so Strict applies only to a join on them: when an earlier step
  on the left table changes its rows (a filter, another join, a summary,
  a pivot), or the right table has steps of its own, the checkbox is
  greyed with the reason, keeps its setting, and the code is the plain
  join.
- **Under a rule, `na_matches = "never"`.** sideview writes
  `na_matches = "never"` on every rule join (dplyr’s default would match
  `NA` to `NA`), so a key that is `NA` never matches another `NA` and
  the key check counts them the same way when a rule is set.
- **Saved workspaces** keep the rule and the Strict flag. A workspace
  saved with a rule and opened in a 0.3.x install loses the rule
  silently (0.3.x ignores unknown fields).
- **Known differences.** The saved widget drops fractions of a second
  from date-times, so a boundary that falls inside a second can differ
  from R. The generated duckdb code for a date-time window uses the
  session time zone when the ICU extension is loaded, so with a non-UTC
  `TimeZone` setting a boundary can move. Running the code in R on a
  mixed arrow/data-frame and duckdb chain may leave temporary `dbplyr_*`
  tables on your connection until it closes.
- **lubridate for duckdb date-time windows.** On a duckdb table, the
  code for a window on a date-time column writes
  [`lubridate::days()`](https://lubridate.tidyverse.org/reference/period.html),
  so run it with lubridate installed (it is in Suggests; Date and
  numeric windows do not need it).

### Big tables: full data for arrow and duckdb cards

Arrow tables, datasets and queries and duckdb tables
([`dplyr::tbl()`](https://dplyr.tidyverse.org/reference/tbl.html)) used
to keep only their first 50 rows, so a sort, a join check or a codebook
looked complete when it was not. They now use the whole table.

- **Sort, filter and scroll** run in duckdb on the whole table. The
  header shows the true row count.
- **Join check, column inspector and codebook** profile the whole table
  in duckdb; only summaries come back into R, and the table is never
  collected. Results equal the in-memory ones.
  [`sv_join_diagnostics()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_join_diagnostics.md)
  accepts duckdb and Arrow tables,
  [`sv_column_profile()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_column_profile.md)
  has a new `column` argument for them, and
  [`sv_codebook()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_codebook.md)
  accepts them and has a `progress` argument. Arrow tables go through a
  private duckdb connection that closes with the session.
- **The codebook has a new column, `rows_profiled`,** after `n`. `n` is
  the table’s true row count and `rows_profiled` is how many rows the
  profile used. They are equal except for a preview-only card.
- **The canvas says what it used.** Without duckdb, or when the link to
  a table is lost, the card header reads “First 50 of N rows” and the
  checks say “Based on the first 50 rows”. A toast explains a lost link,
  and a codebook shows its progress (“Profiling visits_db: column 40 of
  200”).
- **Generated code stays lazy** and ends in one `collect()`. Joins
  across duckdb, arrow and data frames are written so they run, a
  “contains” filter is `stringr::str_detect(col, "<escaped literal>")`
  (stringr is in Suggests), and a reshape on arrow collects first. If
  **Run in R** fails, the message adds “This step may need data in R:
  move collect() above it.”
- Auto Map, the Discrepancy tab’s value comparison and the copilot’s
  schema summary still use the preview (the copilot is told the true row
  count). Auto Map suggestions and the discrepancy summary say so
  (“Based on the first 50 rows”), and so does the auto-clean button.
  Nothing is sent to the model but the schema.
- Fixed: the gadget toolbar now has the **Auto Map** button (R answered
  the request, but there was no button). The saved widget drops it,
  since it needs R. When nothing is found, a toast says “No suggested
  joins found”.
- Fixed: with duckdb 2.0, a `>`, `>=`, `<`, `<=` or `=` filter on an
  Arrow date-time column with a time zone matched no rows. duckdb 2.0
  turns that comparison into a filter inside the Arrow scan, which loses
  every row.
- Fixed: a BIGINT column (what duckdb gives `count()` and
  [`range()`](https://rdrr.io/r/base/range.html)) made the lazy join
  check, filters and “contains” fail.
- Fixed: an Arrow factor sorts by its levels, not its text, and keeps
  its class and its time zones in the gadget’s inspector and codebook.
- Fixed: a filter value that is not a valid value for the column
  (`"yes"` on a logical, `"abc"` on a date) matches no rows, as on a
  data frame, instead of failing.
- Fixed: card headers and printed cards write counts as `200,000`, not
  `200000` or `2e+05`; a widget codebook gives a lazy card’s true row
  count as `n`.
- Fixed: a duckdb table whose name holds `"` or `\` gets code that
  parses; a saved state never holds a card’s lazy table.
- Sorted and scrolled windows on a big table are faster: duckdb returns
  only the rows shown (a sorted window of 5,000,000 rows takes under 0.3
  s).

Known differences from an in-memory card:

- “Contains” on a number matches its text. The grid filter drops a
  trailing `.0`, but in generated code duckdb writes a double as
  `"130.0"` where R writes `"130"`, and float noise or scientific
  notation can differ.
- A POSIXct value at exactly midnight, and `-0`, can print differently.
- Join keys of different types compare as text; double keys compare
  exactly; an in-memory POSIXct key is compared as text where a database
  key is compared as an instant.
- Arrow time-zone offsets are computed for 1900 to 2100, so local times
  outside that range may be off. duckdb `TIMESTAMPTZ` columns show in
  UTC. duckdb ordered factors report class `"factor"`.
- Joining arrow with duckdb copies the arrow side into a duckdb
  temporary table
  ([`arrow::to_duckdb()`](https://arrow.apache.org/docs/r/reference/to_duckdb.html)
  then
  [`dplyr::compute()`](https://dplyr.tidyverse.org/reference/compute.html)),
  which uses memory. A data frame joined into duckdb is copied as
  `sideview_<table>`.
- duckdb 1.4.3 can crash when it scans an arrow factor column that
  contains `NA`. sideview decodes these columns itself, but generated
  code that calls
  [`arrow::to_duckdb()`](https://arrow.apache.org/docs/r/reference/to_duckdb.html)
  on one may hit it: convert the factor to character first.
- Two duckdb tables on different connections cannot be join-checked. A
  saved or embedded widget has no R session, so lazy cards there show
  the preview.

### Other changes

- The copilot chat keeps a reply in order: text written after the code
  now appears below the code instead of above it.
- A join step in the Pipeline tab keeps its join type, move and delete
  buttons on one line in a narrow drawer; the key check stays on the
  line below.
- The column inspector shows summary numbers to about four significant
  digits (5.338, not 5.33789). The profile and the codebook keep full
  precision.

## sideview 0.3.0

CRAN release: 2026-11-08

A full pass over the user interface, tested in a real browser and in
RStudio (dialog, Viewer pane, external browser, the addin, a saved HTML
file and a Quarto page), plus new features for clinical data work.

### New features

- **Pipeline with history.** Each sort, filter, join, rename, recode,
  mutate, reshape or summarise is a step in the drawer’s Pipeline tab.
  Steps can be turned off, reordered or deleted, with undo/redo
  (`Ctrl+Z` / `Ctrl+Y`) and a choice of `%>%` or `|>`. The drawer has
  real builder tabs: Join, Filter (several conditions, AND/OR), Arrange,
  Mutate, Recode, Reshape and Summarise.
- **Join diagnostics before you join.** Connecting two columns shows the
  match rate in each direction, unmatched keys with examples, the key
  relationship (1:1, 1:m, m:m warning), rows produced by each join type,
  and NA, spacing or case problems in the keys. Also available as
  [`sv_join_diagnostics()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_join_diagnostics.md).
- **Column inspector and codebook.** Click a column’s inspect icon for
  type, missingness, distinct values, a key check, summary statistics or
  top levels and a histogram. **Export codebook** writes a data
  dictionary for every card;
  [`sv_column_profile()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_column_profile.md)
  and
  [`sv_codebook()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_codebook.md)
  do the same from R.
- **Save and open the workspace** from the toolbar.
  `sideview(..., state =)` and `sideview_widget(..., state =)` restore
  card positions, zoom, sorts, filters, joins and the pipeline, and
  `sv_load_state(launch = TRUE)` now really launches.
- **Canvas navigation.** A minimap (bottom-left; `M` hides it), `Ctrl+K`
  to find a card or column, and double-click a card title to zoom to it.
  **Fit** and **Arrange** buttons, and a tidy grid layout at launch.
- **Themes.** `theme = "auto"` (follows RStudio or the browser),
  `"light"`, `"dark"`,
  [`sv_theme()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_theme.md)
  or a
  [`bslib::bs_theme()`](https://rstudio.github.io/bslib/reference/bs_theme.html).
  Every text colour meets WCAG AA contrast.
- **Keyboard and accessibility.** Shortcuts (`?` lists them), real
  buttons with labels and visible focus rings, and the OS “reduce
  motion” setting is respected.
- [`sv_llm_models()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_llm_models.md)
  lists the models an Ollama or OpenAI-compatible server offers. AI
  errors now say how to fix them, and `options(sideview.llm_think)`
  controls Ollama reasoning models. See
  [`?sideview`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)
  for all options.

### Bug fixes

- `viewer = "browser"` works again. Closing or reloading the tab no
  longer leaves the console busy or kills the app
  (`options(sideview.session_grace)`).
- Sort and filter now run on the full data, not just the first 500 rows
  shown. Sort code used `%>` instead of `%>%`.
- Column headers stay put while a table scrolls, so splines stay
  attached. Maximize, minimize, fullscreen (including in the Viewer
  pane) and card resize now behave; the toolbar, palette, drawer and AI
  bar no longer overlap at any window size.
- Click-to-connect no longer starts a stray second connection;
  sort/filter clicks no longer also connect columns; drawer tabs show
  their own content.
- **Done** returns the generated code and **Cancel** returns `NULL`;
  “Run in R” keeps its result in a named object (`sv_result` by
  default), in the environment
  [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)
  was called from (new `env` argument; the workspace when called from
  the console).
- Card and column names are escaped everywhere, so odd names cannot
  break the page.
- Recode and auto-clean emit
  [`dplyr::case_when()`](https://dplyr.tidyverse.org/reference/case-and-replace-when.html)
  (`case_match()` is deprecated in dplyr 1.2).
- A saved or embedded widget hides buttons that need an R session.
- A widget in Quarto or R Markdown no longer stops the page from
  scrolling or restyles the host page.
- Emoji icons are replaced by inline SVG icons that render the same
  everywhere.

### Internal

- One `sideview-core` HTML dependency with a content-based version, so
  browsers never use stale JavaScript or CSS. The bundled pan/zoom code
  is now honestly named `sv-panzoom.js`.
- New real-browser test suite (`tests/testthat/test-layout-browser.R`,
  run with `NOT_CRAN=true`) checks layout and behaviour with real mouse
  and keyboard input.

## sideview 0.2.0

#### Pillar 1: Big Data Scalability & CRAN Readiness

- **DOM Virtualization Engine**: Added `VirtualTable` in `sideview.js`
  and `sideview.css`, bounding active table DOM nodes to ~30 rows with
  dynamic spacer elements and supporting 100k+ rows at 60 FPS scrolling.
- **Arrow & DuckDB Lazy Ingestion**: Added zero-copy schema extraction
  methods (`sv_normalize.arrow_table()`, `sv_normalize.Dataset()`,
  `sv_normalize.tbl_duckdb_connection()`) with soft-dependency guards in
  `Suggests:`.
- **Multi-Key Composite Joins**: Enhanced
  [`sv_code_join()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_join.md)
  and server reactivity to support vector keys
  (`by = c("key1" = "key1", "key2" = "key2")`) and relational
  multi-table pipeline chaining.

#### Pillar 2: Advanced Visual Wrangling & Profiling

- **Visual Pivoting Codegen**: Added
  [`sv_code_pivot_longer()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_pivot_longer.md)
  and
  [`sv_code_pivot_wider()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_pivot_wider.md)
  with full syntactic backtick escaping and custom `values_fn`
  aggregation.
- **Group & Summarize Builder**: Added
  [`sv_code_group_summarize()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_group_summarize.md)
  generating reproducible
  `dplyr::group_by(...) %>% dplyr::summarise(..., .groups = 'drop')`
  workflows.
- **Header Column Profiling**: Embedded inline SVG 5-bin distribution
  sparklines (`<svg class="sideview-sparkline">`), categorical frequency
  distribution bars (`.sideview-cat-profile`), and color-coded
  missingness badges (`.sideview-na-badge`) with 25k-sample performance
  optimization.

#### Pillar 3: Canvas State Persistence & Cloud Sharing

- **State Serialization APIs**: Added
  [`new_sideview_state()`](https://lauyeehow1986-hub.github.io/sideview/reference/new_sideview_state.md),
  [`sv_save_state()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_save_state.md),
  and
  [`sv_load_state()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_load_state.md)
  supporting both portable `.json` and native R `.rds` workspace
  serialization for canvas pan/zoom, card coordinates, splines, and
  pipelines.

#### Pillar 4: Intelligent Copilot & Auto-Mapping

- **Heuristic Foreign Key Detection**: Added
  [`sv_suggest_mappings()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_suggest_mappings.md)
  computing 3-part composite scores (name similarity with ID suffix
  detection, type compatibility, and Jaccard overlap) with precomputed
  unique sets and logical column exclusion.
- **Suggested Splines & Discrepancy Auto-Clean**: Added animated dashed
  suggested splines (`.sideview-spline-suggested dashMove`) with
  click-to-accept join mapping, and
  [`sv_auto_clean_rules()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_auto_clean_rules.md)
  /
  [`sv_code_auto_clean()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_auto_clean_rules.md)
  for automatic
  [`dplyr::case_match()`](https://dplyr.tidyverse.org/reference/case_match.html)
  crosswalk synthesis.
- **Conversational AI Copilot Drawer**: Added multi-turn chat tab with
  context retention
  ([`sv_build_chat_prompt()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_build_chat_prompt.md)),
  turn-based history sliding window (20 turns), and active pipeline code
  guards.

#### Pillar 5: Automated Computer Use & GUI Verification

- **Automated GUI Test Suite**: Added
  `tests/testthat/test-computer-use-gui.R` and headless DOM test runner
  `gui-test-runner.js` verifying 6 core interaction scenarios (canvas
  coordinates, dragging, port click / spline connect, suggested spline
  acceptance, sorting/filtering, drawer action dispatch) with diagnostic
  dumps in [`tempdir()`](https://rdrr.io/r/base/tempfile.html).

## sideview 0.1.0

### Recent Features & Enhancements

#### Interactive Canvas & Navigation

- **Dual Synchronized Scrolling**: The sync scroll feature (`[🔗]` link
  icon in card headers) now synchronously locks both vertical rows
  (`scrollTop`) and horizontal columns (`scrollLeft`) in proportional
  lockstep across wide datasets.
- **Interactive Column Spline Disconnection**:
  - Hovering over any connection spline displays a red highlight glow.
  - Direct click or right-click on any spline or connection port
    immediately removes the connection.
  - Shiny reactivity now dispatches `column_disconnected` to dynamically
    update code generation and downstream operations.
- **Port State Reset & Clearing**: Enhanced `clearOperations()` to
  reliably purge active connecting port states (`this.activePort`) and
  strip visual `.connecting` classes when resetting the canvas.
- **Table Card Snapping & Dragging**: Improved magnetic guideline
  alignment when dragging cards near each other.
- **Syntax Validation Suite**: Added automated Node.js syntax parsing in
  `tests/testthat/test-assets.R` to ensure zero runtime script syntax
  errors.

#### Data Manipulation & Code Generation

- **Interactive Column Sorting**:
  - Tri-state toggle on column header sort indicators (`▲` Ascending,
    `▼` Descending, `original`).
  - Live in-memory row reordering across table cards.
  - Synthesizes and previews corresponding
    [`dplyr::arrange()`](https://dplyr.tidyverse.org/reference/arrange.html)
    pipelines in the Action Drawer.
- **Interactive Column Filtering**:
  - Floating popover activated by column filter icon (`🔍`).
  - Supports numeric comparisons (`>`, `>=`, `<`, `<=`), exact matches
    (`==`, `!=`), and text substring filters (`contains`).
  - Filters rows in real time and synthesizes
    [`dplyr::filter()`](https://dplyr.tidyverse.org/reference/filter.html)
    pipelines.
- **Non-Syntactic Identifier Escaping**: Added client-side
  `escapeColIdentifier()` in `sideview.js` so column names with spaces
  or symbols (e.g. `Patient ID`, `Glucose (mg/dL)`) are safely wrapped
  in backticks across filter and arrange pipelines.
- **List-Column & Vector Safeguard**: Hardened HTML grid table rendering
  in
  [`sideview_ui()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_ui.md)
  to handle nested list-columns and vectors safely with a `[list]`
  placeholder, avoiding length \> 1 evaluation errors under R 4.2+.

#### Action Drawer & Workflow Controls

- **Four Execution Modes**:
  1.  `Insert Script`: Pastes code at the current cursor location in the
      active RStudio script document via
      [`rstudioapi::insertText()`](https://rstudio.github.io/rstudioapi/reference/rstudio-documents.html).
  2.  `Run & Exit`: Sends code to the R console and closes the gadget
      immediately.
  3.  `Run in R`: Evaluates code directly inside the current R
      environment (`.GlobalEnv`) with live row/column toast feedback.
  4.  `Run Console`: Previews and buffers code for the RStudio console.
- **Clearing Controls**:
  - Added a dedicated `Clear` button in the Action Drawer to reset all
    active splines, sort orders, and filters.
  - Added an `[✓] Auto-clear` toggle to automatically reset canvas
    interactions upon code insertion or copy.

#### LLM Assistance & Privacy Context

- **Local Ollama Integration**: Full support for local models such as
  `gemma4:26b` and `llama3.2` with zero data leakage
  (`http://localhost:11434`).
- **Cloud OpenAI-Compatible Support**: Connect to OpenAI, OpenRouter,
  Groq, LM Studio, or vLLM.
- **Privacy-Safe Schema Synthesis**: Prompts contain table names, column
  types, and high-level distribution ranges without exposing
  confidential raw records.

#### Testing & Verification

- **705 Automated Tests**: Full test suite across 9 contexts with 100%
  pass rate covering universal normalization, codegen, LLM prompts,
  RStudio bridges, reactive gadget events, HTML widgets, and static
  asset syntax.

------------------------------------------------------------------------

## sideview 0.1.0

- Initial release of **`sideview`**: Multi-Table 2D Infinite Canvas for
  interactive data exploration, visual field mapping, and LLM-assisted
  Tidyverse code generation.
- Universal S3 normalization engine
  ([`sv_normalize()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_normalize.md))
  supporting `data.frame`, `tibble`,
  [`base::table`](https://rdrr.io/r/base/table.html), `matrix`, `gt`,
  `flextable`, and `htmlwidgets`.
- Standalone self-contained HTML widget export via
  [`save_sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/save_sideview.md).
- Interactive Shiny Gadget and RStudio Addin
  ([`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md),
  [`sideview_addin()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_addin.md)).
