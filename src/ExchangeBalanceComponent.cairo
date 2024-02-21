use starknet::ContractAddress;
use kurosawa_akira::Order::{GasFee, FixedFee, get_gas_fee_and_coin, get_feeable_qty};



#[starknet::interface]
trait INewExchangeBalance<TContractState> {
    fn total_supply(self: @TContractState, token: ContractAddress) -> u256;

    fn balanceOf(self: @TContractState, address: ContractAddress, token: ContractAddress) -> u256;

    fn balancesOf(self: @TContractState, addresses: Span<ContractAddress>, tokens: Span<ContractAddress>) -> Array<Array<u256>>;

    fn get_wrapped_native_token(self: @TContractState) -> ContractAddress;

    fn get_latest_gas_price(self: @TContractState)->u256;

    fn get_fee_recipient(self: @TContractState) -> ContractAddress;

}



#[starknet::component]
mod exchange_balance_logic_component {
    use starknet::{ContractAddress, get_caller_address};
    use super::{INewExchangeBalance, FixedFee, get_feeable_qty};
    use kurosawa_akira::utils::common::DisplayContractAddress;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Mint:Mint,
        Transfer:Transfer,
        Burn:Burn,
        FeeReward:FeeReward,
        Punish:Punish,
        Trade:Trade
    }

    // Debug events
    #[derive(Drop, starknet::Event)]
    struct Mint {
        token:ContractAddress,
        to:ContractAddress,
        amount:u256
    }
    #[derive(Drop, starknet::Event)]
    struct Burn {
        from_:ContractAddress,
        token:ContractAddress,
        amount:u256
    }

    #[derive(Drop, starknet::Event)]
    struct Transfer {
        token: ContractAddress,
        from_: ContractAddress,
        to: ContractAddress,
        amount: u256
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
        maker:ContractAddress, taker:ContractAddress,
        #[key]
        ticker:(ContractAddress,ContractAddress),
        #[key]
        router_maker:ContractAddress, router_taker:ContractAddress,
        amount_base: u256, amount_quote: u256,
        is_sell_side: bool, is_failed: bool, is_ecosystem_book:bool
    }


    #[storage]
    struct Storage {
        _total_supply: LegacyMap::<ContractAddress, u256>, // TVL per token
        _balances: LegacyMap::<(ContractAddress, ContractAddress), u256>, // (token, address) -> balance
        wrapped_native_token: ContractAddress, // ERC20 token in which rollup executer pays the gas fee to sequencer
        fee_recipient: ContractAddress, // receiver of exchange fees
        latest_gas: u256, // latest gas price estimation
    }


    #[embeddable_as(ExchangeBalanceble)]
    impl ExchangeBalancebleImpl<TContractState, +HasComponent<TContractState>> of INewExchangeBalance<ComponentState<TContractState>> {
        
        fn total_supply(self: @ComponentState<TContractState>, token: ContractAddress) -> u256 {return self._total_supply.read(token);}

        fn balanceOf(self: @ComponentState<TContractState>, address: ContractAddress, token: ContractAddress) -> u256 {
            return self._balances.read((token, address));
        }

        fn balancesOf(self: @ComponentState<TContractState>, addresses: Span<ContractAddress>, tokens: Span<ContractAddress>) -> Array<Array<u256>> {
            // Note addresses and tokens should be not empty
            let mut res: Array<Array<u256>> = ArrayTrait::new();
            let sz_addr = addresses.len();
            let sz_token = tokens.len();
            let mut idx_addr = 0;
            loop {
                let addr = *addresses.at(idx_addr);
                let mut sub_res: Array<u256> = ArrayTrait::new();
                let mut idx_token = 0;
                loop {
                    let token = *tokens.at(idx_token);
                    sub_res.append(self._balances.read((token, addr)));
                    idx_token += 1;
                    if sz_token == idx_token { break;}
                };
                res.append(sub_res);
                idx_addr += 1;
                if sz_addr == idx_addr { break;}
            };
            return res;
        }

        fn get_wrapped_native_token(self: @ComponentState<TContractState>) -> ContractAddress { return self.wrapped_native_token.read();}

        fn get_fee_recipient(self: @ComponentState<TContractState>) -> ContractAddress { return self.fee_recipient.read();}
        fn get_latest_gas_price(self: @ComponentState<TContractState>) -> u256 { return self.latest_gas.read();}
    }
    
    #[generate_trait]
    impl InternalExchangeBalancebleImpl<TContractState, +HasComponent<TContractState>> of InternalExchangeBalanceble<TContractState> {
        fn initializer(ref self: ComponentState<TContractState>, fee_recipient:ContractAddress, wrapped_native_token:ContractAddress) {
            self.wrapped_native_token.write(wrapped_native_token);
            self.fee_recipient.write(fee_recipient);
            self.latest_gas.write(1000); // some non zero placeholder on init
        }

        fn mint(ref self: ComponentState<TContractState>,to: ContractAddress, amount: u256, token: ContractAddress) {
            self._total_supply.write(token, self._total_supply.read(token) + amount);
            self._balances.write((token, to), self._balances.read((token, to)) + amount);
            self.emit(Mint{to, token, amount});
        }

        fn burn(ref self: ComponentState<TContractState>, from: ContractAddress, amount: u256, token: ContractAddress) {
            let balance = self._balances.read((token, from));
            assert!(balance >= amount,"FEW_TO_BURN");
            self._balances.write((token, from), balance - amount);
            self._total_supply.write(token, self._total_supply.read(token) - amount);
            self.emit(Burn{from_:from,token,amount});
        }
        fn internal_transfer(ref self: ComponentState<TContractState>, from: ContractAddress, to: ContractAddress, amount: u256, token: ContractAddress) {
            assert!(self._balances.read((token, from)) >= amount, "FEW_BALANCE");
            self._balances.write((token, from), self._balances.read((token, from)) - amount);
            self._balances.write((token, to), self._balances.read((token, to)) + amount);
            self.emit(Transfer{from_:from, to, token, amount});
        }

        fn validate_and_apply_gas_fee_internal(ref self: ComponentState<TContractState>, user: ContractAddress, gas_fee: super::GasFee, gas_price: u256, times:u16, cur_gas_per_action:u32) -> u256 {
            // Validates that gas_fee correctly specified, calculate how many coins and in what token we tfer from user to exchange  
            if gas_price == 0 || gas_fee.gas_per_action == 0 { return 0;}
            let (spent, coin) = super::get_gas_fee_and_coin(gas_fee, gas_price, self.wrapped_native_token.read(), cur_gas_per_action);
            let spent = spent * times.into(); // we can do gas_price * times.into() to avoid zero spnet  but prefer this way
            self.internal_transfer(user, self.fee_recipient.read(), spent, coin);
            return spent;
        }

        fn rebalance_after_trade(ref self: ComponentState<TContractState>, maker:ContractAddress, taker:ContractAddress, ticker:(ContractAddress, ContractAddress),
            amount_base:u256, amount_quote:u256, is_maker_seller:bool) {
            let (base, quote) = ticker;
            if is_maker_seller{ // BASE/QUOTE -> maker sell BASE for QUOTE
                assert!(self.balanceOf(maker, base) >= amount_base, "Failed: maker base balance ({}) >= trade base amount ({}) -- few balance maker", self.balanceOf(maker, base), amount_base);
                self.internal_transfer(maker, taker, amount_base, base);
                
                assert!(self.balanceOf(taker, quote) >= amount_quote, "Failed: taker quote balance ({}) >= trade quote amount ({}) -- few balance taker", self.balanceOf(taker, quote), amount_quote);
                self.internal_transfer(taker, maker, amount_quote, quote);
            }
            else { // BASE/QUOTE -> maker buy BASE for QUOTE
                assert!(self.balanceOf(maker, quote) >= amount_quote, "Failed: maker quote balance ({}) >= trade quote amount ({}) -- few balance maker", self.balanceOf(maker, quote), amount_quote);
                self.internal_transfer(maker, taker, amount_quote, quote);
                assert!(self.balanceOf(taker, base) >= amount_base, "Failed: taker base balance ({}) >= trade base amount ({}) -- few balance taker", self.balanceOf(taker, base), amount_base);
                self.internal_transfer(taker, maker, amount_base, base);
            }
        }

        fn apply_fixed_fee(ref self: ComponentState<TContractState>, trader:ContractAddress, fee:FixedFee, is_sell_side:bool, ticker:(ContractAddress,ContractAddress), base_amount:u256, quote_amount:u256, is_maker:bool) -> (ContractAddress, u256) {
            let (fee_token, fee_amount) = if is_sell_side { let (b, q) = ticker; (q, quote_amount) } else {let (b, q) = ticker; (b, base_amount)};
            let fee_amount = get_feeable_qty(fee, fee_amount, is_maker);
            if fee_amount > 0 { self.internal_transfer(trader, fee.recipient, fee_amount, fee_token);}
            return (fee_token, fee_amount);
        }
    }
}