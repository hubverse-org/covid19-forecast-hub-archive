#!/usr/bin/env Rscript
# Recover the 48 OliverWyman-Navigator forecast files that src/16 dropped
# in cleanup #4. After per-file inspection (see PR description), the
# uniform OW failure pattern is:
#
#   * cum death : 208 groups, full 23-quantile set per group  (complete)
#   * inc death : 208 groups, full 23-quantile set per group  (complete)
#   * inc case  : ~8000 groups, EXACTLY ONE quantile per group at q=0.5
#                 whose value is identical to the file's `median` row for
#                 the same group
#
# inc case requires a 7-level quantile set by hub-config; OW supplied only
# 1 level, so validation fails. The 1 quantile row is redundant with the
# median row (same value), so dropping it loses zero information while
# leaving the cum death / inc death portions completely intact.
#
# Algorithm per file:
#   1. Re-convert the legacy CSV via src/10::convert_forecast_file.
#   2. Drop all rows where target=="inc case" AND output_type=="quantile".
#   3. Drop any NA-value rows (matches src/15's NA cleanup; affects the 2
#      OliverWyman-Navigator files in clean_na_groups_2026-04-28.csv).
#   4. Write the cleaned parquet under model-output/OliverWyman-Navigator/.
#
# Outputs:
#   * 48 parquet files in model-output/OliverWyman-Navigator/
#   * src/logs/recover_oliverwyman_log.csv with per-file outcome columns:
#       file, n_rows_in, n_qrows_dropped_inc_case, n_na_rows_dropped,
#       n_rows_out, status

suppressPackageStartupMessages({
  library(here); library(arrow); library(dplyr); library(readr); library(tibble)
})

repo_root <- here::here()
log_dir   <- file.path(repo_root, "src", "logs")
mo_root   <- file.path(repo_root, "model-output")
csv_root  <- file.path(repo_root, "..", "covid19-forecast-hub", "data-processed",
                       "OliverWyman-Navigator")

source(file.path(repo_root, "src", "10_convert_forecast_file.R"))

manifest <- read_lines(file.path(log_dir, "removed_oliverwyman_2026-04-29.csv"))[-1]
cat(sprintf("recovering %d OliverWyman files\n", length(manifest)))

recover_one <- function(rel_path) {
  # rel_path looks like "OliverWyman-Navigator/2020-07-26-OliverWyman-Navigator.parquet"
  base <- sub("\\.parquet$", "", basename(rel_path))
  csv_path <- file.path(csv_root, paste0(base, ".csv"))
  if (!file.exists(csv_path)) {
    return(tibble(file = rel_path, n_rows_in = NA_integer_,
                  n_qrows_dropped_inc_case = NA_integer_,
                  n_na_rows_dropped = NA_integer_,
                  n_rows_out = NA_integer_,
                  status = sprintf("missing CSV: %s", csv_path)))
  }

  # Convert (writes parquet under mo_root/OliverWyman-Navigator/)
  conv <- tryCatch(convert_forecast_file(csv_path, out_root = mo_root),
                   error = function(e) e)
  if (inherits(conv, "error")) {
    return(tibble(file = rel_path, n_rows_in = NA_integer_,
                  n_qrows_dropped_inc_case = NA_integer_,
                  n_na_rows_dropped = NA_integer_,
                  n_rows_out = NA_integer_,
                  status = sprintf("convert error: %s", conditionMessage(conv))))
  }

  out_path <- file.path(mo_root, rel_path)
  if (!file.exists(out_path)) {
    return(tibble(file = rel_path, n_rows_in = NA_integer_,
                  n_qrows_dropped_inc_case = NA_integer_,
                  n_na_rows_dropped = NA_integer_,
                  n_rows_out = NA_integer_,
                  status = "convert wrote nothing"))
  }

  df <- as.data.frame(read_parquet(out_path))
  n_in <- nrow(df)

  # Drop inc case quantile rows (redundant with median rows; same value).
  is_inc_case_q <- df$target == "inc case" & df$output_type == "quantile"
  n_qdrop <- sum(is_inc_case_q)
  df <- df[!is_inc_case_q, , drop = FALSE]

  # Drop NA value rows (matches src/15's behaviour for the 2 OW files).
  is_na <- is.na(df$value)
  n_nadrop <- sum(is_na)
  df <- df[!is_na, , drop = FALSE]

  write_parquet(df, out_path)
  tibble(file = rel_path, n_rows_in = n_in,
         n_qrows_dropped_inc_case = n_qdrop,
         n_na_rows_dropped = n_nadrop,
         n_rows_out = nrow(df), status = "ok")
}

logs <- list()
for (i in seq_along(manifest)) {
  rp <- manifest[i]
  logs[[i]] <- recover_one(rp)
  if (i %% 10 == 0) cat(sprintf("  processed %d/%d\n", i, length(manifest)))
}

out <- bind_rows(logs)
write_csv(out, file.path(log_dir, "recover_oliverwyman_log.csv"))

ok <- out$status == "ok"
cat(sprintf("\n=== summary ===\n"))
cat(sprintf("files processed: %d\n", nrow(out)))
cat(sprintf("  ok:  %d\n", sum(ok)))
cat(sprintf("  err: %d\n", sum(!ok)))
cat(sprintf("rows in (sum):  %d\n", sum(out$n_rows_in,  na.rm = TRUE)))
cat(sprintf("rows out (sum): %d\n", sum(out$n_rows_out, na.rm = TRUE)))
cat(sprintf("inc case quantile rows dropped: %d\n",
            sum(out$n_qrows_dropped_inc_case, na.rm = TRUE)))
cat(sprintf("NA rows dropped:                %d\n",
            sum(out$n_na_rows_dropped, na.rm = TRUE)))
cat(sprintf("\nwrote: %s\n",
            file.path(log_dir, "recover_oliverwyman_log.csv")))
