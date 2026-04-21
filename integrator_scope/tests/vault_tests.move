#[test_only]
module integrator_scope::vault_tests;

use integrator_scope::vault;
use library_scope::rate_limiter;
use std::unit_test::assert_eq;
use sui::clock;
use sui::test_scenario;

#[test]
fun vault_users_share_one_global_bucket() {
    let owner = @0x11;
    let user_a = @0x12;
    let user_b = @0x13;
    let mut test = test_scenario::begin(owner);
    let initial_vault = sui::coin::mint_for_testing<sui::sui::SUI>(0, test.ctx());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Create the shared vault with one global withdrawal bucket.
    vault::create_and_share(initial_vault, 100, 25, 10, &clk, test.ctx());

    // User A funds the vault.
    test.next_tx(user_a);
    let mut vault = test.take_shared<vault::Vault>();
    let deposit_a = sui::coin::mint_for_testing<sui::sui::SUI>(80, test.ctx());
    vault.deposit(deposit_a);
    test_scenario::return_shared(vault);

    // User B also funds the same shared vault.
    test.next_tx(user_b);
    let mut vault = test.take_shared<vault::Vault>();
    let deposit_b = sui::coin::mint_for_testing<sui::sui::SUI>(40, test.ctx());
    vault.deposit(deposit_b);
    test_scenario::return_shared(vault);

    // User A withdraws first and consumes most of the shared bucket.
    test.next_tx(user_a);
    let mut vault = test.take_shared<vault::Vault>();
    let withdrawn_a = vault.withdraw(70, &clk, test.ctx());

    assert_eq!(withdrawn_a.value(), 70);
    assert_eq!(vault.value(), 50);
    assert_eq!(vault.remaining_capacity(&clk), 30);

    withdrawn_a.burn_for_testing();
    test_scenario::return_shared(vault);

    // User B observes the reduced shared capacity and can only use what remains.
    test.next_tx(user_b);
    let mut vault = test.take_shared<vault::Vault>();
    let withdrawn_b = vault.withdraw(20, &clk, test.ctx());

    assert_eq!(withdrawn_b.value(), 20);
    assert_eq!(vault.value(), 30);
    assert_eq!(vault.remaining_capacity(&clk), 10);

    withdrawn_b.burn_for_testing();
    test_scenario::return_shared(vault);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun vault_second_user_fails_after_global_capacity_is_consumed() {
    let owner = @0x21;
    let user_a = @0x22;
    let user_b = @0x23;
    let mut test = test_scenario::begin(owner);
    let initial_vault = sui::coin::mint_for_testing<sui::sui::SUI>(0, test.ctx());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Create a vault whose shared bucket only allows 50 units immediately.
    vault::create_and_share(initial_vault, 50, 10, 10, &clk, test.ctx());

    // User A deposits enough funds for the test scenario.
    test.next_tx(user_a);
    let mut vault = test.take_shared<vault::Vault>();
    let deposit_a = sui::coin::mint_for_testing<sui::sui::SUI>(60, test.ctx());
    vault.deposit(deposit_a);
    test_scenario::return_shared(vault);

    // User B also deposits, but both users still share the same bucket.
    test.next_tx(user_b);
    let mut vault = test.take_shared<vault::Vault>();
    let deposit_b = sui::coin::mint_for_testing<sui::sui::SUI>(40, test.ctx());
    vault.deposit(deposit_b);
    test_scenario::return_shared(vault);

    // User A consumes the entire global withdrawal capacity.
    test.next_tx(user_a);
    let mut vault = test.take_shared<vault::Vault>();
    let first = vault.withdraw(50, &clk, test.ctx());
    first.burn_for_testing();
    test_scenario::return_shared(vault);

    // User B now fails because no shared capacity is left.
    test.next_tx(user_b);
    let mut vault = test.take_shared<vault::Vault>();
    let failed = vault.withdraw(1, &clk, test.ctx());
    failed.burn_for_testing();
    test_scenario::return_shared(vault);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun vault_policy_update_reduces_available_capacity() {
    let owner = @0x31;
    let user = @0x32;
    let mut test = test_scenario::begin(owner);
    let initial_vault = sui::coin::mint_for_testing<sui::sui::SUI>(0, test.ctx());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Start with a vault whose global bucket has capacity 100.
    vault::create_and_share(initial_vault, 100, 25, 10, &clk, test.ctx());

    // Fund the vault so withdrawals are limited only by the bucket.
    test.next_tx(user);
    let mut vault = test.take_shared<vault::Vault>();
    let deposit = sui::coin::mint_for_testing<sui::sui::SUI>(100, test.ctx());
    vault.deposit(deposit);
    test_scenario::return_shared(vault);

    // Confirm the original configuration exposes the full initial capacity.
    test.next_tx(user);
    let vault = test.take_shared<vault::Vault>();
    assert_eq!(vault.remaining_capacity(&clk), 100);
    test_scenario::return_shared(vault);

    // The admin updates to a stricter policy; the embedded limiter is reconfigured in place.
    test.next_tx(owner);
    let mut vault = test.take_shared<vault::Vault>();
    vault.update_policy(40, 10, 10, &clk, test.ctx());
    test_scenario::return_shared(vault);

    // The user now sees the reduced capacity under the new policy.
    test.next_tx(user);
    let mut vault = test.take_shared<vault::Vault>();

    assert_eq!(vault.remaining_capacity(&clk), 40);
    let withdrawn = vault.withdraw(40, &clk, test.ctx());
    assert_eq!(withdrawn.value(), 40);
    assert_eq!(vault.remaining_capacity(&clk), 0);

    withdrawn.burn_for_testing();
    test_scenario::return_shared(vault);

    clk.destroy_for_testing();
    test.end();
}
