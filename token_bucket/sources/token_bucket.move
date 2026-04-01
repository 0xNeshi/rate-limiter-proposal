module token_bucket::token_bucket;

use std::bcs;
use sui::clock::Clock;
use sui::derived_object;

const SCOPE_KIND_GLOBAL: u8 = 0;
const SCOPE_KIND_ADDRESS: u8 = 1;
const SCOPE_KIND_OBJECT: u8 = 2;
const SCOPE_KIND_BYTES: u8 = 3;

#[error(code = 0)]
const EPolicyMismatch: vector<u8> = "Policy mismatch";
#[error(code = 1)]
const ERateLimited: vector<u8> = "Rate limited";
#[error(code = 2)]
const EPolicyDisabled: vector<u8> = "Policy disabled";
#[error(code = 3)]
const EInvalidPolicy: vector<u8> = "Invalid policy";

/// Immutable token bucket configuration.
///
/// The examples rotate to a brand new `Policy<Tag>` instead of mutating one in place.
/// That makes policy changes explicit and keeps the hot path centered on `State<Tag>`.
public struct Policy<phantom Tag> has key, store {
    id: UID,
    version: u16,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    enabled: bool,
}

/// Shared registry used only for deterministic one-time claims of `State<Tag>`.
///
/// The registry is the object that "remembers" which scope keys already claimed a state.
public struct Registry<phantom Tag> has key, store {
    id: UID,
}

/// Live mutable accounting for one token bucket scope.
///
/// The state stores the policy it is pinned to, human-visible scope metadata, and the
/// current token accounting fields.
public struct State<phantom Tag> has key, store {
    id: UID,
    policy_id: ID,
    scope_kind: u8,
    scope_key_hash: vector<u8>,
    last_refill_ms: u64,
    tokens: u64,
}

/// Create a new immutable token bucket policy.
public fun create_policy<Tag>(
    version: u16,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    ctx: &mut TxContext,
): Policy<Tag> {
    assert!(capacity > 0, EInvalidPolicy);
    assert!(refill_amount > 0, EInvalidPolicy);
    assert!(refill_interval_ms > 0, EInvalidPolicy);

    Policy {
        id: object::new(ctx),
        version,
        capacity,
        refill_amount,
        refill_interval_ms,
        enabled: true,
    }
}

/// Create a fresh registry that can later claim one state per scope key.
public fun create_registry<Tag>(ctx: &mut TxContext): Registry<Tag> {
    Registry { id: object::new(ctx) }
}

/// Claim the canonical global state for a domain.
public fun claim_global_state<Tag>(
    registry: &mut Registry<Tag>,
    policy: &Policy<Tag>,
    clock: &Clock,
): State<Tag> {
    State {
        id: derived_object::claim(&mut registry.id, SCOPE_KIND_GLOBAL),
        policy_id: object::id(policy),
        scope_kind: SCOPE_KIND_GLOBAL,
        scope_key_hash: vector[],
        last_refill_ms: clock.timestamp_ms(),
        tokens: policy.capacity,
    }
}

/// Claim the canonical address-scoped state for `owner`.
public fun claim_address_state<Tag>(
    registry: &mut Registry<Tag>,
    policy: &Policy<Tag>,
    owner: address,
    clock: &Clock,
): State<Tag> {
    State {
        id: derived_object::claim(&mut registry.id, owner),
        policy_id: object::id(policy),
        scope_kind: SCOPE_KIND_ADDRESS,
        scope_key_hash: bcs::to_bytes(&owner),
        last_refill_ms: clock.timestamp_ms(),
        tokens: policy.capacity,
    }
}

/// Claim the canonical object-scoped state for `scope_object_id`.
public fun claim_object_state<Tag>(
    registry: &mut Registry<Tag>,
    policy: &Policy<Tag>,
    scope_object_id: ID,
    clock: &Clock,
): State<Tag> {
    State {
        id: derived_object::claim(&mut registry.id, scope_object_id),
        policy_id: object::id(policy),
        scope_kind: SCOPE_KIND_OBJECT,
        scope_key_hash: scope_object_id.to_bytes(),
        last_refill_ms: clock.timestamp_ms(),
        tokens: policy.capacity,
    }
}

/// Claim the canonical bytes-scoped state for arbitrary protocol-defined keys.
public fun claim_bytes_state<Tag>(
    registry: &mut Registry<Tag>,
    policy: &Policy<Tag>,
    scope_key: vector<u8>,
    clock: &Clock,
): State<Tag> {
    State {
        id: derived_object::claim(&mut registry.id, copy scope_key),
        policy_id: object::id(policy),
        scope_kind: SCOPE_KIND_BYTES,
        scope_key_hash: scope_key,
        last_refill_ms: clock.timestamp_ms(),
        tokens: policy.capacity,
    }
}

/// Compute the currently available tokens after applying elapsed refill time.
public fun available<Tag>(policy: &Policy<Tag>, state: &State<Tag>, clock: &Clock): u64 {
    assert_policy(policy, state);
    let (_, tokens) = current_bucket(policy, state, clock.timestamp_ms());
    tokens
}

/// Main enforcing API: refill if enough time passed, then consume `amount` tokens or abort.
public fun consume_or_abort<Tag>(
    policy: &Policy<Tag>,
    state: &mut State<Tag>,
    amount: u64,
    clock: &Clock,
) {
    assert!(policy.enabled, EPolicyDisabled);
    assert_policy(policy, state);

    let (last_refill_ms, tokens) = current_bucket(policy, state, clock.timestamp_ms());
    assert!(tokens >= amount, ERateLimited);

    state.last_refill_ms = last_refill_ms;
    state.tokens = tokens - amount;
}

/// Move a state from one policy to another.
///
/// The state first accrues any refill under the old policy up to `clock.timestamp_ms()`,
/// then its token balance is clamped to the new policy capacity and pinned to the new
/// policy id. This makes migration explicit and easy to observe in tests.
public fun migrate_state<Tag>(
    current_policy: &Policy<Tag>,
    next_policy: &Policy<Tag>,
    state: &mut State<Tag>,
    clock: &Clock,
) {
    assert!(next_policy.enabled, EPolicyDisabled);
    assert_policy(current_policy, state);

    let now_ms = clock.timestamp_ms();
    let (_, current_tokens) = current_bucket(current_policy, state, now_ms);

    state.policy_id = object::id(next_policy);
    state.last_refill_ms = now_ms;
    state.tokens = min(current_tokens, next_policy.capacity);
}

public fun version<Tag>(policy: &Policy<Tag>): u16 {
    policy.version
}

public fun capacity<Tag>(policy: &Policy<Tag>): u64 {
    policy.capacity
}

public fun refill_amount<Tag>(policy: &Policy<Tag>): u64 {
    policy.refill_amount
}

public fun refill_interval_ms<Tag>(policy: &Policy<Tag>): u64 {
    policy.refill_interval_ms
}

public fun policy_id<Tag>(policy: &Policy<Tag>): ID {
    object::id(policy)
}

public fun state_policy_id<Tag>(state: &State<Tag>): ID {
    state.policy_id
}

public fun state_id<Tag>(state: &State<Tag>): ID {
    object::id(state)
}

public fun registry_id<Tag>(registry: &Registry<Tag>): ID {
    object::id(registry)
}

public fun scope_kind<Tag>(state: &State<Tag>): u8 {
    state.scope_kind
}

public fun scope_key_hash<Tag>(state: &State<Tag>): vector<u8> {
    state.scope_key_hash
}

public fun stored_tokens<Tag>(state: &State<Tag>): u64 {
    state.tokens
}

public fun last_refill_ms<Tag>(state: &State<Tag>): u64 {
    state.last_refill_ms
}

#[test_only]
public fun destroy_state_for_testing<Tag>(state: State<Tag>) {
    let State {
        id,
        policy_id: _,
        scope_kind: _,
        scope_key_hash: _,
        last_refill_ms: _,
        tokens: _,
    } = state;
    object::delete(id);
}

#[test_only]
public fun destroy_registry_for_testing<Tag>(registry: Registry<Tag>) {
    let Registry { id } = registry;
    object::delete(id);
}

#[test_only]
public fun destroy_policy_for_testing<Tag>(policy: Policy<Tag>) {
    let Policy {
        id,
        version: _,
        capacity: _,
        refill_amount: _,
        refill_interval_ms: _,
        enabled: _,
    } = policy;
    object::delete(id);
}

fun assert_policy<Tag>(policy: &Policy<Tag>, state: &State<Tag>) {
    assert!(state.policy_id == object::id(policy), EPolicyMismatch);
}

fun current_bucket<Tag>(policy: &Policy<Tag>, state: &State<Tag>, now_ms: u64): (u64, u64) {
    if (now_ms <= state.last_refill_ms) {
        return (state.last_refill_ms, state.tokens)
    };

    let elapsed_ms = now_ms - state.last_refill_ms;
    let refill_steps = elapsed_ms / policy.refill_interval_ms;
    if (refill_steps == 0) {
        return (state.last_refill_ms, state.tokens)
    };

    let refilled_tokens = refill_steps * policy.refill_amount;
    let tokens = min(policy.capacity, state.tokens + refilled_tokens);
    let last_refill_ms = state.last_refill_ms + refill_steps * policy.refill_interval_ms;
    (last_refill_ms, tokens)
}

fun min(a: u64, b: u64): u64 {
    if (a <= b) a else b
}
