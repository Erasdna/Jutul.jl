export LinearPartitioner, MetisPartitioner
struct LinearPartitioner <: JutulPartitioner

end

function partition(::LinearPartitioner, A, m)
    n, l = size(A)
    @assert n == l
    return partition_linear(m, n)
end

function partition_linear(m, n)
    partition = zeros(Int64, n);
    for i in eachindex(partition)
        partition[i] = ceil(i / (n/m))
    end
    return partition
end

function partition_to_lookup(partition::AbstractVector, N = maximum(partition))
    return tuple(map(i -> findall(isequal(i), partition), 1:N)...)
end

function generate_lookup(partitioner, A, n)
    p = partition(partitioner, A, n)
    return partition_to_lookup(p, n)
end

struct MetisPartitioner <: JutulPartitioner
    algorithm::Symbol
    MetisPartitioner(m = :KWAY) = new(m)
end

function partition(mp::MetisPartitioner, A::AbstractSparseMatrix, m; kwarg...)
    return partition(mp, generate_metis_graph(A), m; kwarg...)
end

function partition(mp::MetisPartitioner, g, m; alg = mp.algorithm, kwarg...)
    return Metis.partition(g, m; alg = alg, kwarg...)
end

metis_strength(F) = F

function metis_strength(F::AbstractMatrix)
    s = zero(eltype(F))
    n, m = size(F)
    for i = 1:min(n, m)
        s += F[i, i]
    end
    return s
end

function generate_metis_graph(A::SparseMatrixCSC)
    n, m = size(A)
    @assert n == m
    i, j, v = findnz(A)
    V = map(metis_strength, v)
    V = metis_integer_weights(V)
    for i in eachindex(V)
        V[i] = clamp(V[i], 1, typemax(Int32))
    end
    I = vcat(i, j)
    J = vcat(j, i)
    V = vcat(V, V)
    M = sparse(I, J, V, n, n)
    return Metis.graph(M, check_hermitian = false, weights = true)
end

function metis_integer_weights(x::AbstractVector{<:Integer})
    return x
end

function metis_integer_weights(x::AbstractVector{<:AbstractFloat})
    mv = mean(x)*0.1;
    @. x = Int64(ceil(x / mv))
    return x
end

generate_metis_graph(A::StaticSparsityMatrixCSR) = generate_metis_graph(A.At)

function compress_partition(p::AbstractVector)
    up = sort!(unique(p))
    p_renum = copy(p)
    for i in eachindex(p)
        p_renum[i] = searchsortedfirst(up, p[i])
    end
    return p_renum
end

"""
    partition(N::AbstractMatrix, num_coarse, weights = ones(size(N, 2)); partitioner = MetisPartitioner(), groups = nothing, n = maximum(N))

Partition based on neighborship (with optional groups kept contigious after partitioning)
"""
function partition(N::AbstractMatrix, num_coarse, weights = ones(size(N, 2)); partitioner = MetisPartitioner(), groups = nothing, n = maximum(N))
    @assert size(N, 1) == 2
    @assert size(N, 2) == length(weights)
    weights::AbstractVector
    weights = metis_integer_weights(weights)
    num_coarse::Integer

    has_groups = !isnothing(groups)
    if has_groups
        # Some entries are clustered together and should not be divided. We
        # create a subgraph using a partition, and extend back afterwards.
        part = collect(1:n)
        for (i, group) in enumerate(groups)
            for g in group
                part[g] = n + i
            end
        end
        part = compress_partition(part)
        N = part[N]
        n_inner = maximum(part)
    else
        n_inner = n
    end
    @assert num_coarse <= n_inner
    i = vec(N[1, :])
    j = vec(N[2, :])
    I = vcat(i, j)
    J = vcat(j, i)
    V = vcat(weights, weights)
    M = sparse(I, J, V, n_inner, n_inner)

    g = generate_metis_graph(M)
    p = partition(partitioner, g, num_coarse)
    if has_groups
        p = p[part]
    end
    return Int64.(p)
end
