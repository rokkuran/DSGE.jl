using Base: Test, LinAlg
using MATLAB

using DSGE
include("../util.jl")
path = dirname(@__FILE__)



model = Model990()
Γ0, Γ1, C, Ψ, Π = eqcond(model)
stake = 1 + 1e-6
G1, C, impact, fmat, fwt, ywt, gev, eu, loose = gensys(Γ0, Γ1, C, Ψ, Π, stake)

mf = MatFile("$path/gensys.mat")
G1_exp = get_variable(mf, "G1_gensys")
C_exp = reshape(get_variable(mf, "C_gensys"), 66, 1)
impact_exp = get_variable(mf, "impact")
eu_exp = get_variable(mf, "eu")
close(mf)

@test test_matrix_eq(G1_exp, G1)
@test test_matrix_eq(C_exp, C)
@test test_matrix_eq(impact_exp, impact)
@test isequal(eu_exp, eu)