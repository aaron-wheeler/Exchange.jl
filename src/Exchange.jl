module Exchange

using Brokerage, Distributions, Dates, Random

const ORDER_ID_COUNTER = Ref{Int64}(0)

include("SimpleMarketMaker.jl")
include("ZeroHFTrader.jl")
include("AdaptiveMarketMaker.jl")

export MM_run!, HFT_run!, AdaptiveMM_run!

end
