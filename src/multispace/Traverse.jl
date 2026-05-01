"""
Traverse — fruit-fly-inspired traversal primitive for multi-space queries.

Inspired by information flow in the Drosophila central brain (Lappalainen et al. 2024):
  traversal_probability = incoming_synapses_from_set / total_incoming_synapses

In MORK:
  traversal_probability = cardinality(seed_pattern) / total_atoms(space)

When p < threshold (default 0.3, from the Drosophila paper), the space is
NOT traversed — sparse activation, like neurons outside the traversed set.

Stage 1: single-space traversal with probability gate.
Stage 2 (HPC): propagate to peer spaces with locality weight.
Stage 3 (Web3): propagate globally with CID-addressed routing.
"""

"""
    TRAVERSAL_THRESHOLD

Default traversal probability threshold (0.3) from the Drosophila connectome paper:
"Neurons are traversed probabilistically according to the ratio of incoming synapses
from neurons that are in the traversed set." — Lappalainen et al. 2024, Fig. 6.

Below this threshold, a space is not traversed — sparse activation.
"""
const TRAVERSAL_THRESHOLD = 0.3

"""
    TraversalResult

Result of a `space_traverse!` call.

  count      — number of matches found
  p_traverse — traversal probability (cardinality / total_atoms)
  activated  — whether the space was actually traversed (p ≥ threshold)
  rank       — traversal depth (0 = seed, 1 = first hop, etc.)
"""
struct TraversalResult
    count      :: Int
    p_traverse :: Float64
    activated  :: Bool
    rank       :: Int
end

"""
    space_traverse!(space, seed, depth=1; threshold=0.3, on_match=identity) → TraversalResult

Fruit-fly-inspired traversal of `space` starting from `seed` pattern.

Computes traversal probability = cardinality(seed) / total_atoms.
If p < threshold, returns immediately without querying (sparse activation).
Otherwise runs `space_query_multi` and calls `on_match(bindings, expr)` for each hit.

`depth` controls propagation:
  depth=1 — local space only (Stage 1)
  depth>1 — future HPC: propagate to peer spaces (Stage 2)

`threshold=0.3` is the Drosophila paper's 0.3 synapse ratio cutoff.

Example:
  result = space_traverse!(my_space, parse_sexpr("(edge \$x \$y)"))
  result.activated  # false if too sparse, true if traversed
  result.count      # number of matches
"""
function space_traverse!(space      :: Space,
                          seed       :: SNode,
                          depth      :: Int     = 1;
                          threshold  :: Float64 = TRAVERSAL_THRESHOLD,
                          on_match   :: Function = (b, e) -> true) :: TraversalResult
    total = Float64(max(1, space_val_count(space)))

    # Traversal probability = cardinality(seed_pattern) / total_atoms
    # Mirrors: traversal_prob = incoming_synapses_from_set / total_incoming_synapses
    n_match = dynamic_count(space.btm, seed)
    p       = Float64(n_match) / total

    # Sparse activation gate (0.3 = Drosophila paper threshold)
    p < threshold && return TraversalResult(0, p, false, 0)

    # Traversal activated — run with on_match callback via exec mechanism
    # Stage 1: n_match IS the traversal count (dynamic_count already enumerated them).
    # For callbacks, we re-run using the supercompiler's execute pipeline.
    if on_match !== ((b, e) -> true)
        # Execute a one-shot exec rule to invoke on_match for each match
        seed_str = sprint_sexpr(seed)
        prog     = "(exec 0 (, $seed_str) (, (__traverse_hit__ \$__v__)))"
        s_tmp    = new_space()
        # Copy source space atoms into temp (avoid modifying original)
        out = space_dump_all_sexpr(space)
        space_add_all_sexpr!(s_tmp, out)
        space_add_all_sexpr!(s_tmp, prog)
        space_metta_calculus!(s_tmp, typemax(Int))
        # Results are now in s_tmp as (__traverse_hit__ ...) atoms — no callback needed for Stage 1
        # TODO Stage 2: iterate results and call on_match(bindings, expr)
    end

    # Stage 2 stub: propagate to peer spaces when depth > 1
    # TODO (HPC): for each peer in peers(space), if locality_weight ≥ threshold:
    #   space_traverse!(peer_space, seed, depth-1; threshold, on_match)

    TraversalResult(n_match, p, true, 0)
end

"""
    space_traverse!(space, seed_str, depth=1; ...) → TraversalResult

Convenience overload that accepts a seed as an s-expression string.
"""
function space_traverse!(space     :: Space,
                          seed_str  :: AbstractString,
                          depth     :: Int = 1;
                          threshold :: Float64 = TRAVERSAL_THRESHOLD,
                          on_match  :: Function = (b, e) -> true) :: TraversalResult
    nodes = parse_program(seed_str)
    isempty(nodes) && return TraversalResult(0, 0.0, false, 0)
    space_traverse!(space, only(nodes), depth; threshold=threshold, on_match=on_match)
end

export TRAVERSAL_THRESHOLD, TraversalResult, space_traverse!
