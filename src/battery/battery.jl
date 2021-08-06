using Terv
export get_flow_volume

#########
# utils #
#########


function get_flow_volume(grid::MinimalECTPFAGrid)
    grid.volumes
end

function declare_units(G::MinimalECTPFAGrid)
    # Cells equal to number of pore volumes
    c = (unit = Cells(), count = length(G.volumes))
    # Faces
    f = (unit = Faces(), count = size(G.neighborship, 2))
    return [c, f]
end

################
# All EC-comps #
################

# TODO: Remove the uncessecary ones
function single_unique_potential(model::ECModel)
    return false
end

function degrees_of_freedom_per_unit(model, sf::ChargeAcc)
    return 1
end

function degrees_of_freedom_per_unit(model, sf::MassAcc)
    return 1
end

function degrees_of_freedom_per_unit(model, sf::KGrad)
    return 1
end

function degrees_of_freedom_per_unit(model::ECModel, sf::Phi)
    return 1
end

function number_of_units(model, pv::KGrad)
    """ Two fluxes per face """
    return 2*count_units(model.domain, Faces())
end

function number_of_units(model, ::Phi)
    return count_units(model.domain, Cells())
end

function number_of_units(model, ::C)
    return count_units(model.domain, Cells())
end

function number_of_units(model, ::T)
    return count_units(model.domain, Cells())
end

function number_of_units(model, BP::BoundaryPotential)
    return size(model.domain.grid.boundary_cells)[1]
end
function number_of_units(model, BP::BoundaryCurrent)
    return size(BP.cells)[1]
end

function number_of_units(model, pv::NonDiagCellVariables)
    """ Each value depends on a cell and all its neighbours """
    return size(model.domain.discretizations.charge_flow.cellcell.tbl, 1) #! Assumes 2D
end

function values_per_unit(model, u::CellVector)
    return 2
end

function values_per_unit(model, u::ScalarNonDiagVaraible)
    return 1
end

function degrees_of_freedom_per_unit(model, sf::NonDiagCellVariables)
    return values_per_unit(model, sf) 
end

# ?Why not faces?
function associated_unit(::KGrad)
    Cells()
end

@inline function get_diagonal_cache(eq::Conservation)
    return eq.accumulation
end

function initialize_variable_value(
    model, pvar::NonDiagCellVariables, val; perform_copy=true
    )
    nu = number_of_units(model, pvar)
    nv = values_per_unit(model, pvar)
    
    @assert length(val) == nu * nv "Expected val length $(nu*nv), got $(length(val))"
    val::AbstractVector

    if perform_copy
        val = deepcopy(val)
    end
    return transfer(model.context, val)
end

function initialize_variable_value!(state, model, pvar::NonDiagCellVariables, symb::Symbol, val::Number)
    num_val = number_of_units(model, pvar)*values_per_unit(model, pvar)
    V = repeat([val], num_val)
    return initialize_variable_value!(state, model, pvar, symb, V)
end


function align_to_jacobian!(
    law::Conservation, jac, model, u::Cells; equation_offset = 0, 
    variable_offset = 0
    )
    fd = law.flow_discretization
    neighborship = get_neighborship(model.domain.grid)

    acc = law.accumulation
    hflux_cells = law.half_face_flux_cells
    density = law.density
    cctbl = model.domain.discretizations.charge_flow.cellcellvec.tbl

    diagonal_alignment!(
        acc, jac, u, model.context;
        target_offset = equation_offset, source_offset = variable_offset
        )
    half_face_flux_cells_alignment!(
        hflux_cells, acc, jac, model.context, neighborship, fd, 
        target_offset = equation_offset, source_offset = variable_offset
        )
    density_alignment!(
        density, acc, jac, model.context, neighborship, fd, cctbl;
        target_offset = equation_offset, source_offset = variable_offset
        )
end

function find_and_place_density!(
    jac, target, source, nu, ne, np, index, density, context
    )
    for e in 1:ne
        for d = 1:np
            pos = find_jac_position(
                jac, target, source, 
                e, d, 
                nu, nu, 
                ne, np, 
                context
                )
            set_jacobian_pos!(density, index, e, d, pos)
        end
    end
end

function density_alignment!(
    density, acc_cache, jac, context, N, flow_disc, cctbl;
    target_offset = 0, source_offset = 0
    )
    
    nu, ne, np = ad_dims(acc_cache)
    facepos = flow_disc.conn_pos
    nc = length(facepos) - 1
    cc = flow_disc.cellcell

    # @threads 
    for cell in 1:nc
        for cn in cc.pos[cell]:(cc.pos[cell+1]-1)
            c, n = cc.tbl[cn]
            @assert c == cell
            other = n
            index = cn
            find_and_place_density!(
                jac, other + target_offset, cell + source_offset, nu, ne, np, index, 
                density, context
                )
        end
    end
end


function declare_pattern(model, e::Conservation, ::Cells)
    df = e.flow_discretization
    hfd = Array(df.conn_data)
    n = number_of_units(model, e)
    # Fluxes
    I = map(x -> x.self, hfd)
    J = map(x -> x.other, hfd)
    # Diagonals
    D = [i for i in 1:n]

    I = vcat(I, D)
    J = vcat(J, D)

    return (I, J)
end

function declare_pattern(model, e::Conservation, ::Faces)
    df = e.flow_discretization
    cd = df.conn_data
    I = map(x -> x.self, cd)
    J = map(x -> x.face, cd)
    return (I, J)
end

#####################
# Updating Jacobian #
#####################


function update_linearized_system_equation!(
    nz, r, model, law::Conservation
    )
    
    acc = get_diagonal_cache(law)
    cell_flux = law.half_face_flux_cells
    cpos = law.flow_discretization.conn_pos

    fill_jac_flux_and_acc!(nz, r, model, acc, cell_flux, cpos)
end

function fill_jac_flux_and_acc!(nz, r, model, acc, cell_flux, cpos)
    """
    Fills the entries of the Jacobian.
    First loop: Adds the contribution from density terms to the loop
    Second loop: Adds contributions from density to r.
    """
    nc, ne, np = ad_dims(acc)
    nu, _ = ad_dims(cell_flux)
    centries = acc.entries
    fentries = cell_flux.entries
    cp = acc.jacobian_positions
    jp = cell_flux.jacobian_positions

        #! @threads removed for debugging, slows performance!
    # Fill accumulation + diag flux
    for cell = 1:nc
        for e in 1:ne
            diag_entry = get_entry(acc, cell, e, centries)

            @inbounds for i = cpos[cell]:(cpos[cell + 1] - 1)
                diag_entry -= get_entry(cell_flux, i, e, fentries)
            end
            
            @inbounds r[e, cell] = diag_entry.value
            for d = 1:np
                apos = get_jacobian_pos(acc, cell, e, d, cp)
                @inbounds nz[apos] = diag_entry.partials[d]
            end
        end
    end

    # Fill of-diagonal flux
    for i in 1:nu
        for e in 1:ne
            a = get_entry(cell_flux, i, e, fentries)
            for d in 1:np
                apos = get_jacobian_pos(cell_flux, i, e, d, jp)
                @inbounds nz[apos] = a.partials[d]
            end
        end
    end

end


function fill_jac_density!(nz, r, model, density)
    """
    Fills the entries of the Jacobian.
    Third loop: Adds the contribution from density terms to the loop
    Fourth loop: Adds contributions from density to r.
    """

    # Cells, equations, partials
    nud, ne, np = ad_dims(density)
    dentries = density.entries
    dp = density.jacobian_positions
    cctbl = model.domain.discretizations.charge_flow.cellcell.tbl

    # Fill density term
    for i = 1:nud
        for e in 1:ne
            entry = get_entry(density, i, e, dentries)

            for d = 1:np
                pos = get_jacobian_pos(density, i, e, d, dp)
                @inbounds nz[pos] -= entry.partials[d]
            end
        end
    end

    nc = number_of_cells(model.domain)
    # Add value from densities
    mf = model.domain.discretizations.charge_flow
    cc = mf.cellcell
    nc = number_of_cells(model.domain)
    for cn in cc.pos[1:end-1] # The diagonal elements
        for e in 1:ne
            c, n = cc.tbl[cn]
            @assert c == n
            entry = get_entry(density, cn, e, dentries)
            @inbounds r[e, c] -= entry.value
        end
    end

end


############################
# Standard implementations #
############################


@terv_secondary function update_as_secondary!(
    kGrad, sv::TPkGrad{Phi}, model::ECModel, param, Phi, Conductivity
    )
    mf = model.domain.discretizations.charge_flow
    conn_data = mf.conn_data
    @tullio kGrad[i] = half_face_two_point_kgrad(conn_data[i], Phi, Conductivity)
end

@terv_secondary function update_as_secondary!(
    kGrad, sv::TPkGrad{C}, model::ECModel, param, C, Diffusivity
    )
    mf = model.domain.discretizations.charge_flow
    conn_data = mf.conn_data
    @tullio kGrad[i] = half_face_two_point_kgrad(conn_data[i], C, Diffusivity)
end

@terv_secondary function update_as_secondary!(
    kGrad, sv::TPkGrad{T}, model::ECModel, param, T, ThermalConductivity
    )
    mf = model.domain.discretizations.charge_flow
    conn_data = mf.conn_data
    @tullio kGrad[i] = half_face_two_point_kgrad(conn_data[i], T, ThermalConductivity)
end


@terv_secondary function update_as_secondary!(
    acc, tv::MassAcc, model, param, C
    )
    V = get_flow_volume(model.domain.grid)
    @tullio acc[i] = C[i] * V[i]
end

@terv_secondary function update_as_secondary!(
    acc, tv::EnergyAcc, model, param, T
    )
    V = get_flow_volume(model.domain.grid)
    @tullio acc[i] = T[i] * V[i]
end

@terv_secondary function update_as_secondary!(
    acc, tv::ChargeAcc, model, param, Phi # only for the graph
    )
    @tullio acc[i] = 0 # Charge neutrality
end
