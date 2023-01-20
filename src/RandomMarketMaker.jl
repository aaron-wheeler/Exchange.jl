using Brokerage, Distributions, Dates

using Random
using CSV, DataFrames

# ====================================================================== #
# #----- Utility functions -----#

function update_init_cash_inventory(cash, z, P_last, S_ref_last, bid_ν_ϵ_t,
                                    bid_ϵ_vals_t, ask_ν_ϵ_t, ask_ϵ_vals_t)
    # balance debts
    cash -= sum(bid_ν_ϵ_t .* round.(P_last .- (S_ref_last .* (1 .+ bid_ϵ_vals_t)), digits=2))
    z += sum(bid_ν_ϵ_t)

    # balance credits
    cash += sum(ask_ν_ϵ_t .* round.(P_last .+ (S_ref_last .* (1 .+ ask_ϵ_vals_t)), digits=2))
    z -= sum(ask_ν_ϵ_t)

    return round(cash, digits=2), z
end

function get_price_details(ticker)
    bid_price, ask_price = Client.getBidAsk(ticker)
    mid_price = round(((ask_price + bid_price) / 2.0); digits=2) # current mid_price
    spread = ask_price - bid_price
    S_ref_0 = round((spread / 2.0), digits=2) # current best spread
    return mid_price, S_ref_0
end

# ======================================================================================== #

function RandomMM_run!(ticker, market_open, market_close, parameters, init_conditions, server_info; collect_data = false)
    # unpack parameters
    id,ϵ_min,ϵ_max,inventory_limit,unit_trade_size,trade_freq = parameters
    cash, z = init_conditions
    host_ip_address, port, username, password = server_info

    # connect to brokerage
    url = "http://$(host_ip_address):$(port)"
    Client.SERVER[] = url
    Client.createUser(username, password)
    user = Client.loginUser(username, password)

    # preallocate data structures and variables
    cash_data = Float64[]
    inventory_data = Float64[]
    # bid_quote_data = Float64[]
    # ask_quote_data = Float64[]
    # S_bid_data = Float64[]
    # S_ask_data = Float64[]
    # mid_price_data = Float64[]
    # time_trade_data = DateTime[]
    new_bid = [0.0 0.0 0.0]
    new_ask = [0.0 0.0 0.0]

    # instantiate dynamic variables
    P_last = 0
    # z = 0
    # cash = 0

    # hold off trading until the market opens
    if Dates.now() < market_open
        @info "(Random MM) Waiting until market open..."
        pre_market_time = Dates.value(market_open - now()) / 1000 # convert to secs
        sleep(pre_market_time)
    end

    # execute trades until the market closes
    @info "(Random MM) Initiating trade sequence now."
    while Dates.now() < market_close
        # check stopping condition
        if Dates.now() > market_close
            break
        end

        # retrieve current market conditions (current mid-price and side-spread)
        P_t, S_ref_0 = get_price_details(ticker)
        new_bid[1] = P_t
        new_ask[1] = P_t
        new_bid[2] = S_ref_0
        new_ask[2] = S_ref_0

        # check variables
        println("========================")
        println("")
        println("P_t = ", P_t)
        println("P_last = ", P_last)
        println("S_ref_0 = ", S_ref_0)

        println("z = ", z)
        println("cash = ", cash)

        #----- Pricing Policy -----#
        # determine how far from S_ref_0 to place quote

        # Set buy and sell ϵ values
        ϵ_buy = round(rand(Uniform(ϵ_min, ϵ_max)), digits = 2)
        ϵ_sell = round(rand(Uniform(ϵ_min, ϵ_max)), digits = 2)
        new_bid[3] = ϵ_buy
        new_ask[3] = ϵ_sell

        # execute actions (submit quotes)
        println("ϵ_buy = $(ϵ_buy), ϵ_sell = $(ϵ_sell)")
        P_bid = P_t - round(S_ref_0*(1 + ϵ_buy), digits=2); P_ask = P_t + round(S_ref_0*(1 + ϵ_sell), digits=2)
        P_bid = round(P_bid, digits=2)
        P_ask = round(P_ask, digits=2)
        P_bid == P_ask ? continue : nothing # avoid error
        # SUBMIT QUOTES
        # post ask quote
        order_id = Exchange.ORDER_ID_COUNTER[] += 1
        order_id *= -1
        println("SELL: price = $(P_ask), size = $(unit_trade_size).")
        order = Client.provideLiquidity(ticker,order_id,"SELL_ORDER",P_ask,unit_trade_size,id)
        # post bid quote
        order_id = Exchange.ORDER_ID_COUNTER[] += 1
        println("BUY: price = $(P_bid), size = $(unit_trade_size).")
        order = Client.provideLiquidity(ticker,order_id,"BUY_ORDER",P_bid,unit_trade_size,id)

        #----- Hedging Policy -----#
        # Determine the fraction of current inventory to hedge (by initiating offsetting trade)

        # set the hedge fraction
        x_frac = round(rand(Uniform()), digits = 2)

        # execute actions (submit hedge trades)
        order_size = round(Int, (x_frac*z))
        if !iszero(order_size) && z > 0
            # positive inventory -> hedge via sell order
            println("Hedge sell order -> sell $(order_size) shares")
            # SUBMIT SELL MARKET ORDER
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            order_id *= -1
            order = Client.hedgeTrade(ticker,order_id,"SELL_ORDER",order_size,id)
            # UPDATE z
            println("Inventory z = $(z) -> z = $(z - order_size)")
            z -= order_size
            # UPDATE cash (not accurate, temporary fix)
            bid_price, _ = Client.getBidAsk(ticker)
            cash += order_size*bid_price
            cash = round(cash, digits=2)
        elseif !iszero(order_size) && z < 0
            # negative inventory -> hedge via buy order
            order_size = -order_size
            println("Hedge buy order -> buy $(order_size) shares")
            # SUBMIT BUY MARKET ORDER
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            order = Client.hedgeTrade(ticker,order_id,"BUY_ORDER",order_size,id)
            # UPDATE z
            println("Inventory z = $(z) -> z = $(z + order_size)")
            z += order_size
            # UPDATE cash (not accurate, temporary fix)
            _, ask_price = Client.getBidAsk(ticker)
            cash -= order_size*ask_price
            cash = round(cash, digits=2)
        end

        # wait 'trade_freq' seconds and reset data structures
        sleep(trade_freq)
        ν_new_bid = [unit_trade_size]
        ν_new_ask = [unit_trade_size]

        #----- Update Step -----#

        # retrieve data for (potentially) unfilled buy order
        active_buy_orders = Client.getActiveBuyOrders(id, ticker)
        for i in eachindex(active_buy_orders)
            # retrieve order
            unfilled_buy = (active_buy_orders[i])[2]
            # cancel unfilled order
            cancel_order = Client.cancelQuote(ticker,unfilled_buy.orderid,"BUY_ORDER",unfilled_buy.price,id)
            # store data
            ν_new_bid[1] = unit_trade_size - unfilled_buy.size
        end

        # retrieve data for (potentially) unfilled sell order
        active_sell_orders = Client.getActiveSellOrders(id, ticker)
        for i in eachindex(active_sell_orders)
            # retrieve order
            unfilled_sell = (active_sell_orders[i])[2]
            # cancel unfilled order
            cancel_order = Client.cancelQuote(ticker,unfilled_sell.orderid,"SELL_ORDER",unfilled_sell.price,id)
            # store data
            ν_new_ask[1] = unit_trade_size - unfilled_sell.size
        end

        # adjust cash and inventory
        cash, z = update_init_cash_inventory(cash, z, P_t, S_ref_0, ν_new_bid,
                                        new_bid[3], ν_new_ask, new_ask[3])

        # compute and store cash and inventory data
        if collect_data == true
            push!(cash_data, cash)
            push!(inventory_data, z)
        end
    end
    @info "(Random MM) Trade sequence complete."

    # clear inventory
    order_size = z
    if !iszero(order_size) && z > 0
        # positive inventory -> hedge via sell order
        println("Hedge sell order -> sell $(order_size) shares")
        # SUBMIT SELL MARKET ORDER
        order_id = Exchange.ORDER_ID_COUNTER[] += 1
        order_id *= -1
        order = Client.hedgeTrade(ticker,order_id,"SELL_ORDER",order_size,id)
        # UPDATE z
        println("Inventory z = $(z) -> z = $(z - order_size)")
        z -= order_size
        # UPDATE cash (not accurate, temporary fix)
        bid_price, _ = Client.getBidAsk(ticker)
        cash += order_size*bid_price
        cash = round(cash, digits=2)
        println("profit = ", cash)
    elseif !iszero(order_size) && z < 0
        # negative inventory -> hedge via buy order
        order_size = -order_size
        println("Hedge buy order -> buy $(order_size) shares")
        # SUBMIT BUY MARKET ORDER
        order_id = Exchange.ORDER_ID_COUNTER[] += 1
        order = Client.hedgeTrade(ticker,order_id,"BUY_ORDER",order_size,id)
        # UPDATE z
        println("Inventory z = $(z) -> z = $(z + order_size)")
        z += order_size
        # UPDATE cash (not accurate, temporary fix)
        _, ask_price = Client.getBidAsk(ticker)
        cash -= order_size*ask_price
        cash = round(cash, digits=2)
        println("profit = ", cash)
    end

    # compute and store cash and inventory data
    if collect_data == true
        push!(cash_data, cash)
        push!(inventory_data, z)
    end

    # Data collection
    if collect_data == true
        # for cash and inventory - prepare tabular dataset
        cash_inv_data = DataFrame(cash_dt = cash_data, inv_dt = inventory_data)
        # for cash and inventory - create save path
        cash_inv_savepath = mkpath("../../Data/ABMs/Exchange/cash_inv")
        # for cash and inventory - save data
        CSV.write("$(cash_inv_savepath)/random_cash_inv_data_id$(id).csv", cash_inv_data)
    end
end