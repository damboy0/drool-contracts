// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {SwapSingleton} from "../src/SwapSingleton.sol";
import {CumulativeRateOracle} from "../src/CumulativeRateOracle.sol";
import {MarginMath} from "../src/libraries/MarginMath.sol";

contract SwapSingletonTest is Test {
    SwapSingleton swapSingleton;
    CumulativeRateOracle oracle;
    ERC20Mock usdc;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        // Deploy oracle
        oracle = new CumulativeRateOracle();

        // Deploy swap singleton
        swapSingleton = new SwapSingleton();

        // Deploy mock USDC
        usdc = new ERC20Mock();

        // Mint tokens
        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 1000e6);

        // Create market
        uint256 termEnd = block.timestamp + 30 days;
        swapSingleton.createMarket(
            address(usdc),
            termEnd,
            10, // 10x leverage
            address(oracle),
            8000 // 80% liquidation threshold
        );

        // Set manual rate for testing
        oracle.setManualRate(300); // 3%
    }

    function test_OpenSwap() public {
        uint256 notional = 100e6; // 100 USDC

        vm.startPrank(alice);
        usdc.approve(address(swapSingleton), 1000e6);

        uint256 positionId = swapSingleton.openSwap(
            0, // marketId
            notional,
            false,
            alice
        );

        vm.stopPrank();

        // Verify position was created
        (uint256 marketId, address fixedReceiver,, uint256 pos_notional, uint256 fixedRate,,,,,,,) =
            swapSingleton.positions(positionId);

        assertEq(marketId, 0);
        assertEq(fixedReceiver, alice);
        assertEq(pos_notional, notional);
        assertGt(fixedRate, 0);
    }

    function test_TakeFloatingSide() public {
        uint256 notional = 100e6;

        // Alice opens swap
        vm.startPrank(alice);
        usdc.approve(address(swapSingleton), 1000e6);
        uint256 positionId = swapSingleton.openSwap(0, notional, false, alice);
        vm.stopPrank();

        // Bob takes floating side
        vm.startPrank(bob);
        usdc.approve(address(swapSingleton), 1000e6);
        swapSingleton.takeFloatingSide(positionId, bob);
        vm.stopPrank();

        // Verify position is matched
        (,, address floatingReceiver,,,,,,,,, bool floatingSideTaken) = swapSingleton.positions(positionId);
        assertEq(floatingReceiver, bob);
        assertTrue(floatingSideTaken);
    }

    function test_SettlePosition() public {
        uint256 notional = 100e6;

        // Open and match swap
        vm.startPrank(alice);
        usdc.approve(address(swapSingleton), 1000e6);
        uint256 positionId = swapSingleton.openSwap(0, notional, false, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(swapSingleton), 1000e6);
        swapSingleton.takeFloatingSide(positionId, bob);
        vm.stopPrank();

        // Advance time to expiry
        uint256 marketTermEnd = block.timestamp + 30 days;
        vm.warp(marketTermEnd + 1);

        // Advance oracle
        oracle.advanceIndex();

        // Settle position
        uint256 balanceBefore = usdc.balanceOf(alice);
        swapSingleton.settlePosition(positionId);
        uint256 balanceAfter = usdc.balanceOf(alice);

        // Verify settlement occurred
        (,,,,,,,,,, bool settled,) = swapSingleton.positions(positionId);
        assertTrue(settled);
    }

    function test_OracleAdvancesIndex() public {
        uint256 initialIndex = oracle.cumulativeIndex();

        // Advance time and rate
        vm.warp(block.timestamp + 1 hours);
        oracle.setManualRate(500); // 5%
        oracle.advanceIndex();

        uint256 newIndex = oracle.cumulativeIndex();
        assertGt(newIndex, initialIndex);
    }

    function test_MarginCalculation() public {
        uint256 notional = 100e6;
        uint256 fixedRate = 400; // 4% BPS
        uint256 term = 30 days;
        uint256 leverage = 10;

        uint256 margin = MarginMath.requiredFixedMargin(notional, fixedRate, term, leverage);

        assertGt(margin, 0);
        // Expected: (100e6 * 400 * 30 days) / (10000 * 365 days * 10)
        // = (100e6 * 400 * 30) / (10000 * 365 * 10)
        // = (1.2e9 * 100) / 36500000
        // ≈ 3.288e6
    }

    function test_SettlementCalculation() public {
        uint256 notional = 100e6;
        uint256 fixedRate = 400; // 4% BPS
        uint256 entryIndex = 1e27; // Start at 1.0
        uint256 currentIndex = 1e27 + (1e27 * 500) / 10000; // Index after 5% growth
        uint256 elapsed = 30 days;

        int256 net = MarginMath.netSettlement(notional, fixedRate, entryIndex, currentIndex, elapsed);

        // Floating rate (5%) > Fixed rate (4%), so floating owes fixed
        assertTrue(net < 0, "Floating should owe fixed");
    }

    function test_Liquidation() public {
        uint256 notional = 100e6;

        vm.startPrank(alice);
        usdc.approve(address(swapSingleton), 1000e6);
        uint256 positionId = swapSingleton.openSwap(0, notional, false, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(swapSingleton), 1000e6);
        swapSingleton.takeFloatingSide(positionId, bob);
        vm.stopPrank();

        // Move to expiry
        uint256 marketTermEnd = block.timestamp + 30 days;
        vm.warp(marketTermEnd + 1);

        // Set extreme rate to trigger liquidation
        oracle.setManualRate(5000); // 50% rate (extreme)
        oracle.advanceIndex();

        // Anyone can liquidate
        address liquidator = makeAddr("liquidator");
        uint256 liquidatorBalanceBefore = usdc.balanceOf(liquidator);

        vm.prank(liquidator);
        swapSingleton.liquidate(positionId);

        uint256 liquidatorBalanceAfter = usdc.balanceOf(liquidator);
        assertGt(liquidatorBalanceAfter, liquidatorBalanceBefore, "Liquidator should receive bounty");

        // Verify position is settled
        (,,,,,,,,,, bool settled,) = swapSingleton.positions(positionId);
        assertTrue(settled);
    }
}
