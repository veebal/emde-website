# =============================================================================
# bocpd.jl : Bayesian online change-point detection (Adams and MacKay, 2007) for the
# Frankel-Wei regression  y_t = x_t'beta + e_t,  e_t ~ N(0, sigma2), with the conjugate
# normal-inverse-gamma prior  beta | sigma2 ~ N(mu0, sigma2 * inv(Lambda0)),
# sigma2 ~ IG(a0, b0), and a constant hazard H = 1/lambda for a new regime.
#
# At each t the filter carries, for every run length r (the number of observations since
# the last change), the posterior sufficient statistics of the regression on those r
# observations and the probability P(r_t = r | y_1:t). The predictive density of y_t given
# a run of length r is Student-t. No quantity reported at t uses data after t, so nothing
# is ever revised.
#
# Exact (no pruning) cost is O(T^2) predictive evaluations; T = 1,700 weekly observations
# takes about a second. `prune` drops run lengths whose posterior mass falls below a
# threshold, which keeps the cost linear in practice; set it to 0 for the exact filter.
# =============================================================================
module BOCPD
using LinearAlgebra, SpecialFunctions, Statistics
export BOCPDPrior, bocpd, bocpd_prior_from_regimes

struct BOCPDPrior
    mu0::Vector{Float64}
    Lambda0::Matrix{Float64}
    a0::Float64
    b0::Float64
    lambda::Float64      # expected regime length in observations; hazard = 1/lambda
end

"Student-t log density of y with df nu, location m, scale^2 s2."
function logpred_t(y, nu, m, s2)
    z2 = (y - m)^2 / s2
    loggamma((nu + 1) / 2) - loggamma(nu / 2) - 0.5 * log(nu * pi * s2) - (nu + 1) / 2 * log1p(z2 / nu)
end

"""
    bocpd(y, X, prior; prune = 1e-10, ks = [4, 8, 13, 26, 52], c = Inf)

Run the filter. With finite `c` the likelihood of each observation under a run is raised to
the power w = 1 / (1 + (u/c)^2), where u is the observation's standardised one-step residual
under that run's own predictive (the weight of the diffusion score-matching posterior,
Altamirano, Briol and Knoblauch, 2023, applied to the Gaussian likelihood): the sufficient
statistics accumulate w x x', w x y, w y^2 and w, so the posterior stays normal-inverse-gamma
and the predictive Student-t, and one extreme week cannot carry a run on its own. `X` is T x p with an intercept column. Returns a NamedTuple of per-period
vectors: `p_change[k]` = P(run length < k) i.e. a change within the last k observations,
`r_map` the most probable run length, `r_mean` its posterior mean, `beta` the posterior-mean
coefficients (mixture over run lengths, T x p), `sigma2` the posterior-mean variance,
`logpred` the one-step predictive log density of y_t (for scoring), and `start_map` the
most probable start of the current regime as an index.
"""
function bocpd(y::AbstractVector{<:Real}, X::AbstractMatrix{<:Real}, prior::BOCPDPrior;
               prune::Float64 = 1e-10, ks::Vector{Int} = [4, 8, 13, 26, 52], c::Float64 = Inf)
    T, p = size(X)
    H = 1 / prior.lambda
    Lam0 = Symmetric(prior.Lambda0); mu0 = prior.mu0
    L0mu0 = Lam0 * mu0; q0 = dot(mu0, L0mu0)
    # per run-length sufficient statistics (run r = entries 1..r+1 in these vectors, r = 0 first)
    XtX = Vector{Matrix{Float64}}(); Xty = Vector{Vector{Float64}}(); yty = Float64[]; nobs = Float64[]
    push!(XtX, zeros(p, p)); push!(Xty, zeros(p)); push!(yty, 0.0); push!(nobs, 0.0)
    logw = [0.0]                       # log P(r_{t-1}, y_1:t-1), unnormalised, r = 0, 1, ...
    runlen = [0]                       # run lengths carried (after pruning they may be sparse)
    out_pc = Dict(k => zeros(T) for k in ks)
    r_map = zeros(Int, T); r_mean = zeros(T); start_map = zeros(Int, T)
    beta_out = zeros(T, p); s2_out = zeros(T); logpred = zeros(T)
    xt = zeros(p)
    for t in 1:T
        xt .= X[t, :]; yt = y[t]
        nr = length(runlen)
        lp = Vector{Float64}(undef, nr)
        # predictive for each carried run length, and posterior means for reporting
        bmix = zeros(p); s2mix = 0.0
        post_mu = Vector{Vector{Float64}}(undef, nr); post_s2 = Vector{Float64}(undef, nr); wt = ones(nr)
        for i in 1:nr
            Ln = Symmetric(Lam0 + XtX[i]); n = nobs[i]
            ch = cholesky(Ln)
            mun = ch \ (L0mu0 + Xty[i])
            an = prior.a0 + n / 2
            bn = prior.b0 + 0.5 * (yty[i] + q0 - dot(mun, Ln * mun))
            bn = max(bn, 1e-12)
            v = ch \ xt
            s2 = bn / an * (1 + dot(xt, v))
            lp[i] = logpred_t(yt, 2an, dot(xt, mun), s2)
            post_mu[i] = mun; post_s2[i] = an > 1 ? bn / (an - 1) : bn / an
            isfinite(c) && (wt[i] = 1 / (1 + (yt - dot(xt, mun))^2 / (c^2 * s2)))   # score-matching weight on the run's own predictive
        end
        # joint for growth and change
        lj = logw .+ lp                       # log P(r_{t-1}, y_1:t)
        m = maximum(lj); wj = exp.(lj .- m)
        growth = wj .* (1 - H); change = sum(wj) * H
        # evidence and normalised run-length posterior at t
        Z = sum(growth) + change
        post_g = growth ./ Z; post_c = change / Z
        logpred[t] = log(Z) + m - logsumexp_(logw)
        # reporting (run length at t is r_{t-1}+1 for growth, 0 for change)
        newrun = vcat(0, runlen .+ 1); newpost = vcat(post_c, post_g)
        for k in ks
            out_pc[k][t] = sum(newpost[newrun .< k])
        end
        imax = argmax(newpost); r_map[t] = newrun[imax]; start_map[t] = t - newrun[imax] + 1
        r_mean[t] = dot(newpost, newrun)
        # posterior mean coefficients: change component uses the prior
        bmix .= post_c .* mu0; s2mix = post_c * (prior.a0 > 1 ? prior.b0 / (prior.a0 - 1) : prior.b0 / prior.a0)
        for i in 1:nr
            bmix .+= post_g[i] .* post_mu[i]; s2mix += post_g[i] * post_s2[i]
        end
        beta_out[t, :] = bmix; s2_out[t] = s2mix
        # update sufficient statistics: every carried run grows by (xt, yt); a fresh run r = 0 is added
        for i in 1:nr
            XtX[i] .+= wt[i] .* (xt * xt'); Xty[i] .+= wt[i] .* xt .* yt; yty[i] += wt[i] * yt^2; nobs[i] += wt[i]
        end
        pushfirst!(XtX, zeros(p, p)); pushfirst!(Xty, zeros(p)); pushfirst!(yty, 0.0); pushfirst!(nobs, 0.0)
        runlen = newrun; logw = log.(newpost)
        # prune negligible run lengths (never the fresh one)
        if prune > 0
            keep = findall(i -> i == 1 || newpost[i] > prune, eachindex(newpost))
            if length(keep) < length(newpost)
                XtX = XtX[keep]; Xty = Xty[keep]; yty = yty[keep]; nobs = nobs[keep]
                runlen = runlen[keep]; logw = logw[keep]
                logw .-= logsumexp_(logw)
            end
        end
    end
    (p_change = out_pc, r_map = r_map, r_mean = r_mean, start_map = start_map,
     beta = beta_out, sigma2 = s2_out, logpred = logpred)
end

logsumexp_(v) = (m = maximum(v); m + log(sum(exp.(v .- m))))

"""
    bocpd_prior_from_regimes(coefs, sigma2s, lengths; scale = 1.0, a0 = 3.0, robust = true)

Empirical-Bayes hyperparameters from a pooled set of dated regimes. With `robust = true`
the prior mean of the coefficients is their pooled median and the prior standard deviation
is `sqrt(scale)` times the scaled median absolute deviation; otherwise mean and standard
deviation. The inverse-gamma on sigma2 has shape `a0` and scale set so that its mean equals
the pooled median (robust) or mean of the regime variances. `lambda` is the mean regime length.
"""
function bocpd_prior_from_regimes(coefs::AbstractMatrix, sigma2s::AbstractVector, lengths::AbstractVector;
                                  scale = 1.0, a0 = 3.0, robust = true)
    if robust
        mu0 = vec(median(coefs, dims = 1))
        sd = [1.4826 * median(abs.(coefs[:, j] .- mu0[j])) for j in 1:size(coefs, 2)]
        m = median(sigma2s)
    else
        mu0 = vec(mean(coefs, dims = 1)); sd = vec(std(coefs, dims = 1)); m = mean(sigma2s)
    end
    v = (sd .^ 2) .* scale
    Lambda0 = Matrix(Diagonal(1 ./ max.(v, 1e-6)))
    b0 = m * (a0 - 1)
    BOCPDPrior(mu0, Lambda0, a0, b0, mean(lengths))
end
end # module
