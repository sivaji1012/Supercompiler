# Pipeline Decomposition Benchmark — Rule-of-64 Real Speedup

**Date**: 2026-04-29 (corrected 2026-04-29)
**Algorithm**: `decompose_program` (PipelineDecompose.jl)
**Julia version**: 1.12.6
**Steps**: `typemax(Int)` — run to full completion (all pipeline stages)
**Trials**: 2 (median)

---

## Results

| Case | Sources→Stages | Baseline | Decomposed | Speedup | Correct? |
|------|----------------|----------|------------|---------|----------|
| `trans_detect` K=150 edges | 3→2 | ~82,000 ms | ~4,500 ms | **18.5×** | ✓ verified |
| `counter_machine` JZ step | 5→1* | <1 ms (noise) | <1 ms | — | ✓ |
| `odd_even_sort` | 5→1* | <1 ms (noise) | <1 ms | — | ✓ |

\* Rule definitions like `((phase $p) (, ...) (O ...))` and `((step JZ $ts) (, ...) (, ...))` are
**not decomposed** — only `(exec ...)` atoms are. Rule definitions use MORK's rewrite mechanism,
not `space_metta_calculus!` exec dispatch.

---

## Trans-Detect — 18.5× Speedup (Verified Correct)

**Input**: `(exec 0 (, (edge $x $y) (edge $y $z) (edge $z $w)) (, (dtrans $x $y $z $w)))`
**Facts**: 150 edges on a 50-node graph

**Baseline**: ProductZipper O(150³) = 3,375,000 candidate triples → **~82 seconds**

**Decomposed** into 2 stages:
```
Stage 1: (exec 0 (, (edge $x $y) (edge $y $z)) (, (_sc_tmp0 $x $y $z)))
Stage 2: (exec 0 (, (_sc_tmp0 $x $y $z) (edge $z $w)) (, (dtrans $x $y $z $w)))
```
- Stage 1: O(150²) = 22,500 pairs → writes `_sc_tmp0` atoms
- Stage 2: O(M × 150) where M = matching pairs from stage 1 → **~4,500 ms**

**18.5× speedup**. Output verified: 287 `dtrans` atoms from both baseline and decomposed.
`_sc_tmp0` intermediate atoms cleaned up automatically by `execute!`.

---

## 5-Source Cases — Sub-Millisecond (Noise Floor)

Both `counter_machine` (5 sources, Peano arithmetic) and `odd_even_sort` (5 sources)
complete in **under 1ms** — the fact sets are too small to measure. These are not
decomposed anyway (rule definitions, not exec atoms). Benchmarking 5-source exec
atoms at scale requires larger synthetic datasets (see open gap below).

---

## Correctness Bugs Found During Integration

Three bugs were discovered when verifying correctness:

| Bug | Impact | Fix |
|-----|--------|-----|
| Rule decomposition | `((phase $p) ...)` was decomposed — broke invocation | Restrict to `(exec ...)` atoms only |
| Intermediate leak | 267 `_sc_tmp*` atoms per run stayed in space | `_cleanup_sc_tmp!` post-execution |
| Wrong step count | `steps=1` measured Stage 1 only (172× was wrong) | `steps=typemax(Int)` for full completion |

The initial 172× figure was measuring Stage 1 execution (22,500 joins) against the
full O(K³) baseline — a wrong comparison. The correct 18.5× uses full execution of
both stages for the decomposed program.

---

## Comparison with plan_static

| Approach | trans_detect speedup | Correct? |
|----------|---------------------|----------|
| `plan_static` (source reordering) | 0.94× | ✓ |
| `decompose_program` (pipeline) | **18.5×** | ✓ verified |

---

## Open Gap: 5-Source Exec Benchmark

The Rule-of-64 fix is most valuable for `(exec ...)` atoms with 5+ sources at large K.
A proper benchmark needs synthetic `(exec 0 (, src1...src5) (, tpl))` with K=50–200 atoms
per predicate to show O(K⁵) → O(K²) per stage at measurable scale.
