#!/usr/bin/env Rscript
# Fill in missing required quantile levels for the 188 cluster-failure
# files where output_type=='quantile' groups don't cover the hub's full
# 23-level required set.
#
# Algorithm (per file, per (target, forecast_date, location, horizon) group):
#   * if n_anchors >= 23 (all required levels present): leave group alone
#   * if  5 <= n_anchors < 23: fit distfromq::make_q_fn on the submitted
#       (p, v) pairs; query at the missing levels; APPEND those rows.
#   * if n_anchors < 5: DROP all rows for this group (eligible-group policy
#       agreed in the planning conversation -- preserves data quality at
#       the cost of fewer groups).
#
# Non-quantile rows (mean, median) are preserved untouched.
#
# Inputs:  the 188 incomplete files (restored locally by src/18)
# Outputs:
#   * 188 fixed parquet files (rewritten in place under model-output/)
#   * src/logs/distfromq_fill_log.csv -- one row per file:
#       file, n_groups_before, n_groups_after,
#       n_groups_unchanged, n_groups_filled, n_groups_dropped,
#       n_rows_before, n_rows_after, n_rows_added, n_rows_dropped,
#       min_anchors_used, status
#
# Required levels for this hub (from hub-config/tasks.json):
#   0.01, 0.025, 0.05, 0.10, ..., 0.95, 0.975, 0.99  (23 levels)

suppressPackageStartupMessages({
  library(here); library(arrow); library(dplyr); library(readr);
  library(jsonlite); library(distfromq)
})

MIN_ANCHORS <- 5

# Build target -> required-quantile-levels map from hub-config/tasks.json.
# Different targets have different required sets (e.g. inc case has 7 levels
# while inc death / cum death / inc hosp have 23). Imputing 23 levels for an
# inc case group makes it fail with "invalid values/value combinations".
build_target_required <- function(hub_config_path) {
  tasks <- jsonlite::read_json(hub_config_path, simplifyVector = FALSE)
  out <- list()
  for (rnd in tasks$rounds) {
    for (mt in rnd$model_tasks) {
      tgts   <- unlist(mt$task_ids$target$required)
      levels <- sort(as.numeric(unlist(mt$output_type$quantile$output_type_id$required)))
      if (length(tgts) == 0 || length(levels) == 0) next
      for (tg in tgts) {
        existing <- out[[tg]]
        out[[tg]] <- if (is.null(existing)) levels else sort(unique(c(existing, levels)))
      }
    }
  }
  out
}

repo_root <- here::here()
mo_root   <- file.path(repo_root, "model-output")
log_dir   <- file.path(repo_root, "src", "logs")

tracking <- read_csv(file.path(log_dir, "pr-submission-tracking.csv"),
                     show_col_types = FALSE)
target_files <- tracking |>
  filter(ok == "FALSE", grepl("Required task ID", first_error)) |>
  pull(file)
cat(sprintf("processing %d incomplete-quantile files\n", length(target_files)))

TARGET_REQUIRED <- build_target_required(file.path(repo_root, "hub-config", "tasks.json"))
cat("per-target required quantile-level counts:\n")
for (tg in names(TARGET_REQUIRED)) {
  cat(sprintf("  %-10s -> %d levels\n", tg, length(TARGET_REQUIRED[[tg]])))
}

fix_file <- function(rel_path) {
  full <- file.path(mo_root, rel_path)
  df <- as.data.frame(read_parquet(full))
  date_col <- if ("reference_date" %in% names(df)) "reference_date" else "forecast_date"
  gkeys <- c("target", date_col, "location", "horizon")
  cols  <- names(df)

  is_q  <- df$output_type == "quantile"
  q     <- df[is_q, , drop = FALSE]
  non_q <- df[!is_q, , drop = FALSE]

  n_rows_before <- nrow(df)
  n_groups_before <- nrow(unique(q[gkeys]))

  q$q_level <- suppressWarnings(as.numeric(q$output_type_id))
  q <- q[!is.na(q$q_level), , drop = FALSE]

  # Build group id; preserve a per-group "first row" so we can replicate fixed columns
  grp_id <- do.call(paste, c(q[gkeys], sep = "|"))
  unique_groups <- unique(grp_id)

  filled_rows   <- list()
  groups_drop   <- character()
  groups_filled <- 0L
  groups_unch   <- 0L
  min_anchors_used <- Inf

  for (gid in unique_groups) {
    idx <- which(grp_id == gid)
    g   <- q[idx, , drop = FALSE]
    tg  <- as.character(g$target[1])
    required <- TARGET_REQUIRED[[tg]]
    if (is.null(required)) {
      # Unknown target -- be safe: leave it untouched
      groups_unch <- groups_unch + 1L; next
    }
    ps  <- sort(unique(g$q_level))
    n   <- length(ps)
    if (all(required %in% ps)) {
      groups_unch <- groups_unch + 1L; next
    }
    if (n < MIN_ANCHORS) {
      groups_drop <- c(groups_drop, gid); next
    }
    missing <- setdiff(required, ps)
    if (length(missing) == 0L) { groups_unch <- groups_unch + 1L; next }

    # Anchor (p, v) -- collapse duplicates by mean (rare but happens)
    anchor <- g |>
      group_by(q_level) |>
      summarise(value = mean(value), .groups = "drop") |>
      arrange(q_level)

    q_fn <- tryCatch(make_q_fn(ps = anchor$q_level, qs = anchor$value),
                     error = function(e) NULL)
    if (is.null(q_fn)) { groups_drop <- c(groups_drop, gid); next }
    new_vals <- tryCatch(q_fn(missing), error = function(e) NULL)
    if (is.null(new_vals) || any(!is.finite(new_vals))) {
      groups_drop <- c(groups_drop, gid); next
    }

    # Isotonic clamp: each imputed value must lie within the team's anchor
    # bracket. For an imputed level `m`:
    #   lower = max(anchor.value where anchor.p <  m,  hub_min)
    #   upper = min(anchor.value where anchor.p >  m,  +Inf)
    # `hub_min = 0` (all targets in this hub require value >= 0).
    #
    # This subsumes (a) the hub-min clamp for left-tail extrapolation that
    # goes negative, and (b) sub-ULP overshoot when two anchors are equal
    # (e.g. anchors both = 0; distfromq spline returns ~8e-15 between them,
    # which then fails monotonicity vs. the next anchor = 0).
    HUB_MIN <- 0
    ax <- anchor$q_level; av <- anchor$value
    for (k in seq_along(missing)) {
      m <- missing[k]
      below <- ax < m
      above <- ax > m
      lo <- if (any(below)) max(HUB_MIN, max(av[below])) else HUB_MIN
      hi <- if (any(above)) min(av[above])               else Inf
      new_vals[k] <- min(max(new_vals[k], lo), hi)
    }

    # Sanity-check post-clamp monotonicity (cheap; defensive only).
    combined <- rbind(
      tibble(p = anchor$q_level, v = anchor$value),
      tibble(p = missing,        v = new_vals)
    ) |> arrange(p)
    if (any(diff(combined$v) < 0)) {
      groups_drop <- c(groups_drop, gid); next
    }

    # Build the new rows, copying the constant columns from g's first row
    template <- g[1, , drop = FALSE]
    new_block <- template[rep(1L, length(missing)), , drop = FALSE]
    new_block$output_type    <- "quantile"
    new_block$output_type_id <- missing
    new_block$value          <- new_vals
    new_block$q_level        <- missing

    filled_rows[[gid]] <- new_block
    groups_filled <- groups_filled + 1L
    min_anchors_used <- min(min_anchors_used, n)
  }

  # Remove dropped groups from q
  keep <- !(grp_id %in% groups_drop)
  q_keep <- q[keep, , drop = FALSE]

  # Append filled rows
  if (length(filled_rows) > 0) {
    q_final <- bind_rows(q_keep, bind_rows(filled_rows))
  } else {
    q_final <- q_keep
  }
  q_final$q_level <- NULL

  out <- bind_rows(non_q, q_final[, cols, drop = FALSE])
  write_parquet(out, full)

  tibble(
    file = rel_path,
    n_groups_before    = n_groups_before,
    n_groups_after     = n_groups_before - length(groups_drop),
    n_groups_unchanged = groups_unch,
    n_groups_filled    = groups_filled,
    n_groups_dropped   = length(groups_drop),
    n_rows_before      = n_rows_before,
    n_rows_after       = nrow(out),
    n_rows_added       = if (length(filled_rows) > 0) sum(vapply(filled_rows, nrow, integer(1))) else 0L,
    n_rows_dropped     = sum(grp_id %in% groups_drop),
    min_anchors_used   = if (is.finite(min_anchors_used)) min_anchors_used else NA_integer_,
    status             = "ok"
  )
}

logs <- list()
for (i in seq_along(target_files)) {
  rp <- target_files[i]
  logs[[i]] <- tryCatch(
    fix_file(rp),
    error = function(e) {
      tibble(file = rp, n_groups_before = NA_integer_, n_groups_after = NA_integer_,
             n_groups_unchanged = NA_integer_, n_groups_filled = NA_integer_,
             n_groups_dropped = NA_integer_, n_rows_before = NA_integer_,
             n_rows_after = NA_integer_, n_rows_added = NA_integer_,
             n_rows_dropped = NA_integer_, min_anchors_used = NA_integer_,
             status = conditionMessage(e))
    })
  if (i %% 10 == 0) cat(sprintf("  processed %d/%d\n", i, length(target_files)))
}

log_df <- bind_rows(logs)
write_csv(log_df, file.path(log_dir, "distfromq_fill_log.csv"))

ok <- log_df$status == "ok"
cat(sprintf("\n=== summary ===\n"))
cat(sprintf("files processed:    %d\n", nrow(log_df)))
cat(sprintf("files ok:           %d\n", sum(ok)))
cat(sprintf("files with error:   %d\n", sum(!ok)))
cat(sprintf("total rows added:   %d\n", sum(log_df$n_rows_added,   na.rm = TRUE)))
cat(sprintf("total rows dropped: %d\n", sum(log_df$n_rows_dropped, na.rm = TRUE)))
cat(sprintf("groups unchanged:   %d\n", sum(log_df$n_groups_unchanged, na.rm = TRUE)))
cat(sprintf("groups filled:      %d\n", sum(log_df$n_groups_filled,    na.rm = TRUE)))
cat(sprintf("groups dropped:     %d\n", sum(log_df$n_groups_dropped,   na.rm = TRUE)))
cat(sprintf("\nwrote: %s\n", file.path(log_dir, "distfromq_fill_log.csv")))
