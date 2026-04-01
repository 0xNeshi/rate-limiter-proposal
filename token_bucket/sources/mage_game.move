module token_bucket::mage_game;

use sui::clock::Clock;
use token_bucket::token_bucket;

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
public struct Mage has key, store {
    id: UID,
    owner: address,
    mana: token_bucket::State<ManaTag>,
}

/// Tag separating the mana limiter domain from every other token bucket domain.
public struct ManaTag has copy, drop, store {}

/// Create a game, a shared registry, and the first immutable mana policy.
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
/// policy capacity.
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
/// mana state is migrated explicitly so the policy change is observable.
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
/// Old immutable policies remain around so mages can be migrated explicitly later.
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

public fun cast_expeliarmus(
    game: &Game,
    active_policy: &token_bucket::Policy<ManaTag>,
    mage: &mut Mage,
    clock: &Clock,
    ctx: &TxContext,
) {
    cast_spell(game, active_policy, mage, EXPELIARMUS_COST, clock, ctx)
}

public fun cast_crucio(
    game: &Game,
    active_policy: &token_bucket::Policy<ManaTag>,
    mage: &mut Mage,
    clock: &Clock,
    ctx: &TxContext,
) {
    cast_spell(game, active_policy, mage, CRUCIO_COST, clock, ctx)
}

public fun cast_avada_kedavra(
    game: &Game,
    active_policy: &token_bucket::Policy<ManaTag>,
    mage: &mut Mage,
    clock: &Clock,
    ctx: &TxContext,
) {
    cast_spell(game, active_policy, mage, AVADA_KEDAVRA_COST, clock, ctx)
}

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
