#!/usr/bin/env Rscript
# Convert every legacy forecast CSV under
# ../covid19-forecast-hub/data-processed/<team-model>/*.csv into
# model-output/<team-model>/<round_id>-<team-model>.parquet.
#
# Uses furrr::future_map_dfr for parallelism across 8 workers; the per-file
# conversion logic lives in src/10_convert_forecast_file.R. A pass/fail log
# (one row per source file) is written to src/logs/convert_forecasts_<date>.csv.

suppressPackageStartupMessages({
  library(here); library(dplyr); library(purrr); library(furrr); library(readr)
})

src_root <- "../covid19-forecast-hub/data-processed"
out_root <- here::here("model-output")
log_dir  <- here::here("src", "logs")
if (!dir.exists(log_dir)) dir.create(log_dir, recursive = TRUE)

files <- list.files(src_root, "\\.csv$", recursive = TRUE, full.names = TRUE)
cat("converting", length(files), "forecast files...\n")

# Source helper into the parent and let furrr ship globals to workers. We
# also source it inside each worker (.options below) so package globals like
# `ERA_TABLE` and `parse_target` are visible.
src_helper <- here::here("src", "10_convert_forecast_file.R")
source(src_helper)

plan(multisession, workers = 8L)
t0 <- Sys.time()
res <- future_map_dfr(
  files,
  function(f) {
    source(src_helper, local = TRUE)
    convert_forecast_file(f, out_root)
  },
  .options = furrr_options(seed = TRUE,
                           globals = c("src_helper", "out_root"))
)
plan(sequential)

elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
cat(sprintf("done in %.1fs (%.1f min)\n", elapsed, elapsed / 60))

cat("\n--- summary ---\n")
res |> summarise(
  ok = sum(ok), failed = sum(!ok),
  total_n_in    = sum(n_in,    na.rm = TRUE),
  total_n_out   = sum(n_out,   na.rm = TRUE),
  total_dropped = sum(n_dropped_round, na.rm = TRUE)
) |> print()

cat("\nrounds:\n");        print(table(res$round, useNA = "ifany"))
cat("\npoint output:\n");  print(table(res$point_output_type, useNA = "ifany"))

if (any(!res$ok)) {
  cat("\n--- failures ---\n")
  print(res |> filter(!ok) |> count(error, sort = TRUE), n = 40)
}

log_path <- file.path(log_dir, sprintf("convert_forecasts_%s.csv", Sys.Date()))
write_csv(res, log_path)
cat("\nlog:", log_path, "\n")
