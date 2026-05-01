#!/usr/bin/env Rscript
# Validate every model-metadata/*.yml against hub-config/model-metadata-schema.json
# using hubValidations. Emit per-file pass/fail rows to src/logs/.

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(here)
  library(hubValidations)
})

hub_path <- here::here()
md_dir   <- file.path(hub_path, "model-metadata")
log_dir  <- here::here("src", "logs")
if (!dir.exists(log_dir)) dir.create(log_dir, recursive = TRUE)

files <- list.files(md_dir, "\\.yml$", full.names = TRUE)
cat("model-metadata files to validate:", length(files), "\n")

validate_one <- function(f) {
  rel <- sub(paste0("^", hub_path, "/?"), "", f)
  res <- tryCatch(
    validate_model_metadata(hub_path = hub_path, file_path = basename(f)),
    error = function(e) e
  )
  if (inherits(res, "error")) {
    return(tibble::tibble(file = basename(f),
                          ok = FALSE,
                          message = conditionMessage(res)))
  }
  # validate_model_metadata returns a list of check_* objects
  failed <- vapply(res, function(x) inherits(x, "check_failure") ||
                                     inherits(x, "check_error"),
                   logical(1))
  if (any(failed)) {
    msgs <- vapply(res[failed], function(x) {
      tryCatch(format(x), error = function(e) "<unformattable>")
    }, character(1))
    return(tibble::tibble(file = basename(f),
                          ok = FALSE,
                          message = paste(msgs, collapse = "; ")))
  }
  tibble::tibble(file = basename(f), ok = TRUE, message = "ok")
}

results <- map_dfr(files, validate_one)
log_path <- file.path(log_dir, sprintf("validate_metadata_%s.csv", Sys.Date()))
readr::write_csv(results, log_path)

cat(sprintf("\nresult: %d ok, %d failed\n", sum(results$ok), sum(!results$ok)))
if (any(!results$ok)) {
  cat("\nfailures:\n")
  print(results |> filter(!ok), n = 50)
}
cat("log:", log_path, "\n")
