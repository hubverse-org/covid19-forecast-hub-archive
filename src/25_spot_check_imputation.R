#!/usr/bin/env Rscript
# Systematic spot-check of distfromq quantile imputation across all affected models.
#
# Selection strategy (driven entirely by distfromq_fill_log.csv):
#   1. Keep only files where n_groups_filled > 0 (actual imputation occurred,
#      not just group drops).
#   2. For each team-model, pick up to FILES_PER_MODEL files, preferring those
#      with the most filled groups (most to verify).
#   3. For each selected file, find the groups that were filled (present in
#      "after" but not "before"), sample up to GROUPS_PER_FILE of them, and
#      plot before vs. after side-by-side.
#
# Output: src/spot-check-plots/<team>/<file>_<group>.png
#         (directory is gitignored — plots are NOT committed to the repo)
#
# Usage: Rscript src/25_spot_check_imputation.R
#        Rscript src/25_spot_check_imputation.R --files-per-model 1 --groups-per-file 5

suppressPackageStartupMessages({
  library(here); library(arrow); library(dplyr); library(readr)
  library(ggplot2); library(patchwork)
})

# ── config ────────────────────────────────────────────────────────────────────
FILES_PER_MODEL  <- 2L   # max files to plot per team-model
GROUPS_PER_FILE  <- 10L  # max groups (locations/horizons) to plot per file
BEFORE_BRANCH    <- "ngr/add-data"
SEED             <- 42L  # for reproducible group sampling

args <- commandArgs(trailingOnly = TRUE)
if ("--files-per-model" %in% args)
  FILES_PER_MODEL <- as.integer(args[which(args == "--files-per-model") + 1])
if ("--groups-per-file" %in% args)
  GROUPS_PER_FILE <- as.integer(args[which(args == "--groups-per-file") + 1])

set.seed(SEED)

# ── paths ─────────────────────────────────────────────────────────────────────
repo_root <- here::here()
log_path  <- file.path(repo_root, "src", "logs", "distfromq_fill_log.csv")
mo_root   <- file.path(repo_root, "model-output")
out_root  <- file.path(repo_root, "src", "spot-check-plots")
dir.create(out_root, recursive = TRUE, showWarnings = FALSE)

# ── helpers ───────────────────────────────────────────────────────────────────
read_before <- function(rel_path) {
  tmp <- tempfile(fileext = ".parquet")
  cmd <- sprintf("git show %s:model-output/%s > %s", BEFORE_BRANCH, rel_path, tmp)
  rc  <- system(cmd, ignore.stderr = TRUE)
  if (rc != 0) stop("git show failed for ", rel_path)
  df <- as.data.frame(read_parquet(tmp))
  file.remove(tmp)
  df
}

read_after <- function(rel_path) {
  as.data.frame(read_parquet(file.path(mo_root, rel_path)))
}

date_col <- function(df) {
  if ("reference_date" %in% names(df)) "reference_date" else "forecast_date"
}

gkeys <- function(df) c("target", date_col(df), "location", "horizon")

group_id <- function(df) {
  do.call(paste, c(df[gkeys(df)], sep = "|"))
}

# Quantile levels present in "after" but not in "before" for the same group.
find_filled_groups <- function(before, after) {
  b_q <- before[before$output_type == "quantile", ]
  a_q <- after[after$output_type  == "quantile", ]
  gk  <- gkeys(before)

  b_q$grp <- group_id(b_q)
  a_q$grp <- group_id(a_q)

  b_counts <- b_q |> count(grp, name = "n_before")
  a_counts <- a_q |> count(grp, name = "n_after")

  merged <- inner_join(b_counts, a_counts, by = "grp") |>
    filter(n_after > n_before)

  merged$grp
}

make_group_plot <- function(before, after, grp_id_str, rel_path) {
  gk <- gkeys(before)
  b_q <- before[before$output_type == "quantile" & group_id(before) == grp_id_str, ]
  a_q <- after[after$output_type  == "quantile" & group_id(after)  == grp_id_str, ]

  if (nrow(b_q) == 0 || nrow(a_q) == 0) return(NULL)

  b_q$q <- suppressWarnings(as.numeric(b_q$output_type_id))
  a_q$q <- suppressWarnings(as.numeric(a_q$output_type_id))
  b_q <- b_q[!is.na(b_q$q), ]
  a_q <- a_q[!is.na(a_q$q), ]
  a_q$imputed <- !a_q$q %in% b_q$q

  meta  <- b_q[1, gk]
  label <- paste(unlist(meta), collapse = " | ")
  n_b   <- nrow(b_q)
  n_a   <- nrow(a_q)

  ylim <- range(c(b_q$value, a_q$value), na.rm = TRUE)
  pad  <- diff(ylim) * 0.05
  if (pad == 0) pad <- 1
  ylim <- ylim + c(-pad, pad)

  p_before <- ggplot(b_q, aes(q, value)) +
    geom_line(color = "grey60") +
    geom_point(size = 2.5, color = "#1f4e79") +
    coord_cartesian(ylim = ylim) +
    labs(title = sprintf("before (%d levels)", n_b),
         x = "quantile level", y = "value") +
    theme_minimal(base_size = 10)

  p_after <- ggplot(a_q, aes(q, value)) +
    geom_line(color = "grey60") +
    geom_point(aes(color = imputed, shape = imputed), size = 2.5) +
    scale_color_manual(values = c(`FALSE` = "#1f4e79", `TRUE` = "#c0392b"),
                       labels = c("submitted", "imputed")) +
    scale_shape_manual(values = c(`FALSE` = 16, `TRUE` = 1),
                       labels = c("submitted", "imputed")) +
    coord_cartesian(ylim = ylim) +
    labs(title = sprintf("after (%d levels, %d imputed)", n_a, sum(a_q$imputed)),
         x = "quantile level", y = NULL, color = NULL, shape = NULL) +
    theme_minimal(base_size = 10) +
    theme(legend.position = "bottom")

  (p_before | p_after) +
    plot_annotation(
      title    = basename(tools::file_path_sans_ext(rel_path)),
      subtitle = label,
      theme    = theme(plot.title    = element_text(face = "bold", size = 11),
                       plot.subtitle = element_text(color = "grey30", size = 9))
    )
}

# ── select files ──────────────────────────────────────────────────────────────
log <- read_csv(log_path, show_col_types = FALSE) |>
  filter(n_groups_filled > 0) |>
  mutate(model = sub("/.*", "", file)) |>
  group_by(model) |>
  slice_max(order_by = n_groups_filled, n = FILES_PER_MODEL, with_ties = FALSE) |>
  ungroup()

cat(sprintf("models with imputed groups: %d\n", n_distinct(log$model)))
cat(sprintf("files selected:             %d\n", nrow(log)))
cat(sprintf("groups per file (max):      %d\n\n", GROUPS_PER_FILE))

# ── plot ──────────────────────────────────────────────────────────────────────
total_plots <- 0L

for (i in seq_len(nrow(log))) {
  row <- log[i, ]
  rp  <- row$file
  cat(sprintf("[%d/%d] %s  (filled groups: %d)\n",
              i, nrow(log), rp, row$n_groups_filled))

  before <- tryCatch(read_before(rp), error = function(e) {
    message("  ! git show failed: ", conditionMessage(e)); NULL
  })
  if (is.null(before)) next

  after  <- tryCatch(read_after(rp),  error = function(e) {
    message("  ! read_after failed: ", conditionMessage(e)); NULL
  })
  if (is.null(after)) next

  filled_grps <- tryCatch(find_filled_groups(before, after), error = function(e) {
    message("  ! find_filled_groups failed: ", conditionMessage(e)); character(0)
  })
  if (length(filled_grps) == 0) {
    message("  no filled groups detected — skipping"); next
  }

  # Sample up to GROUPS_PER_FILE
  sampled <- if (length(filled_grps) > GROUPS_PER_FILE) {
    sample(filled_grps, GROUPS_PER_FILE)
  } else {
    filled_grps
  }

  model_dir <- file.path(out_root, row$model)
  dir.create(model_dir, recursive = TRUE, showWarnings = FALSE)
  file_stem <- tools::file_path_sans_ext(basename(rp))

  for (j in seq_along(sampled)) {
    g   <- sampled[j]
    plt <- tryCatch(make_group_plot(before, after, g, rp), error = function(e) {
      message("  ! plot error for group ", g, ": ", conditionMessage(e)); NULL
    })
    if (is.null(plt)) next

    safe_g <- gsub("[^A-Za-z0-9_.-]", "_", g)
    out_path <- file.path(model_dir,
                          sprintf("%s__%s.png", file_stem, safe_g))
    ggsave(out_path, plt, width = 9, height = 4, dpi = 130)
    total_plots <- total_plots + 1L
  }
  cat(sprintf("  wrote %d plots to %s/\n", length(sampled), model_dir))
}

cat(sprintf("\ndone — %d plots written to %s\n", total_plots, out_root))
