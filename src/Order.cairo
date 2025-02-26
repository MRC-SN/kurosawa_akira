use core::traits::Into;
use starknet::ContractAddress;
use serde::Serde;
use array::SpanTrait;
use starknet::{get_block_timestamp};
use kurosawa_akira::utils::common::{min,DisplayContractAddress};


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Hash)]
struct GasFee {
    gas_per_action: u32,
    fee_token: ContractAddress,
    max_gas_price: u256,
    conversion_rate: (u256, u256),
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq,Hash)]
struct FixedFee {
    recipient: ContractAddress,
    maker_pbips: u32,
    taker_pbips: u32,
    apply_to_receipt_amount:bool
}


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq,Hash)]
struct OrderFee {
    trade_fee: FixedFee,
    router_fee: FixedFee,
    gas_fee: GasFee,
}


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq,Hash)]
struct OrderFlags {
    full_fill_only: bool, 
    best_level_only: bool,
    post_only: bool,
    is_sell_side: bool,
    is_market_order: bool,
    to_ecosystem_book: bool,
    external_funds: bool
}


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq,Hash)]
enum TakerSelfTradePreventionMode {
    NONE, // allow self trading
    EXPIRE_TAKER, // on contract side wont allow orders to match if they have same order signer, on exchange expiring remaining qty of taker
    EXPIRE_MAKER, // on contract side wont allow orders to match if they have same order signer, on exchange expiring remaining qty of maker's orders
    EXPIRE_BOTH, // on contract side wont allow orders to match, on exchange expiring remaining qty of taker and makers orders
} // semantic take place only depending on takers' order mode


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq,Hash)]
struct Quantity {
    base_qty: u256, // qunatity in base asset raw amount
    quote_qty: u256, // quantity in quote asset raw amount
    base_asset: u256 // raw amount of base asset representing 1, eg 1 eth is 10**18
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq,Hash)]
struct Constraints {
    number_of_swaps_allowed: u16, // if order is taker, one can limit maximum number of trades can happens with this taker order (necesasry becase taker order incur gas fees)
    duration_valid: u32, // epoch tine in seconds, time when order becomes invalid
    created_at: u32, // epoch time in seconds, time when order was created by user
    stp: TakerSelfTradePreventionMode,
    nonce: u32, // maker nonce, for order be valid this nonce must be >= in Nonce component
    min_receive_amount: u256, // minimal amount that user willing to receive from the full mstching of order, default value 0, for now defined for router takers, serves as slippage that filtered on exchange
    router_signer: ContractAddress // if taker order is router aka trader outside of our ecosystem then this is router that router this trader to us
    //depends_on:felt252 // order on fill of order it depends on
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq,Hash)]
struct Order {
    maker: ContractAddress, // trading account that created order
    price: u256, // price in quote asset raw amount, for taker order serves as protection price, for passive order execution price, might be zero
    qty: Quantity, // quote qty
    ticker: (ContractAddress, ContractAddress), // (base asset address, quote asset address) eg ETH/USDC
    fee: OrderFee, // order fees that user must fulfill once trade happens
    constraints: Constraints,
    salt: felt252, // random salt for security
    flags: OrderFlags, // various order flags of order
    source: felt252, // source of liquidity
    sign_scheme:felt252 // sign scheme used to sign order
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq,Hash)]
struct SimpleOrder {
    price: u256, // protection price in quote asset raw amount, for security
    base_asset: u256,  // omit Quantity since inferred by previous orders
    ticker: (ContractAddress, ContractAddress), // (base asset address, quote asset address) eg ETH/USDC
    is_sell_side:bool,
}

#[derive(Copy, Drop, Serde, PartialEq)]
struct SignedOrder {
    order: Order,
    sign: Span<felt252>, // makers' signer signature of poseidon hash of order,
    router_sign: (felt252,felt252) // router_signer signature of poseidon hash of order in case of router taker order, else (0, 0)
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct OrderTradeInfo {
    filled_base_amount: u256, // filled amount in base asset
    filled_quote_amount: u256, // filled amount in quote qty
    last_traded_px: u256,
    num_trades_happened: u16,
    as_taker_completed: bool,
    is_sell_side:bool
}


fn get_feeable_qty(fixed_fee: FixedFee, feeable_qty: u256, is_maker:bool) -> u256 {
    let pbips = if is_maker {fixed_fee.maker_pbips} else {fixed_fee.taker_pbips};
    if pbips == 0 { return 0;}
    return (feeable_qty * pbips.into() - 1) / 1_000_000 + 1;
}

fn get_limit_px(maker_order:Order, maker_fill_info:OrderTradeInfo) ->  u256{  //TODO: and qty rename
    let settle_px = if maker_fill_info.filled_base_amount > 0 || maker_fill_info.filled_quote_amount > 0 {maker_fill_info.last_traded_px} else {maker_order.price};
    return settle_px; 
}

fn get_available_base_qty(settle_px:u256, qty:Quantity, fill_info: OrderTradeInfo) -> u256 {
    // calculate available qty in base asset that fulfillable
    // if base_qty not specified it is defined by quote_qty
    // elif quote_qty not specified it is defined by base_qty
    // if both specified takes the minimum
    // eg ETH/USDC
    // buy order -> buy base asset in return for quote asset
    // sell order -> buy quote asset in return for base asset
    let quote_qty_by_quote_asset = if qty.quote_qty > 0 {
        assert!(qty.quote_qty >= fill_info.filled_quote_amount, "Order already filled by quote quote {} filled {}",
                qty.quote_qty, fill_info.filled_quote_amount);
        qty.base_asset * (qty.quote_qty - fill_info.filled_quote_amount)  / settle_px } else {0};
    let quote_qty_by_base_asset  = if qty.base_qty > 0 { 
        assert!(qty.base_qty >= fill_info.filled_base_amount, "Order already filled by base base {} filled {}",
                qty.base_qty, fill_info.filled_base_amount);
        qty.base_qty - fill_info.filled_base_amount} else {0};
    if (qty.base_qty == 0)  { return quote_qty_by_quote_asset; }
    if (qty.quote_qty == 0) { return quote_qty_by_base_asset; }
    return min(quote_qty_by_quote_asset, quote_qty_by_base_asset);
}

fn do_taker_price_checks(taker_order:Order, settle_px:u256, taker_fill_info:OrderTradeInfo) -> u256 {
    assert!(taker_order.flags.is_sell_side || settle_px <= taker_order.price, "BUY_PROTECTION_PRICE_FAILED: settle_px ({}) <= taker_order.price ({})", settle_px, taker_order.price);
    assert!(!taker_order.flags.is_sell_side || settle_px >= taker_order.price, "SELL_PROTECTION_PRICE_FAILED: settle_px ({}) >= taker_order.price ({})", settle_px, taker_order.price); 

    if taker_fill_info.filled_base_amount > 0 || taker_fill_info.filled_quote_amount > 0 {
        let last_traded_px = taker_fill_info.last_traded_px;
        if taker_order.flags.best_level_only { assert!(last_traded_px == settle_px , "BEST_LVL_ONLY: failed last_traded_px ({}) == settle_px ({})", last_traded_px, settle_px);}
        else {
            if !taker_order.flags.is_sell_side { assert!(last_traded_px <= settle_px, "BUY_PARTIAL_FILL_ERR: failed last_traded_px ({}) <= settle_px ({})", last_traded_px, settle_px);} 
            else { assert!(last_traded_px >= settle_px, "SELL_PARTIAL_FILL_ERR: failed last_traded_px ({}) >= settle_px ({})", last_traded_px, settle_px);}
        }
    }
    let rem = get_available_base_qty(settle_px, taker_order.qty, taker_fill_info);
    assert!(rem > 0, "FILLED_TAKER_ORDER");

    return rem;
}

fn do_maker_checks(maker_order:Order, maker_fill_info:OrderTradeInfo, nonce:u32,fee_recipient:ContractAddress)-> (u256, u256) {
    assert!(maker_order.fee.trade_fee.recipient == fee_recipient, "WRONG_MAKER_FEE_RECIPIENT: expected {} got {}", fee_recipient, maker_order.fee.trade_fee.recipient);
    assert!(!maker_order.flags.is_market_order, "WRONG_MARKET_TYPE");
    let settle_px = get_limit_px(maker_order, maker_fill_info);
    let remaining = get_available_base_qty(settle_px, maker_order.qty, maker_fill_info);
    assert!(remaining > 0, "MAKER_ALREADY_FILLED_BY_BASE: remaining = ({})", remaining);
    assert!(maker_order.constraints.nonce >= nonce, "OLD_MAKER_NONCE: failed maker_order.nonce ({}) >= nonce ({})", maker_order.constraints.nonce, nonce);
    assert!(!maker_order.flags.full_fill_only, "WRONG_MAKER_FLAG: maker_order can't be full_fill_only");
    assert!(get_block_timestamp() < maker_order.constraints.created_at.into() + maker_order.constraints.duration_valid.into(), "Maker order expire {}", maker_order.constraints.duration_valid);
    if maker_order.flags.post_only {
        assert!(!maker_order.flags.best_level_only, "WRONG_MAKER_FLAGS");
    }
    assert(!maker_order.flags.external_funds, 'MAKER_ALWAYS_NOT_EXTERNAL');
    return (settle_px, remaining); 
}


fn generic_taker_check(taker_order:Order, taker_fill_info:OrderTradeInfo, nonce:u32, swaps:u16, taker_order_hash:felt252, fee_recipient:ContractAddress) {
    assert!(taker_order.fee.trade_fee.recipient == fee_recipient, "WRONG_TAKER_FEE_RECIPIENT: expected {} got {}", fee_recipient, taker_order.fee.trade_fee.recipient);
    assert!(taker_order.constraints.number_of_swaps_allowed >= taker_fill_info.num_trades_happened + swaps, "HIT_SWAPS_ALLOWED");
    assert!(!taker_order.flags.post_only, "WRONG_TAKER_FLAG");
    assert!(taker_order.constraints.nonce >= nonce, "OLD_TAKER_NONCE");
    assert!(!taker_fill_info.as_taker_completed, "Taker order {} marked completed", taker_order_hash);
    assert!(get_block_timestamp() <  taker_order.constraints.created_at.into() + taker_order.constraints.duration_valid.into(), "Taker order expire {}", taker_order.constraints.duration_valid);
}

fn generic_common_check(maker_order:Order, taker_order:Order) {
    assert!(taker_order.flags.is_sell_side != maker_order.flags.is_sell_side, "WRONG_SIDE");
    assert!(taker_order.ticker == maker_order.ticker, "MISMATCH_TICKER");
    assert!(taker_order.flags.to_ecosystem_book == maker_order.flags.to_ecosystem_book, "MISMATCH_BOOK_DESTINATION");
    assert!(taker_order.qty.base_asset == maker_order.qty.base_asset, "WRONG_ASSET_AMOUNT");
}


fn get_gas_fee_and_coin(gas_fee: GasFee, cur_gas_price: u256, native_token:ContractAddress, cur_gas_per_action:u32, times:u16) -> (u256, ContractAddress) {
    if cur_gas_price == 0 { return (0, native_token);}
    if gas_fee.gas_per_action == 0 { return (0, native_token);}
    assert!(gas_fee.max_gas_price >= cur_gas_price, "Failed: max_gas_price ({}) >= cur_gas_price ({})", gas_fee.max_gas_price, cur_gas_price);
    assert!(gas_fee.gas_per_action >= cur_gas_per_action, "Failed: gas_per_action ({}) >= cur_gas_per_action ({})", gas_fee.gas_per_action, cur_gas_per_action);
    
    let spend_native = cur_gas_per_action.into() * cur_gas_price;
    
    if gas_fee.fee_token == native_token {
        return (spend_native, native_token);
    }

    let (r0, r1) = gas_fee.conversion_rate;
    let spend_converted = spend_native * r1 / r0;
    return (spend_converted * times.into(), gas_fee.fee_token);
}