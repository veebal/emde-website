# =============================================================================
# common.jl : shared helpers for the site build. `include`d by build.jl, export.jl and
# reproduce.jl. Configuration, the BIS download, the per-country data set, the dating
# table (as in the lab's JULIA/common.jl) and the SQLite layer.
# =============================================================================
using CSV, DataFrames, Dates, HTTP, JSON3, SQLite, DBInterface, SHA, YAML, Statistics,
      LinearAlgebra, Printf, FXRegime

const ROOT    = normpath(joinpath(@__DIR__, ".."))
const DB_PATH = joinpath(ROOT, "data", "err.sqlite")
const BIS_DIR = joinpath(ROOT, "data", "raw", "bis")

load_config() = YAML.load_file(joinpath(ROOT, "config.yml"); dicttype = Dict{String,Any})

# ---- countries and settings ---------------------------------------------------------------
"One row per configured country; `settings` merges `defaults` with the entry's overrides."
function country_table(cfg)
    df = DataFrame(iso2 = String[], iso3 = String[], ccy = String[], name = String[], region = String[],
                   sort_order = Int[], settings = Any[])
    meta = Set(["code", "iso3", "ccy", "name", "region"])
    for (i, e) in enumerate(cfg["countries"])
        e isa AbstractDict || error("config.yml: every country needs code, iso3, ccy, name and region; got $(e)")
        s = merge(cfg["defaults"], Dict(k => v for (k, v) in e if !(k in meta)))
        push!(df, (uppercase(string(e["code"])), uppercase(string(e["iso3"])), uppercase(string(e["ccy"])),
                   string(e["name"]), string(get(e, "region", "Other")), i, s))
    end
    allunique(df.iso3) || error("config.yml: duplicate iso3 codes")
    allunique(df.ccy)  || error("config.yml: duplicate currency codes")
    df
end

asdate(x) = x isa Date ? x : Date(string(x))

# ---- BIS download: one request per reference area, cached under data/raw/bis/ --------------
bis_url(area, from) = "https://stats.bis.org/api/v2/data/dataflow/BIS/WS_XRU/1.0/D.$(area)..A?format=csv&startPeriod=$(from)"

"""
    fetch_bis_area(area, from; refresh, offline) -> path of the cached CSV ("" if no data)

The cache is reused when it was written today, unless `refresh`; with `offline` nothing is
downloaded. A series BIS does not publish (HTTP 404) is cached as an empty file.
"""
function fetch_bis_area(area::AbstractString, from; refresh = false, offline = false)
    mkpath(BIS_DIR)
    f = joinpath(BIS_DIR, area * ".csv")
    fresh = isfile(f) && Date(unix2datetime(mtime(f))) == today()
    if offline || (fresh && !refresh)
        isfile(f) || error("$area: no cached BIS file and --offline given")
        return f
    end
    for attempt in 1:4
        try
            r = HTTP.get(bis_url(area, from); connect_timeout = 30, readtimeout = 300, status_exception = false, retry = false)
            if r.status == 200 && length(r.body) > 0
                write(f, r.body); println("  fetched $area"); return f
            elseif r.status == 404
                write(f, ""); println("  $area: no BIS data"); return f
            else
                println("  $area: attempt $attempt failed (HTTP $(r.status))")
            end
        catch e
            println("  $area: attempt $attempt failed ($(sprint(showerror, e)))")
        end
        sleep(2attempt)
    end
    isfile(f) && (println("  $area: using the cached file"); return f)
    error("could not download BIS area $area")
end

"Daily LCU-per-USD series of one area as a DataFrame(date, value); first value per date, NaN dropped."
function read_bis_area(path::AbstractString)
    (isfile(path) && filesize(path) > 1) || return DataFrame(date = Date[], value = Float64[])
    raw = CSV.read(path, DataFrame; select = ["TIME_PERIOD", "OBS_VALUE"], types = String)
    out = DataFrame(date = Date[], value = Float64[]); seen = Set{Date}()
    for r in eachrow(raw)
        (ismissing(r.TIME_PERIOD) || ismissing(r.OBS_VALUE)) && continue
        v = tryparse(Float64, r.OBS_VALUE); d = tryparse(Date, r.TIME_PERIOD)
        (v === nothing || d === nothing || isnan(v)) && continue
        d in seen && continue
        push!(seen, d); push!(out, (d, v))
    end
    sort!(out, :date)
end

"Dict area => DataFrame(date, value) for every area, fetching as needed."
function bis_panel(cfg, areas; refresh = false, offline = false)
    from = cfg["bis"]["from"]
    Dict(a => read_bis_area(fetch_bis_area(a, from; refresh, offline)) for a in sort(unique(areas)))
end

"""
    make_fx(panel, area, ccy, s, anchors) -> FXSeries

Daily levels in numeraire units (ccy, USD, then the other regressors), as the site's R
`make_fx_data`: ccy = area / numeraire, USD = 1 / numeraire, JPY = JP / numeraire, ...;
restricted to `s["start"]`..`s["end"]` and to days on which every column is observed.
"""
function make_fx(panel, area, ccy, s, anchors)
    num_area = get(anchors, s["numeraire"], nothing)
    (num_area === nothing || !haskey(panel, num_area)) && error("numeraire $(s["numeraire"]) not available in BIS data")
    haskey(panel, area) && nrow(panel[area]) > 0 || error("no BIS series found (ref area $area)")
    regs = [r for r in String.(s["regressors"]) if r != ccy]
    cols = unique(vcat(ccy, "USD", regs))
    lookup(a) = Dict(zip(panel[a].date, panel[a].value))
    num = lookup(num_area); own = lookup(area)
    others = Dict{String,Dict{Date,Float64}}()
    for r in regs
        r == "USD" && continue
        a = get(anchors, r, nothing)
        (a === nothing || !haskey(panel, a)) && error("regressor $r has no BIS area in anchor_areas")
        others[r] = lookup(a)
    end
    start = asdate(s["start"]); stop = s["end"] === nothing ? Date(9999) : asdate(s["end"])
    dates = Date[]; vals = Vector{Float64}[]
    for d in sort(collect(keys(num)))
        (d < start || d > stop) && continue
        haskey(own, d) || continue
        row = Float64[]
        ok = true
        for c in cols
            v = c == ccy ? own[d] / num[d] : c == "USD" ? 1 / num[d] : (haskey(others[c], d) ? others[c][d] / num[d] : NaN)
            isnan(v) && (ok = false; break)
            push!(row, v)
        end
        ok || continue
        push!(dates, d); push!(vals, row)
    end
    FXSeries(dates, cols, isempty(vals) ? zeros(0, length(cols)) : reduce(vcat, permutedims.(vals)))
end

"""
    weekly_returns(fx, ccy, regs) -> FXSeries

Friday-anchored weekly log returns in per cent (FXRegime.fxreturns, as the lab). The final
week is dropped when its Friday lies after the last daily observation, so that a week whose
value could still change when more days arrive never enters the database.
"""
function weekly_returns(fx::FXSeries, ccy, regs; frequency = :weekly)
    ret = fxreturns(ccy, regs, fx; frequency = Symbol(frequency), start = first(fx.index), stop = last(fx.index))
    n = length(ret.index)
    if n > 0 && ret.index[end] > last(fx.index)
        ret = FXSeries(ret.index[1:n-1], ret.names, ret.values[1:n-1, :])
    end
    ret
end

# ---- dating table, as the lab's regime_table ----------------------------------------------
function regime_table(reg::FXRegimes)
    dates = index(reg); n = length(dates)
    bp, _ = breakpoints(reg)
    starts = vcat(1, bp .+ 1); ends = vcat(bp, n)
    cm = coef(reg); cn = coefnames(reg)
    fits = refit(reg)
    df = DataFrame(regime = [string(dates[s], "--", dates[e]) for (s, e) in zip(starts, ends)],
                   start = dates[starts], var"end" = dates[ends], n_obs = ends .- starts .+ 1,
                   r2 = [r2(f) for f in fits])
    for (j, name) in enumerate(cn)
        df[!, name] = cm[:, j]
    end
    df
end

# ---- hashes ---------------------------------------------------------------------------------
shorthash(s::AbstractString) = bytes2hex(sha256(s))[1:12]
file_hash(paths) = shorthash(join([read(p, String) for p in paths], "\n"))

"Hash of the settings that determine the filter output (prior, pruning, horizons, weight, variance detector)."
function engine_version(bc)
    vs = bc["variance"]
    parts = [("mu0", bc["mu0"]), ("prior_sd", bc["prior_sd"]), ("a0", bc["a0"]), ("b0", bc["b0"]), ("lambda", bc["lambda"]),
             ("prune", bc["prune"]), ("ks", bc["ks"]), ("c", get(get(bc, "dsm", Dict()), "c", nothing)),
             ("variance", [vs["rho"], vs["alpha"], vs["ucap"], vs["window"]]), ("refractory", bc["alert"]["refractory"])]
    shorthash(JSON3.write(parts))
end

# ---- SQLite ---------------------------------------------------------------------------------
const SCHEMA = [
    """CREATE TABLE IF NOT EXISTS builds (
         build_id INTEGER PRIMARY KEY, built_at TEXT NOT NULL, data_end TEXT, config_hash TEXT, code_hash TEXT,
         engine_version TEXT, notes TEXT)""",
    """CREATE TABLE IF NOT EXISTS settings (build_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT,
         PRIMARY KEY (build_id, key))""",
    """CREATE TABLE IF NOT EXISTS countries (iso3 TEXT PRIMARY KEY, iso2 TEXT, ccy TEXT UNIQUE, name TEXT, region TEXT,
         sort_order INTEGER, has_page INTEGER NOT NULL DEFAULT 1, note TEXT)""",
    """CREATE TABLE IF NOT EXISTS events (date TEXT NOT NULL, label TEXT NOT NULL)""",
    """CREATE TABLE IF NOT EXISTS rates (ccy TEXT NOT NULL, date TEXT NOT NULL, rate REAL NOT NULL,
         first_seen_build INTEGER NOT NULL, PRIMARY KEY (ccy, date))""",
    """CREATE TABLE IF NOT EXISTS returns (ccy TEXT NOT NULL, date TEXT NOT NULL, series TEXT NOT NULL, ret REAL,
         PRIMARY KEY (ccy, date, series))""",
    """CREATE TABLE IF NOT EXISTS regimes (build_id INTEGER NOT NULL, ccy TEXT NOT NULL, regime_no INTEGER NOT NULL,
         start_date TEXT, end_date TEXT, n_obs INTEGER, r2 REAL, b_intercept REAL, b_usd REAL, b_jpy REAL, b_eur REAL,
         b_gbp REAL, variance REAL, PRIMARY KEY (build_id, ccy, regime_no))""",
    """CREATE TABLE IF NOT EXISTS breaks (build_id INTEGER NOT NULL, ccy TEXT NOT NULL, breakdate TEXT NOT NULL,
         PRIMARY KEY (build_id, ccy, breakdate))""",
    """CREATE TABLE IF NOT EXISTS online (ccy TEXT NOT NULL, date TEXT NOT NULL, engine_version TEXT NOT NULL,
         p_change_4 REAL, p_change_8 REAL, p_change_13 REAL, p_change_26 REAL, p_change_52 REAL,
         r_map INTEGER, start_map TEXT, r_mean REAL, beta_intercept REAL, beta_usd REAL, beta_jpy REAL, beta_eur REAL,
         beta_gbp REAL, sigma2 REAL, logpred REAL, var_down REAL, var_up REAL, var_ref REAL, var_alert INTEGER,
         first_seen_build INTEGER NOT NULL, PRIMARY KEY (ccy, date, engine_version))""",
    """CREATE TABLE IF NOT EXISTS alerts (ccy TEXT NOT NULL, date TEXT NOT NULL, rule TEXT NOT NULL, direction TEXT,
         p REAL, claimed_start TEXT, k INTEGER, threshold REAL, first_seen_build INTEGER NOT NULL,
         PRIMARY KEY (ccy, date, rule))""",
    """CREATE TABLE IF NOT EXISTS status (build_id INTEGER NOT NULL, ccy TEXT NOT NULL, status TEXT NOT NULL,
         regime_since TEXT, usd_weight REAL, r2 REAL, p_change_26 REAL, online_start TEXT, online_usd_weight REAL,
         last_alert_date TEXT, last_alert_rule TEXT, last_prob_alert_date TEXT, last_var_alert_date TEXT,
         last_var_direction TEXT, last_obs TEXT, PRIMARY KEY (build_id, ccy))""",
    """CREATE TABLE IF NOT EXISTS revisions (build_id INTEGER NOT NULL, ccy TEXT NOT NULL, kind TEXT NOT NULL,
         detail TEXT, old_value TEXT, new_value TEXT)""",
    "CREATE INDEX IF NOT EXISTS online_ccy_date ON online (ccy, engine_version, date)",
    "CREATE INDEX IF NOT EXISTS rates_ccy_date ON rates (ccy, date)",
]

function open_db(path = DB_PATH)
    mkpath(dirname(path))
    db = SQLite.DB(path)
    DBInterface.execute(db, "PRAGMA journal_mode = WAL"); DBInterface.execute(db, "PRAGMA synchronous = NORMAL")
    foreach(sql -> DBInterface.execute(db, sql), SCHEMA)
    db
end

exec(db, sql, params = ()) = DBInterface.execute(db, sql, params)
query(db, sql, params = ()) = DataFrame(DBInterface.execute(db, sql, params))

"Insert many rows (an iterable of tuples) with one prepared statement inside a transaction."
function insert_rows(db, sql, rows)
    stmt = DBInterface.prepare(db, sql)
    SQLite.transaction(db) do
        for r in rows
            DBInterface.execute(stmt, r)
        end
    end
    DBInterface.close!(stmt)
end

sqlval(x::Date) = string(x)
sqlval(x::Nothing) = missing
sqlval(x::Float64) = isnan(x) ? missing : x
sqlval(x) = x

table_names(db) = query(db, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").name

"Flatten the configuration (all but the country list) into dotted keys; lists are stored as JSON."
function flatten_settings(cfg)
    out = Dict{String,String}()
    walk(prefix, v) = begin
        if v isa AbstractDict
            for (k, x) in v; walk(prefix == "" ? string(k) : prefix * "." * string(k), x); end
        elseif v isa AbstractVector
            out[prefix] = JSON3.write(v)
        else
            out[prefix] = v === nothing ? "" : string(v)
        end
    end
    for (k, v) in cfg
        k == "countries" && continue
        walk(string(k), v)
    end
    out
end
