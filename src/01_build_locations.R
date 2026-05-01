#!/usr/bin/env Rscript
# Copy locations lookup from the legacy covid19-forecast-hub into auxiliary-data/.
# Schema: abbreviation, location, location_name, population
# Locations are FIPS codes ("01"-"56", "US"); population used by validators
# (e.g. flag forecasts exceeding state population).

suppressPackageStartupMessages({
  library(readr)
  library(here)
})

src_path  <- "../covid19-forecast-hub/data-locations/locations.csv"
dest_dir  <- here::here("auxiliary-data")
dest_path <- file.path(dest_dir, "locations.csv")

if (!dir.exists(dest_dir)) dir.create(dest_dir, recursive = TRUE)

# Specify column types: location must stay character ("01" not 1)
locations <- read_csv(src_path, col_types = cols(
  abbreviation  = col_character(),
  location      = col_character(),
  location_name = col_character(),
  population    = col_double()
))

write_csv(locations, dest_path)

cat(sprintf("wrote %d locations to %s\n", nrow(locations), dest_path))
