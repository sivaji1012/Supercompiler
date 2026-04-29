using Test
using MorkSupercompiler

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
