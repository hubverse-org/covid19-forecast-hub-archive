#!/usr/bin/env Rscript
# Pure helper: parse a legacy covid19-forecast-hub `target` string into the
# hubverse-style (target, horizon, time_unit) tuple.
#
#   "1 wk ahead inc death"   -> target = "inc death", horizon = 1L, time_unit = "wk"
#   "12 day ahead inc hosp"  -> target = "inc hosp",  horizon = 12L, time_unit = "day"
#   "1 wk ahead cum death"   -> target = "cum death", horizon = 1L, time_unit = "wk"
#   "1 wk ahead inc case"    -> target = "inc case",  horizon = 1L, time_unit = "wk"
#
# Unparseable strings yield NA in every component. Vectorised: pass a character
# vector of length N, get back a 3-column tibble of length N.

suppressPackageStartupMessages({
  library(stringr)
  library(tibble)
})

parse_target <- function(s) {
  m <- str_match(s, "^(\\d+) (wk|day) ahead (inc|cum) (case|death|hosp)$")
  tibble(
    target    = ifelse(is.na(m[, 4]) | is.na(m[, 5]),
                       NA_character_,
                       paste(m[, 4], m[, 5])),
    horizon   = suppressWarnings(as.integer(m[, 2])),
    time_unit = m[, 3]
  )
}

# --- self-test (only when run as a script) -------------------------------
if (sys.nframe() == 0L && !interactive()) {
  suppressPackageStartupMessages(library(testthat))

  test_that("standard targets parse", {
    out <- parse_target(c("1 wk ahead inc death",
                          "12 day ahead inc hosp",
                          "20 wk ahead cum death",
                          "8 wk ahead inc case"))
    expect_equal(out$target,    c("inc death", "inc hosp", "cum death", "inc case"))
    expect_equal(out$horizon,   c(1L, 12L, 20L, 8L))
    expect_equal(out$time_unit, c("wk", "day", "wk", "wk"))
  })

  test_that("zero-horizon hosp parses", {
    out <- parse_target("0 day ahead inc hosp")
    expect_equal(out$target, "inc hosp")
    expect_equal(out$horizon, 0L)
    expect_equal(out$time_unit, "day")
  })

  test_that("malformed strings give NA without errors", {
    out <- parse_target(c("garbage", "", NA_character_, "1 month ahead inc death"))
    expect_true(all(is.na(out$target)))
    expect_true(all(is.na(out$horizon)))
    expect_true(all(is.na(out$time_unit)))
  })

  test_that("vectorised over many rows", {
    n <- 100
    s <- rep("3 wk ahead inc death", n)
    out <- parse_target(s)
    expect_equal(nrow(out), n)
    expect_true(all(out$target == "inc death"))
    expect_true(all(out$horizon == 3L))
  })

  cat("\nAll parse_target tests passed.\n")
}
