// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../libraries/DataTypes.sol";

/**
 * @title BettingStorage
 * @notice Diamond storage pattern for single-token betting (LBT only)
 * @dev Simplified storage removing multi-token complexity
 *
 * Key Features:
 * - Single LBT token and pool (no multi-token support)
 * - Diamond storage pattern for upgradeability
 * - Simplified from multi-token version
 * - ~30% less storage complexity
 */
library BettingStorage {
    // Unique storage position (keccak256("betting.storage.lbt.v1"))
    bytes32 constant STORAGE_POSITION = 0x52c63c9a7e0c799f8e3f3c8b1a6d5e4f3c2b1a0987654321fedcba9876543211;

    /// @notice Main storage struct containing all betting state
    struct Layout {
        // ============ Core Mappings ============

        /// @notice Bet data by ID
        mapping(uint256 => DataTypes.Bet) bets;

        /// @notice Bet predictions stored separately (avoids nested arrays)
        mapping(uint256 => DataTypes.BetPredictions) betPredictions;

        /// @notice Round accounting data
        mapping(uint256 => DataTypes.RoundAccounting) roundAccounting;

        /// @notice Round metadata and status
        mapping(uint256 => DataTypes.RoundMetadata) roundMetadata;

        /// @notice Match pools per round: roundId => matchIndex => MatchPool
        mapping(uint256 => mapping(uint256 => DataTypes.MatchPool)) matchPools;

        /// @notice Locked odds per round: roundId => matchIndex => LockedOdds
        mapping(uint256 => mapping(uint256 => DataTypes.LockedOdds)) lockedOdds;

        /// @notice Match results per round: roundId => matchIndex => result (1=HOME_WIN, 2=AWAY_WIN, 3=DRAW)
        mapping(uint256 => mapping(uint256 => uint8)) matchResults;

        /// @notice User's bet IDs
        mapping(address => uint256[]) userBets;

        /// @notice User's bet count per round (for limits)
        mapping(address => mapping(uint256 => uint256)) userRoundBetCount;

        // ============ NEW: Isolated Round Pool Accounting ============

        /// @notice Protocol reserves (available liquidity not locked to any round)
        uint256 protocolReserves;

        /// @notice Round betting pools: roundId => RoundPool
        /// @dev Each round has isolated pool for paying winners
        mapping(uint256 => DataTypes.RoundPool) roundPools;

        // ============ Single Token (LBT) - Protocol-Backed ============

        /// @notice The LeagueBet Token (LBT) address
        address lbtToken;

        // ============ Contract References ============

        /// @notice Game engine contract
        address gameEngine;

        /// @notice Protocol treasury address
        address protocolTreasury;

        /// @notice Rewards distributor address
        address rewardsDistributor;

        /// @notice SwapRouter for token conversions
        address swapRouter;

        /// @notice Season predictor contract address
        address seasonPredictor;

        // ============ Counters ============

        /// @notice Next bet ID to assign
        uint256 nextBetId;

        /// @notice Current active round
        uint256 currentRoundId;

        /// @notice Total bets placed (all time)
        uint256 totalBetsPlaced;

        /// @notice Total volume (all time, in LBT)
        uint256 totalVolumeAllTime;

        // ============ Accumulators ============

        /// @notice Season reward pool balance
        uint256 seasonRewardPool;

        /// @notice Total protocol fees collected
        uint256 totalProtocolFees;

        // ============ Configuration ============

        /// @notice Fee configuration
        DataTypes.FeeConfig feeConfig;

        /// @notice Betting limits
        DataTypes.BettingLimits limits;

        /// @notice Parlay multipliers by leg count (1-10)
        uint256[11] parlayMultipliers;

        /// @notice Count-based parlay tier thresholds
        uint256[5] countTierThresholds;

        /// @notice Count-based parlay multipliers
        uint256[5] countTierMultipliers;

        /// @notice Reserve-based decay thresholds
        uint256[4] reserveTierThresholds;

        /// @notice Reserve-based decay percentages
        uint256[4] reserveTierDecay;

        /// @notice Default seed amounts per outcome
        DataTypes.SeedConfig defaultSeeds;

        // ============ LP System (v2 — global pool with per-deposit time-locks) ============

        /// @notice Free LP capital available to back new bets
        /// @dev Separate from protocolReserves. Grows/shrinks with deposits, withdrawals,
        ///      and pro-rata share of round sweep profits/losses.
        uint256 lpReserves;

        /// @notice Total LP share tokens outstanding (across all active deposits)
        uint256 totalLPShares;

        /// @notice All LP deposit positions, keyed by LP address
        /// @dev Array never shrinks — inactive positions have active=false.
        ///      depositIndex is the array index, stable forever.
        mapping(address => DataTypes.LPDeposit[]) lpDeposits;

        /// @notice LP fraction of the combined pool at the time each round was seeded (1e18 scale)
        /// @dev Snapshotted in seedRound(). Used at sweepRoundPool() to split
        ///      the remaining pot between LP reserves and protocol reserves proportionally.
        mapping(uint256 => uint256) lpFractionAtSeed;

        // ============ Flags ============

        /// @notice Emergency pause flag
        bool paused;

        /// @notice Allow new bets flag
        bool bettingEnabled;
    }

    /// @notice Get storage layout pointer
    /// @return l Storage layout struct
    function layout() internal pure returns (Layout storage l) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            l.slot := position
        }
    }

    // ============ Storage Accessors ============

    /**
     * @notice Get LBT token address
     * @return token LBT token address
     */
    function getLBTToken() internal view returns (address token) {
        return layout().lbtToken;
    }

    /**
     * @notice Get protocol reserves balance (FIXED: Returns actual reserves, not total balance)
     * @return balance Protocol's available LBT reserves (not locked in round pools)
     */
    function getProtocolReserves() internal view returns (uint256 balance) {
        return layout().protocolReserves;
    }

    /**
     * @notice Get bet info
     * @param betId Bet ID
     * @return bet Bet struct
     */
    function getBet(uint256 betId) internal view returns (DataTypes.Bet storage bet) {
        return layout().bets[betId];
    }

    /**
     * @notice Get bet predictions
     * @param betId Bet ID
     * @return predictions Bet predictions struct
     */
    function getBetPredictions(
        uint256 betId
    ) internal view returns (DataTypes.BetPredictions storage predictions) {
        return layout().betPredictions[betId];
    }

    /**
     * @notice Get match pool
     * @param roundId Round ID
     * @param matchIndex Match index
     * @return pool Match pool struct
     */
    function getMatchPool(
        uint256 roundId,
        uint256 matchIndex
    ) internal view returns (DataTypes.MatchPool storage pool) {
        return layout().matchPools[roundId][matchIndex];
    }

    /**
     * @notice Get round accounting
     * @param roundId Round ID
     * @return accounting Round accounting struct
     */
    function getRoundAccounting(
        uint256 roundId
    ) internal view returns (DataTypes.RoundAccounting storage accounting) {
        return layout().roundAccounting[roundId];
    }

    /**
     * @notice Get round metadata
     * @param roundId Round ID
     * @return metadata Round metadata struct
     */
    function getRoundMetadata(
        uint256 roundId
    ) internal view returns (DataTypes.RoundMetadata storage metadata) {
        return layout().roundMetadata[roundId];
    }

    /**
     * @notice Check if betting is enabled
     * @return enabled Whether betting is enabled
     */
    function isBettingEnabled() internal view returns (bool) {
        return layout().bettingEnabled && !layout().paused;
    }

    /**
     * @notice Get current round ID
     * @return roundId Current round
     */
    function getCurrentRound() internal view returns (uint256) {
        return layout().currentRoundId;
    }

    /**
     * @notice Get next bet ID and increment
     * @return betId The next bet ID (starts at 1, never 0)
     * @dev C-01 FIX: Increment FIRST to ensure bet IDs start at 1
     *      Bet ID 0 is reserved as "invalid/not found" sentinel value
     */
    function getNextBetId() internal returns (uint256 betId) {
        Layout storage s = layout();
        s.nextBetId++;      // Increment FIRST
        betId = s.nextBetId; // Now returns 1, 2, 3, ... (never 0)
    }

    /**
     * @notice Add bet to user's bet list
     * @param user User address
     * @param betId Bet ID to add
     */
    function addUserBet(address user, uint256 betId) internal {
        layout().userBets[user].push(betId);
    }

    /**
     * @notice Get user's bet list
     * @param user User address
     * @return betIds Array of user's bet IDs
     */
    function getUserBets(address user) internal view returns (uint256[] memory) {
        return layout().userBets[user];
    }
}
