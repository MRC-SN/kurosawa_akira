



use kurosawa_akira::Order::{SignedOrder,Order,get_gas_fee_and_coin, OrderTradeInfo, OrderFee, FixedFee,GasFee,
            get_feeable_qty,get_limit_px, do_taker_price_checks, do_maker_checks, get_available_base_qty, generic_taker_check,generic_common_check,TakerSelfTradePreventionMode};


#[starknet::interface]
trait IBaseOrderTradeLogic<TContractState> {
    fn get_ecosystem_trade_info(self: @TContractState, order_hash: felt252) -> OrderTradeInfo;
    fn get_ecosystem_trades_info(self: @TContractState, order_hashes: Array<felt252>) -> Array<OrderTradeInfo>;
}

#[starknet::component]
mod base_trade_component {
    use core::array::SpanTrait;
    use core::{traits::TryInto,option::OptionTrait, array::ArrayTrait, traits::Destruct, traits::Into};
    use kurosawa_akira::{NonceComponent::INonceLogic, SignerComponent::ISignerLogic};
    use starknet::{get_contract_address, ContractAddress, get_block_timestamp};
    use super::{do_taker_price_checks,do_maker_checks,get_available_base_qty, get_feeable_qty, get_limit_px, SignedOrder,Order, TakerSelfTradePreventionMode, OrderTradeInfo, OrderFee, FixedFee};
    use kurosawa_akira::utils::common::{DisplayContractAddress, min};

    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait, IERC20Dispatcher};
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl, SNIP12MetadataImpl};

    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcherTrait, ILayerAkiraCoreDispatcher};
    use kurosawa_akira::LayerAkiraExternalGrantor::{IExternalGrantorDispatcherTrait, IExternalGrantorDispatcher};
    
    #[storage]
    struct Storage {
        orders_trade_info: starknet::storage::Map::<felt252, OrderTradeInfo>,
        core_contract:ContractAddress,
        router_contract:ContractAddress,
    }


    
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        FeeReward:FeeReward,
        Punish:Punish,
        Trade:Trade
    }

    #[derive(Drop, starknet::Event)]
    struct FeeReward {
        #[key]
        recipient:ContractAddress,
        token:ContractAddress,
        amount:u256,
    }
    #[derive(Drop, starknet::Event)]
    struct Punish {
        #[key]
        router:ContractAddress,
        taker_hash:felt252,
        maker_hash:felt252,
        amount:u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Trade {
        #[key]
        maker:ContractAddress, 
        #[key]
        taker:ContractAddress,
        ticker:(ContractAddress,ContractAddress),
        router_maker:ContractAddress, router_taker:ContractAddress,
        amount_base: u256, amount_quote: u256,
        is_sell_side: bool, is_failed: bool, is_ecosystem_book:bool,
        maker_hash:felt252, taker_hash:felt252,
        maker_source:felt252, taker_source:felt252
    }



    #[embeddable_as(BaseTradable)]
    impl BaseOrderTradableImpl<TContractState, 
    +HasComponent<TContractState>,
    +Drop<TContractState>> of super::IBaseOrderTradeLogic<ComponentState<TContractState>> {
        fn get_ecosystem_trade_info(self: @ComponentState<TContractState>, order_hash: felt252) -> OrderTradeInfo {
            return self.orders_trade_info.read(order_hash);
        }
        fn get_ecosystem_trades_info(self: @ComponentState<TContractState>, mut order_hashes: Array<felt252>) -> Array<OrderTradeInfo> {
            let mut res = ArrayTrait::new();
            loop {
                match order_hashes.pop_front(){
                    Option::Some(order_hash) => {res.append(self.get_ecosystem_trade_info(order_hash))}, Option::None(_) => {break();}
                }
            };
            return res; 
        }
    }

     #[generate_trait]
    impl InternalOrderTradableImpl<TContractState, +HasComponent<TContractState>,
    +Drop<TContractState>, > of InternalBaseOrderTradable<TContractState> {

        // exposed only in contract user apply ecosystem trades
        fn apply_ecosystem_trades(ref self: ComponentState<TContractState>, mut taker_orders:Array<(SignedOrder, bool)>, mut maker_orders:Array<SignedOrder>, mut iters:Array<(u16, bool)>,
                    mut oracle_settled_qty:Array<u256>, gas_price:u256,cur_gas_per_action:u32) {
            let mut maker_order = *maker_orders.at(0).order;
            let mut maker_hash: felt252  = 0.try_into().unwrap();  
            let mut maker_fill_info = self.orders_trade_info.read(maker_hash);
            let core = ILayerAkiraCoreDispatcher {contract_address:self.core_contract.read() };
            
            let (_, use_prev_maker) = *iters.at(0);
            let mut first_iter = true;
            assert!(!use_prev_maker, "WRONG_FIRST_ITER");

            let fee_recipient = core.get_fee_recipient();

            loop {
                match iters.pop_front(){
                    Option::Some((trades, mut use_prev_maker)) => {
                        let (mut total_base, mut total_quote) = (0,0);
            
                        let (signed_taker_order, as_taker_completed) = taker_orders.pop_front().unwrap();
                        let (taker_order, taker_hash, mut taker_fill_info) =  self.part_safe_validate_taker(signed_taker_order, trades, fee_recipient); 
                        let mut cur = 0;

                        loop {
                            if cur == trades { break();}

                            if !use_prev_maker {
                                // update state for maker that gone (edge case if )
                                if first_iter {  first_iter = false; } else { self.orders_trade_info.write(maker_hash, maker_fill_info);}
                                
                                let (new_maker_order,new_hash,new_fill_info) = self.do_internal_maker_checks(maker_orders.pop_front().unwrap(), fee_recipient);
                                maker_order = new_maker_order; maker_hash = new_hash; maker_fill_info = new_fill_info;
                                
                            } else {
                                let remaining = get_available_base_qty(get_limit_px(maker_order, maker_fill_info), maker_order.qty, maker_fill_info);
                                assert!(remaining > 0, "MAKER_ALREADY_PREVIOUSLY_FILLED");
                                use_prev_maker = false;
                            }
                            assert!(!taker_order.flags.external_funds && !maker_order.flags.external_funds, "WRONG_EXTERNAL_FLAGS");
                            
                            if (taker_order.constraints.stp != TakerSelfTradePreventionMode::NONE) { // check stp mode, if not None require prevention
                                assert!(core.get_signer(maker_order.maker) != core.get_signer(taker_order.maker), "STP_VIOLATED");
                            }
                            let (base, quote, px) = self.get_settled_amounts(maker_order, taker_order, maker_fill_info, taker_fill_info, oracle_settled_qty.pop_front().unwrap(), maker_hash);
                            self.settle_trade(maker_order, taker_order,base, quote, maker_hash, taker_hash);
                            total_base += base; total_quote += quote;
                            maker_fill_info.filled_base_amount += base; maker_fill_info.filled_quote_amount += quote; maker_fill_info.last_traded_px = px;
                            taker_fill_info.filled_base_amount += base; taker_fill_info.filled_quote_amount += quote; taker_fill_info.last_traded_px = px;
                            maker_fill_info.is_sell_side = !taker_order.flags.is_sell_side;
                            cur += 1;
                        };
                        
                        taker_fill_info.num_trades_happened += trades; taker_fill_info.as_taker_completed = as_taker_completed;
                        taker_fill_info.is_sell_side = taker_order.flags.is_sell_side;
                        self.orders_trade_info.write(taker_hash, taker_fill_info);
                        
                        self.apply_taker_fee_and_gas(taker_order, total_base, total_quote, gas_price, trades, cur_gas_per_action, fee_recipient);

                    },
                    Option::None(_) => {
                        assert!(taker_orders.len() == 0 && maker_orders.len() == 0 && iters.len() == 0, "MISMATCH");
                        // update state for last maker that gone
                        
                        self.orders_trade_info.write(maker_hash, maker_fill_info);
                        break();
                    }
                }
            };
        }

        fn apply_single_taker(ref self: ComponentState<TContractState>, signed_taker_order:SignedOrder, mut signed_maker_orders:Span<(SignedOrder,u256)>,
                    total_amount_matched:u256, gas_price:u256,  cur_gas_per_action:u32, as_taker_completed:bool, 
                    skip_taker_validation:bool, gas_trades_to_pay:u16, transfer_taker_recieve_back:bool, allow_charge_gas_on_receipt:bool)  -> (bool, felt252) {
            
            let (exchange, trades): (ContractAddress, u16) = (get_contract_address(), signed_maker_orders.len().try_into().unwrap());
            // let gas_trades_to_pay = if (skip_gas_pay) {0} else {trades};
            let core = ILayerAkiraCoreDispatcher {contract_address:self.core_contract.read() };
            let fee_recipient = core.get_fee_recipient();
            let (taker_order, taker_hash, mut __) =  if !signed_taker_order.order.flags.external_funds {
                self.part_safe_validate_taker(signed_taker_order, trades, fee_recipient)
            } else {
                let (o, hash, info, available) = self._do_part_external_taker_validate(signed_taker_order, trades, fee_recipient);
                // prevent exchange trigger reimbure on purpose else we can send 0 and it will trigger failure on checks and trigger router punishment
                //  we need this oracle because we might dont know beforehand how much taker will spent because px is protection price
                assert!(total_amount_matched <= available, "WRONG_AMOUNT_MATCHED_ORACLE got {} should be less {}", total_amount_matched, available);
                (o, hash, info)
            };
                                
            let mut expected_amount_spend = if taker_order.flags.external_funds  {
                // HOW to deal with PPL that create AA that force exception in implementation?
                if (!skip_taker_validation && !core.check_sign(taker_order.maker, taker_hash, signed_taker_order.sign, taker_order.sign_scheme)) {0}
                else {
                    if !self._prepare_router_taker(taker_order, total_amount_matched, exchange, gas_trades_to_pay, gas_price, cur_gas_per_action, allow_charge_gas_on_receipt) {0} else {total_amount_matched}
                }
            } else {total_amount_matched};

            let failed = expected_amount_spend == 0;
            if failed && taker_order.flags.external_funds {
                // here use trades instead of gas pay trades
                self.apply_punishment(taker_order, signed_maker_orders, fee_recipient, taker_hash, gas_price, cur_gas_per_action, as_taker_completed);
                return (false, taker_hash);
            }

            let (accum_base, accum_quote) = self.apply_trades(taker_order, signed_maker_orders, fee_recipient, taker_hash, gas_price, cur_gas_per_action, as_taker_completed);
            
            let (taker_received, unspent, spent) = if taker_order.flags.is_sell_side {
                    if (!taker_order.flags.external_funds) { expected_amount_spend = accum_base}
                    assert(expected_amount_spend >= accum_base, 'FINALIZE_BASE_OVERFLOW');                    
                    (accum_quote, expected_amount_spend - accum_base, accum_base)
                } else {
                    if (!taker_order.flags.external_funds) { expected_amount_spend = accum_quote}
                    assert(expected_amount_spend >= accum_quote, 'FINALIZE__OVERFLOW');                    
                    (accum_base, expected_amount_spend - accum_quote, accum_quote)
                };
            self.finalize_router_taker(taker_order, taker_hash, taker_received, unspent, gas_price, 
                gas_trades_to_pay, cur_gas_per_action, spent, fee_recipient, transfer_taker_recieve_back, taker_order.flags.external_funds); 


            return (true, taker_hash);     
        }


        fn do_internal_maker_checks(self: @ComponentState<TContractState>, signed_order:SignedOrder, fee_recipient:ContractAddress) -> (Order,felt252, OrderTradeInfo) {
            let (core, order, sign) = (ILayerAkiraCoreDispatcher {contract_address:self.core_contract.read() }, signed_order.order, signed_order.sign);
            let maker_hash =  order.get_message_hash(order.maker);
            let maker_fill_info = self.orders_trade_info.read(maker_hash);
            do_maker_checks(order, maker_fill_info, core.get_nonce(order.maker), fee_recipient);            
            assert!(core.check_sign(order.maker, maker_hash, sign, order.sign_scheme), "WRONG_SIGN_MAKER: (maker_hash, sign) : ({})", maker_hash);
            return (order, maker_hash, maker_fill_info);
        }


        fn part_safe_validate_taker(self: @ComponentState<TContractState>, taker_signed_order:SignedOrder, swaps:u16, fee_recipient:ContractAddress) -> (Order,felt252,OrderTradeInfo) {
            let (core, taker_order, sign) = (ILayerAkiraCoreDispatcher {contract_address:self.core_contract.read() }, taker_signed_order.order,  taker_signed_order.sign);
            let taker_order_hash = taker_order.get_message_hash(taker_order.maker);
            let taker_fill_info = self.orders_trade_info.read(taker_order_hash);
            
            assert(!taker_order.flags.external_funds, 'ECOSYSTEM_TAKER_NOT_EXTERNAL');
            assert!(core.check_sign(taker_order.maker, taker_order_hash, sign, taker_order.sign_scheme), "WRONG_SIGN_TAKER: (taker_order_hash) = ({})", taker_order_hash,);
            super::generic_taker_check(taker_order, taker_fill_info, core.get_nonce(taker_order.maker), swaps, taker_order_hash, fee_recipient);
            return (taker_order, taker_order_hash, taker_fill_info);
        }

        fn settle_trade(ref self:ComponentState<TContractState>, maker_order:Order, taker_order:Order, settle_base_amount:u256, settle_quote_amount:u256,maker_hash:felt252,taker_hash:felt252 ) {
            // Tfer amount between acount on settled trades and apply maker fees both trade and router fee if specified
            let core = ILayerAkiraCoreDispatcher {contract_address:self.core_contract.read() };
            core.rebalance_after_trade(maker_order.maker, taker_order.maker, maker_order.ticker, settle_base_amount, settle_quote_amount, maker_order.flags.is_sell_side);
            self.apply_fixed_fees(maker_order, settle_base_amount, settle_quote_amount, true);
            self.emit(Trade{
                router_maker:maker_order.fee.router_fee.recipient, router_taker:taker_order.fee.router_fee.recipient,
                maker:maker_order.maker, taker:taker_order.maker, ticker:maker_order.ticker, is_failed:false, 
                is_ecosystem_book:maker_order.flags.to_ecosystem_book, amount_base:settle_base_amount, amount_quote:settle_quote_amount, is_sell_side:maker_order.flags.is_sell_side,maker_hash,taker_hash,maker_source:maker_order.source,taker_source:taker_order.source });
        }

        fn get_settled_amounts(self:@ComponentState<TContractState>, maker_order:Order,taker_order:Order, maker_fill_info:OrderTradeInfo, taker_fill_info:OrderTradeInfo, 
                        oracle_settle_qty:u256, maker_hash:felt252) -> (u256, u256, u256) {
            let settle_px = get_limit_px(maker_order, maker_fill_info);
            let maker_qty = get_available_base_qty(settle_px, maker_order.qty, maker_fill_info);
            let taker_qty = do_taker_price_checks(taker_order, settle_px, taker_fill_info);
            let mut settle_base_amount = if maker_qty > taker_qty {taker_qty} else {maker_qty};
            if oracle_settle_qty > 0 {
                assert!(oracle_settle_qty <= settle_base_amount, "WRONG_ORACLE_SETTLE_QTY {} for {}", oracle_settle_qty, maker_hash);
                settle_base_amount = oracle_settle_qty; 
            }
            super::generic_common_check(maker_order, taker_order);
            let settle_quote_amount = settle_px * settle_base_amount / maker_order.qty.base_asset;
            assert!(settle_quote_amount > 0, "0_QUOTE_AMOUNT");
            return (settle_base_amount, settle_quote_amount, settle_px);

        }   
        
        fn apply_taker_fee_and_gas(ref self: ComponentState<TContractState>, taker_order:Order, base_amount:u256, quote_amount:u256, gas_price:u256, trades:u16, 
                        cur_gas_per_action:u32, fee_recipient:ContractAddress) -> (ContractAddress, u256, u256, u256) {
            let mut core = ILayerAkiraCoreDispatcher {contract_address:self.core_contract.read() };
            let (fee_token, fee_amount, exchange_fee) = self.apply_fixed_fees(taker_order, base_amount, quote_amount, false);
            let (spent, coin) = super::get_gas_fee_and_coin(taker_order.fee.gas_fee, gas_price, core.get_wrapped_native_token(), cur_gas_per_action, trades);
            if (spent !=0 ) {core.transfer(taker_order.maker, fee_recipient, spent, coin)};
            return (fee_token, fee_amount, exchange_fee, spent);
        }

        fn apply_fixed_fees(ref self: ComponentState<TContractState>,order:Order,base_amount:u256, quote_amount:u256,is_maker:bool) -> (ContractAddress,u256, u256) {
            let (fee_token_trade, exchange_fee) =  self.apply_fixed_fee(order.maker, order.fee.trade_fee, order.flags.is_sell_side, order.ticker, base_amount, quote_amount, is_maker);
            let (fee_token_router, fee_amount) = self.apply_fixed_fee(order.maker, order.fee.router_fee, order.flags.is_sell_side, order.ticker, base_amount, quote_amount, is_maker);
            assert(fee_token_trade==fee_token_router, 'MISMATCH fixed fee tokens');
            if fee_amount > 0 { 
                self.emit(FeeReward{ recipient:order.fee.router_fee.recipient, token:fee_token_trade, amount:fee_amount});
            }
            return (fee_token_trade, fee_amount, exchange_fee);
        }

        fn _do_part_external_taker_validate(self:@ComponentState<TContractState>, signed_taker_order:SignedOrder, swaps:u16, fee_recipient:ContractAddress) -> (Order,felt252,OrderTradeInfo, u256) {
            //Returns max user can actually spend
            let (router, taker_order) = (IExternalGrantorDispatcher {contract_address:self.router_contract.read()}, signed_taker_order.order);
            let taker_hash = taker_order.get_message_hash(taker_order.maker);
            let taker_fill_info = self.orders_trade_info.read(taker_hash);
            
            //Validate router, job of exchange because of this assert
            assert!(router.validate_router(taker_hash, signed_taker_order.router_sign, taker_order.constraints.router_signer, taker_order.fee.router_fee.recipient), "WRONG_ROUTER_SIGN");
            // nonce here so router cant on purpose send old orders of user
            super::generic_taker_check(taker_order, taker_fill_info, ILayerAkiraCoreDispatcher {contract_address:self.core_contract.read()}.get_nonce(taker_order.maker), swaps, taker_hash, fee_recipient);
            assert!(taker_order.flags.is_market_order, "WRONG_MARKET_TYPE_EXTERNAL"); // external ones cant become passive orders
            let remaining_taker_amount =  self._infer_upper_bound_required(taker_order, taker_fill_info);
            let mut spend_fees = 0;
            if !taker_order.fee.trade_fee.apply_to_receipt_amount {spend_fees += get_feeable_qty(taker_order.fee.trade_fee, remaining_taker_amount, false)}
            if !taker_order.fee.router_fee.apply_to_receipt_amount {spend_fees += get_feeable_qty(taker_order.fee.router_fee, remaining_taker_amount, false)}
            assert!(remaining_taker_amount + spend_fees > 0, "WRONG_TAKER_AMOUNT");
            return (taker_order, taker_hash, taker_fill_info, remaining_taker_amount + spend_fees);
        }

        fn _infer_upper_bound_required(self:@ComponentState<TContractState>, taker_order:Order, taker_fill_info:OrderTradeInfo) ->u256 {
            // Gives approxiation how much user must have tokens that he is willing to spend
            if taker_order.flags.is_sell_side { // sell of base asset
                return get_available_base_qty(taker_order.price, taker_order.qty, taker_fill_info);
            } else { // sell of quote asset
                
                let by_quote_asset = if taker_order.qty.quote_qty > 0 {
                    assert!(taker_order.qty.quote_qty >= taker_fill_info.filled_quote_amount,  "Order already filled by quote quote {} filled {}",
                                taker_order.qty.quote_qty, taker_fill_info.filled_quote_amount);
                    taker_order.qty.quote_qty - taker_fill_info.filled_quote_amount} else {0};

                let by_base_asset = if taker_order.qty.base_qty > 0 {
                    assert!(taker_order.qty.base_qty >= taker_fill_info.filled_base_amount,  "Order already filled by base base {} filled {}",
                                taker_order.qty.base_qty, taker_fill_info.filled_base_amount);
                    taker_order.price * (taker_order.qty.base_qty - taker_fill_info.filled_base_amount) / taker_order.qty.base_asset} else {0};
                
                if taker_order.qty.base_qty == 0 {return by_quote_asset;}
                if taker_order.qty.quote_qty == 0 { return by_base_asset;}
                return min(by_quote_asset, by_base_asset);
            }     
        }

        fn _prepare_router_taker(ref self:ComponentState<TContractState>, taker_order:Order, mut out_amount:u256, exchange:ContractAddress, swaps:u16,
                            gas_price:u256, cur_gas_per_action:u32, allow_charge_gas_from_receipt:bool) -> bool {
            // Prepare taker context for the trade when it have external funds mode
            // 1) Checks if user granted necessary permissions and have enough balance, and nonce of order is correct
            // 2) Tfer necessary amount for the trade and mint tokens on exchange for the user
            // In case of failure returns 0 signalizing that issue due router's bad job
            let (base, quote) = (taker_order.ticker);
            let core = ILayerAkiraCoreDispatcher {contract_address:self.core_contract.read() };

            if taker_order.constraints.nonce < core.get_nonce(taker_order.maker) { return false;}
            let (mut spent_gas, gas_token) = super::get_gas_fee_and_coin(taker_order.fee.gas_fee, gas_price, core.get_wrapped_native_token(), cur_gas_per_action, swaps);
            let (trade_spend_token, trade_receive_token) =  if taker_order.flags.is_sell_side {(base,quote)} else {(quote,base)};
            if trade_spend_token == gas_token  {
                out_amount += spent_gas; spent_gas = 0;
            }
            
            if !self.can_transfer(exchange, trade_spend_token, taker_order.maker, out_amount) {return false;}
            // if user pay for gas in currency that he receives we omit this step
            // it is job of exchange to ensure that user recieves enough gas tokens to cover costs of swap
            
            if (!allow_charge_gas_from_receipt || gas_token != trade_receive_token) && !self.can_transfer(exchange, gas_token, taker_order.maker, spent_gas) {return false;}
            self.transfer_in(exchange, trade_spend_token, taker_order.maker, out_amount);
            
            if (!allow_charge_gas_from_receipt || gas_token != trade_receive_token) {
                self.transfer_in(exchange, gas_token, taker_order.maker, spent_gas);
            }
            return true;
        }

        fn finalize_router_taker(ref self:ComponentState<TContractState>, taker_order:Order, taker_hash:felt252, mut received_amount:u256, unspent_amount:u256, gas_price:u256, trades:u16, cur_gas_per_action:u32,
                    spent_amount:u256, fee_recipient:ContractAddress, transfer_back_received:bool, tfer_back_unspent:bool) {
            // Finalize router taker
            // 1) pay for gas, trade, router fee
            // 2) transfer user erc20 tokens that he received + unspent amount of tokens he was selling
            let (b, q) = if taker_order.flags.is_sell_side { (spent_amount, received_amount) } else { (received_amount, spent_amount) };
            let (spending_token, receive_token) = if taker_order.flags.is_sell_side {let (b,q) = taker_order.ticker; (b,q)} else {let (b, q) = taker_order.ticker;(q,b)};
            
            let (fee_token, router_fee_amount, exchange_fee_amount, mut gas) =  self.apply_taker_fee_and_gas(taker_order, b, q, gas_price, trades, cur_gas_per_action, fee_recipient);
            // we charged him for gas but we need to deduct before sending back in case it was gas currency he received
            if (taker_order.fee.gas_fee.fee_token != receive_token) {gas = 0}
            
            
            if (spending_token == fee_token) { //if fees was in token user spend we deduct them from spend to return remaining else from recieve before sending back
                if transfer_back_received {self.transfer_back(receive_token, taker_order.maker, received_amount - gas);}
                if tfer_back_unspent {self.transfer_back(spending_token, taker_order.maker, unspent_amount - router_fee_amount - exchange_fee_amount);}
            } else {
                if transfer_back_received { self.transfer_back(receive_token, taker_order.maker, received_amount - router_fee_amount - exchange_fee_amount - gas);}
                if tfer_back_unspent {self.transfer_back(spending_token, taker_order.maker, unspent_amount);} // tfer unspent amount
            }
        }
      
        fn punish_router_simple(ref self: ComponentState<TContractState>, gas_fee:super::GasFee,router_addr:ContractAddress, 
                    maker:ContractAddress, taker:ContractAddress, gas_px:u256, taker_hash:felt252, maker_hash:felt252, 
                        cur_gas_per_action:u32, fee_recipient:ContractAddress) {
            let (mut router, mut core) = (IExternalGrantorDispatcher {contract_address:self.router_contract.read()},ILayerAkiraCoreDispatcher {contract_address:self.core_contract.read()});
            let native_base_token = core.get_wrapped_native_token();
            let charged_fee = cur_gas_per_action.into() * gas_px * router.get_punishment_factor_bips().into() / 10000;
            if charged_fee == 0 {return;}
            
            router.transfer_to_core(router_addr, native_base_token, 2 * charged_fee);
            core.safe_mint(fee_recipient, charged_fee, native_base_token);
            core.safe_mint(maker, charged_fee, native_base_token);
            self.emit(Punish{router:router_addr, taker_hash, maker_hash, amount: 2 * charged_fee});
        }

        fn transfer_back(ref self:ComponentState<TContractState>, token:ContractAddress, maker:ContractAddress, amount:u256) {
            if amount == 0 {return;}
            ILayerAkiraCoreDispatcher { contract_address: self.core_contract.read() }.safe_burn(maker, amount, token);
        }

        fn transfer_in(ref self:ComponentState<TContractState>, exchange:ContractAddress, token:ContractAddress, maker:ContractAddress, amount:u256) {
            if amount == 0 {return;}
            let erc = IERC20Dispatcher {contract_address:token}; erc.transferFrom(maker, self.core_contract.read(), amount);
            ILayerAkiraCoreDispatcher { contract_address: self.core_contract.read() }.safe_mint(maker, amount, token);
        }
        fn can_transfer(self:@ComponentState<TContractState>, exchange:ContractAddress, token:ContractAddress, maker:ContractAddress, amount:u256) -> bool {
            if amount == 0 {return true;}
            let erc = IERC20Dispatcher {contract_address:token};
            if erc.allowance(maker, exchange) < amount { return false;}
            if erc.balanceOf(maker) < amount { return false;}
            return true;
        }


        fn apply_fixed_fee(ref self: ComponentState<TContractState>, trader:ContractAddress, fee:FixedFee, is_sell_side:bool, ticker:(ContractAddress,ContractAddress), base_amount:u256, quote_amount:u256, is_maker:bool) -> (ContractAddress, u256) {
            let core = ILayerAkiraCoreDispatcher {contract_address:self.core_contract.read() };
            let (b, q) = ticker; 
            
            let (fee_token, fee_amount) = if is_sell_side  { 
                if fee.apply_to_receipt_amount {(q, quote_amount)} else {(b, base_amount)} } 
                else { if fee.apply_to_receipt_amount {(b, base_amount)} else {(q, quote_amount)} };
            let fee_amount = get_feeable_qty(fee, fee_amount, is_maker);
            if fee_amount > 0 { core.transfer(trader, fee.recipient, fee_amount, fee_token);}
            return (fee_token, fee_amount);
        }

        fn apply_punishment(ref self:ComponentState<TContractState>, 
                                taker_order:Order, mut signed_maker_orders:Span<(SignedOrder,u256)>, fee_recipient:ContractAddress,
                                taker_hash:felt252,
                                gas_price:u256, cur_gas_per_action:u32, as_taker_completed:bool) {
            let core = ILayerAkiraCoreDispatcher {contract_address:self.core_contract.read() };
            let mut taker_fill_info = self.orders_trade_info.read(taker_hash);
            
            loop {
                match signed_maker_orders.pop_front(){
                    Option::Some((signed_maker_order, oracle_settle_qty)) => {
                        // even if external taker fails we must validate makers are correct ones
                        let (maker_order, maker_hash, mut maker_fill_info) = self.do_internal_maker_checks(*signed_maker_order, fee_recipient);
                        let (amount_base, amount_quote, _) = self.get_settled_amounts(maker_order, taker_order, maker_fill_info, taker_fill_info, *oracle_settle_qty, maker_hash);
                        
                        if (!taker_order.flags.external_funds && taker_order.constraints.stp != TakerSelfTradePreventionMode::NONE) {
                            assert!(core.get_signer(maker_order.maker) != core.get_signer(taker_order.maker), "STP_VIOLATED");
                        }
                        
                        self.punish_router_simple(taker_order.fee.gas_fee, taker_order.fee.router_fee.recipient, 
                            *signed_maker_order.order.maker, taker_order.maker, gas_price, taker_hash, maker_hash, cur_gas_per_action, fee_recipient);

                        self.emit(Trade{router_maker:maker_order.fee.router_fee.recipient, router_taker:taker_order.fee.router_fee.recipient,
                                maker:maker_order.maker, taker:taker_order.maker, ticker:maker_order.ticker, is_failed:true, 
                                is_ecosystem_book:maker_order.flags.to_ecosystem_book, amount_base, amount_quote, is_sell_side:maker_order.flags.is_sell_side, taker_hash, 
                                maker_hash, maker_source: maker_order.source, taker_source:taker_order.source });
                                              
                    },
                    Option::None(_) => { 
                        // invalidate order
                        taker_fill_info.filled_base_amount = taker_order.qty.base_qty;
                        taker_fill_info.filled_quote_amount = taker_order.qty.quote_qty;
                        taker_fill_info.as_taker_completed = as_taker_completed;
                        taker_fill_info.is_sell_side = taker_order.flags.is_sell_side;
                        taker_fill_info.num_trades_happened += signed_maker_orders.len().try_into().unwrap();
                        self.orders_trade_info.write(taker_hash, taker_fill_info);
                        break();
                    }
                }
            };

        }

        fn apply_trades(ref self:ComponentState<TContractState>, 
                                taker_order:Order, mut signed_maker_orders:Span<(SignedOrder,u256)>, fee_recipient:ContractAddress,
                                taker_hash:felt252,
                                gas_price:u256, cur_gas_per_action:u32, as_taker_completed:bool) -> (u256, u256) {
            let core = ILayerAkiraCoreDispatcher {contract_address:self.core_contract.read() };
            let mut taker_fill_info = self.orders_trade_info.read(taker_hash);
            let (mut accum_base, mut accum_quote): (u256,u256) = (0,0);
            loop {
                match signed_maker_orders.pop_front(){
                    Option::Some((signed_maker_order, oracle_settle_qty)) => {
                        // even if external taker fails we must validate makers are correct ones
                        let (maker_order, maker_hash, mut maker_fill_info) = self.do_internal_maker_checks(*signed_maker_order, fee_recipient);
                        let (amount_base, amount_quote, settle_px) = self.get_settled_amounts(maker_order, taker_order, maker_fill_info, taker_fill_info, *oracle_settle_qty, maker_hash);
                        
                        if (!taker_order.flags.external_funds && taker_order.constraints.stp != TakerSelfTradePreventionMode::NONE) {
                            assert!(core.get_signer(maker_order.maker) != core.get_signer(taker_order.maker), "STP_VIOLATED");
                        }
                        self.settle_trade(maker_order, taker_order, amount_base, amount_quote, maker_hash, taker_hash);

                        maker_fill_info.filled_base_amount += amount_base; maker_fill_info.filled_quote_amount += amount_quote; maker_fill_info.last_traded_px = settle_px;
                        taker_fill_info.filled_base_amount += amount_base; taker_fill_info.filled_quote_amount += amount_quote; taker_fill_info.last_traded_px = settle_px;
                        self.orders_trade_info.write(maker_hash, maker_fill_info);
                        accum_base += amount_base; accum_quote += amount_quote;
                        maker_fill_info.is_sell_side = !taker_order.flags.is_sell_side;
                        
                    },
                    Option::None(_) => { 
                        taker_fill_info.as_taker_completed = as_taker_completed;
                        taker_fill_info.num_trades_happened += signed_maker_orders.len().try_into().unwrap();
                        taker_fill_info.is_sell_side = taker_order.flags.is_sell_side;
                        self.orders_trade_info.write(taker_hash, taker_fill_info);
                        break();
                    }
                }
            };                      
            (accum_base, accum_quote)
        }

        fn assert_slippage(self: @ComponentState<TContractState>, taker_hash:felt252, max_spend:u256, min_receive:u256) {
            let fill_info  = self.get_ecosystem_trade_info(taker_hash);
            let (spend, received) = if fill_info.is_sell_side {(fill_info.filled_base_amount, fill_info.filled_quote_amount)}
                                      else {(fill_info.filled_quote_amount,fill_info.filled_base_amount)};
            assert(max_spend == 0 || spend <= max_spend, 'Failed to max spend');
            assert(min_receive == 0 || received >= min_receive, 'Failed to min receive');
            
        }
    }

}