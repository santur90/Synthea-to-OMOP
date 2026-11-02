# Review tables for existing DQD results. Reads output/dqd/dqd_results.json only:
# no database access, no DQD rerun, and the original JSON/summary.csv are not touched.
# review_status is a triage label, not a root-cause claim:
#   out_of_scope_cost              check is on the COST table (COST ETL intentionally skipped)
#   expected_missing_optional_table  DQD's own error says the check's table does not exist
#                                    (relation "<schema>.<table>" does not exist) and the table
#                                    is an optional results-schema table (COHORT, COHORT_DEFINITION)
#   requires_review                everything else
suppressPackageStartupMessages(library(jsonlite))

out_dir <- file.path("output", "dqd")
json_path <- file.path(out_dir, "dqd_results.json")
if (!file.exists(json_path)) stop("Results file not found: ", json_path)

res <- fromJSON(json_path, simplifyDataFrame = TRUE)$CheckResults
col <- function(name) if (name %in% names(res)) res[[name]] else rep(NA, nrow(res))

optional_tables <- c("COHORT", "COHORT_DEFINITION")
tbl <- toupper(col("cdmTableName"))
err <- col("error")
has_err <- !is.na(err)
err_flat <- trimws(gsub("[[:space:]]+", " ", ifelse(has_err, err, "")))

relation_missing <- function(i) {
  m <- regmatches(err_flat[i], regexpr("relation \"[^\"]+\" does not exist", err_flat[i]))
  length(m) == 1 && grepl(paste0("\\.", tolower(tbl[i]), "\"|^relation \"", tolower(tbl[i]), "\""),
                          tolower(m))
}

status <- vapply(seq_len(nrow(res)), function(i) {
  if (tbl[i] == "COST" || (has_err[i] && grepl("\\bcost\\b", err[i], ignore.case = TRUE))) {
    "out_of_scope_cost"
  } else if (has_err[i] && tbl[i] %in% optional_tables && relation_missing(i)) {
    "expected_missing_optional_table"
  } else {
    "requires_review"
  }
}, character(1))

build <- function(idx) {
  data.frame(
    check_id = col("checkId")[idx],
    check_name = col("checkName")[idx],
    check_level = col("checkLevel")[idx],
    category = col("category")[idx],
    subcategory = col("subcategory")[idx],
    cdm_table = col("cdmTableName")[idx],
    cdm_field = col("cdmFieldName")[idx],
    concept_id = col("conceptId")[idx],
    num_violated_rows = col("numViolatedRows")[idx],
    num_denominator_rows = col("numDenominatorRows")[idx],
    pct_violated_rows = col("pctViolatedRows")[idx],
    threshold_pct = col("thresholdValue")[idx],
    dqd_failed = col("failed")[idx],
    dqd_is_error = col("isError")[idx],
    not_applicable = col("notApplicable")[idx],
    error_message = err_flat[idx],
    review_status = status[idx],
    stringsAsFactors = FALSE
  )
}

failed_idx <- which(col("failed") == 1)
errored_idx <- which(has_err)

failed_df <- build(failed_idx)
errored_df <- build(errored_idx)
write.csv(failed_df, file.path(out_dir, "failed_checks_review.csv"), row.names = FALSE)
write.csv(errored_df, file.path(out_dir, "errored_checks.csv"), row.names = FALSE)

statuses <- c("requires_review", "expected_missing_optional_table", "out_of_scope_cost")
summary_df <- rbind(
  data.frame(metric = "failed_checks", review_status = "all", count = nrow(failed_df)),
  data.frame(metric = "errored_checks", review_status = "all", count = nrow(errored_df)),
  data.frame(metric = "failed_checks", review_status = statuses,
             count = vapply(statuses, function(s) sum(failed_df$review_status == s), numeric(1))),
  data.frame(metric = "errored_checks", review_status = statuses,
             count = vapply(statuses, function(s) sum(errored_df$review_status == s), numeric(1)))
)
write.csv(summary_df, file.path(out_dir, "dqd_review_summary.csv"), row.names = FALSE)

short <- function(d) {
  d$error_message <- substr(d$error_message, 1, 70)
  d[, c("check_name", "check_level", "category", "cdm_table", "cdm_field", "num_violated_rows",
        "num_denominator_rows", "threshold_pct", "review_status", "error_message")]
}
options(width = 250)
cat("\n== failed_checks_review.csv ==\n"); print(short(failed_df), row.names = FALSE)
cat("\n== errored_checks.csv ==\n"); print(short(errored_df), row.names = FALSE)
cat("\n== dqd_review_summary.csv ==\n"); print(summary_df, row.names = FALSE)
