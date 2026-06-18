#!/usr/bin/env Rscript
# Pre-flight for the distfromq / floating-point-noise fixers.
#
# Restores the 190 cluster-validation failures (job 59079072) from the
# ngr/add-data branch into model-output/, then audits each file:
#   * which groups (target, ref_date|forecast_date, location, horizon) have
#     the full required quantile set vs which are short, and by how much.
#   * minimum anchor count per file -- the gate for whether distfromq is
#     trustworthy. Project policy: require >= 5 existing quantile levels
#     in every group before we'll impute.
#
# Outputs:
#   src/logs/fail_anchor_counts.csv -- one row per (file, group):
#     file, target, ref_date_col, ref_date, location, horizon,
#     n_existing, n_missing, min_existing_p, max_existing_p
#   src/logs/fail_anchor_summary.csv -- one row per file:
#     file, fail_type, n_groups, min_anchors_in_any_group,
#     pct_groups_below_5, eligible_for_distfromq
#
# This script is idempotent: it can be re-run to refresh the audit.

suppressPackageStartupMessages({
  library(here); library(arrow); library(dplyr); library(readr); library(tidyr)
})

repo_root <- here::here()
mo_root   <- file.path(repo_root, "model-output")
log_dir   <- file.path(repo_root, "src", "logs")
dir.create(log_dir, showWarnings = FALSE, recursive = TRUE)

tracking_csv <- file.path(log_dir, "pr-submission-tracking.csv")
stopifnot(file.exists(tracking_csv))

# Identify the 190 failing files and their failure type
all_rows <- read_csv(tracking_csv, show_col_types = FALSE)
fail_rows <- all_rows |>
  filter(ok == "FALSE") |>
  mutate(
    fail_type = case_when(
      grepl("not all increase", first_error) ~ "monotonic",
      grepl("Required task ID", first_error)  ~ "incomplete",
      TRUE                                    ~ "other"
    )
  )
cat(sprintf("failing files: %d total (monotonic=%d, incomplete=%d, other=%d)\n",
            nrow(fail_rows),
            sum(fail_rows$fail_type == "monotonic"),
            sum(fail_rows$fail_type == "incomplete"),
            sum(fail_rows$fail_type == "other")))

# Restore each failing parquet from ngr/add-data into model-output/.
# Files are currently absent from main (chunk PRs included only passing files).
cat("restoring 190 failing files from ngr/add-data ...\n")
restored <- 0
for (rp in fail_rows$file) {
  dst <- file.path(mo_root, rp)
  dir.create(dirname(dst), showWarnings = FALSE, recursive = TRUE)
  if (!file.exists(dst)) {
    rc <- system2("git", c("show", paste0("ngr/add-data:model-output/", rp)),
                  stdout = dst, stderr = FALSE)
    if (rc == 0 && file.size(dst) > 0) restored <- restored + 1 else file.remove(dst)
  }
}
cat(sprintf("restored %d files\n", restored))

# Required quantile levels for this hub. These appear across all rounds in
# hub-config/tasks.json; the 23-level set is the union.
required_levels <- c(0.01, 0.025, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35,
                     0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80,
                     0.85, 0.90, 0.95, 0.975, 0.99)
cat(sprintf("required quantile levels: %d\n", length(required_levels)))

# Per-file audit
group_rows <- list(); file_rows <- list()
for (i in seq_len(nrow(fail_rows))) {
  rp     <- fail_rows$file[i]
  ftype  <- fail_rows$fail_type[i]
  full   <- file.path(mo_root, rp)
  if (!file.exists(full)) next
  df <- as.data.frame(read_parquet(full))
  date_col <- if ("reference_date" %in% names(df)) "reference_date" else "forecast_date"
  q  <- df[df$output_type == "quantile", , drop = FALSE]
  if (nrow(q) == 0) next
  q$q_level <- suppressWarnings(as.numeric(q$output_type_id))
  q <- q[!is.na(q$q_level), , drop = FALSE]

  # Per-group anchor count
  gkeys <- c("target", date_col, "location", "horizon")
  grouped <- q |>
    group_by(across(all_of(gkeys))) |>
    summarise(
      existing_levels = list(sort(unique(q_level))),
      n_existing      = length(unique(q_level)),
      .groups = "drop"
    ) |>
    mutate(
      n_missing       = length(required_levels) - n_existing,
      min_existing_p  = vapply(existing_levels, min, numeric(1)),
      max_existing_p  = vapply(existing_levels, max, numeric(1)),
      ref_date_col    = date_col,
      file            = rp
    )
  group_rows[[i]] <- grouped |>
    rename(ref_date = !!date_col) |>
    select(file, target, ref_date_col, ref_date, location, horizon,
           n_existing, n_missing, min_existing_p, max_existing_p)

  file_rows[[i]] <- tibble(
    file = rp,
    fail_type = ftype,
    n_groups = nrow(grouped),
    min_anchors_in_any_group = min(grouped$n_existing),
    pct_groups_below_5 = mean(grouped$n_existing < 5),
    eligible_for_distfromq = all(grouped$n_existing >= 5)
  )

  if (i %% 20 == 0) cat(sprintf("  audited %d/%d\n", i, nrow(fail_rows)))
}

groups_df <- bind_rows(group_rows)
files_df  <- bind_rows(file_rows)

write_csv(groups_df, file.path(log_dir, "fail_anchor_counts.csv"))
write_csv(files_df,  file.path(log_dir, "fail_anchor_summary.csv"))

cat("\n=== summary ===\n")
cat(sprintf("files audited: %d\n", nrow(files_df)))
cat(sprintf("files eligible (every group has >=5 anchors): %d\n",
            sum(files_df$eligible_for_distfromq)))
cat(sprintf("files ineligible (>=1 group with <5 anchors): %d\n",
            sum(!files_df$eligible_for_distfromq)))
cat("\nanchor-count distribution (min per file):\n")
print(table(files_df$min_anchors_in_any_group, files_df$fail_type))
cat(sprintf("\nwrote:\n  %s\n  %s\n",
            file.path(log_dir, "fail_anchor_counts.csv"),
            file.path(log_dir, "fail_anchor_summary.csv")))
