# Data-quality checks on the OMOP CDM with OHDSI DataQualityDashboard (read-only).
# Written against DataQualityDashboard 2.9.1: executeDqChecks() args and the
# CheckResults columns (failed, passed, isError, notApplicable, thresholdValue,
# numViolatedRows, pctViolatedRows, ...) were verified from the installed package.
source("R/common.R")
suppressPackageStartupMessages(library(DataQualityDashboard))

# Usage: Rscript R/03_dqd.R                    full scan + summaries
#        Rscript R/03_dqd.R --summarize-only   re-summarize existing dqd_results.json (no DB access)
summarize_only <- "--summarize-only" %in% commandArgs(trailingOnly = TRUE) ||
  identical(Sys.getenv("DQD_SUMMARIZE_ONLY"), "1")

t_start <- Sys.time()
cdm_schema <- cfg$schemas$cdm
cdm_version <- cfg$etl$cdm_version
out_dir <- file.path(cfg$paths$output, "dqd")
json_file <- "dqd_results.json"
num_threads <- as.integer(Sys.getenv("DQD_THREADS", "4"))
# COST ETL was intentionally skipped, so COST checks say nothing about the analytic CDM.
excluded_tables <- "COST"

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!summarize_only) {
cd <- make_connection_details()

# Pre-flight: fail clearly on empty core tables (read-only queries).
# The connection is owned and closed here, separately from the one executeDqChecks manages.
timed_step("Pre-flight checks", {
  conn <- connect(cd)
  tryCatch({
  for (tbl in c("person", "concept")) {
    res_n <- querySql(conn, sprintf("SELECT COUNT(*) AS row_count FROM %s.%s", cdm_schema, tbl))
    # Column name case varies by DatabaseConnector version, so read by position.
    if (nrow(res_n) != 1 || ncol(res_n) != 1) {
      stop(sprintf("Unexpected COUNT result for %s.%s: %d row(s) x %d column(s)", cdm_schema, tbl, nrow(res_n), ncol(res_n)))
    }
    n <- suppressWarnings(as.numeric(res_n[[1]][1]))
    if (length(n) != 1 || is.na(n)) stop(sprintf("COUNT for %s.%s is NA or not numeric", cdm_schema, tbl))
    if (n == 0) stop(sprintf("%s.%s is empty; run R/01_load_vocab.R and R/02_etl.R first", cdm_schema, tbl))
    message(sprintf("Pre-flight: %s.%s = %.0f", cdm_schema, tbl, n))
  }
  }, finally = disconnect(conn))
})

# writeToTable = FALSE: nothing is written to the database (the default would create
# dqdashboard_results in the results schema). resultsDatabaseSchema is still required.
#
# executeDqChecks owns its connection. In DQD 2.9.1 with numThreads > 1 it overwrites its own
# `connection` variable with NULL (after registering on.exit(disconnect(connection))), so the
# exit handler fails with "no applicable method for `@` applied to NULL" AFTER the results
# JSON is written. Tolerate exactly that error, and only if the JSON was freshly written.
json_path <- file.path(out_dir, json_file)
run_dqd <- function() executeDqChecks(
  connectionDetails = cd,
  cdmDatabaseSchema = cdm_schema,
  resultsDatabaseSchema = cfg$schemas$results,
  vocabDatabaseSchema = cdm_schema,
  cdmSourceName = cfg$etl$cdm_source_name,
  cdmVersion = cdm_version,
  numThreads = num_threads,
  outputFolder = out_dir,
  outputFile = json_file,
  writeToTable = FALSE,
  writeToCsv = FALSE,
  tablesToExclude = union(
    eval(formals(executeDqChecks)$tablesToExclude), excluded_tables
  ),
  verboseMode = FALSE
)

timed_step("DataQualityDashboard::executeDqChecks", tryCatch(
  run_dqd(),
  error = function(e) {
    cleanup_bug <- grepl("jConnection|applied to an object of class \"NULL\"", conditionMessage(e))
    json_fresh <- file.exists(json_path) && file.mtime(json_path) >= t_start
    if (!(cleanup_bug && json_fresh)) stop(e)
    warning("Ignored DQD 2.9.1 connection-cleanup error after results were written: ",
            conditionMessage(e), call. = FALSE)
  }
))
} else {
  message("Summarize-only mode: reading existing results, no database access")
}

if (!file.exists(file.path(out_dir, json_file))) stop("Results file not found: ", file.path(out_dir, json_file))
res <- jsonlite::fromJSON(file.path(out_dir, json_file), simplifyDataFrame = TRUE)$CheckResults
col <- function(name) if (name %in% names(res)) res[[name]] else rep(NA, nrow(res))

res$is_cost_related <- toupper(col("cdmTableName")) %in% excluded_tables |
  grepl("\\bcost\\b", col("error"), ignore.case = TRUE)
# Defensive: drop any COST rows that slipped through from the core assessment.
core <- res[!res$is_cost_related, ]

pct <- function(a, b) if (b == 0) NA_real_ else round(100 * a / b, 2)
summarize <- function(d) {
  passed <- sum(d$passed == 1, na.rm = TRUE)
  failed <- sum(d$failed == 1, na.rm = TRUE)
  data.frame(
    total_checks = nrow(d),
    passed_checks = passed,
    failed_checks = failed,
    errored_checks = sum(d$isError == 1, na.rm = TRUE),
    not_applicable_checks = sum(d$notApplicable == 1, na.rm = TRUE),
    pass_percentage = pct(passed, passed + failed) # excludes not-applicable, as DQD does
  )
}

summary_df <- cbind(scope = "core_cdm_excl_cost", summarize(core))
if (any(res$is_cost_related)) {
  summary_df <- rbind(summary_df, cbind(scope = "cost_related_excluded", summarize(res[res$is_cost_related, ])))
}
write.csv(summary_df, file.path(out_dir, "summary.csv"), row.names = FALSE)

by_level <- function(d, keys) {
  d$checkLevel <- as.character(d$checkLevel)
  d$category <- ifelse(is.na(d$category), "Unknown", d$category)
  d$subcategory <- ifelse(is.na(d$subcategory), "None", d$subcategory)
  grp <- do.call(paste, c(d[keys], sep = "\r"))
  out <- do.call(rbind, lapply(split(d, grp), function(g) {
    s <- summarize(g)
    cbind(g[1, keys, drop = FALSE], s)
  }))
  rownames(out) <- NULL
  out[do.call(order, out[keys]), ]
}
write.csv(by_level(core, c("checkLevel", "category", "subcategory")),
          file.path(out_dir, "summary_by_level_category.csv"), row.names = FALSE)

failed <- core[core$failed == 1 & !is.na(core$failed), ]
reason <- ifelse(
  !is.na(failed$error),
  paste("ERROR:", failed$error),
  sprintf("%s of %s rows (%s%%) violate; threshold %s%%. %s",
          failed$numViolatedRows, failed$numDenominatorRows, failed$pctViolatedRows,
          failed$thresholdValue, ifelse(is.na(failed$checkDescription), "", failed$checkDescription))
)
failed_df <- data.frame(
  check_id = failed$checkId,
  check_name = failed$checkName,
  check_level = failed$checkLevel,
  category = failed$category,
  subcategory = failed$subcategory,
  table = failed$cdmTableName,
  field = failed$cdmFieldName,
  concept_id = failed$conceptId,
  threshold_pct = failed$thresholdValue,
  num_violated_rows = failed$numViolatedRows,
  num_denominator_rows = failed$numDenominatorRows,
  actual_pct_violated = failed$pctViolatedRows,
  is_error = failed$isError,
  failure_reason = reason,
  stringsAsFactors = FALSE
)
write.csv(failed_df, file.path(out_dir, "failed_checks.csv"), row.names = FALSE)

message("\nCore CDM summary (COST excluded):")
print(summary_df, row.names = FALSE)
message(sprintf("Failed checks: %d -> %s", nrow(failed_df), file.path(out_dir, "failed_checks.csv")))
message(sprintf("Total runtime: %.1f min", as.numeric(difftime(Sys.time(), t_start, units = "mins"))))
