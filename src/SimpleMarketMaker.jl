using Brokerage, Distributions, Dates

function get_OB_orderflow(ticker)
    bid_volume, ask_volume = Client.getBidAskVolume(ticker)
    OB_imbalance = (bid_volume - ask_volume) / (bid_volume + ask_volume)
    return OB_imbalance, bid_volume, ask_volume 
end

function get_LOB_details(ticker)
    bid_price, ask_price = Client.getBidAsk(ticker)
    spread = ask_price - bid_price
    return bid_price, ask_price, spread 
end

function post_bid_quote!(ticker, OB_imbalance, tick_size, volume_location, volume_scale, volume_shape, equil_scale, id)
    # determine price
    _, ask_price, spread = get_LOB_details(ticker)
    liquidity_mean = max(tick_size, tick_size - OB_imbalance*(spread))
    liquidity_shape = 1.01 + OB_imbalance*(1.0)
    liquidity_demand = round(rand(InverseGaussian(liquidity_mean, liquidity_shape)); digits=2)
    limit_price = round((ask_price - spread - liquidity_demand); digits=2)
    # determine volume
    vol_disparity = 1 + (OB_imbalance)
    equil = ((max(0, 1 - vol_disparity)) * (volume_location))^equil_scale # order book stability term
    limit_size = round(Int, abs(rand(SkewNormal(volume_location, volume_scale+equil, volume_shape+equil))))
    # place order
    order_id = Exchange.ORDER_ID_COUNTER[] += 1
    # println("BUY: price = $(limit_price), size = $(limit_size).")
    order = Client.provideLiquidity(ticker,order_id,"BUY_ORDER",limit_price,limit_size,id)
end

function post_ask_quote!(ticker, OB_imbalance, tick_size, volume_location, volume_scale, volume_shape, equil_scale, id)
    # determine price
    bid_price, _, spread = get_LOB_details(ticker)
    liquidity_mean = max(tick_size, tick_size + OB_imbalance*(spread))
    liquidity_shape = 1.01 - OB_imbalance*(1.0)
    liquidity_demand = round(rand(InverseGaussian(liquidity_mean, liquidity_shape)); digits=2)
    limit_price = round((bid_price + spread + liquidity_demand); digits=2)
    # determine volume
    vol_disparity = 1 - (OB_imbalance)
    equil = ((max(0, 1 - vol_disparity)) * (volume_location))^equil_scale # order book stability term
    limit_size = round(Int, abs(rand(SkewNormal(volume_location, volume_scale+equil, volume_shape+equil))))
    # place order
    order_id = Exchange.ORDER_ID_COUNTER[] += 1
    order_id *= -1
    # println("SELL: price = $(limit_price), size = $(limit_size).")
    order = Client.provideLiquidity(ticker,order_id,"SELL_ORDER",limit_price,limit_size,id)
end

function post_contra_bid_quote!(ticker, OB_imbalance, tick_size, volume_location, volume_scale, volume_shape, equil_scale, id)
    # determine raised price
    _, ask_price, spread = get_LOB_details(ticker)
    liquidity_mean = max(tick_size, tick_size*(1 - OB_imbalance*(spread)))
    liquidity_shape = 1.01 + OB_imbalance*(1.0)
    liquidity_demand = round(rand(InverseGaussian(liquidity_mean, liquidity_shape)); digits=2)
    limit_price = round((ask_price - spread + liquidity_demand); digits=2)
    # determine volume
    vol_disparity = 1 + (OB_imbalance)
    equil = ((max(0, 1 - vol_disparity)) * (volume_location))^equil_scale # order book stability term
    limit_size = round(Int, abs(rand(SkewNormal(volume_location, volume_scale+equil, volume_shape+equil))))
    # place order
    order_id = Exchange.ORDER_ID_COUNTER[] += 1
    # println("CONTRA_BUY: price = $(limit_price), size = $(limit_size).")
    order = Client.provideLiquidity(ticker,order_id,"BUY_ORDER",limit_price,limit_size,id)
end

function post_contra_ask_quote!(ticker, OB_imbalance, tick_size, volume_location, volume_scale, volume_shape, equil_scale, id)
    # determine lower price
    bid_price, _, spread = get_LOB_details(ticker)
    liquidity_mean = max(tick_size, tick_size*(1 + OB_imbalance*(spread)))
    liquidity_shape = 1.01 - OB_imbalance*(1.0)
    liquidity_demand = round(rand(InverseGaussian(liquidity_mean, liquidity_shape)); digits=2)
    limit_price = round((bid_price + spread - liquidity_demand); digits=2)
    # determine volume
    vol_disparity = 1 - (OB_imbalance)
    equil = ((max(0, 1 - vol_disparity)) * (volume_location))^equil_scale # order book stability term
    limit_size = round(Int, abs(rand(SkewNormal(volume_location, volume_scale+equil, volume_shape+equil))))
    # place order
    order_id = Exchange.ORDER_ID_COUNTER[] += 1
    order_id *= -1
    # println("CONTRA_SELL: price = $(limit_price), size = $(limit_size).")
    order = Client.provideLiquidity(ticker,order_id,"SELL_ORDER",limit_price,limit_size,id)
end

# ======================================================================================== #

function MM_run!(ticker, market_open, market_close, parameters, server_info)
    # unpack parameters
    min_side_volume,tick_size,volume_location,volume_scale,volume_shape,equil_scale,pareto_threshold  = parameters
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
        @info "(MM) Waiting until market open..."
        pre_market_time = Dates.value(market_open - now()) / 1000 # convert to secs
        sleep(pre_market_time)
    end

    # execute trades until the market closes
    @info "(MM) Initiating trade sequence now."
    while Dates.now() < market_close
        # Check stability of OB
        OB_imbalance, bid_volume, ask_volume = get_OB_orderflow(ticker)
        if bid_volume ≥ min_side_volume && ask_volume ≥ min_side_volume
            continue
        elseif bid_volume < min_side_volume && ask_volume ≥ min_side_volume
            # place new bid side (BUY) limit order to stabilize OB
            post_bid_quote!(ticker, OB_imbalance, tick_size, volume_location, volume_scale, volume_shape, equil_scale, id)
            # retrieve updated OB_imbalance
            OB_imbalance, _, _ = get_OB_orderflow(ticker)
        elseif ask_volume < min_side_volume && bid_volume ≥ min_side_volume
            # place new ask side (SELL) limit order to stabilize OB
            post_ask_quote!(ticker, OB_imbalance, tick_size, volume_location, volume_scale, volume_shape, equil_scale, id)
            # retrieve updated OB_imbalance
            OB_imbalance, _, _ = get_OB_orderflow(ticker)
        else
            # place new bid side (BUY) and ask side (SELL) limit orders to stabilize OB
            # first, stabilize selloff
            post_bid_quote!(ticker, OB_imbalance, tick_size, volume_location, volume_scale, volume_shape, equil_scale, id)
            # then, stabilize buying spree
            OB_imbalance, _, _ = get_OB_orderflow(ticker) # use updated OB info
            post_ask_quote!(ticker, OB_imbalance, tick_size, volume_location, volume_scale, volume_shape, equil_scale, id)
            # finally, retrieve updated OB_imbalance
            OB_imbalance, _, _ = get_OB_orderflow(ticker)
        end

        # Check if liquidity needed
        _, _, spread = get_LOB_details(ticker)
        if rand(prob_activation) < pareto_threshold && spread > 0.02
            # activate and execute supply & demand order process
            prob_ask = (1/2)*(OB_imbalance + 1)
    
            if rand() ≤ prob_ask
                # place new ask side (SELL) limit order with higher price
                post_ask_quote!(ticker, OB_imbalance, tick_size, volume_location, volume_scale, volume_shape, equil_scale, id)
                # raise price of best bid side (BUY) limit order, TODO: Consider using updated OB_imbalance for contra quote?
                active_buy_orders = Client.getActiveBuyOrders(id, ticker)
                post_contra_bid_quote!(ticker, OB_imbalance, tick_size, volume_location, volume_scale, volume_shape, equil_scale, id)
                # cancel old bid side (BUY) limit order
                if !isempty(active_buy_orders)
                    void_buy = rand(active_buy_orders)[2]
                    cancel_order = Client.cancelQuote(ticker,void_buy.orderid,"BUY_ORDER",void_buy.price, id)
                end
            else
                # place new bid side (BUY) limit order with lower price
                post_bid_quote!(ticker, OB_imbalance, tick_size, volume_location, volume_scale, volume_shape, equil_scale, id)
                # lower price of best ask side (SELL) limit order, TODO: Consider using updated OB_imbalance for contra quote?
                active_sell_orders = Client.getActiveSellOrders(id, ticker)
                post_contra_ask_quote!(ticker, OB_imbalance, tick_size, volume_location, volume_scale, volume_shape, equil_scale, id)
                # cancel old ask side (SELL) limit order
                if !isempty(active_sell_orders)
                    void_sell = rand(active_sell_orders)[2]
                    cancel_order = Client.cancelQuote(ticker,void_sell.orderid,"SELL_ORDER",void_sell.price, id)
                end
            end
        end
    end
    @info "(MM) Trade sequence complete."
end