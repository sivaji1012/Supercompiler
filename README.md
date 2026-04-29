# MorkSupercompiler.jl

A formally-grounded supercompiler for MeTTa+MM2, implemented in Julia.

Implements the full specification from three design documents by Ben Goertzel (Oct–Apr 2025/2026):

| Document | Coverage |
|----------|----------|
| *A MORK-Native Supercompiler for MeTTa+MM2* (Oct 2025) | ✅ Complete — all 14 algorithms, all data structures |
| *Approximate Supercompilation for MeTTa+MM2* (Oct 2025) | 🔄 In progress — p-box stubs present, algebra next |
| *A Multi-Geometry Hyperon Methods Framework* (Apr 2026) | 📋 Planned |

**Repo**: [sivaji1012/Supercompiler](https://github.com/sivaji1012/Supercompiler)  
**Depends on**: [sivaji1012/MORK](https://github.com/sivaji1012/MORK) + [sivaji1012/PathMap](https://github.com/sivaji1012/PathMap)

---

## Quick Start

```julia
using MorkSupercompiler, MORK

s = new_space()
space_add_all_sexpr!(s, "(edge 0 1) (edge 1 2) (edge 2 3)")

result = sc_run!(s, raw"(exec 0 (, (edge $x $y) (edge $y $z)) (, (path $x $z)))")
println(timing_report(result))
println(sc_explain(s, raw"(exec 0 (, (edge $x $y) (edge $y $z)) (, (path $x $z)))"))
```

### Development REPL (warm, Revise-enabled)

```bash
julia --project=. -i tools/sc_repl.jl
```
```julia
t()                   # run all tests (no restart)
plan(prog)            # static source reordering
report(facts, prog)   # join-plan explanation
run(facts, prog, n)   # plan + execute n steps
```

---

## Architecture

Six layers mirroring the MM2 Supercompiler spec §10 roadmap:

```
src/
  frontend/           S-expression parser (SExpr.jl)
  core/               M-Core IR (MCore.jl) + Effect algebra (Effects.jl)       §3–4
  planner/            Selectivity, Statistics, QueryPlanner                     §5
  rewrite/            Source reorderer (Rewrite.jl)
  supercompiler/      Stepper, CanonicalKeys, BoundedSplit,                     §6–8
                      KBSaturation, EvoSpecializer
  codegen/            MM2Compiler (Algorithm 14 bisimulation)                   §9
  integration/        SCPipeline, Profiler, Explainer, AdaptivePlanner          §10.4
  approx/             (in progress) P-box algebra, uncertain inference          approx spec
```

---

## Implemented Algorithms — Doc 1 (MM2 Supercompiler Spec)

| # | Algorithm | Section | File | ✓ |
|---|-----------|---------|------|---|
| 1 | EffectCommutes | §4.2 | `core/Effects.jl` | ✅ |
| 2 | EstimatePatternCardinality | §5.1.2 | `planner/Statistics.jl` | ✅ |
| 3 | PrefixSampling | §5.1.3 | `planner/Statistics.jl` | ✅ |
| 4 | UpdateIncrementalStats | §5.2.1 | `planner/Statistics.jl` | ✅ |
| 5 | ShouldReplan | §5.2.2 | `integration/AdaptivePlanner.jl` | ✅ |
| 6 | EffectAwarePlanning | §5.3.1 | `planner/QueryPlanner.jl` | ✅ |
| 7 | RewriteOnce | §6.1 | `supercompiler/Stepper.jl` | ✅ |
| 8 | CallPrimitive | §6.1 | `supercompiler/Stepper.jl` | ✅ |
| 9 | BoundedSplit | §6.2 | `supercompiler/BoundedSplit.jl` | ✅ |
| 10 | KeySubsumption | §6.3.2 | `supercompiler/CanonicalKeys.jl` | ✅ |
| 11 | IncrementalSaturation | §7.1 | `supercompiler/KBSaturation.jl` | ✅ |
| 12 | GatedEvolutionarySpecialization | §8.1 | `supercompiler/EvoSpecializer.jl` | ✅ |
| 13 | CanReuseFitnessCache | §8.2 | `supercompiler/EvoSpecializer.jl` | ✅ |
| 14 | BisimulationProof | §9.2 | `codegen/MM2Compiler.jl` | ✅ |

## Data Structures — Doc 1 (Spec Appendix B)

| Structure | File | Spec Fields |
|-----------|------|-------------|
| 11 M-Core node types | `core/MCore.jl` | Sym, Var, Lit, Con, App, Abs, LetNode, MatchNode, Choice, Prim, MCoreRef |
| `Effect` algebra | `core/Effects.jl` | Read, Write, Append, Create, Delete, Observe, Pure |
| `MORKStatistics` | `planner/Statistics.jl` | node_type_counts, pattern_shape_histogram, predicate_fanout, argument_selectivity, pattern_match_cache, correlation_matrix |
| `IncrementalStats` | `planner/Statistics.jl` | base, delta, growth_rate, selectivity_drift, last_replan_time |
| `EffectStats` | `planner/Statistics.jl` | pattern_effect_probability, effect_correlation, effect_cost, effect_frequency |
| `CanonicalPathSig` | `supercompiler/CanonicalKeys.jl` | head, shape, tags, depth, kb_sig, effect_sig |
| `VersionedIndex` | `supercompiler/KBSaturation.jl` | version, index, delta_since, stats, last_replan_ver |
| `UncertainNode` + `PBox` | `core/MCore.jl` | From approx spec §2.4 |

---

## Tests

253 tests, organized by layer:

```
test/
  runtests.jl                         master runner (includes all)
  frontend/    test_sexpr.jl
  core/        test_mcore.jl  test_effects.jl
  planner/     test_statistics.jl  test_selectivity.jl  test_query_planner.jl
  rewrite/     test_rewrite.jl
  supercompiler/
               test_stepper.jl  test_canonical_keys.jl  test_bounded_split.jl
               test_kb_saturation.jl  test_evo_specializer.jl
  codegen/     test_mm2_compiler.jl
  integration/ test_pipeline.jl  test_profiler.jl  test_explainer.jl
               test_adaptive_planner.jl
```

---

## Public API

### Pipeline

```julia
sc_run!(s, program; opts)        # stats → plan → execute, returns SCResult
sc_run(facts, program; steps)    # fresh space + run
timing_report(result)            # per-phase ms breakdown
```

### Explanation

```julia
sc_explain(s, program)           # join order + cardinalities + variable flow
sc_dot(program)                  # Graphviz DOT source
sc_diff(original, planned)       # what changed after planning
```

### Profiling

```julia
sc_profile(facts, program; steps, trials)  # baseline vs planned timing
speedup_report(profile)                    # formatted speedup table
```

### Adaptive Replanning

```julia
ap = AdaptivePlan(s, program)
sc_run_adaptive!(s, ap; steps)   # auto-replan when cardinalities drift
```

### Query Planner

```julia
collect_stats(s; sample_frac)    # build MORKStatistics (Algorithms 2+3)
sc_plan_static(program)          # reorder sources, no Space needed
sc_plan_program(s, program)      # reorder using live btm prefix counts
plan_query(sources, stats)       # Algorithm 6: (planned_sources, barriers)
```

### Supercompiler Core

```julia
rewrite_once(g, id, env, deps, registry)   # Algorithm 7 RewriteOnce
bounded_split(g, id, env, stats; budget)   # Algorithm 9 BoundedSplit
canonical_key(g, id, depth)                # CanonicalPathSig
subsumes(key1, key2)                       # Algorithm 10 KeySubsumption
saturate!(kb; max_rounds)                  # Algorithm 11 IncrementalSaturation
compile_program(g, root_ids)               # Algorithm 14 → MM2 exec s-expressions
```

---

## What's Next

**Doc 2 — Approximate Supercompilation** (`src/approx/`):

| File | Algorithms | Spec |
|------|-----------|------|
| `PBoxAlgebra.jl` | AddPBox, Fréchet bounds | §2.3 Alg 1 |
| `UncertainQuery.jl` | EstimateCardinalityPBox, MatchWithUncertainty | §3 Alg 2+3 |
| `UncertainInference.jl` | UncertainModusPonens (AND/OR with correlation) | §4 Alg 4 |
| `ApproxMOSES.jl` | TournamentWithPBox | §5 Alg 6 |
| `ApproxPipeline.jl` | 4-phase approximate pipeline, ApproxIndex, ApproximatePathSig | §6 |
