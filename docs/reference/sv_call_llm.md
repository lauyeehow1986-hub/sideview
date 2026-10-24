# Call Local Ollama or OpenAI-Compatible LLM Endpoint

Sends prompt requests to local Ollama (`http://localhost:11434`) or
OpenAI-compatible endpoints via `httr2`. Supports model selection,
customizable endpoints, API key authentication, and clean error
reporting for network or HTTP status failures.

## Usage

``` r
sv_call_llm(
  prompt,
  backend = c("ollama", "openai"),
  model = NULL,
  endpoint = NULL,
  api_key = NULL,
  timeout = 60,
  extract_code = FALSE,
  resolve_model = TRUE,
  ...
)
```

## Arguments

- prompt:

  A character string or `sideview_prompt` object from `sv_build_prompt`.

- backend:

  Character string: either `"ollama"` or `"openai"`.

- model:

  Model name (e.g., `"llama3.2"`, `"llama3"`, `"gpt-4o-mini"`).

- endpoint:

  Base URL or full chat endpoint for the API.

- api_key:

  API key (for OpenAI or authenticated endpoints).

- timeout:

  Request timeout in seconds. Default 60.

- extract_code:

  Logical; if TRUE, runs
  [`sv_extract_code()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_extract_code.md)
  on the response text. Default FALSE.

- resolve_model:

  Logical; for Ollama, if an untagged model such as `"llama3.2"` is not
  installed, retry once with an installed tag of it (e.g.
  `"llama3.2:3b"`). Default TRUE.

- ...:

  Additional options added to the request body (e.g. `temperature`). For
  Ollama, `think = FALSE` is sent unless you pass `think` or set
  `options(sideview.llm_think = TRUE)`, so reasoning models answer
  promptly.

## Value

Character string containing the LLM response text (or extracted code if
`extract_code = TRUE`).
