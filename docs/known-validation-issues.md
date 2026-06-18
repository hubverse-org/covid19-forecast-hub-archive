# Known validation issues

Failures surfaced when running `hubValidations::validate_submission` (and the
faster custom validator at `src/12b_fast_validate.R`) over the converted hub.
Most issues were inherited from the legacy `covid19-forecast-hub` data; some
have been remediated in place (see "Cleanups" below), the rest are preserved
as-is and documented here.

The authoritative per-file pass/fail logs live in:

- `src/logs/validate_submissions_sample_2026-04-28.csv` — full
  `hubValidations::validate_submission`, 1 file per team-model, **before**
  cleanups.
- `src/logs/validate_submissions_fast_sample_2026-04-28.csv` — custom fast
  validator, same 128 files, **before** cleanups.
- `src/logs/validate_submissions_fast_full_2026-04-28.csv` — custom fast
  validator over all 8,954 files, **before** cleanups.
- `src/logs/clean_na_groups_2026-04-29.csv` — per-file NA-row cleanup record.
- `src/logs/removed_nonmonotone_2026-04-28.csv` — manifest of files removed
  for non-monotonic quantiles.
- `src/logs/removed_oliverwyman_2026-04-29.csv` — manifest of failing
  OliverWyman-Navigator files removed.

The slow and fast validators **agreed on the same 7 failing files** in the
sample. The fast validator reports group counts; the slow validator reports
specific missing combinations.

---

## Cleanups applied

After the initial full validation surfaced 334 failures, four remediation
passes were run:

### 1. Removed 85 files with non-monotonic quantiles

Files where the quantile `value` column was not monotonically non-decreasing
when ordered by `output_type_id` (i.e. the team's quantiles cross). These
cannot be made schema-valid without altering the submitted predictions, so
the parquet outputs were dropped from `model-output/`. The original CSVs
remain untouched in `../covid19-forecast-hub/data-processed/`.

Manifest: `src/logs/removed_nonmonotone_2026-04-28.csv` (85 entries).
Driver:   `src/13_remove_nonmonotone.R`.

### 2. Renamed 2 UChicago `_+` dirs/files

`hubValidations:::parse_file_name` rejects the literal `+` character in
filenames. Two team-model dirs originally named `UChicago-CovidIL_10_+` and
`UChicago-CovidIL_30_+` were renamed to drop the trailing `_+`:

```
model-output/UChicago-CovidIL_10_+/  -> model-output/UChicago-CovidIL_10/
model-output/UChicago-CovidIL_30_+/  -> model-output/UChicago-CovidIL_30/
```

Inner parquet filenames and the corresponding `model-metadata/<dir>.yml`
files (and their `model_abbr` field) were updated to match.

Driver: `src/14_rename_uchicago.R`. Both files now pass validation.

### 3. Cleaned NA rows from 13 files

Every NA `value` cell in the affected files was localised to entire
`(target, reference_date, location, horizon)` quantile groups (verified
before cleanup — no group had a mix of valid and NA quantiles). The cleanup
drops only the NA rows, leaving any valid `mean`/`median` rows in the same
groups intact. For five AMM-EpiInvert files this preserves the team's mean
predictions even though all their quantile rows for those groups were NA;
the files now contain mean-only predictions.

Driver: `src/15_clean_na_groups.R`. Per-file row counts (before → after):

| File | Before | After | Dropped |
|---|---:|---:|---:|
| `AMM-EpiInvert/2022-09-05-AMM-EpiInvert.parquet` | 1,152 | 144 | 1,008 |
| `AMM-EpiInvert/2022-09-12-AMM-EpiInvert.parquet` | 992 | 124 | 868 |
| `AMM-EpiInvert/2022-09-19-AMM-EpiInvert.parquet` | 896 | 112 | 784 |
| `AMM-EpiInvert/2022-09-26-AMM-EpiInvert.parquet` | 896 | 112 | 784 |
| `AMM-EpiInvert/2022-10-03-AMM-EpiInvert.parquet` | 896 | 112 | 784 |
| `COVIDhub_CDC-ensemble/2022-01-03-COVIDhub_CDC-ensemble.parquet` | 43,944 | 43,848 | 96 |
| `MUNI-ARIMA/2021-08-30-MUNI-ARIMA.parquet` | 6,656 | 6,240 | 416 |
| `MUNI-ARIMA/2021-09-06-MUNI-ARIMA.parquet` | 6,656 | 6,240 | 416 |
| `OliverWyman-Navigator/2021-06-13-OliverWyman-Navigator.parquet` | 26,580 | 16,596 | 9,984 |
| `OliverWyman-Navigator/2021-06-20-OliverWyman-Navigator.parquet` | 26,832 | 16,848 | 9,984 |
| `PandemicCentral-COVIDForest/2021-05-23-PandemicCentral-COVIDForest.parquet` | 97,920 | 95,776 | 2,144 |
| `UMass-sarix/2023-07-24-UMass-sarix.parquet` | 34,776 | 34,132 | 644 |
| `USC-SI_kJalpha/2021-06-13-USC-SI_kJalpha.parquet` | 176,764 | 173,972 | 2,792 |

Of the 13 cleaned files, **11 now pass full validation**; the 2
OliverWyman-Navigator files still failed because they had *both* NA values
*and* incomplete quantile sets in non-NA groups — those 2 are removed in
step 4 below.

### 4. Removed 48 failing OliverWyman-Navigator files

OliverWyman-Navigator was the largest single source of remaining failures
(46 incomplete + 2 NA-plus-incomplete = 48 of 55 total files). Like the
non-monotonic case, these can't be made schema-valid without altering the
team's submitted predictions, so the 48 failing parquet outputs were
dropped from `model-output/`. The 7 passing files are kept; the original
CSVs in `../covid19-forecast-hub/data-processed/` remain untouched.

Manifest: `src/logs/removed_oliverwyman_2026-04-29.csv` (48 entries).
Driver:   `src/16_remove_oliverwyman_failures.R`.

---

## Archive state after cleanups

| Quantity | Before | After |
|---|---:|---:|
| Parquet files in `model-output/` | 8,954 | 8,821 |
| On-disk size | 2.8 GB | 2.6 GB |
| Validation failures (projected) | 334 | 188 |

Projected pass rate after cleanups: **8,633 / 8,821 ≈ 97.9 %**. The 188
remaining failures are all `fast_req_vals` (incomplete required quantile
sets) from teams other than OliverWyman. A definitive full-archive
re-validation has not been run since the cleanups; rerun
`Rscript src/12b_fast_validate.R --full` to refresh.

### Remaining failure category

| Category | Files | Description |
|---|---:|---|
| `fast_req_vals` | 188 | At least one `(target, reference_date, location, horizon)` group is missing one or more required quantile `output_type_id` values. Real data quality issue from the original submission; preserved as-is. |

### Top contributing teams (remaining failures)

| Team-model | Failed files | Cause |
|---|---:|---|
| UChicagoCHATTOPADHYAY-UnIT | 49 | Incomplete quantile sets |
| LNQ-ens1 | 29 | Incomplete quantile sets |
| AIpert-pwllnod | 27 | Incomplete quantile sets |
| QJHong-Encounter | 26 | Incomplete quantile sets |
| IHME-CurveFit | 16 | Incomplete quantile sets |
| UMich-RidgeTfReg | 16 | Incomplete quantile sets |
| Auquan-SEIR | 5 | Incomplete quantile sets |
| (others, smaller counts) | … | Incomplete quantile sets |

### Why these failures existed in the archive

These submissions were accepted by the legacy hub at the time (its
validation was less strict on per-group quantile completeness).
Re-validating against the strict hubverse schema surfaced the data
quality issues that were latent in the original archive.

> **Note**: A previous version of this document stated that altering the
> submitted predictions would defeat the archival intent. That policy was
> revisited; see [Section 5](#5-distfromq-imputed-quantile-fills) below
> for the current treatment of these 190 files.

---

## 5. distfromq-imputed quantile fills

After the cleanups above, 190 files (188 incomplete-quantile + 2
floating-point monotonicity) still failed
`hubValidations::validate_submission` on a full Unity cluster pass
(job `59079072`). Rather than leave them unconverted, all 190 were
remediated and now ship in the archive. The fix policy and per-file
log live in `src/logs/distfromq_fill_log.csv`,
`src/logs/noise_fix_log.csv`, and
`src/logs/validate_fixed_local.csv`.

### What changed (high level)

| Failure type | Files | Treatment | Driver |
|---|---:|---|---|
| Floating-point monotonicity (|delta| < 1e-9 on otherwise constant runs) | 2 | Snap each ULP-noise violator forward to its predecessor's value. Preserves the team's predictions to ~12 sig figs. | `src/19_fix_floating_point_noise.R` |
| Incomplete required quantile set | 188 | For each `(target, reference_date|forecast_date, location, horizon)` group that lacks the target's required quantile levels: fit `distfromq::make_q_fn` on the team's submitted (probability, value) pairs and impute the missing levels. | `src/20_distfromq_fill.R` |

### Eligibility & per-group policy for the 188

- **Per-target required level sets.** The hub uses different required
  quantile sets per target (`inc case` → 7 levels;
  `inc death` / `cum death` / `inc hosp` → 23 levels). The fix reads
  `hub-config/tasks.json` and applies each target's own required set.
- **≥ 5 anchor quantiles** per group is required before `distfromq`
  will impute. Groups with fewer anchors are *dropped* (their rows are
  removed from the file) so the remaining content is fully valid.
- **Isotonic clamping** on imputed values: each new value at level *p*
  is clamped to lie within `[max(0, prev_anchor_value), next_anchor_value]`.
  This is necessary because `distfromq`'s left-tail extrapolation can go
  below 0 (forbidden by the hub's `value >= 0` constraint) and its
  spline can overshoot sub-ULP between equal anchors.

### Aggregate impact (188 incomplete files)

| Quantity | Value |
|---|---:|
| Groups unchanged (already complete for that target) | 689,517 |
| Groups filled by distfromq | 31,583 |
| Groups dropped (< 5 anchors) | 42,219 |
| Rows added | 351,554 |
| Rows dropped | 132,503 |

### Re-validation

All 190 fixed files pass `hubValidations::validate_submission` on local
parallel re-validation (`src/21_validate_fixed_local.R`, 8 cores, 40
min wall). Log: `src/logs/validate_fixed_local.csv` (`ok=TRUE` for all
190).

### Provenance

Imputed rows carry no in-parquet marker — they share schema and shape
with the team's submitted rows. Provenance lives in three places:

- `src/logs/distfromq_fill_log.csv` — per-file counts of groups
  unchanged / filled / dropped + min anchors used.
- `src/logs/noise_fix_log.csv` — per-value snap log for the 2 monotonicity
  files; each row records the original and snapped values + |delta|.
- `src/logs/pr-submission-tracking.csv` — `fixed_by` column on each of
  the 190 files (`"distfromq"` or `"noise_clamp"`).

### Policy reversal note

Prior policy was "altering submitted predictions defeats archival
intent." That stance prioritised provenance over completeness. The
reversal trades 132,503 dropped rows + 351,554 imputed rows (~0.6% of
the archive) for a fully validation-clean dataset of 8,821 files at
~97.9% pass rate → **100% pass rate**. The imputation is documented
end-to-end so downstream users can recover or re-derive the original
submissions from the legacy hub.

---

## Original sample-run snapshot (pre-cleanup)

Kept for reference. The 7 sample failures:

| File | Pre-cleanup category | Post-cleanup status |
|---|---|---|
| `Auquan-SEIR/2020-08-24-Auquan-SEIR.parquet` | incomplete quantiles | still failing (no remediation possible) |
| `CovidActNow-SEIR_CAN/2020-07-05-CovidActNow-SEIR_CAN.parquet` | incomplete quantiles | still failing (no remediation possible) |
| `OliverWyman-Navigator/2021-06-20-OliverWyman-Navigator.parquet` | NA values + incomplete quantiles | parquet removed in cleanup #4 |
| `UChicago-CovidIL_10_+/2020-05-18-…` | `+` in filename | renamed → ✓ pass |
| `UChicago-CovidIL_30_+/2020-05-18-…` | `+` in filename | renamed → ✓ pass |
| `UChicagoCHATTOPADHYAY-UnIT/2021-12-26-…` | incomplete quantiles | still failing (no remediation possible) |
| `USACE-ERDC_SEIR/2020-11-30-USACE-ERDC_SEIR.parquet` | non-monotonic quantiles | parquet removed |
