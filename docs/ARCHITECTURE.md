# MorkSupercompiler.jl — Architecture Reference

---

## Layer Map

```
┌─────────────────────────────────────────────────────────────┐
│  User code / warm REPL (tools/sc_repl.jl)                   │
├─────────────────────────────────────────────────────────────┤
│  Layer 7 — Integration  (src/integration/)                   │
│  SCPipeline · Profiler · Explainer · AdaptivePlanner         │
├─────────────────────────────────────────────────────────────┤
│  Layer 6 — Code Generation  (src/codegen/)                   │
│  MM2Compiler (Algorithm 14, bisimulation, priority encoding) │
├─────────────────────────────────────────────────────────────┤
│  Layer 5 — Core Supercompiler  (src/supercompiler/)          │
│  Stepper · CanonicalKeys · BoundedSplit                      │
│  KBSaturation · EvoSpecializer                               │
├─────────────────────────────────────────────────────────────┤
│  Layer 4 — Source Rewriting  (src/rewrite/)                  │
│  Rewrite (join-order reordering of `,` source lists)         │
├─────────────────────────────────────────────────────────────┤
│  Layer 3 — Query Planner  (src/planner/)                     │
│  Selectivity · Statistics (Algorithms 2-5) · QueryPlanner    │
├─────────────────────────────────────────────────────────────┤
│  Layer 2 — Core IR + Effect algebra  (src/core/)             │
│  MCore (11 node types) · Effects (Algorithm 1)               │
├─────────────────────────────────────────────────────────────┤
│  Layer 1 — Surface Syntax  (src/frontend/)                   │
│  SExpr parser + serializer                                   │
├─────────────────────────────────────────────────────────────┤
│  MORK.jl + PathMap.jl  (external dependencies)               │
└─────────────────────────────────────────────────────────────┘
```

---

## Data Flow: `sc_run!`

```
User calls sc_run!(s, program)
  │
  ├─ 1. collect_stats(s)               → MORKStatistics
  │         Scans btm trie O(√n), builds 6-field stats struct.
  │         Populates pattern_shape_histogram, argument_selectivity,
  │         correlation_matrix.
  │
  ├─ 2. plan_program(program, stats)   → planned_program (String)
  │         Parses program → SNode tree
  │         For each multi-source `,` conjunction:
  │           identify_pure_regions(sources)      Algorithm 6 §5.3.1
  │           build_join_nodes(sources, stats)    JoinNode w/ cardinality
  │           plan_join_order(nodes)              greedy + semi-join penalty
  │         Serializes reordered SNodes back to string
  │
  ├─ 3. (optional) saturate!(kb)       → derived facts added to kb
  │
  ├─ 4. (optional) compile_program()   → MM2 exec s-expressions
  │         Lowers M-Core nodes via MM2Compiler
  │         Records BiSimObligations (§9.2 Algorithm 14)
  │
  └─ 5. space_add_all_sexpr!(s, planned_program)
         space_metta_calculus!(s, max_steps)
         → SCResult (steps, timings, obligs, plan_report)
```

---

## Key Design Decisions

### 1. Source reordering is the primary optimization

For MORK exec patterns, all sources are `Read(space)` effects. Algorithm 1 says `Read` commutes with `Read` → they form a pure region → free reordering.

The optimal order puts the most selective source first. With N sources each matching K atoms, naive ProductZipper costs O(K^N). Reordering so the most selective (K=1) comes first reduces to O(1 × K^(N-1)). This is the **Rule-of-64 fix**.

### 2. BoundedSplit handles the remaining fan-out

When N sources each have K > 1 matches, BoundedSplit prunes branches by probability (cumulative ≥ 0.95). This converts O(K^N) to O(budget × K^(N-1)) exploration.

### 3. Canonical keys ensure termination

`CanonicalPathSig` (depth-3 shape, sorted tag multiset) provides a finite key space. `subsumes(key1, key2)` detects when a current expression has been seen before, allowing safe folding. This is the formal termination guarantee.

### 4. Semi-naive KB saturation avoids quadratic cost

`KBSaturation.saturate!` implements semi-naive evaluation: each rule only fires when at least one premise comes from the **current delta** (new facts this round). This gives O(Δ) cost per round instead of O(total²).

### 5. Bisimulation obligations are recorded, not proven

`MM2Compiler` records 3 proof obligations per compiled exec atom:
- `:forward_sim` — if MeTTa trace exists, MM2 produces it
- `:backward_sim` — if MM2 trace exists, MeTTa trace matches
- `:fairness` — MM2 priority ordering preserves MeTTa fairness

These are discharged externally (by theorem provers or by construction). The compiler does not automate proof generation.

---

## Type Hierarchy

```julia
# M-Core IR
abstract type MCoreNode end
  Sym, Var, Lit, Con, App, Abs, LetNode, MatchNode, Choice, Prim, MCoreRef, UncertainNode

# Effects
abstract type Effect end
  ReadEffect, WriteEffect, AppendEffect, CreateEffect, DeleteEffect, ObserveEffect, PureEffect

# Stepper results
abstract type StepResult end
  Value, Blocked, Residual

# S-expression (surface syntax)
abstract type SNode end
  SAtom, SVar, SList
```

---

## Statistics Schema (§5.1.1 MORKStatistics — all 6 fields)

```julia
struct MORKStatistics
  node_type_counts        :: Dict{Symbol, Int}              # :Sym/:Con/:Prim → count
  pattern_shape_histogram :: Dict{Tuple{String,Int}, Int}   # (head, arity) → count
  predicate_fanout        :: Dict{Tuple{String,Int}, Tuple{Float64,Float64}}  # (pred,pos) → (avg,var)
  argument_selectivity    :: Dict{Tuple{String,Int}, Float64}  # (pred,pos) → constrained_fraction
  pattern_match_cache     :: Dict{UInt64, Int}              # pattern_hash → count (LRU approx)
  correlation_matrix      :: Dict{Tuple{String,String}, Float64}  # (p1,p2) → co-occurrence
  total_atoms             :: Int
  sample_size             :: Int
end
```

`predicate_counts(s::MORKStatistics)` derives a `Dict{String,Int}` from `pattern_shape_histogram` (sum over all arities per head symbol).

---

## Effect Commutativity Table (Algorithm 1, §4.2)

| e1 \ e2 | Pure | Read | Write | Append(r') | Append(r) | Observe |
|---------|------|------|-------|-----------|-----------|---------|
| **Pure** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Read** | ✓ | ✓ | ✗ | ✓ (r≠r') | ✗ | ✓ |
| **Write** | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **Append(r')** | ✓ | ✓ | ✗ | ✓ (r≠r') | ✗ | ✓ |
| **Append(r)** | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ |
| **Observe** | ✓ | ✓ | ✗ | ✓ | ✓ | ✓ |

All MORK exec sources are `Read(same_space)` → all pairs commute → always a pure region.

---

## BoundedSplit Constants (§6.2)

| Constant | Value | Meaning |
|----------|-------|---------|
| `SPLIT_PROB_THRESHOLD` | 0.95 | Stop selecting branches once cumulative P ≥ 0.95 |
| `SPLIT_DEFAULT_BUDGET` | 16 | Max branches regardless of probability |

The catch-all residual (added when cumulative < 1.0) ensures **soundness**: no execution path is silently dropped.

---

## AdaptivePlanner Thresholds (§5.2.2)

| Constant | Value | Trigger |
|----------|-------|---------|
| `MAX_PLAN_AGE` | 50 | Replan after 50 `metta_calculus!` calls |
| `REPLAN_DRIFT` | 0.20 | Replan if any predicate cardinality drifts > 20% |
| atom count doubled | 2× | Replan if space grows to 2× size at last plan |
| `max_plan_age_sec` | 300s | Replan if 5 minutes since last plan (Algorithm 5) |
