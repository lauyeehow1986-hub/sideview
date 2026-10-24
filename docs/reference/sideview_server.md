# Sideview Server Logic

Orchestrates bi-directional Shiny reactivity between the infinite 2D
canvas and the R session. Handles field mapping (`column_mapped`),
column renaming (`column_renamed`), discrepancy calculations
(`discrepancy_check`), natural language AI prompts (`run_ai_prompt`),
RStudio script injection (`inject_script`), and RStudio console
execution (`send_console`).

## Usage

``` r
sideview_server(
  cards = list(),
  ...,
  llm_fn = sv_call_llm,
  insert_fn = sv_insert_code,
  console_fn = sv_send_to_console,
  gadget = FALSE,
  run_env = globalenv()
)
```

## Arguments

- cards:

  A `sideview_card` object, a list of `sideview_card` objects, or
  tabular objects to be normalized.

- ...:

  Additional arguments.

- llm_fn:

  Function used to execute LLM queries (default `sv_call_llm`).

- insert_fn:

  Function used to insert code into active RStudio document (default
  `sv_insert_code`).

- console_fn:

  Function used to send code to RStudio console (default
  `sv_send_to_console`).

- gadget:

  If `TRUE`, run as a gadget: the Done and Cancel buttons, closing the
  RStudio dialog, and closing the last browser tab all stop the app.
  After the last tab closes the app waits
  `getOption("sideview.session_grace", 5)` seconds so a page reload does
  not end it. Leave `FALSE` when embedding the server in your own
  multi-user Shiny app.

- run_env:

  Environment where **Run in R** evaluates the pipeline and stores its
  result (as `sv_result` unless another name is given). Defaults to the
  global environment, so the result is there after the gadget closes.

## Value

A Shiny server function `function(input, output, session)`.
