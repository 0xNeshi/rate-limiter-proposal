# Token Bucket Rate Limiter

A simple, reusable onchain rate-limiter pattern for Sui.

This package shows how to separate **configuration**, **state claiming**, and **live usage** so products can enforce limits cleanly, upgrade safely, and explain behavior clearly. It includes two concrete examples:

- **Vault**
  - one shared rate limit for all withdrawals

- **Mage Game**
  - one active mana policy for the game, with a separate mana state for each mage

# The Design in Plain English

The design is built around three objects:

- **`Policy<Tag>`**
  - the immutable rate-limiter rules
  - capacity, refill amount, refill interval, and version

- **`Registry<Tag>`**
  - the object used to claim canonical limiter states exactly once
  - this prevents duplicate state creation for the same scope

- **`State<Tag>`**
  - the live mutable accounting
  - stores which policy it is pinned to and how many tokens are currently available

## Why this split is useful

- **Explicit upgrades**
  - policy changes happen by creating a new `Policy`, not by mutating one in place

- **Small hot path**
  - normal usage updates only the `State`, which keeps the main enforcement path simple

- **Canonical state per scope**
  - the `Registry` ensures each scope gets one deterministic limiter state

- **Observable migrations**
  - when a policy changes, state migration is explicit and easy to audit

- **Flexible rollout options**
  - some products can migrate immediately, while others can migrate gradually

- **Reusable architecture**
  - the same pattern supports global limits, per-user limits, and per-object limits

# Example 1: Vault

The `Vault` example models a shared pool where everyone can deposit, but **all withdrawals consume from one shared global token bucket**.

This is useful when the product needs to control **total outflow**, not individual user behavior.

## Why this implementation is valuable

- **Protects aggregate liquidity**
  - the whole vault can only drain at the configured pace

- **Easy to reason about**
  - one vault, one shared limiter state, one active policy

- **Fast operational updates**
  - when policy changes, the vault can migrate its single shared state immediately

## Vault Flow: Initial Creation

```mermaid
flowchart TD
    A[Admin calls create_and_share] --> B[Create immutable Policy<WithdrawTag>]
    B --> C[Create Registry<WithdrawTag>]
    C --> D[Claim global State from registry]
    D --> E[Create shared Vault object]
    E --> F[Share Vault]
    D --> G[Share State]
    C --> H[Share Registry]
    B --> I[Freeze Policy]
```

## Vault Flow: Withdraw

```mermaid
flowchart TD
    A[User loads Vault + Policy + State] --> B[Validate Vault points to that Policy and State]
    B --> C[Refill bucket based on elapsed time]
    C --> D{Enough tokens?}
    D -- No --> E[Abort: rate limited]
    D -- Yes --> F[Consume tokens from shared State]
    F --> G[Split coin from Vault balance]
    G --> H[Return withdrawn coin]
```

## Vault Flow: Update Rate Limiter Configuration

```mermaid
flowchart TD
    A[Admin submits new rate limit config] --> B[Create new immutable Policy]
    B --> C[Read current shared State under old Policy]
    C --> D[Migrate State to new Policy]
    D --> E[Clamp tokens to new capacity if needed]
    E --> F[Vault stores new active policy id]
    F --> G[Future withdrawals use new Policy immediately]
```

# Example 2: Mage Game

The `Mage Game` example models a game where the **game has one active mana policy**, but **each mage owns its own mana state**.

This is useful when the product wants a shared ruleset, but independent player or object usage.

## Why this implementation is valuable

- **Per-player fairness**
  - one mage spending mana does not affect another mage

- **Better scalability**
  - players do not compete on one shared limiter state for normal gameplay

- **Safer live balancing**
  - the game can switch to a new policy while letting players migrate explicitly

## Mage Game Flow: Initial Creation

```mermaid
flowchart TD
    A[Admin calls create_and_share] --> B[Create immutable Policy<ManaTag>]
    B --> C[Create Registry<ManaTag>]
    C --> D[Create shared Game]
    D --> E[Game stores active policy id]
    D --> F[Share Game]
    C --> G[Share Registry]
    B --> H[Freeze Policy]
```

## Mage Game Flow: Cast Spell

```mermaid
flowchart TD
    A[Player loads Game + active Policy + owned Mage] --> B[Check player owns Mage]
    B --> C[Check Game still points to that Policy]
    C --> D[Check Mage mana State is pinned to current Policy]
    D --> E[Refill mana based on elapsed time]
    E --> F{Enough mana?}
    F -- No --> G[Abort: rate limited]
    F -- Yes --> H[Consume mana from Mage state]
    H --> I[Spell succeeds]
```

## Mage Game Flow: Update Rate Limiter Configuration

```mermaid
flowchart TD
    A[Admin submits new mana config] --> B[Create new immutable Policy]
    B --> C[Game updates active policy id]
    C --> D[Old Policy remains available]
    D --> E[Existing mages are not auto-migrated]
    E --> F[New reads and casts expect the latest Policy]
```

## Mage Game Flow: Player Policy Migration

```mermaid
flowchart TD
    A[Player loads Mage + old Policy + latest Policy + Game] --> B[Check player owns Mage]
    B --> C[Check latest Policy matches Game.active_policy_id]
    C --> D[Migrate Mage mana State from old Policy to latest Policy]
    D --> E[Clamp mana to new capacity if needed]
    E --> F[Mage can now cast under latest Policy]
```

# Key Difference Between the Two Examples

| Topic | Vault | Mage Game |
| --- | --- | --- |
| **Scope of limiting** | One shared global limit | One independent limit per mage |
| **Who shares the state** | All users share one state | Each mage has its own state |
| **Policy update behavior** | Shared state is migrated immediately | Game updates policy first, each mage migrates later |
| **Best for** | Aggregate outflow control | Independent player or object usage |

# Takeaway

This pattern gives a product team a clean way to enforce rate limits **without tying everything to one mutable object or one fragile upgrade path**.

It is useful because it combines:

- **clear rules**
  - immutable policies

- **safe state ownership**
  - canonical claimed states

- **controlled upgrades**
  - explicit migration when policies change

That makes it a strong fit for products that need rate limiting to be **auditable, upgradeable, and easy to reason about in production**.

# Possible Use Cases for the Token Bucket

- Protocol-wide withdrawal throttling
- Per-user claim or redemption limits
- Rate-limited borrowing or minting
- Mana, stamina, or action energy in games
- Dungeon, raid, or reward-entry throttling
