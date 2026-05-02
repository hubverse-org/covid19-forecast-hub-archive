#!/usr/bin/env Rscript
# Strip the trailing "_+" from the UChicago model_abbrs so the parquet
# filenames are parseable by hubValidations:::parse_file_name (which
# rejects "+"). Affects:
#   model-output/UChicago-CovidIL_10_+/  -> model-output/UChicago-CovidIL_10/
#   model-output/UChicago-CovidIL_30_+/  -> model-output/UChicago-CovidIL_30/
#   the inner parquet filename loses "_+" too
#   model-metadata/UChicago-CovidIL_10_+.yml -> .../UChicago-CovidIL_10.yml
#       (and the inside model_abbr field loses "_+" as well)

suppressPackageStartupMessages({
  library(here); library(yaml); library(fs)
})

mo_root <- here::here("model-output")
md_root <- here::here("model-metadata")

old_new <- list(
  list(old = "UChicago-CovidIL_10_+", new = "UChicago-CovidIL_10"),
  list(old = "UChicago-CovidIL_30_+", new = "UChicago-CovidIL_30")
)

for (m in old_new) {
  old_dir <- file.path(mo_root, m$old)
  new_dir <- file.path(mo_root, m$new)

  if (dir.exists(old_dir)) {
    cat(sprintf("renaming dir: %s -> %s\n", m$old, m$new))
    file.rename(old_dir, new_dir)
    # Rename parquet files inside (filenames embed the old team-model)
    pq <- list.files(new_dir, "\\.parquet$", full.names = TRUE)
    for (f in pq) {
      bn <- basename(f)
      new_bn <- sub(m$old, m$new, bn, fixed = TRUE)
      if (new_bn != bn) {
        cat(sprintf("  renaming file: %s -> %s\n", bn, new_bn))
        file.rename(f, file.path(dirname(f), new_bn))
      }
    }
  } else {
    cat("WARN: old dir not found:", old_dir, "\n")
  }

  # Metadata YAML
  old_yml <- file.path(md_root, paste0(m$old, ".yml"))
  new_yml <- file.path(md_root, paste0(m$new, ".yml"))
  if (file.exists(old_yml)) {
    cat(sprintf("renaming metadata: %s.yml -> %s.yml\n", m$old, m$new))
    md <- yaml::read_yaml(old_yml)
    if (!is.null(md$model_abbr)) {
      md$model_abbr <- sub("_\\+$", "", md$model_abbr)
    }
    yaml::write_yaml(md, new_yml)
    file.remove(old_yml)
  } else {
    cat("WARN: old metadata yml not found:", old_yml, "\n")
  }
}

cat("\ndone\n")
