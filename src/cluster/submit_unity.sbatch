#!/bin/bash
#
# Slurm submission script for the UMass Unity cluster: validates every
# parquet file under model-output/ via hubValidations::validate_submission.
#
# Usage (from the hub root):
#   sbatch src/cluster/submit_unity.sbatch
# or with overrides:
#   sbatch --array=1-200 --time=04:00:00 --mem=8G src/cluster/submit_unity.sbatch
#
# After all array tasks finish, aggregate the per-chunk logs:
#   Rscript src/cluster/aggregate_logs.R src/logs/cluster_<JOB_ID>
#
# Sizing rationale:
#   * ~8,800 files. validate_submission averaged ~240s/file in local tests
#     when target_end_date is declared as a derived task_id.
#   * 200 array tasks x 8800/200 = 44 files/task -> ~3 hours/task.
#     Walltime 8h gives headroom; mem 8G covers the largest hosp files.
#   * Round-robin chunk assignment in validate_chunk.R spreads big files
#     across tasks so no single task is the long pole.

#SBATCH --job-name=cfh-validate
#SBATCH --output=src/logs/cluster_%A/slurm-%A_%a.out
#SBATCH --error=src/logs/cluster_%A/slurm-%A_%a.err
#SBATCH --array=1-200
#SBATCH --partition=cpu
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --time=08:00:00

set -euo pipefail

# Make per-job log directory before R starts writing into it.
LOG_DIR="src/logs/cluster_${SLURM_ARRAY_JOB_ID}"
mkdir -p "${LOG_DIR}"

# R environment. Adjust the module name to whatever Unity currently
# offers (`module avail r` to list).
module load r/4.4.0 || module load r

# R library must already exist — install via prepare_unity.sh first.
export R_LIBS_USER="${R_LIBS_USER:-${HOME}/R/library}"
if ! Rscript -e 'quit(status = !requireNamespace("hubValidations", quietly = TRUE))'; then
  echo "ERROR: hubValidations not installed in ${R_LIBS_USER}." >&2
  echo "Run: sbatch src/cluster/prepare_unity.sh" >&2
  exit 2
fi

export HUB_PATH="${SLURM_SUBMIT_DIR}"
export LOG_DIR
export N_TASKS="${SLURM_ARRAY_TASK_COUNT}"

cd "${HUB_PATH}"
Rscript src/cluster/validate_chunk.R
