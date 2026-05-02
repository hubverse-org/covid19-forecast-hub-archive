#!/usr/bin/env Rscript
# One-off backfill: rewrite every model-output parquet so that
#   * the legacy column name `reference_date` is restored to `forecast_date`
#   * a `target_end_date` column is added, computed from
#       weekly  -> end_of_epi_week(forecast_date) + (horizon - 1) * 7
#       daily   -> forecast_date + horizon
#   * column order is forecast_date, target, horizon, location,
#     target_end_date, output_type, output_type_id, value
# This brings on-disk files into agreement with the updated
# 10_convert_forecast_file.R schema and the regenerated tasks.json.

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(lubridate)
  library(here)
})

end_of_epi_week <- function(d) {
  d + (7 - lubridate::wday(d, week_start = 7)) %% 7
}

WEEKLY <- c("inc death", "cum death", "inc case")
DAILY  <- c("inc hosp")

backfill_one <- function(path) {
  d <- arrow::read_parquet(path)
  if ("forecast_date" %in% colnames(d) && "target_end_date" %in% colnames(d)) {
    return(c(path = path, status = "skip"))
  }
  if ("reference_date" %in% colnames(d)) {
    d <- dplyr::rename(d, forecast_date = reference_date)
  }
  d <- d |> mutate(
    target_end_date = dplyr::if_else(
      target %in% WEEKLY,
      end_of_epi_week(forecast_date) + (horizon - 1L) * 7L,
      forecast_date + horizon
    )
  )
  d <- d |> select(forecast_date, target, horizon, location, target_end_date,
                   output_type, output_type_id, value)
  arrow::write_parquet(d, path)
  c(path = path, status = "ok")
}

main <- function() {
  files <- list.files(here::here("model-output"),
                      pattern = "\\.parquet$",
                      recursive = TRUE,
                      full.names = TRUE)
  cat(sprintf("backfilling %d files\n", length(files)))

  res <- vector("list", length(files))
  for (i in seq_along(files)) {
    res[[i]] <- backfill_one(files[i])
    if (i %% 500 == 0) cat(sprintf("  %d / %d\n", i, length(files)))
  }
  tab <- table(vapply(res, function(x) x[["status"]], character(1)))
  cat("\nresults:\n"); print(tab)
}

if (sys.nframe() == 0L && !interactive()) main()
