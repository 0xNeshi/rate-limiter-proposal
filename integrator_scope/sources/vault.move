/// Example integration that applies the generic token bucket to a shared vault.
///
/// This module is the integrator scope for the vault domain. It takes the generic library objects
/// and turns them into a product flow with clear authority:
/// - the vault admin decides when policies are created or rotated,
/// - the vault stores which policy and state are currently active,
/// - end users only interact through deposit, read, and withdraw flows that validate those stored
///   references.
///
/// The intended flow is:
/// 1. the admin calls `create_and_share` once to create the shared vault, its withdrawal policy,
///    one registry, and the single global limiter state,
/// 2. users can deposit freely, but every withdrawal consumes from that one shared state,
/// 3. read paths such as `remaining_capacity` show the current shared headroom,
/// 4. when the admin wants new withdrawal rules, `update_policy` creates a new policy and migrates
///    the same shared state immediately because there is only one active limiter state to update.
module integrator_scope::vault;

use library_scope::token_bucket;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
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
/// that reduced availability immediately. The vault stores the active policy id and the canonical
/// shared state id so every execution path can verify it is consuming from the right limiter.
///
/// This is the key integrator check in the example. Even if someone can create some separate
/// `Policy<WithdrawTag>` through the library, it does not matter unless the vault itself recognizes
/// that policy id as active.
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
///
/// This is the one-time setup path for the example. It creates the withdrawal policy, the shared
/// registry for the withdrawal domain, and the single global state that all later withdrawals will
/// consume from, then publishes the resulting objects in their final shared or immutable form.
///
/// Reviewers should read this as the moment where the generic library objects become the vault's
/// official limiter. After this point, the vault's stored ids define which policy and state count as
/// valid for end-user operations.
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
    let state = registry.claim_global_state(&policy, clock);

    let vault = Vault {
        id: object::new(ctx),
        admin: ctx.sender(),
        policy_id: object::id(&policy),
        registry_id: object::id(&registry),
        state_id: object::id(&state),
        balance: initial_coin.into_balance(),
    };

    transfer::share_object(vault);
    transfer::public_share_object(registry);
    transfer::public_share_object(state);
    transfer::public_freeze_object(policy);
}

/// Anyone can deposit into the shared vault.
///
/// Deposits only change the vault balance. They do not interact with the rate limiter because the
/// limiter in this example is defined over withdrawals, not inflows.
public fun deposit(self: &mut Vault, deposit_coin: Coin<SUI>) {
    self.balance.join(deposit_coin.into_balance());
}

/// Current SUI balance held by the vault.
public fun value(self: &Vault): u64 {
    self.balance.value()
}

/// Read the current remaining withdrawal capacity of the shared bucket.
///
/// This is the main read path for UIs, operators, or tests that want to inspect how much shared
/// withdrawal headroom is currently left before attempting a withdrawal.
///
/// The vault first checks that the supplied policy and state are the same objects it recognizes as
/// current, so callers cannot present an arbitrary policy/state pair and ask the vault to treat it
/// as authoritative.
public fun remaining_capacity(
    self: &Vault,
    policy: &token_bucket::Policy<WithdrawTag>,
    state: &token_bucket::State<WithdrawTag>,
    clock: &Clock,
): u64 {
    assert_active_policy!(self, policy);
    assert_state!(self, state);
    policy.available(state, clock)
}

/// Withdraw from the vault while consuming from the single global token bucket state.
///
/// This is the main execution path of the example: verify the vault is paired with the supplied
/// policy and state, consume from the one shared limiter state, and only then release coins from
/// the vault balance. Because the state is global, every successful withdrawal reduces what later
/// users can withdraw until time-based refill restores capacity.
///
/// This is also why a user-created policy cannot bypass the vault's intended limit. The vault only
/// accepts the specific policy id and state id it has stored as active.
public fun withdraw(
    self: &mut Vault,
    policy: &token_bucket::Policy<WithdrawTag>,
    state: &mut token_bucket::State<WithdrawTag>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert_active_policy!(self, policy);
    assert_state!(self, state);
    policy.consume_or_abort(state, amount, clock);
    self.withdraw_unchecked(amount, ctx)
}

/// Admin-only policy rotation.
///
/// The vault migrates its single shared state immediately because there is only one active
/// limiter state for the whole vault. Reviewers should read this as the "strict but simple"
/// rollout model: one new policy is created, one existing state is migrated, and all future
/// withdrawals begin using the new rules right away.
///
/// The underlying library `create_policy` function is generic, but the vault only exposes policy
/// creation to its admin through this flow. That is the integrator's job in this design.
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
    assert_admin!(self, ctx);
    assert_active_policy!(self, current_policy);
    assert_state!(self, state);

    let next_policy = token_bucket::create_policy<WithdrawTag>(
        next_version,
        next_capacity,
        next_refill_amount,
        next_refill_interval_ms,
        ctx,
    );
    current_policy.migrate_state(&next_policy, state, clock);
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
    assert!(self.balance.value() >= amount, EInsufficientVaultBalance);
    coin::from_balance(self.balance.split(amount), ctx)
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
    assert!(balance.value() == 0, EInsufficientVaultBalance);
    balance.destroy_zero();
    object::delete(id);
}

macro fun assert_admin($self: &Vault, $ctx: &TxContext) {
    let self = $self;
    let ctx = $ctx;
    assert!(self.admin == ctx.sender(), ENotAdmin);
}

macro fun assert_active_policy($self: &Vault, $policy: &token_bucket::Policy<WithdrawTag>) {
    let self = $self;
    let policy = $policy;
    assert!(self.policy_id == object::id(policy), EWrongPolicy);
}

macro fun assert_state($self: &Vault, $state: &token_bucket::State<WithdrawTag>) {
    let self = $self;
    let state = $state;
    assert!(self.state_id == object::id(state), EWrongState);
}
