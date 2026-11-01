# sideview Shiny module and proxy: design

- **Date:** 2026-10-31
- **Release:** sideview 0.4.0, sub-project 3 of 4 (see `MEMORY.md`, "Next release")
- **Status:** design approved in chat, section by section; awaiting review of this written spec
- **Builds on:** `plans/2026-10-25-lazy-full-data-design.md` (R-backed rows, lazy cards) and
  `plans/2026-10-26-join-rules-design.md` (join check, Strict)

## 1. Problem

sideview runs as a gadget (one canvas, R-backed, ends when the user clicks Done) or as an htmlwidget
(browser-only, cards fixed when it is rendered). Neither can live inside a user's own Shiny app and be
driven from its server code. A team that wants a canvas in a review app, fed by a database query that
refreshes, cannot add, swap or remove tables, push a saved workspace, or read back what the user built.
The gadget's inputs and custom messages are also global names, so a page can hold only one canvas.

## 2. What the user told us

- All the use cases apply: refreshing data in a deployed app, loading tables from server code,
  reading the user's pipeline/code back, more than one canvas per app.
- **R-backed** (recommended option): full-data sort/filter, arrow/duckdb lazy cards, the join check and the
  column inspector run in R, as in the gadget.
- **Approach A:** a Shiny module, `sideviewUI(id)` + `sideviewServer(id, ...)`, that reuses
  `sideview_server_impl()` and returns a proxy; not a proxy for the plain htmlwidget, and not a browser-only
  widget update API.

## 3. Goals and non-goals

**Goals**
1. A module pair that puts an R-backed canvas into any Shiny app, several per page.
2. Pipe-able verbs to add, replace and remove cards, set state and highlight columns, from the module's
   server function or anywhere else in the session through `sideviewProxy()`.
3. Read-back reactives for the composed code, the pipeline, the workspace state and the card names.
4. A replace keeps the card's place and every step that still applies; it never silently drops work.
5. The gadget and the widget behave exactly as today; their tests pass without edits.

**Non-goals**
- A proxy for `sideviewOutput()` / `renderSideview()`. The htmlwidget stays browser-only; the module is the
  way to control a canvas from a server. (This replaces the `MEMORY.md` roadmap line about updating a
  `sideviewOutput()` canvas.)
- Running code from the browser in a deployed app (Insert Script, Run & Exit, Run in R, Run Console).
- Keeping layout and pipeline when `renderUI` re-renders a canvas (it comes back with fresh layout).
- Comparing column types on replace (the join check that re-runs catches key-type mismatches).

## 4. API

```r
sideviewUI(id, height = "600px", title = NULL, theme = "auto")

sideviewServer(id, cards = list(), state = NULL, llm_fn = NULL)   # returns a sideview_proxy

sideviewProxy(id, session = shiny::getDefaultReactiveDomain())    # the same proxy, from elsewhere

sv_add_card(proxy, x, name)
sv_replace_card(proxy, name, x)
sv_remove_card(proxy, name)
sv_set_state(proxy, state)
sv_highlight(proxy, name, cols)
```

- `sideviewUI()` renders the gadget's chrome (toolbar, drawer, canvas) in **embedded mode**: no page-level
  `html, body` rules, the wheel scrolls the page, the container carries `data-sv-ns = NS(id)("")`, and it
  starts with **no cards**. `theme` takes what `sideview_ui(theme =)` takes.
- `sideviewServer()` wraps `shiny::moduleServer()` around `sideview_server_impl()`. `cards` is a list
  (as `sideview(...)` takes, named) or a **reactive** returning one. `state` is a state object or JSON text
  applied once after the first cards arrive. `llm_fn` as for `sideview()`; the AI bar and copilot appear
  only when it is given.
- Verbs return the proxy invisibly, so they pipe:
  `sideviewProxy("review") |> sv_replace_card("labs", labs_now()) |> sv_highlight("labs", "lab_date")`.
- The proxy also carries the reactives `$code()`, `$pipeline()`, `$state()`, `$cards()` (section 8).
- `name` is `character(1)`; `cols` is a character vector; `x` is anything `sv_normalize_arg()` accepts
  (data frame, tibble, arrow/duckdb table, `gt`, `flextable`, `table`, ...).

### Code execution is off in module mode

Insert Script, Run & Exit, Run in R and Run Console `eval()` code sent by the browser. In a deployed app any
visitor can forge that code. In module mode these buttons are not rendered and their inputs
(`inject_script`, `send_console`, `send_console_and_exit`, `eval_env`, `sideview_done`, `sideview_cancel`)
are refused server-side: the handlers are not registered. The docs say that `$code()` is composed in the
browser and must be treated as untrusted text (show it, save it, review it), never `eval()`ed unattended.

## 5. Namespacing

- Every input the engine sends is prefixed with the container's `data-sv-ns`: `review-column_mapped`.
  `sendToShiny(name, value)` adds the prefix; the gadget's prefix is `""`, so its names are unchanged.
- Shiny allows one handler per custom message type per page. The handlers are registered **once**
  (guarded by a flag on `window`) and route each message by a new `ns` field to an engine registry
  (`ns -> engine`). A message with no `ns` goes to the engine registered under `""` (the gadget).
- An engine registers under its `ns` when it starts and unregisters in `destroy()`. When an engine
  registers for an `ns` that already has one, the old engine is destroyed first. The router also drops
  engines whose container is no longer in the document. A message for an unknown `ns`, or for a card the
  engine does not have, gets a `console.warn` and is ignored.

## 6. Add, replace and remove

Cards are matched by **name** everywhere, as workspace state already matches them.

**`sv_add_card(proxy, x, name)`** adds an auto-placed card. A name already on the canvas is refused in R
before anything is sent: `Card 'labs' already exists; use sv_replace_card()`.

**`sv_replace_card(proxy, name, x)`** keeps the card where it is and changes its data:

- **Kept:** position, size, minimized state, zoom. The engine gets the new columns, `dims` and
  `totalRows`, clears the card's row cache and re-requests the visible rows. R swaps the card in its store
  (including a lazy card's `source`).
- **Checked:** every pipeline step on that table is tested against the columns it would see at its place
  in the table's chain (the new columns, plus earlier renames and mutates). A step that still has all its
  columns stays as it is. A step that names a missing column is **disabled, not deleted**: it stays in the
  Pipeline tab and can be re-enabled with one click if a later refresh brings the column back. A spline
  whose column is gone is removed and its join step disabled.
- **Told:** one toast lists what was disabled:
  `labs refreshed: 2 steps disabled (lab_dt not found)`. No toast when nothing was disabled.
- **Reset:** `clearJoinChecks()` and `joinDiag` (as `CLAUDE.md` requires for any path that replaces a
  card's data); checks for live joins run again. Highlights on missing columns are cleared.
- **Undo:** kept if nothing was disabled; cleared if anything was (older snapshots name columns that no
  longer exist).

**`sv_remove_card(proxy, name)`** applies the same rule as if every column were missing: the card's
splines are removed and its steps disabled, with the same single toast.

**Reactive `cards =`:** each time it fires, it is compared with the canvas by name: a new name is added,
a name that is gone is removed, and a name still present is replaced, unless the new object is
`identical()` to the one in the store, in which case nothing is sent.

**`sv_set_state(proxy, state)`** behaves exactly like Open: layout, joins and pipeline are replaced and
undo is cleared; cards named in the state but not on the canvas are ignored.

**`sv_highlight(proxy, name, cols)`** sets the card's highlighted columns as a header click would;
columns not on the card are ignored.

## 7. Transport and the R card store

**Card store.** `sideview_server_impl()` today builds `normalized_cards`, `cards_by_name` and
`cards_by_id` once. These become one mutable store, `sv_card_store()` (an environment with `add`,
`replace`, `remove`, `get`, `names`), and every handler looks cards up through it: row windows, the join
check, the inspector, the codebook, Auto Map, discrepancies. A replaced card is what the next request sees.
The gadget uses the same store and never changes it. Clients only name cards in the store, so a forged
input cannot make R read any other object.

**Card payload.** The card-to-JSON code in `sideview_widget()` (`R/widget.R:105-127`) moves into
`sv_card_payload(card, preview_rows = NULL)`, used by the widget (all rows, as today) and the module. The
module sends **only a 500-row preview** (the gadget's preview size) plus `totalRows` and `remote: true`;
the engine attaches remote rows the way the gadget does (`attachRemoteRows`), so sort, filter and scrolling
are served from R. Full data never goes to the browser.

**Messages (R to client), each with `ns`:**

| Message | Payload |
|---|---|
| `sideview_card_add` | `{ns, card}` (`card` = `sv_card_payload()`) |
| `sideview_card_replace` | `{ns, card}` |
| `sideview_card_remove` | `{ns, name}` |
| `sideview_state_set` | `{ns, state}` (JSON text, as `sv_state_json()`) |
| `sideview_highlight` | `{ns, name, cols}` |

Existing messages (`sideview_rows`, `sideview_toast`, `sideview_join_diagnostics`, ...) also carry `ns` in
module mode.

**Inputs (client to R), namespaced:** `sideview_ready` (sent when the engine starts) and
`sideview_snapshot` (section 8), plus all existing inputs except those refused in section 4.

**Ready and queue.** Until `sideview_ready` arrives, R **queues** verb messages, including the initial
`cards`, and then flushes them in order. On every `sideview_ready` (a re-rendered canvas sends it again)
R resends the store's current cards, then any queued messages.

**Finding a canvas.** `sideviewServer()` registers its store, queue and sender in
`session$userData$sideview[[session$ns(id)]]`. A `sideview_proxy` is `{id, session}`.
`sideviewProxy(id, session)` resolves `session$ns(id)`, so nested modules work. Each verb **updates the R
store first, then sends** (or queues) the message, so R and the browser cannot drift.

**Several canvases.** Each canvas has its own store. They share one lazy duckdb connection per Shiny
session, kept in `session$userData` and closed once in `onSessionEnded` (the one-connection-per-session
rule in `CLAUDE.md`). Queues are dropped when the session ends.

## 8. Read-back reactives

In module mode only, the engine sends one namespaced input, `sideview_snapshot`:
`{code, pipeline, state, cards}`, with `pipeline` and `state` as **JSON text**. It is sent on the
pipeline's `onChange` (`sv-pipeline.js:381`; every label except the internal `checks`) and on card move,
resize, minimize, add, replace and remove, **debounced at 300 ms**. Pan and zoom alone do not send it; the
viewport in `$state()` is as of the last snapshot. The snapshot is built after the engine has applied an R
message, so after `sv_replace_card()` the next `$code()` already reflects disabled steps.

| Reactive | Value | Before the first snapshot |
|---|---|---|
| `$code()` | `character(1)`: code composed from enabled steps; `""` for no code (`sv_is_no_code()`) | `""` |
| `$pipeline()` | list of typed steps, `jsonlite::fromJSON(simplifyVector = FALSE)` | `list()` |
| `$state()` | state object from `sv_state_from_json()`; goes straight into `sv_set_state()` / `sv_save_state()` | `NULL` |
| `$cards()` | names of the cards on the canvas, **from the R store** | the initial names |

**Validation.** A snapshot over 1 MB, or whose JSON does not parse, is dropped: the previous values stay
and one `warning()` per session goes to the server log. A `code` that is not one string becomes `""`.

## 9. Errors

Plain `stop(call. = FALSE)` messages, as elsewhere in the package:

| Case | Message |
|---|---|
| `sv_add_card` with a name in use | `Card 'labs' already exists; use sv_replace_card()` |
| `sv_replace_card` / `sv_remove_card` with an unknown name | `No card 'labz'. Cards: visits, labs` |
| `x` that `sv_normalize_arg()` cannot turn into a card | the message `sideview()` gives |
| `sideviewProxy()` with no session | `sideviewProxy() needs a Shiny session: call it inside a server function` |
| no module under the id | `sideviewServer("x") has not been started in this session` |
| invalid `name` / `cols` | `'name' must be a single string` / `'cols' must be a character vector` |

A lazy card whose link is lost after a replace uses the existing fallback to the preview, with one toast.

## 10. Testing

- **`testServer` (R, `tests/testthat/test-module.R`):** each verb updates the store and records its
  message in `session$userData$custom_messages`; messages queue before `sideview_ready` and flush in order
  after it; a second `sideview_ready` resends the cards; the reactive `cards =` diff, including the
  `identical()` skip; snapshot validation (over 1 MB, bad JSON, non-string `code`); every error in
  section 9; refused inputs in module mode; `$cards()` updates right after a verb; a duckdb card replaced
  inside a module (skipped without duckdb).
- **Pure JS (`gui-test-runner.js`):** routing by `ns` (two engines, unknown `ns` ignored); the pipeline's
  missing-column check (disables, tracks renames and mutates, leaves others alone, the undo rule); snapshot
  debounce (several changes, one input).
- **Real browser (`test-layout-browser.R`, real mouse input):** an app with **two canvases** and buttons
  that call each verb. A replace keeps the card's position; spline endpoints stay on their ports; the
  disabled-step toast shows; the two canvases do not affect each other; the page still scrolls; the
  rendered `$code()` text `parse()`s.
- **Unchanged:** the gadget, widget and lazy-twin suites pass without edits.
- **RStudio:** the example app `inst/examples/proxy/app.R` in the Viewer and in the browser, plus a quick
  gadget regression pass; results in `MEMORY.md`.
- **Release:** `devtools::check()` and `pkgdown::check_pkgdown()` clean, the new exports in a "Shiny
  module" reference group; `NEWS.md`, a README section, and the `CLAUDE.md` input/message lists updated.

## 11. Files touched

- `R/module.R` (new): `sideviewUI()`, `sideviewServer()`, `sideviewProxy()`, the verbs, snapshot parsing.
- `R/card_store.R` (new): `sv_card_store()`.
- `R/app_server.R`: lookups through the store, module mode (refused inputs, `ns` on messages, queue).
- `R/app_ui.R`: chrome reusable without cards and without page-level rules; `data-sv-ns`.
- `R/widget.R`: `sv_card_payload()` extracted.
- `inst/www/sideview.js`: `ns` prefix in `sendToShiny`, engine registry and routing, new message
  handlers, replace/remove, `sideview_ready`, snapshot.
- `inst/www/sv-pipeline.js`: missing-column check that disables steps.
- `inst/examples/proxy/app.R` (new), tests above, `NAMESPACE`/`man/`, `_pkgdown.yml`, `NEWS.md`,
  `README.md`, `CLAUDE.md`, `MEMORY.md`.
