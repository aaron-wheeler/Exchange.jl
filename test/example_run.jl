using Exchange, Dates

## Example use case
parameters = (
    min_side_volume = 500, # minimum volume always present on either side of OB
    tick_size = 0.01, # minimum price tick for underlying asset
    volume_location = 50, # location for order size distribution
    volume_scale = 10, # scale for order size distribution
    volume_shape = 1, # shape for order size distribution
    equil_scale = 1.2, # scaling factor or order volume equilibration term
    pareto_threshold = 0.12 # 0.12 -> activate ~ 80% of the time, decrease to slow down
)

server_info = (
    host_ip_address = "0.0.0.0",
    port = "8080",
    username = "Market Maker",
    password = "liquidity123"
)

ticker = 1
market_open = Dates.now() + Dates.Second(10) # DateTime(2022,7,19,13,19,41,036)
market_close = market_open + Dates.Second(45)

MM_run(ticker, market_open, market_close, parameters, server_info)

# include("test/example_run.jl")