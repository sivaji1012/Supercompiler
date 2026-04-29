"""
SCPipeline — end-to-end supercompiler pipeline.

Closes the loop from spec §10.4 (Production Hardening):
  stats → plan → (optional KB saturation) → compile → execute

A single `execute!` call replaces the manual sequence of:
  collect_stats → plan_program → space_add_all_sexpr! → space_metta_calculus!

and adds bisimulation obligation recording, timing, and replanning support.

Pipeline stages (all optional, controlled via SCOptions):
  1. STATS    — collect MORKStatistics from the space (or use cached)
  2. PLAN     — QueryPlanner join-order optimization (Algorithm 6)
  3. SATURATE — KBSaturation incremental saturation on background facts
  4. COMPILE  — MM2Compiler lowers M-Core frags to exec s-expressions
  5. EXECUTE  — space_add_all_sexpr! + space_metta_calculus!
"""

using MORK: Space, new_space, space_add_all_sexpr!, space_metta_calculus!, space_val_count

# ── Pipeline options ──────────────────────────────────────────────────────────

"""
    SCOptions

Controls which pipeline stages are active and their parameters.
"""
struct SCOptions
    collect_stats    :: Bool     # Stage 1: collect MORKStatistics
    plan_join_order  :: Bool     # Stage 2: QueryPlanner reordering
    saturate_kb      :: Bool     # Stage 3: KBSaturation on background
    use_mm2_compiler :: Bool     # Stage 4: lower through MM2Compiler
    max_steps        :: Int      # Stage 5: space_metta_calculus! limit
    stats_sample_frac:: Float64  # fraction of space to sample for stats
    split_budget     :: Int      # BoundedSplit branch budget
end

SCOptions(; max_steps   = typemax(Int),
            plan        = true,
            stats       = true,
            saturate    = false,
            mm2_compile = false,
            sample_frac = 1.0,
            budget      = SPLIT_DEFAULT_BUDGET) =
    SCOptions(stats, plan, saturate, mm2_compile, max_steps, sample_frac, budget)

const SC_DEFAULTS = SCOptions()

# ── Pipeline result ───────────────────────────────────────────────────────────

"""
    SCResult

Output of the supercompiler pipeline.

  steps_executed  — number of metta_calculus! steps taken
  stats           — MORKStatistics used for planning
  plan_report_str — human-readable join-plan report (if plan_join_order=true)
  obligs          — bisimulation obligations from MM2Compiler (if active)
  timings         — Dict of stage → elapsed seconds
  program_planned — the reordered program string actually loaded
"""
struct SCResult
    steps_executed  :: Int
    stats           :: MORKStatistics
    plan_report_str :: String
    obligs          :: Vector{BiSimObligation}
    timings         :: Dict{Symbol, Float64}
    program_planned :: String
end

# ── Main pipeline entry point ─────────────────────────────────────────────────

"""
    execute!(s::Space, program::AbstractString; opts=SC_DEFAULTS) -> SCResult

Run the full supercompiler pipeline on `program`, adding the result to `s`
and executing up to `opts.max_steps` metta_calculus! steps.

`program` should contain the exec/rule atoms NOT yet loaded into `s`.
Background facts should already be in `s` before calling.
"""
function execute!(s       :: Space,
                 program :: AbstractString;
                 opts    :: SCOptions = SC_DEFAULTS) :: SCResult

    timings = Dict{Symbol, Float64}()

    # Stage 1 — collect statistics
    stats = if opts.collect_stats
        t = @elapsed st = collect_stats(s; sample_frac=opts.stats_sample_frac)
        timings[:stats] = t
        st
    else
        MORKStatistics()
    end

    # Stage 2 — plan join order
    program_planned, plan_str = if opts.plan_join_order
        t = @elapsed begin
            planned  = plan_program(program, stats)
            pstr     = plan_report(program, stats)
        end
        timings[:plan] = t
        (planned, pstr)
    else
        (String(program), "")
    end

    # Stage 3 — optional KB saturation on background facts
    if opts.saturate_kb
        t = @elapsed begin
            kb = KBState(MCoreGraph())
            for fid in NodeID[]  # placeholder: integrate with MORK atom enumeration
                kb_add_fact!(kb, fid)
            end
            saturate!(kb; max_rounds=100)
        end
        timings[:saturate] = t
    end

    # Stage 4 — optional MM2Compiler lowering
    obligs = BiSimObligation[]
    if opts.use_mm2_compiler
        t = @elapsed begin
            g = MCoreGraph()
            # Parse program_planned into M-Core nodes via SExpr layer
            nodes  = parse_program(program_planned)
            root_ids = _sexpr_nodes_to_mcore(g, nodes)
            program_planned, obligs = compile_program(g, root_ids)
        end
        timings[:compile] = t
    end

    # Stage 5 — load and execute
    t_exec = @elapsed begin
        space_add_all_sexpr!(s, program_planned)
        steps = space_metta_calculus!(s, opts.max_steps)
    end
    timings[:execute] = t_exec

    SCResult(steps, stats, plan_str, obligs, timings, program_planned)
end

"""
    execute(facts::AbstractString, program::AbstractString; opts, steps) -> Tuple{Space, SCResult}

Convenience wrapper: build a fresh space from `facts`, run the pipeline,
return (space, result).
"""
function execute(facts   :: AbstractString,
                program :: AbstractString;
                opts    :: SCOptions = SC_DEFAULTS,
                steps   :: Int = typemax(Int)) :: Tuple{Space, SCResult}
    s = new_space()
    space_add_all_sexpr!(s, facts)
    opts2 = SCOptions(opts.collect_stats, opts.plan_join_order, opts.saturate_kb,
                      opts.use_mm2_compiler, steps, opts.stats_sample_frac, opts.split_budget)
    result = execute!(s, program; opts=opts2)
    (s, result)
end

# ── SExpr → M-Core conversion (for MM2Compiler integration) ──────────────────

"""Convert a vector of SNodes to M-Core NodeIDs (shallow; Prim for compound atoms)."""
function _sexpr_nodes_to_mcore(g::MCoreGraph, nodes::Vector{SNode}) :: Vector{NodeID}
    NodeID[_sexpr_to_mcore!(g, n) for n in nodes]
end

function _sexpr_to_mcore!(g::MCoreGraph, n::SNode) :: NodeID
    if n isa SAtom
        return add_sym!(g, Sym(Symbol((n::SAtom).name)))
    elseif n isa SVar
        # Variable: parse the index from the name if numeric, else use 0
        name = (n::SVar).name[2:end]  # strip leading $
        ix   = tryparse(Int, name)
        return add_var!(g, Var(ix !== nothing ? ix : 0))
    else
        items = (n::SList).items
        isempty(items) && return add_con!(g, Con(:nil))
        head  = items[1]

        if head isa SAtom && (head::SAtom).name == "exec"
            # Compile exec atom as mm2_exec primitive
            arg_ids = NodeID[_sexpr_to_mcore!(g, items[i]) for i in 2:length(items)]
            return add_prim!(g, Prim(:mm2_exec, arg_ids, EffectSet(UInt8(0x05))))
        end

        head_id  = _sexpr_to_mcore!(g, head)
        field_ids = NodeID[_sexpr_to_mcore!(g, items[i]) for i in 2:length(items)]
        if head isa SAtom
            return add_con!(g, Con(Symbol((head::SAtom).name), field_ids))
        end
        return add_app!(g, App(head_id, field_ids))
    end
end

# ── Timing report ─────────────────────────────────────────────────────────────

"""Human-readable timing summary for an SCResult."""
function timing_report(r::SCResult) :: String
    io = IOBuffer()
    total = sum(values(r.timings))
    println(io, "SCPipeline timings:")
    for (stage, t) in sort(collect(r.timings); by=first)
        pct = round(100 * t / max(total, 1e-9); digits=1)
        println(io, "  $(rpad(stage, 12)) $(rpad(round(t*1000; digits=2), 10)) ms  ($pct%)")
    end
    println(io, "  $(rpad(:total, 12)) $(round(total*1000; digits=2)) ms")
    println(io, "  steps_executed: $(r.steps_executed)")
    !isempty(r.obligs) && println(io, "  bisim_obligs: $(length(r.obligs))")
    String(take!(io))
end

export SCOptions, SC_DEFAULTS, SCResult
export execute!, execute
export timing_report
