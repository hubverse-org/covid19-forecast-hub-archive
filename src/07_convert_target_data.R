#!/usr/bin/env Rscript
# Build target-data/time-series.csv from the legacy data-truth/ files.
#
# Mapping of source files to hubverse target IDs:
#   truth-Incident Deaths.csv       -> "inc death" (weekly, state + US)
#   truth-Cumulative Deaths.csv     -> "cum death" (weekly, state + US)
#   truth-Incident Cases.csv        -> "inc case"  (weekly, state + county + US)
#   truth-Incident Hospitalizations -> "inc hosp"  (daily,  state + US)
#
# truth-Cumulative Cases.csv and truth-Cumulative Hospitalizations.csv have no
# matching target in the archive's tasks.json (no "cum case"/"cum hosp"
# target_id) and are skipped.
#
# Weekly aggregation:
#   * target_end_date = Saturday of the MMWR week containing each daily date
#   * incident targets sum the 7 daily values within a week
#   * cumulative target takes the value at the Saturday end-of-week
#
# Output schema (hubverse target-data time-series):
#   target_end_date (date), location (chr), target (chr), observation (numeric)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(here)
})

src <- "../covid19-forecast-hub/data-truth"
dest_dir <- here::here("target-data")
if (!dir.exists(dest_dir)) dir.create(dest_dir, recursive = TRUE)

# --- helpers --------------------------------------------------------------
# Saturday at the END of the MMWR week containing `d`.
#   Sun (wday%=0) -> +6 days = next Sat
#   Sat (wday%=6) -> +0 days
saturday_of_week <- function(d) {
  d + (6L - as.integer(format(d, "%w"))) %% 7L
}

# Filter rows by location kind. `kinds` ⊆ {"US","state","county"}.
keep_loc_kinds <- function(df, kinds) {
  loc <- df$location
  k <- ifelse(loc == "US", "US",
              ifelse(nchar(loc) == 2L, "state",
                     ifelse(nchar(loc) == 5L, "county", "other")))
  df[k %in% kinds, , drop = FALSE]
}

read_truth <- function(path) {
  read_csv(path, col_types = cols(
    date          = col_date(),
    location      = col_character(),
    location_name = col_character(),
    value         = col_double()
  ))
}

# --- inc death (weekly, state + US) ---------------------------------------
cat("loading Incident Deaths...\n")
inc_d <- read_truth(file.path(src, "truth-Incident Deaths.csv")) |>
  keep_loc_kinds(c("US", "state")) |>
  mutate(target_end_date = saturday_of_week(date), target = "inc death") |>
  group_by(target_end_date, location, target) |>
  summarise(observation = sum(value, na.rm = FALSE), .groups = "drop")
cat("  rows:", nrow(inc_d), "\n")

# --- cum death (weekly EOW, state + US) -----------------------------------
cat("loading Cumulative Deaths...\n")
cum_d <- read_truth(file.path(src, "truth-Cumulative Deaths.csv")) |>
  keep_loc_kinds(c("US", "state")) |>
  mutate(target_end_date = saturday_of_week(date)) |>
  filter(date == target_end_date) |>            # keep only Saturday rows
  transmute(target_end_date, location, target = "cum death", observation = value)
cat("  rows:", nrow(cum_d), "\n")

# --- inc case (weekly, state + county + US) -------------------------------
cat("loading Incident Cases...\n")
inc_c <- read_truth(file.path(src, "truth-Incident Cases.csv")) |>
  keep_loc_kinds(c("US", "state", "county")) |>
  mutate(target_end_date = saturday_of_week(date), target = "inc case") |>
  group_by(target_end_date, location, target) |>
  summarise(observation = sum(value, na.rm = FALSE), .groups = "drop")
cat("  rows:", nrow(inc_c), "\n")

# --- inc hosp (daily, state + US) -----------------------------------------
cat("loading Incident Hospitalizations...\n")
inc_h <- read_truth(file.path(src, "truth-Incident Hospitalizations.csv")) |>
  keep_loc_kinds(c("US", "state")) |>
  transmute(target_end_date = date, location, target = "inc hosp",
            observation = value)
cat("  rows:", nrow(inc_h), "\n")

# --- combine and write ----------------------------------------------------
ts <- bind_rows(inc_d, cum_d, inc_c, inc_h) |>
  arrange(target, target_end_date, location)

cat(sprintf("\ntotal rows: %d\n", nrow(ts)))
cat("rows per target:\n"); print(table(ts$target))

dest <- file.path(dest_dir, "time-series.csv")
write_csv(ts, dest)
cat(sprintf("\nwrote %s (%.1f MB)\n",
            dest, file.size(dest) / 1024 / 1024))
