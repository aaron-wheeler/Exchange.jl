using Brokerage, Distributions, Dates

function get_OB_imbalance(ticker)
    bid_volume, ask_volume = Client.getBidAskVolume(ticker)
    OB_imbalance = (bid_volume - ask_volume) / (bid_volume + ask_volume)
    return OB_imbalance 
end

function get_LOB_details(ticker)
    bid_price, ask_price = Client.getBidAsk(ticker)
    spread = ask_price - bid_price
    return bid_price, ask_price, spread 
end

function PowerLaw(min_volume_size, PL_shape)
    return min_volume_size / (rand() ^ (1 / PL_shape))
end

function MM_run(ticker, market_open, market_close, parameters, server_info)
    # unpack parameters
    username,password,PL_scale,min_volume_size,scale_depth,orderid,pareto_threshold  = parameters
    host_ip_address, port = server_info
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
        @info "Waiting until market open..."
        pre_market_time = Dates.value(market_open - now()) / 1000 # convert to secs
        sleep(pre_market_time)
    end

    # execute trades until the market closes
    @info "Initiating trade sequence now."
    while Dates.now() < market_close
        if rand(prob_activation) < pareto_threshold
            # activate and execute order process
            OB_imbalance = get_OB_imbalance(ticker)
            bid_price, ask_price, spread = get_LOB_details(ticker)
            prob_ask = (1/2)*(OB_imbalance + 1)
    
            if rand() ≤ prob_ask
                # place ask side (SELL) limit order
                gamma_shape = spread
                gamma_scale = exp(OB_imbalance / scale_depth)
                liquidity_demand = trunc(rand(Gamma(gamma_shape, gamma_scale)), digits=2)
                limit_price = bid_price + spread + liquidity_demand
                PL_shape = 1 - (OB_imbalance/PL_scale) # Shape for power law
                limit_size = PowerLaw(min_volume_size, PL_shape)
                # println("SELL: price = $(limit_price), size = $(limit_size).")
                order = Client.provideLiquidity(ticker,orderid,"SELL_ORDER",limit_price,limit_size,id)
            else
                # place bid side (BUY) limit order
                gamma_shape = spread
                gamma_scale = exp(-OB_imbalance / scale_depth)
                liquidity_demand = trunc(rand(Gamma(gamma_shape, gamma_scale)), digits=2)
                limit_price = ask_price - spread - liquidity_demand
                PL_shape = 1 + (OB_imbalance/PL_scale) # Shape for power law
                limit_size = PowerLaw(min_volume_size, PL_shape)
                # println("BUY: price = $(limit_price), size = $(limit_size).")
                order = Client.provideLiquidity(ticker,orderid,"BUY_ORDER",limit_price,limit_size,id)
            end
        end
    end
    @info "Trade sequence complete."
end