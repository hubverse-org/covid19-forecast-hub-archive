#!/usr/bin/env Rscript
# Per-cohort summary of the distfromq remediation outcomes (PR #18).
#
# Joins the three log files written by the remediation pipeline and groups
# the 188 incomplete-quantile files by (team_model, min_anchors_in_any_group)
# -- a "cohort" of files with similar submission density. For each cohort
# reports how many were imputed, how many had any group dropped, how many
# ended up with all quantile groups dropped (file becomes mean/median-only),
# and how many pass validation after the fix.
#
# Outputs:
#   * src/logs/distfromq_remediation_summary.csv -- one row per cohort
#   * stdout summary printed at the end
#
# This is the data source for the "Per-cohort outcome summary" table in
# docs/distfromq-imputation-examples.md. To refresh the table after a
# pipeline re-run, regenerate the CSV here and re-render the markdown
# table from it (or paste this CSV's columns into the table).

suppressPackageStartupMessages({
  library(here); library(readr); library(dplyr); library(tidyr)
})

log_dir <- file.path(here::here(), "src", "logs")

anchor <- read_csv(file.path(log_dir, "fail_anchor_summary.csv"),  show_col_types = FALSE)
fill   <- read_csv(file.path(log_dir, "distfromq_fill_log.csv"),   show_col_types = FALSE)
valid  <- read_csv(file.path(log_dir, "validate_fixed_local.csv"), show_col_types = FALSE)

joined <- anchor |>
  filter(fail_type == "incomplete") |>
  select(file, min_anchors_in_any_group) |>
  inner_join(
    fill |> select(file, n_groups_after, n_groups_filled, n_groups_dropped,
                   n_rows_added, n_rows_dropped),
    by = "file"
  ) |>
  inner_join(valid |> select(file, ok), by = "file") |>
  mutate(team_model = sub("/.*$", "", file))

summary <- joined |>
  group_by(team_model, min_anchors = min_anchors_in_any_group) |>
  summarise(
    n_files                              = n(),
    n_files_with_imputation              = sum(n_groups_filled  > 0),
    n_files_with_group_drops             = sum(n_groups_dropped > 0),
    n_files_all_quantile_groups_dropped  = sum(n_groups_after  == 0),
    n_files_validation_ok_after_fix      = sum(ok),
    rows_imputed_sum                     = sum(n_rows_added),
    rows_dropped_sum                     = sum(n_rows_dropped),
    .groups = "drop"
  ) |>
  arrange(team_model, min_anchors)

out_path <- file.path(log_dir, "distfromq_remediation_summary.csv")
write_csv(summary, out_path)

cat(sprintf("wrote %s (%d cohorts)\n\n", out_path, nrow(summary)))
print(summary, n = Inf)

cat(sprintf("\nTOTAL: %d files, %d imputed, %d with drops, %d all-q dropped, %d validation_ok\n",
            sum(summary$n_files),
            sum(summary$n_files_with_imputation),
            sum(summary$n_files_with_group_drops),
            sum(summary$n_files_all_quantile_groups_dropped),
            sum(summary$n_files_validation_ok_after_fix)))
