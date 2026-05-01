#!/usr/bin/env Rscript
# Scan ../covid19-forecast-hub/data-processed/ to inventory the legacy hub:
#   - distinct (forecast_date, target) pairs (one file sampled per date)
#   - distinct location codes
# Caches results to inst/cache/ so subsequent config scripts can reuse them.
#
# Re-run this whenever the source data changes.

suppressPackageStartupMessages({
  library(readr); library(dplyr); library(purrr); library(stringr); library(here)
})

src_root <- "../covid19-forecast-hub/data-processed"
cache_dir <- here::here("inst", "cache")
if (!dir.exists(cache_dir)) dir.create(cache_dir, recursive = TRUE)

files <- list.files(src_root, "\\.csv$", recursive = TRUE, full.names = TRUE)
cat("total csv files:", length(files), "\n")

# --- (forecast_date, target) inventory -----------------------------------
# Read every CSV's target column and pair with the forecast_date encoded
# in the filename. Sampling one file per date undercounts because different
# teams submit different targets on the same date.
fdates <- str_extract(basename(files), "^\\d{4}-\\d{2}-\\d{2}")
df_files <- tibble(file = files, fdate = as.Date(fdates)) |>
  filter(!is.na(fdate))

read_targets <- function(f, fd) {
  tryCatch({
    d <- suppressWarnings(read_csv(f, col_types = cols_only(target = col_character())))
    tibble(forecast_date = fd, target = unique(d$target))
  }, error = function(e) NULL)
}

cat("scanning all", nrow(df_files), "files for (forecast_date, target)...\n")
t0 <- Sys.time()
all_pairs <- map2_dfr(df_files$file, df_files$fdate, read_targets) |> distinct()
cat(sprintf("  done in %.1fs\n", as.numeric(difftime(Sys.time(), t0, units = "secs"))))
cat("distinct (forecast_date, target) pairs:", nrow(all_pairs), "\n")
saveRDS(all_pairs, file.path(cache_dir, "all_pairs.rds"))

# --- location inventory --------------------------------------------------
# Sample 3 files per team-model directory (covers seasonal location coverage)
dirs <- list.dirs(src_root, recursive = FALSE)
loc_samp <- map(dirs, function(d) {
  fs <- list.files(d, "\\.csv$", full.names = TRUE)
  if (length(fs) <= 3) fs else fs[round(seq(1, length(fs), length.out = 3))]
}) |> unlist()
cat("scanning", length(loc_samp), "files for locations...\n")

read_locs <- function(f) {
  tryCatch({
    d <- suppressWarnings(read_csv(f, col_types = cols_only(location = col_character())))
    unique(d$location)
  }, error = function(e) NULL)
}
all_locs <- map(loc_samp, read_locs) |> unlist() |> unique() |> sort()
cat("distinct locations:", length(all_locs), "\n")
saveRDS(all_locs, file.path(cache_dir, "all_locs.rds"))

cat("\nwrote:\n",
    file.path(cache_dir, "all_pairs.rds"), "\n",
    file.path(cache_dir, "all_locs.rds"),  "\n")
