#!/usr/bin/env julia
# =============================================================================
# export.jl : dump every table of data/err.sqlite to CSV under data/export/, on demand.
#   julia --project=julia julia/export.jl            all tables
#   julia --project=julia julia/export.jl online alerts   only these tables
# =============================================================================
include(joinpath(@__DIR__, "common.jl"))

db = SQLite.DB(DB_PATH)
out = joinpath(ROOT, "data", "export"); mkpath(out)
tables = isempty(ARGS) ? table_names(db) : ARGS
for t in tables
    t in table_names(db) || error("no table named $t (have: $(join(table_names(db), ", ")))")
    df = query(db, "SELECT * FROM $t")
    CSV.write(joinpath(out, t * ".csv"), df)
    println(rpad(t, 12), nrow(df), " rows -> data/export/", t, ".csv")
end
