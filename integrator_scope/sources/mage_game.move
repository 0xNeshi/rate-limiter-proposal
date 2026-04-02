/// Example integration that applies the generic token bucket to a game with per-mage mana.
///
/// This module is the integrator scope for the mana domain. It takes the generic library objects
/// and turns them into a product flow with separate responsibilities:
/// - the game admin decides when a new mana policy becomes active,
/// - the game stores which policy is currently active,
/// - each mage owns its own wrapped state,
/// - end users can only cast successfully when their mage state is current with the game's active
///   policy.
///
/// Even Web2 games enforce similar requirements, where a Player (end user) cannot play the Game
/// unless the version (Policy) of the Game on their machine (`State`) is upgraded to the most
/// recent version.
///
/// The intended flow is:
/// 1. the admin calls `create_and_share` once to create the game, its registry, and the first mana
///    policy,
/// 2. players later call `create_mage`, which claims a fresh object-scoped mana state for each mage
///    under the game's current policy,
/// 3. gameplay calls such as `cast_*` consume from that mage's wrapped state only,
/// 4. when the admin rotates policy, the game points to the new policy immediately but existing
///    mages must call `update_mage_policy` before they can keep casting under the new rules.
module integrator_scope::mage_game;

use library_scope::token_bucket;
use sui::clock::Clock;

const EXPELIARMUS_COST: u64 = 10;
const CRUCIO_COST: u64 = 20;
const AVADA_KEDAVRA_COST: u64 = 30;

#[error(code = 0)]
const ENotAdmin: vector<u8> = "Only the game admin can do this";
#[error(code = 1)]
const EWrongPolicy: vector<u8> = "Wrong policy";
#[error(code = 2)]
const EStaleMagePolicy: vector<u8> = "Mage must be upgraded to the latest policy";
#[error(code = 3)]
const ENotMageOwner: vector<u8> = "Only the mage owner can do this";

/// Shared game object that points to the latest active mana policy and the shared registry.
///
/// The game is the integration-level source of truth for which policy new mages and current reads
/// should use, but it does not directly hold each mage's mutable mana accounting.
///
/// This is the key integrator check in the example. A player may be able to reference some policy
/// object, but gameplay only accepts the policy id that the game currently marks as active.
public struct Game has key, store {
    id: UID,
    admin: address,
    active_policy_id: ID,
    registry_id: ID,
}

/// Owned mage object with its own wrapped mana state.
///
/// Wrapping the state inside the mage keeps the example compact and makes it obvious that each
/// mage's mana accounting is independent from every other mage's mana accounting.
///
/// The mage is the end-user-facing object in this example. The player does not manage raw limiter
/// state separately in normal use; the state travels with the mage and is checked against the
/// game's active policy during reads and casts.
public struct Mage has key, store {
    id: UID,
    owner: address,
    mana: token_bucket::State<ManaTag>,
}

/// Tag separating the mana limiter domain from every other token bucket domain.
public struct ManaTag has copy, drop, store {}

/// Create a game, a shared registry, and the first immutable mana policy.
///
/// This is the one-time setup path for the example. It establishes the shared infrastructure for
/// the mana domain, but it does not create any mage states yet because those are claimed later as
/// players onboard individual mages.
///
/// Reviewers should read this as the point where the game chooses its first official policy. From
/// then on, end-user gameplay is expected to go through the game object, which decides what counts
/// as the active mana policy.
public fun create_and_share(
    version: u16,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    ctx: &mut TxContext,
) {
    let policy = token_bucket::create_policy<ManaTag>(
        version,
        capacity,
        refill_amount,
        refill_interval_ms,
        ctx,
    );
    let registry = token_bucket::create_registry<ManaTag>(ctx);
    let game = Game {
        id: object::new(ctx),
        admin: tx_context::sender(ctx),
        active_policy_id: object::id(&policy),
        registry_id: object::id(&registry),
    };

    transfer::share_object(game);
    transfer::public_share_object(registry);
    transfer::public_freeze_object(policy);
}

/// Anyone can create a mage in the game.
///
/// The mana state is claimed from the game's shared registry and starts full at the active
/// policy capacity. This is the onboarding path for a mage: it binds a newly created mage to the
/// game's current policy and gives that mage its own canonical state for all future casts and later
/// migrations.
///
/// Because the state is claimed from the game's registry and pinned to the game's active policy,
/// this flow makes the intended creation path explicit instead of leaving each player to invent
/// their own limiter state lifecycle.
public fun create_mage(
    game: &Game,
    registry: &mut token_bucket::Registry<ManaTag>,
    active_policy: &token_bucket::Policy<ManaTag>,
    clock: &Clock,
    ctx: &mut TxContext,
): Mage {
    assert_active_policy(game, active_policy);
    assert!(game.registry_id == object::id(registry), EWrongPolicy);

    let mage_id = object::new(ctx);
    let mana = token_bucket::claim_object_state(
        registry,
        active_policy,
        mage_id.to_inner(),
        clock,
    );

    Mage {
        id: mage_id,
        owner: tx_context::sender(ctx),
        mana,
    }
}

/// Public path for a player to upgrade their mage to the latest game policy.
///
/// The caller supplies the mage, its current policy, and the game's latest policy. The wrapped
/// mana state is migrated explicitly so the policy change is observable. This is the staged rollout
/// path of the example: after the game rotates policy, each returning mage upgrades itself before
/// resuming normal gameplay under the new rules.
///
/// This is where the library-level `migrate_state` primitive becomes a protocol-approved end-user
/// flow. The player is not choosing any arbitrary policy; the game still verifies that the proposed
/// latest policy is the one it currently recognizes as active.
public fun update_mage_policy(
    game: &Game,
    current_policy: &token_bucket::Policy<ManaTag>,
    latest_policy: &token_bucket::Policy<ManaTag>,
    mage: &mut Mage,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_owner(mage, ctx);
    assert!(game.active_policy_id == object::id(latest_policy), EWrongPolicy);
    token_bucket::migrate_state(current_policy, latest_policy, &mut mage.mana, clock);
}

/// Admin-only policy rotation.
///
/// Old immutable policies remain around so mages can be migrated explicitly later. Unlike the vault
/// example, this function does not migrate all live state immediately; it only changes which policy
/// the game considers current for new onboarding and future validated reads and casts.
///
/// This is why a player cannot bypass the protocol's intended policy by creating some other policy
/// object. The game only advances through this admin-controlled flow and later validates against the
/// resulting active policy id.
public fun update_policy(
    game: &mut Game,
    current_policy: &token_bucket::Policy<ManaTag>,
    next_version: u16,
    next_capacity: u64,
    next_refill_amount: u64,
    next_refill_interval_ms: u64,
    ctx: &mut TxContext,
) {
    assert_admin(game, ctx);
    assert_active_policy(game, current_policy);

    let next_policy = token_bucket::create_policy<ManaTag>(
        next_version,
        next_capacity,
        next_refill_amount,
        next_refill_interval_ms,
        ctx,
    );
    game.active_policy_id = object::id(&next_policy);
    transfer::public_freeze_object(next_policy);
}

/// Cast a low-cost spell using the mage's current mana state.
///
/// This is a convenience wrapper around the shared execution logic in `cast_spell` and represents
/// the normal gameplay path once a mage is current with the game's active policy.
public fun cast_expeliarmus(
    game: &Game,
    active_policy: &token_bucket::Policy<ManaTag>,
    mage: &mut Mage,
    clock: &Clock,
    ctx: &TxContext,
) {
    cast_spell(game, active_policy, mage, EXPELIARMUS_COST, clock, ctx)
}

/// Cast a medium-cost spell using the mage's current mana state.
///
/// Like the other spell entry points, this only succeeds if the game still recognizes the supplied
/// policy and the mage has already been migrated to it.
public fun cast_crucio(
    game: &Game,
    active_policy: &token_bucket::Policy<ManaTag>,
    mage: &mut Mage,
    clock: &Clock,
    ctx: &TxContext,
) {
    cast_spell(game, active_policy, mage, CRUCIO_COST, clock, ctx)
}

/// Cast a high-cost spell using the mage's current mana state.
///
/// This is the strongest example of why stale-policy checks matter: any action should fail if the
/// mage has not been upgraded to the game's current rules.
public fun cast_avada_kedavra(
    game: &Game,
    active_policy: &token_bucket::Policy<ManaTag>,
    mage: &mut Mage,
    clock: &Clock,
    ctx: &TxContext,
) {
    cast_spell(game, active_policy, mage, AVADA_KEDAVRA_COST, clock, ctx)
}

/// Read the mage's currently available mana under the game's active policy.
///
/// This is the safe inspection path for gameplay or UI code because it verifies both that the game
/// still points to the supplied policy and that the mage has already been migrated to that policy.
///
/// In other words, the game never treats a policy as authoritative just because a user supplied it.
public fun mana(
    game: &Game,
    active_policy: &token_bucket::Policy<ManaTag>,
    mage: &Mage,
    clock: &Clock,
): u64 {
    assert_active_policy(game, active_policy);
    assert!(token_bucket::state_policy_id(&mage.mana) == game.active_policy_id, EStaleMagePolicy);
    token_bucket::available(active_policy, &mage.mana, clock)
}

public fun owner(mage: &Mage): address {
    mage.owner
}

public fun active_policy_id(game: &Game): ID {
    game.active_policy_id
}

public fun registry_id(game: &Game): ID {
    game.registry_id
}

public fun mana_policy_id(mage: &Mage): ID {
    token_bucket::state_policy_id(&mage.mana)
}

public fun stored_mana(mage: &Mage): u64 {
    token_bucket::stored_tokens(&mage.mana)
}

public fun mana_scope_kind(mage: &Mage): u8 {
    token_bucket::scope_kind(&mage.mana)
}

#[test_only]
public fun destroy_mage_for_testing(mage: Mage) {
    let Mage { id, owner: _, mana } = mage;
    token_bucket::destroy_state_for_testing(mana);
    object::delete(id);
}

fun cast_spell(
    game: &Game,
    active_policy: &token_bucket::Policy<ManaTag>,
    mage: &mut Mage,
    mana_cost: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_owner(mage, ctx);
    assert_active_policy(game, active_policy);
    assert!(token_bucket::state_policy_id(&mage.mana) == game.active_policy_id, EStaleMagePolicy);
    token_bucket::consume_or_abort(active_policy, &mut mage.mana, mana_cost, clock);
}

fun assert_admin(game: &Game, ctx: &TxContext) {
    assert!(game.admin == tx_context::sender(ctx), ENotAdmin);
}

fun assert_owner(mage: &Mage, ctx: &TxContext) {
    assert!(mage.owner == tx_context::sender(ctx), ENotMageOwner);
}

fun assert_active_policy(game: &Game, policy: &token_bucket::Policy<ManaTag>) {
    assert!(game.active_policy_id == object::id(policy), EWrongPolicy);
}
