#!/usr/bin/env Rscript
# Validate every model-output parquet file via hubValidations::validate_submission.
#
# Strategy: stratified sample first (one file per team-model dir) to surface
# common errors fast, then optionally a full run. Pass --full to run on every
# file.
#
# Per-file pass/fail/notes go to src/logs/validate_submissions_<date>.csv.

suppressPackageStartupMessages({
  library(here); library(dplyr); library(purrr); library(furrr); library(readr)
  library(hubValidations)
})

hub_path <- here::here()
mo_root  <- file.path(hub_path, "model-output")
log_dir  <- here::here("src", "logs")
if (!dir.exists(log_dir)) dir.create(log_dir, recursive = TRUE)

args <- commandArgs(trailingOnly = TRUE)
mode <- if ("--full" %in% args) "full" else "sample"

team_dirs <- list.dirs(mo_root, recursive = FALSE)
team_dirs <- team_dirs[basename(team_dirs) != "" & !grepl("^\\.", basename(team_dirs))]

if (mode == "sample") {
  # one (newest) file per team-model
  files <- map_chr(team_dirs, function(d) {
    fs <- list.files(d, "\\.parquet$", full.names = TRUE)
    if (length(fs)) sort(fs, decreasing = TRUE)[1] else NA_character_
  })
  files <- files[!is.na(files)]
} else {
  files <- list.files(mo_root, "\\.parquet$", recursive = TRUE, full.names = TRUE)
}

# file_path is relative to model-output/
rel_paths <- sub(paste0("^", mo_root, "/?"), "", files)
cat("validating", length(rel_paths), if (mode == "sample") "(sample)" else "(full)",
    "files\n")

validate_one <- function(rp) {
  res <- tryCatch(
    validate_submission(hub_path = hub_path,
                        file_path = rp,
                        skip_submit_window_check = TRUE,
                        skip_check_config = TRUE),
    error = function(e) e
  )
  if (inherits(res, "error")) {
    return(tibble::tibble(file = rp, ok = FALSE,
                          n_failed = NA_integer_,
                          first_error = conditionMessage(res)))
  }
  failed <- res[vapply(res, function(x) inherits(x, "check_failure") ||
                                         inherits(x, "check_error"),
                       logical(1))]
  if (length(failed) == 0L) {
    return(tibble::tibble(file = rp, ok = TRUE,
                          n_failed = 0L,
                          first_error = NA_character_))
  }
  msgs <- vapply(failed, function(x) {
    m <- tryCatch(x$message %||% x$error_message %||% format(x),
                  error = function(e) "<unformattable>")
    if (length(m) == 0L) "<empty>" else m[[1L]]
  }, character(1))
  tibble::tibble(file = rp, ok = FALSE,
                 n_failed = length(failed),
                 first_error = paste(unique(msgs), collapse = " || "))
}

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 0L)) b else a

t0 <- Sys.time()
if (mode == "full") {
  plan(multisession, workers = 8L)
  res <- future_map_dfr(rel_paths, validate_one,
                       .options = furrr_options(seed = TRUE,
                                                globals = c("hub_path"),
                                                packages = c("hubValidations", "tibble")))
  plan(sequential)
} else {
  res <- map_dfr(rel_paths, validate_one)
}
elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
cat(sprintf("done in %.1fs (%.1f min)\n", elapsed, elapsed / 60))

cat("\n--- summary ---\n")
res |> summarise(ok = sum(ok), failed = sum(!ok)) |> print()

if (any(!res$ok)) {
  cat("\n--- failures grouped by error ---\n")
  res |> filter(!ok) |>
    count(first_error, sort = TRUE) |> print(n = 30)
}

log_path <- file.path(log_dir,
  sprintf("validate_submissions_%s_%s.csv", mode, Sys.Date()))
write_csv(res, log_path)
cat("\nlog:", log_path, "\n")
