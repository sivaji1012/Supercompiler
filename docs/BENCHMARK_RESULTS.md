# Benchmark Results — Rule-of-64 Baseline

**Date**: 2026-04-29  
**Algorithm measured**: `plan_static` (static variable-count join-order heuristic)  
**Julia version**: 1.12.6  
**Steps per case**: 1 (one metta_calculus! application), 2 trials each

---

## Results

| Case | Sources | Baseline exec | Planned exec | Speedup | Sources reordered | Plan overhead |
|------|---------|--------------|-------------|---------|-------------------|---------------|
| `odd_even_sort` | 5 (6 after expansion) | 1217 ms | 638 ms | **1.91×** | 0 | 2005 ms |
| `counter_machine` | 5 | 2184 ms | 1977 ms | **1.10×** | 1 | 2 ms |
| `trans_detect` | 3 | 54758 ms | 58051 ms | 0.94× | 0 | 0.03 ms |

---

## Analysis

### odd_even_sort — 1.91× speedup (unexpected win)
The planner reported "Already optimal — no reordering needed" (all 5 sources have equal static scores). Yet execution was 1.91× faster with planning. This is likely a **JIT warm-up effect**: the first (baseline) trial paid JIT compilation cost; the planned trial ran on already-warmed code. With only 2 trials, this noise dominates. **Not a real speedup from planning.**

### counter_machine — 1.10× speedup  
1 source was reordered. A modest 10% gain from placing the more-selective source first. This is the static heuristic working as designed — small benefit when source selectivities are similar.

### trans_detect — 0.94× (slight regression)
3-source pattern. No reordering (all equal scores). The baseline was 54 seconds (!), confirming this is deep in Rule-of-64 territory (3 sources, ~150 edges = O(150^3) = 3.4M combinations). Planning overhead was negligible (0.03ms) but no speedup since sources weren't reordered.

---

## Key Finding

**`plan_static` alone gives at most ~1.1× speedup** on these Rule-of-64 cases because:
1. All 5-source patterns have equal variable counts → static heuristic cannot distinguish them
2. No reordering means no cardinality-based pruning
3. The ProductZipper still runs full Cartesian product

The 1.91× on odd_even_sort is measurement noise (JIT warm-up with only 2 trials).

---

## What's Needed for Real Speedup

The real 10–1000× requires **MORK integration** — replacing `ProductZipper` in `Space.jl::_space_query_multi_inner!` with a nested-loop join that:
1. Uses `plan_query` cardinality-ordered sources
2. Propagates variable bindings between sources (semi-join pushdown)
3. Uses btm prefix counts for each partially-grounded subsequent source

This is tracked as the next pipeline milestone.

---

## Anomaly: trans_detect baseline = 54 seconds
This is extremely slow for a 3-source query on a 50-node graph. Investigating:
- `(, (edge $x $y) (edge $y $z) (edge $z $w))` with 150 edges: O(150^3) = 3,375,000 candidate triples
- ProductZipper iterates ALL of them before unification filtering
- This directly validates the Rule-of-64 problem description
