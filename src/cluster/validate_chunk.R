#!/usr/bin/env Rscript
# Validate a chunk of model-output parquet files via the full
# hubValidations::validate_submission pipeline. Designed to run as one
# task in a Slurm job array.
#
# Inputs (env vars):
#   SLURM_ARRAY_TASK_ID  - 1-based index of this task (Slurm sets it)
#   N_TASKS              - total tasks in the array (we read it back to
#                           reconstruct the chunk; defaults to
#                           SLURM_ARRAY_TASK_COUNT if unset)
#   HUB_PATH             - path to the hub root (defaults to current dir)
#   LOG_DIR              - where to write per-task CSV logs
#                           (defaults to <HUB_PATH>/src/logs/cluster_<jobid>)
#
# Output:
#   <LOG_DIR>/chunk_<task_id>.csv with one row per file:
#     file, ok, n_failed, first_error
#
# Aggregate across all tasks with `cat <LOG_DIR>/chunk_*.csv` (after
# stripping duplicate headers) or via src/cluster/aggregate_logs.R.

suppressPackageStartupMessages({
  library(hubValidations)
  library(tibble)
  library(readr)
})

# --- arg / env handling ---------------------------------------------------
hub_path <- Sys.getenv("HUB_PATH", unset = getwd())
task_id  <- as.integer(Sys.getenv("SLURM_ARRAY_TASK_ID", unset = "1"))
n_tasks  <- as.integer(Sys.getenv(
  "N_TASKS",
  unset = Sys.getenv("SLURM_ARRAY_TASK_COUNT", unset = "1")
))
log_dir  <- Sys.getenv(
  "LOG_DIR",
  unset = file.path(hub_path, "src", "logs",
                    paste0("cluster_", Sys.getenv("SLURM_JOB_ID", unset = "local")))
)
if (!dir.exists(log_dir)) dir.create(log_dir, recursive = TRUE)

stopifnot(task_id >= 1L, n_tasks >= 1L, task_id <= n_tasks)

# --- enumerate files and slice the chunk ----------------------------------
mo_root <- file.path(hub_path, "model-output")
files <- list.files(mo_root, pattern = "\\.parquet$",
                    recursive = TRUE, full.names = TRUE)
files <- sort(files)
rel_paths <- sub(paste0("^", mo_root, "/?"), "", files)

# Round-robin assignment so that long-tail teams (e.g. inc-hosp parquet
# files, which are larger and slower) get spread across tasks rather than
# piling up in the last few.
my_idx <- seq.int(task_id, length(rel_paths), by = n_tasks)
my_files <- rel_paths[my_idx]

cat(sprintf("[task %d/%d] hub=%s files=%d (of %d total)\n",
            task_id, n_tasks, hub_path, length(my_files), length(rel_paths)))
flush.console()

# --- validate each file ---------------------------------------------------
validate_one <- function(rp) {
  t0 <- Sys.time()
  v <- tryCatch(
    hubValidations::validate_submission(
      hub_path = hub_path,
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

  ok <- tryCatch({
    hubValidations::check_for_errors(v, verbose = FALSE); TRUE
  }, error = function(e) FALSE)

  if (ok) {
    return(tibble(file = rp, ok = TRUE, n_failed = 0L,
                  elapsed_sec = elapsed, first_error = NA_character_))
  }

  # Pull the first failing check name & message out of the collection /
  # hub_validations object for easy triage.
  flat <- if (inherits(v, "hub_validations_collection")) {
    unlist(v, recursive = FALSE, use.names = FALSE)
  } else {
    v
  }
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

`%||%` <- function(a, b) if (is.null(a)) b else a

results <- vector("list", length(my_files))
for (i in seq_along(my_files)) {
  results[[i]] <- validate_one(my_files[i])
  if (i %% 10 == 0 || i == length(my_files)) {
    cat(sprintf("  [%d/%d] last=%s ok=%s elapsed=%.1fs\n",
                i, length(my_files), my_files[i],
                results[[i]]$ok, results[[i]]$elapsed_sec))
    flush.console()
  }
}

out <- do.call(rbind, results)
out_path <- file.path(log_dir, sprintf("chunk_%04d.csv", task_id))
write_csv(out, out_path)
cat(sprintf("[task %d] wrote %s (%d rows; %d ok / %d fail)\n",
            task_id, out_path, nrow(out), sum(out$ok), sum(!out$ok)))
