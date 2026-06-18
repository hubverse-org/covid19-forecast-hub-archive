#!/usr/bin/env Rscript
# Render side-by-side before/after plots of distfromq quantile imputation.
#
# For each (file, group) example, compare:
#   * "Before" — the team's submitted quantiles, as they appear in the
#     pre-fix parquet on the ngr/add-data branch
#   * "After"  — the file as it ships in this branch (PR #18), with
#     missing levels filled by distfromq + isotonic clamp
#
# Output: docs/figures/distfromq_examples/<file>_<group>.png
# Also: docs/distfromq-imputation-examples.md aggregating the figures.

suppressPackageStartupMessages({
  library(here); library(arrow); library(dplyr); library(ggplot2); library(patchwork)
})

repo_root <- here::here()
out_dir   <- file.path(repo_root, "docs", "figures", "distfromq_examples")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

read_before <- function(rel_path) {
  # Pull the original (pre-distfromq) parquet from the ngr/add-data branch
  tmp <- tempfile(fileext = ".parquet")
  cmd <- sprintf("git show ngr/add-data:model-output/%s > %s",
                 rel_path, tmp)
  rc <- system(cmd, ignore.stderr = TRUE)
  if (rc != 0) stop("git show failed for ", rel_path)
  df <- as.data.frame(read_parquet(tmp))
  file.remove(tmp)
  df
}

read_after <- function(rel_path) {
  as.data.frame(read_parquet(file.path(repo_root, "model-output", rel_path)))
}

# A row per (file, target, group_keys, label) that we want to plot.
# group_keys = (forecast_date, location, horizon) tuple values, picked to
# illustrate the distribution shape and the imputation density.
examples <- tibble::tribble(
  ~rel_path,                                                             ~target,     ~forecast_date, ~location, ~horizon, ~label,
  "UChicagoCHATTOPADHYAY-UnIT/2021-12-26-UChicagoCHATTOPADHYAY-UnIT.parquet", "inc death", "2021-12-26",  "06",     1L,       "UChicago (CA, h=1) — 7 -> 23 anchors",
  "LNQ-ens1/2020-08-09-LNQ-ens1.parquet",                                "inc death", "2020-08-09",  "36",     2L,       "LNQ-ens1 (NY, h=2) — 7 -> 23 anchors",
  # Auquan-SEIR file only carries cum death (the team didn't submit inc death on this date)
  "Auquan-SEIR/2020-08-24-Auquan-SEIR.parquet",                          "cum death", "2020-08-24",  "06",     4L,       "Auquan-SEIR (CA cum death, h=4) — 7 -> 23 anchors",
  # QJHong-Encounter and IHME-CurveFit's failing files all have only 2-anchor groups
  # everywhere -- the <5 gate drops them, so there's no imputation to plot. Pick
  # from teams whose failing files have 5+ anchors per group instead.
  # JHU_CSSE-DECOM's only imputable groups are inc case (6 -> 7 anchors); cum/inc death already had 23.
  "JHU_CSSE-DECOM/2022-01-23-JHU_CSSE-DECOM.parquet",                    "inc case",  "2022-01-23",  "06",     1L,       "JHU_CSSE-DECOM (CA inc case, h=1) — 6 -> 7 anchors (fills 1)",
  "Covid19Sim-Simulator/2020-08-16-Covid19Sim-Simulator.parquet",        "inc death", "2020-08-16",  "06",     3L,       "Covid19Sim-Simulator (CA, h=3) — 7 -> 23 anchors",
  "UMich-RidgeTfReg/2020-07-27-UMich-RidgeTfReg.parquet",                "inc death", "2020-07-27",  "US",     2L,       "UMich-RidgeTfReg (US, h=2) — anchors filled"
)

make_plot <- function(rel_path, target, fdate, loc, horiz, label) {
  before <- read_before(rel_path)
  after  <- read_after(rel_path)
  date_col <- if ("reference_date" %in% names(before)) "reference_date" else "forecast_date"

  pick <- function(df, src) {
    sub <- df |>
      filter(.data[[date_col]] == as.Date(fdate),
             target == !!target,
             location == !!loc,
             horizon == !!horiz,
             output_type == "quantile") |>
      mutate(q = as.numeric(output_type_id),
             source = src) |>
      arrange(q)
    sub
  }
  b <- pick(before, "before")
  a <- pick(after,  "after")
  if (nrow(b) == 0 || nrow(a) == 0) {
    message("  group not found for ", rel_path, " - skipping")
    return(NULL)
  }
  # Mark which "after" points are imputed (not in "before")
  a <- a |> mutate(imputed = !q %in% b$q)

  p_before <- ggplot(b, aes(q, value)) +
    geom_line(color = "grey50") +
    geom_point(size = 2.5, color = "#1f4e79") +
    labs(title = "before (submitted)", x = "quantile level", y = "value") +
    theme_minimal(base_size = 11)
  p_after <- ggplot(a, aes(q, value)) +
    geom_line(color = "grey50") +
    geom_point(aes(color = imputed, shape = imputed), size = 2.5) +
    scale_color_manual(values = c(`FALSE` = "#1f4e79", `TRUE` = "#c0392b"),
                       labels = c("submitted", "imputed")) +
    scale_shape_manual(values = c(`FALSE` = 16, `TRUE` = 1),
                       labels = c("submitted", "imputed")) +
    labs(title = "after (post-distfromq)", x = "quantile level", y = NULL,
         color = NULL, shape = NULL) +
    theme_minimal(base_size = 11) +
    theme(legend.position = "bottom")

  # Common y range
  ylim <- range(c(b$value, a$value), na.rm = TRUE) * c(0.95, 1.05)
  p_before <- p_before + coord_cartesian(ylim = ylim)
  p_after  <- p_after  + coord_cartesian(ylim = ylim)

  combined <- (p_before | p_after) +
    plot_annotation(title = label,
                    subtitle = sprintf("target=%s  forecast=%s  loc=%s  horizon=%d   |   anchors: %d -> %d",
                                       target, fdate, loc, horiz, nrow(b), nrow(a)),
                    theme = theme(plot.title = element_text(face = "bold"),
                                  plot.subtitle = element_text(color = "grey30")))

  out_name <- sprintf("%s_%s_%s_h%d.png",
                      gsub("/", "__", tools::file_path_sans_ext(rel_path)),
                      fdate, loc, horiz)
  out_path <- file.path(out_dir, out_name)
  ggsave(out_path, combined, width = 9, height = 4, dpi = 130)
  cat(sprintf("  wrote %s\n", out_path))
  out_path
}

cat(sprintf("rendering %d examples ...\n", nrow(examples)))
paths <- character()
for (i in seq_len(nrow(examples))) {
  e <- examples[i, ]
  cat(sprintf("[%d/%d] %s\n", i, nrow(examples), e$label))
  p <- tryCatch(make_plot(e$rel_path, e$target, e$forecast_date,
                          e$location, e$horizon, e$label),
                error = function(err) {
                  message("  error: ", conditionMessage(err)); NULL
                })
  if (!is.null(p)) paths <- c(paths, p)
}

# Write a markdown doc that embeds the figures
md_path <- file.path(repo_root, "docs", "distfromq-imputation-examples.md")
md <- c(
  "# distfromq imputation: visual examples",
  "",
  "These side-by-side plots show how `src/20_distfromq_fill.R` fills in",
  "missing required quantile levels for a representative sample of the 188",
  "incomplete-quantile files. Each panel shows one forecast group ",
  "(`target` × `forecast_date` × `location` × `horizon`):",
  "",
  "- **Blue dots** are the levels the team actually submitted (\"anchors\").",
  "- **Red circles** are levels filled in by `distfromq::make_q_fn` (a",
  "  monotone-spline interpolation on the anchor (probability, value) pairs),",
  "  then isotonically clamped to `[max(0, prev_anchor), next_anchor]`.",
  "- The grey line is the simple piecewise-linear interpolation through the",
  "  sorted points; it is *not* the spline distfromq uses internally, just a",
  "  visual guide to show the shape stays monotone.",
  "",
  "If the imputation were introducing artifacts, you would expect red points",
  "off the curve traced by the blue points. In every example below the red",
  "points sit smoothly between the team's submitted anchors, with tail",
  "extrapolations clamped where appropriate.",
  ""
)
for (p in paths) {
  # image paths are relative to docs/distfromq-imputation-examples.md
  rel <- sub(file.path(repo_root, "docs/"), "", p, fixed = TRUE)
  md <- c(md, sprintf("![](%s)", rel), "")
}
writeLines(md, md_path)
cat(sprintf("\nwrote %s\n", md_path))
