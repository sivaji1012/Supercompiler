using Test
using MorkSupercompiler

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
