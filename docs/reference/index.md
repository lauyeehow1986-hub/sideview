# Package index

## Interactive Canvas & Gadget

Launch the interactive side-by-side multi-table canvas in RStudio or
standalone.

- [`sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview.md)
  : Multi-Table 2D Infinite Canvas Interactive Gadget
- [`sideview_addin()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_addin.md)
  : RStudio Addin for Sideview
- [`sideview_ui()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_ui.md)
  : Sideview User Interface
- [`sideview_server()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_server.md)
  : Sideview Server Logic
- [`sv_find_tables()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_find_tables.md)
  : Find Tabular Data Objects in an Environment
- [`sv_theme()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_theme.md)
  : Canvas Theme

## Standalone HTMLWidget & Export

Export interactive canvases to self-contained, portable HTML reports or
embed in Shiny.

- [`sideview_widget()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideview_widget.md)
  : Create a Standalone Sideview HTMLWidget
- [`save_sideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/save_sideview.md)
  : Save Sideview Widget to a Standalone HTML File
- [`sideviewOutput()`](https://lauyeehow1986-hub.github.io/sideview/reference/sideviewOutput.md)
  : Shiny Output Container for Sideview Widget
- [`renderSideview()`](https://lauyeehow1986-hub.github.io/sideview/reference/renderSideview.md)
  : Shiny Render Function for Sideview Widget

## Tidyverse Code Generation Engine

Generate reproducible dplyr, tidyr, and forcats pipelines from visual
canvas interactions.

- [`sv_code_join()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_join.md)
  : Generate tidyverse Code for Relational Table Joins
- [`sv_code_pivot_longer()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_pivot_longer.md)
  : Generate tidyverse Code for Reshaping Data from Wide to Long
- [`sv_code_pivot_wider()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_pivot_wider.md)
  : Generate tidyverse Code for Reshaping Data from Long to Wide
- [`sv_code_group_summarize()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_group_summarize.md)
  : Generate tidyverse Code for Grouping and Aggregating Data
- [`sv_code_rename()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_rename.md)
  : Generate tidyverse Code for Column Renaming
- [`sv_code_mutate()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_mutate.md)
  : Generate tidyverse Code for Column Mutation
- [`sv_code_filter()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_filter.md)
  : Generate tidyverse Code for Filtering Rows
- [`sv_code_arrange()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_arrange.md)
  : Generate tidyverse Code for Arranging (Sorting) Rows
- [`sv_code_select()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_select.md)
  : Generate tidyverse Code for Selecting Columns
- [`sv_escape_ident()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_escape_ident.md)
  : Escape R Identifiers with Backticks If Non-Syntactic

## Join Checks, Discrepancies & Recoding

Check join keys, detect fuzzy string mismatches, and generate case_when,
fct_recode, or auto-cleanup rules.

- [`sv_detect_discrepancies()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_detect_discrepancies.md)
  : Detect Exact Matches, Discrepancies, and Fuzzy Near-Matches
- [`sv_join_diagnostics()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_join_diagnostics.md)
  : Join Diagnostics
- [`sv_code_recode()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_code_recode.md)
  : Generate tidyverse Code for Categorical Recoding and Discrepancy
  Crosswalks
- [`sv_auto_clean_rules()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_auto_clean_rules.md)
  [`sv_code_auto_clean()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_auto_clean_rules.md)
  : Generate tidyverse Code for Automatic Discrepancy Cleaning and
  Crosswalks

## Column Profiles & Codebook

Profile a column (missingness, distinct values, quartiles, common
values, data-quality flags) and export a data dictionary.

- [`sv_column_profile()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_column_profile.md)
  : Column Profile
- [`sv_codebook()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_codebook.md)
  : Codebook (Data Dictionary)

## Canvas State Persistence & Cloud Sharing

Serialize complete canvas topologies, card positions, splines, and
pipelines to JSON or RDS.

- [`new_sideview_state()`](https://lauyeehow1986-hub.github.io/sideview/reference/new_sideview_state.md)
  : Create a New Sideview Canvas State Object
- [`sv_save_state()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_save_state.md)
  : Save Canvas State to File
- [`sv_load_state()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_load_state.md)
  : Load Canvas State from File
- [`print(`*`<sideview_state>`*`)`](https://lauyeehow1986-hub.github.io/sideview/reference/print.sideview_state.md)
  : Print Method for Sideview State Objects

## Intelligent Copilot & Auto-Mapping

Proactively suggest candidate joins and orchestrate multi-turn AI
assistance with context retention.

- [`sv_suggest_mappings()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_suggest_mappings.md)
  : Suggest Foreign Key Mappings Across Canvas Cards
- [`sv_build_chat_prompt()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_build_chat_prompt.md)
  : Build Structured Multi-Turn Prompt for Conversational Copilot
- [`sv_build_schema_context()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_build_schema_context.md)
  : Build a Privacy-Safe Schema Context from Sideview Cards
- [`sv_build_prompt()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_build_prompt.md)
  : Build Structured Prompt for Tidyverse LLM Code Generation
- [`sv_call_llm()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_call_llm.md)
  : Call Local Ollama or OpenAI-Compatible LLM Endpoint
- [`sv_llm_models()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_llm_models.md)
  : List the models available from an LLM backend
- [`sv_extract_code()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_extract_code.md)
  : Extract Executable R Code from LLM Response Text

## RStudio API & Environment Bridge

Direct 1-click insertion into active RStudio script editor buffers and
console execution.

- [`sv_is_rstudio_available()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_is_rstudio_available.md)
  : Check if RStudio API is Available
- [`sv_insert_code()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_insert_code.md)
  : Insert Generated Code into the Active RStudio Editor
- [`sv_send_to_console()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_send_to_console.md)
  : Send Generated Code to the RStudio Console

## Universal S3 Normalization

Convert heterogeneous tabular objects into standardized sideview cards.

- [`sv_normalize()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_normalize.md)
  : Universal Normalization Engine for Sideview Cards
