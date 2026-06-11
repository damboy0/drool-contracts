// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICumulativeRateOracle} from "./interfaces/ICumulativeRateOracle.sol";
import {MarginMath} from "./libraries/MarginMath.sol";

contract SwapSingleton is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ─── Market Config ─────────────────────────────────────────────────────
    struct Market {
        address underlyingAsset;
        uint256 termEnd;
        uint256 leverageMultiplier;
        address oracle;
        uint256 liquidationThresholdBps;
        bool active;
    }

    // ─── Position ──────────────────────────────────────────────────────────
    struct Position {
        uint256 marketId;
        address fixedReceiver;
        address floatingReceiver;
        uint256 notional;
        uint256 fixedRateBps;
        uint256 fixedMargin;
        uint256 floatingMargin;
        uint256 liquidationBounty;
        uint256 entryIndex;
        uint256 openTimestamp;
        bool settled;
        bool floatingSideTaken;
    }

    mapping(uint256 => Market) public markets;
    mapping(uint256 => Position) public positions;
    uint256 public nextMarketId;
    uint256 public nextPositionId;

    // Asset balances held in this contract
    mapping(address => uint256) public totalCollateral;

    // ─── Events ────────────────────────────────────────────────────────────
    event MarketCreated(uint256 indexed marketId, address underlyingAsset, uint256 termEnd, address oracle);
    event SwapOpened(
        uint256 indexed positionId, uint256 indexed marketId, address fixedReceiver, uint256 notional, uint256 fixedRate
    );
    event FloatingSideTaken(
        uint256 indexed positionId, address floatingReceiver, uint256 marginRequired, uint256 bounty
    );
    event SwapSettled(uint256 indexed positionId, int256 netAmount, uint256 timestamp);
    event LiquidationExecuted(uint256 indexed positionId, address liquidator, uint256 bounty);

    // ─── Errors ────────────────────────────────────────────────────────────
    error MarketNotActive();
    error MarketExpired();
    error ZeroNotional();
    error AlreadyMatched();
    error AlreadySettled();
    error NotSettled();
    error NotLiquidatable();
    error InsufficientMargin();

    constructor() Ownable(msg.sender) {}

    // ─── Admin Functions ───────────────────────────────────────────────────

    function createMarket(
        address underlyingAsset,
        uint256 termEnd,
        uint256 leverageMultiplier,
        address oracle,
        uint256 liquidationThresholdBps
    ) external onlyOwner returns (uint256 marketId) {
        require(underlyingAsset != address(0), "Invalid asset");
        require(oracle != address(0), "Invalid oracle");
        require(termEnd > block.timestamp, "Invalid term");
        require(leverageMultiplier > 0, "Invalid leverage");
        require(liquidationThresholdBps > 0 && liquidationThresholdBps <= 10000, "Invalid threshold");

        marketId = nextMarketId++;
        markets[marketId] = Market({
            underlyingAsset: underlyingAsset,
            termEnd: termEnd,
            leverageMultiplier: leverageMultiplier,
            oracle: oracle,
            liquidationThresholdBps: liquidationThresholdBps,
            active: true
        });

        emit MarketCreated(marketId, underlyingAsset, termEnd, oracle);
    }

    function deactivateMarket(uint256 marketId) external onlyOwner {
        markets[marketId].active = false;
    }

    // ─── Core Functions ────────────────────────────────────────────────────

    function openSwap(uint256 marketId, uint256 notional, bool, address onBehalfOf)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        Market storage market = markets[marketId];
        if (!market.active) revert MarketNotActive();
        if (block.timestamp >= market.termEnd) revert MarketExpired();
        if (notional == 0) revert ZeroNotional();

        // Get current fixed rate from oracle
        uint256 fixedRate = _quoteFixedRate(marketId, notional);

        // Compute margin required
        uint256 termRemaining = market.termEnd - block.timestamp;
        uint256 marginRequired =
            MarginMath.requiredFixedMargin(notional, fixedRate, termRemaining, market.leverageMultiplier);

        // Pull margin from caller
        address asset = market.underlyingAsset;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), marginRequired);
        totalCollateral[asset] += marginRequired;

        // Create position
        positionId = nextPositionId++;
        address fixedReceiver = onBehalfOf != address(0) ? onBehalfOf : msg.sender;

        ICumulativeRateOracle oracle = ICumulativeRateOracle(market.oracle);
        uint256 entryIndex = oracle.getIndex(block.timestamp);

        positions[positionId] = Position({
            marketId: marketId,
            fixedReceiver: fixedReceiver,
            floatingReceiver: address(0),
            notional: notional,
            fixedRateBps: fixedRate,
            fixedMargin: marginRequired,
            floatingMargin: 0,
            liquidationBounty: 0,
            entryIndex: entryIndex,
            openTimestamp: block.timestamp,
            settled: false,
            floatingSideTaken: false
        });

        emit SwapOpened(positionId, marketId, fixedReceiver, notional, fixedRate);
    }

    function takeFloatingSide(uint256 positionId, address onBehalfOf) external nonReentrant {
        Position storage pos = positions[positionId];
        if (pos.floatingSideTaken) revert AlreadyMatched();
        if (pos.settled) revert AlreadySettled();

        Market storage market = markets[pos.marketId];
        if (block.timestamp >= market.termEnd) revert MarketExpired();

        uint256 termRemaining = market.termEnd - block.timestamp;
        ICumulativeRateOracle oracle = ICumulativeRateOracle(market.oracle);
        uint256 expectedFloat = oracle.getTWAR(7 days);
        uint256 bounty = pos.notional / 1000; // 0.1% of notional

        uint256 marginRequired = MarginMath.requiredFloatingMargin(
            pos.notional, expectedFloat, termRemaining, market.leverageMultiplier, bounty
        );

        address asset = market.underlyingAsset;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), marginRequired);
        totalCollateral[asset] += marginRequired;

        address floater = onBehalfOf != address(0) ? onBehalfOf : msg.sender;
        pos.floatingReceiver = floater;
        pos.floatingMargin = marginRequired - bounty;
        pos.liquidationBounty = bounty;
        pos.floatingSideTaken = true;

        emit FloatingSideTaken(positionId, floater, marginRequired, bounty);
    }

    function settlePosition(uint256 positionId) external nonReentrant {
        Position storage pos = positions[positionId];
        if (pos.settled) revert AlreadySettled();
        if (!pos.floatingSideTaken) revert NotSettled();

        Market storage market = markets[pos.marketId];
        if (block.timestamp < market.termEnd) revert MarketExpired();

        ICumulativeRateOracle oracle = ICumulativeRateOracle(market.oracle);
        uint256 currentIndex = oracle.getIndex(block.timestamp);
        uint256 elapsed = block.timestamp - pos.openTimestamp;

        int256 net = MarginMath.netSettlement(pos.notional, pos.fixedRateBps, pos.entryIndex, currentIndex, elapsed);

        address asset = market.underlyingAsset;
        pos.settled = true;

        if (net > 0) {
            // Fixed receiver owes floating receiver
            uint256 payment = uint256(net);
            uint256 fromFixed = payment > pos.fixedMargin ? pos.fixedMargin : payment;
            IERC20(asset).safeTransfer(pos.floatingReceiver, fromFixed + pos.floatingMargin);
            if (pos.fixedMargin > fromFixed) {
                IERC20(asset).safeTransfer(pos.fixedReceiver, pos.fixedMargin - fromFixed);
            }
        } else {
            // Floating receiver owes fixed receiver
            uint256 payment = uint256(-net);
            uint256 fromFloat = payment > pos.floatingMargin ? pos.floatingMargin : payment;
            IERC20(asset).safeTransfer(pos.fixedReceiver, fromFloat + pos.fixedMargin);
            if (pos.floatingMargin > fromFloat) {
                IERC20(asset).safeTransfer(pos.floatingReceiver, pos.floatingMargin - fromFloat);
            }
        }

        // Return bounty to floating receiver
        IERC20(asset).safeTransfer(pos.floatingReceiver, pos.liquidationBounty);

        totalCollateral[asset] -= (pos.fixedMargin + pos.floatingMargin + pos.liquidationBounty);
        emit SwapSettled(positionId, net, block.timestamp);
    }

    function liquidate(uint256 positionId) external nonReentrant {
        Position storage pos = positions[positionId];
        if (pos.settled) revert AlreadySettled();
        if (!pos.floatingSideTaken) revert NotSettled();

        Market storage market = markets[pos.marketId];
        ICumulativeRateOracle oracle = ICumulativeRateOracle(market.oracle);
        uint256 currentIndex = oracle.getIndex(block.timestamp);
        uint256 elapsed = block.timestamp - pos.openTimestamp;

        int256 net = MarginMath.netSettlement(pos.notional, pos.fixedRateBps, pos.entryIndex, currentIndex, elapsed);

        // Check if either side is undercollateralized
        bool fixedLiquidatable = net > 0 && uint256(net) > (pos.fixedMargin * market.liquidationThresholdBps) / 10000;
        bool floatLiquidatable =
            net < 0 && uint256(-net) > (pos.floatingMargin * market.liquidationThresholdBps) / 10000;

        if (!fixedLiquidatable && !floatLiquidatable) revert NotLiquidatable();

        address asset = market.underlyingAsset;
        pos.settled = true;

        // Settle net obligations and pay bounty to liquidator
        _executeSettlement(pos, net, asset);
        IERC20(asset).safeTransfer(msg.sender, pos.liquidationBounty);

        emit LiquidationExecuted(positionId, msg.sender, pos.liquidationBounty);
    }

    // ─── Internal Helpers ───────────────────────────────────────────────────

    function _quoteFixedRate(uint256 marketId, uint256) internal view returns (uint256) {
        // MVP: return a fixed rate
        // Production: implement pricing curve based on notional, market conditions
        Market storage market = markets[marketId];
        ICumulativeRateOracle oracle = ICumulativeRateOracle(market.oracle);
        uint256 currentFloat = oracle.getTWAR(7 days);
        // Fixed rate = current float + spread
        return currentFloat + 100; // +1% spread
    }

    function _executeSettlement(Position storage pos, int256 net, address asset) internal {
        if (net > 0) {
            uint256 payment = uint256(net);
            uint256 fromFixed = payment > pos.fixedMargin ? pos.fixedMargin : payment;
            IERC20(asset).safeTransfer(pos.floatingReceiver, fromFixed + pos.floatingMargin);
            if (pos.fixedMargin > fromFixed) {
                IERC20(asset).safeTransfer(pos.fixedReceiver, pos.fixedMargin - fromFixed);
            }
        } else {
            uint256 payment = uint256(-net);
            uint256 fromFloat = payment > pos.floatingMargin ? pos.floatingMargin : payment;
            IERC20(asset).safeTransfer(pos.fixedReceiver, fromFloat + pos.fixedMargin);
            if (pos.floatingMargin > fromFloat) {
                IERC20(asset).safeTransfer(pos.floatingReceiver, pos.floatingMargin - fromFloat);
            }
        }
    }
}
