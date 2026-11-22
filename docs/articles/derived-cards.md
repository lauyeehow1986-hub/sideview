# Unmatched rows, stacking and comparing data cuts

A check on the canvas gives you counts. A **derived card** gives you the
rows behind them, as a card of its own, with code that rebuilds it.
Everything below uses small synthetic tables built in the page (no real
patients).

## Rows behind a count

A join check or a SUPP check offers buttons that open the rows behind
its counts: the rows of either table with no match, the rows a date rule
dropped, and the SUPP rows with no parent row or with an `IDVARVAL` that
does not convert. The card is named for what it holds
(`ae_unmatched_dm`) and is built by R from the tables as loaded, so a
duckdb or Arrow input stays lazy. From the console,
[`sv_unmatched()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_unmatched.md)
and
[`sv_supp_orphans()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_supp_orphans.md)
return the same rows.

`dm`` ``<-`` `[`data.frame`](https://rdrr.io/r/base/data.frame.html)`(``USUBJID ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"S-01"``, ``"S-02"``, ``"S-03"``)``, AGE ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``34``, ``51``, ``62``)``)`` ``ae`` ``<-`` `[`data.frame`](https://rdrr.io/r/base/data.frame.html)`(``USUBJID ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"S-01"``, ``"S-02"``, ``"S-09"``)``, AESEQ ``=`` ``1L``,`` `` AETERM ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"Headache"``, ``"Nausea"``, ``"Rash"``)``)`` `[`sv_unmatched`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_unmatched.md)`(``ae``, ``dm``, by ``=`` ``"USUBJID"``)`` ``#> USUBJID AESEQ AETERM`` ``#> 1 S-09 1 Rash`

[`sideview`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)`(``dm``, ``ae``)`` ``# connect USUBJID to USUBJID, then use the buttons on the join check`

## Stacking tables

[`sv_stack_check()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_stack_check.md)
lines up the columns of 2 to 8 tables and reports, per column, its type
in each table and what a stack would do: the same type, a cast to a
common type, a name that differs only by case offered as a rename, and a
column missing from some tables. Nothing changes until you pick a fix.
[`sv_stack()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_stack.md)
stacks the tables with the check’s fixes, adds a `source` column naming
each row’s table, and turns a value that cannot be cast into `NA`.

`wave1`` ``<-`` `[`data.frame`](https://rdrr.io/r/base/data.frame.html)`(``ID ``=`` ``1``:``2``, AGE ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``40L``, ``52L``)``)`` ``wave2`` ``<-`` `[`data.frame`](https://rdrr.io/r/base/data.frame.html)`(``ID ``=`` ``3``:``4``, Age ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``61``, ``47``)``)`` ``chk`` ``<-`` `[`sv_stack_check`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_stack_check.md)`(``wave1 ``=`` ``wave1``, wave2 ``=`` ``wave2``)`` `[`sv_stack`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_stack.md)`(``wave1 ``=`` ``wave1``, wave2 ``=`` ``wave2``, check ``=`` ``chk``)`` ``#> source ID AGE Age`` ``#> 1 wave1 1 40 NA`` ``#> 2 wave1 2 52 NA`` ``#> 3 wave2 3 NA 61`` ``#> 4 wave2 4 NA 47`

In the gadget, the drawer has a **Stack** tab: pick tables, Check,
change a fix, and **Open** adds the stacked table as a card.

## Comparing data cuts

`sv_compare(old, new, by)` matches the rows of two cuts of a table on a
key and counts the rows **added** (key only in `new`), **removed** (key
only in `old`) and **changed** (key in both, a value differs). It also
lists columns that were added, removed or changed type, and the changed
values by column. Nothing is modified.

`ae_old`` ``<-`` `[`data.frame`](https://rdrr.io/r/base/data.frame.html)`(``USUBJID ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"S-01"``, ``"S-02"``, ``"S-03"``, ``"S-04"``)``, AESEQ ``=`` ``1L``,`` `` AETERM ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"Headache"``, ``"Nausea"``, ``"Rash"``, ``"Cough"``)``,`` `` AESEV ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"MILD"``, ``"MODERATE"``, ``"MILD"``, ``"SEVERE"``)``,`` `` stringsAsFactors ``=`` ``FALSE``)`` ``ae_new`` ``<-`` `[`data.frame`](https://rdrr.io/r/base/data.frame.html)`(``USUBJID ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"S-01"``, ``"S-02"``, ``"S-04"``, ``"S-05"``)``, AESEQ ``=`` ``1L``,`` `` AETERM ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"Headache"``, ``"Nausea"``, ``"Cough"``, ``"Dizziness"``)``,`` `` AESEV ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"MILD"``, ``"SEVERE"``, ``"SEVERE"``, ``"MILD"``)``,`` `` stringsAsFactors ``=`` ``FALSE``)`

[`sv_compare`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_compare.md)`(``ae_old``, ``ae_new``, by ``=`` `[`c`](https://rdrr.io/r/base/c.html)`(``"USUBJID"``, ``"AESEQ"``)``)`` ``#> ae_old -> ae_new, key USUBJID + AESEQ`` ``#> Rows: 4 -> 4 added 1 · removed 1 · changed 1 · same 2`` ``#> Columns: added none · removed none · type changed none`` ``#> Changed values by column: AESEV 1`` ``#> added: 1 row`` ``#> removed: 1 row`` ``#> changed: 1 row`

Here `S-05` is new, `S-03` is gone, and `S-02` changed severity. In the
gadget, the drawer’s **Compare** tab does the same: pick the old and the
new table, Check, change the key if the suggestion is wrong (with no key
picked, a CDISC tag suggests one), and **Open** each set of rows as a
card: `ae_new_added`, `ae_old_removed` and `ae_new_changed` (the changed
rows carry the old and new value side by side). Each card is one
`derive` step whose R code is plain `dplyr`, and a duckdb or Arrow input
stays lazy.

[`sideview`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)`(``ae_old``, ``ae_new``)`` ``# open the drawer, choose the Compare tab`

The widget has no R, so it has no Compare tab; a saved compare step
stays in the code, with a notice that the table is not shown.
