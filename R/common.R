# Shared helpers for the R pipeline. Credentials come from environment variables only.
suppressPackageStartupMessages({
  library(DatabaseConnector)
  library(yaml)
})

cfg <- read_yaml("config/config.yml")

require_env <- function(name) {
  v <- Sys.getenv(name, unset = "")
  if (!nzchar(v)) stop("Required environment variable ", name, " is not set. Set it in .env (see .env.example).", call. = FALSE)
  v
}

make_connection_details <- function() {
  jar <- Sys.getenv("DATABASECONNECTOR_JAR_FOLDER")
  if (!nzchar(jar) || !dir.exists(jar)) {
    stop("DATABASECONNECTOR_JAR_FOLDER not set or not found: '", jar, "'")
  }
  # Resolve eagerly: createConnectionDetails evaluates arguments lazily, which would hide
  # a missing variable until connect().
  db_user <- require_env("DB_USER")
  db_password <- require_env("DB_PASSWORD")
  DatabaseConnector::createConnectionDetails(
    dbms         = "postgresql",
    server       = paste0(Sys.getenv("DB_HOST", "localhost"), "/", Sys.getenv("DB_NAME", "omop")),
    port         = as.integer(Sys.getenv("DB_PORT", "5432")),
    user         = db_user,
    password     = db_password,
    pathToDriver = jar
  )
}

create_schema_if_missing <- function(connectionDetails, schema) {
  stopifnot(grepl("^[A-Za-z_][A-Za-z0-9_]*$", schema))
  conn <- connect(connectionDetails)
  on.exit(disconnect(conn))
  executeSql(conn, paste0("CREATE SCHEMA IF NOT EXISTS ", schema, ";"), progressBar = FALSE, reportOverallTime = FALSE)
}

timed_step <- function(label, expr) {
  message(sprintf("[%s] START %s", format(Sys.time(), "%H:%M:%S"), label))
  t0 <- Sys.time()
  force(expr)
  message(sprintf("[%s] DONE  %s (%.1f s)", format(Sys.time(), "%H:%M:%S"), label,
                  as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  invisible(NULL)
}
