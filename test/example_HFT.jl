using Exchange, Dates

## Example use case
parameters = (
    prob_activation = 0.99, # percentage of time that HFTraders actively trade
    init_hist_volatility = 0.2, # starting volatility; constant (for now)
    price_μ = 0.2, # location param for price distribution (Gumbel)
    price_θ = 1.0, # scale param for price distribution (Gumbel)
    tick_size = 0.01, # minimum price tick for underlying asset
    volume_α = 2.0, # shape param for volume distribution (Beta)
    volume_β = 5.0 # shape param for volume distribution (Beta)
)

server_info = (
    host_ip_address = "0.0.0.0",
    port = "8080",
    username = "Market Maker",
    password = "liquidity123"
)

# ticker = 1
# market_open = Dates.now() + Dates.Second(10) # DateTime(2022,7,19,13,19,41,036)
# market_close = market_open + Dates.Second(45)

# MM_run(ticker, market_open, market_close, parameters, server_info)

# include("test/example_HFT.jl")