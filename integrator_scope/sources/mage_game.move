/// Example integration that applies the embedded `RateLimiter` to a game with per-mage mana.
///
/// The game holds the current mana configuration and a version number. Each mage is an
/// owned object that embeds its own `RateLimiter` along with the policy version it was
/// initialised under. Hot paths only succeed when a mage's policy version matches the
/// game's current policy version.
///
/// Even Web2 games enforce similar requirements, where a Player (end user) cannot play the
/// Game unless the version of the Game on their machine (limiter state) is upgraded to the
/// most recent version.
///
/// The intended flow is:
/// 1. the admin calls `create_and_share` once to set the initial mana configuration,
/// 2. players call `create_mage`, which embeds a fresh bucket limiter sized by the game's
///    current configuration and tagged with the current policy version,
/// 3. gameplay calls such as `cast_*` consume from that mage's limiter only, and require the
///    mage's policy version to match the game's,
/// 4. when the admin changes the policy, existing mages must call `update_mage_policy` to
///    reconfigure their limiter and adopt the new version before they can keep casting.
module integrator_scope::mage_game;

use library_scope::rate_limiter::{Self, RateLimiter};
use sui::clock::Clock;

// === Errors ===

#[error(code = 0)]
const ENotAdmin: vector<u8> = "Only the game admin can do this";
#[error(code = 1)]
const EStaleMagePolicy: vector<u8> = "Mage must be upgraded to the latest policy";
#[error(code = 2)]
const ENotMageOwner: vector<u8> = "Only the mage owner can do this";

// === Constants ===

const EXPELIARMUS_COST: u64 = 10;
const CRUCIO_COST: u64 = 20;
const AVADA_KEDAVRA_COST: u64 = 30;

// === Structs ===

/// Shared game object that holds the current mana configuration and policy version.
///
/// The configuration fields are the template applied to newly created mages and to mages
/// that migrate themselves. The version is what the game checks against on every cast so
/// that a stale mage cannot slip through under old rules.
public struct Game has key {
    id: UID,
    admin: address,
    policy_version: u16,
    mana_capacity: u64,
    mana_refill_amount: u64,
    mana_refill_interval_ms: u64,
}

/// Owned mage object with its own embedded mana limiter.
///
/// Each mage carries its own accounting, so one mage's usage never drains another mage's
/// mana. The `policy_version` field records which generation of rules the mage's limiter
/// was configured under, and gameplay requires it to equal the game's current version.
public struct Mage has key, store {
    id: UID,
    owner: address,
    policy_version: u16,
    mana: RateLimiter,
}

// === Public Functions ===

/// Create the shared game with its initial mana configuration.
public fun create_and_share(
    version: u16,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    ctx: &mut TxContext,
) {
    let game = Game {
        id: object::new(ctx),
        admin: ctx.sender(),
        policy_version: version,
        mana_capacity: capacity,
        mana_refill_amount: refill_amount,
        mana_refill_interval_ms: refill_interval_ms,
    };
    transfer::share_object(game);
}

/// Anyone can create a mage in the game.
///
/// The mage's mana limiter starts full at the game's current capacity and is tagged with
/// the game's current policy version, so the mage is immediately usable under the current
/// rules without a separate onboarding migration.
public fun create_mage(game: &Game, clock: &Clock, ctx: &mut TxContext): Mage {
    Mage {
        id: object::new(ctx),
        owner: ctx.sender(),
        policy_version: game.policy_version,
        mana: rate_limiter::new_bucket(
            game.mana_capacity,
            game.mana_refill_amount,
            game.mana_refill_interval_ms,
            clock,
        ),
    }
}

/// Public path for a player to upgrade their mage to the latest game policy.
///
/// Accrues mana under the old configuration first, then reconfigures the embedded limiter
/// to the game's current settings, clamping stored tokens to the new capacity. The mage's
/// policy version is advanced to the game's version so subsequent casts succeed.
public fun update_mage_policy(game: &Game, mage: &mut Mage, clock: &Clock, ctx: &TxContext) {
    assert_owner!(mage, ctx);
    mage.mana.reconfigure_bucket(
        game.mana_capacity,
        game.mana_refill_amount,
        game.mana_refill_interval_ms,
        clock,
    );
    mage.policy_version = game.policy_version;
}

/// Admin-only policy change.
///
/// Updates the game's stored configuration and bumps the policy version. Existing mages
/// are not automatically migrated; each mage must call `update_mage_policy` before it can
/// keep casting. This is the staged rollout model: new rules take effect per mage, on demand.
public fun update_policy(
    game: &mut Game,
    next_version: u16,
    next_capacity: u64,
    next_refill_amount: u64,
    next_refill_interval_ms: u64,
    ctx: &TxContext,
) {
    assert_admin!(game, ctx);
    game.policy_version = next_version;
    game.mana_capacity = next_capacity;
    game.mana_refill_amount = next_refill_amount;
    game.mana_refill_interval_ms = next_refill_interval_ms;
}

/// Cast a low-cost spell using the mage's current mana state.
public fun cast_expeliarmus(game: &Game, mage: &mut Mage, clock: &Clock, ctx: &TxContext) {
    game.cast_spell(mage, EXPELIARMUS_COST, clock, ctx)
}

/// Cast a medium-cost spell using the mage's current mana state.
public fun cast_crucio(game: &Game, mage: &mut Mage, clock: &Clock, ctx: &TxContext) {
    game.cast_spell(mage, CRUCIO_COST, clock, ctx)
}

/// Cast a high-cost spell using the mage's current mana state.
public fun cast_avada_kedavra(game: &Game, mage: &mut Mage, clock: &Clock, ctx: &TxContext) {
    game.cast_spell(mage, AVADA_KEDAVRA_COST, clock, ctx)
}

// === View Helpers ===

/// Read the mage's currently available mana under the game's active policy.
///
/// Aborts with `EStaleMagePolicy` if the mage has not been migrated to the game's current
/// policy version, so this doubles as the "is the mage current?" check for UIs.
public fun mana(game: &Game, mage: &Mage, clock: &Clock): u64 {
    assert!(mage.policy_version == game.policy_version, EStaleMagePolicy);
    mage.mana.available(clock)
}

public fun owner(mage: &Mage): address {
    mage.owner
}

public fun policy_version(game: &Game): u16 {
    game.policy_version
}

public fun mage_policy_version(mage: &Mage): u16 {
    mage.policy_version
}

// === Private Functions ===

fun cast_spell(
    game: &Game,
    mage: &mut Mage,
    mana_cost: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_owner!(mage, ctx);
    assert!(mage.policy_version == game.policy_version, EStaleMagePolicy);
    mage.mana.consume_or_abort(mana_cost, clock);
}

macro fun assert_admin($game: &Game, $ctx: &TxContext) {
    let game = $game;
    let ctx = $ctx;
    assert!(game.admin == ctx.sender(), ENotAdmin);
}

macro fun assert_owner($mage: &Mage, $ctx: &TxContext) {
    let mage = $mage;
    let ctx = $ctx;
    assert!(mage.owner == ctx.sender(), ENotMageOwner);
}

// === Test-Only Helpers ===

#[test_only]
public fun destroy_mage_for_testing(mage: Mage) {
    let Mage { id, owner: _, policy_version: _, mana: _ } = mage;
    id.delete();
}
