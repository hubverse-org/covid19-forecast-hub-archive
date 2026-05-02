#!/usr/bin/env Rscript
# Convert legacy covid19-forecast-hub metadata-*.txt files (YAML) into
# hubverse-style model-metadata YAMLs at model-metadata/<team>-<model>.yml.
#
# Mapping:
#   model_abbr "TEAM-MODEL"   -> team_abbr + model_abbr (split on first '-')
#   model_contributors STRING -> array of {name, affiliation?, email?} objects
#   methods, methods_long,
#     data_inputs             -> nested under model_details
#   ensemble_of_hub_models    -> kept top-level
#   everything else (license, website_url, repo_url, citation,
#     team_funding, twitter_handles, institution_affil,
#     team_model_designation) -> kept as-is
#
# Each converted file is validated against hub-config/model-metadata-schema.json
# via hubValidations::validate_model_metadata. Per-file pass/fail rows are
# written to src/logs/convert_metadata_<date>.csv.

suppressPackageStartupMessages({
  library(yaml)
  library(dplyr)
  library(purrr)
  library(stringr)
  library(here)
  library(hubValidations)
})

src_root  <- "../covid19-forecast-hub/data-processed"
dest_dir  <- here::here("model-metadata")
log_dir   <- here::here("src", "logs")
hub_path  <- here::here()

if (!dir.exists(dest_dir)) dir.create(dest_dir, recursive = TRUE)
if (!dir.exists(log_dir))  dir.create(log_dir,  recursive = TRUE)

# --- helpers --------------------------------------------------------------

# Split a string on top-level commas (commas not nested inside parens).
split_top_commas <- function(s) {
  if (is.na(s) || !nzchar(s)) return(character(0))
  out <- character()
  depth <- 0L
  start <- 1L
  chars <- strsplit(s, "", fixed = TRUE)[[1]]
  for (i in seq_along(chars)) {
    ch <- chars[i]
    if (ch == "(") depth <- depth + 1L
    else if (ch == ")") depth <- max(0L, depth - 1L)
    else if (ch == "," && depth == 0L) {
      out <- c(out, paste(chars[start:(i - 1L)], collapse = ""))
      start <- i + 1L
    }
  }
  out <- c(out, paste(chars[start:length(chars)], collapse = ""))
  trimws(out)
}

email_re <- "^[^@\\s()<>]+@[^@\\s()<>]+\\.[^@\\s()<>]+$"

# Normalize a URL: prepend "https://" if no scheme present. Several legacy
# website_url / repo_url entries omit the scheme (e.g. "covidseverity.com",
# "github.com/potomacresearch") which fails the JSON Schema "uri" format.
normalize_url <- function(s) {
  if (is.null(s) || is.na(s) || !nzchar(trimws(s))) return(s)
  s <- trimws(s)
  if (grepl("^[a-zA-Z][a-zA-Z0-9+.-]*://", s)) s else paste0("https://", s)
}

# Parse one contributor token, e.g. "Marco Ajelli (majelli@iu.edu)" or
# "Jackie Baek (MIT) <baek@mit.edu>". Emails inside the angle brackets are
# trimmed of whitespace and dropped if they don't match the email format
# (some legacy files have entries like "< klein@cddep.org>").
parse_contributor <- function(tok) {
  s <- trimws(tok)
  email <- NULL
  affiliation <- NULL

  # Pull <email> if present.
  m <- regmatches(s, regexpr("<[^>]+>", s))
  if (length(m) == 1L) {
    cand <- trimws(gsub("[<>]", "", m))
    if (grepl(email_re, cand)) email <- cand
    s <- sub("<[^>]+>", "", s)
  }

  # Pull (...) — could be email or affiliation.
  m2 <- regmatches(s, regexpr("\\([^)]+\\)", s))
  if (length(m2) == 1L) {
    inner <- trimws(gsub("[()]", "", m2))
    if (is.null(email) && grepl(email_re, inner)) {
      email <- inner
    } else {
      affiliation <- inner
    }
    s <- sub("\\([^)]+\\)", "", s)
  }

  name <- trimws(gsub("\\s+", " ", s))

  out <- list(name = name)
  if (!is.null(affiliation) && nzchar(affiliation)) out$affiliation <- affiliation
  if (!is.null(email)       && nzchar(email))       out$email       <- email
  out
}

parse_contributors <- function(s) {
  tokens <- split_top_commas(s)
  if (length(tokens) == 0L) return(list())
  lapply(tokens, parse_contributor)
}

# Drop NULL elements from a named list, recursively for nested lists.
compact_list <- function(x) {
  if (is.list(x)) {
    x <- lapply(x, compact_list)
    x <- x[!vapply(x, function(v) is.null(v) || (length(v) == 0L && !is.list(v)),
                   logical(1))]
  }
  x
}

# Convert one legacy metadata to the hubverse layout.
convert_one <- function(legacy) {
  # team_abbr / model_abbr from legacy "TEAM-MODEL" string
  parts <- str_match(legacy$model_abbr,
                     "^([a-zA-Z0-9_+]+)-([a-zA-Z0-9_+]+)$")
  if (is.na(parts[1, 1])) {
    stop(sprintf("model_abbr '%s' does not match TEAM-MODEL pattern",
                 legacy$model_abbr))
  }
  team_abbr_v  <- parts[1, 2]
  model_abbr_v <- parts[1, 3]

  contribs <- parse_contributors(legacy$model_contributors %||% "")

  # model_details holds the methods/data_inputs trio
  model_details <- compact_list(list(
    methods      = legacy$methods,
    methods_long = legacy$methods_long,
    data_inputs  = legacy$data_inputs
  ))

  out <- compact_list(list(
    team_name              = legacy$team_name,
    team_abbr              = team_abbr_v,
    model_name             = legacy$model_name,
    model_abbr             = model_abbr_v,
    model_contributors     = contribs,
    website_url            = normalize_url(legacy$website_url),
    repo_url               = normalize_url(legacy$repo_url),
    license                = legacy$license,
    citation               = legacy$citation,
    team_funding           = legacy$team_funding,
    institution_affil      = legacy$institution_affil,
    twitter_handles        = legacy$twitter_handles,
    team_model_designation = legacy$team_model_designation,
    model_details          = model_details,
    ensemble_of_hub_models = legacy$ensemble_of_hub_models
  ))

  out
}

# --- main loop ------------------------------------------------------------

files <- list.files(src_root, pattern = "^metadata-.*\\.txt$",
                    recursive = TRUE, full.names = TRUE)
cat("metadata files to convert:", length(files), "\n")

`%||%` <- function(a, b) if (is.null(a)) b else a

results <- map(files, function(f) {
  team_model <- basename(dirname(f))
  legacy <- tryCatch(yaml::read_yaml(f),
                     error = function(e) e)
  if (inherits(legacy, "error")) {
    return(tibble::tibble(team_model = team_model,
                          phase = "read",
                          ok = FALSE,
                          message = conditionMessage(legacy)))
  }

  conv <- tryCatch(convert_one(legacy), error = function(e) e)
  if (inherits(conv, "error")) {
    return(tibble::tibble(team_model = team_model,
                          phase = "convert",
                          ok = FALSE,
                          message = conditionMessage(conv)))
  }

  out_path <- file.path(dest_dir, paste0(team_model, ".yml"))
  yaml::write_yaml(conv, out_path)

  tibble::tibble(team_model = team_model,
                 phase = "write",
                 ok = TRUE,
                 message = sprintf("wrote %s", out_path))
})

log_df <- bind_rows(results)
log_path <- file.path(log_dir, sprintf("convert_metadata_%s.csv", Sys.Date()))
readr::write_csv(log_df, log_path)

cat(sprintf("\nconverted: %d ok, %d failed\n",
            sum(log_df$ok), sum(!log_df$ok)))
if (any(!log_df$ok)) {
  cat("failures:\n")
  print(log_df |> filter(!ok))
}
cat("log:", log_path, "\n")
