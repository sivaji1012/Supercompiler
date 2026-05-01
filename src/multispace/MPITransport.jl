"""
MPITransport — MPI peer-to-peer transport layer for multi-space Stage 2.

Design: SPMD (Single Program Multiple Data).
  - Every peer runs identical code, differentiated by MPI rank.
  - No master, no scheduler — all ranks are equal.
  - Non-blocking point-to-point (MPI.Isend / Iprobe+Recv).
  - space_traverse! probability gate drives propagation — no global sync.

Message tags:
  TRAVERSE_TAG = 42  — traverse query (seed pattern bytes)
  RESULT_TAG   = 43  — traverse result count (future use)

Single-node operation (nranks=1):
  MPI uses shared memory loopback — zero network overhead.
  Same code, same semantics, just faster transport.

Scale:
  mpirun -n 1    julia script.jl   → single peer, shared mem
  mpirun -n 128  julia script.jl   → 128 peers, same binary
  mpirun -n 9216 julia script.jl   → Frontier-scale, same binary
"""

import MPI

const TRAVERSE_TAG = Int32(42)
const RESULT_TAG   = Int32(43)

# ── State ─────────────────────────────────────────────────────────────────────

const _MPI_INITIALIZED = Ref{Bool}(false)
const _MPI_COMM        = Ref{MPI.Comm}(MPI.COMM_NULL)

# ── Lifecycle ─────────────────────────────────────────────────────────────────

"""
    mpi_init!() → Nothing

Initialize MPI if not already done. Safe to call multiple times (idempotent).
Sets `_MPI_COMM[]` to `MPI.COMM_WORLD` and updates the global SpaceRegistry
rank/nranks fields.
"""
function mpi_init!()
    _MPI_INITIALIZED[] && return nothing
    MPI.Init()
    _MPI_COMM[]        = MPI.COMM_WORLD
    _MPI_INITIALIZED[] = true
    reg = _REGISTRY[]
    if reg !== nothing
        reg.rank   = Int32(MPI.Comm_rank(_MPI_COMM[]))
        reg.nranks = Int32(MPI.Comm_size(_MPI_COMM[]))
    end
    nothing
end

"""
    mpi_finalize!() → Nothing

Finalize MPI. Call once at program exit when use_mpi=true.
Guarded — safe to call even if MPI was never initialized.
"""
function mpi_finalize!()
    _MPI_INITIALIZED[] || return nothing
    MPI.Finalize()
    _MPI_INITIALIZED[] = false
    nothing
end

# ── Rank queries ──────────────────────────────────────────────────────────────

"""
    mpi_rank() → Int32

Return this peer's MPI rank. Returns LOCAL_PEER (0) when MPI not initialized.
"""
mpi_rank()   :: Int32 = _MPI_INITIALIZED[] ? Int32(MPI.Comm_rank(_MPI_COMM[])) : LOCAL_PEER

"""
    mpi_nranks() → Int32

Return total number of peers. Returns 1 when MPI not initialized.
"""
mpi_nranks() :: Int32 = _MPI_INITIALIZED[] ? Int32(MPI.Comm_size(_MPI_COMM[])) : Int32(1)

"""
    mpi_active() → Bool

True when MPI is initialized and more than one peer exists.
Single-node single-rank runs return false — no MPI overhead.
"""
mpi_active() :: Bool = _MPI_INITIALIZED[] && mpi_nranks() > Int32(1)

# ── Point-to-point messaging ──────────────────────────────────────────────────

"""
    mpi_send_traverse!(dest_rank, query_bytes) → Nothing

Non-blocking send of a traverse query to `dest_rank`.
`query_bytes` = UTF-8 encoded seed pattern s-expression.
Returns immediately — does not wait for dest to receive.
"""
function mpi_send_traverse!(dest_rank::Int32, query_bytes::Vector{UInt8}) :: Nothing
    _MPI_INITIALIZED[] || return nothing
    MPI.Isend(query_bytes, _MPI_COMM[]; dest=Int(dest_rank), tag=Int(TRAVERSE_TAG))
    nothing
end

"""
    mpi_poll_traverse!() → Union{Nothing, Tuple{Int32, Vector{UInt8}}}

Non-blocking poll for incoming traverse queries from any peer.
Returns `(source_rank, query_bytes)` if a message is waiting, `nothing` otherwise.
Call in the peer's main loop to process incoming queries without blocking.
"""
function mpi_poll_traverse!() :: Union{Nothing, Tuple{Int32, Vector{UInt8}}}
    _MPI_INITIALIZED[] || return nothing
    status = MPI.Iprobe(_MPI_COMM[]; source=MPI.ANY_SOURCE, tag=Int(TRAVERSE_TAG))
    status === nothing && return nothing
    src   = Int32(MPI.Get_source(status))
    count = MPI.Get_count(status, UInt8)
    buf   = Vector{UInt8}(undef, count)
    MPI.Recv!(buf, _MPI_COMM[]; source=Int(src), tag=Int(TRAVERSE_TAG))
    (src, buf)
end

"""
    mpi_broadcast_traverse!(query_bytes) → Nothing

Send a traverse query to ALL other peers (non-blocking).
Used when traversal probability is high enough to warrant full broadcast.
"""
function mpi_broadcast_traverse!(query_bytes::Vector{UInt8}) :: Nothing
    _MPI_INITIALIZED[] || return nothing
    my_rank = mpi_rank()
    for r in Int32(0):mpi_nranks()-Int32(1)
        r == my_rank && continue
        MPI.Isend(query_bytes, _MPI_COMM[]; dest=Int(r), tag=Int(TRAVERSE_TAG))
    end
    nothing
end

# ── Barrier (use sparingly — breaks peer model if overused) ───────────────────

"""
    mpi_barrier!() → Nothing

Global synchronization barrier across all peers.
Use ONLY for initialization/shutdown — NOT in the hot traversal loop.
The fruit-fly model is asynchronous; barriers are anti-patterns in the main loop.
"""
function mpi_barrier!() :: Nothing
    _MPI_INITIALIZED[] || return nothing
    MPI.Barrier(_MPI_COMM[])
    nothing
end

export mpi_init!, mpi_finalize!
export mpi_rank, mpi_nranks, mpi_active
export mpi_send_traverse!, mpi_poll_traverse!, mpi_broadcast_traverse!
export mpi_barrier!
export TRAVERSE_TAG, RESULT_TAG
