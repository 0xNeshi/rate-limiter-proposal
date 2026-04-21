#[test_only]
module library_scope::rate_limiter_tests;

use library_scope::rate_limiter;
use std::unit_test::assert_eq;
use sui::clock;
use sui::test_scenario;

// === Bucket ===

#[test]
fun bucket_starts_full_and_refills_over_time() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Create a bucket with capacity 30, refilling 5 every 10 ms.
    let mut rl = rate_limiter::new_bucket(30, 5, 10, &clk);
    assert_eq!(rl.available(&clk), 30);

    // Consuming 20 leaves 10 tokens.
    rl.consume_or_abort(20, &clk);
    assert_eq!(rl.available(&clk), 10);

    // After 20 ms, two refill steps (2 * 5 = 10) are credited back.
    clk.set_for_testing(20);
    assert_eq!(rl.available(&clk), 20);

    // Refill is capped at the configured capacity.
    clk.set_for_testing(1000);
    assert_eq!(rl.available(&clk), 30);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun bucket_try_consume_returns_false_when_empty() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_bucket(10, 1, 100, &clk);
    assert!(rl.try_consume(10, &clk));
    // No refill has happened yet, so the next consume fails without aborting.
    assert!(!rl.try_consume(1, &clk));

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun bucket_consume_or_abort_aborts_when_empty() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_bucket(5, 1, 10, &clk);
    rl.consume_or_abort(10, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun bucket_reconfigure_clamps_tokens_to_new_capacity() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Bucket at full capacity 100.
    let mut rl = rate_limiter::new_bucket(100, 10, 10, &clk);
    assert_eq!(rl.available(&clk), 100);

    // Shrink capacity to 40; stored tokens must be clamped down.
    rl.reconfigure_bucket(40, 10, 10, &clk);
    assert_eq!(rl.available(&clk), 40);

    clk.destroy_for_testing();
    test.end();
}

// === Fixed Window ===

#[test]
fun fixed_window_counts_per_window_and_resets_on_boundary() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // 3 consumes per 100 ms window.
    let mut rl = rate_limiter::new_fixed_window(3, 100, &clk);
    assert_eq!(rl.available(&clk), 3);

    rl.consume_or_abort(1, &clk);
    rl.consume_or_abort(1, &clk);
    assert_eq!(rl.available(&clk), 1);

    // Still inside the first window: fourth consume is blocked.
    assert!(!rl.try_consume(2, &clk));

    // Crossing into the next window resets usage back to full capacity.
    clk.set_for_testing(150);
    assert_eq!(rl.available(&clk), 3);
    rl.consume_or_abort(3, &clk);
    assert_eq!(rl.available(&clk), 0);

    clk.destroy_for_testing();
    test.end();
}

// === Cooldown ===

#[test]
fun cooldown_requires_elapsed_time_between_consumes() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(100);

    // 50 ms cooldown between single-unit consumes.
    let mut rl = rate_limiter::new_cooldown(50);
    assert_eq!(rl.available(&clk), 1);

    // First consume succeeds.
    rl.consume_or_abort(1, &clk);
    assert_eq!(rl.available(&clk), 0);

    // Before the cooldown elapses, consumes are rejected.
    clk.set_for_testing(140);
    assert!(!rl.try_consume(1, &clk));

    // After the cooldown, a consume succeeds again.
    clk.set_for_testing(150);
    assert_eq!(rl.available(&clk), 1);
    rl.consume_or_abort(1, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun cooldown_only_accepts_single_unit_consumes() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_cooldown(50);
    // Cooldown is inherently binary; any amount other than 1 is rejected.
    assert!(!rl.try_consume(2, &clk));
    assert!(!rl.try_consume(0, &clk));
    assert!(rl.try_consume(1, &clk));

    clk.destroy_for_testing();
    test.end();
}

// === Reconfigure variant guards ===

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_bucket_on_non_bucket_aborts() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_cooldown(50);
    rl.reconfigure_bucket(10, 1, 10, &clk);

    clk.destroy_for_testing();
    test.end();
}
