export MultiPhaseSystem, ImmiscibleMultiPhaseSystem, SinglePhaseSystem
export LiquidPhase, VaporPhase
export number_of_phases, get_short_name, get_name
export update_linearized_system!
export SourceTerm

export allocate_storage, update_equations!
# Abstract multiphase system
abstract type MultiPhaseSystem <: TervSystem end


function get_phases(sys::MultiPhaseSystem)
    return sys.phases
end

function number_of_phases(sys::MultiPhaseSystem)
    return length(get_phases(sys))
end

struct SourceTerm{R<:Real,I<:Integer}
    cell::I
    values::AbstractVector{R}
end


function allocate_storage!(d, G, sys::MultiPhaseSystem)
    nph = number_of_phases(sys)
    phases = get_phases(sys)
    npartials = nph
    nc = number_of_cells(G)
    nhf = number_of_half_faces(G)

    A_p = get_incomp_matrix(G)
    if nph == 1
        jac = A_p
    else
        jac = repeat(A_p, nph, nph) # This is super slow even with nph = 1?!
    end

    n_dof = nc*nph
    dx = zeros(n_dof)
    r = zeros(n_dof)
    lsys = LinearizedSystem(jac, r, dx)
    d["LinearizedSystem"] = lsys
    # hasAcc = !isa(sys, SinglePhaseSystem) # and also incompressible!!
    for phaseNo in eachindex(phases)
        ph = phases[phaseNo]
        sname = get_short_name(ph)
        law = ConservationLaw(G, lsys, npartials)
        d[string("ConservationLaw_", sname)] = law
        d[string("Mobility_", sname)] = allocate_vector_ad(nc, npartials)
        # d[string("Accmulation_", sname)] = allocate_vector_ad(nc, npartials)
        # d[string("Flux_", sname)] = allocate_vector_ad(nhf, npartials)
    end
end

function update_equations!(model, storage; dt = nothing, sources = nothing)
    sys = model.system;
    sys::MultiPhaseSystem
    G = model.G

    state = storage["state"]
    state0 = storage["state0"]
    
    p = state["Pressure"]
    p0 = state0["Pressure"]
    pv = model.G.pv

    phases = get_phases(sys)
    for phNo in eachindex(phases)
        phase = phases[phNo]
        sname = get_short_name(phase)
        # Parameters - fluid properties
        rho = storage["parameters"][string("Density_", sname)]
        mu = storage["parameters"][string("Viscosity_", sname)]
        # Storage structure
        law = storage[string("ConservationLaw_", sname)]
        mob = storage[string("Mobility_", sname)]
        acc = law.accumulation

        mob .= 1/mu
        # @debug "Computing half-face fluxes."
        half_face_flux!(law.half_face_flux, mob, p, G)
        # @debug "Computing accumulation terms."
        @. acc = (pv/dt)*(rho(p) - rho(p0))
        if !isnothing(sources)
            # @debug "Inserting source terms."
            insert_sources(acc, sources, phNo)
        end
    end
end

function insert_sources(acc, sources, phNo)
    for src in sources
        acc[src.cell] += src.values[phNo]
    end
end

function update_linearized_system!(model::TervModel, storage)
    sys = model.system;
    sys::MultiPhaseSystem

    lsys = storage["LinearizedSystem"]
    phases = get_phases(sys)
    for phase in phases
        sname = get_short_name(phase)
        law = storage[string("ConservationLaw_", sname)]
        update_linearized_system!(model.G, lsys, law)
    end
end

function update_linearized_system!(G, lsys::LinearizedSystem, law::ConservationLaw)
    apos = law.accumulation_jac_pos
    jac = lsys.jac
    r = lsys.r
    # Fill in diagonal
    fill_accumulation!(jac, r, law.accumulation, apos)
    # Fill in off-diagonal
    fpos = law.half_face_flux_jac_pos
    fill_fluxes(jac, r, G.conn_data, law.half_face_flux, apos, fpos)
end

function fill_accumulation!(jac, r, acc, apos)
    @inbounds Threads.@threads for i = 1:size(apos, 2)
        r[i] = acc[i].value
        @inbounds for derNo = 1:size(apos, 1)
            index = apos[derNo, i]
            jac.nzval[index] = acc[i].partials[derNo]
        end
    end
end

function fill_fluxes(jac, r, conn_data, half_face_flux, apos, fpos)
    @inbounds Threads.@threads for i = 1:size(fpos, 2)
        cell_index = conn_data[i].self
        r[cell_index] += half_face_flux[i].value
        @inbounds for derNo = 1:size(apos, 1)
            index = fpos[derNo, i]
            diag_index = apos[derNo, cell_index]
            df_di = half_face_flux[i].partials[derNo]
            jac.nzval[index] = -df_di
            jac.nzval[diag_index] += df_di
        end
    end
end
## Systems
# Immiscible multiphase system
struct ImmiscibleSystem <: MultiPhaseSystem
    phases::AbstractVector
end

# Single-phase
struct SinglePhaseSystem <: MultiPhaseSystem
    phase
end

function get_phases(sys::SinglePhaseSystem)
    return [sys.phase]
end

function number_of_phases(::SinglePhaseSystem)
    return 1
end

## Phases
# Abstract phase
abstract type AbstractPhase end

function get_short_name(phase::AbstractPhase)
    return get_name(phase)[1:1]
end

# Liquid phase
struct LiquidPhase <: AbstractPhase end

function get_name(::LiquidPhase)
    return "Liquid"
end

# Vapor phases
struct VaporPhase <: AbstractPhase end

function get_name(::VaporPhase)
    return "Vapor"
end

