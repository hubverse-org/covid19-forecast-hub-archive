# UMass Unity validation pipeline

Runs `hubValidations::validate_submission` over every parquet file under
`model-output/` in parallel as a Slurm array job.

## Files

- `prepare_unity.sh` — One-shot install of hubValidations + deps into
  `$R_LIBS_USER`. Run *once*, before the array job.
- `validate_chunk.R` — Worker script. Validates a round-robin slice of the
  full file list (slice = `(SLURM_ARRAY_TASK_ID, N_TASKS)`); writes one
  `chunk_NNNN.csv` per task with columns
  `file, ok, n_failed, elapsed_sec, first_error`.
- `submit_unity.sbatch` — Slurm submission script. Defaults to a 200-task
  array, 8 h walltime, 8 GB / task, partition `cpu`. Adjust as needed.
- `aggregate_logs.R` — After all chunks finish, collapse them into a
  single `validate_submissions_full.csv` and print a summary.

## Quick start

From the hub root on a Unity login node:

```bash
# 1. One-shot install (do this once per account; ~30–60 min compile time)
sbatch src/cluster/prepare_unity.sh
# wait for it to finish:
#   squeue -u "${USER}" -j <INSTALL_JOB_ID>
# verify:
#   tail src/logs/install-<INSTALL_JOB_ID>.out

# 2. Submit the validation array (logs land in src/logs/cluster_<JOB_ID>/)
sbatch src/cluster/submit_unity.sbatch

# Track progress
squeue -u "${USER}" -j <JOB_ID>
ls src/logs/cluster_<JOB_ID>/chunk_*.csv | wc -l   # 200 when complete

# Aggregate when done
Rscript src/cluster/aggregate_logs.R src/logs/cluster_<JOB_ID>
```

You can also chain them so the array runs automatically once install
finishes:

```bash
INSTALL_ID=$(sbatch --parsable src/cluster/prepare_unity.sh)
sbatch --dependency=afterok:${INSTALL_ID} src/cluster/submit_unity.sbatch
```

## Tuning

`validate_submission` runs at roughly **240 s/file** locally when
`target_end_date` is declared in `derived_task_ids` (the default in
`hub-config/tasks.json`). With ~8,800 files and the default 200-task
array, each task processes ~44 files and finishes in ~3 hours.

To change the array size, override `--array` on the command line:

```bash
sbatch --array=1-400 --time=02:00:00 src/cluster/submit_unity.sbatch
```

Per-file work is pure CPU, so `--cpus-per-task=1` is right; bumping it
buys nothing.

## R libraries

The first task of the array runs `install.packages(...)` into
`$R_LIBS_USER` (defaults to `~/R/library`) using the hubverse r-universe
mirror, so no manual setup is needed on a fresh account. Subsequent tasks
see the libraries immediately.

The module name in `submit_unity.sbatch` (`r/4.4.0`) is a guess; run
`module avail r` on Unity if loading fails and edit the script.

## Why a round-robin slice?

`inc hosp` parquet files are ~3–10× larger than `inc death` files because
of the daily horizon. A contiguous chunking scheme would dump all hosp
files of a team into a single task and that task would dominate wall
time. Round-robin (`seq(task_id, n, by = n_tasks)`) spreads big files
evenly, so all tasks finish within a tight band.
