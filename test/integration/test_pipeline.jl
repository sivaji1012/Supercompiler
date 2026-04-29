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
