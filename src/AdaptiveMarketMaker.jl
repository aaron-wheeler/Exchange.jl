using Brokerage, Distributions, Dates

using Random
# using Plots
using Convex
using ECOS
using LinearAlgebra
using JuMP
import Ipopt

# ====================================================================== #
# #----- Initialization Procedure -----#

function post_rand_quotes(ticker, num_quotes, unit_trade_size, id,
                    bid_order_ids_t, bid_ϵ_vals_t, ask_order_ids_t, ask_ϵ_vals_t)
    # send random orders
    P_t, S_ref_0 = get_LOB_details(ticker)
    rand_ϵ = [rand(-0.5:0.01:0.5) for _ in 1:num_quotes]
    # compute limit prices
    S_bid = S_ref_0 .* (1 .+ rand_ϵ')
    P_bid = round.(P_t .- S_bid, digits=2)
    S_ask = S_ref_0 .* (1 .+ rand_ϵ')
    P_ask = round.(P_t .+ S_ask, digits=2)
    # post quotes
    for i in 1:num_quotes
        # post ask quote
        order_id = Exchange.ORDER_ID_COUNTER[] += 1
        order_id *= -1
        order = Client.provideLiquidity(ticker,order_id,"SELL_ORDER",P_ask[i],unit_trade_size,id)
        # println("SELL: price = $(P_ask[i]), size = $(unit_trade_size).")
        # fill quote vector
        ask_order_ids_t[i] = order_id

        # post bid quote
        order_id = Exchange.ORDER_ID_COUNTER[] += 1
        order = Client.provideLiquidity(ticker,order_id,"BUY_ORDER",P_bid[i],unit_trade_size,id)
        # println("BUY: price = $(P_bid[i]), size = $(unit_trade_size).")
        # fill quote vector
        bid_order_ids_t[i] = order_id
    end
    # fill quote vectors
    ask_ϵ_vals_t = rand_ϵ
    bid_ϵ_vals_t = rand_ϵ

    return P_t, S_ref_0, bid_order_ids_t, bid_ϵ_vals_t, ask_order_ids_t, ask_ϵ_vals_t
end

function update_init_cash_inventory(cash, z, P_last, S_ref_last, bid_ν_ϵ_t,
                                    bid_ϵ_vals_t, ask_ν_ϵ_t, ask_ϵ_vals_t)
    # account debts
    cash -= sum(bid_ν_ϵ_t .* round.(P_last .- (S_ref_last .* (1 .+ bid_ϵ_vals_t)), digits=2))
    z += sum(bid_ν_ϵ_t)

    # account credits
    cash += sum(ask_ν_ϵ_t .* round.(P_last .+ (S_ref_last .* (1 .+ ask_ϵ_vals_t)), digits=2))
    z -= sum(ask_ν_ϵ_t)

    return round(cash, digits=2), z
end

# #----- Incoming net flow (ν_ϵ) mean and variance estimates -----#

# initialize Empirical Response Table
function construct_ERTable(P_last, S_ref_last, num_quotes, bid_ϵ_vals_t,
                                    bid_ν_ϵ_t, ask_ϵ_vals_t, ask_ν_ϵ_t)
    # prepare data matrix, arbitrarily, bids first
    P = fill(P_last, num_quotes)
    S_ref = fill(S_ref_last, num_quotes)
    A = hcat(P, S_ref, bid_ϵ_vals_t)
    A = vcat(A, hcat(P, S_ref, ask_ϵ_vals_t))
    # compute incoming net flow
    ν_ϵ = vcat(bid_ν_ϵ_t, ask_ν_ϵ_t)
    # compute normalized spread PnL -> ν_ϵ*S_ref*(1 + ϵ)) / S_ref
    s_ϵ = [((ν_ϵ_t[i]*A[:, 2][i]*(1 + A[:, 3][i])) / (A[:, 2][i])) for i in 1:size(A, 1)]
    return ν_ϵ, s_ϵ, A
end

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

function compute_mse(y_true, x, A)
    # compute least squares solution
    y_pred = A * x
    # compute mean squared error
    loss = sum((y_true .- y_pred).^2) / length(y_true)
    return loss
end

# calculate the volatility σ

# ======================================================================================== #

function AdaptiveMM_run!(ticker, market_open, market_close, parameters, init_conditions, server_info)
    # unpack parameters
    η_ms,γ,δ_tol,inventory_limit,unit_trade_size,trade_freq = parameters
    cash, z, num_init_quotes = init_conditions
    host_ip_address, port, username, password = server_info
    id = ticker # LOB assigned to Market Maker

    # initiation and activation rule
    time = 0.0:0.001:10.0 # sufficiently granular for Pareto distribution
    prob_activation = (pdf.(Pareto(1,1), time))[1005:10001]
    initiated = false

    # connect to brokerage
    url = "http://$(host_ip_address):$(port)"
    Client.SERVER[] = url
    Client.createUser(username, password)
    user = Client.loginUser(username, password)

    # preallocate data structures
    ν_ϵ_losses = Float64[]
    s_ϵ_losses = Float64[]
    new_bid = [0.0 0.0 0.0]
    new_ask = [0.0 0.0 0.0]

    # hold off trading until the market opens
    if Dates.now() < market_open
        @info "(Adaptive MM) Waiting until market open..."
        pre_market_time = Dates.value(market_open - now()) / 1000 # convert to secs
        sleep(pre_market_time)
    end

    # execute trades until the market closes
    @info "(Adaptive MM) Initiating trade sequence now."
    while Dates.now() < market_close
        if initiated != true
            #----- Initialization Step -----#
            # preallocate init quote vectors
            bid_order_ids_t = zeros(Int, num_quotes)
            bid_ϵ_vals_t = zeros(Float64, num_quotes)
            bid_ν_ϵ_t = fill(unit_trade_size, num_quotes)
            ask_order_ids_t = zeros(Int, num_quotes)
            ask_ϵ_vals_t = zeros(Float64, num_quotes)
            ask_ν_ϵ_t = fill(unit_trade_size, num_quotes)
            
            # post init quotes
            trade_volume_last = OMS.trade_volume_t[ticker]
            P_last, S_ref_last, bid_order_ids_t, bid_ϵ_vals_t, ask_order_ids_t, ask_ϵ_vals_t = post_rand_quotes(ticker, num_init_quotes, unit_trade_size, id, 
                                    bid_order_ids_t, bid_ϵ_vals_t, ask_order_ids_t, ask_ϵ_vals_t)

            # wait 'trade_freq' seconds (at least), and longer if no quotes filled
            sleep(trade_freq)
            while length(Client.getActiveSellOrders(id, ticker)) == num_init_quotes && length(Client.getActiveBuyOrders(id, ticker)) == num_init_quotes
                sleep(trade_freq)
            end
            trade_volume_t = OMS.trade_volume_t[ticker]

            # retrieve data for unfilled orders
            active_sell_orders = Client.getActiveSellOrders(id, ticker)
            for i in eachindex(active_sell_orders)
                # retrieve order
                unfilled_sell = rand(active_sell_orders[i])[2]
                # cancel unfilled order
                cancel_order = Client.cancelQuote(ticker,unfilled_sell.orderid,"SELL_ORDER",unfilled_sell.price,id)
                # store data
                idx = findfirst(x -> x==unfilled_sell.orderid, ask_order_ids_t)
                ask_ν_ϵ_t[idx] = unit_trade_size - unfilled_sell.size
            end

            active_buy_orders = Client.getActiveBuyOrders(id, ticker)
            for i in eachindex(active_buy_orders)
                # retrieve order
                unfilled_buy = rand(active_buy_orders[i])[2]
                # cancel unfilled order
                cancel_order = Client.cancelQuote(ticker,unfilled_buy.orderid,"BUY_ORDER",unfilled_buy.price,id)
                # store data
                idx = findfirst(x -> x==unfilled_buy.orderid, bid_order_ids_t)
                bid_ν_ϵ_t[idx] = unit_trade_size - unfilled_buy.size
            end

            # adjust cash and inventory
            cash, z = update_init_cash_inventory(cash, z, P_last, S_ref_last, bid_ν_ϵ_t,
                                        bid_ϵ_vals_t, ask_ν_ϵ_t, ask_ϵ_vals_t)

            # construct Empirical Response Table
            ν_ϵ, s_ϵ, A = construct_ERTable(P_last, S_ref_last, num_quotes, bid_ϵ_vals_t,
                                                bid_ν_ϵ_t, ask_ϵ_vals_t, ask_ν_ϵ_t)

            # compute initial least squares estimators
            x_QR_ν = A \ ν_ϵ # QR Decomposition
            x_QR_s = A \ s_ϵ # QR Decomposition
            𝐏_old = inv(A' * A) # for Recursive Least Squares step

            # compute and store loss (for plotting)
            ν_loss = compute_mse(ν_ϵ, x_QR_ν, A)
            push!(ν_ϵ_losses, ν_loss)
            s_loss = compute_mse(s_ϵ, x_QR_s, A)
            push!(s_ϵ_losses, s_loss)

            # store values for online mean and variance estimates
            # https://www.johndcook.com/blog/standard_deviation/
            sum_ν = sum(ν_ϵ) # rolling sum count
            var_ν = 0 # var(ν_ϵ) # initial variance
            k = length(ν_ϵ) # number of samples, same as length(s_ϵ)
            sum_s = sum(s_ϵ) # rolling sum count
            var_s = 0 # var(s_ϵ) # initial variance

            # compute total market volume (for individual ticker) in last time interval
            V_market = trade_volume_t - trade_volume_last

            # compute the volatility σ
            log_returns = [log(P_rounds[i+1] / P_rounds[i]) for i in 1:(num_rounds -1)]
            mean_return = sum(log_returns) / length(log_returns)
            return_variance = sum((log_returns .- mean_return).^2) / (length(log_returns) - 1)
            σ = sqrt(return_variance) # volatility

            # complete initialization step
            initiated = true
        end
        
        # retrieve current market conditions (current mid-price and side-spread)
        P_t, S_ref_0 = get_LOB_details(ticker)
        new_bid[1] = P_t
        new_ask[1] = P_t
        new_bid[2] = S_ref_0
        new_ask[2] = S_ref_0

        # update volatility estimate
        σ = σ * sqrt(P_t - P_last) # new volatility

        #----- Pricing Policy -----#
        # STEP 1: Ensure that Market Maker adapts policy if it is getting little or no trade flow

        # compute the ϵ that gets us the closest to η_ms
        # initialize -
        ϵ_ms = Variable() # scalar
        t = Variable() # scalar (for absolute value)
        # setup problem (reformulate absolute value) and solve -
        prob = η_ms - (([P_t S_ref_0 ϵ_ms]*x_QR_ν)[1]) / V_market
        problem = minimize(t, ϵ_ms >= -0.02, ϵ_ms <= 0.02, t >= prob, t >= -prob)
        # Solve the problem by calling solve!
        solve!(problem, ECOS.Optimizer; silent_solver = true)

        # compute the ϵ that maximizes profit within δ_tol
        # initialize -
        cost1 = problem.optval
        ϵ_opt = Variable() # scalar
        t = Variable() # scalar
        prob = η_ms - (([P_t S_ref_0 ϵ_opt]*x_QR_ν)[1]) / V_market
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
        cost2 = JuMP.Model(Ipopt.Optimizer)
        set_silent(cost2)
        ϵ_skew = 0 # scalar
        @variable(cost2, ϵ_skew)
        # setup problem -
        E_s_ϵ = ([P_t S_ref_0 ϵ_skew]*x_QR_s)[1] # expected value
        mean_s = sum_s / k
        mean_s_ϵ = mean_s + ((E_s_ϵ - mean_s) / k)
        var_s_ϵ = var_s + ((E_s_ϵ - mean_s) * (E_s_ϵ - mean_s_ϵ)) # variance
        # repeat for ν
        E_z_ν_ϵ = z + ([P_t 0 ϵ_skew]*x_QR_ν)[1] # expected value
        mean_ν = sum_ν / k
        mean_z_ν_ϵ = mean_ν + ((E_z_ν_ϵ - mean_ν) / k)
        var_z_ν_ϵ = var_ν + ((E_z_ν_ϵ - mean_ν) * (E_z_ν_ϵ - mean_z_ν_ϵ)) # variance
        # solve the problem -
        @NLobjective(cost2, Min, -(S_ref_0 * E_s_ϵ) + γ * sqrt((S_ref_0^2 * var_s_ϵ) + (σ^2 * var_z_ν_ϵ)))
        optimize!(cost2)

        # execute actions (submit quotes)
        trade_volume_last = OMS.trade_volume_t[ticker]
        if z > 0
            # positive inventory -> skew sell-side order
            ϵ_buy = ϵ_buy
            ϵ_sell = round(value.(ϵ_skew), digits = 2)
            new_bid[3] = ϵ_buy
            new_ask[3] = ϵ_sell
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
            new_bid[3] = ϵ_buy
            new_ask[3] = ϵ_sell
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
        cost_hedge = JuMP.Model(Ipopt.Optimizer)
        set_silent(cost_hedge)
        x_frac = 0 # scalar
        Z = z # scalar
        @variable(cost_hedge, 0 <= x_frac <= 1)
        @variable(cost_hedge, -inventory_limit <= Z <= inventory_limit)
        # setup problem -
        Z = z*(1 - x_frac)
        E_zx_ν_ϵ = Z + ([P_t S_ref_0 ϵ_hedge]*x_QR_ν)[1] # expected value
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
            order_size = -round(Int, (x_frac*z))
            # println("Hedge sell order -> sell $(order_size) shares")
            # SUBMIT SELL MARKET ORDER
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            order_id *= -1
            order = Client.hedgeTrade(ticker,order_id,"SELL_ORDER",order_size,id)
            # UPDATE z
            # println("Inventory z = $(z) -> z = $(z - order_size)")
            z -= order_size
        elseif z < 0
            # negative inventory -> hedge via buy order
            order_size = round(Int, (x_frac*z))
            # println("Hedge buy order -> buy $(order_size) shares")
            # SUBMIT BUY MARKET ORDER
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            order = Client.hedgeTrade(ticker,order_id,"BUY_ORDER",order_size,id)
            # UPDATE z
            # println("Inventory z = $(z) -> z = $(z - order_size)")
            z += order_size
        end

        # wait 'trade_freq' seconds and reset data structures
        sleep(trade_freq)
        trade_volume_t = OMS.trade_volume_t[ticker]
        ν_new_bid = [unit_trade_size]
        ν_new_ask = [unit_trade_size]
        ν_new = 0
        s_new = 0
        A_new = 0

        #----- Update Step -----#

        # retrieve data for (potentially) unfilled buy order
        active_buy_orders = Client.getActiveBuyOrders(id, ticker)
        for i in eachindex(active_buy_orders)
            # retrieve order
            unfilled_buy = first(active_buy_orders[i])[2]
            # cancel unfilled order
            cancel_order = Client.cancelQuote(ticker,unfilled_buy.orderid,"BUY_ORDER",unfilled_buy.price,id)
            # store data
            ν_new_bid[1] = unit_trade_size - unfilled_buy.size
        end

        # retrieve data for (potentially) unfilled sell order
        active_sell_orders = Client.getActiveSellOrders(id, ticker)
        for i in eachindex(active_sell_orders)
            # retrieve order
            unfilled_sell = first(active_sell_orders[i])[2]
            # cancel unfilled order
            cancel_order = Client.cancelQuote(ticker,unfilled_sell.orderid,"SELL_ORDER",unfilled_sell.price,id)
            # store data
            ν_new_ask[1] = unit_trade_size - unfilled_sell.size
        end

        # adjust cash and inventory
        cash, z = update_init_cash_inventory(cash, z, P_t, S_ref_0, ν_new_bid,
                                        new_bid[3], ν_new_ask, new_ask[3])

        # Update Estimators: Recursive Least Squares w/ multiple observations
        # 𝐏_old = inv(A' * A)
        # new observation k
        ν_new = vcat(ν_ϵ, vcat(ν_new_bid, ν_new_ask))
        A_new = vcat(A, vcat(new_bid, new_ask))
        s_new = [((ν_new[i]*A_new[:, 2][i]*(1 + A_new[:, 3][i])) / (A_new[:, 2][i])) for i in 1:size(A_new, 1)]
        # update 𝐏_k
        𝐏_new = 𝐏_old - 𝐏_old*A_new'*inv(I + A_new*𝐏_old*A_new')*A_new*𝐏_old
        # compute 𝐊_k
        𝐊_k = 𝐏_new*A_new'
        # compute new estimator
        x_QR_ν = x_QR_ν + 𝐊_k*(ν_new .- A_new*x_QR_ν)
        x_QR_s = x_QR_s + 𝐊_k*(s_new .- A_new*x_QR_s)

        # update Empirical Response Table and related variables for next time step
        V_market = trade_volume_t - trade_volume_last
        ν_ϵ = ν_new
        s_ϵ = s_new
        A = A_new
        𝐏_old = 𝐏_new

        # compute and store loss (for plotting)
        ν_loss = compute_mse(ν_ϵ, x_QR_ν, A)
        push!(ν_ϵ_losses, ν_loss)
        s_loss = compute_mse(s_ϵ, x_QR_s, A)
        push!(s_ϵ_losses, s_loss)

        # update online variance and values for future online estimates
        # https://www.johndcook.com/blog/standard_deviation/
        for i in eachindex(ν_new[k+1:end])
            mean_ν = sum_ν / (k + i - 1) # using prev sum & k
            mean_ν_new = mean_ν + ((ν_new[k+i] - mean_ν) / (k + i))
            var_ν += (var_ν + ((ν_new[k+i] - mean_ν) * (ν_new[k+i] - mean_ν_new))) / (k + i) # new variance
        end
        # repeat for s
        for i in eachindex(s_new[k+1:end])
            mean_s = sum_s / (k + i - 1) # using prev sum & k
            mean_s_new = mean_s + ((s_new[k+i] - mean_s) / (k + i))
            var_s += (var_s + ((s_new[k+i] - mean_s) * (s_new[k+i] - mean_s_new))) / (k + i) # new variance
        end
        # update values
        sum_ν = sum(ν_new[k+1:end]) # rolling sum count
        sum_s = sum(s_new[k+1:end]) # rolling sum count
        k = length(ν_ϵ) # number of samples, same as length(s_ϵ)
        P_last = P_t # for volatility update step

    end
    @info "(Adaptive MM) Trade sequence complete."
    # Plots
    # plot losses
end