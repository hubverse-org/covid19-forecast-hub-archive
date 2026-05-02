# Build log: covid19-forecast-hub → hubverse-style archive

This document describes how the archive was built. It started as a forward-
looking plan and is now an as-built record. Deviations from the original
plan are noted inline.

## Goal

Convert the legacy [covid19-forecast-hub](https://github.com/reichlab/covid19-forecast-hub)
data (at `../covid19-forecast-hub/`) into a hubverse-compliant archive at
`../covid19-forecast-hub-archive/`. All work in **R**. Validation via
`hubValidations`. Config files authored via `hubAdmin`.

## Source inventory (from `../covid19-forecast-hub/`)

- `data-processed/`: ~39 GB, **8,970 CSV** forecast files, **129 team-model
  directories** (the original plan estimated 136), ~588M source rows.
  Stable schema: `forecast_date, target, target_end_date, location, type,
  quantile, value`.
- `data-truth/`: ~948 MB across 6 CSVs (`truth-Incident Hospitalizations.csv`,
  `truth-Incident Cases.csv`, `truth-Incident Deaths.csv`,
  `truth-Cumulative Cases.csv`, `truth-Cumulative Deaths.csv`,
  `truth-Cumulative Hospitalizations.csv`). Schema:
  `date, location, location_name, value`.
- `data-locations/locations.csv`: `abbreviation, location, location_name,
  population` (3,202 rows: states + DC + 5 territories + 3,144 counties + US).
  The original plan undercounted this as 51 because the early survey only
  looked at state-level rows.
- `data-processed/<team>-<model>/metadata-<team>-<model>.txt`: per-model
  YAML metadata (129 files). Schema enforced by `schema.yml` at repo root.

## As-built hub layout

```
covid19-forecast-hub-archive/
├── hub-config/                          (100 KB)
│   ├── admin.json
│   ├── tasks.json                       (84 KB; 3 rounds, 4 model_tasks each)
│   └── model-metadata-schema.json
├── auxiliary-data/                      (96 KB)
│   └── locations.csv                    (3,202 rows)
├── model-metadata/                      (540 KB; 129 YAMLs)
├── model-output/                        (2.8 GB; 8,954 parquet files)
│   └── <team>-<model>/
│       └── YYYY-MM-DD-<team>-<model>.parquet
├── target-data/                         (85 MB)
│   ├── time-series.csv                  (615,683 rows)
│   └── oracle-output.csv                (1,847,049 rows)
├── docs/
│   └── known-validation-issues.md
├── src/                                 (~1,600 lines of R)
│   ├── PLAN.md                          (this file)
│   ├── 00_discover_data.R
│   ├── 00_validate_hub_config.R
│   ├── 01_build_locations.R
│   ├── 02_build_tasks_json.R
│   ├── 03_build_admin_json.R
│   ├── 04_build_model_metadata_schema.R
│   ├── 05_convert_metadata.R
│   ├── 06_validate_metadata.R
│   ├── 07_convert_target_data.R
│   ├── 08_build_oracle_output.R
│   ├── 09_parse_target.R
│   ├── 10_convert_forecast_file.R
│   ├── 11_convert_all_forecasts.R
│   ├── 12_validate_submissions.R
│   ├── 12b_fast_validate.R
│   └── logs/                            (per-run pass/fail CSVs)
├── inst/cache/                          (rds caches: forecast dates, locations)
└── README.md
```

## Round structure (as built)

The original plan proposed **6 rounds** based on README documentation
(R1–R6). After full data discovery, the active-target signature did not
form 6 clean contiguous eras — submissions of "deprecated" targets
continued for years past official cutoffs. The implementation collapsed to
**3 rounds** matching the major eras of active targets:

- **R1** 2020-03-15 → 2020-07-25 — `inc death`, `cum death`
- **R2** 2020-07-26 → 2023-03-05 — `inc death`, `cum death`, `inc case`, `inc hosp`
- **R3** 2023-03-06 → 2024-04-29 — `inc hosp`

Within each round, every model_task shares the same union of forecast
dates (a hubverse schema requirement: `forecast_date` task_id values must
be consistent across model_tasks within a round).

Quantile sets (fixed per target):

| Target | Quantiles | Set |
|---|---:|---|
| `inc death`, `cum death`, `inc hosp` | 23 | 0.01, 0.025, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 0.975, 0.99 |
| `inc case` | 7 | 0.025, 0.10, 0.25, 0.50, 0.75, 0.90, 0.975 |

Locations per target (verified empirically over all 8,970 source CSVs):

| Target | State + US | County |
|---|---:|---:|
| `inc death`, `cum death`, `inc hosp` | 57 | 0 |
| `inc case` | 57 | 3,144 |

## Phases (as executed)

### Phase 1 — Configs

Authored via `hubAdmin` builders. All four checks pass via
`hubValidations::check_config_hub_valid()` and `hubAdmin::validate_config()`.

| Step | Script | Output |
|---|---|---|
| 1 | `01_build_locations.R` | `auxiliary-data/locations.csv` |
| 2 | `02_build_tasks_json.R` | `hub-config/tasks.json` |
| 3 | `03_build_admin_json.R` | `hub-config/admin.json` |
| 4 | `04_build_model_metadata_schema.R` | `hub-config/model-metadata-schema.json` |
| ✓ | `00_validate_hub_config.R` | passes all four schema/hub-config checks |

**Discovery cache** (`00_discover_data.R`): scans every source CSV for the
`(forecast_date, target, location)` set used by 02 and downstream scripts;
caches to `inst/cache/`. ~3.6 min full scan.

**Filed bug**: `hubverse-org/hubAdmin#117` (false-positive duplicate
detection between `mean` and `median` output_type items). Already filed by
the maintainer; existing workaround applied in `02_build_tasks_json.R`
(give one a `value_minimum=0`, omit it on the other).

### Phase 2 — Model metadata

`05_convert_metadata.R` parses each legacy `metadata-*.txt` (YAML), splits
the legacy `model_abbr` ("TEAM-MODEL") into `team_abbr` + `model_abbr`,
parses the free-text `model_contributors` string into an array of
`{name, affiliation?, email?}` objects, nests `methods`/`methods_long`/
`data_inputs` under `model_details`, and writes
`model-metadata/<team>-<model>.yml`. `06_validate_metadata.R` runs
`hubValidations::validate_model_metadata()` per file.

**Result: 129 / 129 valid.** Two issues caught and fixed during validation:
trimming whitespace inside `<email>` brackets, and prepending `https://`
to schemeless URLs.

### Phase 3 — Target data (CSV per user preference)

| Step | Script | Output |
|---|---|---|
| 1 | `07_convert_target_data.R` | `target-data/time-series.csv` (615,683 rows) |
| 2 | `08_build_oracle_output.R` | `target-data/oracle-output.csv` (1,847,049 rows) |

Mapping:

- `truth-Incident Deaths.csv` → `inc death` (weekly Saturday-EW sum, state + US)
- `truth-Cumulative Deaths.csv` → `cum death` (weekly Saturday-EW value, state + US)
- `truth-Incident Cases.csv` → `inc case` (weekly Saturday-EW sum, state + county + US)
- `truth-Incident Hospitalizations.csv` → `inc hosp` (daily passthrough, state + US)
- `truth-Cumulative Cases.csv`, `truth-Cumulative Hospitalizations.csv` →
  no matching target in `tasks.json`; skipped.

Oracle output: 3 rows per time-series row (one per `output_type` ∈
{quantile, mean, median}); `oracle_value = observation`,
`output_type_id = NA`.

### Phase 4 — Forecast conversion

| Step | Script | Notes |
|---|---|---|
| 1 | `09_parse_target.R` | regex parser, unit-tested with `testthat` |
| 2 | `10_convert_forecast_file.R` | per-file conversion function + CLI |
| 3 | `11_convert_all_forecasts.R` | parallel driver (8 workers via `furrr`) |

**Per-file logic**:

- Read source CSV with explicit column types
- `forecast_date` passed through under its legacy name (not renamed to
  `reference_date`)
- Parse `target` string into `(target, horizon)`; drop rows whose
  `time_unit` doesn't match the target's canonical unit
- Filter to in-round (target, time_unit) tuples; out-of-round rows logged
- Point-forecast logic: per-file determination — every
  `(forecast_date, location, target, horizon)` group's `point` row
  must match the corresponding `quantile=0.5` row (relative tol 1e-6)
  for all to be emitted as `median`; otherwise all become `mean`
- Quantile rows: `output_type=quantile`, `output_type_id=quantile`
- `target_end_date` passed through verbatim from the legacy data; for the
  one-time backfill of pre-existing parquet files, it was recomputed from
  `(forecast_date, target, horizon)` via `src/17_rename_and_add_ted.R`
- Write `model-output/<team>-<model>/<forecast_date>-<team>-<model>.parquet`

**Full run**: 8,970 source CSVs → **8,954 parquet** files (16 dropped
because every row was out-of-round); ~588M input rows → ~568M output rows
(19.9M dropped by round filter); 39 GB CSV → **2.8 GB parquet (~14×
smaller)**; **5.9 min** wall time on 8 workers.

Point determination: 5,746 files → `median`, 2,805 → `mean`, 419 →
quantile-only.

### Phase 5 — Validation

| Step | Script | Notes |
|---|---|---|
| 1 | `12_validate_submissions.R` | reference: full `hubValidations::validate_submission` |
| 2 | `12b_fast_validate.R` | fast custom validator (replaces `req_vals` with vectorised dplyr) |

**Bottleneck found**: `hubValidations:::check_required_output_type_by_modeling_task`
(invoked by `req_vals`) takes ~17 s/file because it expands the full
`(forecast_date × location × horizon × output_type_id)` cross-product per
model_task and joins it against the file's data. For our R2 inc-case
model_task that's ≥179K rows of expanded grid per file. Sample-mode
validation took **188 minutes** for 128 files.

**Custom replacement**: vectorised dplyr group-by-and-completeness check
on the file's actual `(target, forecast_date, location, horizon)` groups
against each target's required quantile set. Same semantics for archive
purposes. Floating-point bug fixed: `seq(0.05, 0.95, by=0.05)` does not
produce bit-exact `0.15` etc.; replaced with literal enumeration.

**Cross-check**: on the 128-file sample, the slow and fast validators
flag **exactly the same 7 files** (identical sets).

**Full run** (`12b_fast_validate.R --full`, 8 workers, 28 min):
**8,620 ok / 334 failed (96.3% pass rate)**.

| Failure category | Files |
|---|---:|
| `fast_req_vals` (incomplete quantile sets) | 234 |
| `value_col_non_desc` (non-monotonic quantiles) | 85 |
| `value_col_valid` (NA / wrong-type values) | 13 |
| `file_name` (`+` in `model_abbr`) | 2 |

Detailed per-team and per-cause breakdown lives in
`docs/known-validation-issues.md`. All failures trace to legacy
submissions, not the conversion pipeline.

## Key conventions and decisions

- **Forecast file format**: parquet (per user preference).
- **Target data file format**: CSV (per user preference).
- **Locations**: stored in `auxiliary-data/`, not `hub-config/` (per user preference).
- **Mean vs median for `type=point` rows**: per-file determination. If
  every `(forecast_date, location, target, horizon)` group's point value
  matches its 0.5 quantile (relative tol 1e-6), the file's points become
  `median`; otherwise `mean`. Mean and median both `is_required: false`
  in `tasks.json`.
- **`target_end_date` column**: passed through verbatim from the legacy
  data (preserves the MMWR-week Saturday convention for weekly targets).
  Stored as a regular task_id in `tasks.json`; *not* listed in
  `derived_task_ids`, because the legacy weekly relationship does not
  satisfy the simple `forecast_date + horizon * unit` formula that
  hubverse tooling assumes for derived task IDs.
- **Round granularity**: 3 era-based rounds keyed to changes in active
  targets (collapsed from the original 6-round plan after data inspection).
- **One input CSV → one output parquet**: preserves traceability for the
  validation log.
- **Stragglers**: files where every row is out-of-round (e.g. lone inc-case
  submission after 2023-03-06) are dropped — 16 source files. See
  `src/logs/convert_forecasts_2026-04-28.csv`.

## Computational footprint (actual, not estimated)

| Phase | Wall time |
|---|---|
| 1 — discovery + configs | ~5 min |
| 2 — metadata conversion + validation | ~30 s |
| 3 — target data | ~1 min |
| 4 — forecast conversion (8,970 files, 8 workers) | **5.9 min** |
| 5a — slow validation, sample only (128 files) | **188 min** |
| 5b — fast validation, sample (128 files, sequential) | 2.7 min |
| 5b — fast validation, full (8,954 files, 8 workers) | **28 min** |

## R package dependencies

`hubAdmin`, `hubUtils`, `hubValidations`, `arrow`, `readr`, `dplyr`, `tidyr`,
`purrr`, `furrr`, `yaml`, `jsonlite`, `stringr`, `here`, `testthat`.
