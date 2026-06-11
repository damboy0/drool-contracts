// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ICumulativeRateOracle {
    function getIndex(uint256 timestamp) external view returns (uint256);
    function getTWAR(uint256 lookbackSeconds) external view returns (uint256 avgRateBps);
    function advanceIndex() external;
    function setManualRate(uint256 rateBps) external;
}
