#!/usr/bin/env Rscript
# Fix floating-point monotonicity violations in the 2 USC-SI_kJalpha files.
#
# Background: cluster validation (job 59079072) flagged 2 files for
# non-monotonic quantile values. On inspection both violations are 1-ULP
# floating-point noise (|delta| < 1e-11) on what are effectively constant
# quantile runs -- NOT real crossings of the team's submitted values.
#
# Fix policy: for each non-monotonic group, snap each offending value
# forward to the previous quantile's value (`v[i] = v[i-1]`) when
# `|v[i-1] - v[i]| < TOL`. This preserves the team's predictions to
# ~12 sig figs (the printed precision they would have authored) and
# alters at most 1 value per group.
#
# If any violation has |delta| >= TOL we ABORT for that file -- that
# would indicate a real crossing requiring escalation, not a noise clamp.
#
# Outputs:
#   src/logs/noise_fix_log.csv -- one row per snapped value:
#     file, group_key, q_level, old_value, new_value, abs_delta

suppressPackageStartupMessages({
  library(here); library(arrow); library(dplyr); library(readr); library(tibble)
})

repo_root <- here::here()
mo_root   <- file.path(repo_root, "model-output")
log_dir   <- file.path(repo_root, "src", "logs")
dir.create(log_dir, showWarnings = FALSE, recursive = TRUE)

TOL <- 1e-9
files <- c(
  "USC-SI_kJalpha/2022-01-09-USC-SI_kJalpha.parquet",
  "USC-SI_kJalpha/2022-03-27-USC-SI_kJalpha.parquet"
)

fix_one <- function(rel_path) {
  full_path <- file.path(mo_root, rel_path)
  df <- as.data.frame(read_parquet(full_path))
  date_col <- if ("reference_date" %in% names(df)) "reference_date" else "forecast_date"
  gkeys    <- c("target", date_col, "location", "horizon")
  orig_cols <- names(df)

  is_q  <- df$output_type == "quantile"
  q     <- df[is_q, , drop = FALSE]
  non_q <- df[!is_q, , drop = FALSE]

  q$q_level <- suppressWarnings(as.numeric(q$output_type_id))
  # sort by group keys, then by q_level
  ord_args <- c(lapply(gkeys, function(k) q[[k]]), list(q$q_level))
  q <- q[do.call(order, ord_args), , drop = FALSE]

  grp_id <- do.call(paste, c(q[gkeys], sep = "|"))
  changes <- list()
  for (gid in unique(grp_id)) {
    idx <- which(grp_id == gid)
    if (length(idx) < 2) next
    vals <- q$value[idx]
    levs <- q$q_level[idx]
    for (j in 2:length(vals)) {
      d <- vals[j] - vals[j - 1]
      if (d < 0) {
        absd <- abs(d)
        if (absd >= TOL) {
          stop(sprintf(
            "Real crossing in %s @ group [%s] level %g: %.15g -> %.15g (delta=%.3e); refusing to snap.",
            rel_path, gid, levs[j], vals[j - 1], vals[j], d))
        }
        old <- vals[j]
        vals[j] <- vals[j - 1]
        changes[[length(changes) + 1]] <- tibble(
          file      = rel_path,
          group_key = gid,
          q_level   = levs[j],
          old_value = old,
          new_value = vals[j],
          abs_delta = absd
        )
      }
    }
    q$value[idx] <- vals
  }

  # Drop the helper column and recombine. Row order isn't required by hubValidations.
  q$q_level <- NULL
  out <- rbind(non_q, q[, orig_cols, drop = FALSE])
  write_parquet(out, full_path)

  if (length(changes) > 0) bind_rows(changes) else tibble()
}

all_changes <- list()
for (rp in files) {
  cat(sprintf("fixing %s\n", rp))
  ch <- fix_one(rp)
  cat(sprintf("  %d value(s) snapped\n", nrow(ch)))
  all_changes[[rp]] <- ch
}

log_path <- file.path(log_dir, "noise_fix_log.csv")
write_csv(bind_rows(all_changes), log_path)
cat(sprintf("\nwrote: %s\n", log_path))
