export plot_interactive, plot_multimodel_interactive
export plot_mesh, plot_mesh!
export plot_cell_data!, plot_cell_data
export plot_solve_breakdown
export plot_cumulative_solve, plot_cumulative_solve!


function plot_interactive(arg...; kwarg...)
    check_plotting_availability()
    plot_interactive_impl(arg...; kwarg...)
end

function plot_interactive_impl

end

function plot_multimodel_interactive(arg...; kwarg...)
    check_plotting_availability()
    plot_multimodel_interactive_impl(arg...; kwarg...)
end

function plot_multimodel_interactive_impl

end


function plot_mesh(arg...; kwarg...)
    check_plotting_availability()
    plot_mesh_impl(arg...; kwarg...)
end

function plot_mesh_impl

end

function plot_mesh!(arg...; kwarg...)
    check_plotting_availability()
    plot_mesh_impl!(arg...; kwarg...)
end

function plot_mesh_impl!

end


function plot_cell_data(arg...; kwarg...)
    check_plotting_availability()
    plot_cell_data_impl(arg...; kwarg...)
end

function plot_cell_data_impl

end

function plot_cell_data!(arg...; kwarg...)
    check_plotting_availability()
    plot_cell_data_impl!(arg...; kwarg...)
end

function plot_cell_data_impl!

end

function check_plotting_availability(; throw = true)
    ok = true
    try
        ok = check_plotting_availability_impl()
    catch e
        if throw
            if e isa MethodError
                error("Plotting is not available. You need to have a Makie backend available. For 3D plots, GLMakie is recommended. To fix: using Pkg; Pkg.add(\"GLMakie\") and then call using GLMakie to enable plotting.")
            else
                rethrow(e)
            end
        else
            ok = false
        end
    end
    return ok
end

function check_plotting_availability_impl

end

function plot_solve_breakdown

end

function plot_cumulative_solve

end

function plot_cumulative_solve!

end

function plot_linear_convergence

end

function plot_linear_convergence!

end