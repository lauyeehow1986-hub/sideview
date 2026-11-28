# CLAUDE.md — sideview

## What this is
`sideview` is an R package (v0.3.x) that puts many tables side by side on a **2D pan/zoom canvas**.
It runs either as an interactive **Shiny gadget** (`sideview()`, RStudio addin `sideview_addin()`) or as an
exportable **htmlwidget** (`sideview_widget()`, `save_sideview()`, Quarto/Rmd). Users drag table cards,
sort/filter from headers, connect columns with SVG splines to generate `dplyr` joins, inspect
discrepancies, and ask an LLM copilot (Ollama / OpenAI-compatible) for tidyverse code. Generated code is
inserted into RStudio via `rstudioapi`.

Research/education tool — **not for clinical decisions**. Never commit real patient data; fixtures are synthetic.

## Architecture
```
R side                                         Browser side (inst/www)
------                                         -----------------------
sv_normalize() (R/normalize.R)  ->  sideview_card objects
  |-- gadget:  sideview() (R/sideview.R)
  |      sideview_ui()  (R/app_ui.R)   ->  server-rendered HTML cards  ->  sideview.js  initSideview()
  |      sideview_server() (R/app_server.R)  <->  Shiny.setInputValue / sendCustomMessage
  |-- module:  sideviewUI()/sideviewServer()/sideviewProxy() + sv_add_card() etc. (R/module.R) -> same server impl
  |      in module mode; mutable card store (R/card_store.R: sv_card_store(), add/replace/remove/get/names)
  |-- widget:  sideview_widget() (R/widget.R)  ->  JSON cards  ->  inst/htmlwidgets/sideview.js
                                                                   -> new Sideview.Engine(el, opts)
codegen: R/codegen.R (sv_code_* generators)    engine: SideviewEngine + VirtualTable (sideview.js)
pipeline: inst/www/sv-pipeline.js (SideviewPipeline: typed steps -> composed R code, undo/redo;
          pure JS, no DOM — the single source of generated code in both gadget and widget)
list view: inst/www/sv-listview.js (`SideviewListView`, owned by the engine), with `setView`, `movePanes`
          and `openBuilder` on the engine
accessible canvas: inst/www/sv-access.js (`SideviewAccess`, owned by the engine as `engine.access`; loaded before
          `sideview.js`): keyboard on cards and column headers, reading order, focus following. Switch, zoom floor
          and the `?` rows live in sideview.js; low-vision rules in sideview.css under `.sv-access`
llm/copilot: R/llm.R, R/copilot.R              pan/zoom: inst/www/sv-panzoom.js (small in-house impl)
state: R/state.R (sv_save_state/sv_load_state) styles: inst/www/sideview.css (--sv-* tokens)
rstudio bridge: R/rstudio.R
```
- Shiny inputs (client → R): `column_mapped`, `column_disconnected`, `column_sorted`, `column_filtered`,
  `column_renamed`, `clear_operations`, `discrepancy_check`, `request_suggested_mappings`,
  `apply_auto_clean`, `run_ai_prompt`, `send_copilot_chat`, `inject_script`, `send_console`,
  `send_console_and_exit`, `eval_env`, `sideview_card_moved`, `sideview_highlight_changed`,
  `sideview_rows_request`, `join_diagnostics_request`, `derive_request` (`{id, op, inputs, args, name?}`: validated by `sv_derive_clean()`, inputs are store names, args off the allowlist dropped, the SUPP plan is R's own), `derive_forget` (`{name}`: only a card with `derived`), `stack_check_request` (`{id, tables, fixes?}`: `tables` are 2 to 8 store names, each once; cleaned with `derive_request`'s stack rules by one helper, `sv_stack_clean()`; a refusal changes nothing), `compare_request` (`{id, old, new, by?}`: `old` and `new` are store names, `by` is 1 to 20 column names the same in both; cleaned by `sv_compare_clean()`, which `derive_request`'s compare ops use too; with no `by` R suggests one from the cards' CDISC tags; a refusal changes nothing), `column_profile_request`, `supp_check_request` (`{id, parent, supp, plan?, rdomain?}`; `rdomain` is a hint R takes only if it is in the SUPP card's tag `rdomains` or the card has no tags; module: routed by `ns`, the client only names cards in the R store), `codebook_export`,
  `state_save`, `state_open_request`, `sideview_ready` (module: the canvas is on the page, R sends its cards),
  `sideview_snapshot` (module: `{code, pipeline, state, cards}`, pipeline/state as JSON text, debounced 300 ms),
  `sideview_done`, `sideview_cancel`,
  `cancel` (miniUI dialog close).
- Custom messages (R → client): `sideview_code_update`, `sideview_discrepancies`,
  `sideview_suggested_mappings` (candidates carry `group`, e.g. `"cdisc:adae~ae"`, and `kind`, `"trace"|"subject"|"visit"`, both null for heuristic rows; a group is drawn as dashed paths with class `sideview-spline-suggested-cdisc` and accepted as one join by `addConnections()`: one undo step, one `column_mapped` per key), `sideview_copilot_reply`, `sideview_inject_result`,
  `sideview_console_result`, `sideview_eval_result`, `sideview_rows`, `sideview_ai_status`,
  `sideview_join_diagnostics`, `sideview_derive_result` (`{id, error}`: a refused `derive_request`; success is a `sideview_card_add` with `request_id`), `sideview_stack_check` (`{id, columns, n_rows, id_col, name, open_label, code_preview, text}` from `sv_stack_plan()`, each column with a `table` cell per input; or `{id, error}`; carries `ns` in module mode), `sideview_compare` (`{id, old_name, new_name, by, n_old, n_new, added, removed, changed, same, repeated_*, compared, type_changed, only_old, only_new, per_column, changed_values, text, open, code_preview}`: the counts and lines of `sv_compare_finish()`, `by` an array and `per_column` an object, `open` the three button labels, `code_preview` `{added, removed, changed}`; or `{id, error}`, with `by: []` when no key could be suggested; carries `ns` in module mode), `sideview_column_profile`, `sideview_supp_check` (`{id, ...check}` from `sv_supp_check()`, or `{id, error}`; carries `ns` in module mode; the check has a `combine_supp` field `{ok, reason, prep: {rdomain, idvar_na}, installed}`, where `installed` is `null` from the browser and TRUE/FALSE (metatools >= 0.3.0) from the R handler), `sideview_codebook_saved` (module: carries `csv`, the file text, plus `filename`; the browser downloads it),
  `sideview_state_saved`, `sideview_state_loaded`,
  `sideview_cdisc_update` (module: `{tags: {<card_id>: tag | null}}`, the badges only; an unknown card id is ignored quietly),
  `sideview_card_add` (the first population on `sideview_ready` carries `initial: true`; a derived card's payload carries `derived: {op, inputs, args}` and the message `request_id`, the id of the `derive_request` it answers), `sideview_card_replace`, `sideview_card_remove`, `sideview_state_set`, `sideview_highlight`,
  `sideview_code_style` (`{style, ns}`: `dplyr`/`pharmaverse`, display and codegen only; sent before `sideview_state_set`, whose pipeline `style` wins),
  `sideview_llm` (module without `llm_fn`: hide the AI bar and Copilot tab),
  `sideview_toast` (`{text, type, id?, card?}`: a notice from R, e.g. the lazy-to-preview fallback; a toast with the same `id` is updated in place, as for codebook progress; `card` is the id of the card the notice is about: the browser then sets that card's `data-rows-basis` to `preview`, as for a lost link).
- `sideview_code_update` carries `source`: `event` (echo of a client step; ignored), `auto_clean`
  (appended as a custom step), `copilot` (offered in the chat bubble only), `ai`/absent (replaces the pipeline).
- Keep this list in sync when adding inputs/messages.
- **Module routing (`ns`):** every input a module canvas sends is prefixed with the container's `data-sv-ns`
  (`review-column_mapped`; the gadget's prefix is `""`). Shiny allows one handler per custom message type, so
  `onMessage()` registers each type once and routes by the `ns` field of the message to the engine registry
  (`ns` -> engine; no `ns` = the gadget). An unknown `ns` or card gets a `console.warn`. A new R-to-client message
  must carry `ns` in module mode (`send()` adds it); a new handler goes through `onMessage()`, never
  `Shiny.addCustomMessageHandler` directly.
- **Module mode is an untrusted client:** the code-execution inputs (`inject_script`, `send_console`,
  `send_console_and_exit`, `eval_env`, `sideview_done`, `sideview_cancel`) are refused (handlers not registered)
  and their buttons not rendered, and the LLM backend, endpoint and key are never taken from the browser (only
  `llm_fn`). `$code()` is composed in the browser: show, save or review it, never `eval()` it unattended. Clients
  only name cards in the R store, so a forged input cannot make R read another object. A verb updates the R
  store first, then tells the browser (queued until `sideview_ready`); verbs return the proxy invisibly.
- **Lazy (arrow / duckdb) cards:** `new_sideview_card()` keeps the user's object as `source` (plus `code_ref`,
  `is_lazy`, `lazy_source`); `card$data` stays the 50-row preview and `dims[1]` the true row count. **`source` is
  never serialised**: not in widget JSON, state or card attributes (test-lazy.R checks this). All lazy logic is
  in `R/lazy.R`: the `sv_lazy_*` functions are twins of the in-memory ones (`sv_lazy_rows_window` /
  `sv_rows_window`, `sv_lazy_join_diagnostics`, `sv_lazy_column_profile`), and test-lazy.R holds them to the data
  frame result with `expect_equal(tolerance = 1e-12)` over duckdb and arrow fixtures. Change a twin together
  with its in-memory function. Lazy tables are never collected: only summaries, row windows and
  `collect(head(tbl, 0))` (for R classes) come back. One private duckdb connection per Shiny session
  (`sv_lazy_env()`), closed in `onSessionEnded`; a user's connection is left clean. A lost link or a missing
  duckdb falls back to the preview with one `sideview_toast`. In a module a lazy card's payload has `remote: true` (R serves the whole table), so the browser sets
  `data-rows-basis="full"` and the true-size badge; only the widget's lazy card (no `remote`) is labelled a preview. `forget(id)`
  unregisters the Arrow views a cached lazy table put on the session connection (`sv_arrow_views` attribute). Do not use `is.nan()`/`is.infinite()` in lazy
  expressions (dbplyr turns them into `PRINTF('%f', col)`, which fails on integer types): use `isnan()`/`isinf()`.
  Lazy "contains" is `str_detect(col, "<escaped literal>")`, never `stringr::fixed()`.
- **Sentences:** `sv_say_join` / `sv_say_supp` / `sv_say_profile` (R/say.R) and `sayJoin` / `saySupp` / `sayProfile` (sv-pipeline.js) are twins (test-say.R, byte-equal). Change them together. `sv_describe()` (R/describe.R) is R only.
- **Codebook:** `sv_codebook()` has a `rows_profiled` column after `n` (`n` = true row count, `rows_profiled` =
  rows profiled; equal except for a preview-only card). `SideviewPipeline.codebookRow()`/`codebookCsv()` write the
  same column, so the byte-equal CSV test still holds.
- **Join diagnostics:** `cdisc_notes` (list of strings, maybe empty) is an R-only field of the
  `sideview_join_diagnostics` reply, added by the `join_diagnostics_request` handler and shown under a "CDISC"
  heading after the warnings; the widget's browser-computed diagnostics never carry it, and the twins below
  do not produce it. `derive_offers` is the same kind of R-only field, on this reply and on `sideview_supp_check`: a list of
  `{op, inputs, args, n, label}` for the "open these rows as a card" buttons (`sv_derive_offers_join()` / `sv_derive_offers_supp()`,
  offers with `n == 0` and key-type clashes dropped; the SUPP plan is left out, R recomputes it). The widget never has it. `sv_join_diagnostics()` (R/diagnostics.R) and `SideviewPipeline.joinDiagnostics()`
  (sv-pipeline.js) are twins with the same snake_case fields; `test-diagnostics.R` checks parity and that row
  counts equal dplyr (NA matches NA, as `na_matches = "na"`). The gadget asks R (`join_diagnostics_request`,
  full data); the widget computes in the browser. Change both together. The date-rule check is a third twin:
  `sv_join_diagnostics(rule =)` (R/join_rules.R), `sv_lazy_join_diagnostics(rule =)` (R/lazy.R) and
  `joinDiagnostics(..., { rule })` (sv-pipeline.js) agree with dplyr's `join_by()`; a rule that does not hold
  gives `{error}` with none of the usual fields, and the engine shows that as the key-check error state.
  `join_diagnostics_request` is `{id, left, right, by, rule?}` (`id` = `pipeline.joinSig()`; a rule column missing
  from a table answers `Not in <table>: <col>` like a key); the reply adds `rule`, `rule_kind`, `rule_dropped_x/y`
  and `strict_args`, which the engine hands to `pipeline.setJoinCheck(id, strict_args)` for Strict.
- **Strict applicability:** the join check runs on the two original cards, so `relationship =` / `unmatched =` are written only where that check still holds. `Pipeline.strictApplies(step)` (sv-pipeline.js) returns `{ok, reason}`: not ok when a card is lazy, when an earlier enabled filter, join, summarise, pivot or custom step is on the left table's chain, or when the right table has steps of its own. `compose()`, the Strict checkbox (`joinOptionsHtml`: disabled, title = reason) and `strictLine()` all ask it; the step keeps its `strict` flag. Do not duplicate the test.
- **Join check cache:** a path that replaces a card's data (none exists today) must call `clearJoinChecks()` and reset `joinDiag`, or stale checks (and rule drops) stay on screen.
- **SUPP merge (0.7.0):** same twin rule. `sv_supp_check()` (R/supp.R), `SideviewPipeline.suppCheck()` (sv-pipeline.js)
  and `sv_lazy_supp_check()` (R/lazy.R) return the same fields; test-supp.R / test-lazy.R hold them to each other.
  The merge is a pipeline step `{kind: 'supp', key, table, supp, rdomain, keys, idvars, qnams, rdomain_col}`
  whose plan is captured when it is added; `compose()` writes the plan and guards into the R code (clash guard
  reads `names(dplyr::collect(utils::head(<parent>, 0)))`: plain `names()` fails on dbplyr, `colnames()` on an arrow
  query; on an arrow chain a numeric IDVAR key is cast to the parent's Arrow type, so int64 parquet keys join). A QNAM without QLABEL has label `""`. `IDVARVAL` rows that
  do not convert are `bad_idvarval`, never orphans (`n_matched + n_orphan + bad == n_supp`). Double keys are
  converted only if one decimal regex matches, in R and JS alike; the whitespace around a key is the ASCII class
  `sv_supp_ws` / `SUPP_WS` (never `\s`/`trim()`), and generated `grepl()` uses `perl = TRUE`; `abs(x) > 1e308` is bad.
  An Arrow int64/uint64 key is always a double key (as duckdb BIGINT). Clashes with columns made by earlier chain
  steps are caught in the browser (`columnsBefore()`), not by the code guard. Change a twin together with the others.
- **Compare (D3):** same twin rule. `sv_compare_code()` (R) and `compareCode()` (reached through `deriveExpr()` for the
  compare ops, sv-pipeline.js) are byte-equal; `sv_compare_plan()` / `sv_lazy_compare_plan()` and `sv_compare_rows()` /
  `sv_lazy_compare()` are twins; all of them are tested, so change them together.
- **Stack (D2):** same twin rule. `sv_stack_check()` / `sv_stack()` (R/stack.R) and the `stack` derive op. The column plan
  is `sv_stack_plan()` (in memory) and `sv_lazy_stack_plan()` (duckdb / Arrow): twins, held to each other by
  test-stack.R and test-lazy.R. The rows are `sv_stack_rows()` (in memory) and `sv_lazy_stack()` (one duckdb
  `union_all`, never collected): twins too, and both tested against each other. The generated code is also a twin:
  `sv_stack_code()` (R) and `deriveExpr()` for `op: 'stack'` (sv-pipeline.js) are byte-equal (the code pair; R builds
  the card with `sv_stack_rows()` / `sv_lazy_stack()`, not by running that code); test-derive-code.R evaluates it for
  every backend. `sv_escape_ident()` / `ident()` and `encodeString()` / `str()` quote names and strings the same way
  (ASCII-only syntactic names, control characters escaped; test-stack.R). The step is a `derive` step
  `{op: 'stack', inputs: [2..8], args: {fixes, id_col?, plan}}`; the plan is R's and is embedded verbatim, including
  `tz_text` (the R-computed DST offset tree for a lazy date-time to text cast: JS never ports time zone rules).
  `sv_stack_clean()` adds `tz_text` whenever a card is lazy, even when the plan came from a preview, so JS never
  writes lazy code without it. An opened state's stack steps take the plan R makes from the data as they are then
  (`sv_derive_state_refresh()`; `derivedArrived()` refits a lazy card's step in the browser). A dttm to date cast is
  the UTC date and a date to dttm cast midnight UTC on both sides (lazy uses `epoch_us()`: duckdb 1.4.3 has no ICU
  for `CAST(TIMESTAMPTZ AS DATE)`). duckdb names are case-insensitive, so a lazy plan with `AGE` and `Age` left apart
  carries `case_clash` and `sv_lazy_stack()` refuses it. Without duckdb a whole lazy card is refused, never stacked
  from its preview. `deriveArgsKey()` includes the sorted `fixes` and `id_col` (the default `source` counts as none),
  so two stacks of the same inputs with different fixes are different cards. The wire is `stack_check_request`
  (`{id, tables, fixes?}`, cleaned by `sv_stack_clean()`; the id is a short sequence, and an id over 200 characters
  gets a toast, not silence) and `sideview_stack_check`; Open is a `derive_request` with `op: 'stack'` whose plan is
  made once (`sv_derive_check()` hands validate's clean result to `sv_derive_card()`). Ticking a rename drops the
  cast picked for the renamed column. The card is named after the first table picked. Known gaps: `Sys.timezone()`
  is pinned in lazy date-time code; a number cast to text can be `"1e+05"` in R and `"100000"` in duckdb (and keeps
  15 significant digits in R); a dttm cast to text drops fractional seconds; a cast `integer64` loses digits beyond
  2^53; none of these is counted as `NA`. duckdb tables carry no labels (Arrow tables do); `tz_text` adds about 20 KB
  of saved state per date-time column per input; `sv_stack(check =)` compares a lazy input by name only (data frames
  also by columns, types and row count); `id_col` is not an input to the check, so a user-chosen `id_col` would
  desync the preview from Open (the browser sends none); Check then Open still plans twice; no lazy stack server
  test; `sv_stack_clean()` has no unit test for 9 tables or the cast-target whitelist (the handler pre-checks).
- **Derived cards (D1):** the rows behind a check count as a card of their own. Ops (`sv_derive_ops`): `unmatched`
  and `outside_window` (join check; `args` = `{by, rule?, side}`), `supp_orphans` and `supp_bad_idvarval` (SUPP check;
  `args` = `{rdomain?}`, the plan is R's). `sv_unmatched()` and `sv_supp_orphans()` are the console forms; all of them
  and the canvas builder call `sv_derive_rows()`, so the rows agree. The client sends `derive_request`
  (`{id, op, inputs, args, name?}`); `sv_derive_validate()` / `sv_derive_clean()` check it against the R store (inputs
  must be store names, args off the allowlist are dropped), and a refusal is `sideview_derive_result {id, error}` with
  nothing changed. Success is `sideview_card_add` with `request_id`. `derive_forget {name}` tells R the browser dropped
  a derived card (honoured only for a card with `derived`).
  - **Inputs as loaded:** a derived card is built from its input cards as they are in the R store (the data loaded,
    before the pipeline's own steps), never from a pipeline result. A lazy input stays lazy (`sv_derived_source()`
    in `R/lazy.R`, one tbl on the session connection); `source` is still never serialised.
  - **Code twin:** the pipeline step is `{kind: 'derive', key, table, op, inputs, args}` (`deriveStep()`),
    composed by `deriveExpr()` in sv-pipeline.js. The R builder and the composed code are twins:
    `test-derive-code.R` evaluates the generated code on the inputs and compares it with `sv_derive_rows()` for every
    op, side, rule shape and backend. Change both together.
  - **Liveness is computed, not stored:** `deriveLive(step)` is true when the step is enabled and both inputs are on
    the canvas or written by another live derive step; a derived card without a live step is dropped. `deriveFor(name)`
    finds the live step. `compose()` writes producers first.
  - **Reconcile loop** (`reconcileDerived()`, run on every card or step change): drops derived cards whose step is gone,
    and for each live step whose card is missing sends a `derive_request` (R builds it again). One request per card in
    flight (`derivePending`, swept after 30 s, so a very slow lazy build can be asked twice); a refused request marks the
    card `_deriveFailed` until the card set changes. A card R removed (cascade or failed rebuild) sets `_rRemoved`: no
    request goes out until an input has left the canvas and come back.
  - **Module:** removing an input removes its derived cards first (steps kept); replacing an input rebuilds them in
    place under the same name (`card_replace`; a failed rebuild removes the card and its dependants, one toast); adding
    an input back lets the browser re-add the card through the reconcile loop. State with derive steps is built before
    it reaches the canvas (`sv_derive_from_state()`, `sv_module_add_derived()`); a step that cannot be built is skipped.
  - **Gadget:** `sideview(state =)` builds the derived cards of in-memory inputs up front; with `skip_lazy = TRUE` a step
    that reads a lazy card is built by the server (`sv_derive_from_state()` on whole tables, in the session) and sent
    as `sideview_card_add` at the first flush, not by the reconcile loop. The gadget shares one `sideview_card_add` path
    with module mode. A derived card gets the tag of the card it keeps (`finish()` in `sv_derive_card()`: the SUPP
    card's tag for the SUPP ops); the CDISC finalize does not tag it on its own.
  - **Widget:** no R, so no offers, no buttons and no derived cards; a saved state's derive steps stay in the file and
    `compose()` still writes them whenever both inputs are on the canvas (`deriveLive()` needs the inputs, not the
    derived card). One toast says the tables are not shown.
  - **Module replace of a SUPP input:** the rebuilt derived card's `derived` (op, inputs, args with R's new plan)
    travels in `sideview_card_replace`; `replaceCard()` writes it into the matching derive step, so `$code()` follows
    the new data.
  - The list view shows the same offers as real buttons (`appendOffers()`, `data-sv-lv-action="derive-open"`); a
    duplicate open zooms the existing card and announces it.
- **Pharmaverse code (0.11.0):** same twin rule. `combine_supp` is a field of every SUPP check without an `{error}`.
  `sv_supp_check()` (R/supp.R, data frames: it does not dispatch to the lazy check) and the internal
  `sv_lazy_supp_check()` (R/lazy.R, used by the server handler for a lazy card; never ok, `combine_supp() needs data
  frames`) return only `{ok, reason, prep}`; `SideviewPipeline.suppCheck()` (sv-pipeline.js) returns the same plus `installed: null`; only the server
  handler (R/app_server.R) sets `installed` to `TRUE`/`FALSE`. test-supp.R / test-lazy.R hold the twins together.
  The guard block (`suppCombinePrep()`) only calls `stop()`: it covers the later-cut changes that were found and tested,
  not every possible one, and its label guard compares with the step's captured plan.
  Governing rule: write `metatools::combine_supp()` only when its result equals the dplyr code's; otherwise
  the step stays dplyr and says why. `Pipeline.style` (`"dplyr"` / `"pharmaverse"`, `setStyle()`, no undo) is part of the
  pipeline state without a schema bump; a state without one loads as dplyr. `setSuppCheck(key, field|null)` is not state.
  `combineSuppApplies(step)` is rule 6 (no enabled step on the SUPP card; on the parent, only filter, arrange and
  supp steps before or after the merge, since the dplyr code labels the QNAMs where the parent chain ends) and `combineSuppFor(step)` is the one decision that
  `compose()` and the step line both ask (a stale check, i.e. drift, gives dplyr with `Merge needs refreshing`): do not
  duplicate it. A merge with no check, or a lazy / preview / failing one, stays dplyr. The R-only `installed` flag only
  changes the step-line text. Change a twin together with the others.
- **Column inspector / codebook:** same twin rule. `sv_column_profile()` / `sv_codebook()` (R/codebook.R) and
  `SideviewPipeline.columnProfile()` / `codebookRow()` / `codebookCsv()` (sv-pipeline.js); `test-codebook.R`
  checks the fields, the issue texts and that the JS CSV is byte-equal to `write.csv(sv_codebook(...))`.
  The gadget profiles in R (`column_profile_request`) and writes the codebook via `sv_choose_codebook_path()`
  (RStudio save dialog, else a new `codebook*.csv` in `getwd()`); the widget downloads a CSV Blob.
- **Workspace state (v0.3.0 schema):** `engine.getState()` / `applyState()` (sideview.js) and `R/state.R`.
  State crosses the wire as **JSON text** (`sv_state_json()` / `sv_state_from_json()`), never as a Shiny
  list, so one-element arrays and nulls survive. `sideview(state =)` embeds it in
  `<script class="sideview-state">`; the widget passes `options.state`. Cards match by **name**; a restored
  view skips the first auto-fit. Open replaces joins and pipeline and clears undo. A card entry may carry an optional
  `user_sized: true` (the user resized it; no schema bump), which `applyState()` turns back into `data-sv-user-sized`.
  With the Accessible canvas on, `getState()` saves an auto-sized card's default size (its inline width/height), never
  the enlarged on-screen size, so a state saved with the switch on opens the same with it off. Save/Open use
  `rstudioapi::selectFile` only in the gadget when `data-sv-file-dialog="r"`; otherwise browser download/file picker.
- **CDISC tags:** `sideview(..., cdisc = "auto")`, `sideview_widget()`, `save_sideview()`, `sideviewServer()` and
  `sv_codebook()` take `cdisc`: `"auto"`, `FALSE`, or a named character vector of domains (`c(my_ae = "AE")`).
  Tags are derived in R (`R/cdisc.R`, catalogue in `inst/extdata/cdisc_catalogue.csv`) and are **never saved in
  state**; they are re-derived on load. `domain` is a codebook twin column (R and `codebookRow()` in JS, byte-equal
  CSV). `workspace state` carries one optional field, `view.labels_row` (the `L` toggle), without a schema bump.
  Only column labels and a domain line reach the LLM schema text, never rows.
- **"No code"** is `""` on the wire. The drawer placeholder (`# Connect two columns ...`) is display text only;
  test with `sv_is_no_code()` (R) / `isNoCode()` (JS). Done with no code returns `NULL`.
- **Gadget lifecycle:** `sv_new_lifecycle()` counts sessions; the app stops only after
  `getOption("sideview.session_grace", 5)` seconds with no session, so a browser reload survives.
- **Splines:** visible paths (`.sideview-connector-svg`, z 25) are `pointer-events: none`. Clicks go to invisible
  hit paths in `.sideview-connector-hitlayer` (z 5, below the cards at z 10). Create a hit path for every new
  connector (`attachHitPath`) and prune it on removal (`pruneHitPaths`).
- **Theme:** `theme =` on `sideview()`/`sideview_widget()`/`sideview_ui()` takes `"auto"|"light"|"dark"`,
  `sv_theme()` or a `bslib::bs_theme()` (R/theme.R → `sv_resolve_theme()`). The gadget carries it as the
  container class `sv-theme-<mode>` plus inline `--sv-*` overrides; the widget passes `options.theme` /
  `options.themeVars` to `Engine.applyTheme()` / `applyThemeVars()`. Dark tokens live in
  `.sv-theme-dark` and in `@media (prefers-color-scheme: dark) .sv-theme-auto` — keep the two blocks equal
  (test-theme.R checks it, plus WCAG ≥ 4.5:1 for every text/background pair).
- **Mode-aware overrides:** a custom colour that must differ by mode uses `-light`/`-dark` variables:
  the base block has `--sv-primary-text: var(--sv-primary-text-light, #...)`, the dark blocks use
  `var(--sv-primary-text-dark, #...)`. Use `--sv-primary-text` (not `--sv-primary`) for primary-coloured *text*.
- **`view =` (0.8.0):** `sideview()`, `sideview_widget()`, `save_sideview()`, `sideview_ui()`, `sideviewUI()` take
  `view = getOption("sideview.view", "canvas")`, validated with `match.arg(view, c("canvas", "list"))`. Gadget and module
  containers carry `data-sv-view`, the widget `options$view`. `view.mode` (`"canvas"`/`"list"`) in workspace state is kept
  only when valid (`sv_state_scrub()` drops anything else, also on load) and never required.
- **List view shell (0.8.0):** `inst/www/sv-listview.js` defines `SideviewListView` (loaded after `sv-pipeline.js`, before
  `sideview.js`; in `sv_asset_version()` and the dependency). `engine.setView('canvas'|'list')` (sideview.js) sets `hidden` +
  `aria-hidden` on the viewport, minimap and the two connector SVGs (the canvas `transform` is untouched), flips every
  `[data-sv-view-toggle]` (`aria-pressed`; the name stays "List view"), announces "List view"/"Canvas view", and moves focus to
  the list's first `<h2>` (or the container). The list (`<section class="sideview-listview" role="region">`) is built the
  first time and appended to the container; its text is DOM/`textContent` only (never `innerHTML` for a name). Sections, in
  order: Summary, Tables, Join, Merge SUPP, Transform, Pipeline, Code, Copilot (only when `engine.llmAvailable()`: not `sv-no-llm`,
  and a module, or `data-sv-llm="true"`). Result hooks `onJoinDiag` / `onSuppCheck` / `onColumnProfile` go through
  `engine.listHook()` (a failing hook never breaks the reply). A hidden card measures 0, so `setView('list')` keeps card sizes in
  `_hiddenGeom` for `getState()` and `setView('canvas')` re-renders the virtual tables. No new Shiny input or message.
- **List view tables (0.8.0):** one `<div data-sv-table="<name>">` per card (`h3#<ns>sv-lv-t-<i>`, a `<ul>` of columns, or
  `<details>` closed above 30 columns, then a captioned `<table>` with Ruling 2 counts, 25 rows a page). The rows come from
  `VirtualTable.cellText(i, col)` (the string the card cell shows, `null` while a remote block is missing; the card render
  shares `cellDisplay()`) and refill through `VirtualTable.onBlock(fn)` (returns an unsubscribe, called in `destroy()`).
  List-view updates are narrow: `refresh()` (list shown), `updateSections()` (the Copilot section comes and goes; used by
  `sideview_llm`), `syncTables()` (cards came, went or were replaced; called from `syncTableMeta()`) never rebuild the shell,
  so focus, scroll, the rows page and an open Columns list survive; only `render()` rebuilds everything. Sort goes through
  `engine.sortColumn`; Filter calls `engine.openBuilder('filter', {table, column})` when it exists (Task 15). Lazy cards are
  paged through `sideview_rows_request` windows only; the list never collects a table.
- **Card messages announce** "Table <name> added." / "replaced." / "removed." (not the `initial` population); the list view re-renders only that table's section, and reads "No tables yet." when empty.
- **List view counts (0.8.0):** `sparkStats` (sv-listview.js) reads header badges only for full in-memory cards; lazy, truncated and `rowsBasis="preview"` cards, `~N distinct` and unexpected titles give no count. Canvas-side filter changes call `listHook('renderTable')`, so the list follows them.
- **View precedence:** the `view` argument (`data-sv-view` / `options.view`) is the default; a restored workspace state's valid
  `view.mode` wins over it (at start, `applyState` records it and the constructor applies it after the first layout; on Open,
  `setView` at once). A state without `view.mode`, or with an invalid one, leaves the view as it is. The starting view is
  silent (no announcement, no focus move). `getState().view.mode` is `engine.view`.
- **Shortcuts switch (WCAG 2.1.4):** `engine.shortcutsOn()` reads `localStorage['sideview.shortcuts']` (`on`/`off`, in
  try/catch; a throw is no value), then the in-memory choice `setShortcuts()` made, then the R default
  (`data-sv-shortcuts="false"` from `options(sideview.shortcuts = FALSE)` in `sv_ui_build()`, or
  `options.shortcuts === false` from `sideview_widget()`), then the view (off in `engine.view === 'list'`). `setShortcuts(on)`
  updates every `[data-sv-shortcuts-switch]` and announces. The single-key handler returns early when off; `Ctrl+K` and
  `Ctrl+Enter` are never gated. No new Shiny input or message.
- **Announcements:** `engine.announce()` (one `.sideview-announcer` per engine). A new result or step path announces through it.
- **Shortcuts:** gated by `shortcutsOn()`. The `sideview.shortcuts` option is carried as `data-sv-shortcuts` / `options.shortcuts`.
- **Table ARIA:** each card `<table>` has a `<caption class="sv-sr-only">` (card name, set with `textContent`, so no escaping is
  needed), `aria-rowcount = getRowCount() + 1`, `aria-colcount`, the header row `aria-rowindex="1"` and data rows
  `aria-rowindex = virtual index + 2`, all rewritten in `VirtualTable.render()` (so sort, filter and remote row blocks keep them
  right). The gadget's server-rendered tables get the caption in `initExistingCards()`. Lazy tables are never collected: the
  count is the remote or true row count.
- **Keyboard:** single-key shortcuts (F, 0, +/-, T, D, M, L, /, ?) and Ctrl+K (card search) only fire when the
  canvas owns the keyboard (`ownsKeyboard()`: standalone, or focus inside an embedded widget) and never while
  typing. Ctrl+Enter submits a drawer builder. Add new shortcuts to the `?` dialog list too.
- **Accessible canvas (0.9.0):** one switch, opt-in. Each engine resolves its state **once**, in the constructor
  (`resolveAccess()`): `localStorage['sideview.access']` (`on`/`off`, try/catch), then `_accessMem`, then the R default
  (`data-sv-access="true"` from `access =` on `sideview()` / `sideview_ui()` / `sideviewUI()` via `sv_ui_build()`, or
  `options.access` from `sideview_widget(options = list(access = TRUE))`; all follow `options(sideview.access)`; the widget
  and `save_sideview()` have no `access` argument), else off. `accessOn()` returns the cached value and only
  `setAccess()` changes it, so toggling one canvas leaves another on the page as it is until the next load.
  `setAccess(on)` stores it, toggles the class
  `sv-access` on the container, updates every `[data-sv-access-switch]` (a `role="switch"` in the `?` dialog beside the
  shortcuts switch), redraws the `?` key list and announces `Accessible canvas on.` / `off.`. Not in workspace state; no
  new Shiny input or message. Everything below happens only with the switch on.
  - **Zoom floor:** `minScaleNow()` is 1.0 (`ACCESS_MIN_SCALE`), else `options.minScale`; panzoom's `setMinScale()` clamps
    wheel, `-`, `0`, `fitAll()` and a restored state (`canvas.zoom`). Switching on below 1.0 zooms to 1.0 around the focused
    card, else the view centre; switching off restores the range without changing the zoom.
  - **CSS:** `.sideview-container.sv-access` overrides `--sv-*` with `!important` (so tokens beat inline `theme =`; the
    test-theme.R parser strips `!important`): text 7:1, lines/ports/focus ring 4.5:1, dark and `prefers-color-scheme` blocks
    kept equal. Text is at least 16 px, controls at least 24 x 24, focus ring 3 px + 2 px offset. Layout is CSS only: no
    inline geometry writes for sizes, user-sized cards (`data-sv-user-sized`) keep their size. Switching on, if the grown
    cards overlap, `accessLayout()` keeps the old positions in `_preAccessLayout` and runs `arrangeCards(false)`;
    switching off puts back each card the user has not moved since, so the default layout returns.
  - **Splines:** each accepted join gets `data-sv-pat`: the lowest of 0..5 that no live join uses (a key set added in one
    call shares one), else the live join count mod 6. The six dash patterns apply under `sv-access` and `forced-colors`
    only, with `stroke-linecap: butt` (round caps close the 4 px gaps); never `6 6` (suggested) or `4 4` (draft). Arrowheads are marker `<path>`s in
    `defs.sideview-marker-defs` (`ensureMarkerDefs()`), so count connectors as `.sideview-connector-svg path` outside `defs`.
  - **OS blocks (always on, switch or not):** `@media (forced-colors: active)` (system colours, patterns and markers kept)
    and `@media (prefers-contrast: more)` (stronger borders and focus ring; layout and zoom range unchanged), both scoped under
    `.sideview-container`.
  - **Precedence of colours:** forced-colors system colours, then the `.sv-access` tokens (`!important`), then inline
    `theme =` overrides, then the `prefers-contrast` tokens, then the default tokens. The R argument or option sets the start
    state of the switch; the stored browser choice wins over it.
  - **Keys (focus-scoped, so they work with the shortcuts switch off; never while typing; only when `ownsKeyboard()`):**
    card: Arrows 20 px, Shift+Arrows 100 px (debounced 500 ms: one `sideview_card_moved`, one announcement), Alt+Arrows jump to
    the nearest card, Enter focus the first header, PageUp/PageDown/Home/End scroll the body. Header (roving Tab stop): Left/Right,
    Esc back to the card, `C` connect (Enter completes through `addConnection`, as a click does), Delete removes the join
    (menu `div.sideview-kb-menu[role=menu]` when several), `J` jumps to the joined column. The jump modifier is the one
    constant `JUMP_MODS = 'alt'` in sv-access.js: Alt+Left is the browser's Back key. If any host (Edge, RStudio dialog or
    Viewer) navigates away, change it to `'ctrl+alt'` and update the `?` rows (`ACCESS_SHORTCUTS`), tests and docs.
    Add new access keys to `ACCESS_SHORTCUTS` too.
  - **Focus following:** `ensureVisible()` pans only (never zooms) so the item plus 24 px sits clear of the drawer, AI bar
    and minimap. Cards get `tabindex="0"`, `role="group"`, `aria-label`; each card body is a second Tab stop
    (`tabindex="0"`, `role="region"`, `"<name> rows"`). Every attribute change goes through one record so `disable()`
    restores the original exactly; it then moves focus to the container if it was on an element that lost its tab stop
    (header, card body), and a dialog's return focus (`engine.returnFocus()`) falls back to the container the same way.
    Reading order re-orders card nodes by position and restores them on disable.
  - **Tests:** `test-access-browser.R` (keys, Tab order, floor, switch precedence, forced-colors with
    `Emulation.setEmulatedMedia`), `test-a11y-browser.R` (axe with the switch on, **no** accepted rules; switch off keeps
    `SV_AXE_ACCEPTED`; each panel state is asserted as reached before axe runs),
    `test-theme.R` (7:1 and 4.5:1 for the access tokens). Manual pass: `plans/2026-11-15-access-manual-script.md`.
- **Navigation:** `zoomToCard()` (title double-click, minimap click, Ctrl+K result), the minimap (`renderMinimap()`,
  redrawn from `scheduleConnectorUpdate()`) and the search dialog live in `sideview.js`. Chrome z-order: minimap 105 <
  overlay 110 < drawer 120 < AI bar 130 < search/shortcut scrims 140. The container gets `sv-narrow` (< 720px) and
  `sv-compact` (< 1040px) from `initLayoutObserver()`; use them for responsive chrome rules.
- **Assets:** dependency versions come from `sv_asset_version()` (package version + content fingerprint),
  so browsers never serve stale JS/CSS. Don't hard-code a version for `sideview.js`/`sideview.css`.

## Build, test, run (Windows, R 4.5.2)
- R: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"`
- Tests: `Rscript -e "devtools::test()"`; full check: `Rscript -e "devtools::check()"`.
  Real-browser tests are skipped "on CRAN": set `NOT_CRAN=true` to run them.
- Accessibility tests: `test-a11y-browser.R` (AX tree, keys, axe-core). Install `npm install --no-save axe-core@4.10.3`
  or set `SV_AXE_PATH`. An accepted axe rule goes in `SV_AXE_ACCEPTED` with its reason.
- Prefer real input (`b$Input$dispatchMouseEvent` via chromote) over `dispatchEvent` in browser tests —
  synthetic events skip hit-testing, which is how overlay bugs slipped through.
- JS syntax: `node --check inst/www/sideview.js`
- Docs: `Rscript -e "devtools::document()"` (roxygen → `man/`, `NAMESPACE`); site: `pkgdown::build_site()`
  (set `RSTUDIO_PANDOC` to RStudio's `resources/app/bin/quarto/bin/tools`). Every push to `main` deploys the site twice:
  Pages' legacy build serves the committed `docs/` folder, and `.github/workflows/pkgdown.yaml` rebuilds it in CI
  and deploys that (usually last). Keep the committed `docs/` current too. Run
  `pkgdown::check_pkgdown()` first: every export must be in the `_pkgdown.yml` reference index. pkgdown renders
  every root `.md`, so delete `docs/CLAUDE.*` / `docs/MEMORY.*` and their `sitemap.xml` / `search.json` entries
  (the workflow does this in CI with its "Drop dev notes" step).
- Try it: `devtools::load_all(); sideview(mtcars, iris, viewer = "browser")` (also `"dialog"`, `"pane"`)

## Conventions
- **Standing rule:** Every new feature (0.9.0 D, 0.10.0 E and later) must work in the list view
  (`inst/www/sv-listview.js`) and print as sentences in the console (a `print()` method over `sv_say_*`, with a JS twin
  where the browser shows the same result). A feature with a canvas-only path is not finished. Say what was checked with
  a screen reader and what was not: do not claim an NVDA pass until `plans/2026-11-14-nvda-script.md` has been run.
- Exported R functions use the `sv_` prefix (except `sideview*` entry points), `snake_case`, roxygen docs.
- Heavy/optional packages (`arrow`, `duckdb`, `gt`, `flextable`, `bslib`) stay in `Suggests:` behind
  `requireNamespace()` guards.
- CSS: use `--sv-*` design tokens, no hard-coded colours in rules; every token used must be defined.
  Scope all rules under `.sideview-container` — the widget must not restyle a host page.
- Icons: inline SVG icons only — **no emoji/Unicode glyph icons** (they render inconsistently on Windows RStudio).
- JS: escape any user/table-derived text before `innerHTML`; use `CSS.escape` for attribute selectors;
  batch connector redraws with `requestAnimationFrame`; every global listener must be removed in `destroy()`.
- Generated R code must `parse()` — add a test for every new code generator.
- Privacy: only schema summaries go to the LLM, never raw rows.

## Verification rule (important)
`tests/testthat/gui-test-runner.js` runs against a **mock DOM** and cannot catch layout bugs.
Every UI change must also be checked in a **real browser** (shinytest2/chromote layout tests in
`tests/testthat/test-layout-browser.R`) and, for gadget behaviour, **in RStudio itself**
(dialog, Viewer pane, external browser). Record what was verified in `MEMORY.md`.

## Tracking
- `MEMORY.md` — running change log, decisions, open issues, backlog. Update it with every change.
- `plans/` — design specs; `plans/2026-10-24-ui-qa-checklist.md` — the feature QA checklist.
- `NEWS.md` — user-facing release notes.

