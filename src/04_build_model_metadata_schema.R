#!/usr/bin/env Rscript
# Build hub-config/model-metadata-schema.json — the JSON Schema that each
# model-metadata/<team>-<model>.yml file is validated against.
#
# Hubverse uses JSON Schema draft 2020-12. The legacy covid19-forecast-hub
# schema (see ../covid19-forecast-hub/schema.yml) had a flatter layout with
# fields like `model_abbr` formatted as "TEAM-MODEL" and `methods` at the
# top level. We adopt the modern hubverse layout here:
#   - team_abbr / model_abbr split (derived from the legacy model_abbr)
#   - methods nested under model_details
#   - team_model_designation kept as a top-level enum field for fidelity
#
# The migration script (05_convert_metadata.R) is responsible for mapping
# legacy fields to this schema.

suppressPackageStartupMessages({
  library(jsonlite)
  library(hubAdmin)
  library(here)
})

schema <- list(
  `$schema`   = "https://json-schema.org/draft/2020-12/schema",
  title       = "Schema for COVID-19 Forecast Hub Archive model metadata",
  description = paste0(
    "Schema for model metadata files in the COVID-19 Forecast Hub archive. ",
    "Adapted from the legacy covid19-forecast-hub schema.yml plus modern ",
    "hubverse conventions. See https://docs.hubverse.io for details."
  ),
  type = "object",
  properties = list(
    team_name = list(
      description = "The name of the team submitting the model",
      type = "string"
    ),
    team_abbr = list(
      description = "Abbreviated name of the team submitting the model",
      type = "string",
      pattern = "^[a-zA-Z0-9_+]+$",
      # Longest legacy team_abbr is "UChicagoCHATTOPADHYAY" (21 chars).
      # Bumped to 24 for headroom while still rejecting absurd names.
      maxLength = 24L
    ),
    model_name = list(
      description = "The name of the model",
      type = "string"
    ),
    model_abbr = list(
      description = "Abbreviated name of the model",
      type = "string",
      pattern = "^[a-zA-Z0-9_+]+$",
      maxLength = 16L
    ),
    model_contributors = list(
      type = "array",
      items = list(
        type = "object",
        properties = list(
          name        = list(type = "string"),
          affiliation = list(type = "string"),
          orcid       = list(type = "string",
                             pattern = "^\\d{4}\\-\\d{4}\\-\\d{4}\\-[\\dX]{4}$"),
          email       = list(type = "string", format = "email"),
          twitter     = list(type = "string")
        ),
        additionalProperties = FALSE
      )
    ),
    website_url = list(
      description = "Public-facing website for the model",
      type = "string",
      format = "uri"
    ),
    repo_url = list(
      description = "Repository containing the model code",
      type = "string",
      format = "uri"
    ),
    license = list(
      description = "License governing the model output data",
      type = "string"
    ),
    citation = list(
      description = "One or more citations for this model",
      type = "string"
    ),
    team_funding = list(
      description = "Funding sources for the team or its members",
      type = "string"
    ),
    institution_affil = list(
      description = "Institutional affiliation of the team",
      type = "string"
    ),
    twitter_handles = list(
      description = "Twitter/X handles for the team or its members",
      type = "string"
    ),
    team_model_designation = list(
      description = "Submission designation per the legacy hub",
      type = "string",
      enum = list("primary", "secondary", "proposed", "other")
    ),
    model_details = list(
      description = "Structured information about the model",
      type = "object",
      properties = list(
        data_inputs = list(
          description = "List or description of data inputs used by the model",
          type = "string"
        ),
        methods = list(
          description = "A brief (<= 200 char) description of the model's methods",
          type = "string",
          maxLength = 200L
        ),
        methods_long = list(
          description = "A full description of the model's methods",
          type = "string"
        )
      ),
      additionalProperties = FALSE
    ),
    ensemble_of_hub_models = list(
      description = "TRUE if the model is an ensemble of other hub models",
      type = "boolean"
    ),
    this_model_is_an_ensemble = list(
      description = "Legacy alias for ensemble_of_hub_models — kept for fidelity",
      type = "boolean"
    )
  ),
  additionalProperties = TRUE,
  required = list("team_name", "team_abbr", "model_name", "model_abbr",
                  "license", "model_details")
)

dest <- here::here("hub-config", "model-metadata-schema.json")
write_json(schema, dest, pretty = TRUE, auto_unbox = TRUE,
           null = "null", na = "null")
cat(sprintf("wrote %s (%.1f KB)\n", dest, file.size(dest) / 1024))

cat("\n--- validate_model_metadata_schema ---\n")
v <- validate_model_metadata_schema(hub_path = here::here())
print(v)
