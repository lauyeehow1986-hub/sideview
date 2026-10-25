## R CMD check results

0 errors | 0 warnings | 1 note

* This is a new submission.

On the local Windows check only, a second note lists a directory `'NULL'` in
the check directory. R CMD check sets `R_LIBS_USER='NULL'` (with the quotes),
and R 4.5 on Windows creates a missing `R_LIBS_USER` folder at startup, so
`Rscript --vanilla -e 1` makes the same folder with that setting. The package
does not create it.

## Test environments

* local Windows 11, R 4.5.2: `R CMD check --as-cran`
* win-builder: R-devel and R-release
* GitHub Actions (`--as-cran`, `NOT_CRAN=false`): Ubuntu R-devel, R-release and
  R-oldrel; macOS and Windows R-release

## Notes for the reviewer

* The package is interactive by design (a 'shiny' gadget and an 'htmlwidgets'
  widget). Examples that would open a viewer are wrapped in `if (interactive())`;
  the rest run, and any files they write go to `tempfile()`.
* Files are written only when the user asks for it: the toolbar's Save and
  Export buttons, or the `file` argument of `sv_save_state()` and
  `sv_codebook()`.
* The optional LLM assistant makes network calls only when the user sends a
  prompt. Tests mock every request, and tests that need a browser, 'Node.js'
  or network access are skipped on CRAN.
