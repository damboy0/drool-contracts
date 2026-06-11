// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ISwapSingleton {
    function openSwap(uint256 marketId, uint256 notional, bool mintNFT, address onBehalfOf)
        external
        returns (uint256 positionId);

    function takeFloatingSide(uint256 positionId, address onBehalfOf) external;

    function settlePosition(uint256 positionId) external;

    function liquidate(uint256 positionId) external;
}
