using Jutul
using Test

function test_single(use_manual)
    sys = ScalarTestSystem()
    D = ScalarTestDomain(use_manual = use_manual)
    model = SimulationModel(D, sys)
    
    source = ScalarTestForce(1.0)
    forces = setup_forces(model, sources = source)
    state0 = setup_state(model, Dict(:XVar=>0.0))
    sim = Simulator(model, state0 = state0)
    states, = simulate(sim, [1.0], forces = forces, info_level = -1)

    X = states[end][:XVar]
    return X[] ≈ 1.0
end

@testset "Scalar test system" begin
    @test test_single(true)
    @test test_single(false)
end
