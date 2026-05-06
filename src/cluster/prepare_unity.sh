#!/bin/bash
#
# One-shot install of hubValidations + dependencies into the user's
# personal R library on UMass Unity. Run this once, BEFORE submitting
# the array job (submit_unity.sbatch).
#
# Run as a Slurm job (not on the login node):
#
#   sbatch src/cluster/prepare_unity.sh
#
# When this finishes successfully, the array job can assume the
# library is ready.

#SBATCH --job-name=cfh-install
#SBATCH --output=src/logs/install-%j.out
#SBATCH --error=src/logs/install-%j.err
#SBATCH --partition=cpu
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=02:00:00

set -euo pipefail

mkdir -p src/logs

module load r/4.4.0 || module load r

export R_LIBS_USER="${R_LIBS_USER:-${HOME}/R/library}"
mkdir -p "${R_LIBS_USER}"

# Compile in parallel; cuts the dep-install time substantially.
export MAKEFLAGS="-j${SLURM_CPUS_PER_TASK:-4}"

Rscript -e '
pkgs <- c("hubValidations", "arrow", "dplyr", "readr", "tibble")
missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) == 0L) {
  message("All packages already installed.")
} else {
  message("Installing: ", paste(missing, collapse = ", "))
  install.packages(missing,
    repos = c("https://hubverse-org.r-universe.dev",
              "https://cloud.r-project.org"),
    Ncpus = as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", "4")))
}
# Final sanity: every package must load.
for (p in pkgs) {
  loadNamespace(p)
  message("OK: ", p, " ", as.character(packageVersion(p)))
}
'
echo "install OK at $(date)"
