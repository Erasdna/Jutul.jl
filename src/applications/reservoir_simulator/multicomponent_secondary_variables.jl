# Saturations as primary variable
struct OverallMoleFractions <: FractionVariables
    dz_max
    OverallMoleFractions(;dz_max = 0.2) = new(dz_max)
end

values_per_entity(model, v::OverallMoleFractions) = number_of_components(model.system)

minimum_value(::OverallMoleFractions) = MultiComponentFlash.MINIMUM_COMPOSITION
absolute_increment_limit(z::OverallMoleFractions) = z.dz_max


function update_primary_variable!(state, p::OverallMoleFractions, state_symbol, model, dx)
    s = state[state_symbol]
    unit_sum_update!(s, p, model, dx)
end

mutable struct InPlaceFlashBuffer
    z
    forces
    function InPlaceFlashBuffer(n)
        z = zeros(n)
        new(z, nothing)
    end
end

struct FlashResults <: ScalarVariable
    storage
    method
    update_buffer
    function FlashResults(system; method = SSIFlash(), kwarg...)
        eos = system.equation_of_state
        # np = number_of_partials_per_entity(system, Cells())
        n = MultiComponentFlash.number_of_components(eos)
        s = flash_storage(eos, method = method, inc_jac = true, diff_externals = true, npartials = n, static_size = true)
        new(s, method, InPlaceFlashBuffer(n))
    end
end

default_value(model, ::FlashResults) = FlashedMixture2Phase(model.system.equation_of_state)

function initialize_variable_value!(state, model, pvar::FlashResults, symb, val::AbstractDict; need_value = false)
    @assert need_value == false
    n = number_of_entities(model, pvar)
    v = default_value(model, pvar)
    T = typeof(v)
    V = Vector{T}(undef, n)
    for i in 1:n
        V[i] = default_value(model, pvar)
    end
    # V = repeat([v], n)
    initialize_variable_value!(state, model, pvar, symb, V)
end

function initialize_variable_ad(state, model, pvar::FlashResults, symb, npartials, diag_pos; context = DefaultContext(), kwarg...)
    n = number_of_entities(model, pvar)
    v_ad = get_ad_entity_scalar(1.0, npartials, diag_pos; kwarg...)
    ∂T = typeof(v_ad)

    r = FlashedMixture2Phase(model.system.equation_of_state, ∂T)
    T = typeof(r)
    V = Vector{T}(undef, n)
    for i in 1:n
        V[i] = FlashedMixture2Phase(model.system.equation_of_state, ∂T)
    end
    state[symb] = V
    return state
end

struct TwoPhaseCompositionalDensities <: PhaseMassDensities
end

struct PhaseMassFractions <: FractionVariables
    phase
end

struct LBCViscosities <: PhaseVariables end

values_per_entity(model, v::PhaseMassFractions) = number_of_components(model.system)

function select_secondary_variables_system!(S, domain, system::CompositionalSystem, formulation)
    nph = number_of_phases(system)
    S[:PhaseMassDensities] = TwoPhaseCompositionalDensities()
    S[:LiquidMassFractions] = PhaseMassFractions(:liquid)
    S[:VaporMassFractions] = PhaseMassFractions(:vapor)
    S[:TotalMasses] = TotalMasses()
    S[:FlashResults] = FlashResults(system)
    S[:Saturations] = Saturations()
    S[:Temperature] = ConstantVariables([273.15 + 30.0])
    S[:PhaseViscosities] = LBCViscosities() # 1 cP for all phases by default
end

degrees_of_freedom_per_entity(model, v::MassMobilities) = number_of_phases(model.system)#*number_of_components(model.system)


@terv_secondary function update_as_secondary!(flash_results, fr::FlashResults, model, param, Pressure, Temperature, OverallMoleFractions)
    # S = flash_storage(eos)
    S, m, buf = fr.storage, fr.method, fr.update_buffer
    eos = model.system.equation_of_state
    for i in eachindex(flash_results)
        f = flash_results[i]
        P = Pressure[i]
        T = Temperature[1, i]
        Z = @view OverallMoleFractions[:, i]

        flash_results[i] = update_flash_result(S, m, buf, eos, f, P, T, Z)
    end
end

function update_flash_result(S, m, buffer, eos, f, P, T, Z)
    K = f.K
    z, forces = buffer.z, buffer.forces
    @. z = value(Z)
    # Conditions
    c = (p = value(P), T = value(T), z = z)
    # Perform flash
    vapor_frac = flash_2ph!(S, K, eos, c, NaN, method = m, extra_out = false)
    if isnothing(forces)
        # Initialize.
        forces = force_coefficients(eos, (p = P, T = T, z = Z), static_size = true)
    end

    l, v = f.liquid, f.vapor
    x = l.mole_fractions
    y = v.mole_fractions
    if isnan(vapor_frac)
        # Single phase condition. Life is easy.
        vals = single_phase_update!(P, T, Z, x, y, forces, eos, c)
    else
        # Two-phase condition: We have some work to do.
        vals = two_phase_update!(S, P, T, Z, x, y, K, vapor_frac, forces, eos, c)
    end
    Z_L, Z_V, V, phase_state = vals
    return FlashedMixture2Phase(phase_state, K, V, x, y, Z_L, Z_V)
end

function get_compressibility_factor(forces, eos, P, T, Z)
    ∂cond = (p = P, T = T, z = Z)
    force_coefficients!(forces, eos, ∂cond)
    return mixture_compressibility_factor(eos, ∂cond, forces)
end

function single_phase_update!(P, T, Z, x, y, forces, eos, c)
    AD = Base.promote_type(eltype(Z), typeof(P), typeof(T))
    Z_L = get_compressibility_factor(forces, eos, P, T, Z)
    Z_V = Z_L
    @. x = Z
    @. y = Z
    V = single_phase_label(eos.mixture, c)
    if V > 0.5
        phase_state = SinglePhaseVapor()
    else
        phase_state = SinglePhaseLiquid()
    end
    out = (Z_L::AD, Z_V::AD, V::Float64, phase_state::Union{SinglePhaseVapor, SinglePhaseLiquid})
    return out
end

function two_phase_update!(S, P, T, Z, x, y, K, vapor_frac, forces, eos, c)
    @. x = liquid_mole_fraction(Z, K, vapor_frac)
    @. y = vapor_mole_fraction(x, K)
    if eltype(x)<:ForwardDiff.Dual
        inverse_flash_update!(S, eos, c, vapor_frac)
        ∂c = (p = P, T = T, z = Z)
        V = set_partials_vapor_fraction(convert(eltype(x), vapor_frac), S, eos, ∂c)
        set_partials_phase_mole_fractions!(x, S, eos, ∂c, :liquid)
        set_partials_phase_mole_fractions!(y, S, eos, ∂c, :vapor)
    else
        V = vapor_frac
    end
    Z_L = get_compressibility_factor(forces, eos, P, T, x)
    Z_V = get_compressibility_factor(forces, eos, P, T, y)
    phase_state = TwoPhaseLiquidVapor()

    return (Z_L, Z_V, V, phase_state)
end

@terv_secondary function update_as_secondary!(Sat, s::Saturations, model::SimulationModel{D, S}, param, FlashResults) where {D, S<:CompositionalSystem}
    for i in 1:size(Sat, 2)
        S_l, S_v = phase_saturations(FlashResults[i])
        Sat[1, i] = S_l
        Sat[2, i] = S_v
    end
end

@terv_secondary function update_as_secondary!(massmob, m::MassMobilities, model::SimulationModel{D, S}, param) where {D, S<:CompositionalSystem}
    # error()
end

@terv_secondary function update_as_secondary!(X, m::PhaseMassFractions, model::SimulationModel{D, S}, param, FlashResults) where {D, S<:CompositionalSystem}
    molar_mass = map((x) -> x.mw, model.system.equation_of_state.mixture.properties)
    phase = m.phase
    for (i, f) in enumerate(FlashResults)
        if phase_is_present(phase, f.state)
            X_i = view(X, :, i)
            r = getfield(f, phase)
            x_i = r.mole_fractions
            update_mass_fractions!(X_i, x_i, molar_mass)
        end
    end
end

function update_mass_fractions!(X, x, molar_masses)
    t = 0
    for i in eachindex(x)
        tmp = molar_masses[i]*x[i]
        t += tmp
        X[i] = tmp
    end
    @. X = X/t
end

@terv_secondary function update_as_secondary!(rho, m::TwoPhaseCompositionalDensities, model::SimulationModel{D, S}, param, Pressure, Temperature, FlashResults) where {D, S<:CompositionalSystem}
    eos = model.system.equation_of_state
    for i in 1:size(rho, 2)
        p = Pressure[i]
        T = Temperature[1, i]
        ρ_l, ρ_v = mass_densities(eos, p, T, FlashResults[i])
        rho[1, i] = ρ_l
        rho[2, i] = ρ_v
    end
end

@terv_secondary function update_as_secondary!(rho, m::LBCViscosities, model::SimulationModel{D, S}, param, Pressure, Temperature, FlashResults) where {D, S<:CompositionalSystem}
    eos = model.system.equation_of_state
    for i in 1:size(rho, 2)
        p = Pressure[i]
        T = Temperature[1, i]
        ρ_l, ρ_v = lbc_viscosities(eos, p, T, FlashResults[i])
        rho[1, i] = ρ_l
        rho[2, i] = ρ_v
    end
end

# Total masses
@terv_secondary function update_as_secondary!(totmass, tv::TotalMasses, model::SimulationModel{G, S}, param, FlashResults, PhaseMassDensities, Saturations, VaporMassFractions, LiquidMassFractions) where {G, S<:CompositionalSystem}
    pv = get_pore_volume(model)
    ρ = PhaseMassDensities
    X = LiquidMassFractions
    Y = VaporMassFractions
    Sat = Saturations
    F = FlashResults

    # @info "Total mass" value.(Sat) value.(X) value.(Y) value.(ρ)
    @tullio totmass[c, i] = two_phase_compositional_mass(F[i].state, ρ, X, Y, Sat, c, i)*pv[i]
    # @debug "Total mass updated:" totmass[:, 1] ρ[:, 1] Sat[:, 1] pv[1]
end

function two_phase_compositional_mass(::SinglePhaseVapor, ρ, X, Y, Sat, c, i)
    M = ρ[2, i]*Sat[2, i]*Y[c, i]
    # @info "Vapor cell $i component $c" M
    return M
end

function two_phase_compositional_mass(::SinglePhaseLiquid, ρ, X, Y, Sat, c, i)
    M = ρ[1, i]*Sat[1, i]*X[c, i]
    return M
end

function two_phase_compositional_mass(::TwoPhaseLiquidVapor, ρ, X, Y, S, c, i)
    M_v = ρ[1, i]*S[1, i]*X[c, i]
    M_l = ρ[2, i]*S[2, i]*Y[c, i]
    return M_l + M_v
end