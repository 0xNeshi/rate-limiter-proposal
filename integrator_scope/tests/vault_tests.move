#[test_only]
module integrator_scope::vault_tests;

use integrator_scope::vault;
use library_scope::token_bucket;
use std::unit_test::assert_eq;
use sui::clock;
use sui::coin;
use sui::test_scenario;

#[test]
fun vault_users_share_one_global_bucket() {
    let owner = @0x11;
    let user_a = @0x12;
    let user_b = @0x13;
    let mut test = test_scenario::begin(owner);
    let initial_vault = coin::mint_for_testing<sui::sui::SUI>(0, test.ctx());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Create the shared vault with one global withdrawal bucket.
    vault::create_and_share(initial_vault, 0, 100, 25, 10, &clk, test.ctx());

    // User A funds the vault.
    test.next_tx(user_a);
    let mut vault = test.take_shared<vault::Vault>();
    let deposit_a = coin::mint_for_testing<sui::sui::SUI>(80, test.ctx());
    vault.deposit(deposit_a);
    test_scenario::return_shared(vault);

    // User B also funds the same shared vault.
    test.next_tx(user_b);
    let mut vault = test.take_shared<vault::Vault>();
    let deposit_b = coin::mint_for_testing<sui::sui::SUI>(40, test.ctx());
    vault.deposit(deposit_b);
    test_scenario::return_shared(vault);

    // User A withdraws first and consumes most of the shared bucket.
    test.next_tx(user_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let mut state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();
    let withdrawn_a = vault.withdraw(&policy, &mut state, 70, &clk, test.ctx());

    assert_eq!(withdrawn_a.value(), 70);
    assert_eq!(vault.value(), 50);
    assert_eq!(vault.remaining_capacity(&policy, &state, &clk), 30);

    withdrawn_a.burn_for_testing();
    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_shared(policy);

    // User B observes the reduced shared capacity and can only use what remains.
    test.next_tx(user_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let mut state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();
    let withdrawn_b = vault.withdraw(&policy, &mut state, 20, &clk, test.ctx());

    assert_eq!(withdrawn_b.value(), 20);
    assert_eq!(vault.value(), 30);
    assert_eq!(vault.remaining_capacity(&policy, &state, &clk), 10);

    withdrawn_b.burn_for_testing();
    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_shared(policy);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = token_bucket::ERateLimited)]
fun vault_second_user_fails_after_global_capacity_is_consumed() {
    let owner = @0x21;
    let user_a = @0x22;
    let user_b = @0x23;
    let mut test = test_scenario::begin(owner);
    let initial_vault = coin::mint_for_testing<sui::sui::SUI>(0, test.ctx());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Create a vault whose shared bucket only allows 50 units immediately.
    vault::create_and_share(initial_vault, 0, 50, 10, 10, &clk, test.ctx());

    // User A deposits enough funds for the test scenario.
    test.next_tx(user_a);
    let mut vault = test.take_shared<vault::Vault>();
    let deposit_a = coin::mint_for_testing<sui::sui::SUI>(60, test.ctx());
    vault.deposit(deposit_a);
    test_scenario::return_shared(vault);

    // User B also deposits, but both users still share the same bucket.
    test.next_tx(user_b);
    let mut vault = test.take_shared<vault::Vault>();
    let deposit_b = coin::mint_for_testing<sui::sui::SUI>(40, test.ctx());
    vault.deposit(deposit_b);
    test_scenario::return_shared(vault);

    // User A consumes the entire global withdrawal capacity.
    test.next_tx(user_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let mut state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();
    let first = vault.withdraw(&policy, &mut state, 50, &clk, test.ctx());
    first.burn_for_testing();
    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_shared(policy);

    // User B now fails because no shared capacity is left.
    test.next_tx(user_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let mut state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();
    let failed = vault.withdraw(&policy, &mut state, 1, &clk, test.ctx());
    failed.burn_for_testing();

    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_shared(policy);
    clk.destroy_for_testing();
    test.end();
}

#[test]
fun vault_policy_update_reduces_available_capacity() {
    let owner = @0x31;
    let user = @0x32;
    let mut test = test_scenario::begin(owner);
    let initial_vault = coin::mint_for_testing<sui::sui::SUI>(0, test.ctx());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Start with a vault whose global bucket has capacity 100.
    vault::create_and_share(initial_vault, 0, 100, 25, 10, &clk, test.ctx());

    // Fund the vault so withdrawals are limited only by the bucket.
    test.next_tx(user);
    let mut vault = test.take_shared<vault::Vault>();
    let deposit = coin::mint_for_testing<sui::sui::SUI>(100, test.ctx());
    vault.deposit(deposit);
    test_scenario::return_shared(vault);

    // Confirm the original policy exposes the full initial capacity.
    test.next_tx(user);
    let vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();
    assert_eq!(vault.remaining_capacity(&policy, &state, &clk), 100);
    let old_policy_id = vault.active_policy_id();
    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_shared(policy);

    // The admin rotates to a stricter policy and migrates the shared state immediately.
    test.next_tx(owner);
    let mut vault = test.take_shared<vault::Vault>();
    let mut current_policy = test.take_shared_by_id<token_bucket::Policy<vault::WithdrawTag>>(
        old_policy_id,
    );
    let mut state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();
    vault.update_policy(&mut current_policy, &mut state, 1, 40, 10, 10, &clk, test.ctx());
    let new_policy_id = vault.active_policy_id();

    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_shared(current_policy);

    // The user now sees the reduced capacity under the new policy.
    test.next_tx(user);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared_by_id<token_bucket::Policy<vault::WithdrawTag>>(new_policy_id);
    let mut state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();

    assert_eq!(vault.remaining_capacity(&policy, &state, &clk), 40);
    let withdrawn = vault.withdraw(&policy, &mut state, 40, &clk, test.ctx());
    assert_eq!(withdrawn.value(), 40);
    assert_eq!(vault.remaining_capacity(&policy, &state, &clk), 0);

    withdrawn.burn_for_testing();
    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_shared(policy);

    clk.destroy_for_testing();
    test.end();
}
