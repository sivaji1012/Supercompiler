using Test
using MorkSupercompiler

@testset "SCPipeline — execute! stages (plan=true)" begin
    facts = raw"""
    (edge 0 1) (edge 1 2) (edge 2 3)
    """
    prog  = raw"""
    (exec 0 (, (edge $x $y) (edge $y $z)) (, (trans $x $z)))
    """
    s = new_space()
    space_add_all_sexpr!(s, facts)
    r = execute!(s, prog; opts=SCOptions(max_steps=1))
    @test r isa SCResult
    @test haskey(r.timings, :execute)
    @test haskey(r.timings, :plan)
    @test !isempty(r.program_planned)
end

@testset "SCPipeline — execute convenience wrapper" begin
    facts = "(a 1) (a 2) (a 3)"
    prog  = raw"(exec 0 (, (a $x)) (, (b $x)))"
    s, r  = execute(facts, prog; steps=1)
    @test s isa Space
    @test r isa SCResult
    @test space_val_count(s) > 3   # at least some new atoms
end

@testset "SCPipeline — timing_report returns non-empty string" begin
    _, r = execute("(foo 1)", raw"(exec 0 (, (foo $x)) (, (bar $x)))"; steps=1)
    rep  = timing_report(r)
    @test !isempty(rep)
    @test occursin("execute", rep)
end

@testset "SCPipeline — decompose stage fires for 3-source program" begin
    facts = "(edge 0 1) (edge 1 2) (edge 2 3)"
    prog  = raw"(exec 0 (, (edge $x $y) (edge $y $z) (edge $z $w)) (, (dtrans $x $w)))"
    _, r  = execute(facts, prog; steps=1)
    # decompose=true by default: 1 original atom → 2 stages
    @test r.n_atoms_original == 1
    @test r.n_atoms_decomposed == 2
    @test haskey(r.timings, :decompose)
end

@testset "SCPipeline — decompose=false skips decomposition" begin
    facts = "(edge 0 1) (edge 1 2) (edge 2 3)"
    prog  = raw"(exec 0 (, (edge $x $y) (edge $y $z) (edge $z $w)) (, (dtrans $x $w)))"
    opts  = SCOptions(decompose=false)
    _, r  = execute(facts, prog; opts=opts, steps=1)
    @test r.n_atoms_original == r.n_atoms_decomposed   # no change
    @test !haskey(r.timings, :decompose)
end

@testset "SCPipeline — 2-source program unchanged by decompose" begin
    facts = "(edge 0 1) (edge 1 2)"
    prog  = raw"(exec 0 (, (edge $x $y) (edge $y $z)) (, (path $x $z)))"
    _, r  = execute(facts, prog; steps=1)
    # 2 sources ≤ STAGE_MAX_SOURCES → no decomposition
    @test r.n_atoms_original == r.n_atoms_decomposed
end
