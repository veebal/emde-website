#!/usr/bin/env julia
# =============================================================================
# reproduce.jl : reproduce the dating and the online filter of one currency from the weekly
# returns stored in data/err.sqlite, with the settings of the latest build, and write
#   data/export/reproduce_<CCY>_regimes.csv  and  data/export/reproduce_<CCY>_online.csv
# so that a reader can check the numbers on a country page against the code in this folder.
#   julia --project=julia julia/reproduce.jl INR
# =============================================================================
include(joinpath(@__DIR__, "common.jl"))
include(joinpath(@__DIR__, "bocpd.jl"))
include(joinpath(@__DIR__, "variance.jl"))
using .BOCPD, .VarianceCUSUM

length(ARGS) == 1 || error("usage: julia --project=julia julia/reproduce.jl <CCY>")
ccy = uppercase(ARGS[1])
cfg = load_config(); bc = cfg["bocpd"]; ac = bc["alert"]; vs = bc["variance"]
c = cfg["countries"][findfirst(e -> uppercase(string(e["ccy"])) == ccy, cfg["countries"])]
s = merge(cfg["defaults"], Dict(k => v for (k, v) in c if !(k in ("code", "iso3", "ccy", "name", "region"))))

db = SQLite.DB(DB_PATH)
r = query(db, "SELECT date, series, ret FROM returns WHERE ccy = ? ORDER BY date", (ccy,))
nrow(r) > 0 || error("no returns stored for $ccy; run julia/build.jl first")
regs = [x for x in String.(s["regressors"]) if x != ccy]
cols = vcat(ccy, regs); dates = sort(unique(Date.(r.date)))
vals = fill(NaN, length(dates), length(cols)); di = Dict(d => i for (i, d) in enumerate(dates)); cj = Dict(c => j for (j, c) in enumerate(cols))
for x in eachrow(r); ismissing(x.ret) || (vals[di[Date(x.date)], cj[x.series]] = x.ret); end
ret = FXSeries(dates, cols, vals)

reg = fxregimes(ret; h = Int(s["h"]), breaks = Int(s["breaks"]), ic = Symbol(s["ic"]))
tab = regime_table(reg)
println("Dated breaks: ", join(string.(breakdates(reg)), ", ")); show(stdout, MIME"text/plain"(), tab); println()

prior = BOCPDPrior(Float64.(bc["mu0"]), Matrix(Diagonal(1 ./ Float64.(bc["prior_sd"]) .^ 2)), Float64(bc["a0"]), Float64(bc["b0"]), Float64(bc["lambda"]))
y = ret[:, ccy]; X = hcat(ones(length(y)), [ret[:, x] for x in regs]...)
ks = Int.(bc["ks"])
f = bocpd(y, X, prior; prune = Float64(bc["prune"]), ks = ks, c = Float64(bc["dsm"]["c"]))
vc = variance_cusum(y, X, f.beta; rho = Float64(vs["rho"]), alpha = Float64(vs["alpha"]), ucap = Float64(vs["ucap"]),
                    refractory = Int(ac["refractory"]), window = Int(vs["window"]))
out = DataFrame(date = dates)
for k in ks; out[!, "p_change_$k"] = f.p_change[k]; end
out.r_map = f.r_map; out.start_map = dates[f.start_map]; out.r_mean = f.r_mean
out.beta_Intercept = f.beta[:, 1]
for (j, nm) in enumerate(regs); out[!, "beta_" * nm] = f.beta[:, j + 1]; end
out.sigma2 = f.sigma2; out.logpred = f.logpred
out.var_down = vc.down; out.var_up = vc.up; out.var_ref = vc.vref; out.var_alert = vc.alert
@printf("Latest week %s: P(change within %d weeks) = %.3f, most probable start %s\n", dates[end], Int(ac["k"]), out[end, "p_change_$(Int(ac["k"]))"], out.start_map[end])

ex = joinpath(ROOT, "data", "export"); mkpath(ex)
CSV.write(joinpath(ex, "reproduce_$(ccy)_regimes.csv"), tab); CSV.write(joinpath(ex, "reproduce_$(ccy)_online.csv"), out)
println("written data/export/reproduce_$(ccy)_regimes.csv and data/export/reproduce_$(ccy)_online.csv")
