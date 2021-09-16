struct CartesianMesh <: AbstractTervMesh
    dims   # Tuple of dimensions (x, y, [z])
    deltas # Either a tuple of scalars (uniform grid) or a tuple of vectors (non-uniform grid)
    origin # Coordinate of lower left corner
    function CartesianMesh(dims::Tuple, deltas_or_size::Union{Nothing, Tuple} = nothing; origin = nothing)
        dim = length(dims)
        if isnothing(deltas_or_size)
            deltas_or_size = Tuple(ones(dim))
        end
        if isnothing(origin)
            origin = zeros(dim)
        end
        function generate_deltas(deltas_or_size)
            first = deltas_or_size[1]
            deltas = Vector(undef, dim)
            if isa(first, AbstractFloat)
                # Deltas are actually size of domain in each direction
                for i = 1:dim
                    deltas[i] = deltas_or_size[i]/dims[i]
                end
                δ = Tuple(deltas)
            else
                # Deltas are the actual cell widths
                first::AbstractVector
                for i = 1:dim
                    @assert length(deltas_or_size[i]) == dims[i]
                end
                δ = deltas_or_size
            end
            return δ
        end
        @assert length(deltas_or_size) == dim
        deltas = generate_deltas(deltas_or_size)
        return new(dims, deltas, origin)
    end
end

dim(t::CartesianMesh) = length(t.dims)

function tpfv_geometry(g::CartesianMesh)
    Δ = g.deltas
    d = dim(g)

    nx, ny, nz = get_3d_dims(g)

    cell_index(x, y, z) = (z-1)*nx*ny + (y-1)*nx + x
    get_deltas(x, y, z) = (get_delta(Δ, x, 1), get_delta(Δ, y, 2), get_delta(Δ, z, 3))
    # Cell data first - volumes and centroids
    nc = nx*ny*nz
    if isa(Δ[1], AbstractFloat)
        # Uniform mesh
        V = repeat([prod(Δ)], nc)

        cell_centroids = zeros(d, nc)
        for x in 1:nx
            for y in 1:ny
                for z = 1:nz
                    for i in 1:d
                        pos = (x, y, z)
                        c = cell_index(pos...)
                        δ = Δ[i]
                        cell_centroids[i, c] = (pos[i] - 0.5)*δ + g.origin[i]
                    end
                end
            end
        end
    else
        error("Variable strides not implemented yet")
    end

    # Then face data:
    nf = (nx-1)*ny*nz + (ny-1)*nx*nz + (nz-1)*ny*nx
    N = Matrix{Int}(undef, 2, nf)
    face_areas = Vector{Float64}(undef, nf)
    face_centroids = Matrix{Float64}(undef, d, nf)
    face_normals = zeros(d, nf)

    pos = 1
    for y in 1:ny
        for z = 1:nz
            for x in 1:(nx-1)
                index = cell_index(x, y, z)
                N[1, pos] = index
                N[2, pos] = cell_index(x+1, y, z)

                Δx, Δy, Δz  = get_deltas(x, y, z)

                face_areas[pos] = Δy*Δz
                face_normals[1, pos] = 1.0

                face_centroids[:, pos] = cell_centroids[:, index]
                Δx_next = get_delta(Δ, x+1, 1)
                # Offset by the grid size
                @. face_centroids[1, :] += (Δx_next + Δx)/4.0
                pos += 1
            end
        end
    end
    for y in 1:(ny-1)
        for x in 1:nx
            for z = 1:nz
                index = cell_index(x, y, z)
                N[1, pos] = index
                N[2, pos] = cell_index(x, y+1, z)

                Δx, Δy, Δz  = get_deltas(x, y, z)

                face_areas[pos] = Δx*Δz
                face_normals[2, pos] = 1.0

                face_centroids[:, pos] = cell_centroids[:, index]
                Δy_next = get_delta(Δ, y+1, 2)
                # Offset by the grid size
                @. face_centroids[2, :] += (Δy_next + Δy)/4.0
                pos += 1
            end
        end
    end
    for z = 1:(nz-1)
        for y in 1:ny
            for x in 1:nx
                index = cell_index(x, y, z)
                N[1, pos] = index
                N[2, pos] = cell_index(x, y, z+1)

                Δx, Δy, Δz  = get_deltas(x, y, z)

                face_areas[pos] = Δx*Δy
                face_normals[3, pos] = 1.0

                face_centroids[:, pos] = cell_centroids[:, index]
                Δz_next = get_delta(Δ, z+1, 3)
                # Offset by the grid size
                @. face_centroids[3, :] += (Δz_next + Δz)/4.0
                pos += 1
            end
        end
    end

    return TwoPointFiniteVolumeGeometry(N, face_areas, V, face_normals, cell_centroids, face_centroids)
end

function get_3d_dims(g)
    d = length(g.dims)
    if d == 1
        nx = g.dims[1]
        ny = nz = 1
    elseif d == 2
        nx, ny = g.dims
        nz = 1
    else
        @assert d == 3
        nx, ny, nz = g.dims
    end
    return (nx, ny, nz)
end


function get_delta(Δ, index, d)
    if length(Δ) >= d
        δ = Δ[d]
        if isa(δ, AbstractFloat)
            v = δ
        else
            v = δ[index]
        end
    else
        v = 1.0
    end
    return v
end