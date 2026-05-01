#!/usr/bin/env Rscript
# Remove forecast files flagged for non-monotonic quantile values.
# Per project decision: such files cannot be made schema-valid without
# altering the team's submitted predictions, so we leave them unconverted
# (i.e. drop the parquet from model-output/). The original CSVs remain
# untouched in ../covid19-forecast-hub/data-processed/.
#
# Reads the most recent validate_submissions_fast_full_*.csv log to find
# the affected files. Removes them. Cleans up any team-model dirs that
# become empty. Updates the corresponding row in the conversion log.

suppressPackageStartupMessages({
  library(here); library(readr); library(dplyr)
})

mo_root  <- here::here("model-output")
log_dir  <- here::here("src", "logs")

# Pick the newest fast-full validation log
log_files <- list.files(log_dir, "^validate_submissions_fast_full_.*\\.csv$",
                        full.names = TRUE)
stopifnot(length(log_files) > 0)
val_log <- log_files[which.max(file.mtime(log_files))]
cat("reading:", val_log, "\n")

res <- read_csv(val_log, show_col_types = FALSE)
nm_files <- res$file[grepl("^value_col_non_desc", res$first_error)]
cat("non-monotonic files:", length(nm_files), "\n")

removed_dirs <- c()
for (rp in nm_files) {
  full <- file.path(mo_root, rp)
  if (file.exists(full)) {
    file.remove(full)
  }
}

# Remove now-empty team-model dirs
team_dirs <- list.dirs(mo_root, recursive = FALSE)
for (d in team_dirs) {
  files <- list.files(d, "\\.parquet$", full.names = TRUE)
  if (length(files) == 0L) {
    cat("team-model dir empty after removal — removing:", basename(d), "\n")
    unlink(d, recursive = TRUE)
    removed_dirs <- c(removed_dirs, basename(d))
  }
}

cat(sprintf("\nremoved %d parquet files; %d empty team-model dirs cleared\n",
            length(nm_files), length(removed_dirs)))

# Write a removal manifest for traceability
manifest_path <- file.path(log_dir, sprintf("removed_nonmonotone_%s.csv", Sys.Date()))
write_csv(tibble::tibble(removed_file = nm_files), manifest_path)
cat("manifest:", manifest_path, "\n")
