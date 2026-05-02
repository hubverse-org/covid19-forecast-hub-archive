#!/usr/bin/env Rscript
# Build hub-config/admin.json for the covid19-forecast-hub archive.
#
# hubAdmin (v1.9.0) does not expose builder functions for admin.json, so the
# config is composed as a list and serialized with jsonlite::write_json,
# then verified with hubAdmin::validate_config(config = "admin").

suppressPackageStartupMessages({
  library(jsonlite)
  library(hubAdmin)
  library(here)
})

options(hubAdmin.schema_version = "v6.0.0")

admin <- list(
  schema_version = "https://raw.githubusercontent.com/hubverse-org/schemas/main/v6.0.0/admin-schema.json",
  name           = "COVID-19 Forecast Hub Archive",
  maintainer     = "Reich Lab",
  contact = list(
    name  = "Nicholas Reich",
    email = "nick@umass.edu"
  ),
  repository = list(
    host  = "github",
    owner = "hubverse-org",
    name  = "covid19-forecast-hub-archive"
  ),
  file_format = list("parquet"),
  timezone    = "US/Eastern",
  cloud = list(
    enabled = FALSE,
    host = list(
      name             = "aws",
      storage_service  = "s3",
      storage_location = "covid19-forecast-hub-archive"
    )
  )
)

dest <- here::here("hub-config", "admin.json")
write_json(admin, dest, pretty = TRUE, auto_unbox = TRUE)
cat(sprintf("wrote %s (%.1f KB)\n", dest, file.size(dest) / 1024))

cat("\n--- validate_config ---\n")
v <- validate_config(hub_path = here::here(), config = "admin")
print(v)
