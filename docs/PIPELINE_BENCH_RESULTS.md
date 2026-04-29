# Pipeline Decomposition Benchmark — Rule-of-64 Real Speedup

**Date**: 2026-04-29  
**Algorithm**: `decompose_program` (PipelineDecompose.jl)  
**Julia version**: 1.12.6  
**Trials**: 2 (median)

---

## Results

| Case | Sources | Stages | Baseline | Decomposed | Speedup |
|------|---------|--------|----------|------------|---------|
| `trans_detect` (K=150 edges) | 3 | 2 | 79,083 ms | 459 ms | **172×** |
| `counter_machine` JZ step | 5 | 4 | ~0 ms | ~0 ms | ~2.3× (noise) |
| `odd_even_sort` | 5 | 4 | ~0 ms | ~0 ms | ~2.3× (noise) |

---

## Trans-Detect — 172× Speedup (Confirmed Rule-of-64 Fix)

**Input**: `(exec 0 (, (edge $x $y) (edge $y $z) (edge $z $w)) (, (dtrans $x $y $z $w)))`  
**Facts**: 150 edges on a 50-node graph

**Baseline**: ProductZipper O(150³) = 3,375,000 candidate triples → **79 seconds**

**Decomposed** into 2 stages:
```
Stage 1: (exec 0 (, (edge $x $y) (edge $y $z)) (, (_sc_tmp0 $x $y $z)))
Stage 2: (exec 0 (, (_sc_tmp0 $x $y $z) (edge $z $w)) (, (dtrans $x $y $z $w)))
```
- Stage 1: O(150²) = 22,500 pairs → writes `_sc_tmp0` atoms
- Stage 2: O(M × 150) where M = actual matching pairs from stage 1 → **459 ms**

**172× speedup** = 79,083ms / 459ms. Exceeds the 10-100× target.

---

## 5-Source Cases — Sub-Millisecond (Noise Floor)

Both `counter_machine` (5 sources, Peano arithmetic) and `odd_even_sort` (5 sources, array sort step) complete in **under 1ms** for these small fact sets. The ~2.3× figure is measurement noise — the baseline is too fast to benchmark reliably at steps=1.

To properly benchmark 5-source speedup requires larger fact sets where the O(K⁵) baseline becomes measurable.

### Counter-machine 5-source decomposition (correct):
```
Stage 1: ((step JZ $ts) (, (state $ts (IC $i)) (program $i (JZ $r $j)))
                         (, (_sc_tmp0 $i $j $r $ts)))
Stage 2: ((step JZ $ts) (, (_sc_tmp0 $i $j $r $ts) (state $ts (REG $r $v)))
                         (, (_sc_tmp1 $i $j $ts $v)))
Stage 3: ((step JZ $ts) (, (_sc_tmp1 $i $j $ts $v) (state $ts (REG $k $kv)))
                         (, (_sc_tmp2 $i $j $k $kv $ts $v)))
Stage 4: ((step JZ $ts) (, (_sc_tmp2 $i $j $k $kv $ts $v) (if $v (S $i) $j $ni))
                         (, (state (S $ts) (IC $ni)) (state (S $ts) (REG $k $kv))))
```

---

## Key Result

`decompose_program` delivers a **172× speedup** on the canonical Rule-of-64 case
(`trans_detect`, 3 sources, 150 edges).

The algorithm is correct: intermediate `_sc_tmp*` atoms carry all variables
needed downstream (both for subsequent join sources and the final template),
implementing semi-join pushdown without any MORK internals changes.

---

## Comparison with plan_static Baseline

| Approach | trans_detect speedup |
|----------|---------------------|
| `plan_static` (source reordering) | 0.94× (no gain) |
| `decompose_program` (pipeline) | **172×** |

The 183× delta confirms: join-order reordering alone cannot fix Rule-of-64.
Only structural decomposition that limits stage arity to ≤ STAGE_MAX_SOURCES (=2)
delivers the required speedup.
