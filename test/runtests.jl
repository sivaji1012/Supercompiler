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


# ── §6 MCore IR (§3.1 of mm2_supercompiler_spec) ─────────────────────────────

@testset "MCore — 11 node types (§3.1)" begin
    g = MCoreGraph()

    id_foo   = add_sym!(g, Sym(:foo))
    id_x     = add_var!(g, Var(0))
    id_42    = add_lit!(g, Lit(42))
    id_con   = add_con!(g, Con(:kb_fact, [id_foo]))
    id_app   = add_app!(g, App(id_foo, [id_x]))
    id_abs   = add_abs!(g, Abs([0], id_app))
    id_let   = add_let!(g, LetNode([(0, id_42)], id_foo))
    id_match = add_match!(g, MatchNode(id_x, [MatchClause(id_foo, id_app)]))
    id_choice= add_choice!(g, Choice([ChoiceAlt(id_foo)]))
    id_prim  = add_prim!(g, Prim(:kb_query, [id_foo]))
    id_ref   = add_mref!(g, MCoreRef(:my_def))

    @test (get_node(g, id_foo)::Sym).name      == :foo
    @test (get_node(g, id_x)::Var).ix          == 0
    @test (get_node(g, id_42)::Lit).val        == 42
    @test (get_node(g, id_con)::Con).head      == :kb_fact
    @test (get_node(g, id_app)::App).fun       == id_foo
    @test (get_node(g, id_abs)::Abs).body      == id_app
    @test (get_node(g, id_let)::LetNode).body  == id_foo
    @test length((get_node(g, id_match)::MatchNode).clauses) == 1
    @test length((get_node(g, id_choice)::Choice).alts)     == 1
    @test (get_node(g, id_prim)::Prim).op      == :kb_query
    @test (get_node(g, id_ref)::MCoreRef).def_id == :my_def
    @test g.next_id == UInt32(12)
end

@testset "MCore — domain compilation (§3.2)" begin
    g   = MCoreGraph()
    pat = add_sym!(g, Sym(:pattern))
    kid = compile_kb_query(g, pat)
    @test isvalid(kid)
    n   = get_node(g, kid)::Prim
    @test n.op == :kb_query && n.args == [pat]
end

@testset "UncertainNode (§2.4 approx spec)" begin
    vp  = PBox(0.8, 1.0, 0.95)
    cp  = PBox(0.0, 10.0, 1.0)
    g   = MCoreGraph()
    bid = add_sym!(g, Sym(:base))
    un  = UncertainNode(bid, vp, cp, 0.05)
    @test un.base == bid && un.error_bound == 0.05
    @test un.value_pbox.confidence == 0.95
end

# ── §7 Effect algebra (§4 of mm2_supercompiler_spec) ─────────────────────────

@testset "Effects — Algorithm 1 EffectCommutes (§4.2)" begin
    sp  = DEFAULT_SPACE
    sp2 = SpaceID(:other)

    @test commutes(PURE, ReadEffect(sp))
    @test commutes(ReadEffect(sp), PURE)
    @test commutes(ReadEffect(sp), ReadEffect(sp))
    @test commutes(ReadEffect(sp), ReadEffect(sp2))
    @test commutes(ReadEffect(sp), ObserveEffect(sp))
    @test commutes(ObserveEffect(sp), ObserveEffect(sp))
    @test commutes(AppendEffect(sp), AppendEffect(sp2))  # diff resource
    @test !commutes(AppendEffect(sp), AppendEffect(sp))  # same resource
    @test !commutes(AppendEffect(sp), ReadEffect(sp))    # Read sees Append
    @test commutes(AppendEffect(sp), ObserveEffect(sp))  # Observe doesn't
    @test !commutes(WriteEffect(sp), WriteEffect(sp))
    @test !commutes(WriteEffect(sp), ReadEffect(sp))
    @test commutes(PURE, WriteEffect(sp))                # Pure commutes with everything
end

@testset "Effects — sink-free checks (§4.3)" begin
    sp = DEFAULT_SPACE
    @test is_sink_free([ReadEffect(sp), AppendEffect(sp)])
    @test sink_free_check([ReadEffect(sp), AppendEffect(sp)]) === nothing
    @test !is_sink_free([ReadEffect(sp), DeleteEffect(sp)])
    @test sink_free_check([WriteEffect(sp)]) isa String
end

@testset "Effects — MORK sources all commute (free reorder justification)" begin
    e1 = mork_source_effects()
    e2 = mork_source_effects()
    @test commutes_all(e1, e2)
end


# ── §8 Stepper — Algorithm 7 RewriteOnce + Algorithm 8 CallPrimitive (§6.1) ──

@testset "Stepper — Values (Lit, Sym, Abs are immediate)" begin
    g = MCoreGraph()
    id_l = add_lit!(g, Lit(42))
    id_s = add_sym!(g, Sym(:foo))
    id_a = add_abs!(g, Abs([0], id_l))

    @test rewrite_once(g, id_l, Env()) isa Value
    @test rewrite_once(g, id_s, Env()) isa Value
    @test rewrite_once(g, id_a, Env()) isa Value   # Abs is a value (not yet applied)
end

@testset "Stepper — Var lookup" begin
    g    = MCoreGraph()
    id_l = add_lit!(g, Lit(99))
    id_v = add_var!(g, Var(0))
    env  = env_extend(Env(), id_l)

    r = rewrite_once(g, id_v, env)
    @test r isa Value && r.id == id_l   # Var(0) → bound value

    r2 = rewrite_once(g, id_v, Env())
    @test r2 isa Value && r2.id == id_v   # unbound Var → Value(itself)
end

@testset "Stepper — beta reduction (App of Abs)" begin
    g    = MCoreGraph()
    id_l = add_lit!(g, Lit(7))
    # (λ x. x) applied to Lit(7) → Lit(7)
    id_v   = add_var!(g, Var(0))
    id_abs = add_abs!(g, Abs([0], id_v))
    id_app = add_app!(g, App(id_abs, [id_l]))

    r = step_to_value(g, id_app, Env())
    @test r isa Value
    @test (get_node(g, r.id)::Lit).val == 7
end

@testset "Stepper — Let binding" begin
    g    = MCoreGraph()
    id_l = add_lit!(g, Lit(5))
    id_v = add_var!(g, Var(0))
    id_let = add_let!(g, LetNode([(0, id_l)], id_v))

    r = step_to_value(g, id_let, Env())
    @test r isa Value
    @test (get_node(g, r.id)::Lit).val == 5
end

@testset "Stepper — Con steps its fields" begin
    g      = MCoreGraph()
    id_l1  = add_lit!(g, Lit(1))
    id_v0  = add_var!(g, Var(0))
    id_con = add_con!(g, Con(:pair, [id_l1, id_v0]))
    env    = env_extend(Env(), add_lit!(g, Lit(2)))

    r = step_to_value(g, id_con, env)
    @test r isa Value
    n = get_node(g, r.id)::Con
    @test n.head == :pair
    @test (get_node(g, n.fields[1])::Lit).val == 1
    @test (get_node(g, n.fields[2])::Lit).val == 2
end

@testset "Stepper — Choice returns Blocked (needs BoundedSplit)" begin
    g  = MCoreGraph()
    id = add_sym!(g, Sym(:a))
    id_choice = add_choice!(g, Choice([ChoiceAlt(id)]))
    r = rewrite_once(g, id_choice, Env())
    @test r isa Blocked
end

@testset "Stepper — Prim :identity handler" begin
    g    = MCoreGraph()
    id_l = add_lit!(g, Lit(42))
    id_p = add_prim!(g, Prim(:identity, [id_l]))
    r = step_to_value(g, id_p, Env())
    @test r isa Value && r.id == id_l
end

@testset "Stepper — Match dispatches on constructor" begin
    g       = MCoreGraph()
    # Build: match (Con :ok [Lit 1]) with | Con :ok [Var 0] → Var 0 | _ → Lit 0
    id_lit1 = add_lit!(g, Lit(1))
    id_lit0 = add_lit!(g, Lit(0))
    id_scrut= add_con!(g, Con(:ok, [id_lit1]))

    id_pv   = add_var!(g, Var(0))
    id_pp   = add_con!(g, Con(:ok, [id_pv]))
    clause1 = MatchClause(id_pp, NULL_NODE, id_pv)   # :ok [x] → x
    clause2 = MatchClause(NULL_NODE, NULL_NODE, id_lit0)  # wildcard → 0
    id_match = add_match!(g, MatchNode(id_scrut, [clause1, clause2]))

    r = step_to_value(g, id_match, Env())
    @test r isa Value
    @test (get_node(g, r.id)::Lit).val == 1   # matched :ok → returned inner Lit(1)
end

@testset "Stepper — DepSet blocks on non-commuting effects" begin
    g    = MCoreGraph()
    # Node with READ effect; Dep has WRITE effect on same resource
    # Read does NOT commute with Write → Blocked
    id_prim = add_prim!(g, Prim(:kb_query, NodeID[], EffectSet(UInt8(0x01))))
    deps    = DepSet([WriteEffect(DEFAULT_SPACE)])
    r = rewrite_once(g, id_prim, Env(), deps)
    @test r isa Blocked
end

@testset "Stepper — Env extend / lookup" begin
    g    = MCoreGraph()
    id_a = add_lit!(g, Lit(10))
    id_b = add_lit!(g, Lit(20))
    env  = env_extend(Env(), [id_a, id_b])
    @test env_lookup(env, 0) == id_a
    @test env_lookup(env, 1) == id_b
    @test !isvalid(env_lookup(env, 9))
end


# ── §9 CanonicalKeys — §6.3 of mm2_supercompiler_spec ────────────────────────

@testset "CompactShape — shape_subsumes" begin
    s0 = CompactShape(0, 0, 0)
    s2 = CompactShape(2, 1, 0)
    s3 = CompactShape(3, 2, 0)
    @test shape_subsumes(s0, s0)   # reflexive
    @test shape_subsumes(s2, s3)   # s2 ≤ s3 component-wise
    @test !shape_subsumes(s3, s2)  # not the other way
end

@testset "canonical_key — extracts head + shape from graph" begin
    g    = MCoreGraph()
    id_l = add_lit!(g, Lit(1))
    id_c = add_con!(g, Con(:pair, [id_l, id_l]))

    key = canonical_key(g, id_c, 0)
    @test key.head == :pair
    @test key.shape.arities[1] == UInt8(2)   # :pair has 2 fields
    @test :pair in key.tags
    @test :Lit  in key.tags
end

@testset "Algorithm 10 — KeySubsumption (§6.3.2)" begin
    g   = MCoreGraph()
    id1 = add_con!(g, Con(:foo, NodeID[]))
    id2 = add_con!(g, Con(:foo, NodeID[]))

    k1 = canonical_key(g, id1, 0)
    k2 = canonical_key(g, id2, 0)
    @test subsumes(k1, k2)    # identical structure → k1 subsumes k2
    @test subsumes(k2, k1)    # symmetric when identical

    # Different head → no subsumption
    id3  = add_con!(g, Con(:bar, NodeID[]))
    k3   = canonical_key(g, id3, 0)
    @test !subsumes(k1, k3)

    # Wider shape subsumes narrower (general subsumes specific)
    id_lit = add_lit!(g, Lit(1))
    id_big = add_con!(g, Con(:foo, [id_lit, id_lit, id_lit]))
    k_big  = canonical_key(g, id_big, 0)
    @test !subsumes(k_big, k1)   # k_big has arity 3, k1 has 0 → 3 ≰ 0
    @test subsumes(k1, k_big)    # k1 shape (0,0,0) ≤ k_big shape → k1 subsumes k_big
end

@testset "FoldTable — record and lookup" begin
    g    = MCoreGraph()
    ft   = FoldTable()
    id_c = add_con!(g, Con(:foo, NodeID[]))
    key  = canonical_key(g, id_c, 0)

    @test !can_fold(ft, key)     # empty table — nothing to fold
    record!(ft, key, id_c)
    @test can_fold(ft, key)      # now it's there
    @test lookup_fold(ft, key) == id_c

    # A more specific key (same head, bigger shape) is subsumed by the recorded one
    id_lit  = add_lit!(g, Lit(1))
    id_big  = add_con!(g, Con(:foo, [id_lit]))
    key_big = canonical_key(g, id_big, 0)
    @test can_fold(ft, key_big)  # key (shape 0) subsumes key_big (shape 1)
end


# ── §10 BoundedSplit — Algorithm 9 (§6.2 of mm2_supercompiler_spec) ───────────

@testset "BoundedSplit — non-splittable node passes through" begin
    g    = MCoreGraph()
    id_l = add_lit!(g, Lit(42))
    stats = MORKStatistics()
    sr   = bounded_split(g, id_l, Env(), stats)
    @test length(sr.branches) == 1
    @test sr.branches[1].id == id_l
    @test sr.total_prob ≈ 1.0
    @test !sr.catchall_added
end

@testset "BoundedSplit — Choice: selects top branches by probability" begin
    g    = MCoreGraph()
    ids  = [add_sym!(g, Sym(Symbol("alt$i"))) for i in 1:5]
    alts = ChoiceAlt.(ids)
    id_c = add_choice!(g, Choice(alts))

    stats = MORKStatistics(
        Dict("alt1"=>100, "alt2"=>200, "alt3"=>50, "alt4"=>10, "alt5"=>5),
        Dict{String,Int}(), Dict{Tuple{String,Int},Tuple{Float64,Float64}}(),
        365, 365)

    sr = bounded_split(g, id_c, Env(), stats; budget=3)
    # Should have selected up to 3 branches + maybe a catchall
    n_non_catchall = count(b -> !b.is_catchall, sr.branches)
    @test n_non_catchall <= 3
    # Total prob of selected branches should be in [0, 1]
    @test 0.0 <= sr.total_prob <= 1.0
    # If not all branches covered, catchall added for soundness
    if sr.total_prob < 1.0
        @test sr.catchall_added
    end
end

@testset "BoundedSplit — budget=1 selects exactly 1 main branch" begin
    g    = MCoreGraph()
    ids  = [add_sym!(g, Sym(Symbol("x$i"))) for i in 1:4]
    alts = ChoiceAlt.(ids)
    id_c = add_choice!(g, Choice(alts))
    # Use realistic stats so prob per guard < 1.0
    stats = MORKStatistics(
        Dict("x1"=>25,"x2"=>25,"x3"=>25,"x4"=>25),
        Dict{String,Int}(),
        Dict{Tuple{String,Int},Tuple{Float64,Float64}}(),
        100, 100)

    sr = bounded_split(g, id_c, Env(), stats; budget=1)
    non_ca = count(b -> !b.is_catchall, sr.branches)
    @test non_ca == 1           # exactly 1 real branch selected
    @test length(sr.branches) >= 1
end

@testset "BoundedSplit — SPLIT_PROB_THRESHOLD constant is 0.95" begin
    @test SPLIT_PROB_THRESHOLD == 0.95
    @test SPLIT_DEFAULT_BUDGET == 16
end


# ── §11 KBSaturation — Algorithm 11 (§7.1) ────────────────────────────────────

@testset "KBSaturation — base facts + VersionedIndex" begin
    g  = MCoreGraph()
    kb = KBState(g)

    id1 = add_con!(g, Con(:parent, [add_sym!(g, Sym(:alice)), add_sym!(g, Sym(:bob))]))
    id2 = add_con!(g, Con(:parent, [add_sym!(g, Sym(:bob)),   add_sym!(g, Sym(:carol))]))
    kb_add_fact!(kb, id1)
    kb_add_fact!(kb, id2)

    @test length(index_lookup(kb.index, :parent)) == 2
    @test length(all_facts(kb)) == 2
    @test length(kb.delta) == 2   # both in delta before saturation
end

@testset "KBSaturation — saturate! reaches fixed point" begin
    g  = MCoreGraph()
    kb = KBState(g)

    # Fact: (parent alice bob)
    id_alice = add_sym!(g, Sym(:alice))
    id_bob   = add_sym!(g, Sym(:bob))
    id_carol = add_sym!(g, Sym(:carol))
    id_p1    = add_con!(g, Con(:parent, [id_alice, id_bob]))
    id_p2    = add_con!(g, Con(:parent, [id_bob,   id_carol]))
    kb_add_fact!(kb, id_p1)
    kb_add_fact!(kb, id_p2)

    # Rule: (parent X Y) ∧ (parent Y Z) → (ancestor X Z)
    id_vx    = add_var!(g, Var(0))
    id_vy    = add_var!(g, Var(1))
    id_vz    = add_var!(g, Var(2))
    id_body1 = add_con!(g, Con(:parent, [id_vx, id_vy]))
    id_body2 = add_con!(g, Con(:parent, [id_vy, id_vz]))
    id_head  = add_con!(g, Con(:ancestor, [id_vx, id_vz]))
    rule_id  = add_sym!(g, Sym(:ancestor_rule))
    rule     = Rule(id_head, [id_body1, id_body2], rule_id)
    kb_add_rule!(kb, rule)

    n_new = saturate!(kb; max_rounds=10)
    @test n_new >= 1   # at least (ancestor alice carol) derived

    anc_facts = index_lookup(kb.index, :ancestor)
    @test length(anc_facts) >= 1
end

@testset "KBSaturation — idempotent (second saturate! adds nothing)" begin
    g  = MCoreGraph()
    kb = KBState(g)

    id_a = add_con!(g, Con(:fact, [add_sym!(g, Sym(:a))]))
    kb_add_fact!(kb, id_a)
    saturate!(kb; max_rounds=5)

    n2 = saturate!(kb; max_rounds=5)
    @test n2 == 0   # no rules → fixed point immediately
end

# ── §12 EvoSpecializer — Algorithms 12 + 13 + 5 + 7 (§8) ────────────────────

@testset "EvoSpecializer — Algorithm 12 GatedSpecialization" begin
    # < 10% → SPEC_VECTORIZED
    d1 = should_specialize(1.0, 100, 100, 500.0)
    @test d1.level == SPEC_VECTORIZED
    @test d1.amortization_ratio < 0.10

    # 10–50% → SPEC_INCREMENTAL
    d2 = should_specialize(1.0, 100, 100, 3000.0)
    @test d2.level == SPEC_INCREMENTAL

    # ≥ 50% → SPEC_GENERIC
    d3 = should_specialize(1.0, 100, 100, 8000.0)
    @test d3.level == SPEC_GENERIC
end

@testset "EvoSpecializer — Algorithm 13 CanReuseFitnessCache" begin
    g = MCoreGraph()
    # Parent: (f (lit 1))
    id_f  = add_sym!(g, Sym(:f))
    id_l1 = add_lit!(g, Lit(1))
    id_p  = add_app!(g, App(id_f, [id_l1]))
    # Child: (f (lit 2)) — only constant changed
    id_l2 = add_lit!(g, Lit(2))
    id_c  = add_app!(g, App(id_f, [id_l2]))

    meta  = CacheMetadata(1.0)
    @test can_reuse_cache(g, id_c, id_p, meta)   # 1 constant change ≤ max_changes=3

    # Child: (g (lit 1)) — structural change (different head)
    id_g  = add_sym!(g, Sym(:g))
    id_c2 = add_app!(g, App(id_g, [id_l1]))
    @test !can_reuse_cache(g, id_c2, id_p, meta)  # structural change
end

@testset "EvoSpecializer — Algorithm 5 ApproximateFitness (Hoeffding bound)" begin
    pb = approximate_fitness(0.7, 100)
    lo, hi = pb.intervals[1]
    @test lo < 0.7 < hi         # interval straddles sample fitness
    @test pb.probabilities[1] ≈ 0.95
    @test pb.probabilities[2] ≈ 0.05   # 5% tail reserve
    @test pb.confidence ≈ 1.0

    # More samples → narrower interval
    pb2 = approximate_fitness(0.7, 10_000)
    lo2, hi2 = pb2.intervals[1]
    @test (hi2 - lo2) < (hi - lo)   # narrower
end

@testset "EvoSpecializer — Algorithm 7 AllocateEvaluations" begin
    pop = [
        EvolutionaryPBox(1, PBox(0.5, 0.9, 1.0), PBox(0.0,1.0,1.0), 0.8, 1),
        EvolutionaryPBox(2, PBox(0.1, 0.3, 1.0), PBox(0.0,1.0,1.0), 0.5, 5),
        EvolutionaryPBox(3, PBox(0.8, 0.95,1.0), PBox(0.0,1.0,1.0), 0.9, 2),
    ]
    alloc = allocate_evaluations(pop, 2)
    @test length(alloc) == 2
    # All returned ids should be valid individual ids
    @test all(x -> x[1] in 1:3, alloc)
    # Priorities should be non-negative
    @test all(x -> x[2] >= 0.0, alloc)
end

# ── §13 MM2Compiler — Algorithm 14 (§9) ──────────────────────────────────────

@testset "MM2Compiler — sprint_mcore_to_mm2" begin
    g = MCoreGraph()
    id_s = add_sym!(g, Sym(:foo))
    id_l = add_lit!(g, Lit(42))
    id_v = add_var!(g, Var(0))
    id_c = add_con!(g, Con(:pair, [id_s, id_v]))

    @test sprint_mcore_to_mm2(g, id_s) == "foo"
    @test sprint_mcore_to_mm2(g, id_l) == "42"
    @test sprint_mcore_to_mm2(g, id_v) == "\$x0"
    @test sprint_mcore_to_mm2(g, id_c) == "(pair foo \$x0)"
end

@testset "MM2Compiler — priority encoding (§9.3)" begin
    @test sprint_priority(MM2Priority(1)) == "(1 0)"
    @test sprint_priority(MM2Priority(3, 2)) == "(3 2)"
    @test MM2Priority(1) < MM2Priority(2)
    @test MM2Priority(2, 0) < MM2Priority(2, 1)
end

@testset "MM2Compiler — compile_conditional! produces 2 atoms" begin
    g   = MCoreGraph()
    ctx = CompileCtx(g)
    id_cond = add_sym!(g, Sym(:cond))
    id_then = add_sym!(g, Sym(:then_val))
    id_else = add_sym!(g, Sym(:else_val))

    atoms = compile_conditional!(ctx, id_cond, id_then, id_else)
    @test length(atoms) == 2
    # First atom: pattern contains cond
    @test occursin("cond", atoms[1].pattern)
    # Second atom: pattern contains "not"
    @test occursin("not", atoms[2].pattern)
    # Second atom has higher priority
    @test atoms[1].priority < atoms[2].priority
end

@testset "MM2Compiler — compile_program produces loadable s-exprs" begin
    g   = MCoreGraph()
    id_pat  = add_con!(g, Con(:edge, [add_var!(g, Var(0)), add_var!(g, Var(1))]))
    id_tmpl = add_con!(g, Con(:node, [add_var!(g, Var(0))]))
    id_exec = add_prim!(g, Prim(:mm2_exec, [NULL_NODE, id_pat, id_tmpl], EffectSet(UInt8(0x05))))

    prog, obligs = compile_program(g, [id_exec])
    @test !isempty(prog)
    @test occursin("exec", prog)
    @test !isempty(obligs)
    # All three bisimulation obligations recorded
    kinds = Set(o.kind for o in obligs)
    @test :forward_sim  in kinds
    @test :backward_sim in kinds
    @test :fairness     in kinds
end

@testset "MM2Compiler — sequential compilation preserves order" begin
    g   = MCoreGraph()
    ctx = CompileCtx(g)
    ids = [add_prim!(g, Prim(:mm2_exec, NodeID[], EffectSet(UInt8(0x05)))) for _ in 1:3]
    atoms = compile_sequential!(ctx, ids)
    @test length(atoms) == 3
    # Priorities must be strictly increasing
    @test atoms[1].priority < atoms[2].priority < atoms[3].priority
end

println("All tests passed ✓")
