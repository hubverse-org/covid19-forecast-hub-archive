#!/usr/bin/env Rscript
# Run hub-level config validation. Should pass once Phase 1 (configs) is
# complete and before any model-output / model-metadata content is added.

suppressPackageStartupMessages({
  library(hubValidations)
  library(hubAdmin)
  library(here)
})

options(hubAdmin.schema_version = "v6.0.0")

hub_path <- here::here()
cat("hub_path:", hub_path, "\n\n")

cat("--- hubValidations::check_config_hub_valid ---\n")
v_hub <- check_config_hub_valid(hub_path = hub_path)
print(v_hub)

cat("\n--- hubAdmin::validate_config (tasks) ---\n")
print(validate_config(hub_path = hub_path, config = "tasks"))

cat("\n--- hubAdmin::validate_config (admin) ---\n")
print(validate_config(hub_path = hub_path, config = "admin"))

cat("\n--- hubAdmin::validate_model_metadata_schema ---\n")
print(validate_model_metadata_schema(hub_path = hub_path))
