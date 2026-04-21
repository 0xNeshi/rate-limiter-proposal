#[test_only]
module integrator_scope::mage_game_tests;

use integrator_scope::mage_game;
use library_scope::token_bucket;
use std::unit_test::assert_eq;
use sui::clock;
use sui::test_scenario;

#[test]
fun mages_have_independent_mana_and_regenerate_over_time() {
    let admin = @0x41;
    let player_a = @0x42;
    let player_b = @0x43;
    let mut test = test_scenario::begin(admin);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Create the shared game and initial mana policy.
    mage_game::create_and_share(0, 30, 5, 10, test.ctx());

    // Player A creates a mage whose mana starts at full capacity.
    test.next_tx(player_a);
    let game = test.take_shared<mage_game::Game>();
    let mut policy = test.take_shared<token_bucket::Policy<mage_game::ManaTag>>();
    let mage_a = game.create_mage(&mut policy, &clk, test.ctx());
    transfer::public_transfer(mage_a, player_a);
    test_scenario::return_shared(game);
    test_scenario::return_shared(policy);

    // Player B creates an independent mage with its own mana state.
    test.next_tx(player_b);
    let game = test.take_shared<mage_game::Game>();
    let mut policy = test.take_shared<token_bucket::Policy<mage_game::ManaTag>>();
    let mage_b = game.create_mage(&mut policy, &clk, test.ctx());
    transfer::public_transfer(mage_b, player_b);
    test_scenario::return_shared(game);
    test_scenario::return_shared(policy);

    // Player A spends mana and leaves only 10 available.
    test.next_tx(player_a);
    let game = test.take_shared<mage_game::Game>();
    let policy = test.take_shared<token_bucket::Policy<mage_game::ManaTag>>();
    let mut mage_a = test.take_from_sender<mage_game::Mage>();
    game.cast_crucio(&policy, &mut mage_a, &clk, test.ctx());
    assert_eq!(game.mana(&policy, &mage_a, &clk), 10);
    test_scenario::return_to_sender(&test, mage_a);
    test_scenario::return_shared(game);
    test_scenario::return_shared(policy);

    // Player B spends mana separately and is unaffected by player A's usage.
    test.next_tx(player_b);
    let game = test.take_shared<mage_game::Game>();
    let policy = test.take_shared<token_bucket::Policy<mage_game::ManaTag>>();
    let mut mage_b = test.take_from_sender<mage_game::Mage>();
    game.cast_expeliarmus(&policy, &mut mage_b, &clk, test.ctx());
    assert_eq!(game.mana(&policy, &mage_b, &clk), 20);
    test_scenario::return_to_sender(&test, mage_b);
    test_scenario::return_shared(game);
    test_scenario::return_shared(policy);

    // Advance time so both mana buckets refill.
    clk.set_for_testing(20);

    // Player A regains mana according to the refill schedule.
    test.next_tx(player_a);
    let game = test.take_shared<mage_game::Game>();
    let policy = test.take_shared<token_bucket::Policy<mage_game::ManaTag>>();
    let mage_a = test.take_from_sender<mage_game::Mage>();
    assert_eq!(game.mana(&policy, &mage_a, &clk), 20);
    test_scenario::return_to_sender(&test, mage_a);
    test_scenario::return_shared(game);
    test_scenario::return_shared(policy);

    // Player B independently refills back to full.
    test.next_tx(player_b);
    let game = test.take_shared<mage_game::Game>();
    let policy = test.take_shared<token_bucket::Policy<mage_game::ManaTag>>();
    let mage_b = test.take_from_sender<mage_game::Mage>();
    assert_eq!(game.mana(&policy, &mage_b, &clk), 30);
    test_scenario::return_to_sender(&test, mage_b);
    test_scenario::return_shared(game);
    test_scenario::return_shared(policy);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = mage_game::EStaleMagePolicy)]
fun mage_must_upgrade_to_latest_policy_before_casting() {
    let admin = @0x51;
    let player_a = @0x52;
    let player_b = @0x53;
    let mut test = test_scenario::begin(admin);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Create the game with an initial mana policy.
    mage_game::create_and_share(0, 30, 10, 10, test.ctx());

    // Player A creates a mage under the initial policy.
    test.next_tx(player_a);
    let game = test.take_shared<mage_game::Game>();
    let mut policy = test.take_shared<token_bucket::Policy<mage_game::ManaTag>>();
    let mage_a = game.create_mage(&mut policy, &clk, test.ctx());
    transfer::public_transfer(mage_a, player_a);
    test_scenario::return_shared(game);
    test_scenario::return_shared(policy);

    // Player B also creates a mage under the same initial policy.
    test.next_tx(player_b);
    let game = test.take_shared<mage_game::Game>();
    let mut policy = test.take_shared<token_bucket::Policy<mage_game::ManaTag>>();
    let mage_b = game.create_mage(&mut policy, &clk, test.ctx());
    transfer::public_transfer(mage_b, player_b);
    test_scenario::return_shared(game);
    test_scenario::return_shared(policy);

    // Player A uses mana before the policy changes, establishing an old-policy state.
    test.next_tx(player_a);
    let game = test.take_shared<mage_game::Game>();
    let policy = test.take_shared<token_bucket::Policy<mage_game::ManaTag>>();
    let mut mage_a = test.take_from_sender<mage_game::Mage>();
    game.cast_crucio(&policy, &mut mage_a, &clk, test.ctx());
    let old_policy_id = game.active_policy_id();
    test_scenario::return_to_sender(&test, mage_a);
    test_scenario::return_shared(game);
    test_scenario::return_shared(policy);

    // Player B also acts while the old policy is still current.
    test.next_tx(player_b);
    let game = test.take_shared<mage_game::Game>();
    let policy = test.take_shared_by_id<token_bucket::Policy<mage_game::ManaTag>>(old_policy_id);
    let mut mage_b = test.take_from_sender<mage_game::Mage>();
    game.cast_expeliarmus(&policy, &mut mage_b, &clk, test.ctx());
    test_scenario::return_to_sender(&test, mage_b);
    test_scenario::return_shared(game);
    test_scenario::return_shared(policy);

    // The admin rotates the game to a new policy version.
    test.next_tx(admin);
    let mut game = test.take_shared<mage_game::Game>();
    let mut current_policy = test.take_shared_by_id<token_bucket::Policy<mage_game::ManaTag>>(
        old_policy_id,
    );
    game.update_policy(&mut current_policy, 1, 40, 10, 10, test.ctx());
    let new_policy_id = game.active_policy_id();
    test_scenario::return_shared(game);
    test_scenario::return_shared(current_policy);

    // Advance time before testing migration under the new policy.
    clk.set_for_testing(20);

    // Player A explicitly migrates and can keep casting under the new policy.
    test.next_tx(player_a);
    let game = test.take_shared<mage_game::Game>();
    let old_policy = test.take_shared_by_id<token_bucket::Policy<mage_game::ManaTag>>(
        old_policy_id,
    );
    let new_policy = test.take_shared_by_id<token_bucket::Policy<mage_game::ManaTag>>(
        new_policy_id,
    );
    let mut mage_a = test.take_from_sender<mage_game::Mage>();
    game.update_mage_policy(&old_policy, &new_policy, &mut mage_a, &clk, test.ctx());
    assert_eq!(game.mana(&new_policy, &mage_a, &clk), 30);
    game.cast_avada_kedavra(&new_policy, &mut mage_a, &clk, test.ctx());
    assert_eq!(game.mana(&new_policy, &mage_a, &clk), 0);
    test_scenario::return_to_sender(&test, mage_a);
    test_scenario::return_shared(game);
    test_scenario::return_shared(old_policy);
    test_scenario::return_shared(new_policy);

    // Player B skips migration and fails when trying to cast against the new policy.
    test.next_tx(player_b);
    let game = test.take_shared<mage_game::Game>();
    let new_policy = test.take_shared_by_id<token_bucket::Policy<mage_game::ManaTag>>(
        new_policy_id,
    );
    let mut mage_b = test.take_from_sender<mage_game::Mage>();
    game.cast_expeliarmus(&new_policy, &mut mage_b, &clk, test.ctx());
    test_scenario::return_to_sender(&test, mage_b);
    test_scenario::return_shared(game);
    test_scenario::return_shared(new_policy);

    clk.destroy_for_testing();
    test.end();
}
