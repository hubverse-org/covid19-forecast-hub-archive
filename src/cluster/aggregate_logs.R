#!/usr/bin/env Rscript
# Aggregate per-chunk CSVs written by src/cluster/validate_chunk.R into a
# single combined log + a small summary printed to stdout.
#
# Usage:
#   Rscript src/cluster/aggregate_logs.R <log_dir>
# Example:
#   Rscript src/cluster/aggregate_logs.R src/logs/cluster_123456

suppressPackageStartupMessages({
  library(readr); library(dplyr)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) {
  stop("usage: aggregate_logs.R <log_dir>")
}
log_dir <- args[1]
stopifnot(dir.exists(log_dir))

chunks <- list.files(log_dir, pattern = "^chunk_\\d+\\.csv$", full.names = TRUE)
if (length(chunks) == 0L) stop("no chunk_*.csv files in ", log_dir)
cat(sprintf("merging %d chunk files from %s\n", length(chunks), log_dir))

all <- bind_rows(lapply(chunks, read_csv, show_col_types = FALSE))
out_path <- file.path(log_dir, "validate_submissions_full.csv")
write_csv(all, out_path)

cat(sprintf("\nwrote %s (%d rows)\n", out_path, nrow(all)))
cat(sprintf("  ok:   %d\n", sum(all$ok)))
cat(sprintf("  fail: %d\n", sum(!all$ok)))
cat(sprintf("  total wall (sum of per-file): %.1f hours\n",
            sum(all$elapsed_sec, na.rm = TRUE) / 3600))

# Top failing teams
all$team_model <- basename(dirname(all$file))
fails <- all |> filter(!ok) |>
  count(team_model, sort = TRUE)
if (nrow(fails)) {
  cat("\n--- top failing teams ---\n")
  print(head(fails, 25))
}

# Top failure reasons (truncated)
all$first_error_short <- substr(all$first_error %||% "", 1, 80)
err_summary <- all |> filter(!ok) |>
  count(first_error_short, sort = TRUE)
if (nrow(err_summary)) {
  cat("\n--- top first-error categories ---\n")
  print(head(err_summary, 15))
}

`%||%` <- function(a, b) if (is.null(a)) b else a
