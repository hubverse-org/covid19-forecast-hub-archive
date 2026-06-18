#!/usr/bin/env Rscript
# Re-validate the 190 cluster-failure files after the src/19 noise-clamp
# and src/20 distfromq fixes, locally via parallel::mclapply.
#
# Uses the same hubValidations::validate_submission entry point as the
# Slurm pipeline (src/cluster/validate_chunk.R), just parallelised in-
# process via fork-based workers.
#
# Inputs:
#   * src/logs/pr-submission-tracking.csv -- enumerates the 190 failing
#     files via `ok == "FALSE"`.
#   * model-output/<...> -- the fixed parquet files (in place).
#
# Outputs:
#   src/logs/validate_fixed_local.csv -- one row per file:
#     file, ok, n_failed, elapsed_sec, first_error
#
# Args (env):
#   N_CORES (default = parallel::detectCores()), e.g. N_CORES=8 Rscript ...

suppressPackageStartupMessages({
  library(here); library(parallel); library(readr); library(tibble);
  library(dplyr); library(hubValidations)
})

repo_root <- here::here()
log_dir   <- file.path(repo_root, "src", "logs")

n_cores <- as.integer(Sys.getenv("N_CORES", unset = parallel::detectCores()))
cat(sprintf("using %d cores\n", n_cores))

`%||%` <- function(a, b) if (is.null(a)) b else a

# Enumerate target files
tracking <- read_csv(file.path(log_dir, "pr-submission-tracking.csv"),
                     show_col_types = FALSE)
files <- tracking |> filter(ok == "FALSE") |> pull(file)
cat(sprintf("validating %d files\n", length(files)))

validate_one <- function(rp) {
  t0 <- Sys.time()
  v <- tryCatch(
    hubValidations::validate_submission(
      hub_path = repo_root,
      file_path = rp,
      skip_submit_window_check = TRUE
    ),
    error = function(e) e
  )
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  if (inherits(v, "error")) {
    return(tibble(file = rp, ok = FALSE, n_failed = NA_integer_,
                  elapsed_sec = elapsed,
                  first_error = paste0("validate_submission error: ",
                                       conditionMessage(v))))
  }

  ok_pass <- tryCatch({
    hubValidations::check_for_errors(v, verbose = FALSE); TRUE
  }, error = function(e) FALSE)

  if (ok_pass) {
    return(tibble(file = rp, ok = TRUE, n_failed = 0L,
                  elapsed_sec = elapsed, first_error = NA_character_))
  }

  flat <- if (inherits(v, "hub_validations_collection")) {
    unlist(v, recursive = FALSE, use.names = FALSE)
  } else v
  failed <- vapply(flat, function(chk) {
    inherits(chk, "check_failure") || inherits(chk, "check_error")
  }, logical(1))
  first <- which(failed)[1]
  msg <- if (!is.na(first)) {
    chk <- flat[[first]]
    sprintf("%s: %s", chk$name %||% "?",
            chk$message %||% "(no message)")
  } else "(unknown)"
  tibble(file = rp, ok = FALSE, n_failed = sum(failed),
         elapsed_sec = elapsed, first_error = msg)
}

t_start <- Sys.time()
results <- parallel::mclapply(files, validate_one,
                              mc.cores = n_cores,
                              mc.preschedule = FALSE)
out <- bind_rows(results)
total <- as.numeric(difftime(Sys.time(), t_start, units = "secs"))

out_path <- file.path(log_dir, "validate_fixed_local.csv")
write_csv(out, out_path)

cat(sprintf("\n=== summary ===\n"))
cat(sprintf("total wall time: %.1f min\n", total / 60))
cat(sprintf("files validated: %d\n", nrow(out)))
cat(sprintf("  ok:   %d\n", sum(out$ok)))
cat(sprintf("  fail: %d\n", sum(!out$ok)))
if (sum(!out$ok) > 0) {
  cat("\n=== top 5 failures ===\n")
  print(head(out |> filter(!ok) |> select(file, n_failed, first_error), 5))
}
cat(sprintf("\nwrote: %s\n", out_path))
