using Exchange, Dates

## Example use case
parameters = (
    volume_location = 50, # location for order size distribution
    volume_scale = 10, # scale for order size distribution
    volume_shape = 1, # shape for order size distribution
    scale_depth = 2.5, # amplifies the effects caused by OB_imbalance
    orderid = 1234, # arbitrary (for now)
    pareto_threshold = 0.12 # activate ~ 80% of the time
)

server_info = (
    host_ip_address = "0.0.0.0",
    port = "8080",
    username = "Market Maker",
    password = "liquidity123"
)

ticker = 1
market_open = Dates.now() + Dates.Second(20) # DateTime(2022,7,19,13,19,41,036)
market_close = market_open + Dates.Second(5)

MM_run(ticker, market_open, market_close, parameters, server_info)

# include("test/example_run.jl")