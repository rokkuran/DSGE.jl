"""
```
forecast(m, systems, z0s; shocks = dzeros(S, (0, 0, 0), [myid()]),
    procs = [myid()])
```

Computes forecasts for all draws, given a model object, system matrices, initial
state vectors, and optionally an array of shocks.

### Inputs

- `m::AbstractModel`: model object
- `systems::DVector{System{S}}`: vector of `System` objects specifying
  state-space system matrices for each draw
- `z0s::DVector{Vector{S}}`: vector of state vectors in the final historical
  period (aka inital forecast period)

where `S<:AbstractFloat`.

### Keyword Arguments

- `shocks::DArray{S, 3}`: array of size `ndraws` x `nshocks` x `horizon`, whose
  elements are the shock innovations for each time period, for draw
- `procs::Vector{Int}`: list of worker processes over which to distribute
  draws. Defaults to `[myid()]`

### Outputs

- `states::DArray{S, 3}`: array of size `ndraws` x `nstates` x `horizon` of
  forecasted states for each draw
- `obs::DArray{S, 3}`: array of size `ndraws` x `nobs` x `horizon` of forecasted
  observables for each draw
- `pseudo::DArray{S, 3}`: array of size `ndraws` x `npseudo` x `horizon` of
  forecasted pseudo-observables for each draw. If
  `!forecast_pseudoobservables(m)`, `pseudo` will be empty.
- `shocks::DArray{S, 3}`: array of size `ndraws` x `nshocks` x `horizon` of
  shock innovations for each draw
"""
function forecast{S<:AbstractFloat}(m::AbstractModel,
    systems::DVector{System{S}, Vector{System{S}}},
    z0s::DVector{Vector{S}, Vector{Vector{S}}};
    shocks::DArray{S, 3} = dzeros(S, (0, 0, 0), [myid()]),
    procs::Vector{Int} = [myid()])

    # Reset procs to [myid()] if necessary
    procs = reset_procs(m, procs)

    # Numbers of useful things
    ndraws = length(systems)
    nprocs = length(procs)
    horizon = forecast_horizons(m)

    nstates = n_states_augmented(m)
    nobs    = n_observables(m)
    npseudo = n_pseudoobservables(m)
    nshocks = n_shocks_exogenous(m)

    states_range = 1:nstates
    obs_range    = (nstates + 1):(nstates + nobs)
    pseudo_range = (nstates + nobs + 1):(nstates + nobs + npseudo)
    shocks_range = (nstates + nobs + npseudo + 1):(nstates + nobs + npseudo + nshocks)

    shocks_provided = !isempty(shocks)

    # Construct distributed array of forecast outputs
    out = DArray((ndraws, nstates + nobs + npseudo + nshocks, horizon), procs, [nprocs, 1, 1]) do I
        localpart = zeros(map(length, I)...)
        draw_inds = first(I)
        ndraws_local = Int(ndraws / nprocs)

        for i in draw_inds
            # Index out shocks for draw i
            shocks_i = if shocks_provided
                convert(Array, slice(shocks, i, :, :))
            else
                Matrix{S}()
            end

            states, obs, pseudo, shocks = compute_forecast(m, systems[i],
                z0s[i]; shocks = shocks_i)

            i_local = mod(i-1, ndraws_local) + 1

            localpart[i_local, states_range, :] = states
            localpart[i_local, obs_range,    :] = obs
            if forecast_pseudoobservables(m)
                localpart[i_local, pseudo_range, :] = pseudo
            end
            localpart[i_local, shocks_range, :] = shocks
        end
        return localpart
    end

    # Convert SubArrays to DArrays and return
    states = convert(DArray, out[1:ndraws, states_range, 1:horizon])
    obs    = convert(DArray, out[1:ndraws, obs_range,    1:horizon])
    pseudo = convert(DArray, out[1:ndraws, pseudo_range, 1:horizon])
    shocks = convert(DArray, out[1:ndraws, shocks_range, 1:horizon])

    return states, obs, pseudo, shocks
end

"""
```
compute_forecast(m, system, z0; shocks = Matrix{S}())

compute_forecast(system, z0, shocks)

compute_forecast(T, R, C, Q, Z, D, Z_pseudo, D_pseudo, z0, shocks)
```

### Inputs

- `m::AbstractModel`: model object. Only needed for the method in which `shocks`
  are not provided.
- `system::System{S}`: state-space system matrices. Alternatively, provide
  transition equation matrices `T`, `R`, `C`; measurement equation matrices `Q`,
  `Z`, `D`; and (possibly empty) pseudo-measurement equation matrices `Z_pseudo`
  and `D_pseudo`.
- `z0`: state vector in the final historical period (aka inital forecast period)

where `S<:AbstractFloat`.

### Keyword Arguments

- `shocks::Matrix{S}`: matrix of size `nshocks` x `horizon` of shock innovations
  under which to forecast. If not provided, shocks are drawn according to:

  1. If `forecast_killshocks(m)`, `shocks` is set to a `nshocks` x `horizon`
     matrix of zeros
  2. Otherwise, if `forecast_tdist_shocks(m)`, draw `horizons` many shocks from a
     `Distributions.TDist(forecast_tdist_df_val(m))`
  3. Otherwise, draw `horizons` many shocks from a
     `DegenerateMvNormal(zeros(nshocks), sqrt(system[:QQ]))`

### Outputs

- `states::Matrix{S}`: matrix of size `nstates` x `horizon` of forecasted states
- `obs::Matrix{S}`: matrix of size `nobs` x `horizon` of forecasted observables
- `pseudo::Matrix{S}`: matrix of size `npseudo` x `horizon` of forecasted
  pseudo-observables. If `!forecast_pseudoobservables(m)` or the provided
  `Z_pseudo` and `D_pseudo` matrices are empty, then `pseudo` will be empty.
- `shocks::Matrix{S}`: matrix of size `nshocks` x `horizon` of shock innovations
"""
function compute_forecast{S<:AbstractFloat}(m::AbstractModel, system::System{S},
    z0::Vector{S}; shocks::Matrix{S} = Matrix{S}())

    # Numbers of things
    nshocks = n_shocks_exogenous(m)
    horizon = forecast_horizons(m)

    # Populate shocks matrix
    if isempty(shocks)
        shocks = zeros(S, nshocks, horizon)

        # Draw shocks if necessary
        if !forecast_kill_shocks(m)
            dist = if forecast_tdist_shocks(m)
                # Use t-distributed shocks
                Distributions.TDist(forecast_tdist_df_val(m))
            else
                # Use normally distributed shocks
                DegenerateMvNormal(zeros(S, nshocks), sqrt(system[:QQ]))
            end

            for t in 1:horizon
                shocks[:, t] = rand(dist)
            end
        end
    end

    # Determine whether to enforce the zero lower bound in the forecast
    enforce_zlb = forecast_enforce_zlb(m)
    ind_r = m.observables[:obs_nominalrate]
    ind_r_sh = m.exogenous_shocks[:rm_sh]
    zlb_value = forecast_zlb_value(m)

    compute_forecast(system, z0, shocks; enforce_zlb = enforce_zlb,
        ind_r = ind_r, ind_r_sh = ind_r_sh, zlb_value = zlb_value)
end


function compute_forecast{S<:AbstractFloat}(system::System{S}, z0::Vector{S},
    shocks::Matrix{S}; enforce_zlb::Bool = false, ind_r::Int = -1,
    ind_r_sh::Int = -1, zlb_value::S = 0.13/4)

    # Unpack system
    T, R, C = system[:TTT], system[:RRR], system[:CCC]
    Q, Z, D = system[:QQ], system[:ZZ], system[:DD]

    Z_pseudo, D_pseudo = if !isnull(system.pseudo_measurement)
        system[:ZZ_pseudo], system[:DD_pseudo]
    else
        Matrix{S}(), Vector{S}()
    end

    compute_forecast(T, R, C, Q, Z, D, Z_pseudo, D_pseudo, z0, shocks;
        enforce_zlb = enforce_zlb, ind_r = ind_r, ind_r_sh = ind_r_sh,
        zlb_value = zlb_value)
end

function compute_forecast{S<:AbstractFloat}(T::Matrix{S}, R::Matrix{S},
    C::Vector{S}, Q::Matrix{S}, Z::Matrix{S}, D::Vector{S}, Z_pseudo::Matrix{S},
    D_pseudo::Vector{S}, z0::Vector{S}, shocks::Matrix{S}; enforce_zlb::Bool = false,
    ind_r::Int = -1, ind_r_sh::Int = -1, zlb_value::S = 0.13/4)

    # Setup
    nshocks = size(R, 2)
    nstates = size(T, 2)
    nobs    = size(Z, 1)
    npseudo = size(Z_pseudo, 1)
    horizon = size(shocks, 2)

    # Define our iteration function
    iterate(z_t1, ϵ_t) = C + T*z_t1 + R*ϵ_t

    # Iterate state space forward
    states = zeros(S, nstates, horizon)
    states[:, 1] = iterate(z0, shocks[:, 1])
    for t in 2:horizon
        states[:, t] = iterate(states[:, t-1], shocks[:, t])

        # Change monetary policy shock to account for 0.25 interest rate bound
        interest_rate_forecast = getindex(D + Z*states[:, t], ind_r)
        if enforce_zlb && interest_rate_forecast[1] < zlb_value
            # Solve for interest rate shock causing interest rate forecast to be exactly ZLB
            shocks[ind_r_sh, t] = 0.
            shocks[ind_r_sh, t] = (zlb_value - D[ind_r] - Z[ind_r, :]*iterate(states[:, t-1], shocks[:, t])) /
                                      (Z[ind_r, :]*RRR[:, ind_r_sh])

            # Forecast again with new shocks
            states[:, t] = iterate(states[:, t-1], shocks[:, t])

            # Confirm procedure worked
            interest_rate_forecast = getindex(D + Z*states[:, t], ind_r)
            @assert interest_rate_forecast >= zlb_value
        end
    end

    # Apply measurement and pseudo-measurement equations
    obs    = D .+ Z*states
    pseudo = if !isempty(Z_pseudo) && !isempty(D_pseudo)
        D_pseudo .+ Z_pseudo * states
    else
        Matrix{S}()
    end

    # Return forecasts
    return states, obs, pseudo, shocks
end
