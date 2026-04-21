/// Example integration that embeds a `RateLimiter` inside a shared vault.
///
/// The vault is a single shared object that carries its own rate limiter as a field. There
/// is no separate policy, registry, or state object: the limiter lives inside the vault, so
/// every execution path that already has `&mut Vault` also has `&mut` access to the one
/// limiter that controls withdrawals.
///
/// The intended flow is:
/// 1. the admin calls `create_and_share` once to create the shared vault with an initial
///    withdrawal bucket,
/// 2. users can deposit freely, but every withdrawal consumes from the embedded limiter,
/// 3. read paths such as `remaining_capacity` show the current shared headroom,
/// 4. the admin can call `update_policy` to rewrite the limiter's configuration in place;
///    existing token balance is clamped to the new capacity.
module integrator_scope::vault;

use library_scope::rate_limiter::{Self, RateLimiter};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::sui::SUI;

// === Errors ===

#[error(code = 0)]
const EInsufficientVaultBalance: vector<u8> = "Insufficient vault balance";
#[error(code = 1)]
const ENotAdmin: vector<u8> = "Only the vault admin can do this";

// === Structs ===

/// Shared vault that embeds one global withdrawal limiter.
///
/// Because the limiter lives inside the vault, every successful withdrawal reduces what
/// later users can withdraw until time-based refill restores capacity. There is no way for
/// a user to present a different limiter: the only one that counts is the field on the
/// shared vault object.
public struct Vault has key {
    id: UID,
    admin: address,
    limiter: RateLimiter,
    balance: Balance<SUI>,
}

// === Public Functions ===

/// Create the shared vault with an initial withdrawal bucket in one transaction.
///
/// This is the one-time setup path. It seeds the vault balance from `initial_coin`, creates
/// the embedded token bucket limiter, and shares the resulting vault. No auxiliary policy or
/// state objects are produced.
public fun create_and_share(
    initial_coin: Coin<SUI>,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let vault = Vault {
        id: object::new(ctx),
        admin: ctx.sender(),
        limiter: rate_limiter::new_bucket(capacity, refill_amount, refill_interval_ms, clock),
        balance: initial_coin.into_balance(),
    };
    transfer::share_object(vault);
}

/// Anyone can deposit into the shared vault.
///
/// Deposits only change the vault balance. They do not interact with the rate limiter
/// because the limiter in this example is defined over withdrawals, not inflows.
public fun deposit(self: &mut Vault, deposit_coin: Coin<SUI>) {
    self.balance.join(deposit_coin.into_balance());
}

/// Current SUI balance held by the vault.
public fun value(self: &Vault): u64 {
    self.balance.value()
}

/// Read the current remaining withdrawal capacity of the embedded bucket.
public fun remaining_capacity(self: &Vault, clock: &Clock): u64 {
    self.limiter.available(clock)
}

/// Withdraw from the vault while consuming from the embedded limiter.
///
/// This is the main execution path: consume `amount` from the limiter, then release coins
/// from the vault balance. Because the limiter is owned by the vault, every successful
/// withdrawal reduces what later users can withdraw until refill restores capacity.
public fun withdraw(
    self: &mut Vault,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    self.limiter.consume_or_abort(amount, clock);
    self.withdraw_unchecked(amount, ctx)
}

/// Admin-only policy update.
///
/// Rewrites the embedded limiter's configuration in place. Any tokens earned under the old
/// configuration are credited first, then the configuration is updated and the stored token
/// balance is clamped to the new capacity. There is no separate rotation or migration step
/// because the vault only ever has one limiter.
public fun update_policy(
    self: &mut Vault,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_admin!(self, ctx);
    self.limiter.reconfigure_bucket(capacity, refill_amount, refill_interval_ms, clock);
}

// === View Helpers ===

public fun admin(self: &Vault): address {
    self.admin
}

public fun withdraw_unchecked(self: &mut Vault, amount: u64, ctx: &mut TxContext): Coin<SUI> {
    assert!(self.balance.value() >= amount, EInsufficientVaultBalance);
    coin::from_balance(self.balance.split(amount), ctx)
}

// === Private Functions ===

macro fun assert_admin($self: &Vault, $ctx: &TxContext) {
    let self = $self;
    let ctx = $ctx;
    assert!(self.admin == ctx.sender(), ENotAdmin);
}

// === Test-Only Helpers ===

#[test_only]
public fun destroy_empty_for_testing(self: Vault) {
    let Vault { id, admin: _, limiter: _, balance } = self;
    assert!(balance.value() == 0, EInsufficientVaultBalance);
    balance.destroy_zero();
    id.delete();
}
