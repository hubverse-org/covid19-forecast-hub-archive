# COVID-19 Forecast Hub Archive

A [hubverse](https://hubverse.io)-compliant archive of the data originally
submitted to the [COVID-19 Forecast Hub](https://github.com/reichlab/covid19-forecast-hub),
which collected weekly forecasts of US COVID-19 deaths, cases, and
hospitalizations from April 2020 through April 2024.

The legacy hub used a custom CSV format that predates the hubverse standard.
This repo is a faithful re-encoding of the same forecasts (and the same
observed data used for evaluation) into hubverse layout, so they can be
queried with `hubData`, `hub-data`, and the rest of the hubverse tooling.

Anyone interested in using these data for additional research or
publications is requested to contact `nick@umass.edu` for information
regarding attribution of the source forecasts.

## What's in the archive

- **129 team-models** spanning 2020-03-15 → 2024-04-29
- **8,954 forecast files** (parquet, ~2.8 GB total)
- **4 targets**: `inc death`, `cum death`, `inc case`, `inc hosp`
- **Quantile predictions** (23 quantiles for deaths/hosp, 7 for cases) plus
  optional `mean` and `median` point estimates
- **State + US national** locations for deaths and hospitalizations;
  state + US + 3,144 **county-level** locations for cases
- **Target data** (615,683 weekly/daily observations) and **oracle output**
  (1,847,049 rows) for evaluation

## Repository layout

```
.
├── hub-config/                 hubverse config (admin, tasks, model-metadata schema)
├── auxiliary-data/             location lookup (FIPS, name, population)
├── model-metadata/             one YAML per submitting team-model
├── model-output/               <team-model>/<forecast_date>-<team-model>.parquet
├── target-data/                time-series.csv + oracle-output.csv
├── docs/                       known-validation-issues.md
└── src/                        R scripts that built the archive
```

## Output schema (`model-output/`)

| Column | Type | Notes |
|---|---|---|
| `forecast_date` | date | Date the forecast was submitted (legacy `forecast_date`, kept under its original name rather than renamed to `reference_date`) |
| `target` | string | One of `inc death`, `cum death`, `inc case`, `inc hosp` |
| `horizon` | int | Time-step ahead. Weekly for deaths/cases, daily for hosp |
| `location` | string | FIPS code (`"01"`–`"56"`, `"60"`–`"78"` territories, `"US"`, or 5-digit county) |
| `target_end_date` | date | Date the forecast targets. For weekly targets this is the MMWR-week Saturday corresponding to `(forecast_date, horizon)`; for `inc hosp` it equals `forecast_date + horizon` days. Materialized in every file rather than declared as a `derived_task_ids`, because the legacy weekly relationship is not a simple `forecast_date + horizon * unit` offset |
| `output_type` | string | `quantile`, `median`, or `mean` |
| `output_type_id` | double | Quantile value (0.01–0.99) for `quantile`; `NA` otherwise |
| `value` | double | Forecast value |

### How point forecasts were classified

The legacy hub's `type=point` rows are emitted as either `median` or `mean`
on a **per-file basis**:

- If every `(forecast_date, location, target, horizon)` group with a point
  row also has a `quantile=0.5` row whose value matches the point value
  (relative tolerance `1e-6`), all point rows in that file are emitted as
  `output_type=median`.
- Otherwise, all point rows in that file are emitted as `output_type=mean`.

Across the archive: 5,746 files were classified as `median`, 2,805 as
`mean`, and 419 contain only quantile predictions.

## Round structure

Three era-based rounds capture how the set of requested targets changed
over the life of the legacy hub:

| Round | Date range | Active targets |
|---|---|---|
| R1 | 2020-03-15 → 2020-07-25 | `inc death`, `cum death` |
| R2 | 2020-07-26 → 2023-03-05 | `inc death`, `cum death`, `inc case`, `inc hosp` |
| R3 | 2023-03-06 → 2024-04-29 | `inc hosp` |

`tasks.json` declares each target's quantile set as required (23 for
deaths and hospitalizations, 7 for cases). `mean` and `median` are
declared but not required.

## Known data quality issues

The archive preserves the legacy submissions as-is. Re-validating against
the strict hubverse schema surfaces a small number of files (~3.7% of the
archive) with issues that were latent in the original data:

- **234** files have at least one `(target, forecast_date, location, horizon)`
  group missing one or more required quantiles
- **85** files have non-monotonic quantiles (e.g. the 0.10 quantile is
  greater than the 0.05 quantile)
- **13** files have `NA` or non-numeric values in the `value` column
- **2** files contain a `+` character in the `model_abbr` that
  `hubValidations:::parse_file_name` rejects

The full per-team-per-category breakdown is in
[`docs/known-validation-issues.md`](docs/known-validation-issues.md), and
the per-file pass/fail logs are under `src/logs/`. None of these failures
indicate problems with the conversion pipeline; every issue traces to the
original team's submission.

## How the archive was built

The conversion pipeline lives entirely in `src/` and is reproducible. See
[`src/PLAN.md`](src/PLAN.md) for the full as-built record (data inventory,
round-design rationale, per-script descriptions, computational footprint,
and dependency list).

To rebuild from scratch with a sibling clone of the legacy
`covid19-forecast-hub` checked out at `../covid19-forecast-hub/`:

```r
# 0. Inventory the legacy data (caches forecast dates and locations)
source("src/00_discover_data.R")

# 1. Hub configs (validates against hubverse schema)
source("src/01_build_locations.R")
source("src/02_build_tasks_json.R")
source("src/03_build_admin_json.R")
source("src/04_build_model_metadata_schema.R")
source("src/00_validate_hub_config.R")

# 2. Model metadata
source("src/05_convert_metadata.R")
source("src/06_validate_metadata.R")

# 3. Target data
source("src/07_convert_target_data.R")
source("src/08_build_oracle_output.R")

# 4. Forecast conversion (parallel; ~6 min on 8 workers)
source("src/11_convert_all_forecasts.R")

# 5. Validation (parallel; ~28 min on 8 workers)
system("Rscript src/12b_fast_validate.R --full")
```

R package dependencies: `hubAdmin`, `hubUtils`, `hubValidations`, `arrow`,
`readr`, `dplyr`, `tidyr`, `purrr`, `furrr`, `yaml`, `jsonlite`, `stringr`,
`here`, `testthat`.

## Accessing the data with hubverse tooling

This archive follows the hubverse `v6.0.0` schema, so every hubverse
client can read it directly. For example, with the R client `hubData`:

```r
library(hubData)
hub_con <- connect_hub("path/to/covid19-forecast-hub-archive",
                       file_format = "parquet")
hub_con |>
  dplyr::filter(location == "MA",
                target == "inc hosp",
                output_type == "quantile") |>
  collect_hub()
```

Equivalent Python access via [hub-data](https://hubverse-org.github.io/hub-data/):

```python
import hubdata
hub = hubdata.connect_hub("path/to/covid19-forecast-hub-archive")
df  = (hub.filter(location="MA", target="inc hosp", output_type="quantile")
          .collect())
```

## Acknowledgments

This repository follows the data formats and tooling standards published by
the [hubverse](https://hubverse.io). The forecast data is republished from
the original [COVID-19 Forecast Hub](https://github.com/reichlab/covid19-forecast-hub),
maintained by the [Reich Lab](https://reichlab.io) at UMass Amherst with
support from the US CDC and many academic partners. Citations and
attribution requirements vary by submitting team — see each model's
metadata file under [`model-metadata/`](model-metadata/) for the relevant
license, citation, and contact details.
