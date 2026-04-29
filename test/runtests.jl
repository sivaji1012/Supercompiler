using Test
using MorkSupercompiler

# ── §1 SExpr parser ───────────────────────────────────────────────────────────

@testset "SExpr parser" begin
    @testset "atoms" begin
        n = parse_sexpr("foo")
        @test n isa SAtom && (n::SAtom).name == "foo"

        n = parse_sexpr("foo-bar")
        @test n isa SAtom && (n::SAtom).name == "foo-bar"

        n = parse_sexpr("!=")
        @test n isa SAtom && (n::SAtom).name == "!="

        n = parse_sexpr("42")
        @test n isa SAtom && (n::SAtom).name == "42"
    end

    @testset "variables" begin
        n = parse_sexpr("\$x")
        @test n isa SVar && (n::SVar).name == "\$x"

        n = parse_sexpr("\$ts")
        @test n isa SVar && (n::SVar).name == "\$ts"
    end

    @testset "lists" begin
        n = parse_sexpr("(foo bar baz)")
        @test n isa SList
        items = (n::SList).items
        @test length(items) == 3
        @test (items[1]::SAtom).name == "foo"
        @test (items[2]::SAtom).name == "bar"

        n = parse_sexpr("()")
        @test n isa SList && isempty((n::SList).items)

        n = parse_sexpr("(parity \$i \$p)")
        @test n isa SList
        items = (n::SList).items
        @test (items[1]::SAtom).name == "parity"
        @test (items[2]::SVar).name == "\$i"
        @test (items[3]::SVar).name == "\$p"
    end

    @testset "nested" begin
        n = parse_sexpr("((phase \$p) (, (parity \$i \$p)) (O x))")
        @test n isa SList
        items = (n::SList).items
        @test items[1] isa SList
        conj = items[2]
        @test is_conjunction(conj)
    end

    @testset "program" begin
        src = """
        (foo bar)
        ; comment
        (baz \$x \$y)
        """
        nodes = parse_program(src)
        @test length(nodes) == 2
    end

    @testset "roundtrip" begin
        exprs = [
            "(parity \$i \$p)",
            "(exec 0 (, (edge \$x \$y) (edge \$y \$z)) (, (trans \$x \$z)))",
            "((phase \$p) (, (parity \$i \$p) (succ \$i \$si) (A \$i \$e)) (O x))",
        ]
        for e in exprs
            n = parse_sexpr(e)
            @test sprint_sexpr(n) == e
        end
    end
end

# ── §2 Selectivity utilities ──────────────────────────────────────────────────

@testset "Selectivity" begin
    ground   = parse_sexpr("(parity 0 even)")
    partial  = parse_sexpr("(parity \$i even)")
    all_var  = parse_sexpr("(parity \$i \$p)")
    bare_var = parse_sexpr("\$x")

    @testset "static_score" begin
        @test static_score(ground)   == 0.0
        @test static_score(partial)  <  static_score(all_var)
        @test static_score(bare_var) == 1.0
    end

    @testset "count_vars / count_atoms" begin
        @test count_vars(ground)  == 0
        @test count_atoms(ground) == 3
        @test count_vars(all_var) == 2
        @test count_atoms(all_var) == 1
    end

    @testset "is_ground / is_conjunction" begin
        @test is_ground(ground)
        @test !is_ground(partial)
        conj = parse_sexpr("(, (a \$x) (b \$y))")
        @test is_conjunction(conj)
        @test !is_conjunction(ground)
    end
end

# ── §3 Static reordering ──────────────────────────────────────────────────────

@testset "Rewrite (static)" begin
    @testset "conjunction reorder" begin
        conj = parse_sexpr("(, (parity \$i \$p) (succ 0 1) (\$x \$y \$z))")
        @test is_conjunction(conj)
        reordered = reorder_conjunction_static(conj::SList)
        items = reordered.items
        sources = items[2:end]
        scores  = static_score.(sources)
        # Result must be sorted by ascending static_score
        @test issorted(scores)
        # (succ 0 1) is ground → score 0.0 → must be first
        @test static_score(sources[1]) == 0.0
        # (\$x \$y \$z) is fully variable → score 1.0 → must be last
        @test static_score(sources[end]) == 1.0
    end

    @testset "program reorder" begin
        prog = """((phase \$p) (, (parity \$i \$p) (succ 0 1) (\$x \$y \$z)) (O res))"""
        reordered = reorder_program_static(prog)
        # The program should still parse
        nodes = parse_program(reordered)
        @test length(nodes) == 1
        # First source in the conjunction should be the most selective
        conj = (nodes[1]::SList).items[2]
        @test is_conjunction(conj)
        first_src = (conj::SList).items[2]
        @test static_score(first_src) <= static_score((conj::SList).items[end])
    end
end

# ── §4 Statistics ─────────────────────────────────────────────────────────────

@testset "Statistics" begin
    stats = MORKStatistics()
    @test stats.total_atoms == 0

    @testset "estimate_cardinality — no stats" begin
        src = parse_sexpr("(parity \$i \$p)")
        # With no stats, falls back to total_atoms / 4 = 0 → max(1,...) = 1
        card = estimate_cardinality(src, stats)
        @test card >= 1
    end

    @testset "estimate_cardinality — with predicate count" begin
        stats2 = MORKStatistics(
            Dict("parity" => 5, "succ" => 5, "lt" => 10),
            Dict("parity" => 3, "succ" => 3, "lt" => 3),
            Dict{Tuple{String,Int},Tuple{Float64,Float64}}(),
            20, 20
        )
        @test estimate_cardinality(parse_sexpr("(parity \$i \$p)"), stats2) == 5
        @test estimate_cardinality(parse_sexpr("(lt \$x \$y)"), stats2)     == 10
        # Ground atom: should give 1 (no variables to expand)
        @test estimate_cardinality(parse_sexpr("(parity 0 even)"), stats2) >= 1
    end
end

# ── §5 QueryPlanner ───────────────────────────────────────────────────────────

@testset "QueryPlanner" begin
    @testset "effects_commute" begin
        @test effects_commute(EFF_READ, EFF_READ)
        @test effects_commute(EFF_PURE, EFF_WRITE)
        @test !effects_commute(EFF_WRITE, EFF_APPEND)
    end

    @testset "variable flow" begin
        sources = parse_program("(parity \$i \$p)\n(succ \$i \$si)\n(A \$si \$se)")
        stats2  = MORKStatistics(
            Dict("parity" => 5, "succ" => 5, "A" => 5),
            Dict("parity" => 3, "succ" => 3, "A" => 3),
            Dict{Tuple{String,Int},Tuple{Float64,Float64}}(),
            15, 15)
        nodes = build_join_nodes(sources, stats2)
        @test length(nodes) == 3
        # \$i introduced by (parity \$i \$p) so succ and A should have \$i in vars_in
        @test "\$i" in nodes[2].vars_in
        @test "\$si" in nodes[3].vars_in
    end

    @testset "plan_join_order" begin
        # Ground source should be first (card=1 beats card=5)
        stats3 = MORKStatistics(
            Dict("parity" => 5, "lt" => 10, "succ" => 1),
            Dict{String,Int}(),
            Dict{Tuple{String,Int},Tuple{Float64,Float64}}(),
            20, 20)
        sources = parse_program("(lt \$x \$y)\n(parity \$i \$p)\n(succ 0 1)")
        nodes   = build_join_nodes(sources, stats3)
        perm    = plan_join_order(nodes)
        # Lowest card wins: succ has card=1 (and is ground) → should be first
        @test perm[1] == 3   # succ 0 1 is source 3 (1-indexed)
    end

    @testset "plan_program" begin
        prog = """((phase \$p) (, (lt \$x \$y) (parity \$i \$p) (succ 0 1)) (O res))"""
        stats3 = MORKStatistics(
            Dict("parity" => 5, "lt" => 10, "succ" => 1),
            Dict{String,Int}(),
            Dict{Tuple{String,Int},Tuple{Float64,Float64}}(),
            16, 16)
        planned = plan_program(prog, stats3)
        nodes   = parse_program(planned)
        conj    = ((nodes[1]::SList).items[2]::SList)
        first_src = conj.items[2]
        # Lowest-card source first: succ 0 1 (card=1)
        @test sprint_sexpr(first_src) == "(succ 0 1)"
    end
end

println("All tests passed ✓")
