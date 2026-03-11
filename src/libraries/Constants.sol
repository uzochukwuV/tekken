// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Constants
 * @notice Protocol-wide constants for the betting platform
 * @dev Centralized constants prevent magic numbers and enable easy auditing
 */
library Constants {
    // ============ Precision ============

    uint256 constant PRECISION = 1e18;
    uint256 constant BPS_PRECISION = 10000; // Basis points (100% = 10000)
    uint256 constant ODDS_PRECISION = 1e18; // Odds stored as 1.5e18 = 1.5x

    // ============ Fee Configuration (Basis Points) - Protocol-Backed Model ============

    uint256 constant PROTOCOL_FEE_BPS = 9800;     // 98% to protocol treasury (reserves)
    uint256 constant SEASON_POOL_FEE_BPS = 200;   // 2% to season rewards
    uint256 constant CANCELLATION_FEE_BPS = 1000; // 10% cancellation fee

    // ============ Betting Limits ============

    uint256 constant MAX_BET_AMOUNT = 10_000 ether;      // Max single bet
    uint256 constant MAX_PAYOUT_PER_BET = 100_000 ether; // Max payout per bet
    uint256 constant MAX_ROUND_PAYOUTS = 500_000 ether;  // Max payouts per round
    uint256 constant MIN_BET_AMOUNT = 1e6;               // Minimum bet (1 USDC with 6 decimals, or 0.000001 tokens with 18 decimals)

    // ============ Parlay Multipliers (1e18 scale) ============
    // Linear progression from 1.0x (1 match) to 1.25x (10 matches)

    uint256 constant PARLAY_MULT_1_MATCH = 1e18;      // 1.00x
    uint256 constant PARLAY_MULT_2_MATCHES = 105e16;  // 1.05x
    uint256 constant PARLAY_MULT_3_MATCHES = 110e16;  // 1.10x
    uint256 constant PARLAY_MULT_4_MATCHES = 113e16;  // 1.13x
    uint256 constant PARLAY_MULT_5_MATCHES = 116e16;  // 1.16x
    uint256 constant PARLAY_MULT_6_MATCHES = 119e16;  // 1.19x
    uint256 constant PARLAY_MULT_7_MATCHES = 121e16;  // 1.21x
    uint256 constant PARLAY_MULT_8_MATCHES = 123e16;  // 1.23x
    uint256 constant PARLAY_MULT_9_MATCHES = 124e16;  // 1.24x
    uint256 constant PARLAY_MULT_10_MATCHES = 125e16; // 1.25x

    // ============ Count-Based Parlay Tiers ============
    // FOMO mechanism: early parlays get higher multipliers

    uint256 constant COUNT_TIER_1 = 10;   // First 10 parlays
    uint256 constant COUNT_TIER_2 = 20;   // Parlays 11-20
    uint256 constant COUNT_TIER_3 = 30;   // Parlays 21-30
    uint256 constant COUNT_TIER_4 = 40;   // Parlays 31-40
    // Tier 5: 41+ parlays

    uint256 constant COUNT_MULT_TIER_1 = 25e17;  // 2.5x (first 10)
    uint256 constant COUNT_MULT_TIER_2 = 22e17;  // 2.2x
    uint256 constant COUNT_MULT_TIER_3 = 19e17;  // 1.9x
    uint256 constant COUNT_MULT_TIER_4 = 16e17;  // 1.6x
    uint256 constant COUNT_MULT_TIER_5 = 13e17;  // 1.3x (41+)

    // ============ Reserve-Based Decay ============
    // Safety valve: reduce multipliers when reserves are high

    uint256 constant RESERVE_TIER_1 = 100_000 ether;  // 0-100k
    uint256 constant RESERVE_TIER_2 = 250_000 ether;  // 100k-250k
    uint256 constant RESERVE_TIER_3 = 500_000 ether;  // 250k-500k
    // Tier 4: 500k+

    uint256 constant DECAY_TIER_1 = 10000; // 100% (no decay)
    uint256 constant DECAY_TIER_2 = 8800;  // 88%
    uint256 constant DECAY_TIER_3 = 7600;  // 76%
    uint256 constant DECAY_TIER_4 = 6400;  // 64%

    // ============ Seeding Configuration ============

    // Total virtual seed per match (distributed pseudo-randomly across outcomes)
    // Target odds range: [1.25x - 2.05x] (compressed for tight, competitive odds)
    //
    // Odds Compression System:
    //   - Raw parimutuel odds calculated from pool allocations (varies by team strength)
    //   - Linear compression maps [1.0x - 10.0x] raw → [1.25x - 2.05x] compressed
    //   - Formula: compressed = 1.25 + (raw - 1.0) * 0.80 / 9.0
    //
    // Example Compression:
    //   - Raw 1.5x (strong favorite) → Compressed 1.29x
    //   - Raw 2.0x (moderate favorite) → Compressed 1.34x
    //   - Raw 3.0x (underdog) → Compressed 1.43x
    //   - Raw 5.0x (big underdog) → Compressed 1.61x
    //   - Raw 10.0x (extreme underdog) → Compressed 2.05x (max)
    //
    // Tight range ensures predictable payouts and sustainable liquidity management
    uint256 constant SEED_PER_MATCH = 4500 ether;   // Total seed per match
    uint256 constant MATCHES_PER_ROUND = 10;
    uint256 constant SEED_PER_ROUND = SEED_PER_MATCH * MATCHES_PER_ROUND;

    // ============ Virtual Liquidity ============

    uint256 constant VIRTUAL_LIQUIDITY_MULTIPLIER = 12_000_000;

    // ============ LP Pool ============

    uint256 constant MINIMUM_LIQUIDITY = 1000; // Locked forever on first deposit

    // ============ LP Lock Tiers ============
    // Per-deposit time-locks with bonus share multipliers ("perp long" model)

    uint256 constant LP_MIN_DEPOSIT      = 100 ether;  // 100 LBT minimum per deposit
    uint256 constant LP_EARLY_EXIT_FEE_BPS = 1000;     // 10% penalty — stays in pool for remaining LPs
    uint256 constant MINIMUM_LP_SHARES   = 1000;        // Permanently locked on first deposit (inflation guard)

    // Lock durations
    uint256 constant LP_LOCK_1D  = 1 days;
    uint256 constant LP_LOCK_3D  = 3 days;
    uint256 constant LP_LOCK_7D  = 7 days;
    uint256 constant LP_LOCK_14D = 14 days;
    uint256 constant LP_LOCK_30D = 30 days;

    // Share multipliers per tier (BPS — 10000 = 1.00x baseline)
    // Longer lock → more shares minted per LBT → bigger slice of pool profits
    uint256 constant LP_MULT_1D  = 10000;  // 1.00x
    uint256 constant LP_MULT_3D  = 10500;  // 1.05x
    uint256 constant LP_MULT_7D  = 11000;  // 1.10x
    uint256 constant LP_MULT_14D = 11500;  // 1.15x
    uint256 constant LP_MULT_30D = 12500;  // 1.25x

    // ============ Match Duration ============

    uint256 constant MAX_ROUND_DURATION = 48 hours; // Maximum single-match duration

    // ============ Bounty System ============

    uint256 constant MIN_BOUNTY_CLAIM = 50 ether;  // Minimum payout for bounty claims (50 LBT)
    uint256 constant BOUNTY_PERCENTAGE = 1000;     // 10% bounty in basis points (10% of payout)

    // ============ Round Pool Sweep System ============

    uint256 constant SWEEP_GRACE_PERIOD = 6 hours;    // Grace period after bounty window before sweep
    uint256 constant LATE_CLAIM_FEE_BPS = 1500;       // 15% fee for claims after sweep (basis points)

    // ============ Time Constants ============

    uint256 constant ROUND_DURATION = 3 hours;
    uint256 constant BETTING_CUTOFF = 30 minutes; // Before round end
    uint256 constant VRF_TIMEOUT = 2 hours;       // Emergency settle after
    uint256 constant CLAIM_DEADLINE = 24 hours;   // Winner must claim within 24h after settlement
    // Total sweep deadline = CLAIM_DEADLINE + SWEEP_GRACE_PERIOD = 30 hours

    // ============ Match Constants ============

    uint8 constant MAX_MATCHES_PER_ROUND = 10;
    uint8 constant MIN_MATCHES_PER_BET = 1;
    uint8 constant MAX_MATCHES_PER_BET = 10;

    // ============ Outcome Values ============

    uint8 constant OUTCOME_NONE = 0;
    uint8 constant OUTCOME_HOME_WIN = 1;
    uint8 constant OUTCOME_AWAY_WIN = 2;
    uint8 constant OUTCOME_DRAW = 3;
}
