# Run browser-side modules (inst/www/sv-pipeline.js) under Node.js.

sv_node_bin <- function() {
  node <- Sys.which("node")
  if (nzchar(node)) return(unname(node))
  for (cand in c("C:/Program Files/nodejs/node.exe", "C:/Program Files (x86)/nodejs/node.exe")) {
    if (file.exists(cand)) return(cand)
  }
  ""
}

# Run a JS snippet with `P` bound to the SideviewPipeline API; the snippet must
# assign a JSON-serialisable value to `out`.
run_pipeline_js <- function(body) {
  testthat::skip_on_cran() # CRAN machines may not have Node.js; keep external processes off them
  node <- sv_node_bin()
  lib <- system.file("www", "sv-pipeline.js", package = "sideview")
  if (!nzchar(node) || !nzchar(lib)) skip("Node.js or sv-pipeline.js not available")
  script <- tempfile(fileext = ".js")
  on.exit(unlink(script), add = TRUE)
  writeLines(c(
    sprintf("const P = require(%s);", jsonlite::toJSON(normalizePath(lib, winslash = "/"), auto_unbox = TRUE)),
    "let out = null;",
    body,
    "process.stdout.write(JSON.stringify(out));"
  ), script)
  res <- suppressWarnings(system2(node, shQuote(script), stdout = TRUE, stderr = TRUE))
  status <- attr(res, "status")
  if (!is.null(status) && status != 0) stop(paste(res, collapse = "\n"))
  jsonlite::fromJSON(paste(res, collapse = "\n"), simplifyVector = FALSE)
}
