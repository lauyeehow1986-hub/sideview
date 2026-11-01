# Synthetic CDISC-shaped tables for the cdisc tests (no real data).
sv_cdisc_fixtures <- function() {
  n <- 4L
  sid <- rep("SV-001", n)
  usub <- paste0("SV-001-", sprintf("%03d", 1:n))
  dm <- data.frame(STUDYID = sid, DOMAIN = "DM", USUBJID = usub, SUBJID = sprintf("%03d", 1:n),
                   AGE = c(34, 51, 62, 45), SEX = c("F", "M", "F", "M"),
                   ARM = c("A", "B", "A", "B"), stringsAsFactors = FALSE)
  attr(dm$USUBJID, "label") <- "Unique Subject Identifier"
  attr(dm$AGE, "label") <- "Age"
  attr(dm, "label") <- "Demographics"
  ae <- data.frame(STUDYID = sid, DOMAIN = "AE", USUBJID = usub, AESEQ = 1:n,
                   AETERM = c("Headache", "Nausea", "Rash", "Cough"),
                   AEDECOD = c("HEADACHE", "NAUSEA", "RASH", "COUGH"),
                   AESEV = c("MILD", "MODERATE", "MILD", "SEVERE"),
                   AESTDTC = c("2024-01-02", "2024-01-05", "2024-02-01", "2024-02-09"),
                   stringsAsFactors = FALSE)
  suppae <- data.frame(STUDYID = sid, RDOMAIN = "AE", USUBJID = usub, IDVAR = "AESEQ",
                       IDVARVAL = as.character(1:n), QNAM = "AETRTEM",
                       QLABEL = "Treatment Emergent", QVAL = "Y", stringsAsFactors = FALSE)
  labs <- data.frame(STUDYID = sid, USUBJID = usub, LBSEQ = 1:n, LBTESTCD = "ALT",
                     LBTEST = "Alanine Aminotransferase", LBORRES = c("20", "31", "18", "40"),
                     LBORRESU = "U/L", LBDTC = "2024-01-02", stringsAsFactors = FALSE)
  ts <- data.frame(STUDYID = sid, DOMAIN = "TS", TSSEQ = 1:n,
                   TSPARMCD = c("TITLE", "PHASE", "SPONSOR", "RANDOM"),
                   TSPARM = c("Title", "Phase", "Sponsor", "Randomized"),
                   TSVAL = c("Study", "II", "Acme", "Y"), stringsAsFactors = FALSE)
  xy <- data.frame(STUDYID = sid, DOMAIN = "XY", USUBJID = usub, XYSEQ = 1:n,
                   XYTESTCD = "T1", stringsAsFactors = FALSE)
  adsl <- data.frame(STUDYID = sid, USUBJID = usub, TRT01P = c("A", "B", "A", "B"),
                     TRT01A = c("A", "B", "A", "B"), AGE = dm$AGE, SAFFL = "Y",
                     stringsAsFactors = FALSE)
  bds <- data.frame(STUDYID = rep(sid, 2), USUBJID = rep(usub, 2), PARAMCD = "ALT",
                    PARAM = "Alanine Aminotransferase", AVAL = c(20, 31, 18, 40, 22, 30, 19, 41),
                    stringsAsFactors = FALSE)
  adlb <- cbind(bds, AVISIT = rep(c("Baseline", "Week 4"), each = n))
  adtte <- cbind(bds, CNSR = rep(c(0L, 1L), 4))
  adae <- data.frame(STUDYID = sid, USUBJID = usub, AETERM = ae$AETERM, AEDECOD = ae$AEDECOD,
                     TRTA = c("A", "B", "A", "B"), stringsAsFactors = FALSE)
  # admiral-style ADaM that keeps its SDTM-prefixed columns
  adlb_pfx <- data.frame(STUDYID = rep(sid, 2), USUBJID = rep(usub, 2), LBSEQ = 1:8,
                         LBTESTCD = "ALT", LBTEST = "Alanine Aminotransferase", LBCAT = "CHEMISTRY",
                         LBORRES = as.character(c(20, 31, 18, 40, 22, 30, 19, 41)),
                         LBSTRESN = c(20, 31, 18, 40, 22, 30, 19, 41),
                         PARAMCD = "ALT", PARAM = "Alanine Aminotransferase",
                         AVAL = c(20, 31, 18, 40, 22, 30, 19, 41),
                         AVISIT = rep(c("Baseline", "Week 4"), each = n),
                         BASE = rep(c(20, 31, 18, 40), 2), CHG = c(0, 0, 0, 0, 2, -1, 1, 1),
                         stringsAsFactors = FALSE)
  adae_pfx <- data.frame(STUDYID = sid, USUBJID = usub, TRTA = c("A", "B", "A", "B"),
                         AESEQ = 1:n, AETERM = ae$AETERM, AEDECOD = ae$AEDECOD,
                         AESEV = ae$AESEV, AECAT = "GENERAL", AESTDTC = ae$AESTDTC,
                         stringsAsFactors = FALSE)
  advs_pfx <- data.frame(STUDYID = rep(sid, 2), USUBJID = rep(usub, 2), VSSEQ = 1:8,
                         VSTESTCD = "SYSBP", VSTEST = "Systolic Blood Pressure", VSCAT = "VITALS",
                         VSORRES = as.character(c(120, 130, 125, 118, 121, 129, 126, 119)),
                         VSSTRESN = c(120, 130, 125, 118, 121, 129, 126, 119),
                         PARAMCD = "SYSBP", PARAM = "Systolic Blood Pressure",
                         AVAL = c(120, 130, 125, 118, 121, 129, 126, 119),
                         stringsAsFactors = FALSE)
  send_dm <- cbind(dm, SPECIES = "RAT")
  bw <- data.frame(STUDYID = sid, DOMAIN = "BW", USUBJID = usub, BWSEQ = 1:n,
                   BWTESTCD = "BW", BWORRES = c("250", "260", "255", "270"),
                   stringsAsFactors = FALSE)
  list(dm = dm, ae = ae, suppae = suppae, labs = labs, ts = ts, xy = xy, adsl = adsl,
       adlb = adlb, adtte = adtte, adae = adae, adlb_pfx = adlb_pfx,
       adae_pfx = adae_pfx, advs_pfx = advs_pfx, send_dm = send_dm, bw = bw,
       mtcars = mtcars, iris = iris,
       ae_nostudy = ae[, setdiff(names(ae), "STUDYID")],
       studyid_only = data.frame(STUDYID = sid, x = 1:n),
       keys_only = data.frame(STUDYID = sid, USUBJID = usub, VAL = 1:n, stringsAsFactors = FALSE))
}
