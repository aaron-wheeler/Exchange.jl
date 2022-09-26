using Brokerage, Distributions, Dates, Random

max_price_dev(mid_price, tick_size, contra_side) = round((mid_price + (tick_size*contra_side)); digits=2)

function produce_bid_quote(bid_price, ask_price, spread, init_hist_volatility, price_μ, price_θ, tick_size, volume_α, volume_β)
    mid_price = (bid_price + ask_price)/2.0
    # DETERMINE LIMIT PRICE
    θ = price_θ + init_hist_volatility
    price_dev = round((rand(Gumbel(price_μ, θ)) / 100.0); digits=2)
    bid_price_sample = round((ask_price - spread - price_dev); digits=2)
    new_bid_price = bid_price_sample < mid_price ? bid_price_sample : max_price_dev(mid_price, tick_size, -1)
    # DETERMINE VOLUME
    new_tick_diff = round(Int, (bid_price - new_bid_price)*100.0)
    vol_draw = pdf(Beta(volume_α, volume_β), tick_size*new_tick_diff)
    order_size = floor(Int, 10*(10^(1+vol_draw)))
    return new_bid_price, order_size
end

function produce_ask_quote(bid_price, ask_price, spread, init_hist_volatility, price_μ, price_θ, tick_size, volume_α, volume_β)
    mid_price = (bid_price + ask_price)/2.0
    # DETERMINE LIMIT PRICE
    θ = price_θ + init_hist_volatility
    price_dev = round((rand(Gumbel(price_μ, θ)) / 100.0); digits=2)
    ask_price_sample = round((price_dev + spread + bid_price); digits=2)
    new_ask_price = ask_price_sample > mid_price ? ask_price_sample : max_price_dev(mid_price, tick_size, 1)
    # DETERMINE VOLUME
    new_tick_diff = round(Int, (new_ask_price - ask_price)*100.0)
    vol_draw = pdf(Beta(volume_α, volume_β), tick_size*new_tick_diff)
    order_size = floor(Int, 10*(10^(1+vol_draw)))
    return new_ask_price, order_size
end

function search_bid_quotes(bid_price, active_buy_orders)
    best_bid_price = 0.0
    worst_bid_price = bid_price
    best_quote_id = 0
    worst_quote_id = 0
    for i in eachindex(active_buy_orders)
        order = (active_buy_orders[i])[2]
        if order.price ≥ best_bid_price
            best_bid_price = order.price
            best_quote_id = order.orderid
        end
        if order.price ≤ worst_bid_price
            worst_bid_price = order.price
            worst_quote_id = order.orderid
        end
    end
    return best_bid_price, worst_bid_price, best_quote_id, worst_quote_id
end

function search_ask_quotes(ask_price, active_sell_orders)
    best_ask_price = ask_price
    worst_ask_price = 0.0
    best_quote_id = 0
    worst_quote_id = 0
    for i in eachindex(active_sell_orders)
        order = (active_sell_orders[i])[2]
        if order.price ≤ best_ask_price
            best_ask_price = order.price
            best_quote_id = order.orderid
        end
        if order.price ≥ worst_ask_price
            worst_ask_price = order.price
            worst_quote_id = order.orderid
        end
    end
    return best_ask_price, worst_ask_price, best_quote_id, worst_quote_id
end

function post_contra_ask_quote!(ticker, id, tick_size)
    bid_price, ask_price, spread = get_LOB_details(ticker)
    active_sell_orders = Client.getActiveSellOrders(id, ticker)
    limit_size = 100 # default min HFT volume
    if !isempty(active_sell_orders)
        best_ask_price, worst_ask_price, best_quote_id, worst_quote_id = search_ask_quotes(ask_price, active_sell_orders)
        if spread ≤ 0.05
            # close spread, passive contra order
            if best_ask_price == ask_price
                return
            else
                # place contra order
                order_id = Exchange.ORDER_ID_COUNTER[] += 1
                order_id *= -1
                # println("SELL: price = $(ask_price), size = $(limit_size).")
                sell_order = Client.provideLiquidity(ticker,order_id,"SELL_ORDER",ask_price,limit_size,id)
                # cancel next closest ask
                cancel_order = Client.cancelQuote(ticker,best_quote_id,"SELL_ORDER",best_ask_price, id)
            end
        else
            # large spread, aggressive contra order
            μ = tick_size # distribution mean
            λ = tick_size / (1 + spread) # distribution shape
            # upper bound of distribution increases with spread
            contra_price_dev = round(rand((InverseGaussian(μ, λ))); digits=2)
            contra_ask_sample = round((contra_price_dev + spread + bid_price); digits=2)
            mid_price = (bid_price + ask_price) / 2.0
            half_mid_ask = (mid_price + ask_price) / 2.0
            new_ask_price = contra_ask_sample > half_mid_ask ? contra_ask_sample : max_price_dev(half_mid_ask, tick_size, 1)
            # place contra order
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            order_id *= -1
            # println("SELL: price = $(new_ask_price), size = $(limit_size).")
            sell_order = Client.provideLiquidity(ticker,order_id,"SELL_ORDER",new_ask_price,limit_size,id)
            # cancel next closest ask
            cancel_order = Client.cancelQuote(ticker,best_quote_id,"SELL_ORDER",best_ask_price, id)
        end
    else
        # no existing sell orders in book
        if spread ≤ 0.05
            # place passive contra order
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            order_id *= -1
            # println("SELL: price = $(ask_price), size = $(limit_size).")
            sell_order = Client.provideLiquidity(ticker,order_id,"SELL_ORDER",ask_price,limit_size,id)
        else
            # place aggressive contra order
            μ = tick_size # distribution mean
            λ = tick_size / (1 + spread) # distribution shape
            # upper bound of distribution increases with spread
            contra_price_dev = round(rand((InverseGaussian(μ, λ))); digits=2)
            contra_ask_sample = round((contra_price_dev + spread + bid_price); digits=2)
            mid_price = (bid_price + ask_price) / 2.0
            half_mid_ask = (mid_price + ask_price) / 2.0
            new_ask_price = contra_ask_sample > half_mid_ask ? contra_ask_sample : max_price_dev(half_mid_ask, tick_size, 1)
            # place contra order
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            order_id *= -1
            # println("SELL: price = $(new_ask_price), size = $(limit_size).")
            sell_order = Client.provideLiquidity(ticker,order_id,"SELL_ORDER",new_ask_price,limit_size,id)
        end
    end
end

function post_contra_bid_quote!(ticker, id, tick_size)
    bid_price, ask_price, spread = get_LOB_details(ticker)
    active_buy_orders = Client.getActiveBuyOrders(id, ticker)
    limit_size = 100 # default min HFT volume
    if !isempty(active_buy_orders)
        best_bid_price, worst_bid_price, best_quote_id, worst_quote_id = search_bid_quotes(bid_price, active_buy_orders)
        if spread ≤ 0.05
            # close spread, passive contra order
            if best_bid_price == bid_price
                return
            else
                # place contra order
                order_id = Exchange.ORDER_ID_COUNTER[] += 1
                # println("BUY: price = $(bid_price), size = $(limit_size).")
                buy_order = Client.provideLiquidity(ticker,order_id,"BUY_ORDER",bid_price,limit_size,id)
                # cancel next closest bid
                cancel_order = Client.cancelQuote(ticker,best_quote_id,"BUY_ORDER",best_bid_price, id)
            end
        else
            # large spread, aggressive contra order
            μ = tick_size # distribution mean
            λ = tick_size / (1 + spread) # distribution shape
            # upper bound of distribution increases with spread
            contra_price_dev = round(rand((InverseGaussian(μ, λ))); digits=2)
            contra_bid_sample = round((ask_price - spread - contra_price_dev); digits=2)
            mid_price = (bid_price + ask_price) / 2.0
            half_mid_bid = (mid_price + bid_price) / 2.0
            new_bid_price = contra_bid_sample < half_mid_bid ? contra_bid_sample : max_price_dev(half_mid_bid, tick_size, -1)
            # place contra order
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            # println("BUY: price = $(new_bid_price), size = $(limit_size).")
            buy_order = Client.provideLiquidity(ticker,order_id,"BUY_ORDER",new_bid_price,limit_size,id)
            # cancel next closest bid
            cancel_order = Client.cancelQuote(ticker,best_quote_id,"BUY_ORDER",best_bid_price, id)
        end
    else
        # no existing buy orders in book
        if spread ≤ 0.05
            # place passive contra order
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            # println("BUY: price = $(bid_price), size = $(limit_size).")
            buy_order = Client.provideLiquidity(ticker,order_id,"BUY_ORDER",bid_price,limit_size,id)
        else
            # place aggressive contra order
            μ = tick_size # distribution mean
            λ = tick_size / (1 + spread) # distribution shape
            # upper bound of distribution increases with spread
            contra_price_dev = round(rand((InverseGaussian(μ, λ))); digits=2)
            contra_bid_sample = round((ask_price - spread - contra_price_dev); digits=2)
            mid_price = (bid_price + ask_price) / 2.0
            half_mid_bid = (mid_price + bid_price) / 2.0
            new_bid_price = contra_bid_sample < half_mid_bid ? contra_bid_sample : max_price_dev(half_mid_bid, tick_size, -1)
            # place contra order
            order_id = Exchange.ORDER_ID_COUNTER[] += 1
            # println("BUY: price = $(new_bid_price), size = $(limit_size).")
            buy_order = Client.provideLiquidity(ticker,order_id,"BUY_ORDER",new_bid_price,limit_size,id)
        end
    end
end

# ======================================================================================== #

function HFT_run!(num_tickers, num_HFT, market_open, market_close, parameters, server_info)
    # unpack parameters
    prob_activation,init_hist_volatility,price_μ,price_θ,tick_size,volume_α,volume_β = parameters
    host_ip_address, port, username, password = server_info

    # connect to brokerage
    url = "http://$(host_ip_address):$(port)"
    Client.SERVER[] = url
    Client.createUser(username, password)
    user = Client.loginUser(username, password)

    # preallocate trading vectors
    @assert num_HFT < (Mapper.MM_COUNTER - num_tickers)
    HFT_id = collect(Int, (num_tickers + 1):(num_HFT + num_tickers))
    risk_aversion = [rand(Uniform()) for i in 1:num_HFT] # inventory risk tolerance
    ticker_list = collect(Int, 1:num_tickers)

    # hold off trading until the market opens
    if Dates.now() < market_open
        @info "(HFTrader) Waiting until market open..."
        pre_market_time = Dates.value(market_open - now()) / 1000 # convert to secs
        sleep(pre_market_time)
    end

    # execute trades until the market closes
    @info "(HFTrader) Initiating trade sequence now."
    while Dates.now() < market_close
        # determine order of HFTrader trading sequence
        shuffle!(HFT_id)
        for i in eachindex(HFT_id)
            id = HFT_id[i]
            index = HFT_id[i] - num_tickers
            # determine order of tickers to trade
            shuffle!(ticker_list)
            for j in eachindex(ticker_list)
                ticker = ticker_list[j]
                # check for sufficient trading conditions
                bid_price, ask_price, spread = get_LOB_details(ticker)
                if rand() < prob_activation && spread > 0.02
                    # determine main order side
                    main_order_side = rand() < 0.5 ? 1 : -1
                    if main_order_side > 0
                        # MAIN BUY ORDER
                        # determine if orders are to be stacked based on trader risk tolerance
                        if rand() ≤ risk_aversion[index]
                            # do not stack orders, replace with existing order
                            active_buy_orders = Client.getActiveBuyOrders(id, ticker)
                            # place main buy order
                            limit_price, limit_size = produce_bid_quote(bid_price, ask_price, spread, init_hist_volatility, price_μ, price_θ, tick_size, volume_α, volume_β)
                            order_id = Exchange.ORDER_ID_COUNTER[] += 1
                            # println("BUY: price = $(limit_price), size = $(limit_size).")
                            buy_order = Client.provideLiquidity(ticker,order_id,"BUY_ORDER",limit_price,limit_size,id)
                            if !isempty(active_buy_orders)
                                # cancel order to hedge inventory risk
                                best_bid_price, worst_bid_price, best_quote_id, worst_quote_id = search_bid_quotes(bid_price, active_buy_orders)
                                if limit_price < best_bid_price
                                    # passive; cancel existing bid side (BUY) limit order closest to top of book
                                    cancel_order = Client.cancelQuote(ticker,best_quote_id,"BUY_ORDER",best_bid_price, id)
                                elseif limit_price < best_bid_price
                                    # aggressive; cancel existing bid side (BUY) limit order randomly
                                    void_buy = rand(active_buy_orders)[2]
                                    cancel_order = Client.cancelQuote(ticker,void_buy.orderid,"BUY_ORDER",void_buy.price, id)
                                    # aggressive; cancel existing bid side (BUY) limit order furthest from top of book
                                    # cancel_order = Client.cancelQuote(ticker,worst_quote_id,"BUY_ORDER",worst_bid_price, id)
                                end
                            end
                        else
                            # stack orders, add main buy order
                            limit_price, limit_size = produce_bid_quote(bid_price, ask_price, spread, init_hist_volatility, price_μ, price_θ, tick_size, volume_α, volume_β)
                            order_id = Exchange.ORDER_ID_COUNTER[] += 1
                            # println("BUY: price = $(limit_price), size = $(limit_size).")
                            buy_order = Client.provideLiquidity(ticker,order_id,"BUY_ORDER",limit_price,limit_size,id)
                        end
                        # CONTRA SELL ORDER
                        post_contra_ask_quote!(ticker, id, tick_size)
                    else
                        # MAIN SELL ORDER
                        # determine if orders are to be stacked based on trader risk tolerance
                        if rand() ≤ risk_aversion[index]
                            # do not stack orders, replace with existing order
                            active_sell_orders = Client.getActiveSellOrders(id, ticker)
                            # place main sell order
                            limit_price, limit_size = produce_ask_quote(bid_price, ask_price, spread, init_hist_volatility, price_μ, price_θ, tick_size, volume_α, volume_β)
                            order_id = Exchange.ORDER_ID_COUNTER[] += 1
                            order_id *= -1
                            # println("SELL: price = $(limit_price), size = $(limit_size).")
                            sell_order = Client.provideLiquidity(ticker,order_id,"SELL_ORDER",limit_price,limit_size,id)
                            if !isempty(active_sell_orders)
                                # cancel order to hedge inventory risk
                                best_ask_price, worst_ask_price, best_quote_id, worst_quote_id = search_ask_quotes(ask_price, active_sell_orders)
                                if limit_price > best_ask_price
                                    # passive; cancel existing ask side (SELL) limit order closest to top of book
                                    cancel_order = Client.cancelQuote(ticker,best_quote_id,"SELL_ORDER",best_ask_price, id)
                                elseif limit_price < best_ask_price
                                    # aggressive; cancel existing ask side (SELL) limit order randomly
                                    void_sell = rand(active_sell_orders)[2]
                                    cancel_order = Client.cancelQuote(ticker,void_sell.orderid,"SELL_ORDER",void_sell.price, id)
                                    # aggressive; cancel existing ask side (SELL) limit order furthest from top of book
                                    # cancel_order = Client.cancelQuote(ticker,worst_quote_id,"SELL_ORDER",worst_ask_price, id)
                                end
                            end
                        else
                            # stack orders, add main sell order
                            limit_price, limit_size = produce_ask_quote(bid_price, ask_price, spread, init_hist_volatility, price_μ, price_θ, tick_size, volume_α, volume_β)
                            order_id = Exchange.ORDER_ID_COUNTER[] += 1
                            order_id *= -1
                            # println("SELL: price = $(limit_price), size = $(limit_size).")
                            sell_order = Client.provideLiquidity(ticker,order_id,"SELL_ORDER",limit_price,limit_size,id)
                        end
                        # CONTRA BUY ORDER
                        post_contra_bid_quote!(ticker, id, tick_size)
                    end
                    # check early exit condition
                    if Dates.now() > market_close
                        break
                    end
                end
            end
        end
    end
    @info "(HFTrader) Trade sequence complete."
end