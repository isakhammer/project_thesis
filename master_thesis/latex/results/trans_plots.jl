using Plots
pgfplotsx()
default_size = (500, 300)

using CSV
using DataFrames
using LaTeXStrings
using Printf


struct Simulation
    param
    data
    dirname
    color
end

function translation_plot(sims::Vector{Simulation},dirname)

    # Plot for condition numbers
    p1 = plot(legend=:outertopright, size=default_size, legendtitle=L"(\gamma, \gamma_1, \gamma_2)", yscale=:log10, minorgrid=false)
    # Plot for L2 error, H1 error, and Energy error
    p2 = plot(legend=:outertopright, size=default_size,legendtitle=L"(\gamma, \gamma_1, \gamma_2)", yscale=:log10, minorgrid=false)

    for sim in sims
        γ, γg1, γg2 = sim.param
        label_text = L"(%$(γ), %$(γg1), %$( γg2)) "

        Plots.plot!(p1, sim.data.deltas, sim.data.cond_numbers, label=label_text, color=sim.color)
        Plots.plot!(p2, sim.data.deltas, sim.data.el2s, label=label_text, color=sim.color, linestyle=:solid)
        Plots.plot!(p2, sim.data.deltas, sim.data.eh1s, label=nothing, color=sim.color, linestyle=:dash)
        Plots.plot!(p2, sim.data.deltas, sim.data.ehs_energy, label=nothing, color=sim.color, linestyle=:dot)

    end
    file1 = dirname*"/translation-cond.tex"
    file2 = dirname*"/translation-error.tex"
    println("Saved in $file1 and $file2")
    savefig(p1,file1)
    savefig(p2,file2)
end



println("Hessian Translation Test")
dirname = "translation-test/hessian-n-16-it-500-L-3.11"

# No penalty simulation
path1 = "$dirname/no-penalty-test-gamma-20.0-gamma1-0.0-gamma2-0.0.csv"
param1 = (20,0,0)
data1 = CSV.read(path1, DataFrame)
sim1=Simulation(param1, data1, dirname, "blue")

# Penalty simulation
path2 = "$dirname/no-penalty-test-gamma-20.0-gamma1-10.0-gamma2-0.1.csv"
param2 = (20,10,0.1)
data2 = CSV.read(path2, DataFrame)
sim2=Simulation(param2, data2, dirname, "red")

# Generate plots
sims = [sim1, sim2]
translation_plot(sims, dirname)






