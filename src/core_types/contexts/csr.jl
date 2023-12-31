export ParallelCSRContext
"A context that uses a CSR sparse matrix format together with threads. Experimental."
struct ParallelCSRContext <: CPUJutulContext
    matrix_layout
    minbatch::Integer
    nthreads::Integer
    partitioner::JutulPartitioner
    function ParallelCSRContext(nthreads = Threads.nthreads(); partitioner = MetisPartitioner(), matrix_layout = EquationMajorLayout(), minbatch = minbatch(nothing))
        new(matrix_layout, minbatch, nthreads, partitioner)
    end
end

matrix_layout(c::ParallelCSRContext) = c.matrix_layout
function initialize_context!(context::ParallelCSRContext, domain, system, formulation)
    context
end

nthreads(ctx::ParallelCSRContext) = ctx.nthreads
minbatch(ctx::ParallelCSRContext) = ctx.minbatch

function build_sparse_matrix(context::ParallelCSRContext, I, J, V, n, m)
    return static_sparsity_sparse(I, J, V, n, m, nthreads = nthreads(context), minbatch = minbatch(context))
end
