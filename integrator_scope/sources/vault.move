module integrator_scope::vault;

use library_scope::token_bucket;
use sui::balance::{Self as balance, Balance};
use sui::clock::Clock;
use sui::coin::{Self as coin, Coin};
use sui::sui::SUI;

#[error(code = 0)]
const EInsufficientVaultBalance: vector<u8> = "Insufficient vault balance";
#[error(code = 1)]
const EWrongPolicy: vector<u8> = "Wrong policy";
#[error(code = 2)]
const EWrongState: vector<u8> = "Wrong state";
#[error(code = 3)]
const ENotAdmin: vector<u8> = "Only the vault admin can do this";

/// Shared vault example that uses one global token bucket for all withdrawals.
///
/// If user A withdraws first, the global bucket is partially or fully consumed and user B sees
/// that reduced availability immediately.
public struct Vault has key, store {
    id: UID,
    admin: address,
    policy_id: ID,
    registry_id: ID,
    state_id: ID,
    balance: Balance<SUI>,
}

/// Tag used to separate the vault withdrawal limiter from any other domain.
public struct WithdrawTag has copy, drop, store {}

/// Create the vault and fully initialize its token bucket objects in one transaction.
#[allow(lint(share_owned))]
public fun create_and_share(
    initial_coin: Coin<SUI>,
    version: u16,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let policy = token_bucket::create_policy<WithdrawTag>(
        version,
        capacity,
        refill_amount,
        refill_interval_ms,
        ctx,
    );
    let mut registry = token_bucket::create_registry<WithdrawTag>(ctx);
    let state = token_bucket::claim_global_state(&mut registry, &policy, clock);

    let vault = Vault {
        id: object::new(ctx),
        admin: tx_context::sender(ctx),
        policy_id: object::id(&policy),
        registry_id: object::id(&registry),
        state_id: object::id(&state),
        balance: coin::into_balance(initial_coin),
    };

    transfer::share_object(vault);
    transfer::public_share_object(registry);
    transfer::public_share_object(state);
    transfer::public_freeze_object(policy);
}

/// Anyone can deposit into the shared vault.
public fun deposit(self: &mut Vault, deposit_coin: Coin<SUI>) {
    balance::join(&mut self.balance, coin::into_balance(deposit_coin));
}

/// Current SUI balance held by the vault.
public fun value(self: &Vault): u64 {
    balance::value(&self.balance)
}

/// Read the current remaining withdrawal capacity of the shared bucket.
public fun remaining_capacity(
    self: &Vault,
    policy: &token_bucket::Policy<WithdrawTag>,
    state: &token_bucket::State<WithdrawTag>,
    clock: &Clock,
): u64 {
    assert_active_policy(self, policy);
    assert_state(self, state);
    token_bucket::available(policy, state, clock)
}

/// Withdraw from the vault while consuming from the single global token bucket state.
public fun withdraw(
    self: &mut Vault,
    policy: &token_bucket::Policy<WithdrawTag>,
    state: &mut token_bucket::State<WithdrawTag>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert_active_policy(self, policy);
    assert_state(self, state);
    token_bucket::consume_or_abort(policy, state, amount, clock);
    withdraw_unchecked(self, amount, ctx)
}

/// Admin-only policy rotation.
///
/// The vault migrates its single shared state immediately because there is only one active
/// limiter state for the whole vault.
public fun update_policy(
    self: &mut Vault,
    current_policy: &token_bucket::Policy<WithdrawTag>,
    state: &mut token_bucket::State<WithdrawTag>,
    next_version: u16,
    next_capacity: u64,
    next_refill_amount: u64,
    next_refill_interval_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_admin(self, ctx);
    assert_active_policy(self, current_policy);
    assert_state(self, state);

    let next_policy = token_bucket::create_policy<WithdrawTag>(
        next_version,
        next_capacity,
        next_refill_amount,
        next_refill_interval_ms,
        ctx,
    );
    token_bucket::migrate_state(current_policy, &next_policy, state, clock);
    self.policy_id = object::id(&next_policy);
    transfer::public_freeze_object(next_policy);
}

public fun active_policy_id(self: &Vault): ID {
    self.policy_id
}

public fun registry_id(self: &Vault): ID {
    self.registry_id
}

public fun state_id(self: &Vault): ID {
    self.state_id
}

public fun admin(self: &Vault): address {
    self.admin
}

public fun withdraw_unchecked(self: &mut Vault, amount: u64, ctx: &mut TxContext): Coin<SUI> {
    assert!(balance::value(&self.balance) >= amount, EInsufficientVaultBalance);
    coin::from_balance(balance::split(&mut self.balance, amount), ctx)
}

#[test_only]
public fun destroy_empty_for_testing(self: Vault) {
    let Vault {
        id,
        admin: _,
        policy_id: _,
        registry_id: _,
        state_id: _,
        balance,
    } = self;
    assert!(balance::value(&balance) == 0, EInsufficientVaultBalance);
    balance::destroy_zero(balance);
    object::delete(id);
}

fun assert_admin(self: &Vault, ctx: &TxContext) {
    assert!(self.admin == tx_context::sender(ctx), ENotAdmin);
}

fun assert_active_policy(self: &Vault, policy: &token_bucket::Policy<WithdrawTag>) {
    assert!(self.policy_id == object::id(policy), EWrongPolicy);
}

fun assert_state(self: &Vault, state: &token_bucket::State<WithdrawTag>) {
    assert!(self.state_id == object::id(state), EWrongState);
}
