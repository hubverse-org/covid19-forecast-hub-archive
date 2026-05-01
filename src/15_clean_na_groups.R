#!/usr/bin/env Rscript
# Clean files flagged for NA values in the `value` column.
#
# Strategy: drop only the rows whose `value` is NA. Verified earlier that
# NA rows always cluster into entire `(target, ref_date, location, horizon)`
# groups for the quantile output_type, so dropping them never leaves a
# partially-populated quantile set. Some files (e.g. AMM-EpiInvert) have
# all-NA quantile rows but a valid `mean` row in the same group — we keep
# the mean rows, leaving those groups as mean-only predictions.
#
# Rewrites each affected file in place. Logs the per-file cleanup to
# src/logs/clean_na_groups_<date>.csv.

suppressPackageStartupMessages({
  library(here); library(arrow); library(dplyr); library(readr)
})

log_dir <- here::here("src", "logs")
mo_root <- here::here("model-output")

# Find latest fast-full validation log to identify NA-flagged files
val_logs <- list.files(log_dir, "^validate_submissions_fast_full_.*\\.csv$",
                       full.names = TRUE)
val_log <- val_logs[which.max(file.mtime(val_logs))]
res <- read_csv(val_log, show_col_types = FALSE)
na_files <- res$file[grepl("^value_col_valid", res$first_error)]
cat("cleaning", length(na_files), "files\n\n")

clean_log <- list()
for (rp in na_files) {
  full <- file.path(mo_root, rp)
  if (!file.exists(full)) {
    # Possibly already removed (e.g. non-monotonic + NA in same file)
    clean_log[[rp]] <- list(file = rp, n_in = NA, n_out = NA, n_groups_removed = NA,
                            note = "file not found (already removed?)")
    next
  }

  d <- read_parquet(full)
  n_in <- nrow(d)

  na_mask <- is.na(d$value)
  n_dropped <- sum(na_mask)
  if (n_dropped == 0L) {
    clean_log[[rp]] <- list(file = rp, n_in = n_in, n_out = n_in,
                            n_dropped = 0L, note = "no NA rows")
    next
  }

  d_clean <- d[!na_mask, , drop = FALSE]
  n_out <- nrow(d_clean)

  if (n_out == 0L) {
    file.remove(full)
    clean_log[[rp]] <- list(file = rp, n_in = n_in, n_out = 0L,
                            n_dropped = n_dropped,
                            note = "all rows were NA — file removed")
  } else {
    write_parquet(d_clean, full)
    clean_log[[rp]] <- list(file = rp, n_in = n_in, n_out = n_out,
                            n_dropped = n_dropped,
                            note = "cleaned in place")
  }
  cat(sprintf("%-60s  %d -> %d rows (dropped %d NA rows)\n",
              rp, n_in, n_out, n_dropped))
}

clean_df <- bind_rows(lapply(clean_log, as_tibble))
out_log <- file.path(log_dir, sprintf("clean_na_groups_%s.csv", Sys.Date()))
write_csv(clean_df, out_log)
cat("\nlog:", out_log, "\n")
