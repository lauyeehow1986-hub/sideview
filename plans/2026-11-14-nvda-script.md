# NVDA script for the sideview list view (2026-11-14)

Manual screen-reader pass for the text-first list view. NVDA 2026.2 on Windows 11. Fifteen tasks; each has a
**Setup**, the **Keys** to press and the **Expected speech**. Expected sentences are the strings the code produces
(`sv-listview.js`, `sv-pipeline.js` `say*()`, `sideview.js` `announce()`; the R twins in `R/say.R` agree byte for
byte). Text in `<angle brackets>` is a variable part. NVDA adds its own words (role, state, "heading level 2",
"link", "button", "clickable") around these; the sentences below are what the page itself supplies.

Synthetic data only. Not for clinical use.

## Fixture

`tests/testthat/helper-nvda.R` defines `sv_nvda_fixtures()`:

| Table  | Rows | Columns | Notes |
|--------|------|---------|-------|
| DM     | 10   | STUDYID, DOMAIN, USUBJID (labelled "Unique Subject Identifier"), AGE, SEX | subjects SV-001-001 to SV-001-010 |
| AE     | 12   | STUDYID, DOMAIN, USUBJID, AESEQ, AETERM, AESEV (labelled "Severity/Intensity") | AESEV: MILD 6, MODERATE 3, SEVERE 3; one AE row is for SV-001-099, who is not in DM |
| SUPPAE | 7    | STUDYID, RDOMAIN, USUBJID, IDVAR, IDVARVAL, QNAM, QLABEL, QVAL | QNAM AETRTEM; one row (SV-001-098, AESEQ 99) has no AE row |
| labs   | 40   | STUDYID, USUBJID, LBSEQ, LBTESTCD, LBORRES, LBORRESU | row 30 is `SV-001`, `SV-001-010`, `30`, `BILI`, `55`, `U/L` |

## Launch (once per surface)

Run from the package root (`C:/src/sv-a11y`):

```r
devtools::load_all(".")
source("tests/testthat/helper-nvda.R")
fx <- sv_nvda_fixtures()
sideview(DM = fx$DM, AE = fx$AE, SUPPAE = fx$SUPPAE, labs = fx$labs, viewer = "browser")
```

- Browser pass: `viewer = "browser"` (Chrome or Edge).
- RStudio dialog pass: same call with `viewer = "dialog"`. Viewer pane pass: `viewer = "pane"`.
- Every task starts from a fresh launch unless it says "continue". Tasks 1 to 15 are meant to run in order in one
  session (they build on each other: the pipeline is empty after task 10, one step after task 11, two after task 12).
- Before a fresh pass, clear the stored shortcut choice: in the browser console run
  `localStorage.removeItem('sideview.shortcuts')` (the choice is kept per browser profile and changes the
  default in task 14).

Headless check that the fixture builds and the sentences below are right (no browser):

```r
devtools::load_all(".")
source("tests/testthat/helper-nvda.R")
fx <- sv_nvda_fixtures()
sv_describe(DM = fx$DM, AE = fx$AE, SUPPAE = fx$SUPPAE, labs = fx$labs)
print(sv_join_diagnostics(fx$DM, fx$AE, "USUBJID", x_name = "DM", y_name = "AE"))
print(sv_supp_check(fx$AE, fx$SUPPAE, "AE", "SUPPAE", rdomain = "AE"))
print(sv_column_profile(fx$AE$AESEV))
```

## Preamble

**Speech Viewer.** NVDA menu (NVDA+N), Tools, Speech Viewer. Tick "Show Speech Viewer on Startup" if you want it
every time. Clear it between tasks with its context menu or restart it; copy the text of each task's output from
the viewer's window (select all, Ctrl+C) into the results table.

**Browse mode basics used here.**

| Key | Does |
|-----|------|
| NVDA+Space | toggle browse mode and focus mode |
| NVDA+F7 | Elements List (Headings, Links, Form fields, Buttons) |
| H / Shift+H | next / previous heading |
| 2 / 3 | next heading of level 2 / 3 |
| K | next link |
| B | next button |
| F | next form field (the same key sideview uses for "fit"; the point of task 14) |
| T | next table; Ctrl+Alt+Arrows move by cell inside a table |
| Tab / Shift+Tab | next / previous focusable control |
| Enter / Space | activate |
| NVDA+Down Arrow | say all |

Speech in a live region (the "announcer") arrives after the key press, with no focus change. Record it in the
`speech text` column even when it comes after a focus announcement. "Polite" announcements wait for NVDA to stop
talking; errors are assertive.

**Recording format.** One row per task and surface. `result` is `pass`, `mismatch` or `n/a`. `speech text` is the
text copied from the Speech Viewer (trimmed to the relevant lines). `note` says what differed and whether it is
ours, NVDA's wording, or a known RStudio-pane limit.

| task | surface (browser / RStudio dialog / RStudio Viewer) | result | speech text | note |
|------|------|------|------|------|
| 1 | browser | | | |
| 1 | RStudio dialog | | | |
| 1 | RStudio Viewer | | | |
| ... | | | | |

---

## 1. Open the list view with the toolbar button

**Setup.** Fresh launch (canvas view, the default). Browse mode on.

**Keys.** B until NVDA says "List view" (the toolbar button; its name stays "List view" and its pressed state is
the toggle), or Tab from the page start. Press Enter.

**Expected speech.**
- On the button before pressing: `List view, toggle button, not pressed`.
- After Enter, the announcer: `List view`.
- Focus moves to the first heading: `Summary, heading level 2`.
- Reading on (Down Arrow): `4 tables, 0 join steps, 0 pipeline steps. No code yet.`

## 2. List headings (NVDA+F7) and find AE

**Setup.** Continue.

**Keys.** NVDA+F7, Headings radio. Down Arrow through the list; type `AE` in the filter box ("Filter by").
Escape; Enter on the AE entry to move there.

**Expected speech.** The tree, in order, level 2 then level 3 under it:
- `Summary`
- `Tables`
  - `DM, DM domain, 10 rows by 5 columns, full table.`
  - `AE, AE domain, 12 rows by 6 columns, full table.`
  - `SUPPAE, SUPPAE domain, 7 rows by 8 columns, full table.`
  - `labs, LB domain, 40 rows by 6 columns, full table.`
- `Join`
- `Merge SUPP`
  - `SUPPAE into AE, 1 QNAM`
- `Transform`
  - `Filter`, `Arrange`, `Mutate`, `Recode`, `Summarise`
- `Pipeline`
- `Code`
- `Copilot` only when an LLM is configured; the plain launch above has none, so it is absent.

Filtering on `AE` keeps the AE heading (and SUPPAE, whose text also contains "AE"). After Enter, NVDA reads
`AE, AE domain, 12 rows by 6 columns, full table., heading level 3`.

## 3. Jump to Tables with the skip link

**Setup.** Go back to the top of the list view (Ctrl+Home in browse mode, or Shift+H to the Summary heading).

**Keys.** K (next link) lands on `Skip to tables`; Enter.

**Expected speech.** On the link: `Skip to tables, link`. After Enter, focus is on the heading:
`Tables, heading level 2`. (The two other skip links are `Skip to join` and `Skip to code`.) The page address
does not change.

## 4. Read the AE column list

**Setup.** Continue (focus on the Tables heading).

**Keys.** H to the AE heading (3 for level 3). Down Arrow through the list items (each column is one list item,
followed by its Sort, Filter and Inspect buttons).

**Expected speech.** One item per column, `<name>[, <label>], <kind>[, <n> values][, <n> missing]`:
- `STUDYID, text, 1 values, 0 missing`
- `DOMAIN, text, 1 values, 0 missing`
- `USUBJID, text, 11 values, 0 missing`
- `AESEQ, number, 0 missing`
- `AETERM, text, 4 values, 0 missing`
- `AESEV, Severity/Intensity, text, 3 values, 0 missing`

Each is followed by `Sort <name> button`, `Filter <name> button`, `Inspect <name> button`. The distinct and missing
counts come from the card's header badges, so a card that holds only a preview would leave them out (not the case
for this fixture). The number of rows comes from the heading; "1 values" is the page's wording for a single value.

## 5. Go to row 30 of labs and read its cells with Ctrl+Alt+arrows

**Setup.** Continue. The `labs` section has Previous rows, Next rows, a status, "Go to row" and Go.

**Keys.** H to the `labs` heading. Tab to the `Go to row` edit field (focus mode switches on; NVDA says
`Go to row, edit, spin button` or similar), type `30`, Enter. Then NVDA+Space for browse mode, T to the
`labs rows` table, Ctrl+Alt+Down Arrow into the first body row, then Ctrl+Alt+Right Arrow across.

**Expected speech.**
- Announcer after Enter: `Rows 30 to 40 of 40.`
- The table is named `labs rows`; NVDA reports 41 rows (header plus 40) and 6 columns. The first body row is
  row 30, since the table shows rows 30 to 40.
- Across the first body row, with the column header spoken before each cell:
  `STUDYID SV-001`, `USUBJID SV-001-010`, `LBSEQ 30`, `LBTESTCD BILI`, `LBORRES 55`, `LBORRESU U/L`.
- Ctrl+Alt+Down Arrow reads row 31 (`SV-001`, `SV-001-001`, `31`, `CREAT`, ...).

## 6. Next page

**Setup.** Continue in labs. Put the page back at the start: in `Go to row` type `1`, Enter (announcer
`Rows 1 to 25 of 40.`).

**Keys.** Shift+Tab to `Next rows`, Enter.

**Expected speech.**
- Announcer: `Rows 26 to 40 of 40.`
- Because Next rows is now disabled, focus moves to its neighbour: `Previous rows, button`.
- The status text (read with NVDA+Tab or by arrowing) is `Rows 26 to 40 of 40.`

## 7. Inspect AESEV

**Setup.** Continue; go to the AE heading.

**Keys.** Tab through the AE column buttons to `Inspect AESEV`; Enter.

**Expected speech.**
- Announcer (first sentence): `AESEV, Severity/Intensity is a text column.`
- The profile appears under the column. Down Arrow reads, one paragraph each:
  `AESEV, Severity/Intensity is a text column.`
  `No values are missing.`
  `It has 3 distinct values.`
  `Most common values: MILD (6), MODERATE (3), SEVERE (3).`

## 8. Join DM to AE and hear the check

**Setup.** Continue; Shift+H or the skip link `Skip to join`.

**Keys.** At the `Join` heading, Tab to the group `Join two tables`. Set `Left table` to `DM` and `Right table` to
`AE` (focus mode; Down Arrow in the combo box). Tab to `Left column` and pick `USUBJID`, then `Right column`
`USUBJID`. Tab to `Check join`; Enter. Browse mode, read the result block.

**Expected speech.**
- While waiting: `Checking the join.`
- Announcer (first sentence): `Join of DM and AE by USUBJID is one to many.`
- The result, one paragraph each:
  `Join of DM and AE by USUBJID is one to many.`
  `10 of 10 DM rows match, 100.0 percent.`
  `11 of 12 AE rows match, 91.7 percent.`
  `1 row of AE has no match, for example keys SV-001-099.`
  `Rows by join type: left 11, inner 11, right 12, full 12, semi 10, anti 0.`
- `Add join step` is enabled only now. If a key is left unpicked, `Check join` instead says
  `Pick a left table, a right table and a column on each side first.`

## 9. Add join step and land on the step

**Setup.** Continue (check result showing).

**Keys.** Enter on `Add join step`.

**Expected speech.**
- Announcer: `Join step added. 1 step.` (and, when R's check lands, the first sentence again:
  `Join of DM and AE by USUBJID is one to many.`).
- Focus lands on the new step in the Pipeline section; NVDA reads its text:
  `DM left join AE on USUBJID` followed by the join check line.
- Summary now reads `4 tables, 1 join step, 1 pipeline step. Code is ready.`

## 10. Undo

**Setup.** Continue.

**Keys.** B / Tab to the Pipeline section's `Undo` button; Enter. (Ctrl+Z also works in focus mode when shortcuts
are on.)

**Expected speech.** Announcer: `Undone. 0 steps.` Summary: `4 tables, 0 join steps, 0 pipeline steps. No code yet.`

## 11. Merge SUPPAE into AE

**Setup.** Continue (pipeline empty).

**Keys.** H to the `SUPPAE into AE, 1 QNAM` heading under Merge SUPP. Tab to `Check SUPPAE`; Enter. Then Tab to
`Merge SUPPAE`; Enter.

**Expected speech.**
- Check: announcer `Merging SUPPAE into AE adds 1 column: AETRTEM.`; the result block reads
  `Merging SUPPAE into AE adds 1 column: AETRTEM.`
  `6 of 7 SUPPAE rows match a AE row.`
  `1 SUPPAE row has no AE row, for example SV-001-098 AESEQ 99.`
- Merge: announcer `SUPP merge step added. 1 step.` followed by the same first sentence
  `Merging SUPPAE into AE adds 1 column: AETRTEM.`
- The step appears in the Pipeline section. ("a AE row" is the page's wording.)

## 12. Add a filter

**Setup.** Continue.

**Keys.** H to the AE heading; Tab to `Filter AESEV`; Enter. Focus goes to the `Filter` builder heading and then to
its first empty field. In focus mode: `Table` `AE`, `Column` `AESEV`, `Operator` `==`, `Value` `SEVERE`. Tab to
`Add filter step`; Enter.

**Expected speech.**
- On opening: `Filter, heading level 3`, then the first empty field (`Value, edit`).
- After Enter: announcer `Filter step added. 2 steps.`
- The step reads `AE filter AESEV == "SEVERE"` in the Pipeline list (the exact R expression the builder writes).

## 13. Copy the code

**Setup.** Continue.

**Keys.** `Skip to code` link (K), Enter; then Tab to the `Copy` button; Enter. (The clipboard needs a secure
context: `localhost` or `127.0.0.1` is fine in the browser pass.)

**Expected speech.**
- On the link: `Skip to code, link`, then `Code, heading level 2`.
- `Copy, button`. After Enter: announcer `Code copied.`; the button text briefly reads `Copied!`.
- Paste into a text editor to confirm the clipboard holds the generated `dplyr` code with the join, the SUPP merge
  and the filter. In RStudio dialog and Viewer, where the clipboard may be blocked, the expected result is no
  announcement, which is recorded as a known limit rather than fixed.

## 14. Turn shortcuts off and press F in browse mode

**Setup.** Continue. The list view starts with shortcuts off (the default for the list view unless a stored choice
exists), so first turn them on, then off.

**Keys.** `Skip to tables` back to the top (Ctrl+Home), B/Tab to the `Keyboard shortcuts` switch (it is in the
Summary section). Press Space.

**Expected speech.**
- On the switch: `Keyboard shortcuts, switch, not checked` (or `checked` when on).
- Space once: announcer `Keyboard shortcuts on.` and `checked`.
- Space again: announcer `Keyboard shortcuts off.` and `not checked`.
- Then, in browse mode with focus not in a field, press F. NVDA must move to the next form field
  (`<field name>, edit` or `combo box`); there must be no `Fit` effect on the canvas and no change of speech
  beyond NVDA's own. Record whether the canvas zoom changed after returning to canvas view in task 15 (it
  must not have).

## 15. Switch back to the canvas view

**Setup.** Continue.

**Keys.** Ctrl+Home; B to the `List view` toggle (the Summary section's button or the toolbar one). It reads
`List view, toggle button, pressed`. Enter.

**Expected speech.** Announcer: `Canvas view`. Focus moves to the container (`sideview` canvas); the list view is
hidden from NVDA (`aria-hidden`), and the canvas cards are the visible content. Pressing the toggle again returns
to the list with `List view` and the heading `Summary, heading level 2`.

---

## Results (fill during the pass)

Copy the table from the preamble into `MEMORY.md` as the pass record. For a mismatch that is ours, fix it in its
owning file and add a test in `tests/testthat/test-a11y-browser.R`; RStudio-pane weaknesses are documented, not
fixed.

### Pass status (2026-11-14)

**Not run.** The reviewer declined computer-use access to NVDA, so its Speech Viewer could not be read and no
speech text was captured. No task above has a pass or mismatch result. The script is ready to run by hand
(or by a later session with NVDA access). The accessibility claim stays "checked with automated WCAG tests
(axe) and real-browser keyboard tests; NVDA script written but not yet run; not yet tested by blind users".
