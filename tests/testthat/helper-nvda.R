# Synthetic fixture for the NVDA script (plans/2026-11-14-nvda-script.md). No real data.
# DM 10 subjects; AE 12 rows (AESEV: MILD / MODERATE / SEVERE; one AE row for a subject that is
# not in DM, so the join check has an unmatched key); SUPPAE for AESEQ 1..6 and one orphan row;
# labs 40 rows (LBSEQ 1..40) so "row 30" exists and paging has a second page.
sv_nvda_fixtures <- function() {
  usub <- sprintf("SV-001-%03d", 1:10)
  dm <- data.frame(STUDYID = "SV-001", DOMAIN = "DM", USUBJID = usub, AGE = c(34, 51, 62, 45, 29, 58, 41, 66, 37, 49),
                   SEX = rep(c("F", "M"), 5), stringsAsFactors = FALSE)
  attr(dm$USUBJID, "label") <- "Unique Subject Identifier"
  ae_subj <- c(usub[c(1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10)], "SV-001-099")
  ae <- data.frame(STUDYID = "SV-001", DOMAIN = "AE", USUBJID = ae_subj, AESEQ = c(1L, 2L, 1L, 1L, 1L, 1L, 1L, 1L, 1L, 1L, 1L, 1L),
                   AETERM = rep(c("Headache", "Nausea", "Rash", "Cough"), 3),
                   AESEV = rep(c("MILD", "MODERATE", "MILD", "SEVERE"), 3), stringsAsFactors = FALSE)
  ae$AESEQ <- seq_len(nrow(ae))
  attr(ae$AESEV, "label") <- "Severity/Intensity"
  suppae <- data.frame(STUDYID = "SV-001", RDOMAIN = "AE", USUBJID = c(ae$USUBJID[1:6], "SV-001-098"),
                       IDVAR = "AESEQ", IDVARVAL = as.character(c(1:6, 99L)), QNAM = "AETRTEM",
                       QLABEL = "Treatment Emergent", QVAL = "Y", stringsAsFactors = FALSE)
  labs <- data.frame(STUDYID = "SV-001", USUBJID = rep(usub, 4), LBSEQ = 1:40,
                     LBTESTCD = rep(c("ALT", "AST", "BILI", "CREAT"), each = 10),
                     LBORRES = as.character(round(10 + (1:40) * 1.5, 1)), LBORRESU = "U/L",
                     stringsAsFactors = FALSE)
  list(DM = dm, AE = ae, SUPPAE = suppae, labs = labs)
}
