
module SolverLaplace
    using Gridap
    using LinearAlgebra
    using GridapEmbedded
    using Parameters
    import Gridap: ∇

    # α(x) = x[1]^2 + x[2]^2
    α(x) = 1

    function man_sol(u_ex)
        ∇u_ex(x) = ∇(u_ex)(x)
        ∇Δu_ex(x) = ∇(Δ(u_ex))(x)
        f(x) = Δ(Δ(u_ex))(x)+ α(x)⋅u_ex(x)
        return u_ex, f, ∇u_ex, ∇Δu_ex
    end

    @with_kw struct Solution
        el2
        eh1
        eh_energy
        cond_number
        ndof
    end

    @enum CutFEMType CutFEM AgFEM
    @enum GeometryType circle flower

    function run(; type::CutFEMType=CutFEM, geometry::GeometryType=circle,
                 order, n, u_ex, dirname=nothing, L=1.11, δ=0.0, γ=10.0, γg1=5, γg2=0.01)

        # Mesh size
        h = L/n

        u_ex, f, ∇u_ex, ∇Δu_ex = man_sol(u_ex)

        # Background model (translated)
        θ_δ =  π/4
        r_δ = δ*Point(cos(θ_δ),sin(θ_δ))
        pmin = Point(-L, -L) + r_δ
        pmax = Point(L , L) + r_δ
        bgorigin = ( pmin + pmax )/2

        if geometry == circle
            R  = 1.0
            geo = disk(R)
        else
            r0 = 0.7
            r1 = 0.3
            function ls_flower(x)
                theta = atan(x[1], x[2])
                (x[1]^2 + x[2]^2)^0.5 - r0 - r1*cos(5.0*theta)
            end
            geo = AnalyticalGeometry(x-> ls_flower(x))
        end

        # Background model
        partition = (n,n)
        bgmodel = CartesianDiscreteModel(pmin, pmax, partition)


        println("Sim: order=$order, n=$n, bg (L,L)=($(round(L, digits=2)),$(round(L, digits=2))), bgorigin=($(round(bgorigin[1], digits=2)),$(round(bgorigin[2], digits=2)))")


        # Cut the background model
        cutgeo = cut(bgmodel, geo)
        cutgeo_facets = cut_facets(bgmodel,geo)

        # Set up interpolation mesh and function spaces
        Ω_act = Triangulation(cutgeo, ACTIVE)

        # Construct requeste CutFEM function spaces 
        Vstd = TestFESpace(Ω_act, ReferenceFE(lagrangian, Float64, order), conformity=:H1)

        if type == AgFEM
            strategy = AggregateAllCutCells()
            # treshold = 0.5
            # println("Aggreating all cells with treshold < $(treshold) ")
            # strategy = AggregateCutCellsByThreshold(treshold)
            aggregates = aggregate(strategy, cutgeo)
            # Prepare color for aggregate coloring
            colors = color_aggregates(aggregates, bgmodel)
            V = AgFEMSpace(Vstd, aggregates)
        else
            V = Vstd
        end

        U = TrialFESpace(V)

        # Set up integration meshes, measures and normals
        Ω_bg = Triangulation(bgmodel)
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

        # Set up normal vectors
        n_Γ = get_normal_vector(Γ)
        n_Λ = get_normal_vector(Λ)
        n_Fg = get_normal_vector(Fg)


        function mean_n(u,n)
            return 0.5*( u.plus⋅n.plus + u.minus⋅n.minus )
        end

        function mean_nn(u,n)
            return 0.5*( n.plus⋅ ∇∇(u).plus⋅ n.plus + n.minus ⋅ ∇∇(u).minus ⋅ n.minus )
        end

        function jump_nn(u,n)
            return ( n.plus⋅ ∇∇(u).plus⋅ n.plus - n.minus ⋅ ∇∇(u).minus ⋅ n.minus )
        end

        # Inner facets
        # a(u,v) =( ∫( ∇∇(v)⊙∇∇(u) + α⋅(v⊙u) )dΩ
        #          + ∫(-mean_nn(v,n_Λ)⊙jump(∇(u)⋅n_Λ) - mean_nn(u,n_Λ)⊙jump(∇(v)⋅n_Λ))dΛ
        #          + ∫(-( n_Γ ⋅ ∇∇(v)⋅ n_Γ )⊙∇(u)⋅n_Γ - ( n_Γ ⋅ ∇∇(u)⋅ n_Γ )⊙∇(v)⋅n_Γ)dΓ
        #          + ∫((γ/h)⋅jump(∇(u)⋅n_Λ)⊙jump(∇(v)⋅n_Λ))dΛ + ∫((γ/h)⋅ ∇(u)⊙n_Γ⋅∇(v)⊙n_Γ )dΓ
        #         )

        a_CIP(u,v) = ∫(u*v)*dΩ + ( ∫(Δ(v)⊙Δ(u))dΩ
                    + ∫(-mean(Δ(v))⊙jump(∇(u)⋅n_Λ) - mean(Δ(u))⊙jump(∇(v)⋅n_Λ) + (γ/h)⋅jump(∇(u)⋅n_Λ)⊙jump(∇(v)⋅n_Λ))dΛ
                    + ∫(-Δ(v)⊙∇(u)⋅n_Γ - Δ(u)⊙∇(v)⋅n_Γ + (γ/h)⋅ ∇(u)⊙n_Γ⋅∇(v)⊙n_Γ )dΓ
                )

        # Define linear form
        # Notation: g_1 = ∇u_ex⋅n_Γ, g_2 = ∇Δu_ex⋅n_Γ
        g_1 = ∇u_ex⋅n_Γ
        g_2 = ∇Δu_ex⋅n_Γ
        l(v) = (∫( f*v ) * dΩ
                +  ∫(-(g_2⋅v))dΓ
                + ∫(g_1⊙(-Δ(v) + (γ/h)*∇(v)⋅n_Γ)) * dΓ
               )

        g(u,v) = h^(-2)*( ∫( (γg1*h)*jump(n_Fg⋅∇(u))*jump(n_Fg⋅∇(v)) ) * dFg +
                         ∫( (γg2*h^3)*jump_nn(u,n_Fg)*jump_nn(v,n_Fg) ) * dFg)
        
       
        # Define final discrete bilinear form
        A(u,v) = type == CutFEM ? a_CIP(u,v) + g(u,v) : a_CIP(u,v) 

        # Assemble of system
        op = AffineFEOperator(A, l, U, V)
        uh = solve(op)
        A_mat =  get_matrix(op)
        ndof = size(A_mat)[1]
        cond_number = ( 1/sqrt(ndof) )*cond(A_mat,Inf)

        u_inter = interpolate(u_ex, V) # remove?
        e = u_ex - uh
        el2 = sqrt(sum( ∫(e*e)dΩ ))

        # TODO: Add α into ∫(e⊙e)*dΩ
        eh_energy = sqrt(sum( ∫(e⊙e)dΩ + ∫( ∇∇(e)⊙∇∇(e) )dΩ
                      + ( γ/h ) * ∫(jump(∇(e)⋅n_Λ) ⊙ jump(∇(e)⋅n_Λ))dΛ
                      + ( h/γ ) * ∫(mean_nn(e,n_Λ) ⊙ mean_nn(e,n_Λ))dΛ
                      + ( γ/h ) * ∫((∇(e)⋅n_Γ) ⊙ (∇(e)⋅n_Γ))dΓ
                      + ( h/γ ) * ∫(( n_Γ ⋅ ∇∇(e)⋅ n_Γ ) ⊙ ( n_Γ ⋅ ∇∇(e)⋅ n_Γ ))dΓ
                     ))

        eh1 = sqrt(sum( ∫( e⊙e + ∇(e)⊙∇(e) )dΩ ))

        if dirname != nothing
            vtkdirname =dirname*"/order_$(order)_n_$n"
            mkpath(vtkdirname)
            # Write out models and computational domains for inspection
            writevtk(bgmodel,   vtkdirname*"/bgmodel")
            writevtk(Ω,         vtkdirname*"/Omega")
            writevtk(Ω_act,     vtkdirname*"/Omega_act")
            writevtk(Λ,         vtkdirname*"/Lambda")
            writevtk(Γ,         vtkdirname*"/Gamma")
            writevtk(Fg,        vtkdirname*"/Fg")
            writevtk(Λ,         vtkdirname*"/jumps",           cellfields=["jump_u"=>jump(uh)])
            writevtk(Ω,         vtkdirname*"/sol",             cellfields=["e"=>e, "uh"=>uh, "u"=>u_ex])
            writevtk(Ω_act,         vtkdirname*"/sol_act",             cellfields=["e"=>e, "uh"=>uh, "u"=>u_ex])
            if type == AgFEM
                writevtk(Ω_bg,      vtkdirname*"/aggs_on_bg_mesh", celldata=["aggregate"=>aggregates, "color"=>colors])
            end
        end

        sol = Solution( el2=el2, eh1=eh1, eh_energy=eh_energy,
                        cond_number=cond_number, ndof=ndof)
        return sol
    end

end # module

