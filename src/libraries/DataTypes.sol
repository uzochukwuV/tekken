// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DataTypes
 * @notice Library containing all struct definitions for the betting platform
 * @dev Following Aave V3 pattern - centralized data types for stack-too-deep prevention
 *      All structs use tight packing where possible for gas optimization
 */
library DataTypes {
    // ============ Enums ============

    /// @notice Bet status throughout lifecycle
    enum BetStatus {
        Active,     // Bet placed, round not settled
        Won,        // Round settled, bet won
        Lost,       // Round settled, bet lost
        Cancelled,  // Cancelled before settlement
        Claimed     // Winnings claimed
    }

    /// @notice Match outcome options
    enum Outcome {
        None,       // 0 - Not set
        HomeWin,    // 1 - Home team wins
        AwayWin,    // 2 - Away team wins
        Draw        // 3 - Match ends in draw
    }

    /// @notice Round lifecycle status
    enum RoundStatus {
        None,       // Not created
        Created,    // Round created, not seeded
        Seeded,     // Seeded, betting open
        Locked,     // Betting closed, awaiting results
        Settled,    // Results in, payouts calculated
        Finalized   // Revenue distributed
    }

    // ============ Core Betting Structs ============

    /// @notice Individual match prediction within a bet
    /// @dev Packed to fit in single slot where possible
    struct Prediction {
        uint8 matchIndex;       // 0-9 (max 10 matches per round)
        uint8 predictedOutcome; // 1=HOME_WIN, 2=AWAY_WIN, 3=DRAW
    }

    /// @notice Core bet data - optimized for storage (Protocol-backed model)
    /// @dev Split into multiple slots for gas efficiency
    struct Bet {
        // Slot 1: addresses
        address bettor;         // 20 bytes
        address token;          // 20 bytes - LBT token

        // Slot 2: amounts
        uint128 amount;         // User's bet amount (max ~340 undecillion)
        uint128 potentialPayout;// Potential payout if bet wins

        // Slot 3: multiplier and IDs
        uint128 lockedMultiplier;   // Parlay multiplier (1e18 scale)
        uint64 roundId;             // Round identifier
        uint32 timestamp;           // Bet placement time
        uint8 legCount;             // Number of predictions (1-10)
        BetStatus status;           // Current bet status (1 byte)
    }

    /// @notice Bet predictions stored separately (avoids nested dynamic arrays)
    struct BetPredictions {
        Prediction[] predictions;
    }

    // ============ Pool Structs ============

    /// @notice Pool balances for a single match
    struct MatchPool {
        uint256 homeWinPool;    // Total bet on HOME_WIN (includes virtual seeds)
        uint256 awayWinPool;    // Total bet on AWAY_WIN (includes virtual seeds)
        uint256 drawPool;       // Total bet on DRAW (includes virtual seeds)
        uint256 totalPool;      // Sum of all three
        uint256 homeBetAmount;  // Only from real bets (excludes virtual seeds)
        uint256 awayBetAmount;  // Only from real bets (excludes virtual seeds)
        uint256 drawBetAmount;  // Only from real bets (excludes virtual seeds)
    }

    /// @notice Locked odds for a match (set at betting close)
    struct LockedOdds {
        uint64 homeOdds;        // e.g., 1.5e18 scaled down to 1.5e6
        uint64 awayOdds;        // Stored as 1e6 scale for packing
        uint64 drawOdds;
        bool locked;
    }

    // ============ Round Structs ============

    /// @notice Core round accounting data (Analytics-only, financial tracking in RoundPool)
    struct RoundAccounting {
        // Volume tracking (analytics)
        uint128 totalBetVolume;         // Total wagered this round
        uint32 parlayCount;             // Number of parlays
        uint32 totalBets;               // Total number of bets placed

        // NOTE: Financial tracking (locked, claimed, paid) now in RoundPool struct
        // This struct is for analytics/statistics only
    }

    /// @notice Round metadata and status (Protocol-backed model)
    struct RoundMetadata {
        // Timestamps
        uint64 roundStartTime;
        uint64 roundEndTime;

        // Status flags (packed)
        bool seeded;
        bool settled;
    }

    /// @notice Isolated round betting pool (NEW ACCOUNTING MODEL)
    /// @dev Each round has its own isolated pool of funds for paying winners
    struct RoundPool {
        uint256 totalLocked;           // Total funds locked in this round's pool (for payouts)
        uint256 totalClaimed;          // Amount already claimed from this pool
        uint256 sweepDeadline;         // Timestamp when pool can be swept (roundEndTime + 30 hours)
        bool swept;                    // Whether remaining funds have been swept back to protocol
    }

    // ============ LP Pool Structs ============

    /// @notice Individual LP deposit with a per-deposit time-lock
    /// @dev Each call to depositLiquidity() creates one LPDeposit entry.
    ///      LP holds multiple positions and can exit each independently after lockExpiry.
    ///      Early exit burns the position but charges a fee that stays in the pool,
    ///      benefiting remaining LPs (like a penalty for breaking a perp position early).
    struct LPDeposit {
        uint128 shares;          // LP shares minted — larger for longer lock tiers
        uint128 amount;          // Original LBT deposited
        uint64  depositTime;     // Block timestamp of deposit
        uint64  lockExpiry;      // depositTime + lockDuration; free exit after this
        uint8   lockTierIndex;   // 0=1d | 1=3d | 2=7d | 3=14d | 4=30d
        bool    active;          // False once withdrawn (never deleted — index stays stable)
    }

    /// @notice Legacy pool state (kept for ABI compatibility, not used in LP v2)
    struct PoolState {
        uint128 totalLiquidity;
        uint128 totalShares;
        uint128 lockedLiquidity;
        uint128 borrowedForBalancing;
        bool roundActive;
    }

    /// @notice Legacy LP position (kept for ABI compatibility, not used in LP v2)
    struct LPPosition {
        uint128 shares;
        uint128 totalDeposited;
        uint128 totalWithdrawn;
        uint64 lastDepositTime;
    }

    // ============ Params Structs (Stack-too-deep prevention) ============

    /// @notice Parameters for placing a bet
    struct PlaceBetParams {
        address bettor;
        address token;
        uint256 amount;
        uint256[] matchIndices;
        uint8[] predictions;
    }

    /// @notice Parameters for settling a round
    struct SettlementParams {
        uint256 roundId;
        uint8[] results;        // Outcome for each match
    }

    /// @notice Parameters for claiming winnings
    struct ClaimParams {
        uint256 betId;
        address claimer;
        uint256 minPayout;      // Slippage protection
    }

    /// @notice Parameters for LP operations
    struct LPParams {
        address lpProvider;
        address token;
        uint256 amount;
        uint256 minShares;      // For deposits
        uint256 minReceived;    // For withdrawals
    }

    /// @notice Parameters for revenue distribution
    struct RevenueParams {
        uint256 roundId;
        uint256 netProfit;
        uint256 protocolShare;
        uint256 lpShare;
        uint256 seasonShare;
    }

    // ============ View Return Structs ============

    /// @notice Full bet info for external queries
    struct BetInfo {
        address bettor;
        address token;
        uint256 amount;
        uint256 roundId;
        uint256 potentialPayout;
        uint256 lockedMultiplier;
        uint8 legCount;
        BetStatus status;
        Prediction[] predictions;
    }

    /// @notice Round summary for external queries
    struct RoundSummary {
        uint256 roundId;
        uint256 totalVolume;
        uint256 totalBets;
        uint256 parlayCount;
        RoundStatus status;
        uint256 startTime;
        uint256 endTime;
    }

    /// @notice LP position summary
    struct LPPositionSummary {
        uint256 shares;
        uint256 shareValue;
        uint256 sharePercentage;
        uint256 totalDeposited;
        uint256 totalWithdrawn;
        int256 profitLoss;
    }

    // ============ Config Structs ============

    /// @notice Protocol fee configuration (Protocol-backed model)
    struct FeeConfig {
        uint16 protocolFeeBps;      // Protocol fee (basis points)
        uint16 seasonPoolFeeBps;    // Season pool fee (basis points)
        uint16 cancellationFeeBps;  // Cancellation fee (basis points)
    }

    /// @notice Betting limits configuration
    struct BettingLimits {
        uint128 maxBetAmount;       // Max single bet
        uint128 maxPayoutPerBet;    // Max payout per bet
        uint128 maxRoundPayouts;    // Max total payouts per round
        uint128 minBetAmount;       // Minimum bet
    }

    /// @notice Parlay multiplier configuration
    struct ParlayConfig {
        uint128[] legMultipliers;   // Multiplier per leg count (index 0 = 1 leg)
        uint32[] countTierThresholds; // Parlay count tiers
        uint128[] countTierMultipliers; // Multiplier per tier
    }

    /// @notice Seeding configuration per match
    struct SeedConfig {
        uint128 homeSeed;
        uint128 awaySeed;
        uint128 drawSeed;
    }
}
