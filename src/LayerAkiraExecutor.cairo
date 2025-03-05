
use kurosawa_akira::NonceComponent::{SignedIncreaseNonce, IncreaseNonce};
use kurosawa_akira::Order::{SignedOrder, Order};
use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    
    
#[starknet::interface]
trait ILayerAkiraExecutor<TContractState> {
    fn get_order_hash(self: @TContractState, order:Order) -> felt252;
    fn apply_increase_nonces(ref self: TContractState, signed_nonces: Array<SignedIncreaseNonce>, gas_price:u256);

    fn apply_increase_nonce(ref self: TContractState, signed_nonce: SignedIncreaseNonce, gas_price:u256, cur_gas_per_action:u32);

    fn apply_withdraw(ref self: TContractState, signed_withdraw: SignedWithdraw, gas_price:u256, cur_gas_per_action:u32);

    fn apply_withdraws(ref self: TContractState, signed_withdraws: Array<SignedWithdraw>, gas_price:u256, cur_gas_per_action:u32);

    fn apply_ecosystem_trades(ref self: TContractState, taker_orders:Array<(SignedOrder,bool)>, maker_orders: Array<SignedOrder>, iters:Array<(u16,bool)>, oracle_settled_qty:Array<u256>, gas_price:u256, cur_gas_per_action:u32);
    
    fn apply_single_execution_step(ref self: TContractState, taker_order:SignedOrder, maker_orders: Array<(SignedOrder,u256)>, total_amount_matched:u256,  gas_price:u256, cur_gas_per_action:u32, as_taker_completed:bool) -> bool;
    
    fn apply_execution_steps(ref self: TContractState, bulk:Array<(SignedOrder, Array<(SignedOrder,u256)>, u256,bool)>,  gas_price:u256, cur_gas_per_action:u32) -> Array<bool>;



}

#[starknet::contract]
mod LayerAkiraExecutor {
    use kurosawa_akira::BaseTradeComponent::base_trade_component as  base_trade_component;
    use kurosawa_akira::SORTradeComponent::sor_trade_component as  sor_trade_component;
    
    use starknet::{ContractAddress, get_caller_address, get_tx_info};

    use base_trade_component::InternalBaseOrderTradable;
    use sor_trade_component::InternalSORTradable;
    use kurosawa_akira::SORTradeComponent::SORDetails;

    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcherTrait, ILayerAkiraCoreDispatcher};

    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    use kurosawa_akira::NonceComponent::{SignedIncreaseNonce, IncreaseNonce};
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl,SNIP12MetadataImpl,IncreaseNonceHashImpl,WithdrawHashImpl};
    use kurosawa_akira::Order::{SignedOrder, Order, SimpleOrder};
    
    
    component!(path: base_trade_component,storage: base_trade_s, event:BaseTradeEvent);
    component!(path: sor_trade_component,storage: sor_trade_s, event:SORTradeEvent);
    

    #[abi(embed_v0)]
    impl BaseOrderTradableImpl = base_trade_component::BaseTradable<ContractState>;
    #[abi(embed_v0)]
    impl SORTradableImpl = sor_trade_component::SORTradable<ContractState>;
    
    #[storage]
    struct Storage {
        #[substorage(v0)]
        base_trade_s: base_trade_component::Storage,
        #[substorage(v0)]
        sor_trade_s: sor_trade_component::Storage,
        
        exchange_invokers: starknet::storage::Map::<ContractAddress, bool>,
    }


    #[constructor]
    fn constructor(ref self: ContractState, core_address:ContractAddress, router_address:ContractAddress) {
        self.base_trade_s.core_contract.write(core_address);
        self.base_trade_s.router_contract.write(router_address);
        self.exchange_invokers.write(ILayerAkiraCoreDispatcher {contract_address:core_address }.get_owner(), true);
        self.sor_trade_s.core_address.write(core_address);
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> ContractAddress {
        ILayerAkiraCoreDispatcher {contract_address:self.base_trade_s.core_contract.read()}.get_owner()
    }

    #[external(v0)]
    fn get_core(self: @ContractState) -> ContractAddress {self.base_trade_s.core_contract.read()}
    #[external(v0)]
    fn get_router(self: @ContractState) -> ContractAddress {self.base_trade_s.router_contract.read()}


    #[external(v0)]
    fn update_exchange_invokers(ref self: ContractState, invoker:ContractAddress, enabled:bool) {
        assert!(get_owner(@self) == get_caller_address(), "Access denied: update_exchange_invokers is only for the owner's use");
        self.exchange_invokers.write(invoker, enabled);
        self.emit(UpdateExchangeInvoker{invoker, enabled});
    }


    #[external(v0)]
    fn get_order_hash(self: @ContractState, order:Order) -> felt252 { order.get_message_hash(order.maker)}



    #[external(v0)]
    fn apply_increase_nonce(ref self: ContractState, signed_nonce: SignedIncreaseNonce, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self);
        ILayerAkiraCoreDispatcher {contract_address:self.base_trade_s.core_contract.read()}
            .apply_increase_nonce(signed_nonce, gas_price, cur_gas_per_action);
    }


    #[external(v0)]
    fn apply_increase_nonces(ref self: ContractState, mut signed_nonces: Array<SignedIncreaseNonce>, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self);
        ILayerAkiraCoreDispatcher {contract_address:self.base_trade_s.core_contract.read()}
            .apply_increase_nonces(signed_nonces,gas_price,cur_gas_per_action);
    }

    #[external(v0)]
    fn apply_withdraw(ref self: ContractState, signed_withdraw: SignedWithdraw, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self);
        ILayerAkiraCoreDispatcher {contract_address:self.base_trade_s.core_contract.read()}.
            apply_withdraw(signed_withdraw, gas_price, cur_gas_per_action);
    }

    #[external(v0)]
    fn apply_withdraws(ref self: ContractState, mut signed_withdraws: Array<SignedWithdraw>, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self);
        ILayerAkiraCoreDispatcher {contract_address:self.base_trade_s.core_contract.read()}.
            apply_withdraws(signed_withdraws, gas_price, cur_gas_per_action);
    }

    #[external(v0)]
    fn apply_ecosystem_trades(ref self: ContractState, taker_orders:Array<(SignedOrder,bool)>, maker_orders: Array<SignedOrder>, iters:Array<(u16, bool)>, oracle_settled_qty:Array<u256>, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self);
        self.base_trade_s.apply_ecosystem_trades(taker_orders, maker_orders, iters, oracle_settled_qty, gas_price, cur_gas_per_action);
    }

    #[external(v0)]
    fn apply_single_execution_step(ref self: ContractState, taker_order:SignedOrder, maker_orders: Array<(SignedOrder,u256)>, total_amount_matched:u256, gas_price:u256, cur_gas_per_action:u32,as_taker_completed:bool, ) -> bool {
        assert_whitelisted_invokers(@self);
        let (succ, _) =  self.base_trade_s.apply_single_taker(taker_order, maker_orders.span(), total_amount_matched, gas_price, cur_gas_per_action, as_taker_completed, false, maker_orders.len().try_into().unwrap(), taker_order.order.flags.external_funds, true);
        return succ;
    }

    #[external(v0)]
    fn apply_execution_steps(ref self: ContractState,  mut bulk:Array<(SignedOrder, Array<(SignedOrder,u256)>, u256, bool)>,  gas_price:u256,  cur_gas_per_action:u32) -> Array<bool> {
        assert_whitelisted_invokers(@self);
        let mut res: Array<bool> = ArrayTrait::new();
            
        loop {
            match bulk.pop_front(){
                Option::Some((taker_order, maker_orders, total_amount_matched, as_taker_completed)) => {
                    let (succ, _) = self.base_trade_s.apply_single_taker(taker_order, maker_orders.span(), total_amount_matched, gas_price, cur_gas_per_action, as_taker_completed, false, maker_orders.len().try_into().unwrap(), taker_order.order.flags.external_funds, true);
                    res.append(succ);

                },
                Option::None(_) => {break;}
            };
        };
        return res;
    }


    #[external(v0)]
    fn placeTakerOrder(ref self: ContractState, order: Order, router_sign: (felt252,felt252)) {
        let tx_info = get_tx_info().unbox();
        if (!self.exchange_invokers.read(tx_info.account_contract_address)) {return;}; // shallow termination for client// argent simulation
        self.sor_trade_s.placeTakerOrder(order,router_sign);
    }
    #[external(v0)]
    fn fullfillTakerOrder(ref self: ContractState, mut maker_orders:Array<(SignedOrder,u256)>,
                    total_amount_matched:u256, gas_steps:u32, gas_price:u256) {
        assert_whitelisted_invokers(@self); self.sor_trade_s.fullfillTakerOrder(maker_orders, total_amount_matched, gas_steps, gas_price);
    }

    #[external(v0)]
    fn placeSORTakerOrder(ref self: ContractState, orchestrate_order: SimpleOrder, path:Array<SimpleOrder>, router_signature:(felt252, felt252), details: SORDetails) {
        let tx_info = get_tx_info().unbox();
        if (!self.exchange_invokers.read(tx_info.account_contract_address)) {return;}; // shallow termination for client// argent simulation
        self.sor_trade_s.placeSOROrder(orchestrate_order, path, router_signature, details);
    }

    #[external(v0)]
    fn fulfillSORAtomic(ref self: ContractState, makers_orders:Array<(SignedOrder,u256)>,
                        total_amount_matched_and_len:Array<(u256, u8)>, gas_steps:u32, gas_price:u256, sor_id:felt252) {
        assert_whitelisted_invokers(@self); 
        self.sor_trade_s.fulfillSORAtomic(makers_orders, total_amount_matched_and_len, gas_steps, gas_price, sor_id);           
    }

    #[external(v0)]
    fn fulfillSORLeadOrder(ref self: ContractState, sor_id:felt252, makers_orders:Array<(SignedOrder,u256)>,
            total_amount_matched:u256, gas_steps:u32, gas_price:u256, total_trades:u16) {
        assert_whitelisted_invokers(@self);
        self.sor_trade_s.fulfillSORLeadOrder(sor_id, makers_orders, total_amount_matched, gas_steps, gas_price, total_trades);

    }
    #[external(v0)]
    fn fulfillSORPath(ref self: ContractState, sor_id:felt252, makers_orders:Array<(SignedOrder,u256)>,
                    total_amount_matched:u256, gas_steps:u32, gas_price:u256, total_trades:u16) {
        assert_whitelisted_invokers(@self);
        self.sor_trade_s.fulfillSORPath(sor_id, makers_orders, total_amount_matched, gas_steps, gas_price, total_trades);
    }

    #[derive(Drop, Serde)]
    enum Step {
        BulkExecutionSteps: (Array<(SignedOrder, Array<(SignedOrder,u256)>, u256, bool)>, bool),
        SingleExecutionStep:((SignedOrder, Array<(SignedOrder,u256)>, u256, bool),bool),
        EcosystemTrades: (Array<(SignedOrder,bool)>, Array<SignedOrder>, Array<(u16, bool)>, Array<u256>),
        IncreaseNonceStep:SignedIncreaseNonce,
        WithdrawStep:SignedWithdraw,
    }


    #[external(v0)]
    fn apply_steps(ref self: ContractState, mut steps:Array<Step>, nonce_steps: u32, withdraw_steps:u32,router_steps:u32, ecosystem_steps:u32, gas_price:u256) {
        assert_whitelisted_invokers(@self);
        loop {
            match steps.pop_front(){
                Option::Some(step)=> {
                    match step {
                        Step::BulkExecutionSteps((data, is_ecosystem_gas_book)) => {
                            let gas_steps = if is_ecosystem_gas_book {ecosystem_steps} else {router_steps};
                            apply_execution_steps(ref self, data, gas_price, gas_steps);  
                        },    
                        Step::SingleExecutionStep((data, is_ecosystem_gas_book)) => {
                            let gas_steps = if is_ecosystem_gas_book {ecosystem_steps} else {router_steps};
                            let (taker_order, maker_orders, total_amount_matched,as_taker_completed) = data;
                            apply_single_execution_step(ref self, taker_order, maker_orders, total_amount_matched, gas_price, gas_steps, as_taker_completed);  
                        },
                        Step::EcosystemTrades((takers, makers, iters, oracle_settled_qty)) => {
                            apply_ecosystem_trades(ref self,takers,makers,iters,oracle_settled_qty, gas_price, ecosystem_steps);
                        },
                        Step::IncreaseNonceStep(data) => {apply_increase_nonce(ref self,data, gas_price, nonce_steps)},
                        Step::WithdrawStep(data) => {apply_withdraw(ref self,data, gas_price, withdraw_steps)},
                    };
                },
                Option::None(_) => {break;}
            };
        };
    }


    fn assert_whitelisted_invokers(self: @ContractState) {
        assert!(self.exchange_invokers.read(get_caller_address()), "Access denied: Only whitelisted invokers");
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        BaseTradeEvent: base_trade_component::Event,
        SORTradeEvent: sor_trade_component::Event,

        UpdateExchangeInvoker: UpdateExchangeInvoker
    }

    #[derive(Drop, starknet::Event)]
    struct UpdateExchangeInvoker {#[key] invoker: ContractAddress, enabled: bool}


}

