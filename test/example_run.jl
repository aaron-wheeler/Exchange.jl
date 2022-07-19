using Exchange, Dates

## Example use case
parameters = (
    username = "Market Maker",
    password = "liquidity123",
    PL_scale = 2, # scaling factor for power law order size
    min_volume_size = 10, # lower bound of volume size
    scale_depth = 2.5,
    orderid = 1234, # arbitrary (for now)
    pareto_threshold = 0.12 # activate ~ 80% of the time
)

server_info = (
    host_ip_address = "0.0.0.0",
    port = "8080"
)

ticker = 1
market_open = Dates.now() + Dates.Second(20) # DateTime(2022,7,19,13,19,41,036)
market_close = market_open + Dates.Second(5)

MM_run(ticker, market_open, market_close, parameters, server_info)

# include("test/example_run.jl")