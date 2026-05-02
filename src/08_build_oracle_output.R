#!/usr/bin/env Rscript
# Build target-data/oracle-output.csv from target-data/time-series.csv.
#
# Per the hubverse target-data spec, oracle_value is computed as:
#   * quantile / mean / median / sample : oracle_value = observation,
#                                          output_type_id = NA
#   * pmf  : oracle_value = 1 if observed category else 0
#   * cdf  : oracle_value = 0 below observed threshold, 1 at-or-above
#
# This hub uses only quantile / mean / median, so a single observation
# produces three oracle rows — one per output_type with output_type_id = NA
# and oracle_value = observation.
#
# Output schema:
#   location (chr), target_end_date (date), target (chr),
#   output_type (chr), output_type_id (chr|NA), oracle_value (numeric)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tidyr)
  library(jsonlite)
  library(here)
})

ts_path <- here::here("target-data", "time-series.csv")
stopifnot(file.exists(ts_path))

ts <- read_csv(ts_path, col_types = cols(
  target_end_date = col_date(),
  location        = col_character(),
  target          = col_character(),
  observation     = col_double()
))
cat("time-series rows:", nrow(ts), "\n")

# Subset to (target, target_end_date) pairs declared in tasks.json. The
# time-series is preserved as-is upstream (it can carry truth observations
# that predate the first forecast round); the oracle has to align to the
# tasks.json allowlist or `target_tbl_values` validation fails.
tasks_path <- here::here("hub-config", "tasks.json")
stopifnot(file.exists(tasks_path))
tasks <- jsonlite::fromJSON(tasks_path, simplifyVector = FALSE)
ted_by_target <- list()
for (rnd in tasks$rounds) {
  for (mt in rnd$model_tasks) {
    tids <- mt$task_ids
    tgt  <- tids$target$required[[1]]
    teds <- as.Date(unlist(tids$target_end_date$optional))
    ted_by_target[[tgt]] <- sort(unique(c(ted_by_target[[tgt]], teds)))
  }
}
ted_lookup <- tibble::tibble(
  target          = rep(names(ted_by_target), lengths(ted_by_target)),
  target_end_date = as.Date(do.call(c, unname(ted_by_target)),
                            origin = "1970-01-01")
)
before <- nrow(ts)
ts <- ts |> semi_join(ted_lookup, by = c("target", "target_end_date"))
cat(sprintf("filtered to tasks.json target_end_dates: %d -> %d (%d dropped)\n",
            before, nrow(ts), before - nrow(ts)))

output_types <- c("quantile", "mean", "median")

oracle <- crossing(ts, tibble(output_type = output_types)) |>
  mutate(output_type_id = NA_character_,
         oracle_value   = observation) |>
  select(location, target_end_date, target,
         output_type, output_type_id, oracle_value) |>
  arrange(target, target_end_date, location, output_type)

cat("oracle rows:", nrow(oracle), "\n")

dest <- here::here("target-data", "oracle-output.csv")
write_csv(oracle, dest)
cat(sprintf("wrote %s (%.1f MB)\n",
            dest, file.size(dest) / 1024 / 1024))
