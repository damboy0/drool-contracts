// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SwapSingleton}        from "../src/SwapSingleton.sol";
import {CumulativeRateOracle} from "../src/CumulativeRateOracle.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Deploy: CumulativeRateOracle + SwapSingleton + first market
//
// forge script script/DeployProtocol.s.sol \
//   --rpc-url $RPC_URL --private-key $PRIVATE_KEY \
//   --broadcast --verify \
//   --verifier-url "https://api.etherscan.io/v2/api?chainid=11155111" \
//   --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
// ─────────────────────────────────────────────────────────────────────────────
// USDC : 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8
// LINK
contract DeployProtocol is Script {

    address constant USDC              = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8;
    uint256 constant TERM_LENGTH       = 30 days;
    uint256 constant LEVERAGE          = 10;
    uint256 constant LIQUIDATION_BPS   = 8000;
    uint256 constant INITIAL_RATE_BPS  = 300;

    function run() external {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("=== FixedFlow Protocol Deployment ===");
        console2.log("Deployer :", deployer);
        console2.log("Chain    :", block.chainid);

        vm.startBroadcast(pk);

        // 1. Oracle
        CumulativeRateOracle oracle = new CumulativeRateOracle();
        // oracle.setManualRate(INITIAL_RATE_BPS);
        oracle.advanceIndex();
        console2.log("[1] Oracle   :", address(oracle));
        console2.log("    rate     :", INITIAL_RATE_BPS, "bps");
        console2.log("    index    :", oracle.cumulativeIndex());

        // 2. SwapSingleton
        SwapSingleton swap = new SwapSingleton();
        console2.log("[2] Singleton:", address(swap));

        // 3. Market 0 — USDC 30-day
        uint256 termEnd  = block.timestamp + TERM_LENGTH;
        uint256 marketId = swap.createMarket(
            USDC, termEnd, LEVERAGE, address(oracle), LIQUIDATION_BPS
        );
        console2.log("[3] Market ID:", marketId);
        console2.log("    asset    :", USDC);
        console2.log("    termEnd  :", termEnd);
        console2.log("    leverage :", LEVERAGE);

        vm.stopBroadcast();

        console2.log("\n=== Copy to .env ===");
        console2.log("ORACLE_ADDRESS=", address(oracle));
        console2.log("SWAP_SINGLETON_ADDRESS=", address(swap));
        console2.log("MARKET_ID=0");
    }
}