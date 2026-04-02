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
    vault::deposit(&mut vault, deposit_a);
    test_scenario::return_shared(vault);

    // User B also funds the same shared vault.
    test.next_tx(user_b);
    let mut vault = test.take_shared<vault::Vault>();
    let deposit_b = coin::mint_for_testing<sui::sui::SUI>(40, test.ctx());
    vault::deposit(&mut vault, deposit_b);
    test_scenario::return_shared(vault);

    // User A withdraws first and consumes most of the shared bucket.
    test.next_tx(user_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_immutable<token_bucket::Policy<vault::WithdrawTag>>();
    let mut state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();
    let withdrawn_a = vault::withdraw(&mut vault, &policy, &mut state, 70, &clk, test.ctx());

    assert_eq!(coin::value(&withdrawn_a), 70);
    assert_eq!(vault::value(&vault), 50);
    assert_eq!(vault::remaining_capacity(&vault, &policy, &state, &clk), 30);

    coin::burn_for_testing(withdrawn_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_immutable(policy);

    // User B observes the reduced shared capacity and can only use what remains.
    test.next_tx(user_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_immutable<token_bucket::Policy<vault::WithdrawTag>>();
    let mut state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();
    let withdrawn_b = vault::withdraw(&mut vault, &policy, &mut state, 20, &clk, test.ctx());

    assert_eq!(coin::value(&withdrawn_b), 20);
    assert_eq!(vault::value(&vault), 30);
    assert_eq!(vault::remaining_capacity(&vault, &policy, &state, &clk), 10);

    coin::burn_for_testing(withdrawn_b);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_immutable(policy);

    clock::destroy_for_testing(clk);
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
    vault::deposit(&mut vault, deposit_a);
    test_scenario::return_shared(vault);

    // User B also deposits, but both users still share the same bucket.
    test.next_tx(user_b);
    let mut vault = test.take_shared<vault::Vault>();
    let deposit_b = coin::mint_for_testing<sui::sui::SUI>(40, test.ctx());
    vault::deposit(&mut vault, deposit_b);
    test_scenario::return_shared(vault);

    // User A consumes the entire global withdrawal capacity.
    test.next_tx(user_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_immutable<token_bucket::Policy<vault::WithdrawTag>>();
    let mut state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();
    let first = vault::withdraw(&mut vault, &policy, &mut state, 50, &clk, test.ctx());
    coin::burn_for_testing(first);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_immutable(policy);

    // User B now fails because no shared capacity is left.
    test.next_tx(user_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_immutable<token_bucket::Policy<vault::WithdrawTag>>();
    let mut state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();
    let failed = vault::withdraw(&mut vault, &policy, &mut state, 1, &clk, test.ctx());
    coin::burn_for_testing(failed);

    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_immutable(policy);
    clock::destroy_for_testing(clk);
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
    vault::deposit(&mut vault, deposit);
    test_scenario::return_shared(vault);

    // Confirm the original policy exposes the full initial capacity.
    test.next_tx(user);
    let vault = test.take_shared<vault::Vault>();
    let policy = test.take_immutable<token_bucket::Policy<vault::WithdrawTag>>();
    let state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();
    assert_eq!(vault::remaining_capacity(&vault, &policy, &state, &clk), 100);
    let old_policy_id = vault::active_policy_id(&vault);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_immutable(policy);

    // The admin rotates to a stricter policy and migrates the shared state immediately.
    test.next_tx(owner);
    let mut vault = test.take_shared<vault::Vault>();
    let current_policy = test.take_immutable_by_id<token_bucket::Policy<vault::WithdrawTag>>(
        old_policy_id,
    );
    let mut state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();
    vault::update_policy(&mut vault, &current_policy, &mut state, 1, 40, 10, 10, &clk, test.ctx());
    let new_policy_id = vault::active_policy_id(&vault);

    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_immutable(current_policy);

    // The user now sees the reduced capacity under the new policy.
    test.next_tx(user);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_immutable_by_id<token_bucket::Policy<vault::WithdrawTag>>(new_policy_id);
    let mut state = test.take_shared<token_bucket::State<vault::WithdrawTag>>();

    assert_eq!(vault::remaining_capacity(&vault, &policy, &state, &clk), 40);
    let withdrawn = vault::withdraw(&mut vault, &policy, &mut state, 40, &clk, test.ctx());
    assert_eq!(coin::value(&withdrawn), 40);
    assert_eq!(vault::remaining_capacity(&vault, &policy, &state, &clk), 0);

    coin::burn_for_testing(withdrawn);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(state);
    test_scenario::return_immutable(policy);

    clock::destroy_for_testing(clk);
    test.end();
}
