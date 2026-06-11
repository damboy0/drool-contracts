// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SwapSingleton}        from "../src/SwapSingleton.sol";
import {CumulativeRateOracle} from "../src/CumulativeRateOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// On-chain test script for SwapSingleton + CumulativeRateOracle
//
// Run individual steps via STEP env var:
//   STEP=1  — verify deployment state
//   STEP=2  — advance oracle index
//   STEP=3  — open swap (fixed side)
//   STEP=4  — take floating side
//   STEP=5  — liquidation check
//   STEP=6  — settle position
//   STEP=all — all steps in sequence
//
// ─────────────────────────────────────────────────────────────────────────────
contract InteractProtocol is Script {

    // ── Paste your deployed addresses here ──────────────────────────────
    address constant ORACLE   = 0x239B0AD6c22e8508713df9eF53360B5f970Cd666; 
    address constant SINGLETON= 0x7d6a9c2cE05505f54bC8E05781d5b09b5f2bE4eE;
    uint256 constant MARKET_ID= 0;

    address constant USDC     = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8;

    // Test amounts (USDC has 6 decimals on Aave Sepolia testnet)
    uint256 constant NOTIONAL = 10_000e6;    // 10,000 USDC notional
    // margin will be computed by contract: notional * rate * term / leverage

    CumulativeRateOracle oracle;
    SwapSingleton        swap;

    function run() external {
        require(ORACLE    != address(0), "Set ORACLE address");
        require(SINGLETON != address(0), "Set SINGLETON address");

        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory step = vm.envOr("STEP", string("all"));

        oracle = CumulativeRateOracle(ORACLE);
        swap   = SwapSingleton(SINGLETON);

        console2.log("=== FixedFlow Protocol On-chain Test ===");
        console2.log("Oracle   :", ORACLE);
        console2.log("Singleton:", SINGLETON);
        console2.log("Deployer :", deployer);
        console2.log("Step     :", step);

        if (_eq(step, "1") || _eq(step, "all")) _step1_verifyState(deployer);
        if (_eq(step, "2") || _eq(step, "all")) _step2_advanceOracle(pk);
        if (_eq(step, "3") || _eq(step, "all")) _step3_openSwap(pk, deployer);
        if (_eq(step, "4") || _eq(step, "all")) _step4_takeFloating(pk, deployer);
        if (_eq(step, "5") || _eq(step, "all")) _step5_liquidationCheck();
        // Step 6 (settle) requires market expiry — run separately after termEnd
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 1 — Verify deployment state
    // ═══════════════════════════════════════════════════════════════════════
    function _step1_verifyState(address deployer) internal view {
        console2.log("");
        console2.log("STEP 1: Verify Deployment State");
        console2.log("");

        // Oracle state
        console2.log("[Oracle]");
        console2.log("  owner              :", oracle.owner());
        console2.log("  cumulativeIndex    :", oracle.cumulativeIndex());
        console2.log("  lastRateBps        :", oracle.lastRateBps());
        console2.log("  lastUpdateTimestamp:", oracle.lastUpdateTimestamp());
        console2.log("  snapshotCount      :", oracle.snapshotCount());

        // Market state
        (
            address asset,
            uint256 termEnd,
            uint256 leverage,
            address mOracle,
            uint256 liqBps,
            bool active
        ) = swap.markets(MARKET_ID);

        console2.log("[Market 0]");
        console2.log("  active             :", active);
        console2.log("  underlyingAsset    :", asset);
        console2.log("  termEnd            :", termEnd);
        console2.log("  termEnd (from now) :", termEnd > block.timestamp ? termEnd - block.timestamp : 0, "seconds");
        console2.log("  leverageMultiplier :", leverage);
        console2.log("  oracle             :", mOracle);
        console2.log("  liquidationBps     :", liqBps);

        // Singleton state
        console2.log("[SwapSingleton]");
        console2.log("  owner              :", swap.owner());
        console2.log("  nextMarketId       :", swap.nextMarketId());
        console2.log("  nextPositionId     :", swap.nextPositionId());
        console2.log("  totalCollateral    :", swap.totalCollateral(USDC));

        // Assertions
        require(active,               "FAIL: market not active");
        require(asset == USDC,        "FAIL: wrong underlying asset");
        require(mOracle == ORACLE,    "FAIL: oracle mismatch");
        require(termEnd > block.timestamp, "FAIL: market already expired");
        require(oracle.cumulativeIndex() >= 1e27, "FAIL: oracle not bootstrapped");
        require(swap.owner() == deployer, "FAIL: wrong singleton owner");

        console2.log("STEP 1 PASSED: deployment state verified");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 2 — Advance oracle index (simulates time passing)
    // ═══════════════════════════════════════════════════════════════════════
    function _step2_advanceOracle(uint256 pk) internal {
        console2.log("----------------------------------");
        console2.log("STEP 2: Advance Oracle Index");
        console2.log("----------------------------------");

        uint256 indexBefore = oracle.cumulativeIndex();
        uint256 rateBefore  = oracle.lastRateBps();
        console2.log("[Before] cumulativeIndex:", indexBefore);
        console2.log("[Before] lastRateBps    :", rateBefore);

        vm.startBroadcast(pk);
        oracle.advanceIndex();
        vm.stopBroadcast();

        uint256 indexAfter = oracle.cumulativeIndex();
        console2.log("[After]  cumulativeIndex:", indexAfter);
        console2.log("Index delta            :", indexAfter - indexBefore);

        // getTWAR sanity check
        uint256 twar = oracle.getTWAR(7 days);
        console2.log("TWAR (7d)              :", twar, "bps");

        require(indexAfter >= indexBefore, "FAIL: index should be monotonic");
        console2.log("STEP 2 PASSED: oracle index advanced");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 3 — Open swap (fixed receiver side)
    // ═══════════════════════════════════════════════════════════════════════
    function _step3_openSwap(uint256 pk, address deployer) internal {
        console2.log("----------------------------------");
        console2.log("STEP 3: Open Swap (Fixed Receiver Side)");
        console2.log("----------------------------------");

        uint256 usdcBefore = IERC20(USDC).balanceOf(deployer);
        uint256 collBefore = swap.totalCollateral(USDC);
        console2.log("[Before] USDC balance  :", usdcBefore);
        console2.log("[Before] totalCollateral:", collBefore);
        console2.log("Notional               :", NOTIONAL);

        vm.startBroadcast(pk);
        // Approve singleton to pull margin
        IERC20(USDC).approve(address(swap), type(uint256).max);

        uint256 positionId = swap.openSwap(
            MARKET_ID,
            NOTIONAL,
            true,        // isFixedReceiver — unused param in current impl
            deployer     // onBehalfOf
        );
        vm.stopBroadcast();

        // Read position
        (
            uint256 mId,
            address fixedReceiver,
            address floatingReceiver,
            uint256 notional,
            uint256 fixedRateBps,
            uint256 fixedMargin,
            uint256 floatingMargin,
            uint256 bounty,
            uint256 entryIndex,
            uint256 openTs,
            bool settled,
            bool floatTaken
        ) = swap.positions(positionId);

        console2.log("[Position", positionId, "]");
        console2.log("  marketId           :", mId);
        console2.log("  fixedReceiver      :", fixedReceiver);
        console2.log("  floatingReceiver   :", floatingReceiver);
        console2.log("  notional           :", notional);
        console2.log("  fixedRateBps       :", fixedRateBps);
        console2.log("  fixedMargin        :", fixedMargin);
        console2.log("  entryIndex         :", entryIndex);
        console2.log("  settled            :", settled);
        console2.log("  floatingSideTaken  :", floatTaken);

        uint256 usdcAfter = IERC20(USDC).balanceOf(deployer);
        uint256 collAfter = swap.totalCollateral(USDC);
        console2.log("[After] USDC balance   :", usdcAfter);
        console2.log("[After] totalCollateral :", collAfter);
        console2.log("Margin locked          :", usdcBefore - usdcAfter);

        require(fixedReceiver == deployer, "FAIL: wrong fixed receiver");
        require(notional == NOTIONAL,      "FAIL: wrong notional");
        require(!settled,                  "FAIL: should not be settled");
        require(!floatTaken,               "FAIL: float side should be open");
        require(fixedMargin > 0,           "FAIL: fixed margin should be > 0");
        require(usdcAfter < usdcBefore,    "FAIL: USDC should have been pulled");
        require(collAfter > collBefore,    "FAIL: collateral should have increased");

        console2.log("STEP 3 PASSED: position", positionId, "opened");

        // Save positionId for step 4 — log it prominently
        console2.log(">>> IMPORTANT: Set POSITION_ID=", positionId, "for STEP=4");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 4 — Take floating side
    // ═══════════════════════════════════════════════════════════════════════
    function _step4_takeFloating(uint256 pk, address deployer) internal {
        console2.log("----------------------------------");
        console2.log("STEP 4: Take Floating Side");
        console2.log("----------------------------------");

        uint256 positionId = vm.envOr("POSITION_ID", uint256(0));
        console2.log("Using positionId:", positionId);

        (,,,,,, uint256 floatMarginBefore,,,,,bool floatTakenBefore) = swap.positions(positionId);
        require(!floatTakenBefore, "FAIL: floating side already taken");

        uint256 usdcBefore = IERC20(USDC).balanceOf(deployer);
        console2.log("[Before] USDC balance:", usdcBefore);

        vm.startBroadcast(pk);
        IERC20(USDC).approve(address(swap), type(uint256).max);
        swap.takeFloatingSide(positionId, deployer);
        vm.stopBroadcast();

        (
            ,
            address fixedR,
            address floatR,
            uint256 notional,
            uint256 fixedRate,
            uint256 fixedMargin,
            uint256 floatMargin,
            uint256 bounty,
            ,
            ,
            bool settled,
            bool floatTaken
        ) = swap.positions(positionId);

        uint256 usdcAfter = IERC20(USDC).balanceOf(deployer);

        console2.log("[Position", positionId, " after float taken]");
        console2.log("  fixedReceiver      :", fixedR);
        console2.log("  floatingReceiver   :", floatR);
        console2.log("  notional           :", notional);
        console2.log("  fixedRateBps       :", fixedRate);
        console2.log("  fixedMargin        :", fixedMargin);
        console2.log("  floatingMargin     :", floatMargin);
        console2.log("  liquidationBounty  :", bounty);
        console2.log("  floatingSideTaken  :", floatTaken);
        console2.log("  settled            :", settled);
        console2.log("[After] USDC balance :", usdcAfter);
        console2.log("Margin locked        :", usdcBefore - usdcAfter);

        require(floatTaken,             "FAIL: float side should be taken");
        require(floatR == deployer,     "FAIL: wrong floating receiver");
        require(floatMargin > 0,        "FAIL: float margin should be > 0");
        require(bounty > 0,             "FAIL: bounty should be > 0");
        require(usdcAfter < usdcBefore, "FAIL: USDC should have been pulled");

        console2.log("STEP 4 PASSED: floating side taken, position fully matched");
        console2.log(">>> Both sides matched. Run STEP=6 after termEnd to settle.");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 5 — Liquidation health check
    // ═══════════════════════════════════════════════════════════════════════
    function _step5_liquidationCheck() internal view {
        console2.log("----------------------------------");
        console2.log("STEP 5: Liquidation Health Check");
        console2.log("----------------------------------");

        uint256 positionId = vm.envOr("POSITION_ID", uint256(0));

        (
            uint256 mId,
            ,
            ,
            uint256 notional,
            uint256 fixedRate,
            uint256 fixedMargin,
            uint256 floatMargin,
            uint256 bounty,
            ,
            ,
            bool settled,
            bool floatTaken
        ) = swap.positions(positionId);

        console2.log("Position            :", positionId);
        console2.log("notional            :", notional);
        console2.log("fixedRateBps        :", fixedRate);
        console2.log("fixedMargin         :", fixedMargin);
        console2.log("floatingMargin      :", floatMargin);
        console2.log("bounty              :", bounty);
        console2.log("settled             :", settled);
        console2.log("floatingSideTaken   :", floatTaken);

        (, , , , uint256 liqBps, ) = swap.markets(mId);
        uint256 currentRate = oracle.getTWAR(7 days);
        console2.log("Current TWAR        :", currentRate, "bps");
        console2.log("Fixed rate          :", fixedRate, "bps");
        console2.log("Liquidation BPS     :", liqBps);

        if (currentRate > fixedRate) {
            console2.log("Rate direction: floating rate > fixed rate");
            console2.log("   Fixed receiver (lender) is WINNING");
            console2.log("   Floating receiver is LOSING");
        } else {
            console2.log("Rate direction: fixed rate >= floating rate");
            console2.log("   Floating receiver (maintainer) is WINNING");
            console2.log("   Fixed receiver is LOSING");
        }

        // Estimate liquidation trigger threshold
        uint256 fixedLiqThreshold = (fixedMargin * liqBps) / 10000;
        uint256 floatLiqThreshold = (floatMargin * liqBps) / 10000;
        console2.log("Fixed liq threshold :", fixedLiqThreshold);
        console2.log("Float liq threshold :", floatLiqThreshold);
        console2.log("(Position liquidatable if net P&L exceeds threshold)");

        console2.log("STEP 5 PASSED: health check complete");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 6 — Settle position (run after termEnd)
    // Must be run as a separate broadcast after market expiry:
    //   STEP=6 forge script script/InteractProtocol.s.sol ...
    // ═══════════════════════════════════════════════════════════════════════
    function settleAfterExpiry() external {
        uint256 pk         = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(pk);
        uint256 positionId = vm.envUint("POSITION_ID");

        oracle  = CumulativeRateOracle(ORACLE);
        swap    = SwapSingleton(SINGLETON);

        console2.log("----------------------------------");
        console2.log("STEP 6: Settle Position After Expiry");
        console2.log("----------------------------------");

        (, uint256 termEnd, , , ,) = swap.markets(MARKET_ID);
        require(block.timestamp >= termEnd, "Market not yet expired");

        uint256 fixedBalBefore = IERC20(USDC).balanceOf(deployer);
        console2.log("[Before] USDC balance:", fixedBalBefore);

        // Advance oracle one last time before settlement
        vm.startBroadcast(pk);
        oracle.advanceIndex();
        swap.settlePosition(positionId);
        vm.stopBroadcast();

        uint256 fixedBalAfter = IERC20(USDC).balanceOf(deployer);
        console2.log("[After]  USDC balance:", fixedBalAfter);

        (,,,,,,,,,, bool settled,) = swap.positions(positionId);
        require(settled, "FAIL: position should be settled");

        int256 pnl = int256(fixedBalAfter) - int256(fixedBalBefore);
        console2.log("P&L (deployer):", pnl);
        console2.log("STEP 6 PASSED: position settled");
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _getMarket() internal view returns (
        address asset, uint256 termEnd, uint256 leverage,
        address mOracle, uint256 liqBps, bool active,
        uint256 dummy1, uint256 dummy2
    ) {
        (asset, termEnd, leverage, mOracle, liqBps, active)
            = swap.markets(MARKET_ID);
        dummy1 = 0; dummy2 = 0;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}