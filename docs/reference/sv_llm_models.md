# List the models available from an LLM backend

Queries a local Ollama server (`/api/tags`) or an OpenAI-compatible
server (`/models`) for the installed or available model names. Useful
for choosing `options(sideview.llm_model = ...)`.

## Usage

``` r
sv_llm_models(
  backend = c("ollama", "openai"),
  endpoint = NULL,
  api_key = NULL,
  timeout = 5
)
```

## Arguments

- backend:

  `"ollama"` or `"openai"`.

- endpoint:

  Base URL. Defaults as in
  [`sv_call_llm()`](https://lauyeehow1986-hub.github.io/sideview/reference/sv_call_llm.md);
  a chat endpoint (`.../api/chat`, `.../chat/completions`) is also
  accepted.

- api_key:

  API key for OpenAI-compatible servers.

- timeout:

  Request timeout in seconds. Default 5.

## Value

A character vector of model names.
