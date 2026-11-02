# Steps 1 and 4: create the CDM v5.4 tables and load the Athena vocabulary.
# Run before R/02_etl.R. Requires: remotes::install_github("OHDSI/ETLSyntheaBuilder")
source("R/common.R")
library(ETLSyntheaBuilder)

cd <- make_connection_details()
cdm_schema <- cfg$schemas$cdm
cdm_version <- cfg$etl$cdm_version
vocab_dir <- cfg$paths$vocab

if (!dir.exists(vocab_dir) || length(list.files(vocab_dir)) == 0) {
  stop("Vocabulary files not found in '", vocab_dir, "'. Download from https://athena.ohdsi.org")
}

timed_step("Create schema", create_schema_if_missing(cd, cdm_schema))

timed_step("1) CreateCDMTables", CreateCDMTables(
  connectionDetails = cd, cdmSchema = cdm_schema, cdmVersion = cdm_version
))

timed_step("4) LoadVocabFromCsv", LoadVocabFromCsv(
  connectionDetails = cd, cdmSchema = cdm_schema, vocabFileLoc = vocab_dir
))
