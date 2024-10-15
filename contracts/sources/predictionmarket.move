module forecaster::bitcoin_prediction_market {
    use std::signer;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use std::vector;
    use std::option::{Self, Option};

     use pyth::pyth;
    use pyth::price::Price;
    use pyth::price_identifier;

    /// Errors
    const ROUND_DURATION: u64 = 300; // 5 minutes in seconds
    const ERROR_NOT_INITIALIZED: u64 = 1;
    const ERROR_NOT_ADMIN: u64 = 2;
    const ERROR_NOT_OPERATOR: u64 = 3;
    const ERROR_ALREADY_INITIALIZED: u64 = 4;
    const ERROR_ROUND_NOT_BETTABLE: u64 = 5;
    const ERROR_INSUFFICIENT_BET: u64 = 6;
    const ERROR_ALREADY_BET: u64 = 7;
    const ERROR_ROUND_NOT_ENDED: u64 = 8;
    const ERROR_ROUND_ENDED: u64 = 9;
    const ERROR_NOT_CLAIMABLE: u64 = 10;
    const ERROR_ALREADY_CLAIMED: u64 = 11;
    const ERROR_INVALID_EPOCH: u64 = 12;

    /// Constants
    const MAX_TREASURY_FEE: u64 = 1000; // 10%
    const PYTH_BTC_PRICE_FEED_ID: vector<u8> = x"e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43";

    struct PredictionMarket has key {
        admin: address,
        operator: address,
        oracle: address,
        current_epoch: u64,
        treasury_fee: u64,
        treasury_amount: u64,
        rounds: vector<Round>,
        paused: bool,
        last_round_time: u64,
    }

    struct Round has store, drop {
        epoch: u64,
        start_timestamp: u64,
        end_timestamp: u64,
        start_price: u64,
        end_price: u64,
        total_amount: u64,
        bull_amount: u64,
        bear_amount: u64,
        reward_amount: u64,
        reward_base_cal_amount: u64,
        resolved: bool,
    }

    struct UserBet has store, drop, copy {
        epoch: u64,
        position: bool, // true for Bull, false for Bear
        amount: u64,
        claimed: bool,
    }

    struct UserBets has key {
        bets: vector<UserBet>,
    }

    public fun initialize(admin: &signer, operator: address, oracle: address, treasury_fee: u64) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<PredictionMarket>(admin_addr), ERROR_ALREADY_INITIALIZED);
        assert!(treasury_fee <= MAX_TREASURY_FEE, ERROR_INVALID_EPOCH);

        move_to(admin, PredictionMarket {
            admin: admin_addr,
            operator,
            oracle,
            current_epoch: 0,
            treasury_fee,
            treasury_amount: 0,
            rounds: vector::empty(),
            paused: false,
            last_round_time: 0,
        });

        // Start the first round
        start_new_round(admin);
    }

    public fun start_new_round(operator: &signer) acquires PredictionMarket {
        let operator_addr = signer::address_of(operator);
        let market = borrow_global_mut<PredictionMarket>(@forecaster);
        
        assert!(operator_addr == market.operator, ERROR_NOT_OPERATOR);
        assert!(!market.paused, ERROR_NOT_INITIALIZED);

        let current_timestamp = timestamp::now_seconds();
        assert!(current_timestamp >= market.last_round_time + ROUND_DURATION, ERROR_ROUND_NOT_ENDED);

        let new_epoch = market.current_epoch + 1;
        let current_price = get_bitcoin_price();

        let new_round = Round {
            epoch: new_epoch,
            start_timestamp: current_timestamp,
            end_timestamp: current_timestamp + ROUND_DURATION,
            start_price: current_price,
            end_price: 0,
            total_amount: 0,
            bull_amount: 0,
            bear_amount: 0,
            reward_amount: 0,
            reward_base_cal_amount: 0,
            resolved: false,
        };

        vector::push_back(&mut market.rounds, new_round);
        market.current_epoch = new_epoch;
        market.last_round_time = current_timestamp;
    }

    public fun resolve_round(operator: &signer) acquires PredictionMarket {
        let operator_addr = signer::address_of(operator);
        let market = borrow_global_mut<PredictionMarket>(@forecaster);
        
        assert!(operator_addr == market.operator, ERROR_NOT_OPERATOR);
        assert!(!market.paused, ERROR_NOT_INITIALIZED);

        let current_timestamp = timestamp::now_seconds();
        let current_round = vector::borrow_mut(&mut market.rounds, market.current_epoch - 1);
        
        assert!(current_timestamp >= current_round.end_timestamp, ERROR_ROUND_NOT_ENDED);
        assert!(!current_round.resolved, ERROR_ROUND_ENDED);

        let end_price = get_bitcoin_price();
        current_round.end_price = end_price;
        current_round.resolved = true;

        // Calculate rewards
        let reward_amount = if (end_price > current_round.start_price) {
            // Bull wins
            current_round.reward_base_cal_amount = current_round.bull_amount;
            current_round.total_amount - (current_round.total_amount * market.treasury_fee / 10000)
        } else if (end_price < current_round.start_price) {
            // Bear wins
            current_round.reward_base_cal_amount = current_round.bear_amount;
            current_round.total_amount - (current_round.total_amount * market.treasury_fee / 10000)
        } else {
            // House wins
            current_round.reward_base_cal_amount = 0;
            0
        };

        current_round.reward_amount = reward_amount;
        market.treasury_amount = market.treasury_amount + (current_round.total_amount - reward_amount);

        // Start a new round
        start_new_round(operator);
    }

    public fun bet_bull(user: &signer, amount: u64) acquires PredictionMarket, UserBets {
        bet_internal(user, coin::withdraw<AptosCoin>(user, amount), true)
    }

    public fun bet_bear(user: &signer, amount: u64) acquires PredictionMarket, UserBets {
        bet_internal(user, coin::withdraw<AptosCoin>(user, amount), false)
    }

    fun bet_internal(user: &signer, amount: Coin<AptosCoin>, is_bull: bool) acquires PredictionMarket, UserBets {
        let user_addr = signer::address_of(user);
        let market = borrow_global_mut<PredictionMarket>(@forecaster);
        
        assert!(!market.paused, ERROR_NOT_INITIALIZED);
        let current_round = vector::borrow_mut(&mut market.rounds, market.current_epoch - 1);
        
        assert!(is_round_bettable(current_round), ERROR_ROUND_NOT_BETTABLE);

        // Update round data
        let bet_amount = coin::value(&amount);
        current_round.total_amount = current_round.total_amount + bet_amount;
        if (is_bull) {
            current_round.bull_amount = current_round.bull_amount + bet_amount;
        } else {
            current_round.bear_amount = current_round.bear_amount + bet_amount;
        };

        // Update user data
        if (!exists<UserBets>(user_addr)) {
            move_to(user, UserBets { bets: vector::empty() });
        };
        let user_bets = borrow_global_mut<UserBets>(user_addr);
        vector::push_back(&mut user_bets.bets, UserBet {
            epoch: current_round.epoch,
            position: is_bull,
            amount: bet_amount,
            claimed: false,
        });

        // Transfer the bet amount to the contract
        coin::deposit(@forecaster, amount);
    }

    public fun claim(user: &signer, epoch: u64) acquires PredictionMarket, UserBets {
        let user_addr = signer::address_of(user);
        let market = borrow_global<PredictionMarket>(@forecaster);
        
        assert!(epoch < market.current_epoch, ERROR_ROUND_NOT_ENDED);
        let round = vector::borrow(&market.rounds, epoch - 1);
        assert!(round.resolved, ERROR_ROUND_NOT_ENDED);

        let user_bets = borrow_global_mut<UserBets>(user_addr);
        let user_bet_opt = find_user_bet(&mut user_bets.bets, epoch);
        assert!(option::is_some(&user_bet_opt), ERROR_NOT_CLAIMABLE);

        let user_bet = option::borrow_mut(&mut user_bet_opt);
        assert!(!user_bet.claimed, ERROR_ALREADY_CLAIMED);

        let reward_amount = if ((round.end_price > round.start_price && user_bet.position) ||
                                (round.end_price < round.start_price && !user_bet.position)) {
            (user_bet.amount * round.reward_amount) / round.reward_base_cal_amount
        } else {
            0
        };

        user_bet.claimed = true;
        if (reward_amount > 0) {
            coin::transfer<AptosCoin>(@forecaster, user_addr, reward_amount);
        };
    }

    fun find_user_bet(bets: &mut vector<UserBet>, epoch: u64): Option<UserBet> {
        let length = vector::length(bets);
        let i = 0;
        while (i < length) {
            let bet = vector::borrow(bets, i);
            if (bet.epoch == epoch) {
                return option::some(*bet);
            };
            i = i + 1;
        };
        option::none()
    }

   /*public fun get_bitcoin_price(): u64 {
    let btc_price_id = price_identifier::from_byte_vec(PYTH_BTC_PRICE_FEED_ID);
    let price_feed = pyth::get_price_feed_from_price_identifier(btc_price_id);
    let current_price = pyth::get_price(price_feed);
    let price_value = price::get_price(&current_price);
    let expo = price::get_expo(&current_price);

    // Adjust the price based on the exponent value
    if (expo < 0) {
        let abs_expo = u64::from(0 - expo);
        price_value / (10u64 ** abs_expo)
    } else {
        price_value * (10u64 ** (expo as u64))
    }
}*/
public fun get_bitcoin_price(user: &signer, pyth_price_update: vector<vector<u8>>): Price {
 
        // First update the Pyth price feeds
        let coins = coin::withdraw(user, pyth::get_update_fee(&pyth_price_update));
        pyth::update_price_feeds(pyth_price_update, coins);
 
        // Read the current price from a price feed.
        // Each price feed (e.g., BTC/USD) is identified by a price feed ID.
        // The complete list of feed IDs is available at https://pyth.network/developers/price-feed-ids
        // Note: Aptos uses the Pyth price feed ID without the `0x` prefix.
        let btc_price_identifier = x"e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43";
        let btc_usd_price_id = price_identifier::from_byte_vec(btc_price_identifier);
        pyth::get_price(btc_usd_price_id)
    }




    fun is_round_bettable(round: &Round): bool {
        let current_time = timestamp::now_seconds();
        !round.resolved && current_time >= round.start_timestamp && current_time < round.end_timestamp
    }

    public fun pause_market(admin: &signer) acquires PredictionMarket {
        let admin_addr = signer::address_of(admin);
        let market = borrow_global_mut<PredictionMarket>(@forecaster);
        assert!(admin_addr == market.admin, ERROR_NOT_ADMIN);
        market.paused = true;
    }

    public fun unpause_market(admin: &signer) acquires PredictionMarket {
        let admin_addr = signer::address_of(admin);
        let market = borrow_global_mut<PredictionMarket>(@forecaster);
        assert!(admin_addr == market.admin, ERROR_NOT_ADMIN);
        market.paused = false;
    }
}