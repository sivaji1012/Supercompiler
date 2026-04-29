using Test
using MorkSupercompiler

@testset "Explainer — sc_explain on multi-source pattern" begin
    s = new_space()
    space_add_all_sexpr!(s, "(parity 0 even) (parity 1 odd) (succ 0 1) (succ 1 2)")
    prog = raw"""((phase $p) (, (parity $i $p) (succ $i $si) (A $i $e)) (O res))"""
    exp  = sc_explain(s, prog)
    @test !isempty(exp)
    @test occursin("Sources", exp)
    @test occursin("Planned order", exp)
end

@testset "Explainer — sc_explain on single-source (no reorder)" begin
    s = new_space()
    space_add_all_sexpr!(s, "(foo 1)")
    prog = raw"(exec 0 (, (foo $x)) (, (bar $x)))"
    exp  = sc_explain(s, prog)
    @test occursin("no multi-source", exp)
end

@testset "Explainer — sc_dot produces valid DOT header" begin
    prog = raw"""((phase $p) (, (parity $i $p) (succ $i $si)) (O res))"""
    dot  = sc_dot(prog)
    @test startswith(strip(dot), "digraph")
    @test occursin("rankdir", dot)
end

@testset "Explainer — sc_diff detects reordering" begin
    prog = raw"""((phase $p) (, (lt $x $y) (parity $i $p)) (O res))"""
    stats = MORKStatistics(Dict("parity" => 5, "lt" => 50), 55)
    planned = plan_program(prog, stats)
    diff = sc_diff(prog, planned)
    @test !isempty(diff)
end
