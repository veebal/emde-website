# =============================================================================
# variance.jl : the two-sided CUSUM e-detector on the residual variance, copied verbatim
# from the lab's JULIA/dsm.jl (the only part of that file the site uses; the dsm engine
# itself is not deployed).
# =============================================================================
module VarianceCUSUM
using LinearAlgebra, Statistics
export variance_cusum

"""
    variance_cusum(y, X, beta; rho, alpha, ucap, refractory, window, minobs)

A two-sided CUSUM on the squared standardised one-step residual u_t = e_t^2 / v_t, with
e_t = y_t - x_t'beta_{t-1} (beta the filter's posterior mean at t-1) and v_t the variance of
the preceding `window` residuals estimated by their median squared residual divided by the
median of a chi-squared(1) variable, 0.4549, which no single week can move. The downward
statistic accumulates the log likelihood ratio of N(0, v/rho) against N(0, v), the upward one
that of N(0, rho v) with u capped at `ucap`. Each is an e-detector when the pre-change law is
N(0, v) (Shin, Ramdas and Rinaldo, 2024): with threshold log(1/alpha) the average run length
to a false alarm is at least 1/alpha. Returns the statistics, the reference variance and an
alert vector (-1 fall, +1 rise, 0 none); both statistics restart after an alert.
"""
function variance_cusum(y, X, beta::AbstractMatrix; rho = 3.0, alpha = 1 / 520, ucap = 9.0, refractory = 26, window = 52, minobs = 13)
    T = length(y); h = log(1 / alpha)
    Sdn = zeros(T); Sup = zeros(T); vref = fill(NaN, T); alert = zeros(Int, T); last = -10^9
    e2 = fill(NaN, T); sd = 0.0; su = 0.0
    for t in 2:T
        e2[t] = (y[t] - dot(view(X, t, :), view(beta, t - 1, :)))^2
        lo = max(2, t - window); n = t - lo
        n >= minobs || continue
        v = median(view(e2, lo:t-1)) / 0.4549; vref[t] = v
        u = e2[t] / v
        sd = max(0.0, sd + 0.5 * log(rho) - (rho - 1) * u / 2)
        su = max(0.0, su - 0.5 * log(rho) + (1 - 1 / rho) * min(u, ucap) / 2)
        Sdn[t] = sd; Sup[t] = su
        if t - last > refractory && (sd > h || su > h)
            alert[t] = sd > h ? -1 : 1; last = t; sd = 0.0; su = 0.0
        end
    end
    (down = Sdn, up = Sup, vref = vref, alert = alert)
end
end # module
