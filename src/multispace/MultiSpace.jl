"""
MultiSpace — optional hierarchical multi-space layer for MorkSupercompiler.

Stage 1: Single-node registry of named MORK spaces.
Stage 2 (future): Julia HPC peer-to-peer via Dagger.jl/Distributed.jl.
Stage 3 (future): Web3 content-addressed spaces via CID.

Design principles (fruit-fly-inspired):
  - No master/worker — every space is a peer
  - Traversal probability gates propagation (threshold = 0.3, from Drosophila paper)
  - NamedSpaceID is content-addressable now, extensible to CID later
  - User defines their own topology — no hardcoded domain names

Usage:
  enable_multi_space!(true)
  reg = get_registry()
  new_space!(reg, "my-kb", :common)
  new_space!(reg, "my-app", :app)
"""

# ── Feature flag ──────────────────────────────────────────────────────────────

"""
    ENABLE_MULTI_SPACE[]

Global flag. When false (default), the entire multi-space layer is inactive
and all operations fall through to single-flat-space semantics with zero overhead.
"""
const ENABLE_MULTI_SPACE = Ref{Bool}(false)

"""
    enable_multi_space!(flag::Bool; use_mpi::Bool=false) → Nothing

Enable or disable the multi-space layer at runtime.

  flag=false (default): zero overhead, exactly current single-space behaviour.
  flag=true:  SpaceRegistry active, MM2 commands intercepted.
  use_mpi=true: initialise MPI transport (Stage 2 HPC peer-to-peer).
               Calls mpi_init!() which sets registry rank/nranks from MPI.
               Safe to call multiple times (idempotent).

Single-node:   enable_multi_space!(true)              → Stage 1 registry only
Multi-node:    enable_multi_space!(true; use_mpi=true) → Stage 2 MPI peers
"""
function enable_multi_space!(flag::Bool; use_mpi::Bool=false)
    ENABLE_MULTI_SPACE[] = flag
    if flag
        _ensure_registry!()
        use_mpi && mpi_init!()
    end
    nothing
end

# ── NamedSpaceID ───────────────────────────────────────────────────────────────────

"""
    LOCAL_PEER

Sentinel peer_id meaning "this node" — MPI rank 0 on a single-node run,
or the local rank on a multi-node run.  Used as default in NamedSpaceID.
"""
const LOCAL_PEER = Int32(0)

"""
    NamedSpaceID

Content-addressable space identifier.

  name    :: String  — user-defined name (e.g. "my-knowledge-base", "my-app")
  cid     :: UInt64  — content hash of the space's PathMap root (Merkle-ready)
                       Zero for a freshly created empty space.
  peer_id :: Int32   — MPI rank of the peer that owns this space.
                       LOCAL_PEER (0) = local to this process.
                       No master — every peer is equal (SPMD model).

Stage 1: `name` is the primary key.  peer_id = LOCAL_PEER always.
Stage 2 (HPC): peer_id = MPI rank.  Routing via space_traverse! probability gate.
Stage 3 (Web3): `cid` becomes the primary key (IPFS/content-addressed).
"""
struct NamedSpaceID
    name    :: String
    cid     :: UInt64
    peer_id :: Int32
end

NamedSpaceID(name::AbstractString) =
    NamedSpaceID(String(name), UInt64(0), LOCAL_PEER)

# Equality and hashing by (name, peer_id) — two peers can have same-named spaces
Base.:(==)(a::NamedSpaceID, b::NamedSpaceID) = a.name == b.name && a.peer_id == b.peer_id
Base.hash(s::NamedSpaceID, h::UInt)     = hash(s.peer_id, hash(s.name, h))
Base.show(io::IO, s::NamedSpaceID)      =
    print(io, "NamedSpaceID(\"$(s.name)\", peer=$(s.peer_id))")

# ── SpaceRegistry ─────────────────────────────────────────────────────────────

"""
    SpaceRegistry

Manages a collection of named MORK spaces with role metadata.

  spaces     :: Dict{NamedSpaceID, Space}  — local spaces owned by this peer
  roles      :: Dict{NamedSpaceID, Symbol} — :common or :app (user-assignable)
  disk_paths :: Dict{NamedSpaceID, String} — optional .act file backing
  rank       :: Int32  — this peer's MPI rank (LOCAL_PEER=0 on single-node)
  nranks     :: Int32  — total number of peers in the MPI communicator (1 = single-node)

No hardcoded topology. Users define their own via MM2 commands or the Julia API.
SPMD: every peer runs the same code, differentiated by rank.
"""
mutable struct SpaceRegistry
    spaces     :: Dict{NamedSpaceID, Space}
    roles      :: Dict{NamedSpaceID, Symbol}
    disk_paths :: Dict{NamedSpaceID, String}
    rank       :: Int32   # this peer's MPI rank
    nranks     :: Int32   # total peers (1 = single-node, no MPI)
end

SpaceRegistry() = SpaceRegistry(
    Dict{NamedSpaceID, Space}(),
    Dict{NamedSpaceID, Symbol}(),
    Dict{NamedSpaceID, String}(),
    LOCAL_PEER,
    Int32(1)
)

# ── Global registry singleton ─────────────────────────────────────────────────

const _REGISTRY = Ref{Union{SpaceRegistry, Nothing}}(nothing)

function _ensure_registry!()
    _REGISTRY[] === nothing && (_REGISTRY[] = SpaceRegistry())
    nothing
end

"""
    get_registry() → SpaceRegistry

Return the global SpaceRegistry. Enables multi-space if not already enabled.
"""
function get_registry() :: SpaceRegistry
    enable_multi_space!(true)
    _REGISTRY[]::SpaceRegistry
end

# ── Registry operations ───────────────────────────────────────────────────────

"""
    new_space!(reg, name, role=:app) → Space

Create and register a new empty MORK space with the given name and role.
Role must be :app or :common.
"""
function new_space!(reg::SpaceRegistry, name::AbstractString,
                    role::Symbol = :app) :: Space
    role ∈ (:app, :common) || error("role must be :app or :common, got :$role")
    id  = NamedSpaceID(name)
    haskey(reg.spaces, id) && error("space \"$name\" already exists")
    s   = new_space()
    reg.spaces[id] = s
    reg.roles[id]  = role
    s
end

"""
    get_space(reg, name) → Space

Retrieve a registered space by name. Throws if not found.
"""
function get_space(reg::SpaceRegistry, name::AbstractString) :: Space
    id = NamedSpaceID(name)
    get(reg.spaces, id) do
        error("space \"$name\" not registered. Use new_space! first.")
    end
end

"""
    common_space(reg) → Space

Return the first :common space in the registry.
Throws if no common space has been designated.
"""
function common_space(reg::SpaceRegistry) :: Space
    for (id, role) in reg.roles
        role == :common && return reg.spaces[id]
    end
    error("No :common space registered. Create one with new_space!(reg, name, :common).")
end

"""
    list_spaces(reg) → Vector{NamedTuple}

List all registered spaces with their names, roles, and atom counts.
"""
function list_spaces(reg::SpaceRegistry) :: Vector{NamedTuple}
    [(name=id.name, role=reg.roles[id],
      atoms=space_val_count(reg.spaces[id]),
      disk=get(reg.disk_paths, id, nothing))
     for id in keys(reg.spaces)]
end

# ── Content hash (Stage 1 stub, extensible to Merkle/CID) ────────────────────

"""
    compute_cid(s::Space) → UInt64

Compute a lightweight content hash of the space's PathMap.
Stage 1: simple hash of the atom count + first/last paths.
Stage 3 (Web3): replace with full Merkle root over the trie.
"""
function compute_cid(s::Space) :: UInt64
    n = space_val_count(s)
    n == 0 && return UInt64(0)
    hash(n)  # Stage 1 stub — replace with Merkle root in Stage 3
end

export ENABLE_MULTI_SPACE, enable_multi_space!
export LOCAL_PEER, NamedSpaceID, SpaceRegistry
export get_registry, new_space!, get_space, common_space, list_spaces
export compute_cid
