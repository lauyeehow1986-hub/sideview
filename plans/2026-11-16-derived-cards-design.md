# sideview derived cards (unmatched rows, stack, compare data cuts): design

- **Date:** 2026-11-16
- **Sub-project:** **D** of the 2026-11-13 roadmap (A, C shipped in 0.8.0; B in 0.9.0; E next). Target 0.10.0.
- **Status:** agreed in chat part by part; builder check done; this written spec awaits review.
  Points I settled myself are marked **(my call)**.
- **Delivery:** one spec, three PRs on their own branches, in this order:
  **D1** derived cards + unmatched/dropped rows, **D2** stack and compare columns, **D3** compare data cuts.
  Each PR is releasable alone; the version goes to 0.10.0 with D3.

## 1. Intent

A biostatistician checking clinical tables keeps asking "which rows?" after sideview says "how many".
Today the join check says *12 ae rows have no match in dm* and shows 5 sample keys; the SUPP check says
*3 orphan SUPP rows*. D turns those counts into **tables on the canvas** that can be joined onward (were the
unmatched AE subjects screen failures in DS?). It adds two everyday jobs that are clumsy by hand: **stacking**
two waves of a table whose column types and labels drifted, and **comparing two data cuts** of the same table
by key (rows added, removed, changed between the June and September AE extracts). The last one was ranked
highest.

All three rest on one new building block: **a card made from other cards** (a *derived card*). It has its own
line in the generated code, lives in the R card store like any card, and R serves its rows, so a lazy (duckdb /
Arrow) result stays lazy.

D must work in the **canvas, the list view and the console**, like A and B.

## 2. What the user decided

- The three features and their behaviour as played back (sections 5-7), with my proposals accepted as they
  stand: "let's use this first, we can rescope in future if needed".
- **Approach A** (section 4): a derived card is a pipeline step, built by R from its input cards.
- The **htmlwidget is left out** of D (it has no R session).
- Compare data cuts: comparisons are **exact** (no numeric tolerance), **NA in both versions counts as the
  same**, **rows with a duplicate key are reported and left out**, and **the type-change check comes before the
  value check**. No "ignore these columns" option in D.
- Fuzzy joins are out (from the 2026-11-13 notes); near-miss keys are shown instead (section 6, case-only names).

## 3. Goals, non-goals, anti-goals

**Goals**
- One click from a count to the rows behind it, as a card that behaves like every other card (rows, sort,
  filter, column inspector, join check, codebook, connect onward).
- Stack two or more cards with a column comparison and accept/override fixes, generating `bind_rows()`.
- Compare two versions of a table by key: a summary, plus Added / Removed / Changed values cards.
- Generated code rebuilds every derived card from the input cards; copied out, it runs with dplyr only.
- Lazy inputs give lazy derived cards; nothing is collected.
- The same summaries, as text, in the list view and from console functions.

**Non-goals (D)**
- The htmlwidget (`sideview_widget()`, `save_sideview()`): no D buttons; a state with derive steps opened there
  shows those steps disabled with one toast **(my call)**.
- Numeric tolerance; ignoring columns in a compare; fuzzy joins; more than two versions in one compare.
- Proxy verbs for derived cards in the module (a host app can call `sv_compare()` etc. and `sv_add_card()`).
- `metatools`, `dm`, `pointblank`, `metacore` (sub-project E).

**Anti-goals** (would make D a failure even if it works)
- A derived card whose rows differ from what its generated code produces.
- Collecting a lazy table to build or show a derived card.
- Guessing: silently merging near-miss columns, silently resolving duplicate keys, a tolerance nobody chose.
- Any change to the canvas for someone who never presses the new buttons (beyond the buttons themselves).
- A module (untrusted) client being able to make R read an object outside the card store, or run code.

## 4. Approaches considered

| | Approach | Trade-off |
|---|---|---|
| **A (chosen)** | A `derive` pipeline step; R builds the card from the store and registers it; `compose()` writes it as its own assignment | Most work (pipeline, store, state, module routing), but the code rebuilds every card and lazy stays lazy |
| B | Snapshot: R computes once and adds a plain data-frame card | Least work, but stale when inputs change, the code does not rebuild it, and a lazy input would be collected |
| C | Compute in the browser (JS twins), as the widget's join check | Would work in the widget, but sees only the 500-row preview of big or lazy cards, so counts are wrong where it matters; a third twin per feature |

The user picked A.

## 5. The building block: derived cards

### 5.1 What a derived card is

A card whose data is an operation on other cards: `op` + `inputs` (card names) + `args`. The ops:

| `op` | From | Card name **(my call)** | Generated code (in-memory form) |
|---|---|---|---|
| `unmatched` | join check, either side | `<x>_unmatched_<y>` | `dplyr::anti_join(x, y, by = <keys>)` |
| `outside_window` | join check with a date rule, either side | `<x>_outside_window` | rows of `x` with a key match in `y` but no row that satisfies the rule: `dplyr::semi_join(x, y, by = <keys>)` then `dplyr::anti_join(y, by = dplyr::join_by(<keys>, <rule>))` |
| `supp_orphans` | SUPP check | `<supp>_orphans` | SUPP rows whose (`USUBJID`, IDVAR value) has no parent row; uses the check's plan (IDVAR conversion) as the merge does |
| `supp_bad_idvarval` | SUPP check | `<supp>_bad_idvarval` | SUPP rows whose `IDVARVAL` does not convert to the IDVAR's type |
| `stack` | Stack (section 6) | `<first>_stacked` | `dplyr::bind_rows(.id = "source", <name> = <name>, <name> = <name> %>% <fixes>)` |
| `cut_added`, `cut_removed`, `cut_changed` | Compare (section 7) | `<new>_added`, `<old>_removed`, `<new>_changed` | section 7.4 |

A name already in the store gets `_2`, `_3`, ... R chooses the final name (the client may suggest one) and makes
it a syntactic R name.

**Inputs are the cards as loaded**, never their pipeline chains **(my call, agreed in chat as part of A)**: a
derived card is built from `refFor(input)`, the same choice the Strict join check makes. A filter on `ae` does not
change `ae_unmatched_dm`. An input may itself be a derived card (unmatched rows of a stacked card); then it is
"as loaded" too, i.e. its own derive expression.

**The count on a button is the row count of the card it opens**, and the cards of one check never overlap
**(my call, after the builder check)**:
- **No date rule:** `unmatched` = rows of `x` with no key match in `y`, NA matching NA (`na_matches = "na"`, as the
  check without a rule), so it equals `n_x - matched_x`.
- **With a date rule** the check pairs keys with `na_matches = "never"` (`R/join_rules.R`), so both ops use
  `"never"`: `unmatched` = rows with no key match (rows with an NA key included), `outside_window` = rows with a
  key match but no pair that satisfies the rule (= `rule_dropped_x`). The two partition what the rule join drops:
  `unmatched + outside_window = n_x - matched_x`. The drawer shows two buttons.
- The same for `y`. `supp_orphans` equals `n_orphan`; `supp_bad_idvarval` equals `bad_idvarval$n`.
- Keys of different kinds compare as text, as in the check.

### 5.2 Flow (gadget and module)

1. The user presses **Open as card** (or Stack's / Compare's open buttons). The browser sends
   `derive_request` `{id, op, inputs, args, name?}`.
2. R checks it: `op` is known, every input is a card in the store, every column named in `args` exists in its
   input. Anything else answers `sideview_derive_result {id, error}` and changes nothing. (Module: routed by `ns`;
   the client only names cards in the store, as for every other request.)
3. R builds the card (section 5.3), adds it to the store, then sends `sideview_card_add` with the normal payload
   plus `derived: {op, inputs, args}` and `request_id`. The store is updated first, then the browser told, as for
   module verbs.
4. The browser adds the card next to its first input (free spot, not overlapping) and adds one `derive` step to
   the pipeline: **one undo step**. It announces "Table ae_unmatched_dm added, 12 rows." (B's live region).

### 5.3 How R builds it

- In-memory inputs: R evaluates the op with dplyr; the card's `data` is the result.
- Any lazy input: the card is lazy. Its `source` is a recipe; resolving it (in `sv_lazy_tbl()` or a sibling) builds
  the query from the inputs' tbls placed on the session connection with `sv_lazy_place()`, and caches it under
  the card id like a converted Arrow table. `dims[1]` is a `count()` in the engine; `data` is the 50-row preview.
  `source` is never serialised (as today). `forget(id)` releases what the recipe registered.
- A lost link or a missing duckdb falls back exactly as for other lazy cards (one `sideview_toast`).
- CDISC tag **(my call)**: `unmatched`, `outside_window`, `cut_added`, `cut_removed` take their first input's tag;
  `supp_*` take the SUPP card's tag; `stack` takes the tag when all inputs share it; `cut_changed` has none.

### 5.4 The `derive` step and generated code

- Step: `{kind: 'derive', key, table: <new card>, op, inputs, args}`; `table` is the derived card, so steps the user
  adds to it later form its chain as usual.
- `compose()` writes every enabled derive step as an assignment, `<name> <- <expression>`, before any chain that
  reads it, in step order (a derive can only name cards that exist, so step order is dependency order). A later
  chain on the card starts from `<name>`. The cross-backend rules `compose()` already has (copy, `to_duckdb()`,
  `compute()`) apply to derive expressions with lazy inputs.
- A derive assignment **stays lazy** when an input is lazy, like a chain prepared for another chain today: the
  copied code leaves `ae_unmatched_dm` a lazy table, and a later chain on it ends in one `collect()` as usual
  **(my call)**. The code-twin test collects before comparing.
- Generated code must `parse()`, and **evaluated, must equal the card R built** (test: compose in node via
  `helper-node.R`, eval in R, `expect_equal()` with the card's data, for in-memory, duckdb and Arrow inputs).
  This is the twin rule for D: R builder <-> JS `compose()`.
- Removing a derive step removes its card and disables the steps that used it (existing `disableMissing()` path),
  with the existing toast. Derive steps have no enable/disable toggle **(my call)**: a disabled derive with a live
  card would break the "card equals code" rule. Undo of an add removes the card; redo sends the request again.
  R drops a removed derived card from the store on `derive_forget {name}` (only derived cards can be forgotten
  this way).
**A derived card always equals its code** **(my calls, after the builder check)**:
- Whenever a derive step stops being live (its input card is removed by the user or by `sv_remove_card()`, a
  derive it reads is removed, a state is loaded without its inputs), **its card is removed too**, and so are the
  derived cards built from it, in cascade. The step stays in the pipeline, disabled, like any step naming a
  missing table, so restoring the input (or Undo) brings it back by a new `derive_request`.
- When an input's data is replaced (`sv_replace_card()` in a module), R **rebuilds** the derived cards that read it,
  in dependency order, and sends `sideview_card_replace` for each (with `clearJoinChecks()` and a `joinDiag` reset,
  per CLAUDE.md's join-check cache rule). If a column named in `args` is gone, that derived card is removed as
  above, with one toast. Dependencies are read from the `derived` spec each derived card carries in the store; no
  separate graph.
- In a module, the host may `sv_remove_card()` a derived card: that is the same as the user removing it.

### 5.5 State

Derive steps are saved in the pipeline like other steps; derived **rows are never saved**. On load:
- `sideview(state = )`: R rebuilds derived cards from the steps (in order) before the UI is sent.
- Browser Open (state file): for each derive step whose card is missing, the engine sends `derive_request`
  with the saved name; positions come from the state's cards, matched by name as today.
- Module, `sideviewServer(state = )` and `sv_set_state()`: R rebuilds the derived cards from the steps before it
  sends the cards (the same R function as the gadget), so they are in the store and in `sideview_snapshot`'s
  `cards` like any card **(my call)**. The browser's re-request path is only for a state file opened in the page.
- A derive step whose inputs are missing stays disabled, with the usual toast.
No schema bump: `derive` is a new step kind inside `pipeline.steps` **(my call)**; an older sideview ignores
unknown kinds (the builder checks `normalize()` does).

## 6. Stack two tables and compare their columns (D2)

**Flow.** The user picks two or more cards (drawer **Stack** tab, or the list view's Stack builder; the order picked
is the stack order) and presses **Check**. R answers `stack_check_request {id, tables}` with
`sideview_stack_check {id, columns, code_preview, text}`; the user accepts or changes fixes and presses
**Open stacked card**, which is a `derive_request` with `op: 'stack'` and the fixes in `args`.

**The column table:**

```
Column   wave1        wave2        Status
AGE      num          chr          type differs -> as.numeric
RACE     chr "Race"   chr "RACE"   label differs (wave1 label kept)
ARMCD    chr          -            only in wave1 (NA in wave2)
Age      -            num          near-miss for AGE? (case)
```

**Rules (my calls, accepted in chat):**
- Columns match by **exact name**. Names equal ignoring case are flagged *near-miss*; the offered fix is a
  rename to the first table's spelling, off by default. Nothing is merged silently.
- Types differ: the proposed fix casts to the more general type, in this order: logical < integer < double <
  character; Date and POSIXct with character go to character; Date with POSIXct goes to POSIXct; factor with
  character goes to character; two factors keep a factor with the union of levels. The user can pick another
  target (any of the column's types, or character) per column. A cast that would turn non-missing values into
  NA is reported with its count before the card is opened (from R, on the full data or the lazy query).
- Labels differ: the first table's label is kept; the differences are listed. The stacked card carries the kept
  labels; the code writes them explicitly if `bind_rows()` does not keep them.
- A column in only some tables is NA in the others (what `bind_rows()` does).
- `.id = "source"` holds each input's card name. If an input already has a `source` column, the id column is
  `source_2`, etc.
- Lazy inputs: the stack is a lazy `union_all()` with the casts in the query and a constant `source` column;
  never collected.

## 7. Compare data cuts by key (D3)

### 7.1 Flow

Drawer **Compare** tab (and list view builder): pick **old** and **new** cards, confirm the key, press
**Compare**. The key is pre-filled from the CDISC natural key (`sv_keys_natural()`, e.g.
`STUDYID, USUBJID, AESEQ`) when both cards carry the same domain tag, else from columns both share that the
existing key suggestions would pick, else empty. R answers `compare_request {id, old, new, by}` with
`sideview_compare {id, ...summary, text}`.

### 7.2 The summary (drawer, list view, console)

```
ae_2026_06 -> ae_2026_09, key STUDYID + USUBJID + AESEQ
Rows:    1,204 -> 1,251   added 52 · removed 5 · changed 31 · same 1,168
Columns: added AEACN2 · removed none · type changed AESTDTC (chr -> Date)
Changed values by column:  AESEV 18 · AEOUT 9 · AEENDTC 7
Warnings: 2 duplicate keys in new (not compared)
```

With buttons **Open added rows** (52), **Open removed rows** (5), **Open changed values** (31 rows).

### 7.3 Rules

- **Added**: rows of new whose key is not in old. **Removed**: rows of old whose key is not in new.
  **Changed**: key in both, at least one compared column differs. **Same**: key in both, no compared column
  differs.
- **Duplicate keys** **(my call, after the builder check)**: a key is a *repeated key* when it occurs more than once
  in **either** version. Every row with a repeated key, in both versions, is in none of added, removed, changed or
  same; Warnings counts the repeated keys and their rows per version ("2 keys repeat: 4 rows in old, 3 in new, not
  compared"), with up to 5 sample keys. So `added + changed + same + repeated_rows_new = nrow(new)` and
  `removed + changed + same + repeated_rows_old = nrow(old)`; the three cards drop repeated-key rows the same way.
- **Compared columns** are those in both versions with the same type (as `sv_key_kind()` classes them, plus
  factor = character for this purpose **(my call)**). Columns whose type changed are listed and not compared.
  Key columns are not compared.
- **Equality**: exact. NA (and NaN) in both is the same; NA in one only is changed. No tolerance.
- Keys compare as the join check does (NA matches NA; mixed kinds compare as text).
- Counts per column = rows where that column changed.

### 7.4 The three cards and their code

- `<old>_removed` = `dplyr::anti_join(old, new, by = <key>)` minus duplicate-key rows; `<new>_added` likewise.
- `<new>_changed`, long form, one row per changed value: the key columns, then `column` (name), `old`, `new`.
  `old`/`new` are **character** so different column types fit one table (`as.character()`; in a lazy query the
  backend's cast). Generated code is plain dplyr, no tidyr (not in Imports): an `inner_join()` with
  `suffix = c(".old", ".new")` after dropping duplicate keys, then one `transmute()` + `filter()` per compared
  column, combined with `bind_rows()`. Its row count, as a card, is the number of changed **values**; the summary
  counts changed **rows**.
- Equality of a lazy `_changed` card with the in-memory one: same rows and counts; number text compared after
  `as.numeric()` because the backends format doubles differently **(my call)**.

## 8. List view and console

- **List view** (`sv-listview.js`): the join check and SUPP check sections get the same Open buttons; new
  Stack and Compare builders under the existing builder sections, with the summary text R sends (`text`, lines
  from new `sv_say_*` functions). R writes the text; there is no JS twin for D's text because the widget is out
  of scope **(my call)**. Buttons say what they do: "Open 12 unmatched ae rows as a card".
- **Console** (new exports, each in `_pkgdown.yml`):
  - `sv_unmatched(x, y, by, rule = NULL, side = c("x", "y"), what = c("unmatched", "outside_window"))`:
    the rows (lazy in, lazy out).
  - `sv_supp_orphans(parent, supp, rdomain = NULL, what = c("orphans", "bad_idvarval"))`: the rows.
  - `sv_stack_check(...)`: class `sv_stack_check` (the column table, fixes, `code`), printed as the table.
  - `sv_stack(..., check = sv_stack_check(...))`: the stacked table.
  - `sv_compare(old, new, by)`: class `sv_compare` with the summary fields and `added`, `removed`, `changed`
    tables; printed as the summary in 7.2.
  The browser features call these same functions, so the console, list view and canvas cannot disagree.
  Lazy twins live in `R/lazy.R` and test-lazy.R holds them to the in-memory result (tolerance `1e-12`, duckdb and
  Arrow fixtures), per CLAUDE.md.

## 9. Wire names (add to CLAUDE.md's list)

- Inputs: `derive_request` `{id, op, inputs, args, name?}`, `derive_forget` `{name}`,
  `stack_check_request` `{id, tables}`, `compare_request` `{id, old, new, by}`.
- Messages: `sideview_derive_result` `{id, error}` (failure only; success is `sideview_card_add` with `derived`
  and `request_id`), `sideview_stack_check`, `sideview_compare`. All carry `ns` in module mode via `send()`, and
  handlers go through `onMessage()`.

## 10. Testing

- R units: each op's rows and counts against hand-built synthetic data; count agreement with the check that
  offered it (5.1); stack type rules and NA-introducing casts; compare rules, including duplicate keys, NA/NaN,
  type-changed columns, a key with NA, empty versions, identical versions.
- Lazy twins: duckdb and Arrow fixtures, including mixed in-memory + lazy inputs; never collected (a test that
  fails on `collect()` of the full table, as test-lazy.R does today).
- Code twin: compose in node, `parse()`, eval, `expect_equal()` with the R-built card (5.4).
- Pipeline (`test-pipeline.R` / node): derive step ordering, undo/redo, removal disabling dependants,
  load/save round-trip.
- Module (`testServer`): forged `derive_request` naming an unknown card, an unknown op, or a missing column is
  refused with an error reply and no store change; `derive_forget` of a non-derived card is ignored.
- Real browser (chromote, `test-layout-browser.R` / `test-a11y-browser.R`): the buttons with real mouse input,
  the new card placement not overlapping, list view parity with the drawer text, axe-core on the new tabs.
- State: save -> open restores derived cards with the same rows and positions, in the gadget and by file.
- Manual: RStudio dialog, Viewer pane and external browser, recorded in MEMORY.md only after the user says they
  did it.

## 11. Left to the builder

- Exact drawer layout of the Stack and Compare tabs and the Open buttons (follow existing drawer patterns, `--sv-*`
  tokens, inline SVG icons, B's accessible-canvas rules).
- The recipe representation of a lazy derived card and where its resolution lives in `R/lazy.R`.
- How `supp_orphans` code reuses the SUPP merge's IDVAR conversion code (`suppJoins`, `suppPrep`).
- Placement algorithm for the new card (free spot near its first input).
- Sample sizes beyond "up to 5" and wording of toasts, within the existing voice.

## 12. Docs

- NEWS.md entry per PR under the 0.10.0 heading; README Key Features gets one bullet per feature.
- A new article section (or article) "Unmatched rows, stacking and comparing data cuts" with synthetic data;
  screenshots only from synthetic fixtures.
- CLAUDE.md: wire names (section 9), the derive twin rule (5.4), the "inputs as loaded" rule.
- MEMORY.md: roadmap task list updated as each PR starts and lands.
