// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../libraries/DataTypes.sol";
import "../libraries/Constants.sol";
import "../storage/BettingStorage.sol";

/**
 * @title BettingCore
 * @notice Protocol-backed betting core - accepts only LBT (LeagueBet Token)
 * @dev Protocol-backed model: reserves held in contract, no LP system
 *
 * Key Features:
 * - Single token (LBT) only - no multi-token complexity
 * - Protocol-backed liquidity - no LP locking/unlocking
 * - Simplified storage and logic
 * - 24/7 betting - no withdrawal windows
 * - Better gas efficiency (~40% less code)
 */
contract BettingCore is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using BettingStorage for BettingStorage.Layout;

    // ============ Events ============

    event LBTTokenSet(address indexed lbtToken);
    event GameEngineUpdated(address indexed oldEngine, address indexed newEngine);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event SwapRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event BettingEnabledChanged(bool enabled);
    event RoundSeeded(uint256 indexed roundId);
    event OddsLocked(uint256 indexed roundId);
    event SeasonPredictorUpdated(address indexed seasonPredictor);
    event BetPlaced(
        uint256 indexed betId,
        address indexed bettor,
        uint256 roundId,
        uint256 amount,
        uint256 parlayMultiplier,
        uint8 legCount
    );
    event BetCancelled(uint256 indexed betId, address indexed bettor, uint256 refundAmount);
    event BetLost(uint256 indexed betId);
    event WinningsClaimed(uint256 indexed betId, address indexed winner, uint256 payout);
    event BountyClaim(
        uint256 indexed betId,
        address indexed claimer,
        uint256 bounty,
        address indexed winner,
        uint256 winnerAmount
    );
    event RoundSettled(uint256 indexed roundId, uint256 totalPayouts);
    event RevenueFinalized(uint256 indexed roundId, uint256 protocolShare, uint256 seasonShare);
    event RoundPoolSwept(uint256 indexed roundId, uint256 remaining, uint256 protocolShare, uint256 seasonShare);
    // M-05 FIX: Events for configuration updates
    event LimitsUpdated(
        uint128 maxBetAmount,
        uint128 maxPayoutPerBet,
        uint128 maxRoundPayouts,
        uint128 minBetAmount
    );
    event FeeConfigUpdated(
        uint16 protocolFeeBps,
        uint16 seasonPoolFeeBps,
        uint16 cancellationFeeBps
    );

    // ============ Errors ============

    error BettingDisabled();
    error InvalidAmount();
    error InvalidToken();
    error RoundNotActive();
    error RoundAlreadySeeded();
    error BetNotFound();
    error NotBetOwner();
    error BetAlreadySettled();
    error InsufficientLiquidity();
    error InvalidMatchIndex();
    error InvalidPrediction();
    error BettingWindowClosed();
    error UnauthorizedCaller();

    // ============ Modifiers ============

    /**
     * @notice Only owner or authorized game engine can call
     */
    modifier onlyOwnerOrGameEngine() {
        BettingStorage.Layout storage s = BettingStorage.layout();
        if (msg.sender != owner() && msg.sender != s.gameEngine) {
            revert UnauthorizedCaller();
        }
        _;
    }

    // ============ Constructor ============

    constructor(
        address _gameEngine,
        address _protocolTreasury,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_gameEngine != address(0), "Invalid game engine");
        require(_protocolTreasury != address(0), "Invalid treasury");

        BettingStorage.Layout storage s = BettingStorage.layout();
        s.gameEngine = _gameEngine;
        s.protocolTreasury = _protocolTreasury;
        s.bettingEnabled = true;

        // Initialize default limits
        s.limits = DataTypes.BettingLimits({
            maxBetAmount: uint128(Constants.MAX_BET_AMOUNT),
            maxPayoutPerBet: uint128(Constants.MAX_PAYOUT_PER_BET),
            maxRoundPayouts: uint128(Constants.MAX_ROUND_PAYOUTS),
            minBetAmount: uint128(Constants.MIN_BET_AMOUNT)
        });

        // Initialize fee config (Protocol-backed model)
        s.feeConfig = DataTypes.FeeConfig({
            protocolFeeBps: uint16(Constants.PROTOCOL_FEE_BPS),
            seasonPoolFeeBps: uint16(Constants.SEASON_POOL_FEE_BPS),
            cancellationFeeBps: uint16(Constants.CANCELLATION_FEE_BPS)
        });
    }

    // ============ User Functions ============

    /**
     * @notice Place a bet (LBT only)
     * @param amount Bet amount in LBT
     * @param matchIndices Array of match indices (0-9)
     * @param predictions Array of predicted outcomes (1=HOME, 2=AWAY, 3=DRAW)
     * @return betId The ID of the placed bet
     */
    function placeBet(
        uint256 amount,
        uint256[] calldata matchIndices,
        uint8[] calldata predictions
    ) external nonReentrant whenNotPaused returns (uint256 betId) {
        BettingStorage.Layout storage s = BettingStorage.layout();

        // Validate betting enabled
        if (!s.bettingEnabled) revert BettingDisabled();

        // Validate token is set
        if (s.lbtToken == address(0)) revert InvalidToken();

        // Validate amount
        if (amount < s.limits.minBetAmount || amount > s.limits.maxBetAmount) {
            revert InvalidAmount();
        }

        // Validate round is active
        uint256 roundId = s.currentRoundId;
        if (roundId == 0) revert RoundNotActive();

        DataTypes.RoundMetadata storage meta = s.roundMetadata[roundId];
        if (!meta.seeded) revert RoundNotActive();

        // Check betting window (must bet at least 30 min before round ends)
        if (block.timestamp > meta.roundEndTime - Constants.BETTING_CUTOFF) {
            revert BettingWindowClosed();
        }

        // Validate match indices and predictions
        uint8 legCount = uint8(matchIndices.length);
        require(legCount > 0 && legCount <= Constants.MAX_MATCHES_PER_ROUND, "Invalid leg count");
        require(matchIndices.length == predictions.length, "Length mismatch");

        // C-02 FIX: Track used match indices to prevent duplicates
        // Using a bitmap for gas-efficient duplicate detection (max 10 matches = 10 bits)
        uint256 usedMatches = 0;

        for (uint256 i = 0; i < legCount;) {
            if (matchIndices[i] >= Constants.MAX_MATCHES_PER_ROUND) revert InvalidMatchIndex();
            if (predictions[i] < 1 || predictions[i] > 3) revert InvalidPrediction();

            // C-02 FIX: Check for duplicate match index using bitmap
            uint256 matchBit = 1 << matchIndices[i];
            require((usedMatches & matchBit) == 0, "Duplicate match index");
            usedMatches |= matchBit;
            unchecked {
                ++i;
            }
        }

        // Calculate odds-based multiplier by multiplying individual match odds
        uint256 oddsMultiplier = Constants.PRECISION; // Start at 1.0x

        for (uint256 i = 0; i < legCount;) {
            uint256 matchIndex = matchIndices[i];
            uint8 prediction = predictions[i];

            // Get locked odds for this match
            DataTypes.LockedOdds storage odds = s.lockedOdds[roundId][matchIndex];
            require(odds.locked, "Odds not locked");

            // Get the odds for the predicted outcome
            // ⚠️ CRITICAL FIX: Odds are stored as uint64 with 6 decimals (1e6)
            // Must scale to 18 decimals (1e18) for calculations
            uint256 matchOdds;
            if (prediction == 1) {
                matchOdds = uint256(odds.homeOdds) * 1e12; // Scale 1e6 → 1e18
            } else if (prediction == 2) {
                matchOdds = uint256(odds.awayOdds) * 1e12; // Scale 1e6 → 1e18
            } else {
                matchOdds = uint256(odds.drawOdds) * 1e12; // Scale 1e6 → 1e18
            }

            // Multiply odds together: oddsMultiplier = oddsMultiplier * matchOdds / PRECISION
            oddsMultiplier = (oddsMultiplier * matchOdds) / Constants.PRECISION;

            unchecked {
                ++i;
            }
        }

        // Apply parlay bonus on top of odds multiplier
        uint256 parlayBonus = _calculateParlayMultiplier(legCount);
        uint256 finalMultiplier = (oddsMultiplier * parlayBonus) / Constants.PRECISION;

        // Calculate potential payout using final multiplier
        uint256 potentialPayout = (amount * finalMultiplier) / Constants.PRECISION;

        // Check combined pool (protocol reserves + LP reserves) can cover the locked payout
        uint256 totalPool = s.protocolReserves + s.lpReserves;
        require(totalPool >= potentialPayout, "Insufficient pool liquidity");

        // Transfer LBT from user to contract
        IERC20(s.lbtToken).safeTransferFrom(msg.sender, address(this), amount);

        // 1. Add bet amount to protocol reserves (bets always credited to protocol side)
        s.protocolReserves += amount;

        // 2. Lock potential payout — draw from protocol and LP proportionally to their
        //    current share of the combined pool.  The lpFractionAtSeed snapshotted in
        //    seedRound() governs how the pot is returned at sweep time; here we use the
        //    live ratio so each bet fairly draws from whoever has capital available.
        uint256 lpDraw = totalPool > 0 ? (potentialPayout * s.lpReserves) / totalPool : 0;
        s.lpReserves     -= lpDraw;
        s.protocolReserves -= (potentialPayout - lpDraw);
        s.roundPools[roundId].totalLocked += potentialPayout;

        // Create bet
        betId = BettingStorage.getNextBetId();

        s.bets[betId] = DataTypes.Bet({
            bettor: msg.sender,
            token: s.lbtToken, // Always LBT
            amount: uint128(amount),
            potentialPayout: uint128(potentialPayout),
            lockedMultiplier: uint128(finalMultiplier), // Store final multiplier (odds × parlay bonus)
            roundId: uint64(roundId),
            timestamp: uint32(block.timestamp),
            legCount: legCount,
            status: DataTypes.BetStatus.Active
        });

        // Store predictions
        for (uint256 i = 0; i < legCount;) {
            s.betPredictions[betId].predictions.push(DataTypes.Prediction({
                matchIndex: uint8(matchIndices[i]),
                predictedOutcome: predictions[i]
            }));
            unchecked {
                ++i;
            }
        }

        // Update accounting (analytics only)
        DataTypes.RoundAccounting storage acct = s.roundAccounting[roundId];
        acct.totalBetVolume += uint128(amount);

        unchecked {
            acct.totalBets++;
            if (legCount > 1) acct.parlayCount++;
        }

        // Update user tracking
        BettingStorage.addUserBet(msg.sender, betId);
        unchecked {
            s.totalBetsPlaced++;
        }
        s.totalVolumeAllTime += amount;

        emit BetPlaced(betId, msg.sender, roundId, amount, finalMultiplier, legCount);
    }

    /**
     * @notice Cancel an active bet (before round settles)
     * @param betId The bet ID to cancel
     * @return refundAmount Amount refunded after fee
     * @dev M-06 FIX: Cannot cancel after round is settled
     *      H-02 FIX: Update totalBetVolume on cancel
     */
    function cancelBet(uint256 betId) external nonReentrant returns (uint256 refundAmount) {
        BettingStorage.Layout storage s = BettingStorage.layout();
        DataTypes.Bet storage bet = s.bets[betId];

        if (bet.bettor == address(0)) revert BetNotFound();
        if (bet.bettor != msg.sender) revert NotBetOwner();
        if (bet.status != DataTypes.BetStatus.Active) revert BetAlreadySettled();

        // M-06 FIX: Prevent cancellation after round is settled
        DataTypes.RoundMetadata storage meta = s.roundMetadata[bet.roundId];
        require(!meta.settled, "Round already settled");

        // Calculate refund (apply cancellation fee)
        uint256 fee = (bet.amount * s.feeConfig.cancellationFeeBps) / Constants.BPS_PRECISION;
        refundAmount = bet.amount - fee;

        // Update bet status
        bet.status = DataTypes.BetStatus.Cancelled;

        // Update accounting (analytics only)
        DataTypes.RoundAccounting storage acct = s.roundAccounting[bet.roundId];
        acct.totalBetVolume -= uint128(bet.amount);
        unchecked {
            acct.totalBets--;
        }

        // Return locked payout from round pool → back to protocol and LP proportionally.
        // Use the LP fraction snapshotted when this round was seeded so the return
        // mirrors how the funds were originally drawn at bet placement.
        DataTypes.RoundPool storage pool = s.roundPools[bet.roundId];
        pool.totalLocked -= bet.potentialPayout;

        uint256 lpFrac  = s.lpFractionAtSeed[bet.roundId];
        uint256 lpReturn = (uint256(bet.potentialPayout) * lpFrac) / 1e18;
        s.lpReserves       += lpReturn;
        s.protocolReserves += uint256(bet.potentialPayout) - lpReturn;

        // Remove bet amount from protocol reserves (it's being refunded to user)
        s.protocolReserves -= bet.amount;

        // Transfer refund to user
        IERC20(s.lbtToken).safeTransfer(msg.sender, refundAmount);

        // Send fee to treasury (fee stays as protocol revenue)
        if (fee > 0) {
            IERC20(s.lbtToken).safeTransfer(s.protocolTreasury, fee);
        }

        emit BetCancelled(betId, msg.sender, refundAmount);
    }

    /**
     * @notice Claim winnings for a winning bet (supports bounty system)
     * @param betId The bet ID to claim
     * @param minPayout Minimum acceptable payout (slippage protection)
     * @return payout The total claimed amount (for winner, or bounty for claimer)
     * @dev Bounty system: Winners have 24h to claim 100%. After 24h, anyone can claim
     *      and receive 10% bounty while winner gets 90%. Minimum 50 LBT for bounty claims.
     */
    function claimWinnings(
        uint256 betId,
        uint256 minPayout
    ) external nonReentrant returns (uint256 payout) {
        BettingStorage.Layout storage s = BettingStorage.layout();
        DataTypes.Bet storage bet = s.bets[betId];
        DataTypes.RoundMetadata storage meta = s.roundMetadata[bet.roundId];
        DataTypes.RoundAccounting storage acct = s.roundAccounting[bet.roundId];

        if (bet.bettor == address(0)) revert BetNotFound();
        require(meta.settled, "Round not settled");
        require(bet.status == DataTypes.BetStatus.Active, "Already processed");

        // Check if bet won by validating all predictions
        bool won = _checkBetWon(betId);

        if (won) {
            // Calculate total payout once: bet amount * locked multiplier
            uint256 totalPayout = (uint256(bet.amount) * uint256(bet.lockedMultiplier)) / Constants.PRECISION;

            // Determine claim type (direct or bounty)
            bool isBountyClaim = false;
            uint256 claimDeadline = meta.roundEndTime + Constants.CLAIM_DEADLINE;

            if (msg.sender != bet.bettor) {
                // Third-party claim (bounty hunter)
                require(block.timestamp >= claimDeadline, "Claim deadline not passed");
                require(totalPayout >= Constants.MIN_BOUNTY_CLAIM, "Payout below bounty minimum");
                isBountyClaim = true;
            }

            require(totalPayout >= minPayout, "Payout below minimum");

            // Mark as claimed
            bet.status = DataTypes.BetStatus.Claimed;

            // NEW ACCOUNTING: Check if round pool has been swept
            DataTypes.RoundPool storage pool = s.roundPools[bet.roundId];
            bool isLateClaim = pool.swept;
            uint256 actualPayout = totalPayout;

            if (isLateClaim) {
                // Late claim (after sweep): Charge 15% late fee
                uint256 lateFee = (totalPayout * Constants.LATE_CLAIM_FEE_BPS) / Constants.BPS_PRECISION;
                actualPayout = totalPayout - lateFee;

                // Late fees go to protocol treasury
                if (lateFee > 0) {
                    require(s.protocolReserves >= lateFee, "Insufficient protocol reserves for fee");
                    s.protocolReserves -= lateFee;
                    IERC20(s.lbtToken).safeTransfer(s.protocolTreasury, lateFee);
                }
            }

            if (isBountyClaim) {
                // Bounty claim: 10% to claimer, 90% to winner
                uint256 bountyAmount = (actualPayout * Constants.BOUNTY_PERCENTAGE) / Constants.BPS_PRECISION;
                uint256 winnerAmount = actualPayout - bountyAmount;

                if (isLateClaim) {
                    // Pay from protocol reserves (late claim)
                    require(s.protocolReserves >= actualPayout, "Insufficient protocol reserves");
                    s.protocolReserves -= actualPayout;
                } else {
                    // Pay from round pool (on-time claim)
                    require(pool.totalLocked >= actualPayout, "Round pool insufficient");
                    pool.totalClaimed += actualPayout;
                }

                IERC20(s.lbtToken).safeTransfer(msg.sender, bountyAmount);
                IERC20(s.lbtToken).safeTransfer(bet.bettor, winnerAmount);

                payout = bountyAmount; // Return bounty amount to claimer

                emit BountyClaim(betId, msg.sender, bountyAmount, bet.bettor, winnerAmount);
            } else {
                // Direct claim by winner
                if (isLateClaim) {
                    // Pay from protocol reserves (late claim with 15% fee)
                    require(s.protocolReserves >= actualPayout, "Insufficient protocol reserves");
                    s.protocolReserves -= actualPayout;
                } else {
                    // Pay from round pool (on-time claim, 100% payout)
                    require(pool.totalLocked >= actualPayout, "Round pool insufficient");
                    pool.totalClaimed += actualPayout;
                }

                IERC20(s.lbtToken).safeTransfer(bet.bettor, actualPayout);

                payout = actualPayout;

                emit WinningsClaimed(betId, bet.bettor, actualPayout);
            }
        } else {
            // Bet lost - no payout
            bet.status = DataTypes.BetStatus.Lost;
            payout = 0;

            emit BetLost(betId);
        }
    }

    /**
     * @notice Claim multiple bets at once (supports bounty system)
     * @param betIds Array of bet IDs to claim
     * @return totalPayout Total amount claimed (to msg.sender)
     * @dev Bounty system: If claiming after 24h as third party, receives 10% bounty on each winning bet
     * @dev M-02 FIX: Limited to 50 bets per call to prevent gas bombs
     */
    function batchClaim(uint256[] calldata betIds) external nonReentrant returns (uint256 totalPayout) {
        // M-02 FIX: Limit batch size to prevent gas bomb attacks
        require(betIds.length <= 50, "Batch size exceeds limit");

        BettingStorage.Layout storage s = BettingStorage.layout();

        for (uint256 i = 0; i < betIds.length;) {
            uint256 betId = betIds[i];
            DataTypes.Bet storage bet = s.bets[betId];
            DataTypes.RoundMetadata storage meta = s.roundMetadata[bet.roundId];
            DataTypes.RoundAccounting storage acct = s.roundAccounting[bet.roundId];

            if (bet.bettor == address(0)) revert BetNotFound();
            require(meta.settled, "Round not settled");
            require(bet.status == DataTypes.BetStatus.Active, "Already processed");

            // Determine claim type (direct or bounty)
            bool isBountyClaim = false;
            uint256 claimDeadline = meta.roundEndTime + Constants.CLAIM_DEADLINE;

            if (msg.sender != bet.bettor) {
                // Third-party claim (bounty hunter)
                require(block.timestamp >= claimDeadline, "Claim deadline not passed");

                // Calculate total payout first to check minimum
                uint256 betPayout = (uint256(bet.amount) * uint256(bet.lockedMultiplier)) / Constants.PRECISION;
                require(betPayout >= Constants.MIN_BOUNTY_CLAIM, "Payout below bounty minimum");

                isBountyClaim = true;
            }

            // Check if bet won
            bool won = _checkBetWon(betId);

            if (won) {
                // Calculate payout: bet amount * locked multiplier
                uint256 payout = (uint256(bet.amount) * uint256(bet.lockedMultiplier)) / Constants.PRECISION;

                // Mark as claimed
                bet.status = DataTypes.BetStatus.Claimed;

                // NEW ACCOUNTING: Check if round pool has been swept
                DataTypes.RoundPool storage pool = s.roundPools[bet.roundId];
                bool isLateClaim = pool.swept;
                uint256 actualPayout = payout;

                if (isLateClaim) {
                    // Late claim (after sweep): Charge 15% late fee
                    uint256 lateFee = (payout * Constants.LATE_CLAIM_FEE_BPS) / Constants.BPS_PRECISION;
                    actualPayout = payout - lateFee;

                    // Late fees go to protocol treasury
                    if (lateFee > 0) {
                        require(s.protocolReserves >= lateFee, "Insufficient protocol reserves for fee");
                        s.protocolReserves -= lateFee;
                        IERC20(s.lbtToken).safeTransfer(s.protocolTreasury, lateFee);
                    }
                }

                if (isBountyClaim) {
                    // Bounty claim: 10% to claimer, 90% to winner
                    uint256 bountyAmount = (actualPayout * Constants.BOUNTY_PERCENTAGE) / Constants.BPS_PRECISION;
                    uint256 winnerAmount = actualPayout - bountyAmount;

                    if (isLateClaim) {
                        // Pay from protocol reserves (late claim)
                        require(s.protocolReserves >= actualPayout, "Insufficient protocol reserves");
                        s.protocolReserves -= actualPayout;
                    } else {
                        // Pay from round pool (on-time claim)
                        require(pool.totalLocked >= actualPayout, "Round pool insufficient");
                        pool.totalClaimed += actualPayout;
                    }

                    IERC20(s.lbtToken).safeTransfer(msg.sender, bountyAmount);
                    IERC20(s.lbtToken).safeTransfer(bet.bettor, winnerAmount);

                    totalPayout += bountyAmount; // Accumulate bounty for claimer

                    emit BountyClaim(betId, msg.sender, bountyAmount, bet.bettor, winnerAmount);
                } else {
                    // Direct claim by winner
                    if (isLateClaim) {
                        // Pay from protocol reserves (late claim with 15% fee)
                        require(s.protocolReserves >= actualPayout, "Insufficient protocol reserves");
                        s.protocolReserves -= actualPayout;
                    } else {
                        // Pay from round pool (on-time claim, 100% payout)
                        require(pool.totalLocked >= actualPayout, "Round pool insufficient");
                        pool.totalClaimed += actualPayout;
                    }

                    IERC20(s.lbtToken).safeTransfer(bet.bettor, actualPayout);

                    totalPayout += actualPayout;

                    emit WinningsClaimed(betId, bet.bettor, actualPayout);
                }
            } else {
                // Bet lost - no payout
                bet.status = DataTypes.BetStatus.Lost;

                emit BetLost(betId);
            }
            unchecked {
                ++i;
            }
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Seed a round's pools with pseudo-random variation
     * @param roundId The round ID to seed
     */
    function seedRound(uint256 roundId) external {
        BettingStorage.Layout storage s = BettingStorage.layout();

        // Only owner or game engine can seed rounds
        require(
            msg.sender == owner() || msg.sender == s.gameEngine,
            "Not authorized to seed"
        );

        DataTypes.RoundMetadata storage meta = s.roundMetadata[roundId];

        if (meta.seeded) revert RoundAlreadySeeded();

        // Initialize match pools with varied seeds
        for (uint256 i = 0; i < Constants.MAX_MATCHES_PER_ROUND;) {
            (uint256 homeSeed, uint256 awaySeed, uint256 drawSeed) =
                _calculateVariedSeeds(roundId, i);

            s.matchPools[roundId][i] = DataTypes.MatchPool({
                homeWinPool: homeSeed,
                awayWinPool: awaySeed,
                drawPool: drawSeed,
                totalPool: homeSeed + awaySeed + drawSeed,
                homeBetAmount: 0,  // No bets yet, only virtual seeds
                awayBetAmount: 0,
                drawBetAmount: 0
            });
            unchecked {
                ++i;
            }
        }

        meta.seeded = true;
        meta.roundStartTime = uint64(block.timestamp);
        meta.roundEndTime = uint64(block.timestamp + Constants.ROUND_DURATION);

        // Initialize round pool sweep deadline
        // Sweep deadline = roundEndTime + 24h claim window + 6h grace period = 30h total
        s.roundPools[roundId].sweepDeadline = uint64(block.timestamp + Constants.ROUND_DURATION + Constants.CLAIM_DEADLINE + Constants.SWEEP_GRACE_PERIOD);

        // Snapshot LP fraction of combined pool at seed time.
        // This ratio is used at sweepRoundPool() to split unclaimed/losing-bet profits
        // back to LP reserves and protocol reserves proportionally.
        uint256 combinedPool = s.protocolReserves + s.lpReserves;
        s.lpFractionAtSeed[roundId] = combinedPool > 0
            ? (s.lpReserves * 1e18) / combinedPool
            : 0;

        s.currentRoundId = roundId;

        // Lock odds immediately after seeding
        _lockRoundOdds(roundId);

        emit RoundSeeded(roundId);
    }

    /**
     * @notice Settle a round with results
     * @param roundId The round ID to settle
     * @param results Array of match results (1=HOME, 2=AWAY, 3=DRAW per match)
     * @dev Stores results for later claim validation. Actual payouts calculated on claim.
     * @dev Can be called by owner OR gameEngine for auto-settlement
     * @dev H-04 FIX: Validates roundId > 0 to prevent settling non-existent rounds
     */
    function settleRound(
        uint256 roundId,
        uint8[] calldata results
    ) external onlyOwnerOrGameEngine {
        // H-04 FIX: Validate roundId is valid (non-zero)
        require(roundId > 0, "Invalid round ID");

        BettingStorage.Layout storage s = BettingStorage.layout();
        DataTypes.RoundMetadata storage meta = s.roundMetadata[roundId];

        require(meta.seeded, "Round not seeded");
        require(!meta.settled, "Already settled");
        require(results.length == Constants.MAX_MATCHES_PER_ROUND, "Invalid results length");

        // Store match results
        for (uint256 i = 0; i < results.length;) {
            require(results[i] >= 1 && results[i] <= 3, "Invalid result");
            s.matchResults[roundId][i] = results[i];
            unchecked {
                ++i;
            }
        }

        // Mark as settled
        meta.settled = true;

        emit RoundSettled(roundId, 0);
    }

    /**
     * @notice Sweep round pool back to protocol reserves (NEW ACCOUNTING MODEL)
     * @param roundId The round ID to sweep
     * @dev Callable by anyone after 30h deadline (24h claim + 6h grace)
     *      Remaining funds = protocol profit from losing bets + unclaimed winnings
     */
    function sweepRoundPool(uint256 roundId) external nonReentrant {
        BettingStorage.Layout storage s = BettingStorage.layout();
        DataTypes.RoundMetadata storage meta = s.roundMetadata[roundId];
        DataTypes.RoundPool storage pool = s.roundPools[roundId];

        require(meta.settled, "Round not settled");
        require(!pool.swept, "Pool already swept");
        require(block.timestamp >= pool.sweepDeadline, "Sweep deadline not reached");

        // Calculate remaining funds in round pool (protocol profit)
        uint256 remaining = pool.totalLocked - pool.totalClaimed;

        // Mark as swept BEFORE external calls (CEI pattern)
        pool.swept = true;

        if (remaining > 0) {
            // Take 2% season fee from the total remaining before splitting
            uint256 seasonShare = 0;
            uint256 afterFee = remaining;

            if (s.seasonPredictor != address(0)) {
                seasonShare = (remaining * Constants.SEASON_POOL_FEE_BPS) / Constants.BPS_PRECISION;
                afterFee = remaining - seasonShare;
            }

            // Split afterFee between LP reserves and protocol reserves using the
            // fraction snapshotted when this round was seeded.
            uint256 lpFrac      = s.lpFractionAtSeed[roundId];
            uint256 lpProfit    = (afterFee * lpFrac) / 1e18;
            uint256 protocolProfit = afterFee - lpProfit;

            s.lpReserves       += lpProfit;
            s.protocolReserves += protocolProfit;

            // Distribute season share
            if (seasonShare > 0 && s.seasonPredictor != address(0)) {
                // Get current season ID from GameEngine
                (bool success, bytes memory data) = s.gameEngine.staticcall(
                    abi.encodeWithSignature("getCurrentSeason()")
                );
                require(success, "Failed to get season ID");
                uint256 seasonId = abi.decode(data, (uint256));

                IERC20(s.lbtToken).safeTransfer(s.seasonPredictor, seasonShare);

                (success, ) = s.seasonPredictor.call(
                    abi.encodeWithSignature("fundSeasonPool(uint256,uint256)", seasonId, seasonShare)
                );
                require(success, "Failed to fund season pool");
            }

            // Track protocol profit (excluding LP share)
            s.totalProtocolFees += protocolProfit;

            emit RoundPoolSwept(roundId, remaining, protocolProfit, seasonShare);
        } else {
            emit RoundPoolSwept(roundId, 0, 0, 0);
        }
    }

    // ============ Configuration ============

    /**
     * @notice Set LBT token address (Protocol-backed model)
     * @param _lbtToken LBT token address
     */
    function setLBTToken(address _lbtToken) external onlyOwner {
        require(_lbtToken != address(0), "Invalid address");
        BettingStorage.Layout storage s = BettingStorage.layout();
        s.lbtToken = _lbtToken;
        emit LBTTokenSet(_lbtToken);
    }

    /**
     * @notice Set swap router address
     * @param _swapRouter SwapRouter address
     */
    function setSwapRouter(address _swapRouter) external onlyOwner {
        require(_swapRouter != address(0), "Invalid address");
        BettingStorage.Layout storage s = BettingStorage.layout();
        address oldRouter = s.swapRouter;
        s.swapRouter = _swapRouter;
        emit SwapRouterUpdated(oldRouter, _swapRouter);
    }

    /**
     * @notice Update game engine address
     * @param newEngine New game engine address
     */
    function setGameEngine(address newEngine) external onlyOwner {
        require(newEngine != address(0), "Invalid address");
        BettingStorage.Layout storage s = BettingStorage.layout();
        address oldEngine = s.gameEngine;
        s.gameEngine = newEngine;
        emit GameEngineUpdated(oldEngine, newEngine);
    }

    /**
     * @notice Update treasury address
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid address");
        BettingStorage.Layout storage s = BettingStorage.layout();
        address oldTreasury = s.protocolTreasury;
        s.protocolTreasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Set season predictor contract address
     * @param _seasonPredictor Season predictor address
     */
    function setSeasonPredictor(address _seasonPredictor) external onlyOwner {
        require(_seasonPredictor != address(0), "Invalid address");
        BettingStorage.layout().seasonPredictor = _seasonPredictor;
        emit SeasonPredictorUpdated(_seasonPredictor);
    }

    /**
     * @notice Set betting enabled/disabled
     * @param enabled New enabled state
     */
    function setBettingEnabled(bool enabled) external onlyOwner {
        BettingStorage.layout().bettingEnabled = enabled;
        emit BettingEnabledChanged(enabled);
    }

    /**
     * @notice Update betting limits
     * @param limits New limits configuration
     * @dev M-05 FIX: Emits LimitsUpdated event
     * @dev L-08 FIX: Added minimum value validation
     */
    function updateLimits(DataTypes.BettingLimits calldata limits) external onlyOwner {
        // L-08 FIX: Validate limits make sense
        require(limits.minBetAmount > 0, "Min bet cannot be zero");
        require(limits.maxBetAmount >= limits.minBetAmount, "Max bet must be >= min bet");
        require(limits.maxPayoutPerBet > 0, "Max payout cannot be zero");
        require(limits.maxRoundPayouts >= limits.maxPayoutPerBet, "Round max must be >= bet max");

        BettingStorage.layout().limits = limits;
        emit LimitsUpdated(
            limits.maxBetAmount,
            limits.maxPayoutPerBet,
            limits.maxRoundPayouts,
            limits.minBetAmount
        );
    }

    /**
     * @notice Update fee configuration
     * @param config New fee configuration
     * @dev M-05 FIX: Emits FeeConfigUpdated event
     * @dev L-08 FIX: Added fee validation
     */
    function updateFeeConfig(DataTypes.FeeConfig calldata config) external onlyOwner {
        // L-08 FIX: Validate fees don't exceed 100% and total makes sense
        require(config.protocolFeeBps + config.seasonPoolFeeBps <= Constants.BPS_PRECISION, "Total fees exceed 100%");
        require(config.cancellationFeeBps <= 5000, "Cancellation fee too high"); // Max 50%

        BettingStorage.layout().feeConfig = config;
        emit FeeConfigUpdated(
            config.protocolFeeBps,
            config.seasonPoolFeeBps,
            config.cancellationFeeBps
        );
    }

    // ============ Protocol Liquidity Management ============

    event ProtocolDeposit(address indexed depositor, uint256 amount);
    event ProtocolWithdraw(address indexed recipient, uint256 amount);

    /**
     * @notice Deposit LBT tokens into protocol reserves
     * @param amount Amount of LBT to deposit
     * @dev Only owner can deposit to grow protocol reserves
     */
    function depositReserves(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be > 0");
        BettingStorage.Layout storage s = BettingStorage.layout();
        require(s.lbtToken != address(0), "LBT token not set");

        // Transfer tokens to contract
        IERC20(s.lbtToken).safeTransferFrom(msg.sender, address(this), amount);

        // NEW ACCOUNTING: Add to protocol reserves
        s.protocolReserves += amount;

        emit ProtocolDeposit(msg.sender, amount);
    }

    /**
     * @notice Withdraw excess LBT tokens from protocol reserves
     * @param amount Amount of LBT to withdraw
     * @param recipient Address to receive the tokens
     * @dev Can only withdraw from available protocol reserves (not locked in round pools)
     */
    function withdrawReserves(uint256 amount, address recipient) external onlyOwner {
        require(amount > 0, "Amount must be > 0");
        require(recipient != address(0), "Invalid recipient");

        BettingStorage.Layout storage s = BettingStorage.layout();
        require(s.lbtToken != address(0), "LBT token not set");

        // NEW ACCOUNTING: Can only withdraw from protocol reserves
        // Round pools are already isolated and locked
        require(amount <= s.protocolReserves, "Insufficient available reserves");

        // Deduct from protocol reserves
        s.protocolReserves -= amount;

        // Transfer tokens
        IERC20(s.lbtToken).safeTransfer(recipient, amount);

        emit ProtocolWithdraw(recipient, amount);
    }

    /**
     * @notice Get available reserves (not locked for active bets)
     * @return available Protocol reserves (not locked to any round)
     * @return lpFree    LP reserves (free, not locked to any round)
     * @return locked    Amount locked in the current round pool
     * @return total     Total contract LBT balance
     */
    function getAvailableReserves() external view returns (
        uint256 available,
        uint256 lpFree,
        uint256 locked,
        uint256 total
    ) {
        BettingStorage.Layout storage s = BettingStorage.layout();

        available = s.protocolReserves;
        lpFree    = s.lpReserves;
        total     = IERC20(s.lbtToken).balanceOf(address(this));

        if (s.currentRoundId > 0) {
            DataTypes.RoundPool storage pool = s.roundPools[s.currentRoundId];
            if (!pool.swept) {
                locked = pool.totalLocked - pool.totalClaimed;
            }
        }
    }

    // ============ LP System (v2) ============

    event LiquidityDeposited(
        address indexed lp,
        uint256 amount,
        uint256 shares,
        uint8   lockTierIndex,
        uint64  lockExpiry
    );
    event LiquidityWithdrawn(
        address indexed lp,
        uint256 depositIndex,
        uint256 amount,
        uint256 sharesBurned
    );
    event LiquidityEarlyExit(
        address indexed lp,
        uint256 depositIndex,
        uint256 amountOut,
        uint256 penaltyKept   // stays in LP pool, benefits remaining LPs
    );

    /**
     * @notice Deposit LBT as LP liquidity and receive time-locked shares
     * @param amount         LBT amount to deposit (>= LP_MIN_DEPOSIT)
     * @param lockTierIndex  0=1d | 1=3d | 2=7d | 3=14d | 4=30d
     * @dev  Longer lock → higher share multiplier → bigger pro-rata claim on pool profits.
     *       Share price = lpReserves / totalLPShares.  LP effectively opens a "perp long"
     *       on the house edge: profitable when bettors lose, risky when they win.
     */
    function depositLiquidity(
        uint256 amount,
        uint8   lockTierIndex
    ) external nonReentrant whenNotPaused {
        require(amount >= Constants.LP_MIN_DEPOSIT, "Below LP minimum deposit");
        require(lockTierIndex <= 4, "Invalid lock tier (0-4)");

        BettingStorage.Layout storage s = BettingStorage.layout();
        require(s.lbtToken != address(0), "LBT token not set");

        IERC20(s.lbtToken).safeTransferFrom(msg.sender, address(this), amount);

        uint256 multiplierBps = _lpLockMultiplier(lockTierIndex);
        uint256 lockDuration  = _lpLockDuration(lockTierIndex);
        uint256 sharesToMint;

        if (s.totalLPShares == 0) {
            // Bootstrap: 1 LBT = 1 share at multiplier, minus permanently locked minimum
            // (standard Uniswap v2 dead-share pattern prevents price manipulation)
            sharesToMint = (amount * multiplierBps / Constants.BPS_PRECISION) - Constants.MINIMUM_LP_SHARES;
            s.totalLPShares += Constants.MINIMUM_LP_SHARES; // burned forever
        } else {
            // Proportional: sharesToMint = amount * totalShares * multiplier / (lpReserves * BPS)
            sharesToMint = (amount * s.totalLPShares * multiplierBps)
                           / (s.lpReserves * Constants.BPS_PRECISION);
        }

        require(sharesToMint > 0, "Zero shares minted");

        uint64 lockExpiry = uint64(block.timestamp + lockDuration);

        s.lpDeposits[msg.sender].push(DataTypes.LPDeposit({
            shares:        uint128(sharesToMint),
            amount:        uint128(amount),
            depositTime:   uint64(block.timestamp),
            lockExpiry:    lockExpiry,
            lockTierIndex: lockTierIndex,
            active:        true
        }));

        s.totalLPShares += sharesToMint;
        s.lpReserves    += amount;

        emit LiquidityDeposited(msg.sender, amount, sharesToMint, lockTierIndex, lockExpiry);
    }

    /**
     * @notice Withdraw a fully-unlocked LP deposit (no penalty)
     * @param depositIndex  Index in msg.sender's lpDeposits array
     * @dev  Withdrawable amount = shares * lpReserves / totalLPShares.
     *       If pool grew (protocol profitable), LP receives more than deposited.
     *       If pool shrank (bettors won), LP receives less.
     */
    function withdrawLiquidity(uint256 depositIndex) external nonReentrant {
        BettingStorage.Layout storage s = BettingStorage.layout();
        DataTypes.LPDeposit[] storage deposits = s.lpDeposits[msg.sender];

        require(depositIndex < deposits.length, "Invalid deposit index");
        DataTypes.LPDeposit storage dep = deposits[depositIndex];
        require(dep.active, "Deposit already withdrawn");
        require(block.timestamp >= dep.lockExpiry, "Lock period not expired");

        uint256 withdrawAmount = _lpShareValue(dep.shares, s);
        require(withdrawAmount <= s.lpReserves, "Insufficient LP reserves");

        dep.active = false;
        s.totalLPShares -= dep.shares;
        s.lpReserves    -= withdrawAmount;

        IERC20(s.lbtToken).safeTransfer(msg.sender, withdrawAmount);

        emit LiquidityWithdrawn(msg.sender, depositIndex, withdrawAmount, dep.shares);
    }

    /**
     * @notice Exit an LP deposit before its lock expires (10% penalty)
     * @param depositIndex  Index in msg.sender's lpDeposits array
     * @dev  10% of the current share value is kept in the LP pool, immediately
     *       increasing the share price for all remaining LPs.
     *       Use withdrawLiquidity() after lockExpiry for a penalty-free exit.
     */
    function earlyExitLiquidity(uint256 depositIndex) external nonReentrant {
        BettingStorage.Layout storage s = BettingStorage.layout();
        DataTypes.LPDeposit[] storage deposits = s.lpDeposits[msg.sender];

        require(depositIndex < deposits.length, "Invalid deposit index");
        DataTypes.LPDeposit storage dep = deposits[depositIndex];
        require(dep.active, "Deposit already withdrawn");
        require(block.timestamp < dep.lockExpiry, "Lock expired — use withdrawLiquidity");

        uint256 fullAmount = _lpShareValue(dep.shares, s);
        require(fullAmount <= s.lpReserves, "Insufficient LP reserves");

        uint256 penalty    = (fullAmount * Constants.LP_EARLY_EXIT_FEE_BPS) / Constants.BPS_PRECISION;
        uint256 amountOut  = fullAmount - penalty;

        // Burn the shares and remove only the net payout from lpReserves.
        // The penalty (fullAmount - amountOut) stays in the pool, boosting share price
        // for remaining LPs — equivalent to a liquidation penalty in a perp market.
        dep.active = false;
        s.totalLPShares -= dep.shares;
        s.lpReserves    -= amountOut; // penalty remains in lpReserves

        IERC20(s.lbtToken).safeTransfer(msg.sender, amountOut);

        emit LiquidityEarlyExit(msg.sender, depositIndex, amountOut, penalty);
    }

    // ============ LP View Functions ============

    /**
     * @notice Current LP share price: how much 1 share is worth in LBT (1e18 scale)
     */
    function getLPSharePrice() external view returns (uint256) {
        BettingStorage.Layout storage s = BettingStorage.layout();
        if (s.totalLPShares == 0) return 1e18;
        return (s.lpReserves * 1e18) / s.totalLPShares;
    }

    /**
     * @notice All LP deposit positions for an address (active and inactive)
     */
    function getLPDeposits(address lp) external view returns (DataTypes.LPDeposit[] memory) {
        return BettingStorage.layout().lpDeposits[lp];
    }

    /**
     * @notice Current LBT value and total shares of all active deposits for an LP
     */
    function getLPValue(address lp) external view returns (uint256 totalValue, uint256 totalShares) {
        BettingStorage.Layout storage s = BettingStorage.layout();
        DataTypes.LPDeposit[] storage deposits = s.lpDeposits[lp];
        for (uint256 i = 0; i < deposits.length; i++) {
            if (deposits[i].active) {
                totalShares += deposits[i].shares;
            }
        }
        if (s.totalLPShares > 0 && totalShares > 0) {
            totalValue = (totalShares * s.lpReserves) / s.totalLPShares;
        }
    }

    /**
     * @notice Free LP reserves (not locked in any active round pool)
     */
    function getLPReserves() external view returns (uint256) {
        return BettingStorage.layout().lpReserves;
    }

    /**
     * @notice Total LP shares outstanding
     */
    function getTotalLPShares() external view returns (uint256) {
        return BettingStorage.layout().totalLPShares;
    }

    /**
     * @notice LP fraction snapshotted for a round (1e18 scale)
     */
    function getLPFractionAtSeed(uint256 roundId) external view returns (uint256) {
        return BettingStorage.layout().lpFractionAtSeed[roundId];
    }

    // ============ LP Internal Helpers ============

    function _lpShareValue(
        uint256 shares,
        BettingStorage.Layout storage s
    ) internal view returns (uint256) {
        if (s.totalLPShares == 0) return 0;
        return (shares * s.lpReserves) / s.totalLPShares;
    }

    function _lpLockMultiplier(uint8 tierIndex) internal pure returns (uint256) {
        if (tierIndex == 0) return Constants.LP_MULT_1D;
        if (tierIndex == 1) return Constants.LP_MULT_3D;
        if (tierIndex == 2) return Constants.LP_MULT_7D;
        if (tierIndex == 3) return Constants.LP_MULT_14D;
        return Constants.LP_MULT_30D;
    }

    function _lpLockDuration(uint8 tierIndex) internal pure returns (uint256) {
        if (tierIndex == 0) return Constants.LP_LOCK_1D;
        if (tierIndex == 1) return Constants.LP_LOCK_3D;
        if (tierIndex == 2) return Constants.LP_LOCK_7D;
        if (tierIndex == 3) return Constants.LP_LOCK_14D;
        return Constants.LP_LOCK_30D;
    }

    // ============ Emergency ============

    /**
     * @notice Pause the contract
     */
    function pause() external onlyOwner {
        _pause();
        BettingStorage.layout().paused = true;
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
        BettingStorage.layout().paused = false;
    }

    // ============ View Functions ============

    /**
     * @notice Get bet information
     * @param betId The bet ID
     * @return bet Bet struct
     * @return predictions Bet predictions
     */
    function getBet(uint256 betId) external view returns (
        DataTypes.Bet memory bet,
        DataTypes.BetPredictions memory predictions
    ) {
        BettingStorage.Layout storage s = BettingStorage.layout();
        return (s.bets[betId], s.betPredictions[betId]);
    }

    /**
     * @notice Get current round ID
     * @return roundId Current round
     */
    function getCurrentRound() external view returns (uint256) {
        return BettingStorage.layout().currentRoundId;
    }

    /**
     * @notice Get LBT token address
     * @return token LBT token address
     */
    function getLBTToken() external view returns (address) {
        return BettingStorage.layout().lbtToken;
    }

    /**
     * @notice Get protocol reserves balance (NEW ACCOUNTING)
     * @return reserves Protocol's available LBT reserves (not locked in round pools)
     */
    function getProtocolReserves() external view returns (uint256 reserves) {
        return BettingStorage.layout().protocolReserves;
    }

    /**
     * @notice Get round pool information (NEW ACCOUNTING)
     * @param roundId Round ID
     * @return totalLocked Total funds locked in this round's pool
     * @return totalClaimed Total already claimed from pool
     * @return remaining Funds remaining in pool (unclaimed)
     * @return sweepDeadline When pool can be swept back to protocol
     * @return swept Whether pool has been swept
     */
    function getRoundPool(uint256 roundId) external view returns (
        uint256 totalLocked,
        uint256 totalClaimed,
        uint256 remaining,
        uint256 sweepDeadline,
        bool swept
    ) {
        DataTypes.RoundPool storage pool = BettingStorage.layout().roundPools[roundId];
        totalLocked = pool.totalLocked;
        totalClaimed = pool.totalClaimed;
        remaining = totalLocked > totalClaimed ? totalLocked - totalClaimed : 0;
        sweepDeadline = pool.sweepDeadline;
        swept = pool.swept;
    }

    /**
     * @notice Get user's bet IDs
     * @param user User address
     * @return betIds Array of bet IDs
     */
    function getUserBets(address user) external view returns (uint256[] memory) {
        return BettingStorage.layout().userBets[user];
    }

    /**
     * @notice Get match pool for a round
     * @param roundId Round ID
     * @param matchIndex Match index
     * @return pool Match pool data
     */
    function getMatchPool(
        uint256 roundId,
        uint256 matchIndex
    ) external view returns (DataTypes.MatchPool memory) {
        return BettingStorage.layout().matchPools[roundId][matchIndex];
    }

    /**
     * @notice Get round accounting
     * @param roundId Round ID
     * @return accounting Round accounting data
     */
    function getRoundAccounting(
        uint256 roundId
    ) external view returns (DataTypes.RoundAccounting memory) {
        return BettingStorage.layout().roundAccounting[roundId];
    }

    /**
     * @notice Get round metadata
     * @param roundId Round ID
     * @return metadata Round metadata
     */
    function getRoundMetadata(
        uint256 roundId
    ) external view returns (DataTypes.RoundMetadata memory) {
        return BettingStorage.layout().roundMetadata[roundId];
    }

    /**
     * @notice Get locked odds for a match (fixed at seeding time)
     * @param roundId Round ID
     * @param matchIndex Match index (0-9)
     * @return homeOdds Home win odds (18 decimals)
     * @return awayOdds Away win odds (18 decimals)
     * @return drawOdds Draw odds (18 decimals)
     * @return locked Whether odds are locked
     */
    function getLockedOdds(
        uint256 roundId,
        uint256 matchIndex
    ) external view returns (
        uint256 homeOdds,
        uint256 awayOdds,
        uint256 drawOdds,
        bool locked
    ) {
        BettingStorage.Layout storage s = BettingStorage.layout();
        DataTypes.LockedOdds storage odds = s.lockedOdds[roundId][matchIndex];

        // Scale back up to 1e18 precision
        homeOdds = uint256(odds.homeOdds) * 1e12;
        awayOdds = uint256(odds.awayOdds) * 1e12;
        drawOdds = uint256(odds.drawOdds) * 1e12;
        locked = odds.locked;
    }

    /**
     * @notice Check if a bet is eligible for bounty claiming
     * @param betId Bet ID to check
     * @return eligible Whether bet can be claimed with bounty
     * @return timeUntilBounty Seconds until bounty is available (0 if available now)
     * @return bountyAmount Potential bounty amount (10% of payout)
     * @return winnerAmount Amount winner will receive (90% of payout)
     */
    function canClaimWithBounty(uint256 betId) external view returns (
        bool eligible,
        uint256 timeUntilBounty,
        uint256 bountyAmount,
        uint256 winnerAmount
    ) {
        BettingStorage.Layout storage s = BettingStorage.layout();
        DataTypes.Bet storage bet = s.bets[betId];
        DataTypes.RoundMetadata storage meta = s.roundMetadata[bet.roundId];

        // Check basic eligibility
        if (bet.bettor == address(0) || bet.status != DataTypes.BetStatus.Active || !meta.settled) {
            return (false, 0, 0, 0);
        }

        // Check if bet won
        bool won = _checkBetWon(betId);
        if (!won) {
            return (false, 0, 0, 0);
        }

        // Calculate payout
        uint256 totalPayout = (uint256(bet.amount) * uint256(bet.lockedMultiplier)) / Constants.PRECISION;

        // Check minimum for bounty
        if (totalPayout < Constants.MIN_BOUNTY_CLAIM) {
            return (false, 0, 0, 0);
        }

        // Check deadline
        uint256 claimDeadline = meta.roundEndTime + Constants.CLAIM_DEADLINE;

        if (block.timestamp >= claimDeadline) {
            // Bounty available now
            bountyAmount = (totalPayout * Constants.BOUNTY_PERCENTAGE) / Constants.BPS_PRECISION;
            winnerAmount = totalPayout - bountyAmount;
            return (true, 0, bountyAmount, winnerAmount);
        } else {
            // Not yet available
            timeUntilBounty = claimDeadline - block.timestamp;
            bountyAmount = (totalPayout * Constants.BOUNTY_PERCENTAGE) / Constants.BPS_PRECISION;
            winnerAmount = totalPayout - bountyAmount;
            return (false, timeUntilBounty, bountyAmount, winnerAmount);
        }
    }

    /**
     * @notice Get comprehensive claim status for a bet
     * @param betId Bet ID to check
     * @return isWon Whether the bet won
     * @return isClaimed Whether already claimed
     * @return totalPayout Total payout amount
     * @return claimDeadline Timestamp when bounty becomes available
     * @return canBountyClaim Whether bounty claiming is available now
     */
    function getBetClaimStatus(uint256 betId) external view returns (
        bool isWon,
        bool isClaimed,
        uint256 totalPayout,
        uint256 claimDeadline,
        bool canBountyClaim
    ) {
        BettingStorage.Layout storage s = BettingStorage.layout();
        DataTypes.Bet storage bet = s.bets[betId];
        DataTypes.RoundMetadata storage meta = s.roundMetadata[bet.roundId];

        if (bet.bettor == address(0)) {
            return (false, false, 0, 0, false);
        }

        isClaimed = (bet.status == DataTypes.BetStatus.Claimed);

        if (meta.settled && bet.status == DataTypes.BetStatus.Active) {
            isWon = _checkBetWon(betId);
            if (isWon) {
                totalPayout = (uint256(bet.amount) * uint256(bet.lockedMultiplier)) / Constants.PRECISION;
                claimDeadline = meta.roundEndTime + Constants.CLAIM_DEADLINE;
                canBountyClaim = (block.timestamp >= claimDeadline) && (totalPayout >= Constants.MIN_BOUNTY_CLAIM);
            }
        }

        return (isWon, isClaimed, totalPayout, claimDeadline, canBountyClaim);
    }

    /**
     * @notice Get all unclaimed winning bets eligible for bounty claiming in a round
     * @param roundId Round ID to check
     * @param maxResults Maximum number of results to return
     * @return betIds Array of eligible bet IDs
     * @return bounties Array of bounty amounts for each bet
     * @dev Useful for bounty hunters to find profitable claims
     */
    function getClaimableWithBounty(
        uint256 roundId,
        uint256 maxResults
    ) external view returns (
        uint256[] memory betIds,
        uint256[] memory bounties
    ) {
        BettingStorage.Layout storage s = BettingStorage.layout();
        DataTypes.RoundMetadata storage meta = s.roundMetadata[roundId];

        if (!meta.settled) {
            return (new uint256[](0), new uint256[](0));
        }

        uint256 claimDeadline = meta.roundEndTime + Constants.CLAIM_DEADLINE;
        if (block.timestamp < claimDeadline) {
            return (new uint256[](0), new uint256[](0));
        }

        // First pass: count eligible bets (this is expensive, but necessary for view function)
        uint256 totalBets = s.totalBetsPlaced;
        uint256 count = 0;

        // Pre-allocate with max size (will trim later)
        uint256[] memory tempBetIds = new uint256[](maxResults);
        uint256[] memory tempBounties = new uint256[](maxResults);

        for (uint256 betId = 1; betId <= totalBets && count < maxResults;) {
            DataTypes.Bet storage bet = s.bets[betId];

            // Check if bet is for this round
            if (bet.roundId != roundId) {
                unchecked { ++betId; }
                continue;
            }

            // Check if still active (not claimed or processed)
            if (bet.status != DataTypes.BetStatus.Active) {
                unchecked { ++betId; }
                continue;
            }

            // Check if bet won
            if (!_checkBetWon(betId)) {
                unchecked { ++betId; }
                continue;
            }

            // Calculate payout
            uint256 totalPayout = (uint256(bet.amount) * uint256(bet.lockedMultiplier)) / Constants.PRECISION;

            // Check minimum
            if (totalPayout < Constants.MIN_BOUNTY_CLAIM) {
                unchecked { ++betId; }
                continue;
            }

            // Add to results
            tempBetIds[count] = betId;
            tempBounties[count] = (totalPayout * Constants.BOUNTY_PERCENTAGE) / Constants.BPS_PRECISION;
            unchecked {
                ++count;
                ++betId;
            }
        }

        // Trim arrays to actual size
        betIds = new uint256[](count);
        bounties = new uint256[](count);
        for (uint256 i = 0; i < count;) {
            betIds[i] = tempBetIds[i];
            bounties[i] = tempBounties[i];
            unchecked {
                ++i;
            }
        }

        return (betIds, bounties);
    }

    /**
     * @notice Get current odds for a match prediction (DEPRECATED: use getLockedOdds)
     * @param roundId Round ID
     * @param matchIndex Match index (0-9)
     * @param prediction Predicted outcome (1=HOME, 2=AWAY, 3=DRAW)
     * @return odds Current odds (18 decimals), compressed to [1.25x - 2.05x] range
     * @dev This function returns locked odds if available, otherwise calculates from pool state
     */
    function getOdds(
        uint256 roundId,
        uint256 matchIndex,
        uint8 prediction
    ) external view returns (uint256 odds) {
        BettingStorage.Layout storage s = BettingStorage.layout();
        DataTypes.LockedOdds storage lockedOdds = s.lockedOdds[roundId][matchIndex];

        // If odds are locked, return locked odds (preferred)
        if (lockedOdds.locked) {
            if (prediction == 1) {
                odds = uint256(lockedOdds.homeOdds) * 1e12;
            } else if (prediction == 2) {
                odds = uint256(lockedOdds.awayOdds) * 1e12;
            } else if (prediction == 3) {
                odds = uint256(lockedOdds.drawOdds) * 1e12;
            } else {
                revert("Invalid prediction");
            }
            return odds;
        }

        // Fallback: calculate from current pool state (for unseeded rounds)
        DataTypes.MatchPool storage pool = s.matchPools[roundId][matchIndex];

        uint256 outcomePool;
        if (prediction == 1) {
            outcomePool = pool.homeWinPool;
        } else if (prediction == 2) {
            outcomePool = pool.awayWinPool;
        } else if (prediction == 3) {
            outcomePool = pool.drawPool;
        } else {
            revert("Invalid prediction");
        }

        // Calculate raw parimutuel odds: totalPool / outcomePool
        uint256 rawOdds;
        if (outcomePool > 0 && pool.totalPool > 0) {
            rawOdds = (pool.totalPool * Constants.PRECISION) / outcomePool;
        } else {
            rawOdds = Constants.PRECISION;
        }

        // Compress odds to [1.25x - 2.05x] range
        odds = _compressOdds(rawOdds);
    }

    // ============ Internal Helpers ============

    /**
     * @notice Calculate parlay multiplier for a bet
     * @param legCount Number of legs in the parlay
     * @return multiplier Parlay multiplier (18 decimals) with compressed odds
     * @dev L-01 FIX: Removed unused roundId and predictions parameters
     */
    function _calculateParlayMultiplier(
        uint256 legCount
    ) internal pure returns (uint256 multiplier) {
        // Parlay multiplier is a simple bonus based on number of legs
        // NOT the product of individual odds (that's calculated separately in allocation logic)

        if (legCount == 1) {
            multiplier = Constants.PRECISION; // 1.0x (no bonus)
        } else if (legCount == 2) {
            multiplier = 105e16; // 1.05x (5% bonus)
        } else if (legCount == 3) {
            multiplier = 110e16; // 1.10x (10% bonus)
        } else if (legCount == 4) {
            multiplier = 115e16; // 1.15x (15% bonus)
        } else if (legCount == 5) {
            multiplier = 120e16; // 1.20x (20% bonus)
        } else {
            // 6+ legs: 1.25x (25% bonus)
            multiplier = 125e16;
        }
    }

    /**
     * @notice Calculate varied seed amounts per match
     * @param roundId Round ID
     * @param matchIndex Match index
     * @return homeSeed Home win pool seed
     * @return awaySeed Away win pool seed
     * @return drawSeed Draw pool seed
     */
    function _calculateVariedSeeds(
        uint256 roundId,
        uint256 matchIndex
    ) internal view returns (uint256 homeSeed, uint256 awaySeed, uint256 drawSeed) {
        // Generate entropy
        uint256 entropy = uint256(keccak256(abi.encodePacked(
            roundId,
            matchIndex,
            block.timestamp,
            block.prevrandao
        )));

        uint256 totalSeed = Constants.SEED_PER_MATCH;
        uint256 homeStrength = (entropy >> 0) % 100;
        uint256 awayStrength = (entropy >> 8) % 100;
        uint256 diff = homeStrength > awayStrength
            ? homeStrength - awayStrength
            : awayStrength - homeStrength;

        uint256 favoriteAlloc;
        uint256 underdogAlloc;
        uint256 drawAlloc;

        // Tiered allocation based on strength difference
        // Capped at 54% max to ensure minimum odds of 1.85x (100/54 = 1.85x)
        if (diff > 50) {
            favoriteAlloc = 54;  // 1.85x minimum odds
            underdogAlloc = 30;
            drawAlloc = 16;
        } else if (diff > 30) {
            favoriteAlloc = 52;  // 1.92x minimum odds
            underdogAlloc = 32;
            drawAlloc = 16;
        } else if (diff > 15) {
            favoriteAlloc = 50;  // 2.00x minimum odds
            underdogAlloc = 34;
            drawAlloc = 16;
        } else {
            favoriteAlloc = 46;  // 2.17x minimum odds
            underdogAlloc = 42;
            drawAlloc = 12;
        }

        if (homeStrength > awayStrength) {
            homeSeed = (totalSeed * favoriteAlloc) / 100;
            awaySeed = (totalSeed * underdogAlloc) / 100;
        } else {
            homeSeed = (totalSeed * underdogAlloc) / 100;
            awaySeed = (totalSeed * favoriteAlloc) / 100;
        }
        drawSeed = (totalSeed * drawAlloc) / 100;
    }

    /**
     * @notice Check if a bet won by comparing all predictions to match results
     * @param betId Bet ID to check
     * @return won Whether all predictions matched the results
     */
    function _checkBetWon(uint256 betId) internal view returns (bool won) {
        BettingStorage.Layout storage s = BettingStorage.layout();
        DataTypes.Bet storage bet = s.bets[betId];
        DataTypes.BetPredictions storage betPreds = s.betPredictions[betId];

        // All predictions must match for bet to win
        won = true;
        for (uint256 i = 0; i < betPreds.predictions.length;) {
            DataTypes.Prediction memory pred = betPreds.predictions[i];
            uint8 actualResult = s.matchResults[bet.roundId][pred.matchIndex];

            // If prediction doesn't match result, bet loses
            if (pred.predictedOutcome != actualResult) {
                won = false;
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Compress raw parimutuel odds to target range [1.25x - 2.05x]
     * @param rawOdds Raw odds from pool calculation (18 decimals)
     * @return compressed Compressed odds in [1.25x - 2.05x] range
     * @dev Linear compression: maps [1.0x - 10.0x] raw → [1.25x - 2.05x] compressed
     *      Formula: compressed = 1.25 + (raw - 1.0) * (2.05 - 1.25) / (10.0 - 1.0)
     *               compressed = 1.25 + (raw - 1.0) * 0.80 / 9.0
     */
    function _compressOdds(uint256 rawOdds) internal pure returns (uint256 compressed) {
        // Constants for compression (18 decimals)
        uint256 minTarget = 125e16;  // 1.25x
        uint256 maxTarget = 205e16;  // 2.05x
        uint256 minRaw = 1e18;       // 1.0x
        uint256 maxRaw = 10e18;      // 10.0x

        // Clamp raw odds to expected range
        if (rawOdds < minRaw) rawOdds = minRaw;
        if (rawOdds > maxRaw) rawOdds = maxRaw;

        // Linear interpolation: compressed = minTarget + (rawOdds - minRaw) * (maxTarget - minTarget) / (maxRaw - minRaw)
        uint256 range = maxTarget - minTarget;        // 0.80e18
        uint256 rawRange = maxRaw - minRaw;           // 9.0e18
        uint256 offset = rawOdds - minRaw;            // (raw - 1.0)

        compressed = minTarget + (offset * range) / rawRange;
    }

    /**
     * @notice Lock odds for all matches in a round based on seed ratios
     * @param roundId The round ID to lock odds for
     * @dev Called automatically after seeding - odds NEVER change after this
     * @dev L-07 FIX: Added division by zero protection
     */
    function _lockRoundOdds(uint256 roundId) internal {
        BettingStorage.Layout storage s = BettingStorage.layout();

        for (uint256 i = 0; i < Constants.MAX_MATCHES_PER_ROUND;) {
            DataTypes.MatchPool storage pool = s.matchPools[roundId][i];

            require(pool.totalPool > 0, "Pool not initialized");
            // L-07 FIX: Ensure individual pools are non-zero to prevent division by zero
            require(pool.homeWinPool > 0 && pool.awayWinPool > 0 && pool.drawPool > 0, "Invalid pool seeds");

            // Calculate raw parimutuel odds from initial seed ratios
            uint256 rawHomeOdds = (pool.totalPool * Constants.PRECISION) / pool.homeWinPool;
            uint256 rawAwayOdds = (pool.totalPool * Constants.PRECISION) / pool.awayWinPool;
            uint256 rawDrawOdds = (pool.totalPool * Constants.PRECISION) / pool.drawPool;

            // Compress and lock - these odds will NEVER change
            s.lockedOdds[roundId][i] = DataTypes.LockedOdds({
                homeOdds: uint64(_compressOdds(rawHomeOdds) / 1e12), // Scale down to fit uint64 (1e6 precision)
                awayOdds: uint64(_compressOdds(rawAwayOdds) / 1e12),
                drawOdds: uint64(_compressOdds(rawDrawOdds) / 1e12),
                locked: true
            });
            unchecked {
                ++i;
            }
        }

        emit OddsLocked(roundId);
    }

}
