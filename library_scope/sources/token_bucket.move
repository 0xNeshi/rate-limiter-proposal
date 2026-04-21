/// Generic token bucket library used by the example integrations in this repository.
///
/// The intended lifecycle is:
/// 1. create a `Policy<Tag>` that defines the limiter rules for one domain; internally it carries
///    a hidden `ClaimRegistry<Tag>` as a dynamic object field,
/// 2. claim canonical `State<Tag>` objects from that policy for the scopes you want to rate limit,
/// 3. call `available` for read-only inspection or `consume_or_abort` on the hot path,
/// 4. when rules change, call `rotate_policy` to produce a brand new `Policy<Tag>` (with a new
///    object id) that carries the same `ClaimRegistry<Tag>` forward, then explicitly migrate each
///    state to it.
///
/// Because the claim registry travels with every successive policy, scope uniqueness is preserved
/// across policy upgrades: the same address or object id cannot claim a fresh full-capacity state
/// after each rotation.
///
/// The library enforces canonical state claiming and policy-pinned accounting, but it does not by
/// itself decide which policy a product considers active. That choice belongs to the integrator,
/// which is why the example modules store active policy ids and reject arbitrary policies supplied
/// by users.
///
/// Possible hardening ideas discussed for later include capability-gated policy creation, tighter
/// wrapping of policy and state objects inside integrator modules, and reducing opportunities for
/// accidental transfer of user-visible helper objects. Those ideas are not implemented here; this
/// repository is intentionally showing the architecture and the flow first.
module library_scope::token_bucket;

use std::bcs;
use sui::clock::Clock;
use sui::derived_object;
use sui::dynamic_object_field as dof;

// === Errors ===

#[error(code = 0)]
const EPolicyMismatch: vector<u8> = "Policy mismatch";
#[error(code = 1)]
const ERateLimited: vector<u8> = "Rate limited";
#[error(code = 2)]
const EPolicyDisabled: vector<u8> = "Policy disabled";
#[error(code = 3)]
const EInvalidPolicy: vector<u8> = "Invalid policy";

// === Constants ===

const SCOPE_KIND_GLOBAL: u8 = 0;
const SCOPE_KIND_ADDRESS: u8 = 1;
const SCOPE_KIND_OBJECT: u8 = 2;

/// Key under which each policy stores its wrapped `ClaimRegistry<Tag>` as a dynamic object field.
const CLAIM_REGISTRY_KEY: u8 = 0;

// === Structs ===

/// Token bucket configuration and current `ClaimRegistry<Tag>` holder.
///
/// The rule fields (`version`, `capacity`, `refill_amount`, `refill_interval_ms`, `enabled`) are
/// set at creation and are never mutated by this library. In that sense the policy still behaves
/// as a stable rule object: when rules change, the integrator calls `rotate_policy` to create a
/// brand new `Policy<Tag>` with a new object id, and the `ClaimRegistry<Tag>` is handed over to
/// the new policy so domain-wide scope uniqueness is preserved.
///
/// Policies are shared (not frozen) because `derived_object::claim` needs mutable access to the
/// claim registry's `UID`, which is stored as a dynamic object field on the policy. The hot path
/// (`available`, `consume_or_abort`, `migrate_state`) only needs `&Policy`, so read and consume
/// transactions can still run in parallel with each other.
///
/// On its own, creating a `Policy<Tag>` does not make that policy authoritative for any protocol.
/// A protocol still needs its own rule for deciding which policy is active. In the examples, that
/// rule is implemented by storing the active policy id inside the integrating object.
public struct Policy<phantom Tag> has key, store {
    id: UID,
    version: u16,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    enabled: bool,
}

/// Internal canonical claim registry for a domain.
///
/// Exactly one `ClaimRegistry<Tag>` exists per domain. It is created together with the first
/// policy and is then carried forward into every successive policy via `rotate_policy`. The
/// registry's `UID` is what `sui::derived_object` uses to guarantee that each scope key can only
/// ever claim one canonical `State<Tag>`, regardless of how many times the policy rotates.
///
/// This type is public because dynamic object fields require `key + store`, but the library does
/// not expose any constructor or accessor to integrators — the registry is always accessed
/// through `Policy<Tag>`.
public struct ClaimRegistry<phantom Tag> has key, store {
    id: UID,
}

/// Live mutable accounting for one token bucket scope.
///
/// This is the object the hot path mutates during real usage. It stores the policy it is pinned
/// to, human-visible scope metadata, and the current token accounting fields so later reads,
/// execution, and migrations can all reason about the same canonical state object.
///
/// `State<Tag>` exists separately from `Policy<Tag>` because the rules change much less often than
/// live usage does. The policy stays stable and easy to audit, while the state absorbs frequent
/// refill and consumption updates.
///
/// Has `store` ability, because it allows the type to be embedded in other objects.
/// The benefit of this is visible in the `mage_game`, where this type is used to track Mage's mana.
public struct State<phantom Tag> has key, store {
    id: UID,
    policy_id: ID,
    scope_kind: u8,
    scope_key_hash: vector<u8>,
    last_refill_ms: u64,
    tokens: u64,
}

// === Public Functions ===

/// Create the first token bucket policy for a domain.
///
/// This also creates the domain's canonical `ClaimRegistry<Tag>` and attaches it to the returned
/// policy. Call this once during setup. Later rule changes should go through `rotate_policy`,
/// which keeps the same claim registry and therefore the same uniqueness guarantees.
///
/// This function is intentionally a library primitive. In a real integration, it is usually
/// called only from admin-controlled setup flows. Creating a policy directly through the library
/// is not enough to bypass a well-formed integrator, because the integrator still decides which
/// policy id it recognizes as active.
///
/// # Why a User-Created Policy Does Not Bypass the Examples
///
/// Even though this function is generic and open, that does **not** mean a user can
/// override protocol policy just by creating some new `Policy<Tag>` object.
///
/// In the examples:
///
/// - **Vault**
///   - the vault checks that the supplied policy id is exactly the one it stores as active
///
/// - **Mage Game**
///   - the game checks that the supplied policy id is exactly the one it stores as active
///   - it also checks that the mage state is already pinned to that same active policy
///
/// So the protocol-level object remains the source of truth.
public fun create_policy<Tag>(
    version: u16,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    ctx: &mut TxContext,
): Policy<Tag> {
    assert_rule_fields!(capacity, refill_amount, refill_interval_ms);

    let mut policy = Policy<Tag> {
        id: object::new(ctx),
        version,
        capacity,
        refill_amount,
        refill_interval_ms,
        enabled: true,
    };
    let registry = ClaimRegistry<Tag> { id: object::new(ctx) };
    dof::add(&mut policy.id, CLAIM_REGISTRY_KEY, registry);
    policy
}

/// Create a successor policy that inherits the current policy's `ClaimRegistry<Tag>`.
///
/// The returned policy has a brand new object id, so integrators still advance their notion of the
/// "active" policy by swapping in a new id. The important difference from `create_policy` is that
/// no new claim registry is minted: the existing registry is detached from the current policy and
/// attached to the new one, so every scope that previously claimed a state under the domain keeps
/// its uniqueness record. A user cannot re-claim a fresh full-capacity state under the new policy
/// for a scope that already claimed under the old one.
///
/// Old policies remain fully usable for reads, consumption on already-claimed state, and as the
/// source of `migrate_state`. They just can no longer hand out new claims, which is the intended
/// behavior after a rotation.
public fun rotate_policy<Tag>(
    current: &mut Policy<Tag>,
    next_version: u16,
    next_capacity: u64,
    next_refill_amount: u64,
    next_refill_interval_ms: u64,
    ctx: &mut TxContext,
): Policy<Tag> {
    assert_rule_fields!(next_capacity, next_refill_amount, next_refill_interval_ms);

    let registry: ClaimRegistry<Tag> = dof::remove(&mut current.id, CLAIM_REGISTRY_KEY);
    let mut next = Policy<Tag> {
        id: object::new(ctx),
        version: next_version,
        capacity: next_capacity,
        refill_amount: next_refill_amount,
        refill_interval_ms: next_refill_interval_ms,
        enabled: true,
    };
    dof::add(&mut next.id, CLAIM_REGISTRY_KEY, registry);
    next
}

/// Claim the canonical global state for a domain.
///
/// Use this when the whole product or subsystem should share one limiter state, such as a shared
/// vault withdrawal limit. This is typically called during setup because there is only one global
/// scope to claim, and all later execution paths mutate this same returned state.
///
/// The `ClaimRegistry<Tag>` stored inside the policy enforces that only one global state can ever
/// be claimed for the domain, across every policy rotation, so the global limiter follows the
/// same canonical claim story as every other scope.
public fun claim_global_state<Tag>(policy: &mut Policy<Tag>, clock: &Clock): State<Tag> {
    let policy_id = object::id(policy);
    let capacity = policy.capacity;
    let now_ms = clock.timestamp_ms();
    let registry: &mut ClaimRegistry<Tag> = dof::borrow_mut(&mut policy.id, CLAIM_REGISTRY_KEY);
    State {
        id: derived_object::claim(&mut registry.id, SCOPE_KIND_GLOBAL),
        policy_id,
        scope_kind: SCOPE_KIND_GLOBAL,
        scope_key_hash: vector[],
        last_refill_ms: now_ms,
        tokens: capacity,
    }
}

/// Claim the canonical address-scoped state for `owner`.
///
/// Use this in onboarding flows where each account should get its own limiter state. The
/// returned state starts full at the supplied policy capacity and becomes the canonical execution
/// object for that address until it is later migrated to a newer policy.
///
/// This is the intended creation flow for per-address state. The same address cannot claim a
/// second state for the same domain, even after a policy rotation, because the claim registry
/// that backs the claim map travels with every policy version (e.g. a single address can never
/// end up with two `State<Tag>` objects that double its rate limit in the domain).
public fun claim_address_state<Tag>(
    policy: &mut Policy<Tag>,
    owner: address,
    clock: &Clock,
): State<Tag> {
    let policy_id = object::id(policy);
    let capacity = policy.capacity;
    let now_ms = clock.timestamp_ms();
    let registry: &mut ClaimRegistry<Tag> = dof::borrow_mut(&mut policy.id, CLAIM_REGISTRY_KEY);
    State {
        id: derived_object::claim(&mut registry.id, owner),
        policy_id,
        scope_kind: SCOPE_KIND_ADDRESS,
        scope_key_hash: bcs::to_bytes(&owner),
        last_refill_ms: now_ms,
        tokens: capacity,
    }
}

/// Claim the canonical object-scoped state for `scope_object_id`.
///
/// Use this when each product object should carry its own independent limiter state. In the Mage
/// Game example, this is the claim path used when a newly created mage receives its mana state.
/// This function is part of the setup/onboarding path, not the normal consumption hot path.
///
/// The object id is the scope key, so each object can have at most one canonical limiter state
/// for the domain. The `ClaimRegistry<Tag>` held by the policy is what guarantees that, and it
/// survives policy rotations.
public fun claim_object_state<Tag>(
    policy: &mut Policy<Tag>,
    scope_object_id: ID,
    clock: &Clock,
): State<Tag> {
    let policy_id = object::id(policy);
    let capacity = policy.capacity;
    let now_ms = clock.timestamp_ms();
    let registry: &mut ClaimRegistry<Tag> = dof::borrow_mut(&mut policy.id, CLAIM_REGISTRY_KEY);
    State {
        id: derived_object::claim(&mut registry.id, scope_object_id),
        policy_id,
        scope_kind: SCOPE_KIND_OBJECT,
        scope_key_hash: scope_object_id.to_bytes(),
        last_refill_ms: now_ms,
        tokens: capacity,
    }
}

/// Compute the currently available tokens after applying elapsed refill time.
///
/// This is the read-only inspection path for UIs, tests, and product logic that wants to show the
/// current headroom without mutating state. It still verifies that the supplied state is pinned
/// to the supplied policy so callers do not accidentally inspect stale or mismatched state.
///
/// Integrators usually pair this with their own "is this the active policy/state for my product?"
/// checks before surfacing the result to end users.
public fun available<Tag>(policy: &Policy<Tag>, state: &State<Tag>, clock: &Clock): u64 {
    assert_policy!(policy, state);
    let (_, tokens) = policy.current_bucket(state, clock.timestamp_ms());
    tokens
}

/// Main enforcing API: refill if enough time passed, then consume `amount` tokens or abort.
///
/// This is the normal hot-path entry point integrators call from real actions such as withdrawing
/// from a vault or casting a spell. It validates the policy/state pairing, applies any earned
/// refill up to the current time, and then either updates the state with the consumed amount or
/// aborts if the action would exceed the current limit.
///
/// On its own, this function only knows about the supplied policy and state. A complete product
/// flow should also validate that those objects are the ones the product currently recognizes as
/// active. The example modules show that extra check explicitly.
public fun consume_or_abort<Tag>(
    policy: &Policy<Tag>,
    state: &mut State<Tag>,
    amount: u64,
    clock: &Clock,
) {
    assert!(policy.enabled, EPolicyDisabled);
    assert_policy!(policy, state);

    let (last_refill_ms, tokens) = policy.current_bucket(state, clock.timestamp_ms());
    assert!(tokens >= amount, ERateLimited);

    state.last_refill_ms = last_refill_ms;
    state.tokens = tokens - amount;
}

/// Move a state from one policy to another.
///
/// The state first accrues any refill under the old policy up to `clock.timestamp_ms()`, then its
/// token balance is clamped to the new policy capacity and pinned to the new policy id.
/// Integrators call this during policy rollout when they want existing state to begin executing
/// under a newly created policy; some products do this immediately for one shared state, while
/// others do it later as individual users or objects come back on-chain.
///
/// This function is intentionally generic, but the intended usage is still
/// integrator-controlled. A well-formed integrator should decide which next policy is acceptable
/// and when migration is allowed. The examples show two such choices: immediate migration in
/// `vault` and staged migration in `mage_game`.
public fun migrate_state<Tag>(
    current_policy: &Policy<Tag>,
    next_policy: &Policy<Tag>,
    state: &mut State<Tag>,
    clock: &Clock,
) {
    assert!(next_policy.enabled, EPolicyDisabled);
    assert_policy!(current_policy, state);

    let now_ms = clock.timestamp_ms();
    let (_, current_tokens) = current_policy.current_bucket(state, now_ms);

    state.policy_id = object::id(next_policy);
    state.last_refill_ms = now_ms;
    state.tokens = current_tokens.min(next_policy.capacity);
}

// === View Helpers ===

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

// === Private Functions ===

macro fun assert_rule_fields($capacity: u64, $refill_amount: u64, $refill_interval_ms: u64) {
    assert!($capacity > 0, EInvalidPolicy);
    assert!($refill_amount > 0, EInvalidPolicy);
    assert!($refill_interval_ms > 0, EInvalidPolicy);
}

macro fun assert_policy<$Tag>($policy: &Policy<$Tag>, $state: &State<$Tag>) {
    let policy = $policy;
    let state = $state;
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
    let tokens = policy.capacity.min(state.tokens + refilled_tokens);
    let last_refill_ms = state.last_refill_ms + refill_steps * policy.refill_interval_ms;
    (last_refill_ms, tokens)
}

// === Test-Only Helpers ===

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
    id.delete();
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
    let mut id = id;
    let ClaimRegistry<Tag> { id: registry_id } = dof::remove(&mut id, CLAIM_REGISTRY_KEY);
    registry_id.delete();
    id.delete();
}
