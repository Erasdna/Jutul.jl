export TotalMassFlux
export WellGrid, MultiSegmentWell
export TotalMassFlux, PotentialDropBalanceWell

export InjectorControl, ProducerControl, SinglePhaseRateTarget, BottomHolePressureTarget

export Well, Perforations
export MixedWellSegmentFlow
export segment_pressure_drop


abstract type WellPotentialFlowDiscretization <: PotentialFlowDiscretization end

"""
Two point approximation with flux for wells
"""
struct MixedWellSegmentFlow <: WellPotentialFlowDiscretization end

abstract type WellGrid <: PorousMediumGrid 
    # Wells are not porous themselves per se, but they are discretizing 
    # part of a porous medium.
end

# Total velocity in each well segment
struct TotalMassFlux <: ScalarVariable end
function associated_unit(::TotalMassFlux) Faces() end


struct MultiSegmentWell <: WellGrid 
    volumes          # One per cell
    perforations     # (self -> local cells, reservoir -> reservoir cells, WI -> connection factor)
    neighborship     # Well cell connectivity
    top              # "Top" node where scalar well quantities live
    reservoir_symbol # Symbol of the reservoir the well is coupled to
    segment_models   # Segment pressure drop model
    function MultiSegmentWell(volumes::AbstractVector, reservoir_cells;
                                                        WI = nothing,
                                                        N = nothing,
                                                        perforation_cells = nothing,
                                                        segment_models = nothing,
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
        nseg = size(N, 2)
        @assert size(N, 1) == 2

        volumes = vcat([accumulator_volume], volumes)
        if isnothing(WI)
            @warn "No well indices provided. Using 1e-12."
            WI = repeat(1e-12, nr)
        end
        if !isnothing(reservoir_cells) && isnothing(perforation_cells)
            @assert length(reservoir_cells) == nv "If no perforation cells are given, we must 1->1 correspondence between well volumes and reservoir cells."
            perforation_cells = collect(2:nc)
        end
        if isnothing(segment_models)
            Δp = SegmentWellBoreFrictionHB(100.0, 1e-4, 0.1)
            segment_models = repeat([Δp], nseg)
        else
            segment_models::AbstractVector
            @assert length(segment_models) == nseg
        end
        # @assert length(dz) == nseg "dz must have one entry per segment, plus one for the top segment"
        @assert length(WI) == nr  "Must have one well index per perforated cell"
        @assert length(perforation_cells) == nr

        perf = (self = perforation_cells, reservoir = reservoir_cells, WI = WI)
        accumulator = (reference_depth = reference_depth, )
        new(volumes, perf, N, accumulator, reservoir_symbol, segment_models)
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

function segment_pressure_drop(f::SegmentWellBoreFrictionHB, v, ρ, μ)
    D⁰, Dⁱ = f.D_outer, f.D_inner
    R, L = f.roughness, f.L
    ΔD = D⁰-Dⁱ
    s = sign(v)
    if s == 0
        s = 1
    end
    e = eps(typeof(value(v)))
    v = s*max(abs(v), e)
    # Scaling - assuming input is total mass rate
    v = v./(π*ρ.*((D⁰/2)^2 - (Dⁱ/2)^2));
    Re = abs(v*ρ*ΔD)/μ;
    # Friction model - empirical relationship
    f = (-3.6*log(6.9/Re +(R/(3.7*D⁰))^(10/9))/log(10))^(-2);
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

function declare_pattern(model, e::PotentialDropBalanceWell, ::Cells)
    D = model.domain
    N = D.grid.neighborship
    nf = number_of_faces(D)
    m = size(N, 1)
    # nc = number_of_cells(D)
    @assert size(N, 2) == nf
    @assert m == 2
    t = eltype(N)
    I = Vector{t}()
    J = Vector{t}()
    for f in 1:nf
        for i in 1:m
            push!(I, f)
            push!(J, N[i, f])
        end
    end
    return (I, J)
end

function align_to_jacobian!(eq::PotentialDropBalanceWell, jac, model, u::Cells; kwarg...)
    # Need to align to cells, faces is automatically done since it is on the diagonal bands
    cache = eq.equation_cells
    layout = matrix_layout(model.context)
    N = model.domain.grid.neighborship
    nc = count_units(model.domain, u)
    potential_drop_cells_alignment!(cache, jac, N, layout, nc; kwarg...)
end

function potential_drop_cells_alignment!(cache, jac, N, layout, nc; equation_offset = 0, variable_offset = 0)
    _, ne, np = ad_dims(cache)
    nf = size(N, 2)
    nu_t = nf
    nu_s = nc
    for face in 1:nf
        for lr = 1:size(N, 1)
            cellix = N[lr, face]
            for e in 1:ne
                for d = 1:np
                    pos = find_jac_position(jac, face + equation_offset, cellix + variable_offset, e, d, nu_t, nu_s, ne, np, layout)
                    set_jacobian_pos!(cache, 2*(face-1) + lr, e, d, pos)
                end
            end
        end
    end
end

function update_equation!(eq::PotentialDropBalanceWell, storage, model, dt)
    # Loop over segments, calculate pressure drop, ...
    W = model.domain.grid
    state = storage.state
    nph = number_of_phases(model.system)
    single_phase = nph == 1
    if single_phase
        s = 1.0
    else
        s = state.Saturations
    end
    p = state.Pressure
    μ = storage.parameters.Viscosity
    V = state.TotalMassFlux
    densities = state.PhaseMassDensities

    face_entries = eq.equation.entries
    cell_entries = eq.equation_cells.entries

    mass_flow = model.domain.discretizations.mass_flow
    conn_data = mass_flow.conn_data
    for index = 1:length(conn_data)
        cd = conn_data[index]
        gΔz = cd.gdz
        self = cd.self
        other = cd.other
        face = cd.face
        seg_model = W.segment_models[face]

        if single_phase
            s_self, s_other = s, s
        else
            s_self = view(s, :, self)
            s_other = as_value(view(s, :, other))
        end

        p_self = p[self]
        p_other = value(p[other])

        ρ_mix_self = mix_by_saturations(s_self, view(densities, :, self))
        ρ_mix_other = mix_by_saturations(s_other, as_value(view(densities, :, other)))

        Δθ = two_point_potential_drop(p_self, p_other, gΔz, ρ_mix_self, ρ_mix_other)
        if Δθ > 0
            μ_mix = mix_by_saturations(s_self, μ)
        else
            μ_mix = mix_by_saturations(s_other, μ)
        end

        sgn = cd.face_sign
        v = sgn*V[face]
        ρ_mix = 0.5*(ρ_mix_self + ρ_mix_other)

        if sgn == 1
            # This is a good time to deal with the derivatives of v[face] since it is already fetched.
            Δp_f = segment_pressure_drop(seg_model, v, value(ρ_mix), value(μ_mix))
            face_entries[face] = value(Δθ) - Δp_f
            # @debug "Δp_f $face: $Δp_f flux: $v\neq_f: $(face_entries[face])"
            # @debug "rho: $(value(ρ_mix)) mu: $(value(μ_mix))"

            ix = 1
        else
            ix = 2
        end
        Δp = segment_pressure_drop(seg_model, value(v), ρ_mix, μ_mix)
        cell_entries[(face-1)*2 + ix] = sgn*(Δθ - Δp)
        # @debug "Cell entry ($face:$self→$other): $(sgn*(Δθ - Δp))"
    end
end

function update_linearized_system_equation!(nz, r, model, equation::PotentialDropBalanceWell)
    fill_equation_entries!(nz, r, model, equation.equation)
    fill_equation_entries!(nz, nothing, model, equation.equation_cells)
end


function get_flow_volume(grid::WellGrid)
    grid.volumes
end

# Well segments
"""
Perforations are connections from well cells to reservoir vcells
"""
struct Perforations <: TervUnit end

## Well targets


function declare_units(W::MultiSegmentWell)
    c = (unit = Cells(),         count = length(W.volumes))
    f = (unit = Faces(),         count = size(W.neighborship, 2))
    p = (unit = Perforations(),  count = length(W.perforations.self))
    return [c, f, p]
end

"""
Intersection of well with reservoir cells
"""
function get_domain_intersection(u::Cells, target_d::DiscretizedDomain{G}, source_d::DiscretizedDomain{W},
    target_symbol, source_symbol) where {W<:WellGrid, G<:ReservoirGrid}
    well = source_d.grid
    if target_symbol == well.reservoir_symbol
        # The symbol matches up and this well exists in this reservoir
        p = well.perforations
        isect = (target = p.reservoir, source = p.self, target_unit = Cells(), source_unit = Cells())
    else
        isect = (target = nothing, source = nothing, target_unit = Cells(), source_unit = Cells())
    end
end

"""
Intersection of reservoir with well cells
"""
function get_domain_intersection(u::Cells, target_d::DiscretizedDomain{W}, source_d::DiscretizedDomain{G}, target_symbol, source_symbol) where {W<:WellGrid, G<:ReservoirGrid}
    # transpose the connections
    source, target, source_unit, target_unit = get_domain_intersection(u, source_d, target_d, source_symbol, target_symbol)
    return (target = target, source = source, target_unit = target_unit, source_unit = source_unit)
end

"""
Intersection of wells to wells
"""
#function get_domain_intersection(u::Cells, target_d::DiscretizedDomain{W}, source_d::DiscretizedDomain{W}, target_symbol, source_symbol) where {W<:WellGrid}
#    return (target = nothing, source = nothing, target_unit = u, source_unit = u)
#end

"""
Cross term from wellbore into reservoir
"""
function update_cross_term!(ct::InjectiveCrossTerm, eq::ConservationLaw, 
                            target_storage, source_storage,
                            target_model::SimulationModel{DR},
                            source_model::SimulationModel{DW}, 
                            target, source, dt) where {DR<:DiscretizedDomain{G} where G<:ReservoirGrid,
                                                       DW<:DiscretizedDomain{W} where W<:MultiSegmentWell}
    # error("Hello world")
    state_res = target_storage.state
    state_well = source_storage.state

    perforations = source_model.domain.grid.perforations

    res_q = ct.crossterm_target
    well_q = ct.crossterm_source
    apply_well_reservoir_sources!(res_q, well_q, state_res, state_well, perforations, 1)
end

function update_cross_term!(ct::InjectiveCrossTerm, eq::ConservationLaw, 
    target_storage, source_storage,
    target_model::SimulationModel{DW}, 
    source_model::SimulationModel{DR},
    target, source, dt) where {DR<:DiscretizedDomain{G} where G<:ReservoirGrid,
                               DW<:DiscretizedDomain{W} where W<:MultiSegmentWell}
    state_res = source_storage.state
    state_well = target_storage.state

    perforations = target_model.domain.grid.perforations

    res_q = ct.crossterm_source
    well_q = ct.crossterm_target
    apply_well_reservoir_sources!(res_q, well_q, state_res, state_well, perforations, -1)
end


function apply_well_reservoir_sources!(res_q, well_q, state_res, state_well, perforations, sgn)
    p_res = state_res.Pressure
    p_well = state_well.Pressure
    λ = state_res.PhaseMobilities
    ρλ_i = state_res.MassMobilities
    masses = state_well.TotalMasses

    perforation_sources!(well_q, perforations, as_value(p_res), p_well,           as_value(λ), as_value(ρλ_i), masses, sgn)
    perforation_sources!(res_q, perforations, p_res,           as_value(p_well), λ,           ρλ_i,           as_value(masses), sgn)
end

function perforation_sources!(target, perforations, p_res, p_well, λ, ρλ_i, masses, sgn)
    # (self -> local cells, reservoir -> reservoir cells, WI -> connection factor)
    nc = size(ρλ_i, 1)
    nph = size(λ, 1)

    for i in eachindex(perforations.self)
        si = perforations.self[i]
        ri = perforations.reservoir[i]
        wi = perforations.WI[i]
        # TODO: Check sign
        dp = wi*(p_res[ri] - p_well[si])
        if dp > 0
            # Injection
            λ_t = 0
            for ph in 1:nph
                λ_t += λ[ph, ri]
            end
            for c in 1:nc
                # dp * rho * s * totmob well
                target[c, i] = sgn*masses[c, si]*λ_t*dp
            end
        else
            # Production
            for c in 1:nc
                target[c, i] = sgn*ρλ_i[c, ri]*dp
            end
        end

    end
end


# Selection of primary variables
function select_primary_variables_domain!(S, domain::DiscretizedDomain{G}, system, formulation) where {G<:MultiSegmentWell}
    S[:TotalMassFlux] = TotalMassFlux()
end

function select_equations_domain!(eqs, domain::DiscretizedDomain{G}, system, arg...) where {G<:MultiSegmentWell}
    eqs[:potential_balance] = (PotentialDropBalanceWell, 1)
end

# Some utilities
function mix_by_mass(masses, total, values)
    v = 0
    for i in eachindex(masses)
        v += masses[i]*values[i]
    end
    return v/total
end

function mix_by_saturations(s, values)
    v = 0
    for i in eachindex(s)
        v += s[i]*values[i]
    end
    return v
end

function mix_by_saturations(s::Real, values)
    return s*values[]
end