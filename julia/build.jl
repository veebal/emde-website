#!/usr/bin/env julia
# =============================================================================
# build.jl : the single entry point of the site's computation.
#
#   julia --project=julia julia/build.jl                 fetch (cached today) -> date -> filter -> log -> feeds
#   julia --project=julia julia/build.jl --refresh-data  re-download the BIS series first
#   julia --project=julia julia/build.jl --offline       never download, use the cached files
#   julia --project=julia julia/build.jl --notes "text"  a note stored with the build
#   julia --project=julia julia/build.jl --strict        stop if revised data change the stored filter output
#
# All database writes of a build happen in one transaction: a build that fails leaves nothing behind.
#
# Everything is written to data/err.sqlite (see docs/DATABASE.md). The pages are then rendered
# with `quarto render`, which only reads the database. Edit config.yml, not this file, to add
# or change countries and settings.
# =============================================================================
include(joinpath(@__DIR__, "common.jl"))
include(joinpath(@__DIR__, "bocpd.jl"))
include(joinpath(@__DIR__, "variance.jl"))
using .BOCPD, .VarianceCUSUM

const T0 = time()
flags = filter(a -> startswith(a, "--"), ARGS)
notes = let i = findfirst(==("--notes"), ARGS); i === nothing || i == length(ARGS) ? "" : ARGS[i + 1] end
refresh = "--refresh-data" in flags; offline = "--offline" in flags; strict = "--strict" in flags
elapsed() = @sprintf("%.1fs", time() - T0)

# ---- 1. configuration ------------------------------------------------------------------------
cfg = load_config()
countries = country_table(cfg)
anchors = Dict(string(k) => string(v) for (k, v) in cfg["anchor_areas"])
bc = cfg["bocpd"]; ac = bc["alert"]; vs = bc["variance"]
ks = Int.(bc["ks"]); ks == [4, 8, 13, 26, 52] || error("config.yml: bocpd.ks must be [4, 8, 13, 26, 52] (the online table has these columns)")
Int(ac["k"]) in ks || error("config.yml: bocpd.alert.k must be one of bocpd.ks")
engine = engine_version(bc)
config_hash = file_hash([joinpath(ROOT, "config.yml")])
code_hash = file_hash([joinpath(@__DIR__, f) for f in ("common.jl", "bocpd.jl", "variance.jl", "build.jl")])
cn = vcat("(Intercept)", String.(cfg["defaults"]["regressors"]))
cn == ["(Intercept)", "USD", "JPY", "EUR", "GBP"] || error("config.yml: defaults.regressors must be [USD, JPY, EUR, GBP]")
prior = BOCPDPrior(Float64.(bc["mu0"]), Matrix(Diagonal(1 ./ Float64.(bc["prior_sd"]) .^ 2)), Float64(bc["a0"]), Float64(bc["b0"]), Float64(bc["lambda"]))
cw = haskey(bc, "dsm") && bc["dsm"]["c"] !== nothing ? Float64(bc["dsm"]["c"]) : Inf

db = open_db()
prev_build = let r = query(db, "SELECT MAX(build_id) AS b FROM builds"); ismissing(r.b[1]) ? nothing : Int(r.b[1]) end
exec(db, "BEGIN IMMEDIATE")
committed = false
atexit(() -> committed || (exec(db, "ROLLBACK"); println("build failed: nothing was written to the database")))
exec(db, "INSERT INTO builds (built_at, config_hash, code_hash, engine_version, notes) VALUES (?, ?, ?, ?, ?)",
     (Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"), config_hash, code_hash, engine, notes))
build_id = Int(query(db, "SELECT MAX(build_id) AS b FROM builds").b[1])
println("Build $build_id (previous: $(prev_build === nothing ? "none" : prev_build)); engine $engine")
let st = flatten_settings(cfg); st["engine_version"] = engine
    insert_rows(db, "INSERT INTO settings (build_id, key, value) VALUES (?, ?, ?)", ((build_id, k, v) for (k, v) in st))
end
exec(db, "DELETE FROM events")
insert_rows(db, "INSERT INTO events (date, label) VALUES (?, ?)", ((string(asdate(e["date"])), string(e["label"])) for e in get(cfg, "events", [])))

# ---- 2. data ---------------------------------------------------------------------------------
println("BIS data ($(elapsed()))")
panel = bis_panel(cfg, vcat(countries.iso2, collect(values(anchors))); refresh, offline)
# daily LCU per USD of every area, keyed by the currency it quotes
let area_ccy = merge(Dict(zip(countries.iso2, countries.ccy)), Dict(v => k for (k, v) in anchors))
    rows = ((c, string(r.date), r.value, build_id) for (a, c) in area_ccy if haskey(panel, a) for r in eachrow(panel[a]))
    insert_rows(db, "INSERT INTO rates (ccy, date, rate, first_seen_build) VALUES (?, ?, ?, ?) ON CONFLICT (ccy, date) DO UPDATE SET rate = excluded.rate WHERE rate IS NOT excluded.rate", rows)
end

# ---- 3. per-country computation (dating, filter, alerts) -------------------------------------
struct CountryResult
    iso3::String; ccy::String; regs::Vector{String}
    ret::FXSeries; regimes::DataFrame; breakdates::Vector{Date}
    online::Union{DataFrame,Nothing}; note::String
end

function alert_rule(p, dates, start_map, k, threshold, persist, refractory)
    n = length(p); run = zeros(Int, n)
    for i in 1:n; run[i] = p[i] >= threshold ? (i > 1 ? run[i - 1] : 0) + 1 : 0; end
    cand = [i - persist + 1 for i in 1:n if run[i] == persist]        # the first week of the spell
    idx = Int[]; last = -10^9
    for i in cand
        if i - last > refractory; push!(idx, i); last = i; end
    end
    DataFrame(date = dates[idx], p = p[idx .+ persist .- 1], claimed_start = start_map[idx .+ persist .- 1])
end

function compute_country(row, s)
    ccy = row.ccy; regs = [r for r in String.(s["regressors"]) if r != ccy]
    fx = make_fx(panel, row.iso2, ccy, s, anchors)
    size(fx, 1) >= 3 * s["h"] || error("only $(size(fx, 1)) usable daily observations")
    ret = weekly_returns(fx, ccy, regs; frequency = s["frequency"])
    size(ret, 1) >= 3 * s["h"] || error("only $(size(ret, 1)) usable weekly observations")
    # dating (as the lab: FXRegime.fxregimes with h, breaks, ic from the settings)
    note = ""
    reg = try
        fxregimes(ret; h = Int(s["h"]), breaks = Int(s["breaks"]), ic = Symbol(s["ic"]))
    catch e
        note = "fxregimes failed, single regime used: " * sprint(showerror, e); nothing
    end
    regimes, bd = if reg === nothing
        fm = fxlm(ret); d = ret.index
        df = DataFrame(regime = string(d[1], "--", d[end]), start = d[1], var"end" = d[end], n_obs = length(d), r2 = r2(fm))
        for (j, nm) in enumerate(fm.coefnames); df[!, nm] = [coef(fm)[j]]; end
        df, Date[]
    else
        regime_table(reg), breakdates(reg)
    end
    # online filter and variance detector on the same weekly returns
    online = try
        y = ret[:, ccy]; X = hcat(ones(length(y)), [ret[:, r] for r in regs]...)
        ok = .!isnan.(y) .& vec(all(.!isnan.(X), dims = 2))
        y = y[ok]; X = X[ok, :]; dates = ret.index[ok]
        r = bocpd(y, X, prior; prune = Float64(bc["prune"]), ks = ks, c = cw)
        vc = variance_cusum(y, X, r.beta; rho = Float64(vs["rho"]), alpha = Float64(vs["alpha"]), ucap = Float64(vs["ucap"]),
                            refractory = Int(ac["refractory"]), window = Int(vs["window"]))
        out = DataFrame(date = dates)
        for k in ks; out[!, "p_change_$k"] = r.p_change[k]; end
        out.r_map = r.r_map; out.start_map = dates[r.start_map]; out.r_mean = r.r_mean
        out.beta_Intercept = r.beta[:, 1]
        for (j, nm) in enumerate(regs); out[!, "beta_" * nm] = r.beta[:, j + 1]; end
        for nm in cn[2:end]; nm in regs || (out[!, "beta_" * nm] = fill(NaN, length(y))); end
        out.sigma2 = r.sigma2; out.logpred = r.logpred
        out.var_down = vc.down; out.var_up = vc.up; out.var_ref = vc.vref; out.var_alert = vc.alert
        out
    catch e
        note *= (isempty(note) ? "" : " ") * "online filter failed: " * sprint(showerror, e); nothing
    end
    CountryResult(row.iso3, ccy, regs, ret, regimes, bd, online, note)
end

println("Dating and filtering $(nrow(countries)) countries on $(Threads.nthreads()) thread(s) ($(elapsed()))")
results = Vector{Union{CountryResult,String}}(undef, nrow(countries))
Threads.@threads for i in 1:nrow(countries)
    row = countries[i, :]
    results[i] = try
        compute_country(row, row.settings)
    catch e
        sprint(showerror, e)
    end
end

# ---- 4. write: returns (current vintage), regimes and breaks (this build), online (append) ---
const ONLINE_COLS = ["p_change_4", "p_change_8", "p_change_13", "p_change_26", "p_change_52", "r_map", "start_map", "r_mean",
                     "beta_Intercept", "beta_USD", "beta_JPY", "beta_EUR", "beta_GBP", "sigma2", "logpred", "var_down", "var_up", "var_ref", "var_alert"]
const ONLINE_SQL = "INSERT INTO online (ccy, date, engine_version, " * join(lowercase.(ONLINE_COLS), ", ") * ", first_seen_build) VALUES (" *
                   join(fill("?", length(ONLINE_COLS) + 4), ", ") * ")"
same(a, b) = (ismissing(a) && ismissing(b)) || (!ismissing(a) && !ismissing(b) && ((a isa Number && b isa Number) ? (isnan(a) && isnan(b)) || abs(a - b) <= 1e-9 : string(a) == string(b)))

data_revs = Tuple[]      # (ccy, kind, detail, old, new) for weeks whose recomputed filter output differs from the stored one

"""
Append the new weeks of a country's filter output. The weeks already stored for this engine
version are recomputed and compared to 1e-9. They agree unless BIS has revised the daily data
since they were stored; then the stored rows stand (the site never revises what it has said),
the discrepancy is logged as a revision of kind `data`, and only the new weeks are appended.
With --strict a discrepancy stops the build instead.
"""
function store_online!(db, r::CountryResult)
    o = r.online
    old = query(db, "SELECT * FROM online WHERE ccy = ? AND engine_version = ? ORDER BY date", (r.ccy, engine))
    n_old = nrow(old)
    n_old <= nrow(o) || error("$(r.ccy): the database holds $n_old online weeks but the data now give only $(nrow(o))")
    bad = 0; first_bad = nothing; worst = (0.0, "", nothing, nothing)
    for i in 1:n_old
        string(o.date[i]) == old.date[i] || error("$(r.ccy): online week $i is $(o.date[i]) now but $(old.date[i]) in the database")
        differs = false
        for c in ONLINE_COLS
            a = sqlval(o[i, c]); b = old[i, lowercase(c)]
            same(a, b) && continue
            differs = true
            d = (a isa Number && b isa Number) ? abs(a - b) : Inf
            d > worst[1] && (worst = (d, c, b, a))
        end
        if differs
            bad += 1; first_bad === nothing && (first_bad = o.date[i])
        end
    end
    if bad > 0
        msg = @sprintf("%s: revised BIS data change the recomputed filter output on %d of %d stored weeks from %s (largest difference %.3g in %s); stored weeks kept",
                       r.ccy, bad, n_old, first_bad, worst[1], worst[2])
        strict && error(msg * " [--strict]")
        println("  ", msg)
        # the same discrepancy (same stored and recomputed value of the worst week) is logged once, not at every build
        seen = query(db, "SELECT COUNT(*) AS n FROM revisions WHERE ccy = ? AND kind = 'data' AND old_value = ? AND new_value = ?",
                     (r.ccy, string(worst[3]), string(worst[4]))).n[1]
        seen == 0 && push!(data_revs, (r.ccy, "data", msg, string(worst[3]), string(worst[4])))
    end
    rows = ((r.ccy, string(o.date[i]), engine, (sqlval(o[i, c]) for c in ONLINE_COLS)..., build_id) for i in n_old+1:nrow(o))
    insert_rows(db, ONLINE_SQL, rows)
    nrow(o) - n_old
end

n_new_online = 0; n_new_alerts = 0; built = CountryResult[]; failed = Dict{String,String}()
coefcol(df, nm) = nm in names(df) ? df[!, nm] : fill(NaN, nrow(df))
for (i, r) in enumerate(results)
    row = countries[i, :]
    if r isa String
        failed[row.iso3] = r; @printf("  %s: failed (%s)\n", row.iso3, r); continue
    end
    push!(built, r)
    exec(db, "DELETE FROM returns WHERE ccy = ?", (r.ccy,))
    insert_rows(db, "INSERT INTO returns (ccy, date, series, ret) VALUES (?, ?, ?, ?)",
                ((r.ccy, string(r.ret.index[t]), nm, sqlval(r.ret.values[t, j])) for t in 1:length(r.ret.index) for (j, nm) in enumerate(r.ret.names)))
    g = r.regimes
    insert_rows(db, "INSERT INTO regimes (build_id, ccy, regime_no, start_date, end_date, n_obs, r2, b_intercept, b_usd, b_jpy, b_eur, b_gbp, variance) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ((build_id, r.ccy, j, string(g.start[j]), string(g.var"end"[j]), g.n_obs[j], sqlval(g.r2[j]), sqlval(coefcol(g, "(Intercept)")[j]),
                  sqlval(coefcol(g, "USD")[j]), sqlval(coefcol(g, "JPY")[j]), sqlval(coefcol(g, "EUR")[j]), sqlval(coefcol(g, "GBP")[j]), sqlval(coefcol(g, "(Variance)")[j])) for j in 1:nrow(g)))
    insert_rows(db, "INSERT INTO breaks (build_id, ccy, breakdate) VALUES (?, ?, ?)", ((build_id, r.ccy, string(d)) for d in r.breakdates))
    if r.online !== nothing
        global n_new_online += store_online!(db, r)
        # alerts: probability rule and variance rule; a (ccy, date, rule) already logged is never re-logged
        o = r.online; pk = "p_change_$(Int(ac["k"]))"
        a = alert_rule(o[!, pk], o.date, o.start_map, Int(ac["k"]), Float64(ac["threshold"]), Int(ac["persist"]), Int(ac["refractory"]))
        before = query(db, "SELECT COUNT(*) AS n FROM alerts").n[1]
        insert_rows(db, "INSERT OR IGNORE INTO alerts (ccy, date, rule, direction, p, claimed_start, k, threshold, first_seen_build) VALUES (?, ?, 'probability', '', ?, ?, ?, ?, ?)",
                    ((r.ccy, string(a.date[j]), a.p[j], string(a.claimed_start[j]), Int(ac["k"]), Float64(ac["threshold"]), build_id) for j in 1:nrow(a)))
        claim = Int(vs["claim"]); vidx = findall(!=(0), o.var_alert)
        insert_rows(db, "INSERT OR IGNORE INTO alerts (ccy, date, rule, direction, p, claimed_start, k, threshold, first_seen_build) VALUES (?, ?, 'variance', ?, NULL, ?, ?, NULL, ?)",
                    ((r.ccy, string(o.date[t]), o.var_alert[t] < 0 ? "fall" : "rise", string(o.date[max(1, t - claim)]), claim, build_id) for t in vidx))
        global n_new_alerts += query(db, "SELECT COUNT(*) AS n FROM alerts").n[1] - before
    end
    @printf("  %s %s: %d weeks to %s, %d regimes%s%s\n", row.iso3, r.ccy, length(r.ret.index), r.ret.index[end], nrow(r.regimes),
            r.online === nothing ? ", no filter" : "", isempty(r.note) ? "" : " [" * r.note * "]")
end
exec(db, "DELETE FROM countries")
insert_rows(db, "INSERT INTO countries (iso3, iso2, ccy, name, region, sort_order, has_page, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ((c.iso3, c.iso2, c.ccy, c.name, c.region, c.sort_order, haskey(failed, c.iso3) ? 0 : 1,
              haskey(failed, c.iso3) ? failed[c.iso3] : something(findfirst(r -> r.iso3 == c.iso3, built), 0) == 0 ? "" : built[findfirst(r -> r.iso3 == c.iso3, built)].note) for c in eachrow(countries)))

# ---- 5. status of every country --------------------------------------------------------------
recent = Int(get(get(bc, "status", Dict()), "recent_weeks", 26)); stale = Int(get(get(bc, "status", Dict()), "stale_weeks", 52))
pk = "p_change_$(Int(ac["k"]))"
status = DataFrame(ccy = String[], status = String[], regime_since = Any[], usd_weight = Any[], r2 = Any[], p = Any[], online_start = Any[],
                   online_usd = Any[], last_pa = Any[], last_va = Any[], last_vdir = Any[], last_obs = Any[])
for r in built
    g = r.regimes
    if r.online === nothing
        push!(status, (r.ccy, "Not available", string(g.start[end]), sqlval(coefcol(g, "USD")[end]), sqlval(g.r2[end]), missing, missing, missing, missing, missing, missing, string(r.ret.index[end])))
        continue
    end
    o = r.online; last = o[end, :]
    al = query(db, "SELECT date, rule, direction FROM alerts WHERE ccy = ? ORDER BY date", (r.ccy,))
    pa = al[al.rule .== "probability", :]; va = al[al.rule .== "variance", :]
    last_pa = nrow(pa) > 0 ? Date(pa.date[end]) : nothing
    last_va = nrow(va) > 0 ? Date(va.date[end]) : nothing
    weeks(d) = Dates.value(last.date - d) / 7
    st = last_pa !== nothing && weeks(last_pa) <= recent ? "New regime" :
         last_va !== nothing && weeks(last_va) <= recent ? "Variance change" :
         last[pk] >= Float64(ac["threshold"]) ? "Change likely" : "Stable"
    push!(status, (r.ccy, st, string(g.start[end]), sqlval(coefcol(g, "USD")[end]), sqlval(g.r2[end]), last[pk], string(last.start_map),
                   sqlval(coefcol(o, "beta_USD")[end]), last_pa === nothing ? missing : string(last_pa), last_va === nothing ? missing : string(last_va),
                   last_va === nothing ? missing : va.direction[end], string(last.date)))
end
newest = maximum(Date.(status.last_obs))
for i in 1:nrow(status)
    Dates.value(newest - Date(status.last_obs[i])) / 7 > stale && (status.status[i] = "Data ended")
end
last_any(pa, va) = ismissing(pa) ? (ismissing(va) ? (missing, missing) : (va, "variance")) : (ismissing(va) || pa >= va ? (pa, "probability") : (va, "variance"))
insert_rows(db, "INSERT INTO status (build_id, ccy, status, regime_since, usd_weight, r2, p_change_26, online_start, online_usd_weight, last_alert_date, last_alert_rule, last_prob_alert_date, last_var_alert_date, last_var_direction, last_obs) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ((build_id, s.ccy, s.status, s.regime_since, s.usd_weight, s.r2, s.p, s.online_start, s.online_usd, last_any(s.last_pa, s.last_va)..., s.last_pa, s.last_va, s.last_vdir, s.last_obs) for s in eachrow(status)))
exec(db, "UPDATE builds SET data_end = ? WHERE build_id = ?", (string(newest), build_id))

# ---- 6. revisions against the previous build -------------------------------------------------
# a dated break is matched to the nearest previous break within `tol_weeks`; a matched break that
# moved by more than a week is "moved", an unmatched new one "added", an unmatched old one "removed";
# and any change of status is logged.
n_rev = 0
if prev_build !== nothing
    tol_weeks = 8
    oldb = query(db, "SELECT ccy, breakdate FROM breaks WHERE build_id = ?", (prev_build,))
    olds = query(db, "SELECT ccy, status FROM status WHERE build_id = ?", (prev_build,))
    revs = Tuple[]
    for r in built
        n = r.breakdates; o = Date.(oldb.breakdate[oldb.ccy .== r.ccy])
        used = falses(length(n))
        for d in o
            dist = [used[j] ? Inf : abs(Dates.value(n[j] - d)) / 7 for j in eachindex(n)]
            j = isempty(dist) ? 0 : argmin(dist)
            if j > 0 && dist[j] <= tol_weeks
                used[j] = true
                abs(Dates.value(n[j] - d)) > 7 && push!(revs, (r.ccy, "moved", "the break dated $d moved to $(n[j])", string(d), string(n[j])))
            else
                push!(revs, (r.ccy, "removed", "the break dated $d was removed", string(d), ""))
            end
        end
        for j in findall(.!used); push!(revs, (r.ccy, "added", "a break dated $(n[j]) was added", "", string(n[j]))); end
        i = findfirst(==(r.ccy), olds.ccy); k = findfirst(==(r.ccy), status.ccy)
        if i !== nothing && k !== nothing && olds.status[i] != status.status[k]
            push!(revs, (r.ccy, "status", "status changed from '$(olds.status[i])' to '$(status.status[k])'", olds.status[i], status.status[k]))
        end
    end
    append!(revs, data_revs)
    insert_rows(db, "INSERT INTO revisions (build_id, ccy, kind, detail, old_value, new_value) VALUES (?, ?, ?, ?, ?, ?)", ((build_id, v...) for v in revs))
    global n_rev = length(revs)
end

# ---- 7. feeds --------------------------------------------------------------------------------
xml_esc(x) = replace(string(x), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
function write_atom(path, title, subtitle, self_href, entries, updated)
    io = IOBuffer()
    println(io, "<?xml version=\"1.0\" encoding=\"utf-8\"?>")
    println(io, "<feed xmlns=\"http://www.w3.org/2005/Atom\">")
    println(io, "  <title>", xml_esc(title), "</title>")
    println(io, "  <subtitle>", xml_esc(subtitle), "</subtitle>")
    println(io, "  <link href=\"", xml_esc(self_href), "\" rel=\"self\"/>")
    println(io, "  <id>", xml_esc(self_href), "</id>")
    println(io, "  <updated>", updated, "T00:00:00Z</updated>")
    println(io, "  <author><name>XKDR Forum</name></author>")
    for e in entries
        println(io, "  <entry>")
        println(io, "    <title>", xml_esc(e.title), "</title>")
        println(io, "    <link href=\"", xml_esc(e.link), "\"/>")
        println(io, "    <id>", xml_esc(e.id), "</id>")
        println(io, "    <updated>", e.updated, "T00:00:00Z</updated>")
        println(io, "    <summary>", xml_esc(e.summary), "</summary>")
        println(io, "  </entry>")
    end
    println(io, "</feed>")
    write(path, take!(io))
end
let site = string(get(cfg, "site_url", "")), base = isempty(site) ? "." : rstrip(site, '/'), maxn = 100
    mkpath(joinpath(ROOT, "feeds"))
    page(iso3) = "$base/countries/$iso3/index.html"
    a = query(db, "SELECT a.*, c.iso3, c.name FROM alerts a JOIN countries c ON c.ccy = a.ccy ORDER BY a.date DESC, c.iso3 LIMIT ?", (maxn,))
    ea = map(eachrow(a)) do r
        if r.rule == "variance"
            vword = r.direction == "fall" ? "fell" : "rose"; vband = r.direction == "fall" ? "narrowed" : "widened"
            (id = "$base/alerts/variance/$(r.iso3)/$(r.date)", title = "$(r.name) ($(r.ccy)): variance $vword — the band $vband (alert $(r.date))", link = page(r.iso3), updated = r.date,
             summary = "$(r.ccy): variance $vword — the band $vband (alert $(r.date)). Rule: variance. The CUSUM statistic for a $(r.direction) in the residual variance of the $(r.ccy) crossed its threshold at the $(r.date) observation; the change is claimed to lie within the previous $(r.k) weeks, from $(r.claimed_start).")
        else
            (id = "$base/alerts/$(r.iso3)/$(r.date)", title = "$(r.name) ($(r.ccy)): new exchange rate regime likely, $(r.date)", link = page(r.iso3), updated = r.date,
             summary = @sprintf("%s: new regime likely (alert %s). Rule: probability. Probability %.3f that the %s regime changed within the last %d weeks; most probable start of the new regime %s. Alert fired at the %s observation.",
                                r.ccy, r.date, r.p, r.ccy, r.k, r.claimed_start, r.date))
        end
    end
    write_atom(joinpath(ROOT, "feeds", "alerts.xml"), "Exchange rate regimes: alerts",
               "Online alerts of a likely change in a currency's basket regime or in its residual variance", "$base/feeds/alerts.xml", ea, string(today()))
    rv = query(db, "SELECT r.*, substr(b.built_at, 1, 10) AS build_date, c.iso3, c.name FROM revisions r JOIN builds b ON b.build_id = r.build_id JOIN countries c ON c.ccy = r.ccy ORDER BY r.build_id DESC, c.iso3 LIMIT ?", (maxn,))
    kindword(k) = k == "data" ? "data revision" : k == "status" ? "status change" : "break " * k
    er = [(id = "$base/revisions/$(r.iso3)/$(r.build_date)/$(r.kind)/" * (r.kind == "data" ? "" : "$(coalesce(r.old_value, ""))$(coalesce(r.new_value, ""))"),
           title = "$(r.name) ($(r.ccy)): $(kindword(r.kind)), build of $(r.build_date)", link = page(r.iso3), updated = r.build_date,
           summary = "With the data available on $(r.build_date), $(r.detail).") for r in eachrow(rv)]
    write_atom(joinpath(ROOT, "feeds", "revisions.xml"), "Exchange rate regimes: revisions",
               "Retrospective changes to dated regime breaks and to country statuses between builds", "$base/feeds/revisions.xml", er, string(today()))
end

# ---- 8. pages: one index.qmd per country from the template, and the sidebar ------------------
let tpl = read(joinpath(ROOT, "templates", "country.qmd.tpl"), String)
    for r in built
        c = countries[findfirst(==(r.iso3), countries.iso3), :]
        dir = joinpath(ROOT, "countries", r.iso3); mkpath(dir)
        write(joinpath(dir, "index.qmd"), replace(tpl, "{{name}}" => c.name, "{{iso3}}" => r.iso3, "{{ccy}}" => r.ccy))
    end
    for d in readdir(joinpath(ROOT, "countries"))
        d in [r.iso3 for r in built] || rm(joinpath(ROOT, "countries", d); recursive = true, force = true)
    end
    io = IOBuffer(); println(io, "# GENERATED by julia/build.jl - do not edit"); println(io, "website:\n  sidebar:\n    contents:")
    m = countries[[c.iso3 in [r.iso3 for r in built] for c in eachrow(countries)], :]
    for region in sort(unique(m.region))
        println(io, "    - section: ", repr(region)); println(io, "      contents:")
        for c in eachrow(sort(m[m.region .== region, :], :name))
            println(io, "      - href: countries/", c.iso3, "/index.qmd"); println(io, "        text: ", repr(c.name))
        end
    end
    write(joinpath(ROOT, "_sidebar.yml"), take!(io))
end

# ---- 9. commit and report --------------------------------------------------------------------
exec(db, "COMMIT"); committed = true
exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
println("\n--- Build $build_id ---")
println("data to $newest; $(length(built)) of $(nrow(countries)) countries have pages", isempty(failed) ? "" : "; failed: " * join(sort(collect(keys(failed))), ", "))
for st in ["New regime", "Variance change", "Change likely", "Stable", "Data ended", "Not available"]
    n = count(==(st), status.status); n > 0 && println("  $st: $n")
end
println("new online rows: $n_new_online; new alerts: $n_new_alerts; revisions: $n_rev")
println("done in $(elapsed())")
