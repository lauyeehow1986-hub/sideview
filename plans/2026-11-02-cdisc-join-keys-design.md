# sideview CDISC join keys: design

- **Date:** 2026-11-02
- **Release:** sideview 0.6.0, CDISC/pharmaverse sub-project B of A-F (see `MEMORY.md`, Backlog)
- **Status:** design approved in chat, section by section; awaiting review of this written spec
- **Builds on:** `plans/2026-11-01-cdisc-awareness-design.md` (the CDISC tag `card$cdisc`, the catalogue,
  `sv_cdisc_resolve()`), `plans/2026-10-31-sideview-proxy-design.md` (module mode, card store)

## 1. Problem

Since 0.5.0 sideview knows that `ae` is the Adverse Events domain and `adsl` is the subject-level analysis
dataset, but Auto Map still treats them as anonymous tables. Its heuristic scores column pairs by name, type
and value overlap, so between two CDISC datasets it offers noise (`DOMAIN` with `DOMAIN`, `STUDYID` on its
own) and never the composite key a clinical programmer actually joins by (`STUDYID + USUBJID + AESEQ`).
And when a user joins `ae` to `lb` by `USUBJID` alone, the join check says "many-to-many" without saying
why, or what key would fix it.

## 2. What the user told us

- **Activation:** through Auto Map only, made CDISC-aware. Nothing is drawn on load.
- **Modes:** the gadget and module mode (both have the Auto Map button and the R server). The htmlwidget has
  no Auto Map and gets nothing new.
- **Key kinds:** subject level, ADaM-to-SDTM trace, visit level, and key checks inside the join check.
- **Approach (approved):** a rule engine in R that reads tags and column names only; Auto Map uses it for
  pairs of tagged cards and keeps the heuristic for every other pair.

## 3. Goals and non-goals

**Goals**
- One composite key suggestion per pair of tagged cards, drawn as a group of splines and accepted with one
  click as one multi-key join (one undo step).
- CDISC notes in the gadget/module join check that explain a many-to-many result and flag a repeating
  natural key.
- No row scans beyond what Auto Map and the join check already do; lazy cards work from names alone.

**Non-goals**
- SUPPQUAL and RELREC joins (sub-project C).
- admiral code generation (D), ARD/TLG cards (E), define.xml checks (F).
- Suggestions on load, or anything in the htmlwidget.
- Findings-to-findings visit suggestions (`lb` with `vs`): that join is many-to-many by nature; the key check
  explains it instead (§6, note 2).
- A separate uniqueness scan of a table's natural key when it is not the join key (a later codebook item).

## 4. The rules: `sv_cdisc_join_keys(cards)`

New file `R/cdisc_keys.R`. Exported, roxygen-documented. `cards` is a list of `sideview_card` objects after
`sv_cdisc_resolve()`. It reads each card's tag (`card$cdisc`) and column names only (lazy cards cost nothing).

Column names match case-insensitively, as in 0.5.0. Output uses each table's own spelling.

### 4.1 Card roles

- **Hub:** domain `DM` (SDTM or SEND), or ADaM class `ADSL`. One row per subject.
- **Subject-keyed:** any tagged card with a `USUBJID` column, including user tags and class `Custom`.
- **Excluded:** SUPP-- and RELREC (class `Relationship`; sub-project C), and any card without `USUBJID`
  (e.g. the trial-design datasets TS, TA, TE). Cards with no tag, or with a cleared tag, take no part.

### 4.2 The subject key

The subject key of a pair is `STUDYID + USUBJID` when both cards have `STUDYID`, else `USUBJID` alone
(single-study ADaM data sometimes drops `STUDYID`). The reason text says which was used. All rules below
start from this subject key, written `SUBJ`.

### 4.3 Rules per pair (first match wins; at most one suggestion per pair)

1. **Trace (ADaM to SDTM):** an ADaM card other than ADSL, and an SDTM/SEND card with domain `D`, both with
   a `<D>SEQ` column. Keys: `SUBJ + <D>SEQ`. Left: the ADaM card. Right: the SDTM card.
   Examples: `adae` to `ae` by `AESEQ`; `adlb` to `lb` by `LBSEQ`.
2. **Subject level:** one card is a hub and the other is subject-keyed. Keys: `SUBJ`. Left: the other card.
   Right: the hub (the lookup).
   - Hub choice: an SDTM/SEND card links to DM and an ADaM card links to ADSL. When the preferred hub is not
     on the canvas, the other one is used. Each card gets one hub line, not two.
   - ADSL with DM: left ADSL, right DM.
   - Two cards of the same hub kind (two DM cards) get no suggestion.
3. **Visit level:** one card has domain `SV` and the other has `VISITNUM`. Keys: `SUBJ + VISITNUM`.
   Left: the other card. Right: SV.
4. Anything else: no suggestion.

### 4.4 Return value

A data frame, one row per suggested pair:
- `from_table`, `to_table`: card names (left, right).
- `from_cols`, `to_cols`: list columns of character vectors, paired by position, in key order
  (`STUDYID`, `USUBJID`, then the extra key).
- `kind`: `"trace"`, `"subject"` or `"visit"`.
- `reason`: e.g. `"CDISC subject key: DM has one row per subject"`,
  `"CDISC trace key: adae records come from AE (AESEQ)"`, `"... (no STUDYID in adae: USUBJID alone)"`.

An empty input, or one with fewer than two eligible cards, returns a zero-row data frame with these columns.

## 5. Auto Map: payload and canvas

### 5.1 R: `sv_suggest_mappings()`

- New argument `cdisc = "auto"`, with the values of `sv_codebook(cdisc =)`. Tables that arrive as data are
  tagged with it (`sv_cdisc_finalize()`); cards that already carry a tag keep it. `cdisc = FALSE` turns the
  rules off. The gadget and module servers pass the session's own `cdisc` setting.
- Pairs where both cards are tagged (and eligible, §4.1) get only rule rows; the heuristic is skipped for
  them, removing the `DOMAIN`/lone-`STUDYID` noise. Every other pair keeps the heuristic, unchanged.
- Output stays one row per key pair, with two new columns:
  - `group`: e.g. `"cdisc:adae~ae"`; `NA` for heuristic rows.
  - `kind`: `"trace"`, `"subject"`, `"visit"`; `NA` for heuristic rows.
- Rule rows have `confidence = 1` and the rule's `reason`, and come first. `min_confidence` never drops them.
- The empty result (`.empty_mappings_result()`) gains both columns.

The wire message `sideview_suggested_mappings` carries `group` and `kind` on each candidate. Existing fields
are unchanged, so a heuristic candidate is exactly what it is today.

### 5.2 Browser: `renderSuggestedSplines()`

- Each key pair still gets its own dashed spline. Group members share `data-group` and the class
  `sideview-spline-suggested-cdisc` (a slightly heavier stroke; existing `--sv-*` token, no new colour).
- Hovering any member highlights the whole group. The tooltip says "CDISC rule", not a percentage:
  `Suggested CDISC join: adae to ae by STUDYID, USUBJID, AESEQ (ADaM to SDTM trace). Click to accept`.
- **All or nothing:** a click on any member accepts the whole group as one `left_join` (left to lookup),
  removes the group's splines and shows one toast: `Accepted CDISC join: adae to ae by STUDYID, USUBJID, AESEQ`.
- **One undo step:** new `Pipeline.addJoinKeys(left, right, pairs, type)` (sv-pipeline.js) adds all pairs in
  one `change()`. `addConnection` gets a batch path that draws every connector, adds the keys through
  `addJoinKeys` and sends one `column_mapped` per key (R handles each as today).
- Keys already connected between the pair are skipped and the rest merge into that join. If all are
  connected, the group is not drawn.
- If any member's column port cannot be found, the whole group is dropped with a `console.warn`. A partial
  key set is the many-to-many trap, so it is never offered.
- If the pair already has a join the other way round (the user drew `ae` to `adae`), the group is offered in
  that join's direction, so the keys merge into it and no second join appears.
- Heuristic candidates (no `group`) render and behave as today.

## 6. Key checks in the join check

New internal `sv_cdisc_key_notes(cx, cy, by_x, by_y, diag)` in `R/cdisc_keys.R`, returning a character
vector. The `join_diagnostics_request` handler (`R/app_server.R`) calls it after the diagnostics are built and
adds the result to the reply as `cdisc_notes`. It reads only the two cards' tags and the counts already in
`diag` (`relationship`, `dup_keys_x/y`, `rows`), so it adds no data pass and works the same for lazy cards.

No notes when: the reply is `{error}`; either card is untagged or cleared; the session runs with
`cdisc = FALSE`. `sv_join_diagnostics()`, `sv_lazy_join_diagnostics()` and the JS `joinDiagnostics()` are
untouched, so the twin parity tests are unaffected; the widget has no notes.

Notes, in this order:
1. **Many-to-many on a pair with a rule (§4.3)** whose key set the join's keys do not cover: name the missing
   keys. `Add AESEQ: the CDISC key for adae and ae is STUDYID, USUBJID, AESEQ.`
2. **Many-to-many on a pair with no rule:**
   - both cards class `Findings`: `LB and VS both have many records per subject and visit: filter each to one
     test (LBTESTCD, VSTESTCD) or summarise before joining.` (the `--TESTCD` names are the domains' own;
     a name the table lacks is left out of the parenthesis)
   - otherwise: `Add VISITNUM or a --SEQ key, or summarise one side first.`, naming only keys present in both
     tables (`VISITNUM`, `<D>SEQ` of either domain); when none is present, only `Summarise one side first.`
3. **A natural key repeats:** one side's join keys equal (case-insensitively, as a set) that table's natural
   key from the catalogue `keys` column, and its `dup_keys` count is above 0:
   `STUDYID, USUBJID, AESEQ should identify one AE record, but 3 keys repeat: check for duplicate records.`
   This also catches a DM or ADSL that is not one row per subject (DM's natural key is `STUDYID;USUBJID`;
   ADSL, which has no catalogue keys, is checked against its subject key, §4.2). Other ADaM datasets have
   no catalogue keys and get no note 3.

Notes use each table's own column spelling. When the check fell back to a preview, the notes sit under the
same preview label as the rest of the panel.

**Display:** the engine renders `cdisc_notes` below the existing warnings, under a small "CDISC" heading,
escaped, with existing tokens. They do not change `strict_args` or Strict.

## 7. Data flow summary

```
Auto Map click -> request_suggested_mappings -> sv_suggest_mappings(current_cards(), cdisc = <session>)
   tagged pairs: sv_cdisc_join_keys() -> rows with group/kind     other pairs: heuristic (unchanged)
-> sideview_suggested_mappings {candidates: [..., group, kind]} -> grouped dashed splines
-> click -> addConnection batch -> Pipeline.addJoinKeys (one change) + column_mapped per key
-> join_diagnostics_request -> diagnostics + sv_cdisc_key_notes() -> reply.cdisc_notes -> join check panel
```

## 8. Testing

- **`tests/testthat/test-cdisc-keys.R`** on synthetic fixtures (`helper-cdisc.R`: today's dm, ae, suppae,
  adsl, adlb plus new adae, lb, vs, sv, ts):
  - each rule; precedence (`adae` with `ae` is a trace, not subject); hub choice (`ae` to `dm`, `adlb` to
    `adsl`, `ae` to `adsl` when DM is absent, `adsl` to `dm`); `sv` visit; `lb` with `vs` gives nothing;
    SUPP, RELREC and TS excluded; no-`STUDYID` fallback and its reason text;
  - a cleared tag and `cdisc = FALSE` give no rule rows; untagged pairs give the same heuristic rows as before
    (compared with the output of today's function on the same tables);
  - mixed-case column names come back in their own spelling;
  - a duckdb lazy card gives the same keys and is not collected;
  - `sv_suggest_mappings()`: `group`/`kind` columns, rule rows first, no `DOMAIN` or lone-`STUDYID` rows
    between tagged cards, empty result has the new columns;
  - for each accepted group, the generated join code `parse()`s and its row count equals `dplyr::left_join()`.
- **`sv_cdisc_key_notes()`:** every note text above; no notes on error, untagged, cleared or `cdisc = FALSE`.
- **`testServer`:** the suggestions message carries `group` and `kind`; the join check reply carries
  `cdisc_notes` (and none with `cdisc = FALSE`).
- **JS pipeline (node):** `addJoinKeys()` is one undo step, merges into an existing join, keeps direction.
- **Real browser** (chromote, real mouse input via `Input.dispatchMouseEvent`): Auto Map on dm, ae, adsl, adae
  draws grouped splines; hover highlights the group; one click gives one multi-key join, one undo removes it;
  the toast; `ae` x `lb` by `USUBJID` shows the CDISC notes in the join check.
- **RStudio:** dialog, pane and external browser pass; full `devtools::test()` and `devtools::check()`; results
  recorded in `MEMORY.md`.

## 9. Files

- **New:** `R/cdisc_keys.R`, `tests/testthat/test-cdisc-keys.R`.
- **Modified:** `R/copilot.R` (`sv_suggest_mappings()`), `R/app_server.R` (suggestions and join-check
  handlers), `inst/www/sideview.js`, `inst/www/sv-pipeline.js`, `inst/www/sideview.css`,
  `tests/testthat/helper-cdisc.R`, `_pkgdown.yml` (new export), `man/`, the CDISC article, `CLAUDE.md`
  (candidate fields `group`/`kind`; `cdisc_notes` as an R-only join-check reply field), `NEWS.md` (0.6.0),
  `DESCRIPTION` (0.6.0), `MEMORY.md`, rebuilt `docs/`.

## 10. Risks

- **Sponsor-specific sequence names** that do not follow `<D>SEQ` do not trace; those pairs still get the
  subject rule. A user tag cannot fix this. Noted as a limit in the article.
- **Pooled studies:** `STUDYID` stays in the key whenever both cards have it.
- **Large canvases:** rules compare names only, so all-pairs stays cheap; the heuristic's cost is unchanged.
- **Mixed direction:** handled by following an existing join's direction (§5.2).
- **A rule looking like a measured score:** the tooltip says "CDISC rule", not "100%".
