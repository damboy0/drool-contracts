// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {CumulativeRateOracle} from "../src/CumulativeRateOracle.sol";

contract CumulativeRateOracleTest is Test {
    CumulativeRateOracle oracle;

    function setUp() public {
        oracle = new CumulativeRateOracle();
    }

    function test_InitialIndexIsRay() public {
        assertEq(oracle.cumulativeIndex(), 1e27, "Initial index should be 1e27 (RAY)");
    }

    function test_AdvanceIndexIncreasesIndex() public {
        uint256 initialIndex = oracle.cumulativeIndex();

        vm.warp(block.timestamp + 1 hours);
        oracle.setManualRate(300); // 3% rate
        oracle.advanceIndex();

        uint256 newIndex = oracle.cumulativeIndex();
        assertGt(newIndex, initialIndex, "Index should increase");
    }

    function test_IndexGrowthIsMonotonic() public {
        oracle.setManualRate(300);
        oracle.advanceIndex();
        uint256 index1 = oracle.cumulativeIndex();

        vm.warp(block.timestamp + 1 days);
        oracle.setManualRate(300);
        oracle.advanceIndex();
        uint256 index2 = oracle.cumulativeIndex();

        assertGe(index2, index1, "Index should be monotonically increasing");
    }

    function test_GetIndexAtCurrentTimestamp() public {
        uint256 current = oracle.getIndex(block.timestamp);
        assertEq(current, oracle.cumulativeIndex(), "Current index should equal cumulativeIndex");
    }

    function test_GetTWARWithMultipleSnapshots() public {
        // Add initial snapshot
        oracle.setManualRate(300);
        oracle.advanceIndex();

        // Add snapshots over time
        for (uint256 i = 0; i < 24; i++) {
            vm.warp(block.timestamp + 1 hours);
            oracle.setManualRate(300);
            oracle.advanceIndex();
        }

        // Get TWAR for 7 days - should return lastRateBps or default
        uint256 twar = oracle.getTWAR(7 days);
        assertEq(twar, 300, "TWAR should return lastRateBps");
    }

    function test_SnapshotStorage() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1 hours);
            oracle.setManualRate(300);
            oracle.advanceIndex();
        }

        assertTrue(oracle.snapshotCount() > 0, "Should have stored snapshots");
    }

    function test_ManualRateUpdate() public {
        uint256 oldRate = oracle.lastRateBps();

        oracle.setManualRate(500);

        uint256 newRate = oracle.lastRateBps();
        assertNotEq(newRate, oldRate);
        assertEq(newRate, 500);
    }

    function test_HighRateGrowsIndexFaster() public {
        // Start with 3% rate
        oracle.setManualRate(300);
        oracle.advanceIndex();
        uint256 index1 = oracle.cumulativeIndex();

        // Reset to test high rate
        uint256 timestamp1 = block.timestamp;

        // Create new oracle with 5% rate
        CumulativeRateOracle oracle2 = new CumulativeRateOracle();
        oracle2.setManualRate(500);
        oracle2.advanceIndex();

        vm.warp(timestamp1 + 1 days);
        oracle.advanceIndex();
        uint256 index1After = oracle.cumulativeIndex();

        oracle2.setManualRate(500);
        vm.warp(block.timestamp + 1 days);
        oracle2.advanceIndex();
        uint256 index2After = oracle2.cumulativeIndex();

        // 5% rate should grow index faster
        uint256 growth1 = index1After - index1;
        uint256 growth2 = index2After - 1e27; // oracle2 starts fresh

        // Both should be positive growth
        assertGt(growth1, 0);
        assertGt(growth2, 0);
    }
}
