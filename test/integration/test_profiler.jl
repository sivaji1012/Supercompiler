using Test
using MorkSupercompiler

@testset "Profiler — sc_profile returns SCProfile" begin
    facts = "(edge 0 1) (edge 1 2)"
    prog  = raw"(exec 0 (, (edge $x $y) (edge $y $z)) (, (path $x $z)))"
    p = sc_profile(facts, prog; steps=2, trials=1)
    @test p isa SCProfile
    @test p.atom_count_before >= 2
    @test haskey(p.baseline_times, PHASE_EXECUTE)
    @test haskey(p.planned_times,  PHASE_EXECUTE)
end

@testset "Profiler — speedup_report is non-empty" begin
    facts = "(edge 0 1)"
    prog  = raw"(exec 0 (, (edge $x $y)) (, (reach $x)))"
    p   = sc_profile(facts, prog; steps=1, trials=1)
    rep = speedup_report(p)
    @test !isempty(rep)
    @test occursin("Speedup", rep) || occursin("speedup", rep)
end
