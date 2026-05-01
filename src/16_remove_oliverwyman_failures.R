#!/usr/bin/env Rscript
# Remove every failing OliverWyman-Navigator parquet from model-output/.
# Per project decision: their incomplete quantile sets cannot be made
# schema-valid without altering the team's submitted predictions.
#
# Files that pass validation are kept. The original CSVs in
# ../covid19-forecast-hub/data-processed/ remain untouched.
#
# Reads the most recent fast-full validation log to find the failing files.

suppressPackageStartupMessages({
  library(here); library(readr); library(dplyr)
})

mo_root <- here::here("model-output")
log_dir <- here::here("src", "logs")

val_logs <- list.files(log_dir, "^validate_submissions_fast_full_.*\\.csv$",
                       full.names = TRUE)
val_log <- val_logs[which.max(file.mtime(val_logs))]
cat("reading:", val_log, "\n")

res <- read_csv(val_log, show_col_types = FALSE)
ow_failing <- res$file[!res$ok & grepl("^OliverWyman-Navigator/", res$file)]
cat("OliverWyman failing files to remove:", length(ow_failing), "\n")

removed <- 0L
for (rp in ow_failing) {
  full <- file.path(mo_root, rp)
  if (file.exists(full)) {
    file.remove(full)
    removed <- removed + 1L
  }
}
cat(sprintf("removed %d files\n", removed))

# Check whether the dir is empty after removal
ow_dir <- file.path(mo_root, "OliverWyman-Navigator")
if (dir.exists(ow_dir)) {
  remaining <- list.files(ow_dir, "\\.parquet$")
  cat(sprintf("remaining OliverWyman parquet files: %d\n", length(remaining)))
  if (length(remaining) == 0L) {
    cat("dir empty — removing it\n")
    unlink(ow_dir, recursive = TRUE)
  }
}

manifest_path <- file.path(log_dir,
  sprintf("removed_oliverwyman_%s.csv", Sys.Date()))
write_csv(tibble::tibble(removed_file = ow_failing), manifest_path)
cat("manifest:", manifest_path, "\n")
