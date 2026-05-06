#!/usr/bin/env Rscript
# Build hub-config/tasks.json for the covid19-forecast-hub archive using hubAdmin.
#
# Design:
#   * 3 era-based rounds (R1-R3) reflecting changes in the set of requested
#     targets across the active life of the legacy hub:
#       R1 2020-03-15 → 2020-07-25  deaths only (wk inc, wk cum)
#       R2 2020-07-26 → 2023-03-05  deaths + cases + hosp (full triple)
#       R3 2023-03-06 → 2024-04-29  hosp only
#   * 4 target_kinds map to 4 targets with horizon as a separate task_id:
#       "inc death" (wk, h=1..20), "cum death" (wk, h=1..20),
#       "inc case"  (wk, h=1..8),  "inc hosp"  (day, h=0..130)
#   * Quantile sets are fixed per target:
#       deaths/hosp: 23 quantiles, case: 7 quantiles
#   * mean and median output_types are listed but is_required = FALSE
#   * round_id_from_variable: TRUE, round_id: "forecast_date"
#   * target_end_date is included as a regular task_id and is materialized in
#     every model-output file. It is NOT listed in derived_task_ids: although
#     it is technically a function of (forecast_date, target, horizon), the
#     legacy convention for weekly targets does not satisfy the simple
#     `target_end_date = forecast_date + horizon * unit` formula that hubverse
#     tooling assumes for derived task IDs, so we treat it as a stored,
#     authoritative column.
#
# Dates and locations come from inst/cache/, which is populated by
# 00_discover_data.R. Run that first if the caches don't exist.

suppressPackageStartupMessages({
  library(hubAdmin)
  library(dplyr)
  library(stringr)
  library(lubridate)
  library(here)
})

# Pin the hubverse schema version. v6.0.0 matches the placeholder admin.json.
options(hubAdmin.schema_version = "v6.0.0")

cache_dir <- here::here("inst", "cache")
all_pairs_path <- file.path(cache_dir, "all_pairs.rds")
all_locs_path  <- file.path(cache_dir, "all_locs.rds")

if (!file.exists(all_pairs_path) || !file.exists(all_locs_path)) {
  stop("Cache files missing — run src/00_discover_data.R first.")
}

all_pairs <- readRDS(all_pairs_path) |>
  rename(fdate = forecast_date)

# Parse legacy target strings -> (target_id, horizon)
parse_target <- function(s) {
  m <- str_match(s, "^(\\d+) (wk|day) ahead (inc|cum) (case|death|hosp)$")
  # Capture groups: 2 = horizon, 3 = wk|day, 4 = inc|cum, 5 = case|death|hosp
  list(
    target_id = paste(m[, 4], m[, 5]),  # "inc death", "cum death", "inc case", "inc hosp"
    horizon   = as.integer(m[, 2]),
    time_unit = m[, 3]
  )
}
parsed <- bind_cols(all_pairs, as_tibble(parse_target(all_pairs$target)))

# Compute target_end_date for each (forecast_date, horizon, time_unit) tuple,
# matching the legacy COVID-19 forecast hub convention:
#   weekly  -> Saturday at the end of the MMWR week containing forecast_date,
#              shifted by (horizon - 1) full weeks
#   daily   -> forecast_date + horizon days
end_of_epi_week <- function(d) {
  # MMWR week runs Sun..Sat; lubridate::wday(d, week_start = 7) returns
  # 1=Sun..7=Sat. Days to next Saturday (inclusive) = (7 - wday) %% 7.
  d + (7 - lubridate::wday(d, week_start = 7)) %% 7
}
parsed <- parsed |>
  mutate(target_end_date = dplyr::if_else(
    time_unit == "wk",
    end_of_epi_week(fdate) + (horizon - 1L) * 7L,
    fdate + horizon
  ))

# Per-target inventory
target_kinds <- list(
  "inc death" = list(time_unit = "week", target_name = "Weekly incident deaths",
                     target_units = "count", target_type = "discrete"),
  "cum death" = list(time_unit = "week", target_name = "Weekly cumulative deaths",
                     target_units = "count", target_type = "discrete"),
  "inc case"  = list(time_unit = "week", target_name = "Weekly incident cases",
                     target_units = "count", target_type = "discrete"),
  "inc hosp"  = list(time_unit = "day",  target_name = "Daily incident hospitalizations",
                     target_units = "count", target_type = "discrete")
)

# Quantile sets
q23 <- c(0.01, 0.025, seq(0.05, 0.95, by = 0.05), 0.975, 0.99)
q7  <- c(0.025, 0.10, 0.25, 0.50, 0.75, 0.90, 0.975)
stopifnot(length(q23) == 23, length(q7) == 7)

quantiles_for <- function(target_id) {
  if (target_id == "inc case") q7 else q23
}

# Locations: full set observed in data. The legacy hub accepted county-level
# (5-digit FIPS) submissions only for `inc case` forecasts; deaths and
# hospitalizations were state-level + US national only. Verified by full scan
# of all 8,970 source CSVs (see `verify_locs_horizons` discovery script).
all_locs <- readRDS(all_locs_path)
loc_kind <- dplyr::case_when(
  all_locs == "US"             ~ "US",
  nchar(all_locs) == 2L        ~ "state",
  nchar(all_locs) == 5L        ~ "county",
  TRUE                         ~ "other"
)
state_us_locs <- all_locs[loc_kind %in% c("state", "US")]
cat("total locations:", length(all_locs),
    " — state/US:", length(state_us_locs),
    " — county:", sum(loc_kind == "county"), "\n")

# Per-target location set
locations_for <- function(tid) {
  if (tid == "inc case") all_locs else state_us_locs
}

# Round windows (era boundaries from the README + observed first/last dates)
era_windows <- list(
  R1 = list(start = as.Date("2020-03-15"), end = as.Date("2020-07-25"),
            targets = c("inc death", "cum death")),
  R2 = list(start = as.Date("2020-07-26"), end = as.Date("2023-03-05"),
            targets = c("inc death", "cum death", "inc case", "inc hosp")),
  R3 = list(start = as.Date("2023-03-06"), end = as.Date("2024-04-29"),
            targets = c("inc hosp"))
)

# Build a model_task for one target_id within one era. `tid` to avoid
# shadowing the parsed$target_id column inside dplyr filter().
#
# `era_dates_union` is the union of all forecast_dates across the era's
# active targets — required by the hubverse schema, which mandates the
# round_id task_id (forecast_date) be consistent across all model_tasks
# within a single round.
build_model_task <- function(tid, era, era_dates_union) {
  tk <- target_kinds[[tid]]

  era_rows <- parsed |>
    filter(target_id == tid, fdate >= era$start, fdate <= era$end)

  active   <- era_rows |> distinct(fdate)   |> arrange(fdate)   |> pull(fdate) |> as.character()
  horizons <- era_rows |> distinct(horizon) |> arrange(horizon) |> pull(horizon)
  teds     <- era_rows |> distinct(target_end_date) |> arrange(target_end_date) |>
                pull(target_end_date) |> as.character()

  cat(sprintf("  %s: %d dates (of %d in era), horizons %s, teds %d\n",
              tid, length(active), length(era_dates_union),
              if (length(horizons)) sprintf("%d-%d", min(horizons), max(horizons)) else "(none)",
              length(teds)))

  if (length(active) == 0L) return(NULL)

  task_locs <- locations_for(tid)
  task_ids <- create_task_ids(
    create_task_id("forecast_date",   required = NULL, optional = era_dates_union),
    create_task_id("target",          required = tid, optional = NULL),
    create_task_id("horizon",         required = NULL, optional = as.integer(horizons)),
    create_task_id("location",        required = NULL, optional = task_locs),
    create_task_id("target_end_date", required = NULL, optional = teds)
  )

  # NOTE: hubAdmin's check_items_unique compares output_type_item lists by
  # content (ignoring names), so create_output_type_mean() and
  # create_output_type_median() with identical args trigger a false-positive
  # duplicate error. Differentiate them by giving median a hard non-negative
  # bound (counts cannot be negative) and leaving mean unbounded (a poorly
  # calibrated model's mean prediction could in principle dip below zero).
  qs <- quantiles_for(tid)
  output_type <- create_output_type(
    create_output_type_quantile(required = qs, is_required = TRUE,
                                value_type = "double", value_minimum = 0),
    create_output_type_mean(is_required = FALSE,
                            value_type = "double"),
    create_output_type_median(is_required = FALSE,
                              value_type = "double", value_minimum = 0)
  )

  tm <- create_target_metadata(
    create_target_metadata_item(
      target_id     = tid,
      target_name   = tk$target_name,
      target_units  = tk$target_units,
      target_keys   = list(target = tid),
      target_type   = tk$target_type,
      is_step_ahead = TRUE,
      time_unit     = tk$time_unit
    )
  )

  create_model_task(task_ids = task_ids, output_type = output_type, target_metadata = tm)
}

# Build a round from an era
build_round <- function(era_name, era) {
  cat(sprintf("\n[%s] %s -> %s, targets: %s\n",
              era_name,
              format(era$start), format(era$end),
              paste(era$targets, collapse = ", ")))

  # Compute the union of dates across all this era's active targets,
  # so every model_task within the round shares the same forecast_date list.
  era_dates_union <- parsed |>
    filter(target_id %in% era$targets,
           fdate >= era$start, fdate <= era$end) |>
    distinct(fdate) |> arrange(fdate) |> pull(fdate) |> as.character()
  cat(sprintf("  era forecast_date union: %d dates\n", length(era_dates_union)))

  mt_list <- lapply(era$targets, function(t) build_model_task(t, era, era_dates_union))
  mt_list <- mt_list[!vapply(mt_list, is.null, logical(1))]

  mts <- do.call(create_model_tasks, mt_list)

  create_round(
    round_id_from_variable = TRUE,
    round_id = "forecast_date",
    model_tasks = mts,
    submissions_due = list(
      start = format(era$start),
      end   = format(era$end)
    )
  )
}

rounds_list <- mapply(build_round,
                     names(era_windows), era_windows,
                     SIMPLIFY = FALSE)

cfg <- create_config(
  do.call(create_rounds, unname(rounds_list)),
  output_type_id_datatype = "double",
  derived_task_ids = "target_end_date"
)

dest <- here::here("hub-config", "tasks.json")
write_config(cfg, hub_path = here::here(), overwrite = TRUE, silent = FALSE)
cat(sprintf("\nwrote %s (%.1f KB)\n", dest, file.size(dest) / 1024))

# Validate
cat("\n--- validate_config ---\n")
v <- validate_config(hub_path = here::here(), config = "tasks")
print(v)
