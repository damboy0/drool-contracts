// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library MarginMath {
    uint256 constant SECONDS_PER_YEAR = 365 days;
    uint256 constant BPS = 10000;

    /// @notice Minimum margin for the fixed receiver (lender)
    /// fixedMargin = notional * fixedRate * term / leverage
    function requiredFixedMargin(
        uint256 notional,
        uint256 fixedRateBps,
        uint256 termSeconds,
        uint256 leverageMultiplier
    ) internal pure returns (uint256) {
        return (notional * fixedRateBps * termSeconds) / (BPS * SECONDS_PER_YEAR * leverageMultiplier);
    }

    /// @notice Minimum margin for the floating receiver (speculator)
    /// floatingMargin = notional * expectedFloat * term / leverage + bounty
    function requiredFloatingMargin(
        uint256 notional,
        uint256 expectedFloatBps,
        uint256 termSeconds,
        uint256 leverageMultiplier,
        uint256 bountyAmount
    ) internal pure returns (uint256) {
        uint256 base = (notional * expectedFloatBps * termSeconds) / (BPS * SECONDS_PER_YEAR * leverageMultiplier);
        return base + bountyAmount;
    }

    /// @notice Net settlement amount at expiry
    /// Positive = fixed receiver owes floating receiver
    /// Negative = floating receiver owes fixed receiver
    function netSettlement(
        uint256 notional,
        uint256 fixedRateBps,
        uint256 entryIndex,
        uint256 currentIndex,
        uint256 elapsed
    ) internal pure returns (int256) {
        // Realized floating rate in BPS
        uint256 realizedFloatBps = currentIndex > entryIndex
            ? ((currentIndex - entryIndex) * BPS * SECONDS_PER_YEAR) / (entryIndex * elapsed)
            : 0;

        uint256 fixedObligation = (notional * fixedRateBps * elapsed) / (BPS * SECONDS_PER_YEAR);
        uint256 floatObligation = (notional * realizedFloatBps * elapsed) / (BPS * SECONDS_PER_YEAR);

        if (fixedObligation > floatObligation) {
            return int256(fixedObligation - floatObligation);
        } else {
            return -int256(floatObligation - fixedObligation);
        }
    }
}
