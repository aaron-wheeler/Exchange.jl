using Brokerage, Distributions, Dates

using Random
# using Plots
using Convex
using ECOS
using LinearAlgebra
using JuMP
import Ipopt

# ====================================================================== #
# #----- Incoming net flow (ν_ϵ) mean and variance estimates -----#

# initialize Empirical Response Table

# compute initial least squares estimator

# compute the online variance


# #----- Normalized spread PnL (s_ϵ) mean and variance estimates -----#

# initialize Empirical Response Table

# compute initial least squares estimator

# compute the online variance 


# #----- Utility functions -----#

function get_LOB_details(ticker)
    bid_price, ask_price = Client.getBidAsk(ticker)
    mid_price = round(((ask_price + bid_price) / 2.0); digits=2) # current mid_price
    spread = ask_price - bid_price
    S_ref_0 = round((spread / 2.0), digits=2) # current best spread
    return mid_price, S_ref_0
end

# calculate the volatility σ

# ======================================================================================== #

function AdaptiveMM_run!(ticker, market_open, market_close, parameters, server_info)
    # unpack parameters
    η_ms,γ,δ_tol,inventory_limit,unit_trade_size  = parameters
    host_ip_address, port, username, password = server_info
    id = ticker # LOB assigned to Market Maker

    # activation rule
    time = 0.0:0.001:10.0 # sufficiently granular for Pareto distribution
    prob_activation = (pdf.(Pareto(1,1), time))[1005:10001]

    # connect to brokerage
    url = "http://$(host_ip_address):$(port)"
    Client.SERVER[] = url
    Client.createUser(username, password)
    user = Client.loginUser(username, password)

    # hold off trading until the market opens
    if Dates.now() < market_open
        @info "(Adaptive MM) Waiting until market open..."
        pre_market_time = Dates.value(market_open - now()) / 1000 # convert to secs
        sleep(pre_market_time)
    end

    # execute trades until the market closes
    @info "(Adaptive MM) Initiating trade sequence now."
    while Dates.now() < market_close
        # initialization step
        # TODO

        # retrieve current market conditions
        P_t, S_ref_0 = get_LOB_details(ticker)
        # V_market = 25 # total market volume in last time invocation
        # z, k, sum_s, var_s, sum_ν, var_ν, volatility σ
        # x_QR

        #----- Pricing Policy -----#
        # STEP 1: Ensure that Market Maker adapts policy if it is getting little or no trade flow

        # compute the ϵ that gets us the closest to η_ms
        # initialize -
        ϵ_ms = Variable() # scalar
        t = Variable() # scalar
        # setup problem (reformulate absolute value) and solve -
        prob = η_ms - (([P_t S_ref_0 ϵ_ms]*x_QR)[1]) / V_market
        problem = minimize(t, ϵ_ms >= -0.02, ϵ_ms <= 0.02, t >= prob, t >= -prob)
        # Solve the problem by calling solve!
        solve!(problem, ECOS.Optimizer; silent_solver = true)

        # compute the ϵ that maximizes profit within δ_tol
        # initialize -
        cost1 = problem.optval
        ϵ_opt = Variable() # scalar
        t = Variable() # scalar
        prob = η_ms - (([P_t S_ref_t ϵ_opt]*x_QR)[1]) / V_market
        # setup problem and solve -
        p = maximize(ϵ_opt)
        p.constraints += prob <= t
        p.constraints += -prob <= t
        p.constraints += t - cost1 <= δ_tol
        p.constraints += -(t - cost1) <= δ_tol
        solve!(p, ECOS.Optimizer; silent_solver = true)

        # Set buy and sell ϵ values
        ϵ_buy = round(p.optval, digits = 2)
        ϵ_sell = round(p.optval, digits = 2)
        
        # STEP 2: Skew one side (buy/sell) to attract a flow that offsets current inventory
        # initialize -
        cost2 = Model(Ipopt.Optimizer)
        set_silent(cost2)
        ϵ_skew = 0 # scalar
        @variable(cost2, ϵ_skew)
        # setup problem -
        E_s_ϵ = ([P_t S_ref_t ϵ_skew]*x_QR_s)[1] # expected value
        mean_s = sum_s / k
        mean_s_ϵ = mean_s + ((E_s_ϵ - mean_s) / k)
        var_s_ϵ = var_s + ((E_s_ϵ - mean_s) * (E_s_ϵ - mean_s_ϵ)) # variance
        # repeat
        E_z_ν_ϵ = z + ([P_t S_ref_t ϵ_skew]*x_QR)[1] # expected value
        mean_ν = sum_ν / k
        mean_z_ν_ϵ = mean_ν + ((E_z_ν_ϵ - mean_ν) / k)
        var_z_ν_ϵ = var_ν + ((E_z_ν_ϵ - mean_ν) * (E_z_ν_ϵ - mean_z_ν_ϵ)) # variance
        # solve the problem -
        @NLobjective(cost2, Min, -(S_ref_0 * E_s_ϵ) + γ * sqrt((S_ref_0^2 * var_s_ϵ) + (σ^2 * var_z_ν_ϵ)))
        optimize!(cost2)

        # execute actions (submit quotes)
        if z > 0
            # positive inventory -> skew sell-side order
            ϵ_buy = ϵ_buy
            ϵ_sell = round(value.(ϵ_skew), digits = 2)
            # println("ϵ_buy = $(ϵ_buy), ϵ_sell = $(ϵ_sell)")
            P_bid = P_t - round(S_ref_0*(1 + ϵ_buy), digits=2)
            P_ask = P_t + round(S_ref_0*(1 + ϵ_sell), digits=2)
            # SUBMIT QUOTES
            # post ask quote
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            order_id *= -1
            # println("SELL: price = $(P_ask), size = $(unit_trade_size).")
            order = Client.provideLiquidity(ticker,order_id,"SELL_ORDER",P_ask,unit_trade_size,id)
            # post bid quote
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            # println("BUY: price = $(P_bid), size = $(unit_trade_size).")
            order = Client.provideLiquidity(ticker,order_id,"BUY_ORDER",P_bid,unit_trade_size,id)
            # set ϵ param for hedge step
            ϵ_hedge = ϵ_sell
        elseif z < 0
            # negative inventory -> skew buy-side order
            ϵ_buy = round(value.(ϵ_skew), digits = 2)
            ϵ_sell = ϵ_sell
            # println("ϵ_buy = $(ϵ_buy), ϵ_sell = $(ϵ_sell)")
            P_bid = P_t - round(S_ref_0*(1 + ϵ_buy), digits=2); P_ask = P_t + round(S_ref_0*(1 + ϵ_sell), digits=2)
            # SUBMIT QUOTES
            # post ask quote
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            order_id *= -1
            # println("SELL: price = $(P_ask), size = $(unit_trade_size).")
            order = Client.provideLiquidity(ticker,order_id,"SELL_ORDER",P_ask,unit_trade_size,id)
            # post bid quote
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            # println("BUY: price = $(P_bid), size = $(unit_trade_size).")
            order = Client.provideLiquidity(ticker,order_id,"BUY_ORDER",P_bid,unit_trade_size,id)
            # set ϵ param for hedge step
            ϵ_hedge = ϵ_buy
        else
            # no inventory -> no skew
            ϵ_buy = ϵ_buy
            ϵ_sell = ϵ_sell
            # println("ϵ_buy = $(ϵ_buy), ϵ_sell = $(ϵ_sell)")
            P_bid = P_t - round(S_ref_0*(1 + ϵ_buy), digits=2); P_ask = P_t + round(S_ref_0*(1 + ϵ_sell), digits=2)
            # SUBMIT QUOTES
            # post ask quote
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            order_id *= -1
            # println("SELL: price = $(P_ask), size = $(unit_trade_size).")
            order = Client.provideLiquidity(ticker,order_id,"SELL_ORDER",P_ask,unit_trade_size,id)
            # post bid quote
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            # println("BUY: price = $(P_bid), size = $(unit_trade_size).")
            order = Client.provideLiquidity(ticker,order_id,"BUY_ORDER",P_bid,unit_trade_size,id)
            # set ϵ param for hedge step
            ϵ_hedge = ϵ_buy
        end

        #----- Hedging Policy -----#
        # Determine the fraction of current inventory to hedge (by initiating offsetting trade)

        # initialize -
        cost_hedge = Model(Ipopt.Optimizer)
        set_silent(cost_hedge)
        x_frac = 0 # scalar
        Z = z # scalar
        @variable(cost_hedge, 0 <= x_frac <= 1)
        @variable(cost_hedge, -inventory_limit <= Z <= inventory_limit)
        # setup problem -
        Z = z*(1 - x_frac)
        E_zx_ν_ϵ = Z + ([P_t S_ref_t ϵ_hedge]*x_QR)[1] # expected value
        mean_ν = sum_ν / k
        mean_zx_ν_ϵ = mean_ν + ((E_zx_ν_ϵ - mean_ν) / k)
        var_zx_ν_ϵ = var_ν + ((E_zx_ν_ϵ - mean_ν) * (E_zx_ν_ϵ - mean_zx_ν_ϵ)) # variance
        # solve the problem -
        @NLobjective(cost_hedge, Min, (abs(x_frac*z) * S_ref_0) + γ * sqrt(σ^2 * var_zx_ν_ϵ))
        optimize!(cost_hedge)

        # execute actions (submit hedge trades)
        x_frac = round(value.(x_frac), digits = 2)
        if z > 0
            # positive inventory -> hedge via sell order
            # println("Hedge sell order -> sell $(x_frac*z) shares")
            # SUBMIT SELL MARKET ORDER
            # println("Inventory z = $(z) -> z = $(z*(1 - x_frac))")
            nothing
            # UPDATE z
            nothing
        elseif z < 0
            # negative inventory -> hedge via buy order
            # println("Hedge buy order -> buy $(x_frac*z) shares")
            # SUBMIT BUY MARKET ORDER
            # println("Inventory z = $(z) -> z = $(z*(1 - x_frac))")
            nothing
            # UPDATE z
            nothing
        end

        # wait 0.35 seconds
        # retrieve trades
        # cancel unfilled trades

        # Update Estimators: Recursive Least Squares
        # TODO

    end
    @info "(Adaptive MM) Trade sequence complete."
end