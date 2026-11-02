# Steps 2, 3 and 5: load Synthea CSVs into the native schema, then ETL into the CDM.
# Requires R/01_load_vocab.R to have run first (CDM tables + vocabulary).
source("R/common.R")
library(ETLSyntheaBuilder)

cd <- make_connection_details()
cdm_schema <- cfg$schemas$cdm
native_schema <- cfg$schemas$native
cdm_version <- cfg$etl$cdm_version
synthea_version <- cfg$etl$synthea_version
raw_csv_dir <- "data/synthea/csv"
aligned_csv_dir <- "data/synthea/csv_v330" # output folder of python/align_synthea_csv.py

# The native schema is dropped on every run; never let it point at the CDM or public.
if (native_schema == cdm_schema || native_schema == "public") {
  stop("Refusing to drop native schema '", native_schema, "': must differ from the cdm schema and 'public'")
}
if (!dir.exists(raw_csv_dir)) stop("Synthea CSV folder not found: ", raw_csv_dir)

timed_step("Reset native schema", {
  conn <- DatabaseConnector::connect(cd)
  DatabaseConnector::executeSql(conn, sprintf("DROP SCHEMA IF EXISTS %s CASCADE; CREATE SCHEMA %s;", native_schema, native_schema))
  DatabaseConnector::disconnect(conn)
})

timed_step("2) CreateSyntheaTables", CreateSyntheaTables(
  connectionDetails = cd, syntheaSchema = native_schema, syntheaVersion = synthea_version
))

timed_step("Align Synthea CSVs", {
  status <- system2(Sys.which("python"), "python/align_synthea_csv.py")
  if (status != 0) stop("python/align_synthea_csv.py failed with exit status ", status)
  if (!dir.exists(aligned_csv_dir) || length(list.files(aligned_csv_dir, pattern = "\\.csv$")) == 0) {
    stop("Aligned CSV folder missing or empty: ", aligned_csv_dir)
  }
})

timed_step("3) LoadSyntheaTables", LoadSyntheaTables(
  connectionDetails = cd, syntheaSchema = native_schema, syntheaFileLoc = aligned_csv_dir
))

timed_step("5) LoadEventTables", LoadEventTables(
  connectionDetails = cd,
  cdmSchema = cdm_schema,
  syntheaSchema = native_schema,
  cdmVersion = cdm_version,
  syntheaVersion = synthea_version,
  cdmSourceName = cfg$etl$cdm_source_name,
  cdmSourceAbbreviation = cfg$etl$cdm_source_abbreviation,
  cdmHolder = cfg$etl$cdm_holder,
  cdmSourceDescription = paste("Synthea", synthea_version, "data ETL'd to OMOP CDM", cdm_version)
))

tables <- c("person", "observation_period", "condition_occurrence", "drug_exposure",
            "measurement", "visit_occurrence", "death")
conn <- connect(cd)
on.exit(disconnect(conn))
counts <- vapply(tables, function(t) {
  as.numeric(querySql(conn, sprintf("SELECT COUNT(*) AS n FROM %s.%s", cdm_schema, t))$N)
}, numeric(1))
print(data.frame(table = tables, rows = format(counts, big.mark = ","), row.names = NULL))
