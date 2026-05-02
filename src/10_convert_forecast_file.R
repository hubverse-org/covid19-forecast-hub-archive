#!/usr/bin/env Rscript
# Convert one legacy covid19-forecast-hub forecast CSV into a hubverse-style
# parquet file at model-output/<team-model>/<YYYY-MM-DD>-<team-model>.parquet.
#
# Source schema (legacy):
#   forecast_date, target, target_end_date, location, type (point|quantile),
#   quantile, value
#
# Output schema (matches tasks.json):
#   forecast_date, target, horizon, location, target_end_date,
#   output_type, output_type_id, value
#
# Conversions / rules:
#   * forecast_date     -> forecast_date  (passed through verbatim; kept under
#                          the legacy name rather than renamed to
#                          reference_date)
#   * target string     -> (target, horizon) via parse_target()
#   * target_end_date   -> passed through verbatim from the legacy data.
#       Note: for weekly targets the legacy forecast_date was Mon/Sun while
#       target_end_date was the MMWR Saturday, so target_end_date does NOT
#       always equal forecast_date + horizon * unit. Keeping the source
#       value preserves the actual observation date faithfully.
#   * type == "quantile" -> output_type = "quantile",
#                            output_type_id = quantile (numeric)
#   * type == "point"    -> a per-FILE decision:
#       group by (location, target, horizon). If for every group a
#       quantile=0.5 row exists AND its value matches the point row's
#       (relative tol 1e-6), label all of the file's points as "median".
#       Otherwise label all of them as "mean". One determination per file.
#   * Rows whose target is not active in the file's round window are dropped
#     and counted in the result; other rows are passed through.
#
# This file defines the convert_forecast_file() function plus a small CLI for
# converting a single file when invoked as a script (used by the smoke test).

suppressPackageStartupMessages({
  library(readr); library(dplyr); library(stringr); library(tibble)
  library(arrow); library(here)
})

source(here::here("src", "09_parse_target.R"))

# Era / round table — must mirror src/02_build_tasks_json.R
ERA_TABLE <- tibble::tribble(
  ~round, ~start,        ~end,
  "R1",   "2020-03-15",  "2020-07-25",
  "R2",   "2020-07-26",  "2023-03-05",
  "R3",   "2023-03-06",  "2024-04-29",
) |> dplyr::mutate(start = as.Date(start), end = as.Date(end))

ERA_TARGETS <- list(
  R1 = c("inc death", "cum death"),
  R2 = c("inc death", "cum death", "inc case", "inc hosp"),
  R3 = c("inc hosp")
)

# Each target has a single canonical time_unit in tasks.json. Drop legacy
# rows whose parsed time_unit disagrees (e.g. "1 day ahead cum death" — none
# observed in the archive, but defensive).
TARGET_UNIT <- c(
  "inc death" = "wk",
  "cum death" = "wk",
  "inc case"  = "wk",
  "inc hosp"  = "day"
)

round_for_date <- function(d) {
  for (i in seq_len(nrow(ERA_TABLE))) {
    if (d >= ERA_TABLE$start[i] && d <= ERA_TABLE$end[i]) return(ERA_TABLE$round[i])
  }
  NA_character_
}

#' Convert one legacy forecast CSV into a hubverse-conformant parquet file.
#'
#' @param in_path  path to the source CSV under data-processed/<team-model>/
#' @param out_root output directory root (typically <hub>/model-output)
#' @return a one-row tibble describing the outcome (file, ok, n_in, n_out,
#'   n_dropped_round, point_output_type, round, error)
convert_forecast_file <- function(in_path, out_root) {
  team_model <- basename(dirname(in_path))
  bad <- function(msg) tibble::tibble(
    file = in_path, ok = FALSE, n_in = NA_integer_, n_out = NA_integer_,
    n_dropped_round = NA_integer_, point_output_type = NA_character_,
    round = NA_character_, error = msg
  )

  d <- tryCatch(
    suppressWarnings(read_csv(in_path,
      col_types = cols_only(
        forecast_date   = col_date(),
        target          = col_character(),
        target_end_date = col_date(),
        location        = col_character(),
        type            = col_character(),
        quantile        = col_double(),
        value           = col_double()
      ),
      progress = FALSE)),
    error = function(e) e)
  if (inherits(d, "error")) return(bad(paste0("read: ", conditionMessage(d))))
  if (nrow(d) == 0L)        return(bad("empty file"))

  if (length(unique(d$forecast_date)) > 1L) {
    return(bad("multiple forecast_dates in file"))
  }
  ref_date <- d$forecast_date[1]

  rnd <- round_for_date(ref_date)
  if (is.na(rnd)) return(bad(sprintf("forecast_date %s outside all rounds",
                                     format(ref_date))))

  # Parse target into (target_id, horizon, time_unit) and drop unparseable rows.
  parsed <- parse_target(d$target)
  d$target_id <- parsed$target
  d$horizon   <- parsed$horizon
  d$time_unit <- parsed$time_unit
  unparsed_n <- sum(is.na(d$target_id))
  if (unparsed_n > 0L) d <- d[!is.na(d$target_id), , drop = FALSE]

  # Round filter: keep only rows whose target_id is active in the round
  # AND whose parsed time_unit matches the target's canonical unit.
  active <- ERA_TARGETS[[rnd]]
  expected_unit <- TARGET_UNIT[d$target_id]
  in_round <- d$target_id %in% active & !is.na(expected_unit) &
              d$time_unit == expected_unit
  n_dropped <- sum(!in_round)
  d <- d[in_round, , drop = FALSE]
  if (nrow(d) == 0L) return(bad(sprintf(
    "no rows match round %s active targets (%d dropped)", rnd, n_dropped + unparsed_n)))

  # ---- point → mean/median determination (per file) ----
  pts <- d |> filter(type == "point")
  qs  <- d |> filter(type == "quantile")
  med_lookup <- qs |> filter(abs(quantile - 0.5) < 1e-9) |>
    select(location, target_id, horizon, q50 = value)
  if (nrow(pts) == 0L) {
    point_ot <- NA_character_
    all_match <- NA
  } else {
    chk <- pts |>
      left_join(med_lookup, by = c("location", "target_id", "horizon")) |>
      mutate(match = !is.na(q50) &
                     abs(value - q50) <= 1e-6 * pmax(abs(value), 1))
    all_match <- all(chk$match)
    point_ot  <- if (isTRUE(all_match)) "median" else "mean"
  }

  # ---- emit hubverse rows ----
  out_q <- qs |> transmute(
    forecast_date,
    target         = target_id,
    horizon        = as.integer(horizon),
    location,
    target_end_date,
    output_type    = "quantile",
    output_type_id = quantile,
    value
  )

  out_p <- if (nrow(pts) > 0L) {
    pts |> transmute(
      forecast_date,
      target         = target_id,
      horizon        = as.integer(horizon),
      location,
      target_end_date,
      output_type    = point_ot,
      output_type_id = NA_real_,
      value
    )
  } else {
    NULL
  }

  out <- bind_rows(out_q, out_p)

  out_dir <- file.path(out_root, team_model)
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  out_path <- file.path(out_dir,
                        sprintf("%s-%s.parquet", format(ref_date), team_model))
  arrow::write_parquet(out, out_path)

  tibble::tibble(
    file = in_path,
    ok = TRUE,
    n_in  = nrow(d) + n_dropped + unparsed_n,
    n_out = nrow(out),
    n_dropped_round = n_dropped + unparsed_n,
    point_output_type = point_ot %||% NA_character_,
    round = rnd,
    error = NA_character_
  )
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# CLI: Rscript src/10_convert_forecast_file.R <input.csv> <output_root>
if (sys.nframe() == 0L && !interactive()) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) == 2L) {
    res <- convert_forecast_file(args[1], args[2])
    print(res)
  }
}
