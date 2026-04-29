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

include("SExpr.jl")
include("MCore.jl")
include("Effects.jl")
include("Selectivity.jl")
include("Rewrite.jl")
include("Statistics.jl")
include("QueryPlanner.jl")

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

end # module
