##
using Gridap
using Gridap.Algebra
using GridapEmbedded
using Plots
using DataFrames
using CSV
using YAML
using LaTeXStrings

function main(;domain="flower")

    ## Cahn-hilliard
    ε = 1/30
    # ε = 1
    # Gibb's potential
    f(u) = mean(u)*(1 - mean(u)*mean(u))
    # f(u) = u*(1-u^2)
    # f(u) = u

    u_ex(x, t::Real) = cos(x[1])*cos(x[2])*exp(-(4*ε^2 + 2)*t)
    u_ex(t) = x -> u_ex(x,t)
    # f_ex(x, t::Real) = 0

    ##
    L=2.70
    n = 2^7
    h = 2*L/n
    it = 500
    γ = 20
    τ = ε^2/30
    γg1 = 10
    γg2 = 0.5

    pmin = Point(-L/2, -L/2)
    pmax = Point(L/2, L/2)
    partition = (n,n)
    bgmodel = CartesianDiscreteModel(pmin, pmax, partition)


    maindir = "figures/physical_CH_$domain"
    if isdir(maindir)
        rm(maindir; recursive=true)
        mkpath(maindir)
    end

    graphicsdir = maindir*"/graphics"
    mkpath(graphicsdir)


    # Implicit geometry
    if domain=="circle"
        R  = 1.0
        geo = disk(R)
    elseif domain=="flower"
        function ls_flower(x)
            r0, r1 = L*0.3, L*0.1
            theta = atan(x[1], x[2])
            r0 + r1*cos(5.0*theta) -(x[1]^2 + x[2]^2)^0.5
        end
        # using ! operator to define the interioir
        geo = !AnalyticalGeometry(x-> ls_flower(x))
    end


    # Cut the background model
    cutgeo = cut(bgmodel, geo)
    cutgeo_facets = cut_facets(bgmodel,geo)

    # Set up interpolation mesh and function spaces
    Ω_act = Triangulation(cutgeo, ACTIVE)
    Ω = Triangulation(cutgeo, PHYSICAL)
    Ω_bg = Triangulation(bgmodel)
    writevtk(Ω_bg,   graphicsdir*"/Omega_bg")
    writevtk(Ω,         graphicsdir*"/Omega")
    writevtk(Ω_act,     graphicsdir*"/Omega_act")

    ## Function spaces
    order = 2
    # Construct function spaces
    V = TestFESpace(Ω_act, ReferenceFE(lagrangian, Float64, order), conformity=:H1)
    U = TrialFESpace(V)


    # Set up integration meshes, measures and normals
    Ω = Triangulation(cutgeo, PHYSICAL)
    Γ = EmbeddedBoundary(cutgeo)
    Λ = SkeletonTriangulation(cutgeo_facets)
    Fg = GhostSkeleton(cutgeo)

    # Set up integration measures
    degree = 2*order
    dΩ   = Measure(Ω, degree)
    dΓ   = Measure(Γ, degree)
    dΛ   = Measure(Λ, degree) # F_int
    dFg  = Measure(Fg, degree)

    n_Λ = get_normal_vector(Λ)
    n_Γ = get_normal_vector(Γ)

    # Set up normal vectors
    n_Γ = get_normal_vector(Γ)
    n_Λ = get_normal_vector(Λ)
    n_Fg = get_normal_vector(Fg)

    function jump_nn(u,n)
        return ( n.plus⋅ ∇∇(u).plus⋅ n.plus - n.minus ⋅ ∇∇(u).minus ⋅ n.minus )
    end

    a_CIP(u,v) = ( ∫(Δ(v)⊙Δ(u))dΩ
                  + ∫(-mean(Δ(v))⊙jump(∇(u)⋅n_Λ) - mean(Δ(u))⊙jump(∇(v)⋅n_Λ) + (γ/h)⋅jump(∇(u)⋅n_Λ)⊙jump(∇(v)⋅n_Λ))dΛ
                  + ∫(-Δ(v)⊙∇(u)⋅n_Γ - Δ(u)⊙∇(v)⋅n_Γ + (γ/h)⋅ ∇(u)⊙n_Γ⋅∇(v)⊙n_Γ )dΓ
                 )

    g(u,v) = h^(-2)*( ∫( (γg1*h)*jump(n_Fg⋅∇(u))*jump(n_Fg⋅∇(v)) ) * dFg +
                     ∫( (γg2*h^3)*jump_nn(u,n_Fg)*jump_nn(v,n_Fg) ) * dFg)

    A_h(u,v) = a_CIP(u,v) + g(u,v)
    lhs(u,v) = ∫(u*v)*dΩ + τ*ε*A_h(u,v)

    c_h(u,v) = ( ∫(f(u)*Δ(v))*dΩ - ∫(f(mean(u))*jump(∇(v)⋅n_Λ))*dΛ - ∫(f(u)*∇(v)⋅n_Γ )*dΓ)
    rhs(u, v) =  ∫(u*v)*dΩ + ( τ/ε) *c_h(u,v)
    rhs(u) = v -> rhs(u,v)

    ## time loop
    t0 = 0.0
    T = it*τ
    Nt_max = convert(Int64, ceil((T - t0)/τ))
    Nt = 0
    t = t0

    # Maximal number of Picard iterations
    kmax = 1

    # Initial data
    u_dof_vals = (rand(Float64, num_free_dofs(U)) .-0.5)*2.0
    # uh = interpolate_everywhere(u_ex(0),U)
    u0 = FEFunction(U, deepcopy(u_dof_vals))
    uh = FEFunction(U, u_dof_vals)
    u0_L1 = sum( ∫(u0)dΩ )
    pvd = Dict()
    pvd[t] = createvtk(Ω, graphicsdir*"/sol_$t"*".vtu",cellfields=["uh"=>uh, "u_ex"=>u_ex(t)])

    # Adding initial plotting values
    e_L1_ts = Float64[]
    Es = Float64[]
    ts = Float64[]
    push!(ts, t)
    E = sum( ∫((ε/2)*( ∇(uh)⋅∇(uh) ) + (1/ε)*(1/4)*((uh*uh - 1)*(uh*uh - 1))  )dΩ)
    e_L1 = sum( ∫( (u0 - uh ) )dΩ)
    push!(Es, E)
    push!( e_L1_ts, e_L1/u0_L1)

    println("========================================")
    println("Solving Cahn-Hilliard with t0 = $t0, T = $T and time step τ = $τ with Nt_max = $Nt_max timesteps")
    println("========================================")

    ## Set up linear algebra system
    A = assemble_matrix(lhs, U, V)
    lu = LUSolver()
    cache = nothing

    # Time loop
    println("----------------------------------------")
    println("Solving Cahn-Hilliard for step $(Nt_max), n = $n, τ = $τ")
    while t < T
        Nt += 1
        t += τ
        k = 0
        println("$(Nt)/$(Nt_max)")
        while k < kmax
            k += 1
            b = assemble_vector(rhs(uh), V)
            op = AffineOperator(A, b)
            cache = solve!(u_dof_vals, lu, op, cache, isnothing(cache))
            uh = FEFunction(U, u_dof_vals)
        end

        # Adding initial plotting values
        push!(ts, t)
        E = sum( ∫(( ∇(uh)⋅∇(uh) ) + (1/4)*((uh*uh - 1)*(uh*uh - 1))  )dΩ)
        e_L1 = sum( ∫( (u0 - uh ) )dΩ)
        push!(Es, E)
        push!( e_L1_ts, e_L1/u0_L1)
        pvd[t] = createvtk(Ω, graphicsdir*"/sol_$t"*".vtu",cellfields=["uh"=>uh, "u_ex"=>u_ex(t)])
    end

    # Construct pvd file
    createpvd(graphicsdir*"/sol") do pvd_file
        for (t, vtk) in pvd
            pvd_file[t] = vtk
        end
    end

    # Save results
    df = DataFrame(ts=ts, Es=Es, e_L1_ts=e_L1_ts)
    CSV.write(maindir*"/sol.csv", df, delim=',')

    # Normalize data
    p1 = plot(ts, e_L1_ts, label = L"$ e_{L^1(\Omega)} $", xlabel="t")

    p2 = plot(ts[2:end], Es[2:end], xscale=:log10, yscale=:log10, label = L"$E(u)$", xlabel="t")
    savefig(p1,maindir*"/mass_cons.png" )
    savefig(p2,maindir*"/energy.png" )

    parameters = Dict(
        "domain" => domain,
        "gamma" => γ,
        "gamma1" => γg1,
        "gamma2" => γg2,
        "epsilon" => ε,
        "tau" => "epsilon^2/10",
        "L"=>2.70,
        "n"=> 2^7,
        "it"=> it
    )

    YAML.write_file(maindir*"/parameters.yml", parameters)

end
main(domain="circle")
main(domain="flower")