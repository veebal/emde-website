# Exchange rate regimes

A Quarto website that dates the de facto exchange rate regimes of emerging market currencies
and watches, week by week, for the next change. Computation is in Julia; the pages only read
the results.

## Building the site

Two commands, run from the repository root:

```sh
julia --project=julia julia/build.jl     # fetch BIS data, date, filter, log, feeds, pages
~/opt/quarto/bin/quarto render           # render the site from the database
```

The first command needs Julia 1.12 and, the first time, an internet connection to install the
packages listed in `julia/Project.toml` (`FXRegime.jl` is installed from GitHub). It downloads the
BIS series it does not already have from today (`--refresh-data` forces a download, `--offline`
never downloads), dates the regimes of every currency in `config.yml`, runs the online filter and
the variance detector, logs alerts, statuses and revisions, writes the two Atom feeds under
`feeds/`, one `index.qmd` per country under `countries/` and the sidebar. It takes about half a
minute on one thread; `JULIA_NUM_THREADS=auto` spreads the countries over the cores.

The second command needs R with the packages the pages load (`pacman`, `DBI`, `RSQLite`,
`jsonlite`, `dplyr`, `ggplot2`, `scales`, `plotly`, `knitr`, `htmlwidgets`); `R/db.R` installs
`RSQLite` and `DBI` into the user library if they are missing. The pages compute nothing: every
figure, table and sentence is a query against the database.

## Where things are

- `config.yml`: the only file to edit. Countries (BIS reference area, ISO3, currency, name,
  region), the regression and dating settings, the filter's fixed prior and the alert, variance
  and status rules.
- `data/err.sqlite`: the database, not committed. Its schema and invariants are in
  `docs/DATABASE.md`. The online filter output and the alerts are append-only; every build's
  dating and status are kept.
- `julia/`: `build.jl` (the entry point), `common.jl` (configuration, BIS download, data set,
  dating table, database layer), `bocpd.jl` and `variance.jl` (the filter and the variance
  detector, copied verbatim from the research lab), `export.jl` and `reproduce.jl`.
- `R/db.R` and `R/plots.R`: the queries and the charts used by the pages.
- `templates/country.qmd.tpl`: the country page, filled in by the build.
- `feeds/alerts.xml`, `feeds/revisions.xml`: written by the build from the `alerts` and
  `revisions` tables.

## Exporting

`julia --project=julia julia/export.jl` writes every table to CSV under `data/export/`
(`julia/export.jl online alerts` for a subset). `julia --project=julia julia/reproduce.jl INR`
reproduces one currency's dating and filter from the stored returns and writes the two tables
to `data/export/`. The country pages also offer their dated-regime table and filter output as
CSV, written next to the page at render time.

## Notifications

`.github/workflows/notify.yml` emails the newest entries of both feeds when started by hand;
see the comments in that file for the secrets it needs.

## Email sign-up

The site is static, so subscriber addresses are held by a newsletter service that turns each feed into email. The default is Buttondown: create one newsletter for alerts and one for revisions, set each newsletter's RSS-to-email source to the corresponding feed address (`<site_url>/feeds/alerts.xml`, `<site_url>/feeds/revisions.xml`), and enter the two newsletter usernames under `subscribe:` in `config.yml`. The subscribe page then shows a sign-up form for each; while the usernames are empty it shows the feed addresses only. The GitHub workflow `notify.yml` remains as a manual fallback that emails the newest entries to a fixed list.
