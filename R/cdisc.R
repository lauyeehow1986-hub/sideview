# CDISC awareness: dataset catalogue (SDTM, SEND, ADaM).

.sv_cdisc_cache <- new.env(parent = emptyenv())

#' CDISC dataset catalogue
#'
#' The SDTM, SEND and ADaM datasets that sideview recognises, read once per
#' session from a file shipped with the package.
#'
#' @return A data frame of character columns: `name` (dataset code, or the
#'   ADaM class name), `label` (published dataset label), `class`, `standard`
#'   (`"SDTM"`, `"SEND"` or `"ADaM"`), `ig_versions` (`;`-separated
#'   implementation guide versions) and `keys` (`;`-separated natural keys).
#' @examples
#' head(sv_cdisc_catalogue())
#' @export
sv_cdisc_catalogue <- function() {
  if (is.null(.sv_cdisc_cache$catalogue)) {
    path <- system.file("extdata", "cdisc_catalogue.csv", package = "sideview")
    .sv_cdisc_cache$catalogue <- utils::read.csv(path, colClasses = "character",
                                                 na.strings = character())
  }
  .sv_cdisc_cache$catalogue
}
