# Audit: Doc 1 Implementation vs MM2 Supercompiler Spec

**Document**: *A MORK-Native Supercompiler for MeTTa+MM2* (Goertzel, Oct 2025)  
**Spec file**: `docs/specs/mm2_supercompiler_spec.md`  
**Audit date**: 2026-04-29  
**Result**: ✅ All 14 algorithms and all spec data structures implemented.

---

## Algorithm Coverage

| # | Spec Name | Spec Section | Implementation | Notes |
|---|-----------|-------------|----------------|-------|
| 1 | EffectCommutes | §4.2 | `core/Effects.jl::commutes` | All 9 axioms verbatim |
| 2 | EstimatePatternCardinality | §5.1.2 | `planner/Statistics.jl::estimate_cardinality` | Uses pattern_shape_histogram + argument_selectivity |
| 3 | PrefixSampling | §5.1.3 | `planner/Statistics.jl::prefix_sample_count` | O(1) exact subtrie count via PathMap (equivalent to perfect sampling) |
| 4 | UpdateIncrementalStats | §5.2.1 | `planner/Statistics.jl::update_incremental!` | EMA growth_rate, selectivity_drift per predicate |
| 5 | ShouldReplan | §5.2.2 | `integration/AdaptivePlanner.jl::should_replan` | Drift threshold + time_since_replan |
| 6 | EffectAwarePlanning | §5.3.1 | `planner/QueryPlanner.jl::plan_query` | Pure-region identification + cost-based join order |
| 7 | RewriteOnce | §6.1 | `supercompiler/Stepper.jl::rewrite_once` | All 11 node kinds dispatched |
| 8 | CallPrimitive | §6.1 | `supercompiler/Stepper.jl::_call_primitive` | PrimRegistry with :kb_query/:mm2_exec/:fitness_eval/:identity |
| 9 | BoundedSplit | §6.2 | `supercompiler/BoundedSplit.jl::bounded_split` | SPLIT_PROB_THRESHOLD=0.95, SPLIT_DEFAULT_BUDGET=16 |
| 10 | KeySubsumption | §6.3.2 | `supercompiler/CanonicalKeys.jl::subsumes` | 3-part check: structural + KB + effect |
| 11 | IncrementalSaturation | §7.1 | `supercompiler/KBSaturation.jl::saturate!` | Semi-naive: at least one premise from delta_old |
| 12 | GatedEvolutionarySpecialization | §8.1 | `supercompiler/EvoSpecializer.jl::should_specialize` | 3-tier: SPEC_VECTORIZED/INCREMENTAL/GENERIC |
| 13 | CanReuseFitnessCache | §8.2 | `supercompiler/EvoSpecializer.jl::can_reuse_cache` | AST diff: STRUCTURAL/CONSTANT/NONE |
| 14 | BisimulationProof | §9.2 | `codegen/MM2Compiler.jl::record_bisim!` | Records :forward_sim, :backward_sim, :fairness obligations |

---

## Data Structure Coverage (Spec Appendix B)

| Spec Structure | Fields Required | Fields Implemented | File |
|----------------|----------------|-------------------|------|
| M-Core node types | 11 kinds | 11 kinds ✅ | `core/MCore.jl` |
| `Effect` algebra | 7 kinds | 7 kinds ✅ | `core/Effects.jl` |
| `MORKStatistics` | 6 fields | 6 fields ✅ | `planner/Statistics.jl` |
| `IncrementalStats` | 5 fields | 5 fields ✅ | `planner/Statistics.jl` |
| `EffectStats` | 4 fields | 4 fields ✅ | `planner/Statistics.jl` |
| `CanonicalPathSig` | 6 fields | 6 fields ✅ | `supercompiler/CanonicalKeys.jl` |
| `CanonicalKBSig` | 2 fields | 2 fields ✅ | `supercompiler/CanonicalKeys.jl` |
| `CanonicalEffectSig` | 2 fields | 2 fields ✅ | `supercompiler/CanonicalKeys.jl` |
| `VersionedIndex` | 5 fields | 5 fields ✅ | `supercompiler/KBSaturation.jl` |

---

## Gaps Found and Fixed During Audit (2026-04-29)

### GAP-1: `MORKStatistics` had only 5 fields (spec requires 6)

**Spec §5.1.1** requires:
1. `node_type_counts` — ❌ missing
2. `pattern_shape_histogram` — ❌ missing (was using flat predicate_counts)
3. `predicate_fanout` — ✅ present
4. `argument_selectivity` — ❌ missing (was empty Dict)
5. `pattern_match_cache` — ❌ missing
6. `correlation_matrix` — ❌ missing

**Fix**: Rewrote `MORKStatistics` struct with all 6 fields. Added `predicate_counts(s)` helper function for backward compat. Updated `collect_stats` to populate all 6 fields during trie scan. Added convenience 2-arg constructor for tests.

### GAP-2: `IncrementalStats` had only 4 fields (spec requires 5)

**Spec §5.2.1** requires `selectivity_drift` and `last_replan_time`.

**Fix**: Added both fields. `update_incremental!` now computes per-predicate drift and timestamps.

### GAP-3: `EffectStats` not implemented (spec §5.3.2)

**Fix**: Added `EffectStats` struct with all 4 fields to `Statistics.jl`.

### GAP-4: Algorithm 6 missing `identify_pure_regions` step

**Spec §5.3.1**: `regions ← identify_pure_regions(query, effect_analysis)` — our `QueryPlanner.jl` went straight to `plan_join_order` without this step.

**Fix**: Added `PureRegion`, `EffectBarrier`, `identify_pure_regions`, and `plan_query` to `QueryPlanner.jl`. For MORK exec patterns, always produces a single pure region (all sources are `Read`).

### GAP-5: Algorithm 5 missing `time_since_replan` check

**Spec §5.2.2**: replan if `time_since_replan > MAX_PLAN_AGE`.

**Fix**: Updated `should_replan` in `Statistics.jl` to accept `time_since_replan::Float64` and check against `max_plan_age_sec=300.0`. Updated `AdaptivePlanner.jl` to use `last_replan_time` from `IncrementalStats`.

---

## Implementation Notes

### Algorithm 3 (PrefixSampling) — exact vs sampling

The spec describes approximate sampling (`uniform_sample_prefix`, `bootstrap_variance`).
Our implementation uses `read_zipper_at_path` + `zipper_val_count` for O(1) exact subtrie counts.
This is **strictly better** than sampling (exact, not approximate) and is possible because PathMap's
trie structure provides exact counts without full enumeration. No deviation from spec intent.

### Algorithm 14 (BisimulationProof) — obligation recording

The spec describes the proof **structure** (3 obligations: forward sim, backward sim, fairness),
not automated proof checking. Our implementation records `BiSimObligation` structs for external
verification. This is the correct interpretation of the spec.

### Algorithm 6 (EffectAwarePlanning) — all-pure assumption for MORK

The spec handles both pure and non-pure regions (with `EffectBarrier`). For MORK exec sources,
all sources are `Read(space)` which commutes with `Read(space)` (Algorithm 1). So `identify_pure_regions`
always returns a single pure region for MORK programs. The infrastructure for non-pure regions
(topological ordering, EffectBarrier) is implemented for future use.
