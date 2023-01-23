using Brokerage

# ====================================================================== #
# #----- MM Utility functions -----#

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