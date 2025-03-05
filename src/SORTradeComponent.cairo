



use kurosawa_akira::Order::{SignedOrder,Order,SimpleOrder,get_gas_fee_and_coin, OrderTradeInfo, OrderFee, FixedFee,GasFee, OrderFlags, Constraints, Quantity,
            get_feeable_qty,get_limit_px, do_taker_price_checks, do_maker_checks, get_available_base_qty, generic_taker_check,generic_common_check,TakerSelfTradePreventionMode};
use starknet::{ContractAddress};
use core::option::Option;
    
#[starknet::interface]
trait ISORTradeLogic<TContractState> {
    
}


// internal structure used for storing client sored order, up to 5 orders
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct SOR {
    lead:Order, // lead order which defines the begining of complex route
    order0:Option<SimpleOrder>,
    order1:Option<SimpleOrder>,
    order2:Option<SimpleOrder>,
	order3:Option<SimpleOrder>,
	last_order: SimpleOrder, // last order in path
	router_signature_lead:(felt252,felt252),
	allow_nonatomic_processing:bool, // does user allow for his sor to be processed non atomically in separate txs
	trade_fee: FixedFee, // fee incur only on lead or last order, intermediary no charges
    router_fee:FixedFee, // fee incur only on lead or last order, intermediary no charges
    apply_gas_in_first_trade: bool, // gas charged in beg or end leg
    path_len:u8, // len of path excluding lead order
    trades_max:u16, //
    min_receive_amount:u256, // for end leg
    max_spend_amount: u256, // for begining leg
    last_qty:Quantity, // forecasted qty by the user for last order
}
#[derive(Copy, Drop, Serde)]
struct SORDetails { // details supplied with sor sored orders
    lead_qty:Quantity, // forecasted qty by the user
    last_qty:Quantity, // forecasted qty by the user
    trade_fee:FixedFee, // same as in Order
    router_fee:FixedFee,// same as in Order
    gas_fee: GasFee,// same as in Order
    created_at:u32, // same as in Order
    source:felt252, // same as in Order
    allow_nonatomic:bool, // should it be performed atomically or can be split; for large orders might work only splitting due calldata limit sz
    to_ecosystem_book:bool, // same as in Order
    duration_valid:u32,
    nonce:u32, // same as in Order
    external_funds:bool, // same as in Order
    router_signer:ContractAddress, // same as in Order
    salt:felt252, // same as in Order
    sign_scheme:felt252, // same as in Order
    number_of_swaps_allowed: u16, 
    min_receive_amount:u256, // for end leg
    max_spend_amount: u256 // for begining leg
    // target_receive: 
}

#[starknet::component]
mod sor_trade_component {
    use starknet::{get_contract_address, ContractAddress, get_caller_address, get_tx_info, get_block_timestamp};
    use super::{SignedOrder, Order};
    use kurosawa_akira::BaseTradeComponent::base_trade_component as  base_trade_component;
    use base_trade_component::{InternalBaseOrderTradable, BaseOrderTradableImpl};
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl, SNIP12MetadataImpl};
    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcherTrait, ILayerAkiraCoreDispatcher};
    use core::option::Option;
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}


    #[storage]
    struct Storage {
        atomic_taker_info:(felt252, (felt252, felt252)), // hash lock, router sign
        scheduled_taker_order: Order,
        order_hash_to_sor:starknet::storage::Map::<felt252, super::SOR>,
        sor_to_ptr:starknet::storage::Map::<felt252, (u8,bool)>, // index and is failed sor
        atomic_sor:super::SOR,
        core_address:ContractAddress,
    }






    #[embeddable_as(SORTradable)]
    impl SOROrderTradableImpl<TContractState, 
    +HasComponent<TContractState>,
    impl BaseTrade:base_trade_component::HasComponent<TContractState>,
    +Drop<TContractState>> of super::ISORTradeLogic<ComponentState<TContractState>> {}

     #[generate_trait]
    impl InternalSORTradableImpl<TContractState, +HasComponent<TContractState>, +Drop<TContractState> ,
        impl BaseTrade:base_trade_component::HasComponent<TContractState> > of InternalSORTradable<TContractState> {
        
        fn placeTakerOrder(ref self: ComponentState<TContractState>, order: Order, router_sign: (felt252,felt252)) {
            // SNIP-9 place of taker order onchain, rolluper calls account which calls placeTakerOrder
            //  Params:
            //      order: taker order to be filled
            //      router_sign: signature of order if any by router that guarantee correctness of the order   
            assert(order.maker == get_caller_address(), 'Maker must be caller');
            self.acquireLock(router_sign);
            self.scheduled_taker_order.write(order);
        }

        fn fullfillTakerOrder(ref self: ComponentState<TContractState>, mut maker_orders:Array<(SignedOrder, u256)>,
                        total_amount_matched:u256, gas_steps:u32, gas_price:u256) {
            // SNIP-9 execution of taker order onchain
            // rollup MULTICALL: [approve, ..., approve, placeTakerOrder, fullfillTakerOrder]
            //  Params:
            //      maker_orders: array of tuples -- (maker order, base amount matched) against which taker was matched
            //      total_amount_matched: total amount spent by taker in spending token of the trade
            //      gas_steps: actual amount steps to settle 1 trade
            //      gas_price: real gas price per 1 gas
            
            let mut base_trade = get_dep_component_mut!(ref self, BaseTrade);

            let (order, allow_charge_gas_on_receipt, as_taker_filled) = (self.scheduled_taker_order.read(), true, true); 
            let (skip_taker_validation, gas_trades, tfer_taker_recieve_back) = (false, maker_orders.len().try_into().unwrap(), order.flags.external_funds);
            let (_, router_signature) = self.atomic_taker_info.read();
            
            let (succ, taker_hash) = base_trade.apply_single_taker(SignedOrder{ order, sign: array![].span(), router_sign:router_signature}, maker_orders.span(), 
                total_amount_matched, gas_price, gas_steps, as_taker_filled, skip_taker_validation, gas_trades, tfer_taker_recieve_back, allow_charge_gas_on_receipt);
            if succ {base_trade.assert_slippage(taker_hash, 0, order.constraints.min_receive_amount);}

            self.releaseLock();
        }

		fn placeSOROrder(ref self: ComponentState<TContractState>, orchestrate_order:super::SimpleOrder, 
                path:Array<super::SimpleOrder>, router_signature:(felt252, felt252), details:super::SORDetails){
            // SNIP-9 place of sor order (for example, client wants to sell SHIBA for WstETH) and exchange have tickers SHIBA/STRK, ETH/STRK and WstETH/ETH   
            //  Params:
            //      orchestrate_order:  lead order that defined whole sor
            //      path: complex direct straight path that starts from result of orchestrate_order token
            //      router_signature: signature of order if any by router that guarantee correctness of the order 
            //      details: order details supplied to build full taker order inplace from orchestrate_order
            //  Constraints:
            //      - Path is limited to 5 tickers (edges) -- synthethic order mathcing
            //      - First order is defined by external_funds parameter; remaining are in safe determinstic ctx (external_funds==False)
            //      - First order incur router & trade fee, and 0 fees for rest iff fixed fee apply_to_receipt == False
            //      - Last order incur router & trade fee, and 0 fees for rest iff fixed fee apply_to_receipt == True
            //      - Gas for all trades paid only at first trade iff payment token  == spending token or payment token (1)  != last trade receive token (2)
            //      - Gas for all trades paid only at last trade  iff payment token  == last trade receive token
            //      - Gas must be tferred beforehand iff (1) & (2) even if (2) is in path sequence

		    let sz = path.len();
            assert(sz != 0, 'use non bulk'); assert(sz <= 5, 'path is too long');
            assert(details.trade_fee.apply_to_receipt_amount == details.router_fee.apply_to_receipt_amount, 'incorrect apply_to_receipt flag');
            
            // no cycles checked in buildSOR
            let new_sor = self.buildSOR(orchestrate_order, path, router_signature, details);
            
            if (details.allow_nonatomic) {
                let key = new_sor.lead.get_message_hash(new_sor.lead.maker); 
                let sor = self.order_hash_to_sor.read(key);
                assert(sor.lead.maker.try_into().unwrap() == 0, 'sor already existed');
                self.order_hash_to_sor.write(key, new_sor);
            } else {
                 self.acquireLock(router_signature); 
                 self.atomic_sor.write(new_sor);
            }
        }

        fn fulfillSORAtomic(ref self: ComponentState<TContractState>, makers_orders:Array<(SignedOrder,u256)>,
                        total_amount_matched_and_len:Array<(u256, u8)>, gas_steps:u32, gas_price:u256, sor_id:felt252) {
            // SNIP-9 call
            // Allows to fulfill sored client orders atomically within 1 tx
            // Multicall: [approve,..., approve, placeSOROrder, fulfillSORAtomic]
            //  Params:
            //      makers_orders: 1dim array of all maker orders for whole sor (2dim need to avoid use copy)
            //      total_amount_matched_and_len: tuple of <amount sold by client for an order, total trades happend with that order>
            //      gas_steps: actual amount steps to settle 1 trade
            //      gas_price: real gas price per 1 gas
            //      sor_id: 0 if taker order is atomic_only else lead_order hash (exchange attempt to fill non atomic sor orders atomically) 

            // if client set allow non atomic -> exchange can still use fulfillSORAtomic if all trades can fit into one 1 rollup
            let total_trades:u16 = makers_orders.len().try_into().unwrap();
            let sor = if sor_id != 0.try_into().unwrap() {
                let sor = self.order_hash_to_sor.read(sor_id);
                let (head, _) = self.sor_to_ptr.read(sor_id);
                assert(head == 0, 'sor already processed');
                sor
            } else {self.atomic_sor.read()};
            assert(sor.lead.maker != 0x0.try_into().unwrap(), 'sor not initialized');
            assert(total_trades <= sor.trades_max, 'Failed max trades');

            let ((first, last), (total_amount_matched, swaps)) = ((sor.lead, sor.last_order), *total_amount_matched_and_len.at(0));
            
            
            let span_amount_matched = total_amount_matched_and_len.span().slice(1, total_amount_matched_and_len.len() - 1); 
            let (makers_span, fee_recipient) = (makers_orders.span(), first.fee.trade_fee.recipient);
            
            // charge for gas at very first or
            // responsibility of layer akira backend if on last order 
            // if some intermediary force to check if have enough; gas charged from the begining, avoid use receive side  
            let (gas_trades, last_trades) = if sor.apply_gas_in_first_trade {(total_trades,0)} else {(0,total_trades)};
            let (skip_taker_validation, allow_charge_gas_on_receipt, tfer_back_received) = (false, false, false);
            let mut base_trade = get_dep_component_mut!(ref self, BaseTrade);
            
            let (succ, lead_taker_hash) = base_trade.apply_single_taker(
                        SignedOrder{order:first, sign: array![].span(), router_sign:sor.router_signature_lead},
                        makers_span.slice(0, swaps.try_into().unwrap()), total_amount_matched, gas_price, gas_steps, true, 
                            skip_taker_validation, gas_trades, tfer_back_received, allow_charge_gas_on_receipt);
            if succ {base_trade.assert_slippage(sor_id, sor.max_spend_amount, 0);}


            let (zero_trade_fee, zero_router_fee) =  self.getTradeAndRouterFees(sor, false);
            // apply all the orders
            let (mut ptr, mut offset, tfer_taker_recieve_back) = (0, swaps.try_into().unwrap(), false);
            let (ptr1, offset1, __) = self.apply(first, sor.order0, zero_trade_fee, zero_router_fee, ptr, offset, makers_span, span_amount_matched, gas_price, gas_steps, succ, 0, fee_recipient, tfer_taker_recieve_back, lead_taker_hash, Option::None);
            ptr = ptr1; offset = offset1;
            let (ptr1, offset1, __) = self.apply(first, sor.order1, zero_trade_fee, zero_router_fee, ptr, offset, makers_span, span_amount_matched, gas_price, gas_steps, succ, 0, fee_recipient, tfer_taker_recieve_back, lead_taker_hash, Option::None);
            ptr = ptr1; offset = offset1;
            let (ptr1, offset1, __) = self.apply(first, sor.order2, zero_trade_fee, zero_router_fee, ptr, offset, makers_span, span_amount_matched, gas_price, gas_steps, succ, 0, fee_recipient, tfer_taker_recieve_back, lead_taker_hash, Option::None);
            ptr = ptr1; offset = offset1;
            let (ptr1, offset1, __) = self.apply(first, sor.order3, zero_trade_fee, zero_router_fee, ptr, offset, makers_span, span_amount_matched, gas_price, gas_steps, succ, 0, fee_recipient, tfer_taker_recieve_back, lead_taker_hash, Option::None);
            ptr = ptr1; offset = offset1;
            
            let tfer_back_received =  first.flags.external_funds;
            let (last_trade_fee, last_router_fee) = if (sor.trade_fee.apply_to_receipt_amount) {(sor.trade_fee, sor.router_fee)} else {(zero_trade_fee,zero_router_fee)};
            
            
            let (ptr1, offset1, taker_hash) = self.apply(first, Option::Some(last), last_trade_fee, last_router_fee, 
                    ptr, offset, makers_span, span_amount_matched, gas_price, gas_steps, succ, last_trades, fee_recipient, tfer_back_received, lead_taker_hash, Option::Some(sor.last_qty));
            ptr = ptr1; offset = offset1;
            if succ {base_trade.assert_slippage(taker_hash, 0, sor.min_receive_amount);}

            assert(offset == total_trades.into(), 'Mismatch orders count');
            if sor_id != 0.try_into().unwrap() {
                self.sor_to_ptr.write(sor_id, (sor.path_len + 1, !succ)); 
            }  else {
                self.releaseLock();
            }
            
        }


        // SHIBA/STRK STRK/USDC 
        // selling exact SHIBA (specify base)
        // STRK/SHIBA STRK/USDC 
        // 
        //  buy exact


        fn fulfillSORLeadOrder(ref self: ComponentState<TContractState>, sor_id:felt252, makers_orders:Array<(SignedOrder,u256)>,
                        total_amount_matched:u256, gas_steps:u32, gas_price:u256, total_trades:u16) {
            // Allows exchange to fulfill lead order in client sor
            //
            //  Params:
            //      sor_id: lead order hash representing cleint sor
            //      maker_orders: array of tuples -- (maker order, base amount matched) against which lead order was matched
            //      total_amount_matched: total amount spent by taker in spending token of the trade
            //      gas_steps: actual amount steps to settle 1 trade
            //      gas_price: real gas price per 1 gas
            //      total_trades: total trades that happenned in whole sor
            
            let sor = self.order_hash_to_sor.read(sor_id);
            let (head, _) = self.sor_to_ptr.read(sor_id);
            assert(head == 0, 'sor already processed');
            assert(sor.lead.maker != 0x0.try_into().unwrap(), 'sor not initialized');
            assert(sor.allow_nonatomic_processing, 'this sor atomic only');
            assert(total_trades.into() <= sor.trades_max, 'Failed max trades');
            

            let mut base_trade = get_dep_component_mut!(ref self, BaseTrade);
            let (skip_taker_validation, allow_charge_gas_on_receipt) = (true, false); // cause place was directly by user so skip
            let (as_taker_completed, tfer_taker_recieve_back) = (true, false); 
            let gas_trades = if sor.apply_gas_in_first_trade {total_trades} else {0};
            
            let (succ, _) = base_trade.apply_single_taker(
                SignedOrder{order:sor.lead, sign: array![].span(), router_sign:sor.router_signature_lead},
                makers_orders.span(), total_amount_matched, gas_price, gas_steps, as_taker_completed, 
                skip_taker_validation, gas_trades, tfer_taker_recieve_back, allow_charge_gas_on_receipt);
            self.sor_to_ptr.write(sor_id, (1, !succ));
            if succ {base_trade.assert_slippage(sor_id, sor.max_spend_amount, 0);}

        }

        fn fulfillSORPath(ref self: ComponentState<TContractState>, sor_id:felt252, makers_orders:Array<(SignedOrder,u256)>,
                    total_amount_matched:u256, gas_steps:u32, gas_price:u256, total_trades:u16) {
            // Non atomically (might be in separate txs) process orders from client sor path (starting after lead order sequentially)
            // Can only be invoked on sor that supports non atomic execution and after lead order was processed; no double spending
            //  Params:
            //      sor_id: lead order hash representing client sor
            //      maker_orders: array of tuples -- (maker order, base amount matched) against head order was matched
            //      total_amount_matched: total amount spent by taker in spending token of the trade
            //      gas_steps: actual amount steps to settle 1 trade
            //      gas_price: real gas price per 1 gas
            //      total_trades: total trades that happenned in whole sor

            // head is starts from lead order and points on unprocessed order!           
            let (sor, (head, failed))  = (self.order_hash_to_sor.read(sor_id), self.sor_to_ptr.read(sor_id));

            assert(head != 0, 'lead not processed yet');
            assert(head - 1 < sor.path_len, 'sor processed');
            let (succ, fee_recipient) = (!failed, sor.trade_fee.recipient);
            let matched = array![(total_amount_matched, makers_orders.len().try_into().unwrap())].span();
            
            let (order, is_last_order) = self.getOrderFromsor(sor, head);
            let (fee_trade, fee_router) = self.getTradeAndRouterFees(sor, is_last_order && sor.trade_fee.apply_to_receipt_amount);
            let tfer_taker_recieve_back = is_last_order && sor.lead.flags.external_funds;  // last order if sor external need tfer result of sor back
            let gas_trades = if sor.apply_gas_in_first_trade  {0} else {total_trades};
            let overwrite_qty = if (is_last_order) {Option::Some(sor.last_qty)} else {Option::None};
            let (__, __, taker_hash) = self.apply(sor.lead, order, fee_trade, fee_router, 0, 0, makers_orders.span(), matched, gas_price, gas_steps, succ, gas_trades, fee_recipient, tfer_taker_recieve_back, sor_id, overwrite_qty);
            self.sor_to_ptr.write(sor_id, (head + 1, failed));   
            if is_last_order && succ {
                let mut base_trade = get_dep_component_mut!(ref self, BaseTrade);
                base_trade.assert_slippage(taker_hash, 0, sor.min_receive_amount);
            }
         
        }

        fn getOrderFromsor(self: @ComponentState<TContractState>, sor:super::SOR, cur_head:u8) -> (Option<super::SimpleOrder>, bool) {
            // returns <option simple order, is order a last order>
            // if cur_head == 0 it is lead order so an offset of 1

            if (cur_head == sor.path_len) {
                let order = if (cur_head == 1) {sor.order0} else if (cur_head == 2) {sor.order1} else if (cur_head == 3) {sor.order2} else {sor.order3};
                return (order, false);
            } else {
                return (Option::Some(sor.last_order), true);
            }            
        }

        fn buildSOR(self: @ComponentState<TContractState>, orchestrate_order:super::SimpleOrder, 
                path:Array<super::SimpleOrder>, router_signature:(felt252, felt252), details:super::SORDetails) ->super::SOR {
            // building sor that is stored in memory
            // creates inplace lead order from simple orchestrate_order
            // flatten path and store in sor order<i> variables in sor since cant store vectors in contract

            let (zero_trade_fee, zero_router_fee) = self.getZeroFees(details.trade_fee.recipient, details.router_fee.recipient, 
                                                                                            details.trade_fee.apply_to_receipt_amount);
                        
            assert(!(details.min_receive_amount > 0 && details.max_spend_amount > 0), 'Both cant be defined');
            let full_fill_only = details.max_spend_amount == 0; // if client wants to sell exact -> full_fill_only set to True
            // build lead order inplace
            let lead = Order{maker:get_caller_address(), qty:details.lead_qty, price:orchestrate_order.price, ticker:orchestrate_order.ticker,
                salt:details.salt, source: details.source, sign_scheme: details.sign_scheme, 
                    fee: super::OrderFee{
                        trade_fee:  if details.trade_fee.apply_to_receipt_amount {zero_trade_fee} else {details.trade_fee}, 
                        router_fee: if details.trade_fee.apply_to_receipt_amount {zero_router_fee} else {details.router_fee}, 
                        gas_fee: details.gas_fee
                    },
                flags: super::OrderFlags{ full_fill_only, best_level_only: false, post_only: false, is_sell_side: orchestrate_order.is_sell_side,
                    is_market_order: true, to_ecosystem_book: details.to_ecosystem_book, external_funds: details.external_funds
                },
                constraints: super::Constraints{
                    // duration 1 -> should be executed instantly
                    number_of_swaps_allowed: details.number_of_swaps_allowed, duration_valid: details.duration_valid, created_at:details.created_at, 
                    stp: super::TakerSelfTradePreventionMode::NONE, 
                    nonce: details.nonce, min_receive_amount: 0, router_signer: details.router_signer
                }
            };
            
            // cant store array in cairo so we rather limit path size and store in variables
            // note that last order defined always and replace some of the order<i>
            let (sz, none) = (path.len(), Option::None);
            let order0 = if (sz > 1) {Option::Some(*path.at(0))} else {none};
            let order1 = if (sz > 2) {Option::Some(*path.at(1))} else {none};
            let order2 = if (sz > 3) {Option::Some(*path.at(2))} else {none};
            let order3 = if (sz > 4) {Option::Some(*path.at(3))} else {none};
            let last = *path.at(sz - 1);
            // calc upper for gas swaps
            
            let begin_spend_token = if lead.flags.is_sell_side {let (b,_) = lead.ticker;b} else {let (_,q) = lead.ticker; q};
            let end_receive_token = if !last.is_sell_side {let (b,_) = last.ticker;b} else {let (_, q) = last.ticker; q};
            let gas_coin = lead.fee.gas_fee.fee_token;
            
            // check no loop
            assert(begin_spend_token != end_receive_token, 'No loops allowed');
            
            // charge for gas at very first orders or very last
            let apply_gas_in_first_trade = begin_spend_token == gas_coin || end_receive_token != gas_coin;
            
            let new_sor = super::SOR{lead, order0, order1, order2, order3, last_order:last,
            router_signature_lead: router_signature, allow_nonatomic_processing:details.allow_nonatomic, 
            router_fee:details.router_fee, trade_fee: details.trade_fee, apply_gas_in_first_trade, path_len: path.len().try_into().unwrap(),
            trades_max:details.number_of_swaps_allowed.into(), min_receive_amount:details.min_receive_amount, max_spend_amount:details.max_spend_amount,
            last_qty:details.last_qty
            };
            return new_sor;
        }

        fn getTradeAndRouterFees(self: @ComponentState<TContractState>, sor:super::SOR, non_zero_fees:bool) -> (super::FixedFee, super::FixedFee) {
            if !non_zero_fees {return self.getZeroFees(sor.lead.fee.trade_fee.recipient, sor.lead.fee.router_fee.recipient, sor.lead.fee.trade_fee.apply_to_receipt_amount);}
            return (sor.trade_fee, sor.router_fee);
        }

        fn getZeroFees(self: @ComponentState<TContractState>, trade_fee_recipient:ContractAddress, router_fee_recipient:ContractAddress, apply_to_receipt:bool) -> (super::FixedFee, super::FixedFee) {
            let zero_trade_fee = super::FixedFee{recipient:trade_fee_recipient, maker_pbips:0, taker_pbips:0, apply_to_receipt_amount: apply_to_receipt};
            let zero_router_fee = super::FixedFee{recipient:router_fee_recipient, maker_pbips:0, taker_pbips:0, apply_to_receipt_amount:apply_to_receipt};
            return (zero_trade_fee, zero_router_fee);
        }


        fn buildInplaceTakerOrder(self: @ComponentState<TContractState>, minimal_order:super::SimpleOrder, lead: Order, 
                trade_fee:super::FixedFee, router_fee: super::FixedFee, previous_fill_amount_qty:u256, 
                    lead_taker_hash:felt252, overwrite_qty:Option<super::Quantity>) -> Order {
            // build inplace taker order given lead order and minimal info for new order
            let qty = if !overwrite_qty.is_some() {
                let base_qty =  if minimal_order.is_sell_side {previous_fill_amount_qty} else {0};
                let quote_qty = if !minimal_order.is_sell_side {previous_fill_amount_qty} else {0};
                super::Quantity{base_asset:minimal_order.base_asset, base_qty, quote_qty}
            } else {overwrite_qty.unwrap()};
            Order{maker:lead.maker, qty, price:minimal_order.price, ticker:minimal_order.ticker,
                salt:lead_taker_hash, source: lead.source, sign_scheme: lead.sign_scheme, fee: super::OrderFee{trade_fee, router_fee, gas_fee: lead.fee.gas_fee},
                flags: super::OrderFlags{ full_fill_only: true, best_level_only: false, post_only: false, is_sell_side: minimal_order.is_sell_side,
                    is_market_order: true, to_ecosystem_book: lead.flags.to_ecosystem_book, external_funds: false
                },
                constraints: super::Constraints{
                    number_of_swaps_allowed: lead.constraints.number_of_swaps_allowed, duration_valid: lead.constraints.duration_valid, created_at: lead.constraints.created_at, 
                    stp: lead.constraints.stp, nonce: lead.constraints.nonce, min_receive_amount: 0, router_signer: lead.constraints.router_signer
                }
            }
        }

        fn apply(ref self: ComponentState<TContractState>, lead_order:Order, option_order: Option<super::SimpleOrder>,
                            trade_fee:super::FixedFee, router_fee: super::FixedFee, ptr:u32, offset:u32,
                            makers_orders:Span<(SignedOrder,u256)>, 
                            total_amount_matched_and_len:Span<(u256, u8)>, gas_price:u256, gas_steps:u32, succ:bool, gas_trades_to_pay:u16,
                            fee_recipient:ContractAddress, transfer_taker_recieve_back:bool, lead_taker_hash:felt252, overwrite_qty: Option<super::Quantity>) -> (u32, u32, felt252) {
            // Depending on succ, either punish or settle trades for the option order and return an new offset and new ptr 
            // where offset for makers order slicing and ptr index of processing order
            //  inplace builds intermediary order from lead_order and supplied fees
            //  Params:
            //      lead_order: lead order that orchestrate sor
            //      option_order: ongoing intermediary order to be filled/or punished
            //      trade_fee: define trade fee for an option order
            //      router_fee: define trade fee for an option order
            //      ptr: points which orders should be taken to be processed from sor
            //      offset: points to an offset in mm orders where right orders start to match against
            //      total_amount_matched_and_len
            //      ...
            //      succ: if order should be settled or marked as failed
            //      
            let mut base_trade = get_dep_component_mut!(ref self, BaseTrade);
            if option_order.is_some() {
                    let (amount_spent, swaps) = *total_amount_matched_and_len.at(ptr);
                    let order = self.buildInplaceTakerOrder(option_order.unwrap(), lead_order, trade_fee, router_fee, amount_spent, lead_taker_hash, overwrite_qty);
                    // TODO: likely need not to calculate message hash?? cause expensive and no point
                    let taker_hash = order.get_message_hash(order.maker);
                    let as_taker_completed = true;
                    if succ {
                        let (accum_base, accum_quote) = base_trade.apply_trades(order, makers_orders.slice(offset, swaps.try_into().unwrap()), lead_order.fee.trade_fee.recipient, 
                                    taker_hash, gas_price, gas_steps, as_taker_completed);
                        if transfer_taker_recieve_back {
                            let (taker_received, spent) = if order.flags.is_sell_side { (accum_quote, accum_base) } else {(accum_base, accum_quote)};
                            base_trade.finalize_router_taker(order, taker_hash, taker_received, 0, gas_price, 
                                gas_trades_to_pay, gas_steps, spent, fee_recipient, transfer_taker_recieve_back, false); 
                        }
                    } else {
                        base_trade.apply_punishment(order, makers_orders.slice(offset, swaps.try_into().unwrap()), lead_order.fee.trade_fee.recipient, 
                                taker_hash, gas_price, gas_steps, as_taker_completed);

                    }
                    return (offset + swaps.try_into().unwrap(), ptr + 1, taker_hash);
                }
            return (offset, ptr, 0.try_into().unwrap());
        }

        fn acquireLock(ref self:ComponentState<TContractState>, router_sign:(felt252,felt252)) {
            //lock defined by tx_hash of ongoing tx
            let (hash_lock, _) = self.atomic_taker_info.read();
            assert(hash_lock == 0, 'Lock already acquired');       
            let tx_info = get_tx_info().unbox();
            self.atomic_taker_info.write((tx_info.transaction_hash, router_sign));
        }

        fn releaseLock(ref self:ComponentState<TContractState>) {
            let (hash_lock, _) = self.atomic_taker_info.read();            
            let tx_info = get_tx_info().unbox();        
            assert(hash_lock == tx_info.transaction_hash, 'Lock not acquired');
            self.atomic_taker_info.write((0, (0,0)));
        }



    }
}