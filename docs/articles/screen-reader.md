# Using sideview with a screen reader

sideview was first built as a visual canvas. Since 0.8.0 it also has a
**list view** that reads top to bottom, and its checks print as plain
sentences in the console. This page says how to use both.

## How well is this tested

sideview 0.8.0 is **checked with automated WCAG tests (axe) and
real-browser keyboard tests; the NVDA script was run once in Edge with
NVDA 2026.2 (all 15 tasks as written; the RStudio dialog and Viewer pane
were not covered); not yet tested by blind users.** Please treat it as a
first step and tell us where it fails (see “Report a problem” below).

## Start in the list view

The list view shows the same tables as text in one column. Start in it
with the `view` argument or an option:

`# for one call`` `[`sideview`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)`(``patients``, ``visits``, view ``=`` ``"list"``)`` `` ``# for the whole session`` `[`options`](https://rdrr.io/r/base/options.html)`(``sideview.view ``=`` ``"list"``)`

You can also press the **List view** button in the toolbar at any time.
Switching is announced (“List view” or “Canvas view”) and focus moves to
the first heading of the list.

The single-key shortcuts of the canvas (F, T, D and so on) can get in
the way of a screen reader. They default to off in the list view. Turn
them off everywhere with the “Keyboard shortcuts” switch in the `?`
list, or at the start with:

[`options`](https://rdrr.io/r/base/options.html)`(``sideview.shortcuts ``=`` ``FALSE``)`

`Ctrl+K` and `Ctrl+Enter` always work.

## A reading tour by headings

In the list view, move by headings (H in NVDA and JAWS, or the rotor in
VoiceOver). The headings are:

1.  **Summary**: counts of tables, join steps and pipeline steps,
    whether code is ready, skip links, Save, Open and the keyboard
    shortcuts switch.
2.  **Tables**: one heading per table, for example “labs, 5,000 rows by
    3 columns, full table.” Under it, one line per column (name, label,
    kind, and the distinct and missing counts) with Sort, Filter and
    Inspect buttons, then the rows as a captioned table, 25 a page, with
    Previous rows, Next rows and Go to row. A page change is announced
    (“Rows 26 to 50 of 5,000.”) and focus stays on the button.
3.  **Join**: pick two tables and their key columns, read the join check
    as sentences, and add the join.
4.  **Merge SUPP**: for a SUPP– table, check and add the merge into its
    parent.
5.  **Transform**: the step builders: Filter, Arrange, Mutate, Recode
    and Summarise.
6.  **Pipeline**: the steps so far, each of which you can switch off,
    move or delete.
7.  **Code**: the generated R code, with Copy (and Insert, in the
    gadget; a Shiny module has no Insert).
8.  **Copilot**: present only when a language model is set up.

What you do in the list view makes the same code as the canvas does, and
a join made on the canvas shows in the list view’s Pipeline.

## Results as sentences in the console

The results of the checks print as sentences, not as lists of numbers.
For example:

`chk`` ``<-`` `[`sv_join_diagnostics`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_join_diagnostics.md)`(``patients``, ``visits``, by ``=`` ``"patient_id"``)`` ``chk`` ``# "Join of patients and visits by patient_id is one to many. ..."`` `` `[`sv_column_profile`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_column_profile.md)`(``patients``, ``"age"``)`` `[`sv_supp_check`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_supp_check.md)`(``ae``, ``suppae``)`` `[`sv_detect_discrepancies`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_detect_discrepancies.md)`(``patients``, ``"sex"``)`` `[`sv_suggest_mappings`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_suggest_mappings.md)`(``patients``, ``visits``)`` `` `[`unclass`](https://rdrr.io/r/base/class.html)`(``chk``)`` ``# the raw list, if you want the numbers`

[`sv_describe()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_describe.md)
writes one sentence for each table and one line for each column. It is
the text twin of looking at the cards:

`patients`` ``<-`` `[`data.frame`](https://rdrr.io/r/base/data.frame.html)`(`` `` id ``=`` ``1``:``6``,`` `` sex ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"M"``, ``"F"``, ``"F"``, ``NA``, ``"M"``, ``"F"``)``,`` `` age ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``40``, ``51``, ``62``, ``38``, ``45``, ``29``)`` ``)`` `[`sv_describe`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_describe.md)`(``patients``)`

A large duckdb or Arrow table is described from its summaries and is
never loaded into memory.

## Keyboard and low vision

If you can see the screen, at least in part, or cannot use a mouse, you
can use the canvas itself. Turn on the **Accessible canvas** switch:
press `?` and use the switch in the dialog, or start with it on.

`# for one call`` `[`sideview`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)`(``patients``, ``visits``, access ``=`` ``TRUE``)`` `` ``# an htmlwidget (sideview_widget() has no access argument)`` `[`sideview_widget`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md)`(``patients``, ``visits``, options ``=`` `[`list`](https://rdrr.io/r/base/list.html)`(``access ``=`` ``TRUE``)``)`` `` ``# for the whole session, the widget and save_sideview() included`` `[`options`](https://rdrr.io/r/base/options.html)`(``sideview.access ``=`` ``TRUE``)`

The argument or option only sets the starting state. The switch in the
`?` dialog changes it, and the browser remembers that choice, which wins
over R. With the switch off the canvas is unchanged.

With the switch on:

- The zoom never goes below 100%. Text is at least 16 px, every control
  is at least 24 by 24 px, the focus ring is 3 px, and a high-contrast
  colour set replaces the theme colours. Joins are 3 px wide with a dash
  pattern and an arrowhead each, so crossing joins can be told apart
  without colour.
- Each card is a Tab stop, in reading order. Inside a card, Tab reaches
  its buttons, one column header and its table body (“patients rows”),
  then the next card. On a card, Arrows move it 20 px (Shift+Arrows 100
  px), Alt+Arrows focus the nearest card, Enter goes to its first column
  header, and PageUp, PageDown, Home and End scroll its table. The view
  follows focus.
- On a column header, Left and Right move along the columns and Esc goes
  back to the card. `C` starts a join and Enter completes it on the
  column you have moved to (Esc cancels), Delete removes a join (a small
  menu if there are several), and `J` jumps to the joined column. Moves
  and joins are announced. The keys work with the single-key shortcuts
  off and never fire while you type.
- Windows High Contrast and “increase contrast” are followed even with
  the switch off.

Alt+Left is also the browser’s Back key. sideview cancels it for the
jump, but this has not yet been checked in Edge or in RStudio. If it
takes you back in your setup, the list view still gives you every join
and filter by keyboard, and please report it.

## Use a browser, not the RStudio pane

For a screen reader we recommend the gadget in a real browser:

[`sideview`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)`(``patients``, ``visits``, viewer ``=`` ``"browser"``, view ``=`` ``"list"``)`

The reason is what the tests can and cannot show. The keyboard and axe
tests run in a real browser, where the page has full keyboard and
assistive-technology support. How the RStudio Viewer pane and the
RStudio dialog pass keys and speech to a screen reader has **not been
measured**: we have not yet read them with a screen reader, so we make
no claim about them. Until that is done, use `viewer = "browser"`. The
saved HTML widget
([`save_sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/save_sideview.md))
opens in a browser too.

## Report a problem

If something is not read, is read wrongly or cannot be reached by
keyboard, please [open an accessibility
issue](https://github.com/lauyeehow1986-hub/sideview/issues/new?template=accessibility-feedback.yml).
Tell us your screen reader and its version, the browser or RStudio pane,
what you did and what you heard.
