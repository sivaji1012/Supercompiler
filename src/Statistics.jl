"""
Statistics — MORK-aware statistics collection for the query planner.

Implements `MORKStatistics` from MM2 Supercompiler §5.1.1 and the two
cardinality estimation algorithms:

  Algorithm 2 — EstimatePatternCardinality (shape-based)
  Algorithm 3 — PrefixSampling (sublinear prefix-tree sampling)

Statistics are built from a `Space` (or its `btm::PathMap{UnitVal}`) and
keyed by predicate name + argument position, following the MORK-native
hash-cons structure described in the spec.

§5.2.1 — IncrementalStats: delta tracking under monotonic growth.
Statistics only ever grow (sink-free semantics), so we track base + delta
and merge when the delta exceeds a threshold.
"""

using PathMap: read_zipper_at_path, zipper_val_count, zipper_to_next_val!,
               zipper_path, zipper_is_val, zipper_child_count
using MORK:    ExprArity, ExprSymbol, item_byte, byte_item, Space, space_val_count

# ── Core statistics structure ─────────────────────────────────────────────────

"""
    MORKStatistics

MORK-specific statistics for query planning (MM2 Supercompiler §5.1.1).

Fields mirror the spec's `MORKStatistics` structure, adapted to Julia/PathMap:
  - `predicate_counts`   — total atoms per predicate (head symbol)
  - `predicate_arities`  — most common arity per predicate
  - `predicate_fanout`   — (avg_matches, variance) per predicate per arg position
  - `total_atoms`        — total atom count at collection time
  - `sample_size`        — atoms sampled during collection (Algorithm 3)
"""
struct MORKStatistics
    predicate_counts   :: Dict{String, Int}
    predicate_arities  :: Dict{String, Int}
    predicate_fanout   :: Dict{Tuple{String,Int}, Tuple{Float64,Float64}}
    total_atoms        :: Int
    sample_size        :: Int
end

MORKStatistics() = MORKStatistics(
    Dict{String,Int}(), Dict{String,Int}(),
    Dict{Tuple{String,Int},Tuple{Float64,Float64}}(),
    0, 0)

# ── IncrementalStats (§5.2.1) ─────────────────────────────────────────────────

"""
    IncrementalStats

Wraps a base + delta pair for statistics under monotonic growth (§5.2.1).
Use `update_stats!` to add new facts; `merged_stats` to get the combined view.
"""
mutable struct IncrementalStats
    base   :: MORKStatistics
    delta  :: MORKStatistics
    growth_rate :: Float64     # exponential moving average, atoms/update
    last_merge_total :: Int
end

IncrementalStats() = IncrementalStats(MORKStatistics(), MORKStatistics(), 0.0, 0)

# Merge delta into base when delta is > 10% of base (following §5.2.2)
_should_merge(is::IncrementalStats) =
    is.delta.total_atoms > max(100, is.base.total_atoms ÷ 10)

function merged_stats(is::IncrementalStats) :: MORKStatistics
    _merge_mork_stats(is.base, is.delta)
end

function _merge_mork_stats(a::MORKStatistics, b::MORKStatistics) :: MORKStatistics
    counts = merge(+, a.predicate_counts, b.predicate_counts)
    arities = merge(a.predicate_arities, b.predicate_arities)
    fanout = merge(a.predicate_fanout, b.predicate_fanout)
    MORKStatistics(counts, arities, fanout, a.total_atoms + b.total_atoms,
                   a.sample_size + b.sample_size)
end

# ── Statistics collection ─────────────────────────────────────────────────────

"""
    collect_stats(s::Space; sample_frac=0.1) -> MORKStatistics

Scan the space and build statistics for the query planner.  For large spaces,
`sample_frac < 1.0` enables the sublinear PrefixSampling strategy (Algorithm 3).
"""
function collect_stats(s::Space; sample_frac::Float64=1.0) :: MORKStatistics
    total = space_val_count(s)
    sample_size = max(1, round(Int, total * clamp(sample_frac, 0.0, 1.0)))
    collect_stats(s.btm, total, sample_size)
end

function collect_stats(btm, total_atoms::Int, sample_size::Int) :: MORKStatistics
    pred_counts  = Dict{String,Int}()
    pred_arities = Dict{String,Int}()
    pred_fanout  = Dict{Tuple{String,Int},Tuple{Float64,Float64}}()

    rz = read_zipper_at_path(btm, UInt8[])
    n_visited = 0

    while zipper_to_next_val!(rz) && n_visited < sample_size
        path = collect(zipper_path(rz))
        isempty(path) && continue
        n_visited += 1

        # Decode arity byte (first byte of path)
        b0 = path[1]
        tag0 = try byte_item(b0) catch; continue end
        tag0 isa ExprArity || continue
        arity = Int(tag0.arity)
        arity < 2 && continue   # 0-arity or 1-arity (bare atoms/vars) — skip

        # Decode head symbol (second byte + following bytes)
        length(path) < 3 && continue
        b1 = path[2]
        tag1 = try byte_item(b1) catch; continue end
        tag1 isa ExprSymbol || continue
        sym_len = Int(tag1.size)
        2 + sym_len > length(path) && continue

        pred = String(path[3:2+sym_len])

        pred_counts[pred] = get(pred_counts, pred, 0) + 1
        # Track the most common arity per predicate (simple majority: last wins is fine for stats)
        pred_arities[pred] = arity
    end

    # Scale up counts if we sampled
    scale = total_atoms / max(1, sample_size)
    if scale > 1.0
        for k in keys(pred_counts)
            pred_counts[k] = round(Int, pred_counts[k] * scale)
        end
    end

    MORKStatistics(pred_counts, pred_arities, pred_fanout, total_atoms, n_visited)
end

# ── Algorithm 2 — EstimatePatternCardinality (§5.1.2) ─────────────────────────

"""
    estimate_cardinality(src::SNode, stats::MORKStatistics) -> Int

Algorithm 2 from MM2 Supercompiler §5.1.2: shape-based cardinality estimation.

For `(pred arg1 arg2 ...)`:
  1. Start with `predicate_counts[pred]` as the base count
  2. Multiply by selectivity of each constrained argument
  3. Return the estimated match count

Ground arguments reduce the estimate by `1 / base_count` (single match).
Variable arguments: no reduction.
"""
function estimate_cardinality(src::SNode, stats::MORKStatistics) :: Int
    total = stats.total_atoms
    total == 0 && return 1

    src isa SList || return (src isa SVar ? total : 1)
    items = (src::SList).items
    isempty(items) && return 1

    head = items[1]
    head isa SAtom || return total   # compound head: no predicate stats

    pred = (head::SAtom).name
    base = get(stats.predicate_counts, pred, total ÷ 4)

    # Apply per-argument selectivity
    for (i, arg) in enumerate(items[2:end])
        is_ground(arg) || continue   # variable: no restriction
        # Ground argument at position i: estimate 1/fanout reduction
        avg_fanout, _ = get(stats.predicate_fanout, (pred, i), (Float64(base), 0.0))
        avg_fanout > 0 && (base = max(1, round(Int, base / avg_fanout)))
    end

    max(1, base)
end

# ── Algorithm 3 — PrefixSampling (§5.1.3) ────────────────────────────────────

"""
    prefix_sample_count(btm, src::SNode; sample_size=nothing) -> Int

Algorithm 3: PrefixSampling — count atoms in `btm` matching the 2-byte prefix
(arity + head symbol) of `src`.  Uses `zipper_val_count` for an O(1) lookup
rather than actual sampling (equivalent when the PathMap is fully indexed).

`sample_size` is accepted for API compatibility but ignored (PathMap provides
exact subtrie counts without sampling).
"""
function prefix_sample_count(btm, src::SNode; sample_size=nothing) :: Int
    # Delegate to dynamic_count in Selectivity.jl — same algorithm
    dynamic_count(btm, src)
end

# ── Adaptive planning threshold (§5.2.2) ─────────────────────────────────────

"""
    should_replan(plan_card::Int, new_card::Int, growth_rate::Float64) -> Bool

Algorithm 5 — ShouldReplan: return true if cardinality drift exceeds threshold.
Threshold adapts to growth rate (fast-growing spaces need more replanning).
"""
function should_replan(plan_card::Int, new_card::Int, growth_rate::Float64) :: Bool
    plan_card == 0 && return true
    drift = abs(new_card - plan_card) / plan_card
    threshold = clamp(0.2 + 0.5 * growth_rate, 0.2, 0.8)
    drift > threshold
end

export MORKStatistics, IncrementalStats
export collect_stats, merged_stats
export estimate_cardinality, prefix_sample_count, should_replan
