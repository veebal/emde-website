# ---------------------------------------------------------------------------
# db.R : read-only access to data/err.sqlite from the Quarto pages. The pages do no
# computation; every number they show is a query against the database written by
# julia/build.jl (schema in docs/DATABASE.md).
# ---------------------------------------------------------------------------
if (!requireNamespace("RSQLite", quietly = TRUE)) install.packages("RSQLite", repos = "https://cloud.r-project.org")
if (!requireNamespace("DBI", quietly = TRUE)) install.packages("DBI", repos = "https://cloud.r-project.org")

`%||%` <- function(a, b) if (is.null(a)) b else a

# The database path, found by walking up from the directory of the page being rendered.
err_db_path <- function() {
  d <- normalizePath(getwd())
  for (i in 1:6) {
    f <- file.path(d, "data", "err.sqlite")
    if (file.exists(f)) return(f)
    d <- dirname(d)
  }
  stop("data/err.sqlite not found: run `julia --project=julia julia/build.jl` first")
}
err_con <- function() DBI::dbConnect(RSQLite::SQLite(), err_db_path(), flags = RSQLite::SQLITE_RO)
q <- function(con, sql, ...) { p <- list(...); if (length(p)) DBI::dbGetQuery(con, sql, params = p) else DBI::dbGetQuery(con, sql) }

# The latest build and its settings
latest_build <- function(con) q(con, "SELECT * FROM builds WHERE data_end IS NOT NULL ORDER BY build_id DESC LIMIT 1")
setting <- function(con, build_id, key, numeric = TRUE) {
  v <- q(con, "SELECT value FROM settings WHERE build_id = ? AND key = ?", build_id, key)$value
  if (!length(v)) return(NULL)
  if (numeric) as.numeric(v) else v
}
setting_list <- function(con, build_id, key) as.numeric(jsonlite::fromJSON(setting(con, build_id, key, numeric = FALSE)))

# Settings of the online filter and the rules, as one list (mirrors the config.yml `bocpd` block)
bocpd_settings <- function(con, build_id) {
  g <- function(k) setting(con, build_id, paste0("bocpd.", k))
  list(alert = list(k = g("alert.k"), threshold = g("alert.threshold"), persist = g("alert.persist"), refractory = g("alert.refractory")),
       variance = list(rho = g("variance.rho"), alpha = g("variance.alpha"), ucap = g("variance.ucap"), window = g("variance.window"), claim = g("variance.claim")),
       status = list(recent_weeks = g("status.recent_weeks") %||% 26, stale_weeks = g("status.stale_weeks") %||% 52),
       engine_version = setting(con, build_id, "engine_version", numeric = FALSE))
}

# --- queries used by the pages --------------------------------------------------------------
as_date_cols <- function(d, cols) { for (c in intersect(cols, names(d))) d[[c]] <- as.Date(d[[c]]); d }

status_all <- function(con, build_id) {
  d <- q(con, "SELECT s.*, c.iso3, c.name AS country, c.sort_order FROM status s JOIN countries c ON c.ccy = s.ccy WHERE s.build_id = ? ORDER BY c.sort_order", build_id)
  as_date_cols(d, c("regime_since", "online_start", "last_alert_date", "last_prob_alert_date", "last_var_alert_date", "last_obs"))
}
regimes_all <- function(con, build_id) {
  d <- q(con, "SELECT r.*, c.iso3, c.name AS country FROM regimes r JOIN countries c ON c.ccy = r.ccy WHERE r.build_id = ? ORDER BY c.sort_order, r.regime_no", build_id)
  as_date_cols(d, c("start_date", "end_date"))
}
regimes_ccy <- function(con, build_id, ccy) as_date_cols(q(con, "SELECT * FROM regimes WHERE build_id = ? AND ccy = ? ORDER BY regime_no", build_id, ccy), c("start_date", "end_date"))
breaks_ccy  <- function(con, build_id, ccy) as.Date(q(con, "SELECT breakdate FROM breaks WHERE build_id = ? AND ccy = ? ORDER BY breakdate", build_id, ccy)$breakdate)
level_ccy   <- function(con, ccy, from) as_date_cols(q(con, "SELECT date, rate FROM rates WHERE ccy = ? AND date >= ? ORDER BY date", ccy, as.character(from)), "date")
online_ccy  <- function(con, ccy, engine) as_date_cols(q(con, "SELECT * FROM online WHERE ccy = ? AND engine_version = ? ORDER BY date", ccy, engine), c("date", "start_map"))
alerts_ccy  <- function(con, ccy) as_date_cols(q(con, "SELECT a.*, c.iso3 FROM alerts a JOIN countries c ON c.ccy = a.ccy WHERE a.ccy = ? ORDER BY a.date DESC", ccy), c("date", "claimed_start"))
alerts_all  <- function(con, n = NULL) as_date_cols(q(con, sprintf("SELECT a.*, c.iso3 FROM alerts a JOIN countries c ON c.ccy = a.ccy ORDER BY a.date DESC, c.iso3%s", if (is.null(n)) "" else sprintf(" LIMIT %d", n))), c("date", "claimed_start"))
revisions_ccy <- function(con, ccy) q(con, "SELECT r.*, substr(b.built_at, 1, 10) AS build_date, c.iso3 FROM revisions r JOIN builds b ON b.build_id = r.build_id JOIN countries c ON c.ccy = r.ccy WHERE r.ccy = ? ORDER BY r.build_id DESC", ccy)
revisions_all <- function(con, n = NULL) q(con, sprintf("SELECT r.*, substr(b.built_at, 1, 10) AS build_date, c.iso3 FROM revisions r JOIN builds b ON b.build_id = r.build_id JOIN countries c ON c.ccy = r.ccy ORDER BY r.build_id DESC, c.iso3%s", if (is.null(n)) "" else sprintf(" LIMIT %d", n)))
events_all  <- function(con) as_date_cols(q(con, "SELECT date, label FROM events ORDER BY date"), "date")
country_row <- function(con, iso3) q(con, "SELECT * FROM countries WHERE iso3 = ?", iso3)
returns_range <- function(con, ccy) as_date_cols(q(con, "SELECT MIN(date) AS start, MAX(date) AS end FROM returns WHERE ccy = ?", ccy), c("start", "end"))
