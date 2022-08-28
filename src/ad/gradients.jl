export state_gradient
function state_gradient(model, state, F, extra_arg...; kwarg...)
    n_total = number_of_degrees_of_freedom(model)
    ∂F∂x = zeros(n_total)
    return state_gradient!(∂F∂x, model, state, F, extra_arg...; kwarg...)
end

function state_gradient!(∂F∂x, model, state, F, extra_arg...; parameters = setup_parameters(model))
    # Either with respect to all primary variables, or all parameters.
    state = setup_state(model, state)
    state = merge_state_with_parameters(model, state, parameters)
    state = convert_state_ad(model, state)
    state = convert_to_immutable_storage(state)
    # TODO: Evaluate props here.
    state_gradient_outer!(∂F∂x, F, model, state, extra_arg)
    return ∂F∂x
end

function merge_state_with_parameters(model, state, parameters)
    for (k, v) in pairs(parameters)
        state[k] = v
    end
    return state
end

function state_gradient_outer!(∂F∂x, F, model, state, extra_arg)
    state_gradient_inner!(∂F∂x, F, model, state, nothing, extra_arg)
end

function state_gradient_inner!(∂F∂x, F, model, state, tag, extra_arg, eval_model = model)
    layout = matrix_layout(model.context)
    get_partial(x::AbstractFloat, i) = 0.0
    get_partial(x::ForwardDiff.Dual, i) = x.partials[i]
    function diff_entity!(∂F∂x, state, i, S, ne, np, offset)
        state_i = local_ad(state, i, S)
        v = F(eval_model, state_i, extra_arg...)
        for p_i in 1:np
            ix = alignment_linear_index(i, p_i, ne, np, layout) + offset
            ∂F∂x[ix] = get_partial(v, p_i)
        end
    end
    offset = 0
    for e in get_primary_variable_ordered_entities(model)
        np = number_of_partials_per_entity(model, e)
        ne = count_active_entities(model.domain, e)
        ltag = get_entity_tag(tag, e)
        S = typeof(get_ad_entity_scalar(1.0, np, tag = ltag))
        for i in 1:ne
            diff_entity!(∂F∂x, state, i, S, ne, np, offset)
        end
        offset += ne*np
    end
end

function setup_adjoint_storage(model; state0 = setup_state(model), parameters = setup_parameters(model))
    primary_model = adjoint_model_copy(model)
    # Standard model for: ∂Fₙᵀ / ∂xₙ
    forward_sim = Simulator(primary_model, state0 = deepcopy(state0), parameters = deepcopy(parameters), mode = :forward, extra_timing = nothing)
    # Same model, but adjoint for: ∂Fₙ₊₁ᵀ / ∂xₙ
    backward_sim = Simulator(primary_model, state0 = deepcopy(state0), parameters = deepcopy(parameters), mode = :reverse, extra_timing = nothing)
    # Create parameter model for ∂Fₙ / ∂p
    parameter_model = adjoint_parameter_model(model)
    parameter_sim = Simulator(parameter_model, state0 = deepcopy(parameters), parameters = deepcopy(state0), mode = :sensitivities, extra_timing = nothing)

    n_pvar = number_of_degrees_of_freedom(model)
    λ = zeros(n_pvar)
    return (forward = forward_sim, backward = backward_sim, parameter = parameter_sim, lagrange = λ)
end

function solve_adjoint_sensitivities(model, states, reports, G; extra_timing = false, state0 = setup_state(model), forces = setup_forces(model), raw_output = false, kwarg...)
    # One simulator object for the equations with respect to primary (at previous time-step)
    # One simulator object for the equations with respect to parameters
    # For model equations F the gradient with respect to parameters p is
    # ∇ₚG = Σₙ (∂Fₙ / ∂p)ᵀ λₙ where n ∈ [1, N]
    # Given Lagrange multipliers λₙ from the adjoint equations
    # (∂Fₙ / ∂xₙ)ᵀ λₙ = - (∂J / ∂xₙ)ᵀ - (∂Fₙ₊₁ / ∂xₙ)ᵀ λₙ₊₁
    # where the last term is omitted for step n = N and G is the objective function
    set_global_timer!(extra_timing)
    # Allocation part
    storage = setup_adjoint_storage(model; state0 = state0, kwarg...)
    parameter_model = storage.parameter.model
    n_param = number_of_degrees_of_freedom(parameter_model)
    ∇G = zeros(n_param)
    # Timesteps
    timesteps = report_timesteps(reports)
    N = length(states)
    @assert length(reports) == N == length(timesteps)
    # Solve!
    solve_adjoint_sensitivities!(∇G, storage, states, state0, timesteps, G, forces = forces)
    print_global_timer(extra_timing; text = "Adjoint solve detailed timing")
    if raw_output
        out = ∇G
    else
        out = store_sensitivities(parameter_model, ∇G)
    end
    return out
end

function solve_adjoint_sensitivities!(∇G, storage, states, state0, timesteps, G; forces = setup_forces(model))
    N = length(timesteps)
    @assert N == length(states)
    @timeit "sensitivities" for i in N:-1:1
        fn = deepcopy
        if i == 1
            s0 = fn(state0)
        else
            s0 = fn(states[i-1])
        end
        if i == N
            s_next = nothing
        else
            s_next = fn(states[i+1])
        end
        s = fn(states[i])
        update_sensitivities!(∇G, i, G, storage, s0, s, s_next, timesteps, forces)
    end
    return ∇G
end

function update_sensitivities!(∇G, i, G, adjoint_storage, state0, state, state_next, timesteps, all_forces)
    # Unpack simulators
    parameter_sim = adjoint_storage.parameter
    backward_sim = adjoint_storage.backward
    forward_sim = adjoint_storage.forward
    λ = adjoint_storage.lagrange
    # Timestep logic
    N = length(timesteps)
    forces = forces_for_timestep(forward_sim, all_forces, timesteps, i)
    dt = timesteps[i]
    # Assemble Jacobian w.r.t. current step
    @timeit "jacobian (standard)" adjoint_reassemble!(forward_sim, state, state0, dt, forces)
    # Note the sign: There is an implicit negative sign in the linear solver when solving for the Newton increment. Therefore, the terms of the
    # right hand side are added with a positive sign instead of negative.
    lsys = forward_sim.storage.LinearizedSystem
    rhs = lsys.r_buffer
    # Fill rhs with (∂J / ∂x)ᵀₙ (which will be treated with a negative sign when the result is written by the linear solver)
    @timeit "objective gradient" state_gradient_outer!(rhs, G, forward_sim.model, forward_sim.storage.state, (dt, i, forces))
    if isnothing(state_next)
        @assert i == N
        @. λ = 0
    else
        dt_next = timesteps[i+1]
        forces_next = forces_for_timestep(backward_sim, all_forces, timesteps, i+1)
        @timeit "jacobian (with state0)" adjoint_reassemble!(backward_sim, state_next, state, dt_next, forces_next)
        lsys_next = backward_sim.storage.LinearizedSystem
        op = linear_operator(lsys_next)
        # In-place version of
        # rhs += op*λ
        # - (∂Fₙ₊₁ / ∂xₙ)ᵀ λₙ₊₁
        mul!(rhs, op, λ, 1.0, 1.0)
    end
    # We have the right hand side, assemble the Jacobian and solve for the Lagrange multiplier
    @timeit "linear solve" solve!(lsys)
    @. λ = lsys.dx_buffer
    # ∇ₚG = Σₙ (∂Fₙ / ∂p)ᵀ λₙ
    # Increment gradient
    @timeit "jacobian (for parameters)" adjoint_reassemble!(parameter_sim, state, state0, dt, forces)
    lsys_next = parameter_sim.storage.LinearizedSystem
    op_p = linear_operator(lsys_next)
    # In-place version of:
    # ∇G += op_p*λ
    mul!(∇G, op_p, λ, 1.0, 1.0)
end

function adjoint_reassemble!(sim, state, state0, dt, forces)
    s = sim.storage
    model = sim.model
    # Deal with state0 first
    reset_previous_state!(sim, state0)
    update_secondary_variables!(s, model, state0 = true)
    # Apply logic as if timestep is starting
    update_before_step!(s, model, dt, forces)
    # Then the current primary variables
    reset_primary_variables!(s, model, state)
    update_state_dependents!(s, model, dt, forces)
    # Finally update the system
    update_linearized_system!(s, model)
end

function swap_primary_with_parameters!(pmodel, model)
    set_parameters!(pmodel; pairs(model.primary_variables)...)
    # Original model holds the parameters, use those
    set_primary_variables!(pmodel; pairs(model.parameters)...)
    out = vcat(keys(model.secondary_variables)..., keys(model.primary_variables)...)
    for k in out
        push!(pmodel.output_variables, k)
    end
    unique!(pmodel.output_variables)
    return pmodel
end

function adjoint_parameter_model(model)
    pmodel = adjoint_model_copy(model)
    # Swap parameters and primary variables
    swap_primary_with_parameters!(pmodel, model)
    return pmodel
end

function adjoint_model_copy(model::SimulationModel{O, S, C, F}) where {O, S, C, F}
    pvar = copy(model.primary_variables)
    svar = copy(model.secondary_variables)
    outputs = vcat(keys(pvar)..., keys(svar)...)
    prm = copy(model.parameters)
    eqs = model.equations
    # Transpose the system
    new_context = adjoint(model.context)
    return SimulationModel{O, S, C, F}(model.domain, model.system, new_context, model.formulation, pvar, svar, prm, eqs, outputs)
end

function solve_numerical_sensitivities(model, states, reports, G, target;
                                                forces = setup_forces(model),
                                                state0 = setup_state(model),
                                                parameters = setup_parameters(model),
                                                epsilon = 1e-8)
    timesteps = report_timesteps(reports)
    N = length(states)
    @assert length(reports) == N == length(timesteps)
    # Base objective
    base_obj = evaluate_objective(G, model, states, timesteps, forces)
    # Define perturbation
    param_var, param_num = get_parameter_pair(model, parameters, target)
    grad_num = zeros(length(param_num))
    scale = variable_scale(param_var)
    if isnothing(scale)
        ϵ = epsilon
    else
        ϵ = scale*epsilon
    end
    for i in eachindex(grad_num)
        param_i = deepcopy(parameters)
        perturb_parameter!(model, param_i, target, i, ϵ)
        sim_i = Simulator(model, state0 = copy(state0), parameters = param_i)
        states_i, reports = simulate!(sim_i, timesteps, info_level = -1, forces = forces)
        v = evaluate_objective(G, model, states_i, timesteps, forces)
        grad_num[i] = (v - base_obj)/ϵ
    end
    return grad_num
end

function get_parameter_pair(model, parameters, target)
    return (model.parameters[target], parameters[target])
end

function perturb_parameter!(model, param_i, target, i, ϵ)
    param_i[target][i] += ϵ
end

function evaluate_objective(G, model, states, timesteps, all_forces)
    obj = 0.0
    for (step_no, state) in enumerate(states)
        forces = forces_for_timestep(nothing, all_forces, timesteps, step_no)
        dt = timesteps[step_no]
        obj += G(model, state, dt, step_no, forces)
    end
    return obj
end

function store_sensitivities(model, result)
    out = Dict{Symbol, Any}()
    store_sensitivities!(out, model, result)
    return out
end

function store_sensitivities!(out, model, result; kwarg...)
    variables = model.primary_variables
    layout = matrix_layout(model.context)
    return store_sensitivities!(out, model, variables, result, layout; kwarg...)
end

function store_sensitivities!(out, model, variables, result, ::EquationMajorLayout; offset = 0)
    for (k, var) in pairs(variables)
        n = number_of_degrees_of_freedom(model, var)
        m = degrees_of_freedom_per_entity(model, var)
        if n > 0
            r = view(result, (offset+1):(offset+n))
            if var isa ScalarVariable
                v = r
            else
                v = reshape(r, m, n ÷ m)
            end
            v = collect(v)
            scale = variable_scale(var)
            # Variable was scaled - account for this before returning
            if !isnothing(scale)
                v ./= scale
            end
            out[k] = v
        else
            out[k] = similar(result, 0)
        end
        offset += n
    end
    return out
end