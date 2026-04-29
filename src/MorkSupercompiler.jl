"""
MorkSupercompiler — query planner and source-reordering supercompiler for MORK.

Implements Phase 0 of the MM2 Supercompiler design (Goertzel, Oct 2025):
  - §3    M-Core IR foundation (SExpr layer)
  - §5    Query planner with MORK-native cardinality estimation
  - §5.3  Effect-aware join ordering (all exec sources are Read → freely reorder)
  - §5.1  Statistics collection (MORKStatistics)
  - §5.2  Incremental statistics under monotonic growth

Usage (static planning, no Space needed):
  program′ = sc_plan_static(program)
  space_add_all_sexpr!(s, program′)
  space_metta_calculus!(s, max_steps)

Usage (dynamic planning, uses btm cardinalities):
  sc_plan!(s, program)    # adds reordered program to s and runs metta_calculus
  -- or --
  program′ = sc_plan_program(s, program)

Public API:
  sc_plan_static(program)          — pure-string reorder (no Space)
  sc_plan_program(s, program)      — reorder using btm prefix counts
  sc_plan!(s, program, steps)      — add + run in one call
  sc_collect_stats(s)              — build MORKStatistics for s
  sc_plan_report(s, program)       — human-readable join-plan report

Architecture references:
  SExpr.jl      — s-expression parser (M-Core surface syntax)
  Statistics.jl — MORKStatistics + Algorithms 2/3
  Selectivity.jl — dynamic_count / static_score
  Rewrite.jl    — source reordering (pure static, backward-compat)
  QueryPlanner.jl — Algorithm 6 (EffectAwarePlanning) + variable flow
"""
module MorkSupercompiler

using MORK
using PathMap

# Layer 1 — Surface syntax (s-expression parser)
include("frontend/SExpr.jl")

# Layer 2 — Core IR + Effect algebra (§3 + §4 of MM2 spec)
include("core/MCore.jl")
include("core/Effects.jl")

# Layer 3 — Query Planner (§5 of MM2 spec)
include("planner/Selectivity.jl")
include("planner/Statistics.jl")
include("planner/QueryPlanner.jl")

# Layer 4 — Source rewriting (join-order reordering)
include("rewrite/Rewrite.jl")

# Layer 5 — Core Supercompiler (§6 of MM2 spec)
include("supercompiler/Stepper.jl")
include("supercompiler/CanonicalKeys.jl")
include("supercompiler/BoundedSplit.jl")

# Layer 6 — Phase 3 Specializations + Code Generation (§7–9)
include("supercompiler/KBSaturation.jl")
include("supercompiler/EvoSpecializer.jl")
include("codegen/MM2Compiler.jl")

# Layer 7 — Integration + Production Hardening (§10.4)
include("integration/SCPipeline.jl")
include("integration/Profiler.jl")
include("integration/Explainer.jl")
include("integration/AdaptivePlanner.jl")

# ── High-level public API ─────────────────────────────────────────────────────

"""
    sc_plan_static(program::AbstractString) -> String

Reorder sources in all conjunction lists using static selectivity only
(variable-fraction heuristic).  No Space or statistics required.
Cheapest option; use when no background facts are loaded yet.
"""
sc_plan_static(program::AbstractString) :: String =
    reorder_program_static(program)

"""
    sc_collect_stats(s::Space; sample_frac=1.0) -> MORKStatistics

Scan `s` and build MORK-aware statistics (predicate counts, fanout estimates).
Use `sample_frac < 1.0` for large spaces.
"""
sc_collect_stats(s::Space; sample_frac::Float64=1.0) :: MORKStatistics =
    collect_stats(s; sample_frac=sample_frac)

"""
    sc_plan_program(s::Space, program::AbstractString) -> String

Reorder sources using dynamic btm-prefix cardinality counts.
More accurate than `sc_plan_static` when background facts are already loaded.
`program` is the exec/rule string to reorder (NOT yet added to `s`).
"""
sc_plan_program(s::Space, program::AbstractString) :: String =
    plan_program_dynamic(program, s.btm)

"""
    sc_plan_program(stats::MORKStatistics, program::AbstractString) -> String

Reorder using pre-collected statistics (avoids re-scanning the space).
"""
sc_plan_program(stats::MORKStatistics, program::AbstractString) :: String =
    plan_program(program, stats)

"""
    sc_plan!(s::Space, program::AbstractString, max_steps::Int=typemax(Int)) -> Int

Plan, add, and execute in one call:
  1. Reorder sources in `program` using btm prefix counts
  2. Add the reordered program to `s`
  3. Run `space_metta_calculus!(s, max_steps)`
  4. Return the number of steps executed

Equivalent to:
  program′ = sc_plan_program(s, program)
  space_add_all_sexpr!(s, program′)
  space_metta_calculus!(s, max_steps)
"""
function sc_plan!(s::Space, program::AbstractString,
                  max_steps::Int=typemax(Int)) :: Int
    program′ = sc_plan_program(s, program)
    space_add_all_sexpr!(s, program′)
    space_metta_calculus!(s, max_steps)
end

"""
    sc_plan_report(s::Space, program::AbstractString) -> String

Return a human-readable string showing, for each multi-source conjunction in
`program`, the original order, estimated cardinalities, and planned order.
"""
function sc_plan_report(s::Space, program::AbstractString) :: String
    stats = sc_collect_stats(s)
    plan_report(program, stats)
end

# Re-export the most useful lower-level symbols
export sc_plan_static, sc_plan_program, sc_plan!, sc_plan_report
export sc_collect_stats
export MORKStatistics, IncrementalStats, collect_stats, merged_stats
export estimate_cardinality, prefix_sample_count
export SNode, SAtom, SVar, SList
export parse_program, parse_sexpr, sprint_sexpr, sprint_program
export plan_join_order, plan_join_order_static, plan_report
export reorder_program_static, reorder_program_dynamic
export source_order_report
export JoinNode, build_join_nodes, build_join_nodes_dynamic
export effects_commute, EffectKind, EFF_PURE, EFF_READ, EFF_APPEND, EFF_WRITE, EFF_OBSERVE
# MCore IR (Phase 1)
export NodeID, NULL_NODE, EffectSet, SpaceID, DEFAULT_SPACE
export MCoreNode, Sym, Var, Lit, Con, App, Abs, LetNode, MatchNode, MatchClause
export Choice, ChoiceAlt, Prim, MCoreRef, UncertainNode, PBox
export MCoreGraph, get_node
export add_sym!, add_var!, add_lit!, add_con!, add_app!, add_abs!
export add_let!, add_match!, add_choice!, add_prim!, add_mref!
export compile_kb_query, compile_mm2_exec
# Effect algebra (Phase 1)
export Effect, ReadEffect, WriteEffect, AppendEffect
export CreateEffect, DeleteEffect, ObserveEffect, PureEffect, PURE
export commutes, commutes_all, is_sink_free, sink_free_check, mork_source_effects
# Stepper (Phase 2)
export StepResult, Value, Blocked, Residual
export Env, env_lookup, env_extend
export DepSet, can_proceed, add_dep
export PrimRegistry, register_prim!, lookup_prim, DEFAULT_PRIM_REGISTRY
export rewrite_once, step_to_value
# CanonicalKeys (Phase 2)
# BoundedSplit (Phase 2)
export Branch, SplitResult, bounded_split
export SPLIT_PROB_THRESHOLD, SPLIT_DEFAULT_BUDGET
# KBSaturation (Phase 3 §7)
export Fact, is_base_fact, Rule
export VersionedIndex, index_insert!, index_lookup, index_delta_since, bump_version!
export KBState, kb_add_fact!, kb_add_rule!, all_facts, saturate!
# EvoSpecializer (Phase 3 §8)
export SpecLevel, SPEC_GENERIC, SPEC_INCREMENTAL, SPEC_VECTORIZED
export SpecDecision, should_specialize
export ChangeKind, CHANGE_NONE, CHANGE_CONSTANT, CHANGE_STRUCTURAL
export ASTDiff, compute_ast_diff, CacheMetadata, can_reuse_cache
export EvolutionaryPBox, approximate_fitness, allocate_evaluations
# MM2Compiler (Phase 3 §9)
export MM2Priority, MM2ExecAtom, sprint_exec, sprint_priority
export CompileCtx, BiSimObligation
export compile_sequential!, compile_conditional!, compile_node!, compile_program
export sprint_mcore_to_mm2
# Integration layer (Phase 4)
export SCOptions, SC_DEFAULTS, SCResult, sc_run!, sc_run, timing_report
export ProfilePhase, SCProfile, sc_profile, speedup_report
export sc_explain, sc_dot, sc_diff
export AdaptivePlan, should_replan, replan!, sc_run_adaptive!, update_stats!
export MAX_PLAN_AGE, REPLAN_DRIFT
# CanonicalKeys (Phase 2)
export CompactShape, shape_subsumes, extract_shape
export FixedArgMask, CanonicalKBSig, CanonicalEffectSig, CanonicalPathSig
export canonical_key, subsumes
export FoldTable, record!, lookup_fold, can_fold

end # module
