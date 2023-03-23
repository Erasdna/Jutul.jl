module JutulMakieExt

using Jutul, Makie
    function Jutul.check_plotting_availability_impl()
        return true
    end

    include("mesh_plots.jl")
    include("interactive_3d.jl")
    include("performance.jl")
end
