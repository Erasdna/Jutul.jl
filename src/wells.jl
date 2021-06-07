export TotalMassFlux, BottomHolePressure, SurfacePhaseRates
export WellGrid, MultiSegmentWell
export TotalMassFlux, BottomHolePressure, SurfacePhaseRates

export InjectorControl, ProducerControl, SinglePhaseRateTarget, BottomHolePressureTarget

export Well, Perforations
export MixedWellSegmentFlow


abstract type WellPotentialFlowDiscretization <: PotentialFlowDiscretization end

"""
Two point approximation with flux for wells
"""
struct MixedWellSegmentFlow <: WellPotentialFlowDiscretization end

abstract type WellGrid <: PorousMediumGrid 
    # Wells are not porous themselves per se, but they are discretizing 
    # part of a porous medium.
end

struct MultiSegmentWell <: WellGrid 
    volumes          # One per cell
    perforations     # (self -> local cells, reservoir -> reservoir cells, WI -> connection factor)
    neighborship     # Well cell connectivity
    top              # "Top" node where scalar well quantities live
    reservoir_symbol # Symbol of the reservoir the well is coupled to
    function MultiSegmentWell(volumes::AbstractVector, reservoir_cells;
                                                        WI = nothing,
                                                        N = nothing,
                                                        perforation_cells = nothing,
                                                        reference_depth = 0,
                                                        accumulator_volume = 1e-3*mean(volumes),
                                                        reservoir_symbol = :Reservoir)
        nv = length(volumes)
        nc = nv + 1
        nr = length(reservoir_cells)
        if isnothing(N)
            @debug "No connectivity. Assuming nicely ordered linear well."
            N = vcat((1:nv)', (2:nc)')
        elseif maximum(N) == nv
            N = vcat([1, 2], N+1)
        end
        volumes = vcat([accumulator_volume], volumes)
        @show volumes
        if isnothing(WI)
            @warn "No well indices provided. Using 1e-12."
            WI = repeat(1e-12, nr)
        end
        if !isnothing(reservoir_cells) && isnothing(perforation_cells)
            @assert length(reservoir_cells) == nv "If no perforation cells are given, we must 1->1 correspondence between well volumes and reservoir cells."
            perforation_cells = collect(2:nc)
        end
        @assert size(N, 1) == 2
        # @assert length(dz) == nseg "dz must have one entry per segment, plus one for the top segment"
        @assert length(WI) == nr  "Must have one well index per perforated cell"
        @assert length(perforation_cells) == nr

        perf = (self = perforation_cells, reservoir = reservoir_cells, WI = WI)
        accumulator = (reference_depth = reference_depth, )
        new(volumes, perf, N, accumulator, reservoir_symbol)
    end
end

"""
Hagedorn and Brown well bore friction model for a segment.
"""
struct SegmentWellBoreFrictionHB
    L
    roughness
    D_outer
    D_inner
    assume_turbulent
    function SegmentWellBoreFrictionHB(L, roughness, D_outer; D_inner = 0, assume_turbulent = true)
        @assert assume_turbulent
        new(L, roughness, D_outer, D_inner, assume_turbulent)
    end
end

function segment_pressure_drop(sf::SegmentWellBoreFrictionHB, v, ρ, μ)
    D⁰, Dⁱ = sf.D_outer, sf.D_inner
    R, L = sf.roughness, sf.L
    ΔD = D⁰-Dⁱ
    Re = abs(v)ρ*ΔD/μ;
    s = sign(value(v))

    f = (-3.6*log(6.9./Re+(R./(3.7*D⁰))^(10/9))/log(10))^(-2);
    Δp = -(2*s*L/ΔD)*(f*ρ*v^2);
    return Δp
end

struct PotentialDropBalanceWell <: TervEquation
    # Equation: pot_diff(p) - pot_diff_model(v, p)
    equation # Differentiated with respect to Velocity
    equation_cells # Differentiated with respect to Cells
    function PotentialDropBalanceWell(e::TervAutoDiffCache, ec::TervAutoDiffCache)
        new(e, ec)
    end
end

function PotentialDropBalanceWell(model::TervModel, number_of_equations::Integer; kwarg...)
    D = model.domain
    cell_unit = Cells()
    face_unit = Faces()
    nf = count_units(D, face_unit)

    alloc = (n, unit) -> CompactAutoDiffCache(number_of_equations, n, model, unit = unit; kwarg...)
    # One equation per velocity
    eq = alloc(nf, face_unit)
    # Two cells per face -> 2*nf allocated
    eq_cells = alloc(2*nf, cell_unit)

    PotentialDropBalanceWell(eq, eq_cells)
end

function associated_unit(::PotentialDropBalanceWell) Faces() end

function mix_by_mass(masses, total, values)
    v = 0
    for i in eachindex(masses)
        v += masses[i]*values[i]
    end
    return v/total
end

function update_equation!(eq::PotentialDropBalanceWell, storage, model, dt)
    # Loop over segments, calculate pressure drop, ...
    G = model.domain.grid
    # nf = number_of_faces(G)
    state = storage.state
    @show state
    p = state.Pressure
    densities = state.PhaseMassDensities
    total_masses = state.TotalMasses
    total_mass = state.TotalMass

    λ = state.PhaseMobilities
    mass_flow = model.domain.discretizations.mass_flow
    conn_data = mass_flow.conn_data
    for index = 1:length(conn_data)
        cd = conn_data[index]
        gΔz = cd.gdz
        self = cd.self
        other = cd.other

        

        p_self = p[self]
        p_other = value(p[other])



        ρ_mix_self = mix_by_mass(view(total_masses, :, self), total_mass[self], view(densities, :, self))
        
        ρ_mix_other = mix_by_mass(as_value(view(total_masses, :, other)), value(total_mass[other]), as_value(view(densities, :, other)))

        @show total_mass[self]
        @show ρ_mix_self
        @show ρ_mix_other

        Δθ = two_point_potential_drop(p_self, p_other, gΔz, ρ_mix_self, ρ_mix_other)

        if cd.face_sign == 1
            # We do extra stuff
        end
        
        Δp = segment_pressure_drop(seg_model, v, ρ_mix, μ_mix)
        # L = G.neighborship[1, segNo]
        # R = G.neighborship[2, segNo]
        # p_L = p(L)
        # p_R = p(R)


        # Seen from left
        # dpL = value(p_R) - p_L
        # Seen from right
        #dpR = p_R - value(p_L)
        #if value(dpL) > 0
            
        #end

        
    end
    
    error("Not implemented yet")
end


struct ControlEquationWell <: TervEquation
    # Equation:
    #        q_t - target = 0
    #        p|top cell - target = 0
    # We need to store derivatives with respect to q_t (same unit) and the top cell (other unit)
    equation::TervAutoDiffCache
    equation_top_cell::TervAutoDiffCache
    function ControlEquationWell(model, number_of_equations; kwarg...)
        @assert number_of_equations == 1
        alloc = (unit) -> CompactAutoDiffCache(number_of_equations, 1, model, unit = unit; kwarg...)
        # One potential drop per velocity
        target_well = alloc(Well())
        target_topcell = alloc(Cells())
        new(target_well, target_topcell)
    end
end

function update_equation!(eq::ControlEquationWell, storage, model, dt)
    error("Not implemented yet")
    
end

function get_flow_volume(grid::WellGrid)
    grid.volumes
end

function associated_unit(::ControlEquationWell) Well() end


# Well segments
"""
Perforations are connections from well cells to reservoir vcells
"""
struct Perforations <: TervUnit end
"""
Well variables - units that we have exactly one of per well (and usually relates to the surface connection)
"""
struct Well <: TervUnit end

## Well targets
abstract type WellTarget end
struct BottomHolePressureTarget <: WellTarget
    value::AbstractFloat
end

struct SinglePhaseRateTarget <: WellTarget
    value::AbstractFloat
    phase::AbstractPhase
end

## Well controls
abstract type WellForce <: TervForce end
abstract type WellControlForce <: WellForce end

struct InjectorControl <: WellControlForce
    target::WellTarget
    injection_mixture
end

struct ProducerControl <: WellControlForce
    target::WellTarget
end

function declare_units(W::MultiSegmentWell)
    c = (unit = Cells(),         count = length(W.volumes))
    f = (unit = Faces(),         count = size(W.neighborship, 2))
    p = (unit = Perforations(),  count = length(W.perforations.self))
    w = (unit = Well(),          count = 1)
    return [c, f, p, w]
end

# abstract type WellConfiguration <: ScalarVariable end
mutable struct WellConfiguration
    control
    target
    limits
    function WellConfiguration(control = nothing, target = nothing, limits = nothing)
        new(control, target, limits)
    end
end



# Total velocity in each well segment
struct TotalMassFlux <: ScalarVariable end
function associated_unit(::TotalMassFlux) Faces() end

# Bottom hole pressure for the well
# struct BottomHolePressure <: ScalarVariable end
# function associated_unit(::BottomHolePressure) Well() end

# Phase rates for well at surface conditions
# struct SurfacePhaseRates <: GroupedVariables end
# function associated_unit(::SurfacePhaseRates) Well() end

struct TotalMassRateWell <: ScalarVariable end
function associated_unit(::TotalMassRateWell) Well() end

# function degrees_of_freedom_per_unit(model, v::SurfacePhaseRates)
#    return number_of_phases(model.system)
# end

# Selection of primary variables
function select_primary_variables_domain!(S, domain::DiscretizedDomain{G}, system, formulation) where {G<:MultiSegmentWell}
    S[:TotalMassFlux] = TotalMassFlux()
    S[:TotalWellMassRate] = TotalMassRateWell()
    # S[:SurfacePhaseRates] = SurfacePhaseRates()
    # S[:BottomHolePressure] = BottomHolePressure()
end

function select_equations!(eqs, domain::DiscretizedDomain{G}, system, arg...) where {G<:MultiSegmentWell}
    select_equations!(eqs, system)
    eqs[:potential_balance] = (PotentialDropBalanceWell, 1)
    eqs[:control_equation] = (ControlEquationWell, 1)
end

function build_forces(model::SimulationModel{D, S}; control = nothing, limits = nothing) where {D <: DiscretizedDomain{G} where G <: WellGrid, S <: MultiPhaseSystem}
    return (control = control, limits = limits,)
end

function initialize_extra_state_fields_domain!(state, model, domain::DiscretizedDomain{G}) where {G<:WellGrid}
    # Insert structure that holds well control (limits etc) that is then updated before each step
    state[:WellConfiguration] = WellConfiguration()
end

function update_before_step_domain!(storage, model::SimulationModel, domain::DiscretizedDomain{G}, dt, forces) where {G<:WellGrid}
    # Set control to whatever is on the forces
    storage.state.WellConfiguration.control = forces.control
    storage.state.WellConfiguration.limits = forces.limits
end
