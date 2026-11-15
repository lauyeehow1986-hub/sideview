# sideview text-first accessibility (list view, console, a11y tests): design

- **Date:** 2026-11-14
- **Release:** sideview 0.8.0, accessibility sub-projects **A** (text-first access, for blind users) and
  **C** (accessibility test harness). Sub-project B (keyboard and low vision) gets its own spec; D (0.9.0) and
  E (0.10.0) follow.
- **Status:** design approved in chat, section by section; awaiting review of this written spec
- **Builds on:** `plans/2026-10-25-lazy-full-data-design.md` (lazy twins), `plans/2026-10-31-sideview-proxy-design.md`
  (module, untrusted client), `plans/2026-11-03-cdisc-suppqual-merge-design.md` (SUPP check)

## 1. Problem

sideview's interface is a 2D pan-and-zoom canvas. Card positions, splines and the minimap carry meaning only
by sight, so a blind programmer gets little from the canvas however much ARIA it has. The parts that matter
to them (join checks, SUPP checks, column profiles, discrepancies, the pipeline and the generated code) do not
depend on the canvas, but today they are reached through it, or printed in the console as padded tables and
raw lists that are hard to follow with a screen reader.

## 2. What the user told us

- **Audience:** blind and low-vision programmers. Blind first (this spec); low vision in sub-project B.
- **Scope:** everything in the 0.8.0-0.10.0 roadmap, plus extra blind and low-vision features.
- **No blind tester is available.** Testing uses automated checks and NVDA driven by Claude (section 9).
- **List view placement:** (a) a toggle inside the same canvas container, not a separate app.
- **List view scope:** (a) full parity, reusing the drawer builders.
- **Console output:** (a) plain sentences for everyone, not an opt-in option.

## 3. Goals and non-goals

**Goals**
- A list view that reads top to bottom, in every mode (gadget, widget, saved HTML, module), from which a
  screen-reader user can do everything the canvas does except purely visual layout.
- One engine and one pipeline behind both views: a step added in one view is in the other.
- Results announced as one sentence in a live region, in both views.
- Single-key shortcuts that can be turned off (WCAG 2.1.4).
- Console output in plain sentences, and a new `sv_describe()`.
- An accessibility test harness that guards all of the above in CI.

**Non-goals**
- Card positions, splines, minimap, zoom, sync-scroll and column resizing in the list view.
- Sub-project B items (high contrast, `forced-colors`, dashes and markers, keyboard card moves, text size,
  reflow). The list view must not block them.
- Sonification (a later, optional `maidr` hand-off). A braille Unicode sparkline (rejected: screen readers
  read the glyphs as dot patterns; a braille display already shows the text summary).
- Detecting a screen reader automatically (not possible reliably; users opt in with `view =` or the option).

## 4. Architecture

- **Region:** `.sideview-listview`, inside the same `.sideview-container`, built and owned by
  `SideviewEngine`. Labelled region "sideview list view".
- **Toggle:** a toolbar button "List view" / "Canvas view" with `aria-pressed`, method `engine.setView(mode)`
  where `mode` is `"canvas"` or `"list"`.
- **Starting view:** `sideview(..., view =)`, `sideview_widget(view =)`, `save_sideview()` (through the widget)
  and `sideviewUI(view =)`, default `getOption("sideview.view", "canvas")`, validated with `match.arg`.
  The gadget carries it as `data-sv-view` on the container; the widget as `options.view`.
- **State:** the current view is the optional field `view.mode` in workspace state, without a schema bump
  (as `view.labels_row`). A state without it keeps the starting view. Restoring a state that has `view.mode` does
  not change the canvas restore: the saved zoom and pan still apply, and the first auto-fit is still skipped.
- **Hiding:** in list mode the canvas viewport, minimap, connector SVG and hit layer get `hidden` and
  `aria-hidden="true"`; in canvas mode the list view does. Switching back restores the canvas exactly.
- **Data:** the list view has no data path of its own.
  - Rows come from each card's `VirtualTable` (`getRowCount()`, `getCellValue()`, `requestBlock()` for remote
    and lazy cards), so a page follows the card's current sort and filter. Gadget and module rows come from R
    through `sideview_rows_request`; widget rows from the browser. No new R input.
  - Column summaries use the card's `col_types`, `col_labels` and sparkline stats; Inspect uses
    `column_profile_request` (gadget, module) or `SideviewPipeline.columnProfile()` (widget).
  - Join, date-rule and SUPP checks use `join_diagnostics_request` / `joinDiagnostics()` and
    `requestSuppCheck()` as today.
  - Steps go through the same `SideviewPipeline` calls the canvas uses, so undo/redo, the step count and code
    generation are unchanged. A join added in the list view calls the same connection path as the canvas, so
    its spline is drawn; a spline drawn on the canvas shows in the list view's Pipeline.
- **Drawer reuse:** in list mode the drawer's builder, Pipeline and Code panes are moved (the same DOM nodes)
  into the list view's Transform, Pipeline and Code sections, and moved back on return. Handlers are delegated
  on the container, so they keep working; there is always exactly one copy. The drawer shell is hidden in
  list mode.
- **Module security:** unchanged. The list view sends only inputs the canvas already sends and names only cards
  in the R store. Buttons that are not rendered in a module (Insert Script, Run & Exit, Run in R, Run Console)
  are not rendered in the list view either. Without `llm_fn` the Copilot section is absent.
- **Twin rule:** the sentences for join, SUPP and profile results have one formatter in R and one in JS
  (section 7), held byte-equal by a test.

## 5. List view contents and reading order

Skip links first: "Skip to tables", "Skip to join", "Skip to code". Each section is an `<h2>`, each item an `<h3>`.

1. **Summary.** One sentence, e.g. "4 tables, 2 join steps, 5 pipeline steps. Code is ready." Then the view
   toggle, Save and Open, and the "Keyboard shortcuts: on/off" switch.
2. **Tables.** One `<h3>` per card: name, domain if tagged, rows by columns, and the rows basis, e.g.
   "AE, adverse events domain, 1,204 rows by 12 columns, full table" or "... preview of the first 50 rows".
   - **Columns:** a list, one item per column, e.g. "AESEV, Severity, text, 3 values, 0 missing", with Sort,
     Filter and Inspect buttons. Inspect writes the profile sentences under the item. A table with more than
     30 columns shows its column list in a `<details>` element that starts closed, so the heading list stays
     short.
   - **Rows:** a real `<table>` with `<caption>`, `<th scope="col">`, `aria-rowcount` = true row count and
     `aria-rowindex` on each row = its position in the whole (sorted, filtered) table. 25 rows a page, Previous
     and Next buttons, and a "Go to row" number input. A missing value shows as `NA`, as on the canvas. A page
     change announces "Rows 26 to 50 of 1,204". A table with 0 rows says "No rows" and has no pager.
3. **Join.** A form: left table, left column, right table, right column, "Add another key pair" for multi-key
   joins, an optional date rule (the canvas calendar's kinds), and the join type. "Check join" writes the result
   sentences into the section and announces the first one; "Add join step" is enabled after a check. Auto Map
   suggestions are listed, each with "Add" (a CDISC group adds as one join, one undo step).
4. **Merge SUPP.** One item per SUPP card with a parent on the canvas, e.g. "SUPPAE into AE, 2 QNAMs", with
   Check (sentences) and Merge. "Merge needs refreshing" is announced. A SUPP card whose parent is absent says
   so and has no buttons.
5. **Transform.** The drawer builders (Filter, Arrange, Mutate, Recode, Reshape, Summarise) as `<h3>`
   subsections.
6. **Pipeline.** The existing step list (toggle, move, delete), undo and redo.
7. **Code.** The read-only code area, Copy, Insert / Run where allowed, the `%>%` / `|>` choice.
8. **Copilot.** Only when an LLM is available. Replies are announced.

Card and column names are escaped before `innerHTML`, and `CSS.escape` is used in selectors, as everywhere.

## 6. Announcements and keyboard

**Live region.** One per engine, `.sideview-announcer`, `aria-live="polite"`, present in both views. A small
queue spaces messages so they do not overwrite each other, and repeats of the same text are spoken again.
It announces:
- a finished check: the first sentence of `sayJoin()` / `saySupp()` / `sayProfile()`;
- a step added, removed, undone or redone: "Join step added. 3 steps.";
- code copied or inserted;
- a page change in a rows table;
- a toast (error toasts use `role="alert"` instead);
- a copilot reply: "Copilot replied, 6 lines of code.";
- a view switch: "List view" / "Canvas view".

**Shortcuts switch (WCAG 2.1.4).** Single-key shortcuts (F, 0, +/-, T, D, M, L, /, ?) can be turned off.
The switch is stored per browser in `localStorage` (guarded with try/catch), and `options(sideview.shortcuts =
FALSE)` turns them off from R (carried as `data-sv-shortcuts` / `options.shortcuts`). In list view they are off
by default, because NVDA's browse mode uses the same letters. `Ctrl+K` and `Ctrl+Enter` stay on. The `?` dialog
lists the switch.

**Focus.** After a check, focus stays where it was. After "Add join step", focus moves to the new step in the
Pipeline list. After a view switch, focus moves to the new view's first heading (list) or the container
(canvas). After a page change, focus stays on the pager button.

**Controls.** Real `<button>`, `<select>` and `<input>` elements with visible labels, at least 24 by 24 CSS px.

## 7. Console

**Sentence formatters** (internal, return a character vector, one sentence per element):

| Result | R | JS twin (`SideviewPipeline`) |
|---|---|---|
| `sv_join_diagnostics()`, in-memory and lazy, with date rules | `sv_say_join()` | `sayJoin()` |
| `sv_supp_check()`, in-memory and lazy | `sv_say_supp()` | `saySupp()` |
| `sv_column_profile()`, in-memory and lazy | `sv_say_profile()` | `sayProfile()` |

Rules: numbers with `big.mark = ","`; percentages with one decimal; at most 3 sample keys ("for example P05,
P09, P12, and 7 more"); a missing value is "missing" in sentences; plain ASCII apart from data values; one fact
per sentence; lines at most about 100 characters apart from data values. Example: "Join of patients and visits
by patient_id is one to many. 140 of 150 patients rows match, 93.3 percent. 10 patients rows have no match,
for example P05, P09, P12, and 7 more."

**Print methods**
- `print.sv_join_diagnostics()` is rewritten on `sv_say_join()`.
- `sv_column_profile()` and `sv_supp_check()` (plain lists today) get classes `sv_column_profile` and
  `sv_supp_check` and print methods, in the in-memory and lazy versions alike. The Shiny handlers send
  `unclass(x)`, so the JSON to the browser is unchanged (tested).
- `sv_detect_discrepancies()` returns a list: it gets class `c("sv_discrepancies", "list")`, and `unclass()`
  gives the plain list. `sv_suggest_mappings()` returns a data frame: it gets `c("sv_mappings", "data.frame")`,
  and `as.data.frame()` drops the subclass. Both get sentence print methods, and the handlers send the plain
  object. NEWS: "prints as sentences; use `as.data.frame()` (mappings) or `unclass()` (discrepancies) for the
  raw object."
- `sv_codebook()` stays a plain data frame (deliverable for CSV/XLSX; byte-equal CSV test).

**`sv_describe(x, ..., n_levels = 5)`** (new export). Takes data frames, lazy tables or `sideview_card`s.
One sentence per table (name, domain if tagged, rows, columns, how many columns have missing values), then one
line per column: name, label, type; numbers: missing, distinct, min, median, max; text: missing, distinct and
the top `n_levels` values with counts. Built on `sv_column_profile()`, so lazy tables are never collected.
Returns the lines invisibly as class `sv_description` (with a print method), so they can be written to a file.

## 8. Errors and edge cases

- **Lost lazy link:** the existing fallback toast is announced, and the table heading changes to "preview".
- **Check error** (a missing column, a date rule that does not hold, a type clash): the error sentence is
  written and announced; "Add join step" stays disabled.
- **View switch during a pending check:** the reply still lands in the right section (sections are found by
  card name, not by focus).
- **Card added, replaced or removed** (module verbs, Open): the list view re-renders that table's section only
  and announces "Table labs replaced."
- **No cards:** the Tables section says "No tables yet."
- **Widget without R:** everything works from the browser twins; Run buttons are absent as today.

## 9. Test harness (sub-project C, built first)

**Accessibility-tree checks** (`tests/testthat/test-a11y-browser.R`, chromote, skipped on CRAN). Uses
`Accessibility.getFullAXTree` and asserts facts, not full snapshots:
- every button, input and select has a non-empty accessible name;
- list view headings are h2 then h3 in section 5 order;
- each rows table's `aria-rowcount` equals the card's true row count;
- in list view no canvas node is in the tree, and in canvas view no list node is;
- the live region text after a join check equals the first sentence of `sv_say_join()` for the same tables;
- focus lands as section 6 says.

**Keyboard-only walkthrough** with real key events (`Input.dispatchKeyEvent`): open list view, add a join, a
filter and a SUPP merge with Tab, Shift+Tab, Enter, Space and arrows only; the code parses and equals the code
the canvas gives for the same steps. With shortcuts off, F, T and D do nothing.

**axe-core.** Not bundled. The tests look for `axe.min.js` via `SV_AXE_PATH` or a local `node_modules`, and
skip when it is missing. CI installs a pinned `axe-core` with npm in R-CMD-check. Rules: WCAG 2.2 A and AA tags,
0 violations, on canvas and list view, light and dark, 1360x820 and 375x812, gadget, widget and module. Any
accepted rule is listed in the test file with its reason.

**Sentence twins** (`tests/testthat/test-say.R`): R and JS formatters give byte-equal strings on shared
fixtures (node runner, skipped without Node.js); lazy results give the same sentences (test-lazy.R).

**Console tests:** each print method's output against expected lines; ASCII-only and line-length rules;
`sv_describe()` on a data frame, a duckdb table and an arrow table gives the same lines.

**NVDA script** (`plans/2026-11-14-nvda-script.md`): about 15 tasks with the expected speech (open list view,
find AE by heading, read row 30, join DM to AE and hear the result, merge SUPPAE, copy code, ...). Claude runs
it with computer use and NVDA's Speech Viewer, in Chrome or Edge in browser mode, plus one pass in RStudio's
dialog and Viewer pane. The spoken text and any mismatches go into `MEMORY.md`. Weaknesses in RStudio's panes are
documented, and the docs recommend browser mode to screen-reader users.

**Honesty:** NEWS, the README and the new article say "checked with NVDA and automated WCAG tests; not yet
tested by blind users". A GitHub issue template, "Accessibility feedback", asks for the screen reader and
browser used.

## 10. Delivery

| PR | Contents |
|---|---|
| C | Harness and checks for today's features (failing checks for current gaps are fixed or listed with reasons) |
| A1 | `sv_say_*` twins, print methods, classes, `sv_describe()` |
| A2 | Live region, shortcuts switch, table ARIA on canvas cards, toasts as alerts |
| A3 | List view, `view =` arguments, `view.mode` state field |
| A4 | Article "Using sideview with a screen reader", NVDA pass, NEWS, README, issue template |

Each PR updates `NEWS.md`, `MEMORY.md` and, where it adds inputs, messages, rules or options, `CLAUDE.md`.
The new export goes into `_pkgdown.yml`. CLAUDE.md gains a standing rule: every new feature (D, E and later)
must work in the list view and print as sentences in the console.

## 11. Review focus (likely to bite, not covered by a happy path)

1. A sort or filter applied on the canvas, then a page read in the list view: the rows must be the sorted,
   filtered ones, with `aria-rowindex` from the filtered table.
2. A lazy card in the gadget: paging must fetch row windows from R and never collect the table.
3. Moving drawer panes into the list view and back: a builder half filled in keeps its input, and no handler
   fires twice.
4. Names with `<`, `"`, spaces or non-ASCII letters in headings, labels, captions and selectors.
5. The shortcuts switch: off in list view by default even when `localStorage` throws; typing in inputs never
   triggers a shortcut in either state.
