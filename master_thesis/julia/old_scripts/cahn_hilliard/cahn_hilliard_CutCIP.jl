
using Test
using Gridap
using Plots
using Dates
using LaTeXStrings
using Latexify
using PrettyTables

module CH
    using Gridap
    using LinearAlgebra
    using PROPACK
    using GridapEmbedded
    using GridapGmsh
    using Parameters
    import Gridap: ∇

    function man_sol(u_ex)
        f(t) = x ->  ∂t(u_ex)(x,t) + Δ(Δ(u_ex(t)))(x)
        ∇u_ex(t) = x ->  ∇(u_ex(t))(x)
        ∇Δu_ex(t) = x ->  ∇(Δ(u_ex(t)))(x)
        return u_ex, f, ∇u_ex, ∇Δu_ex
    end

    @with_kw struct Solution
        el2s_L2
        eh1s_L2
        ehs_energy_L2
        el2s_inf
        eh1s_inf
        ehs_energy_inf
    end


    function run(;n::Number, dt::Number,
            vtkdirname::String, ode_method::String="BE", u_ex::Union{Function, Nothing}=nothing)

        order=2
        u_ex, f, ∇u_ex, ∇Δu_ex = man_sol(u_ex)

        # Background model
        L = 2.5
        domain = (-L*0.5, L*0.5, -L*0.5, L*0.5)
        pmin = Point(-L*0.5, -L*0.5)
        pmax = Point(L*0.5, L*0.5)
        partition = (n,n)
        bgmodel = CartesianDiscreteModel(pmin, pmax, partition)

        # Implicit geometry
        R  = 1.0
        geo = disk(R)

        # Cut the background model
        cutgeo = cut(bgmodel, geo)
        cutgeo_facets = cut_facets(bgmodel,geo)

        # Set up interpolation mesh and function spaces
        Ω_act = Triangulation(cutgeo, ACTIVE)

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

        # Set up normal vectors
        n_Γ = get_normal_vector(Γ)
        n_Λ = get_normal_vector(Λ)
        n_Fg = get_normal_vector(Fg)

        # Define weak form
        h = L/n

        function mean_n(u,n)
            return 0.5*( u.plus⋅n.plus + u.minus⋅n.minus )
        end

        function mean_nn(u,n)
            return 0.5*( n.plus⋅ ∇∇(u).plus⋅ n.plus + n.minus ⋅ ∇∇(u).minus ⋅ n.minus )
        end

        function jump_nn(u,n)
            return ( n.plus⋅ ∇∇(u).plus⋅ n.plus - n.minus ⋅ ∇∇(u).minus ⋅ n.minus )
        end

        # Define weak form
        γ = 20

        # Ghost penalty parameter
        γg1 = 10
        γg2 = 0.01

        g_1(t) = ∇u_ex(t)⋅n_Γ
        g_2(t) = ∇Δu_ex(t)⋅n_Γ

        # Hessian formulation
        # a_H(t,u,v) =( ∫( ∇∇(v)⊙∇∇(u) )dΩ
        #          + ∫(-mean_nn(v,n_Λ)⊙jump(∇(u)⋅n_Λ) - mean_nn(u,n_Λ)⊙jump(∇(v)⋅n_Λ))dΛ
        #          + ∫(-( n_Γ ⋅ ∇∇(v)⋅ n_Γ )⊙∇(u)⋅n_Γ - ( n_Γ ⋅ ∇∇(u)⋅ n_Γ )⊙∇(v)⋅n_Γ)dΓ
        #          + ∫((γ/h)⋅jump(∇(u)⋅n_Λ)⊙jump(∇(v)⋅n_Λ))dΛ + ∫((γ/h)⋅ ∇(u)⊙n_Γ⋅∇(v)⊙n_Γ )dΓ
        #         )

        # b_H(t,v) = (∫( f(t)*v ) * dΩ
        #           +  ∫(-(g_2(t)⋅v))dΓ
        #           + ∫(g_1(t)⊙(-(n_Γ⋅∇∇(v)⋅n_Γ) + (γ/h)*∇(v)⋅n_Γ)) * dΓ
        #        )

        # # Laplace formulation
        a_L(t,u,v) =  ( ∫(Δ(v)⊙Δ(u))dΩ
                    + ∫(-mean(Δ(v))⊙jump(∇(u)⋅n_Λ) - mean(Δ(u))⊙jump(∇(v)⋅n_Λ) + (γ/h)⋅jump(∇(u)⋅n_Λ)⊙jump(∇(v)⋅n_Λ))dΛ
                    + ∫(-Δ(v)⊙∇(u)⋅n_Γ - Δ(u)⊙∇(v)⋅n_Γ + (γ/h)⋅ ∇(u)⊙n_Γ⋅∇(v)⊙n_Γ )dΓ
                )


        b_L(t,v) = (∫( f(t)*v ) * dΩ
                    +  ∫(-(g_2(t)⋅v))dΓ
                    + ∫(g_1(t)⊙(-Δ(v) + (γ/h)*∇(v)⋅n_Γ)) * dΓ
               )

        # Define of ghost penalties
        g(t,u,v) = h^(-2)*( ∫( (γg1*h)*jump(n_Fg⋅∇(u))*jump(n_Fg⋅∇(v)) ) * dFg +
                         ∫( (γg2*h^3)*jump_nn(u,n_Fg)*jump_nn(v,n_Fg) ) * dFg)

        A(t,u,v) = a_L(t,u,v) + g(t,u,v)
        b(t,v) = b_L(t,v)

        # Initializing linear terms
        m(t, u, v) = ∫(u⋅v )dΩ

        # Alternative 1 (linear)
        # op1 = TransientAffineFEOperator(m,A,b,U,V)

        # Alternative 2 (general form)
        res(t,u,v) = A(t,u,v) + m(t, ∂t(u),v) - b(t,v)
        jac(t,u,du,v) = A(t,du,v)
        jac_t(t,u,dut,v) = m(t, dut,v)
        op2 = TransientFEOperator(res,jac,jac_t,U,V)

        # Alternative 3 (Algorithmic differential)
        # op3 = TransientFEOperator(res, U, V) # Does not work

        # Intalization of method
        op = op2

        # Iterative solvers
        algebraic_solver = LUSolver()
        # solver_method = NLSolver(LUSolver();show_trace=true,method=:newton) #line

        # ODE solvers
        function ode_solver(ode_method, algebraic_solver, dt)
            if ode_method == "BE"
                return ThetaMethod(algebraic_solver, dt, 1)
            elseif ode_method == "CN"
                return ThetaMethod(algebraic_solver, dt, 0.5)
            else
                error("Invalid solver_choice: $ode_method")
            end
        end

        solver = ode_solver(ode_method, algebraic_solver, dt)

        # Inital condition
        t_0 = 0
        T = 1.0
        U_0 = interpolate_everywhere(0,U(0.0))

        #################

        U_h_t = solve(solver, op, U_0, t_0, T)

        solname = vtkdirname*"/sol_dt_$dt"*"_n_$n"
        ts = Float64[]
        el2_ts = Float64[]
        eh1_ts = Float64[]
        eh_energy_ts = Float64[]

        println("Convergence simulation: dt = $dt, n = $n")
        createpvd(solname*".pvd") do pvd
            for (U_h, t) in U_h_t
                e = u_ex(t) - U_h
                pvd[t] = createvtk(Ω, solname*"_$t"*".vtu",cellfields=["u_h"=>U_h,"e"=>e])
                el2_t = sqrt(sum( ∫(e*e)dΩ ))
                eh1_t = sqrt(sum( ∫( e*e + ∇(e)⋅∇(e) )*dΩ ))

                eh_energy = sqrt(sum( ∫(e⊙e)*dΩ + ∫( ∇∇(e)⊙∇∇(e) )*dΩ
                                     + ( γ/h ) * ∫(jump(∇(e)⋅n_Λ) ⊙ jump(∇(e)⋅n_Λ))dΛ
                                     + ( h/γ ) * ∫(mean_nn(e,n_Λ) ⊙ mean_nn(e,n_Λ))dΛ
                                     + ( γ/h ) * ∫((∇(e)⋅n_Γ) ⊙ (∇(e)⋅n_Γ))dΓ
                                     + ( h/γ ) * ∫(( n_Γ ⋅ ∇∇(e)⋅ n_Γ ) ⊙ ( n_Γ ⋅ ∇∇(e)⋅ n_Γ ))dΓ
                                    ))
                push!( ts, t)
                push!( el2_ts, el2_t )
                push!( eh1_ts, eh1_t )
                push!( eh_energy_ts, eh_energy)
            end
        end

        el2s_L2 = sqrt(sum(dt* e_ti^2 for e_ti in el2_ts))
        eh1s_L2 = sqrt(sum(dt* e_ti^2 for e_ti in eh1_ts))
        ehs_energy_L2 = sqrt(sum(dt* e_ti^2 for e_ti in eh_energy_ts))

        el2s_inf = maximum(abs.(el2_ts))
        eh1s_inf = maximum(abs.(eh1_ts))
        ehs_energy_inf = maximum(abs.(eh_energy_ts))

        sol = Solution(el2s_L2=el2s_L2, eh1s_L2=eh1s_L2, ehs_energy_L2=ehs_energy_L2,
                       el2s_inf=el2s_inf, eh1s_inf=eh1s_inf, ehs_energy_inf=ehs_energy_inf)
        return sol
    end
end # Solver

function main()
    vtkdirname= "figures/cahn_hilliard_CutCIP/test_"*string(Dates.now())
    println(vtkdirname)
    mkpath(vtkdirname)
    u_ex(x,t::Real) = sin(t)*(x[1]^2 + x[2]^2 - 1 )^3*sin(x[1])*cos(x[2])
    u_ex(t::Real) = x -> u_ex(x,t)
    n, dt = 2^6, 2^(-4)
    CH.run(n=n, dt=dt, vtkdirname=vtkdirname, ode_method="BE", u_ex=u_ex)
end


# @time main()
