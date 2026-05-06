#!/usr/bin/env Rscript
# Fast(er) submission validator. Runs every per-file hubValidations check
# EXCEPT `req_vals` (which is dominated by hubValidations:::missing_required
# at ~18s/file for our R2 inc-hosp model_task), and replaces it with a
# vectorised dplyr equivalent that asks the same question:
#
#   For every (target, forecast_date, location, horizon) group present in
#   the file, are all of that target's REQUIRED quantile output_type_id
#   values present?
#
# That is the only completeness obligation on our hub — `mean` and `median`
# are is_required=FALSE; forecast_date/location/horizon are all optional.
#
# The custom check is sourced into each parallel worker and the per-file
# pass/fail/notes log lands in src/logs/validate_submissions_fast_<date>.csv.

suppressPackageStartupMessages({
  library(here); library(dplyr); library(purrr); library(furrr); library(readr)
  library(arrow); library(hubValidations)
})

hub_path <- here::here()
mo_root  <- file.path(hub_path, "model-output")
log_dir  <- here::here("src", "logs")
if (!dir.exists(log_dir)) dir.create(log_dir, recursive = TRUE)

# Required quantile sets per target (mirror src/02_build_tasks_json.R).
# NOTE: enumerate literally — `seq(0.05, 0.95, by = 0.05)` accumulates
# floating-point error (e.g. produces 0.15000000000000002 instead of 0.15),
# which `setdiff()` against the bit-exact parquet values then flags as
# "missing".
Q23 <- c(0.01, 0.025, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45,
         0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 0.975, 0.99)
Q7  <- c(0.025, 0.10, 0.25, 0.50, 0.75, 0.90, 0.975)
stopifnot(length(Q23) == 23, length(Q7) == 7)
REQUIRED_Q <- list(
  "inc death" = Q23,
  "cum death" = Q23,
  "inc hosp"  = Q23,
  "inc case"  = Q7
)

# Vectorised completeness check.
# Returns NULL on success, else a tibble of (target, group_key…, missing_qs).
fast_req_check <- function(tbl) {
  q <- tbl[tbl$output_type == "quantile", , drop = FALSE]
  if (nrow(q) == 0L) {
    return(tibble::tibble(target = character(), forecast_date = as.Date(character()),
                          location = character(), horizon = integer(),
                          missing_qs = character()))
  }
  q$qid <- as.numeric(q$output_type_id)

  failed <- list()
  for (tgt in unique(q$target)) {
    rq <- REQUIRED_Q[[tgt]]
    if (is.null(rq)) next

    g <- q[q$target == tgt, , drop = FALSE] |>
      group_by(forecast_date, location, horizon) |>
      summarise(present = list(unique(qid)), .groups = "drop")
    g$missing_qs <- vapply(g$present, function(p) {
      m <- setdiff(rq, p)
      if (length(m) == 0L) "" else paste(sort(m), collapse = ",")
    }, character(1))
    g <- g[nzchar(g$missing_qs), c("forecast_date", "location", "horizon", "missing_qs"), drop = FALSE]
    if (nrow(g) > 0L) {
      g$target <- tgt
      failed[[tgt]] <- g
    }
  }
  if (length(failed) == 0L) {
    return(tibble::tibble(target = character(), forecast_date = as.Date(character()),
                          location = character(), horizon = integer(),
                          missing_qs = character()))
  }
  bind_rows(failed)
}

# Run all hubValidations checks except req_vals + the custom fast req check.
fast_validate_one <- function(rel_path) {
  res <- list(
    file = rel_path, ok = TRUE, n_failed = 0L,
    n_missing = 0L, first_error = NA_character_
  )

  # Wrap every native check; treat any failure as a single ok=FALSE.
  failures <- character()
  add_failure <- function(name, msg) {
    failures[[length(failures) + 1L]] <<- sprintf("%s: %s", name, msg)
  }
  run_check <- function(name, expr) {
    out <- tryCatch(force(expr), error = function(e) e)
    if (inherits(out, "error")) {
      add_failure(name, conditionMessage(out)); return(invisible(FALSE))
    }
    if (inherits(out, "check_failure") || inherits(out, "check_error")) {
      add_failure(name, out$message %||% format(out)); return(invisible(FALSE))
    }
    invisible(TRUE)
  }

  `%||%` <- function(a, b) if (is.null(a) || (length(a) == 0L)) b else a

  # File-level checks.
  run_check("file_name",     check_file_name(file_path = rel_path))
  run_check("file_location", check_file_location(file_path = rel_path))

  # parse_file_name throws hard for filenames containing "+" (e.g.
  # UChicago-CovidIL_10_+); skip the rest of the checks for such files since
  # the file_name check will already have flagged them.
  parsed <- tryCatch(hubValidations:::parse_file_name(rel_path),
                     error = function(e) e)
  if (inherits(parsed, "error")) {
    if (length(failures) == 0L) add_failure("parse_file_name", conditionMessage(parsed))
    res$ok <- FALSE
    res$n_failed <- length(failures)
    res$first_error <- failures[[1L]]
    return(tibble::as_tibble(res))
  }
  round_id_guess <- parsed$round_id

  run_check("file_format", check_file_format(file_path = rel_path,
                                              hub_path = hub_path,
                                              round_id = round_id_guess))
  run_check("file_read",   check_file_read(file_path = rel_path, hub_path = hub_path))

  if (length(failures) > 0L) {
    res$ok <- FALSE
    res$n_failed <- length(failures)
    res$first_error <- failures[[1L]]
    return(tibble::as_tibble(res))
  }

  # Read the file once, both raw and char-coerced
  tbl     <- read_model_out_file(file_path = rel_path, hub_path = hub_path, coerce_types = "none")
  tbl_chr <- read_model_out_file(file_path = rel_path, hub_path = hub_path, coerce_types = "chr")
  round_id <- round_id_guess

  run_check("colnames",          check_tbl_colnames(tbl, round_id = round_id, file_path = rel_path, hub_path = hub_path))
  run_check("col_types",         check_tbl_col_types(tbl, file_path = rel_path, hub_path = hub_path, output_type_id_datatype = "from_config"))
  run_check("unique_round_id",   check_tbl_unique_round_id(tbl, round_id_col = NULL, file_path = rel_path, hub_path = hub_path))
  run_check("match_round_id",    check_tbl_match_round_id(tbl, round_id_col = NULL, file_path = rel_path, hub_path = hub_path))
  run_check("valid_vals",        check_tbl_values(tbl_chr, round_id = round_id, file_path = rel_path, hub_path = hub_path, derived_task_ids = NULL))
  run_check("rows_unique",       check_tbl_rows_unique(tbl_chr, file_path = rel_path, hub_path = hub_path))
  run_check("value_col_valid",   check_tbl_value_col(tbl, round_id = round_id, file_path = rel_path, hub_path = hub_path, derived_task_ids = NULL))
  run_check("value_col_non_desc",check_tbl_value_col_ascending(tbl_chr, file_path = rel_path, hub_path = hub_path, round_id = round_id, derived_task_ids = NULL))

  # Fast custom req_vals
  miss <- fast_req_check(tbl)
  if (nrow(miss) > 0L) {
    add_failure("fast_req_vals",
                sprintf("%d (target, ref_date, location, horizon) groups missing required quantiles",
                        nrow(miss)))
    res$n_missing <- nrow(miss)
  }

  if (length(failures) > 0L) {
    res$ok <- FALSE
    res$n_failed <- length(failures)
    res$first_error <- failures[[1L]]
  }
  tibble::as_tibble(res)
}

# --- driver ---------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
mode <- if ("--full" %in% args) "full" else "sample"

team_dirs <- list.dirs(mo_root, recursive = FALSE)
team_dirs <- team_dirs[basename(team_dirs) != "" & !grepl("^\\.", basename(team_dirs))]

if (mode == "sample") {
  files <- map_chr(team_dirs, function(d) {
    fs <- list.files(d, "\\.parquet$", full.names = TRUE)
    if (length(fs)) sort(fs, decreasing = TRUE)[1] else NA_character_
  })
  files <- files[!is.na(files)]
} else {
  files <- list.files(mo_root, "\\.parquet$", recursive = TRUE, full.names = TRUE)
}

rel_paths <- sub(paste0("^", mo_root, "/?"), "", files)
cat("validating", length(rel_paths),
    if (mode == "sample") "(sample)" else "(full)", "files\n")

t0 <- Sys.time()
if (mode == "full") {
  plan(multisession, workers = 8L)
  on.exit(plan(sequential), add = TRUE)
  res <- future_map_dfr(rel_paths, fast_validate_one,
                       .options = furrr_options(seed = TRUE,
                                                globals = c("hub_path", "fast_req_check", "REQUIRED_Q"),
                                                packages = c("hubValidations", "tibble", "dplyr", "arrow")))
} else {
  res <- map_dfr(rel_paths, fast_validate_one)
}
elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
cat(sprintf("done in %.1fs (%.1f min)\n", elapsed, elapsed / 60))

cat("\n--- summary ---\n")
res |> summarise(ok = sum(ok), failed = sum(!ok),
                 total_missing = sum(n_missing, na.rm = TRUE)) |> print()

if (any(!res$ok)) {
  cat("\n--- failures grouped by first_error (truncated) ---\n")
  res |> filter(!ok) |>
    mutate(err = substr(first_error, 1, 80)) |>
    count(err, sort = TRUE) |> print(n = 30)
}

log_path <- file.path(log_dir,
  sprintf("validate_submissions_fast_%s_%s.csv", mode, Sys.Date()))
write_csv(res, log_path)
cat("\nlog:", log_path, "\n")
