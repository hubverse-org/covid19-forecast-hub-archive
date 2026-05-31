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
- **8,821 forecast files** (parquet, ~2.6 GB total), all passing
  `hubValidations::validate_submission`. From the 8,954 originally
  produced by the conversion pipeline, 85 non-monotonic and 48
  OliverWyman-Navigator files were dropped during the cleanup passes
  (`src/13`, `src/16`); 190 incomplete-quantile / floating-point-noise
  files were remediated via the `distfromq` pipeline (`src/19`,
  `src/20`). Per-file provenance for the remediated set lives in the
  `fixed_by` column of `src/logs/pr-submission-tracking.csv`.
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

## Data quality remediation

Re-validating the originally-converted 8,954 files against the strict
hubverse schema surfaced ~3.7 % with data quality issues that were latent
in the legacy hub's submissions. The pipeline now resolves these through a
mix of removals (where remediation would alter substantive forecasts) and
imputation (where the team's submitted anchors were sufficient to infer
the missing quantiles). The current archive's 8,821 files all pass
`hubValidations::validate_submission`.

Issues encountered and how each was handled:

| Issue | Files affected | How resolved | Driver script | Manifest / log |
|---|---:|---|---|---|
| Non-monotonic quantiles (real crossings, not ULP noise) | 85 | Parquet output dropped; original CSVs untouched in the legacy hub | `src/13_remove_nonmonotone.R` | [`src/logs/removed_nonmonotone_2026-04-28.csv`](src/logs/removed_nonmonotone_2026-04-28.csv) |
| `+` character in directory/filename (rejected by `hubValidations:::parse_file_name`) | 2 | Dirs and parquets renamed to drop the trailing `_+`; metadata `model_abbr` updated to match | `src/14_rename_uchicago.R` | (see `docs/known-validation-issues.md` §2) |
| `NA` rows isolated to entire (target, ref_date, location, horizon) groups | 13 | NA rows dropped from the affected groups; 11 then pass full validation, 2 remained in the OliverWyman row below | `src/15_clean_na_groups.R` | [`src/logs/clean_na_groups_2026-04-28.csv`](src/logs/clean_na_groups_2026-04-28.csv) |
| OliverWyman-Navigator: 46 incomplete-quantile files + 2 NA-plus-incomplete | 48 | Parquet output dropped; whole-team policy decision | `src/16_remove_oliverwyman_failures.R` | [`src/logs/removed_oliverwyman_2026-04-29.csv`](src/logs/removed_oliverwyman_2026-04-29.csv) |
| Floating-point monotonicity (\|delta\| < 1e-11, USC-SI_kJalpha) | 2 | Snap each ULP-noise violator forward to its predecessor's value (~12-sig-fig fidelity to the team's predictions) | `src/19_fix_floating_point_noise.R` | [`src/logs/noise_fix_log.csv`](src/logs/noise_fix_log.csv) |
| Incomplete required quantile set (per-target levels missing) | 188 | For each group with ≥ 5 anchors: fit `distfromq::make_q_fn` on submitted (p, v) pairs and impute missing levels; isotonically clamp to `[max(0, prev_anchor), next_anchor]`. For groups with < 5 anchors: drop the group's rows. | `src/20_distfromq_fill.R` | [`src/logs/distfromq_fill_log.csv`](src/logs/distfromq_fill_log.csv), [`src/logs/fail_anchor_summary.csv`](src/logs/fail_anchor_summary.csv) |

The remediated set (190 files) is identified by a `fixed_by` column in
[`src/logs/pr-submission-tracking.csv`](src/logs/pr-submission-tracking.csv)
(`"distfromq"` for the 188, `"noise_clamp"` for the 2). The most-affected
teams are listed below; see [`docs/known-validation-issues.md`](docs/known-validation-issues.md)
§5 for the full breakdown.

| Team-model | Files remediated | Issue |
|---|---:|---|
| UChicagoCHATTOPADHYAY-UnIT | 49 | Incomplete quantile sets |
| LNQ-ens1 | 29 | Incomplete quantile sets |
| AIpert-pwllnod | 27 | Incomplete quantile sets |
| QJHong-Encounter | 26 | Incomplete quantile sets |
| IHME-CurveFit | 16 | Incomplete quantile sets |
| UMich-RidgeTfReg | 16 | Incomplete quantile sets |
| Auquan-SEIR | 5 | Incomplete quantile sets |
| JHU_UNC_GAS-StatMechPool | 3 | Incomplete quantile sets |
| JHU_CSSE-DECOM, IowaStateLW-STEM, LANL-GrowthRate, MOBS-GLEAM_COVID, UMass-MechBayes | 2 each | Incomplete quantile sets |
| USC-SI_kJalpha | 2 | Floating-point monotonicity (ULP noise) |
| 7 other teams | 1 each | Incomplete quantile sets |

Aggregate impact across the 188 distfromq fills: 31,583 groups received
imputed values (351,554 new rows), 42,219 sparse groups were dropped
(132,503 rows). Re-validation log:
[`src/logs/validate_fixed_local.csv`](src/logs/validate_fixed_local.csv).

A residual **149 legacy CSVs** sit outside the validated archive: 16
were never converted (no rows matched any active round), 85 were dropped
for real (non-ULP) quantile crossings, and 48 were the OliverWyman-Navigator
removals listed above. The original CSVs remain untouched in
`../covid19-forecast-hub/data-processed/`.

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

# 5. Cleanups (drop non-monotonic, rename _+, clean NAs, drop OliverWyman failures)
source("src/13_remove_nonmonotone.R")
source("src/14_rename_uchicago.R")
source("src/15_clean_na_groups.R")
source("src/16_remove_oliverwyman_failures.R")

# 6. Remediation: 2-file noise clamp + 188-file distfromq fill (~1 hour total)
source("src/19_fix_floating_point_noise.R")
source("src/20_distfromq_fill.R")

# 7. Full re-validation (~28 min on 8 workers, or ~40 min for the
#    just-remediated subset via src/21)
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
