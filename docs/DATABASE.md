# The database

Everything the site computes lives in one SQLite file, `data/err.sqlite`, written by
`julia --project=julia julia/build.jl` and read by the Quarto pages through `R/db.R`. The file
is not committed; `julia --project=julia julia/export.jl` dumps every table to CSV under
`data/export/`. Dates are stored as ISO text (`YYYY-MM-DD`); missing numbers as `NULL`.

## Invariants

- `online` and `alerts` are append-only. The filter is recomputed in full at every build, the
  rows already stored for the same `engine_version` must agree with the recomputation to 1e-9
  (the build stops otherwise), and only the new weeks are inserted. An alert, once logged, is
  never deleted or changed. Both tables therefore show what the site said at the time.
- `regimes`, `breaks` and `status` are kept for every build, keyed by `build_id`. The dating is
  retrospective and may change as data arrive; keeping every vintage is what makes the
  `revisions` table computable and lets any earlier dating be recovered.
- `rates`, `returns`, `countries` and `events` hold the current vintage only; `rates` records
  the build at which each observation was first seen.
- The last week of a return series is dropped when its Friday lies after the last daily
  observation, so a week whose value could still change never enters `returns` or `online`.

## Tables

**builds** (`build_id`, `built_at`, `data_end`, `config_hash`, `code_hash`, `engine_version`, `notes`).
One row per run of `build.jl`. `data_end` is the newest weekly observation across countries;
`config_hash` and `code_hash` are the first twelve hex digits of the SHA-256 of `config.yml` and of
the Julia sources; `engine_version` is the hash of the filter settings in force (see `online`).

**settings** (`build_id`, `key`, `value`). The configuration of each build, flattened to dotted
keys (`bocpd.alert.k`, `defaults.numeraire`, ...); lists are stored as JSON. The pages read their
rule parameters from here, so a page never depends on `config.yml` directly. The key
`engine_version` names the `online` rows that belong to this build's settings.

**countries** (`iso3`, `iso2`, `ccy`, `name`, `region`, `sort_order`, `has_page`, `note`). The
configured countries of the latest build: the BIS reference area (`iso2`), the currency explained,
the labels used on the pages, the home-page order, whether a page could be built and any note
from the fit (for example a fallback to a single regime).

**events** (`date`, `label`). The vertical lines on the home-page timeline, from `config.yml`.

**rates** (`ccy`, `date`, `rate`, `first_seen_build`). Daily BIS rates in local currency units
per US dollar, for every country currency and every anchor currency (NZD, JPY, EUR, GBP). A rate
BIS revises is updated in place; `first_seen_build` keeps the build at which the date first
appeared. The country pages draw the level chart from here.

**returns** (`ccy`, `date`, `series`, `ret`). The weekly regression data set of each country:
Friday-anchored log returns in per cent against the numeraire of the country's currency
(`series = ccy`) and of its basket currencies (`series` = USD, JPY, EUR, GBP). The set is stored
per country because the weekly aggregation follows the days on which the country's own rate is
observed. Replaced at every build.

**regimes** (`build_id`, `ccy`, `regime_no`, `start_date`, `end_date`, `n_obs`, `r2`,
`b_intercept`, `b_usd`, `b_jpy`, `b_eur`, `b_gbp`, `variance`). The dated regimes of every build:
one row per segment of the Bai-Perron partition chosen by BIC, with the OLS coefficients, the
maximum-likelihood residual variance and the R-squared of the segment regression. A basket
currency that is the country's own currency has `NULL` in its coefficient column.

**breaks** (`build_id`, `ccy`, `breakdate`). The dated break dates of every build; the last
observation of each regime but the final one. Redundant with `regimes` but convenient for the
revision comparison and for the charts.

**online** (`ccy`, `date`, `engine_version`, `p_change_4` ... `p_change_52`, `r_map`, `start_map`,
`r_mean`, `beta_intercept`, `beta_usd`, `beta_jpy`, `beta_eur`, `beta_gbp`, `sigma2`, `logpred`,
`var_down`, `var_up`, `var_ref`, `var_alert`, `first_seen_build`). The weekly output of the online
change-point filter and of the variance detector: the probability that the regime is younger than
k weeks for each horizon k, the most probable run length and its start date, the posterior-mean
run length, coefficients and residual variance, the one-step predictive log density, the two CUSUM
statistics, their reference variance and the detector's alert (-1 fall, +1 rise, 0 none).
`engine_version` is a hash of the settings that determine these numbers (prior, pruning,
horizons, likelihood weight, variance detector, refractory period); changing any of them starts
a new series alongside the old one rather than overwriting it. Append-only.

**alerts** (`ccy`, `date`, `rule`, `direction`, `p`, `claimed_start`, `k`, `threshold`,
`first_seen_build`). One row per alert ever raised, keyed by currency, week and rule. For the
probability rule, `p` is the probability at the week the spell was confirmed, `claimed_start` the
most probable start of the new regime and `k` the horizon; for the variance rule, `direction` is
`fall` or `rise`, `claimed_start` the beginning of the window within which the change is claimed
to lie and `k` the length of that window in weeks. Append-only; an alert already present for the
same key is not logged again.

**status** (`build_id`, `ccy`, `status`, `regime_since`, `usd_weight`, `r2`, `p_change_26`,
`online_start`, `online_usd_weight`, `last_alert_date`, `last_alert_rule`, `last_prob_alert_date`,
`last_var_alert_date`, `last_var_direction`, `last_obs`). The verdict on every currency at each
build: `New regime` if a probability alert fired within the last 26 weeks of the series,
`Variance change` if only a variance alert did, `Change likely` if the probability is at or above
the threshold without a confirmed spell, `Stable` otherwise, `Data ended` if the series stops more
than 52 weeks before the newest data, `Not available` if the filter could not run. The other
columns are the figures the home page shows with it.

**revisions** (`build_id`, `ccy`, `kind`, `detail`, `old_value`, `new_value`). What changed
between a build and the previous one. A break of the previous build is matched to the nearest
break of the new one within eight weeks: a matched break that moved by more than a week is
`moved`, an unmatched old break `removed`, an unmatched new break `added`; a change of status is
`status`. `detail` is the sentence used in the revisions feed.
