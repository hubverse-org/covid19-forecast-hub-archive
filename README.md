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

## Accessing hub data on the cloud

To ensure greater access to the data created by and submitted to this hub, real-time copies of its model-output,
target, and configuration files are hosted on the Hubverse's Amazon Web Services (AWS) infrastructure,
in a public S3 bucket: `covid19-forecast-hub-archive`

**Note**: For efficient storage, all model-output files in S3 are stored in parquet format, even if the original
versions in the GitHub repository are .csv.

GitHub remains the primary interface for operating the hub and collecting forecasts from modelers.
However, the mirrors of hub files on S3 are the most convenient way to access hub data without using git/GitHub or
cloning the entire hub to your local machine.

The sections below provide examples for accessing hub data on the cloud, depending on your goals and
preferred tools. The options include:

| Access Method              | Description                                                                  |
|----------------------------|------------------------------------------------------------------------------|
| hubData (R)                | Hubverse R client and R code for accessing hub data                          |
| hub-data (Python)          | Python package for working with hubverse data                                |
| AWS command line interface | Download hub data to your machine and use hubData or Polars for local access |

In general, accessing the data directly from S3 (instead of downloading it first) is more convenient. However, if
performance is critical (for example, you're building an interactive visualization), or if you need to work offline,
we recommend downloading the data first.

<!-------------------------------------------------- hubData ------------------------------------------------------->

<details>

<summary>hubData (R)</summary>

[hubData](https://hubverse-org.github.io/hubData), the Hubverse R client, can create an interactive session
for accessing, filtering, and transforming hub model output data stored in S3.

hubData is a good choice if you:

- already use R for data analysis
- want to interactively explore hub data from the cloud without downloading it
- want to save a subset of the hub's data (*e.g.*, forecasts for a specific date or target) to your local machine
- want to save hub data in a different file format (*e.g.*, parquet to .csv)

### Installing hubData

To install hubData and its dependencies (including the dplyr and arrow packages), follow the [instructions in the hubData documentation](https://hubverse-org.github.io/hubData/#installation).

### Using hubData

hubData's [`connect_hub()` function](https://hubverse-org.github.io/hubData/reference/connect_hub.html) returns an [Arrow
multi-file dataset](https://arrow.apache.org/docs/r/reference/Dataset.html) that represents a hub's model output data.
The dataset can be filtered and transformed using dplyr and then materialized into a local data frame
using the [`collect_hub()` function](https://hubverse-org.github.io/hubData/reference/collect_hub.html).


#### Accessing target data

*[hubData will be updated to access target data once the Hubverse target data standards are finalized.]*

#### Accessing model output data

Below is an example of using hubData to connect to a hub on S3 and filter the model output data.

```r
library(dplyr)
library(hubData)

bucket_name <- "covid19-forecast-hub-archive"
hub_bucket <- s3_bucket(bucket_name)
hub_con <- hubData::connect_hub(hub_bucket, file_format = "parquet", skip_checks = TRUE)
hub_con %>%
  dplyr::filter(location == "MA", output_type == "quantile") %>%
  hubData::collect_hub()

```

- [full hubData documentation](https://hubverse-org.github.io/hubData/)

</details>

<!--------------------------------------------------- hub-data ------------------------------------------------------->

<details>

<summary>hub-data (Python)</summary>

The Hubverse team is developing a Python client which provides some initial tools for accessing Hubverse data. The repository is located at https://github.com/hubverse-org/hub-data .


### Installing hub-data

Use pip to install hub-data (the pypi package is https://pypi.org/project/hubdata ):

```sh
pip install hubdata
```

### Using hub-data

Please see the [hub-data package documentation](https://hubverse-org.github.io/hub-data) for examples of how to use the CLI, and the `hubdata.connect_hub()` and `hubdata.create_hub_schema()` functions.

</details>

<!--------------------------------------------------- AWS CLI ------------------------------------------------------->

<details>

<summary>AWS CLI</summary>

AWS provides a terminal-based command line interface (CLI) for exploring and downloading S3 files.
This option is ideal if you:

- plan to work with hub data offline but don't want to use git or GitHub
- want to download a subset of the data (instead of the entire hub)
- are using the data for an application that requires local storage or fast response times

### Installing the AWS CLI

- Install the AWS CLI using the
[instructions here](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- You can skip the instructions for setting up security credentials, since Hubverse data is public

### Using the AWS CLI

When using the AWS CLI, the `--no-sign-request` option is required, since it tells AWS to bypass a credential check
(*i.e.*, `--no-sign-request` allows anonymous access to public S3 data).

> [!NOTE]
> Files in the bucket's `raw` directory should not be used for analysis (they're for internal use only).

List all directories in the hub's S3 bucket:

```sh
aws s3 ls covid19-forecast-hub-archive --no-sign-request
```

List all files in the hub's bucket:

```sh
aws s3 ls covid19-forecast-hub-archive --recursive --no-sign-request
```

Download all of target-data contents to your current working directory:

```sh
aws s3 cp s3://covid19-forecast-hub-archive/target-data/ . --recursive --no-sign-request
```

Download the model-output files for a specific team:

```sh
aws s3 cp s3://covid19-forecast-hub-archive/model-output/COVIDhub-ensemble/ . --recursive --no-sign-request
```

- [Full documentation for `aws s3 ls`](https://docs.aws.amazon.com/cli/latest/reference/s3/ls.html)
- [Full documentation for `aws s3 cp`](https://docs.aws.amazon.com/cli/latest/reference/s3/cp.html)

</details>

## Acknowledgments

This repository follows the data formats and tooling standards published by
the [hubverse](https://hubverse.io). The forecast data is republished from
the original [COVID-19 Forecast Hub](https://github.com/reichlab/covid19-forecast-hub),
maintained by the [Reich Lab](https://reichlab.io) at UMass Amherst with
support from the US CDC and many academic partners. Citations and
attribution requirements vary by submitting team — see each model's
metadata file under [`model-metadata/`](model-metadata/) for the relevant
license, citation, and contact details.
