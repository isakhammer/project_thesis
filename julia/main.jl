include("biharmonic_equation.jl")
using Test
using Plots
import CairoMakie
using LaTeXStrings
using Latexify
using PrettyTables

function generate_figures(hs, hs_str, el2s, eh1s, γ::Integer, order::Integer, dirname::String)
    filename = dirname*"/convergence_d_"*string(order)*"_gamma_"*string(γ)

    function slope(hs,errors)
      x = log10.(hs)
      y = log10.(errors)
      linreg = hcat(fill!(similar(x), 1), x) \ y
      linreg[2]
    end

    function generate_plot(hs,el2s, eh1s )
        p_L2 = slope(hs,el2s)
        p_H1 = slope(hs,eh1s)

        fig = CairoMakie.Figure()
        ax = CairoMakie.Axis(fig[1, 1], yscale = log10, xscale= log2,
                             yminorticksvisible = true, yminorgridvisible = true, yminorticks = CairoMakie.IntervalsBetween(8),
                             xlabel = "h", ylabel = "error norms")

        CairoMakie.lines!(hs, el2s, label="L2 norm", linewidth=2)
        CairoMakie.lines!(hs, eh1s, label="H1 norm", linewidth=2)
        CairoMakie.scatter!(hs, el2s)
        CairoMakie.scatter!(hs, eh1s)
        file = filename*".png"
        CairoMakie.Legend(fig[1,2], ax, framevisible = true)
        CairoMakie.save(file,fig)
    end

    function generate_table(hs_str::Vector, eh1::Vector{Float64}, el2::Vector{Float64})
        lgl2 = log2.(el2[2:end]./el2[1:end-1])
        lgh1 = log2.(eh1[2:end]./eh1[1:end-1])
        lgl2 =  [nothing; lgl2]
        lgh1 =  [nothing; lgh1]

        data = hcat(hs_str, el2, eh1, lgl2, lgh1)
        header = ["h", L"$L_2$", L"$H^1$", L"$log_2(e^{2h}/e^{h}}) $", L"$log_2(\mu^{2h}/\mu^{h}) $"]
        pretty_table(data, header=header, formatters = ( ft_printf("%.3E"), ft_nonothing )) # remove

        open(filename*".tex", "w") do io
            pretty_table(io, data, header=header, backend=Val(:latex ), formatters = ( ft_printf("%.3E"), ft_nonothing ))
        end
    end

    println("Generating plot")
    generate_plot(hs, el2s, eh1s)

    println("Generating table")
    generate_table(hs_str, el2s, eh1s)
end


function makedir(dirname)
    if (isdir(dirname))
        rm(dirname, recursive=true)
    end
    mkdir(dirname)
end

function run_examples(dirname)
    exampledir = dirname*"/example"
    makedir(exampledir)
    ndir(n) = exampledir*"/n_"*string(n)
    ns = [100]
    order=2

    L = 1
    u(x) = cos(( 2π/L )*x[1])*cos(( 2π/L )*x[2])
    for n in ns
        ss = BiharmonicEquation.generate_square_spaces(n=n, L=L, order=order)
        sol = BiharmonicEquation.run_CP_method(ss=ss,u=u)
        BiharmonicEquation.generate_vtk(ss=ss,sol=sol,dirname=ndir(n))
        @test sol.el2 < 10^-1
    end
end


function convergence_analysis(;dirname, orders = [2,3,4], γs = [5, 25, 60], ns = [2^3,2^4,2^5,2^6,2^7], L=1, u::Function, method="test")

    hs = 1 .// ns # does render nice in latex table if L=2π
    hs_str =  latexify.(hs)

    @test length( orders ) == length(γs)
    @test length( ns ) == length(hs)

    for i in 1:length(orders)
        order = orders[i]
        γ = γs[i]

        el2s = Float64[]
        eh1s = Float64[]
        println("Run convergence tests: order = "*string(order), " Method: " , method)

        for n in ns
            ss = BiharmonicEquation.generate_square_spaces(n=n,L=L, γ=γ, order=order)
            sol = BiharmonicEquation.run_CP_method(ss=ss, u=u, method=method)
            push!(el2s, sol.el2)
            push!(eh1s, sol.eh1)
            # push!(hs,   ss.h)
        end

        println("Generate figures")
        generate_figures(hs, hs_str, el2s, eh1s, γ, order, dirname)
    end

end

function run_gamma_analysis(;dirname, orders = [2,3,4], γs = [5, 10, 20, 25, 50, 70], ns = [2^3,2^4,2^5,2^6,2^7], L=1, method="test")

    m,r = 1,1
    L = 1
    u(x) = cos(m*( 2π/L )*x[1])*cos(r*( 2π/L )*x[2])

    hs = 1 .// ns
    for order in orders
        fig = Figure()
        ax = Axis(fig[1, 1], yscale = log10, xscale= log2, yminorticksvisible = true, yminorgridvisible = true, yminorticks = IntervalsBetween(8))
        for i in 1:length(γs)
            γ = γs[i]
            el2s = Float64[]
            eh1s = Float64[]
            println("Run gamma analysis: gamma = "*string(γ), " Method: " , method)

            for n in ns
                ss = BiharmonicEquation.generate_square_spaces(n=n,L=L, γ=γ, order=order)
                sol = BiharmonicEquation.run_CP_method(ss=ss, u=u, method=method)
                push!(el2s, sol.el2)
                push!(eh1s, sol.eh1)
                # push!(hs,   ss.h)
            end

            lines!(hs, el2s, label=string(γ), linewidth=2)
        end

        Legend(fig[1,2], ax,L"$\gamma$ values", framevisible = true)
        save(dirname*"/gamma_analysis_order"*string(order)*".png",fig)
    end
end


function run_convergence(figdir)

    # folder = "biharmonic_equation_results"


    function analysis(;L,m,r)
        u(x) = cos(m*( 2π/L )*x[1])*cos(r*( 2π/L )*x[2])
        conv_dir = figdir*"/L_"*string(L)*"_m_"*string(m)*"_r_"*string(r)
        makedir(conv_dir)
        println("making ", conv_dir)
        convergence_analysis(dirname=conv_dir, orders=[2,3,4], γs=[5,25,30], ns= [2^3,2^4,2^5,2^6,2^7], L=L, u=u)
    end

    analysis(L=2π, m=1, r=1)
    analysis(L=1, m=2, r=3)
    analysis(L=0.01, m=2, r=3)

end

function main()
    println("Generating figures")
    figdir = "figures"
    makedir(figdir)

    run_examples(figdir)
    run_convergence(figdir)
    run_gamma_analysis(dirname=figdir)

end

main()
