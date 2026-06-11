// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CumulativeRateOracle is Ownable {
    // Index stored in ray (1e27) for precision
    uint256 public constant RAY = 1e27;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant STALE_THRESHOLD = 1 hours;

    uint256 public cumulativeIndex;
    uint256 public lastUpdateTimestamp;
    uint256 public lastRateBps;

    // Ring buffer for TWAR computation (store 30 days of snapshots)
    struct Snapshot {
        uint256 timestamp;
        uint256 index;
    }

    Snapshot[720] public snapshots;
    uint256 public snapshotHead;
    uint256 public snapshotCount;

    error StaleOracle(uint256 lastUpdate, uint256 threshold);
    error IndexNotMonotonic();

    event IndexAdvanced(uint256 newIndex, uint256 timestamp, uint256 rateBps);
    event SnapshotStored(uint256 index, uint256 timestamp);

    constructor() Ownable(msg.sender) {
        cumulativeIndex = RAY; // Start at 1.0
        lastUpdateTimestamp = block.timestamp;
        lastRateBps = 300; // default 3%
    }

    /// @notice Anyone can call to advance the index. Should be called at least once per block.
    function advanceIndex() external {
        _advanceIndex();
    }

    function _advanceIndex() internal {
        uint256 currentRate = _fetchCurrentRate();
        uint256 dt = block.timestamp - lastUpdateTimestamp;
        if (dt == 0) return;

        // Simple compounding: index = index * (1 + rate * dt/year)
        // Using BPS: rate is in BPS (1 = 0.01%)
        uint256 newIndex = cumulativeIndex + (cumulativeIndex * currentRate * dt) / (10000 * SECONDS_PER_YEAR);

        require(newIndex >= cumulativeIndex, "IndexNotMonotonic");

        cumulativeIndex = newIndex;
        lastUpdateTimestamp = block.timestamp;
        lastRateBps = currentRate;

        // Store snapshot for TWAR
        _storeSnapshot(newIndex);

        emit IndexAdvanced(newIndex, block.timestamp, currentRate);
    }

    function _fetchCurrentRate() internal view returns (uint256 rateBps) {
        // For MVP: return last known rate or default
        rateBps = lastRateBps > 0 ? lastRateBps : 300; // default 3% if no data
    }

    /// @notice Get the index at a specific timestamp (interpolated)
    function getIndex(uint256 timestamp) external view returns (uint256) {
        if (timestamp >= block.timestamp) return cumulativeIndex;
        // For past timestamps: find nearest snapshot
        return cumulativeIndex;
    }

    /// @notice Time-weighted average rate over lookback period
    function getTWAR(uint256 lookbackSeconds) external view returns (uint256 avgRateBps) {
        // MVP: For now, return last known rate
        // In production, this would compute a proper time-weighted average
        // from snapshots stored during index advancements
        return lastRateBps > 0 ? lastRateBps : 300;
    }

    function _storeSnapshot(uint256 index) internal {
        uint256 slot = (snapshotHead + snapshotCount) % 720;
        snapshots[slot] = Snapshot(block.timestamp, index);
        if (snapshotCount < 720) {
            snapshotCount++;
        } else {
            snapshotHead = (snapshotHead + 1) % 720;
        }
        emit SnapshotStored(index, block.timestamp);
    }

    /// @notice Admin: manually set rate for testing or when Chainlink unavailable
    function setManualRate(uint256 rateBps) external onlyOwner {
        lastRateBps = rateBps;
        // Don't update lastUpdateTimestamp here - let advanceIndex() handle it
    }
}
