using Test
using MorkSupercompiler

@testset "MorkSupercompiler" begin

    # ── Frontend ──────────────────────────────────────────────────────────────
    include("frontend/test_sexpr.jl")

    # ── Planner ───────────────────────────────────────────────────────────────
    include("planner/test_selectivity.jl")
    include("planner/test_statistics.jl")
    include("planner/test_query_planner.jl")

    # ── Rewrite ───────────────────────────────────────────────────────────────
    include("rewrite/test_rewrite.jl")

    # ── Core IR & Effects ─────────────────────────────────────────────────────
    include("core/test_mcore.jl")
    include("core/test_effects.jl")

    # ── Supercompiler ─────────────────────────────────────────────────────────
    include("supercompiler/test_stepper.jl")
    include("supercompiler/test_canonical_keys.jl")
    include("supercompiler/test_bounded_split.jl")
    include("supercompiler/test_kb_saturation.jl")
    include("supercompiler/test_evo_specializer.jl")

    # ── Code Generation ───────────────────────────────────────────────────────
    include("codegen/test_mm2_compiler.jl")

    # ── Integration ───────────────────────────────────────────────────────────
    include("integration/test_pipeline.jl")
    include("integration/test_profiler.jl")
    include("integration/test_explainer.jl")
    include("integration/test_adaptive_planner.jl")

end

println("All tests passed ✓")
