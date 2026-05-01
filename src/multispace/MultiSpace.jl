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
    enable_multi_space!(flag::Bool)

Enable or disable the multi-space layer at runtime.
When false (default): zero overhead, exactly current single-space behaviour.
When true: SpaceRegistry is active, MM2 commands are intercepted.
"""
function enable_multi_space!(flag::Bool)
    ENABLE_MULTI_SPACE[] = flag
    flag && _ensure_registry!()
    nothing
end

# ── NamedSpaceID ───────────────────────────────────────────────────────────────────

"""
    NamedSpaceID

Content-addressable space identifier.

  name :: String    — user-defined name (e.g. "my-knowledge-base", "my-app")
  cid  :: UInt64    — content hash of the space's PathMap root (Merkle-ready)
                      Zero for a freshly created empty space.

Stage 1: `name` is the primary key.
Stage 2 (HPC): extend with `worker_id :: Int` (Distributed.jl process ID).
Stage 3 (Web3): `cid` becomes the primary key (IPFS/content-addressed).
"""
struct NamedSpaceID
    name :: String
    cid  :: UInt64
end

NamedSpaceID(name::AbstractString) = NamedSpaceID(String(name), UInt64(0))

Base.:(==)(a::NamedSpaceID, b::NamedSpaceID) = a.name == b.name
Base.hash(s::NamedSpaceID, h::UInt)     = hash(s.name, h)
Base.show(io::IO, s::NamedSpaceID)      = print(io, "NamedSpaceID(\"$(s.name)\")")

# ── SpaceRegistry ─────────────────────────────────────────────────────────────

"""
    SpaceRegistry

Manages a collection of named MORK spaces with role metadata.

  spaces  :: Dict{NamedSpaceID, Space}   — all registered spaces
  roles   :: Dict{NamedSpaceID, Symbol}  — :common or :app (user-assignable)

No hardcoded topology. Users define their own via MM2 commands or the Julia API.
"""
mutable struct SpaceRegistry
    spaces        :: Dict{NamedSpaceID, Space}
    roles         :: Dict{NamedSpaceID, Symbol}
    disk_paths    :: Dict{NamedSpaceID, String}   # optional .act file backing
end

SpaceRegistry() = SpaceRegistry(
    Dict{NamedSpaceID, Space}(),
    Dict{NamedSpaceID, Symbol}(),
    Dict{NamedSpaceID, String}()
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
export NamedSpaceID, SpaceRegistry
export get_registry, new_space!, get_space, common_space, list_spaces
export compute_cid
