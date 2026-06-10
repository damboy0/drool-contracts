// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";

import {RehypothecationHook} from "../src/RehypothecationHook.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

// ─── Network Config ──────────────────────────────────────────────────────────
//
// Sepolia (chain 11155111):
//   PoolManager:  0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A  (Uniswap v4 Sepolia)
//   Aave v3 Pool: 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951  (Aave v3 Sepolia)
//   USDC:         0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8  (Aave Sepolia testnet USDC)
//   WETH:         0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c  (Aave Sepolia testnet WETH)
// LINK: 0xf8Fb3713D459D7C1018BD0A49D19b4C44290EBE5
//
contract DeployRehypothecationHook is Script {
    using PoolIdLibrary for PoolKey;

    // ─── Hook permission flags (must match getHookPermissions()) ─────────
    uint160 constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG) | uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG)
        | uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG) | uint160(Hooks.BEFORE_SWAP_FLAG) | uint160(Hooks.AFTER_SWAP_FLAG)
        | uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) | uint160(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG);

    // ─── Deployment result (logged at end) ───────────────────────────────
    RehypothecationHook public hook;
    PoolKey public poolKey;
    PoolId public poolId;

    function run() external {
        // ── Load config from environment ─────────────────────────────────
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address poolManagerAddr = vm.envAddress("POOL_MANAGER_ADDRESS");
        address aavePoolAddr = vm.envAddress("AAVE_POOL_ADDRESS");
        address token0Addr = vm.envAddress("TOKEN0_ADDRESS"); // lower address
        address token1Addr = vm.envAddress("TOKEN1_ADDRESS"); // higher address
        uint24 poolFee = uint24(vm.envOr("POOL_FEE", uint256(3000))); // default 0.3%
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));

        // Enforce token ordering (currency0 must be < currency1)
        if (token0Addr > token1Addr) {
            (token0Addr, token1Addr) = (token1Addr, token0Addr);
            console2.log("Token addresses reordered to satisfy currency0 < currency1");
        }

        console2.log("=== FixedFlow RehypothecationHook Deployment ===");
        console2.log("Deployer:      ", deployer);
        console2.log("Network:       ", block.chainid);
        console2.log("PoolManager:   ", poolManagerAddr);
        console2.log("Aave Pool:     ", aavePoolAddr);
        console2.log("Token0:        ", token0Addr);
        console2.log("Token1:        ", token1Addr);
        console2.log("Pool Fee:      ", poolFee);
        console2.log("Tick Spacing:  ", uint256(int256(tickSpacing)));

        // ── Mine CREATE2 salt for correct hook address flags ─────────────
        //
        address create2Factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        console2.log("\nMining CREATE2 salt for hook address with flags:", FLAGS);
        console2.log("CREATE2 factory:", create2Factory);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            create2Factory,
            FLAGS,
            type(RehypothecationHook).creationCode,
            abi.encode(poolManagerAddr, aavePoolAddr, deployer)
        );

        console2.log("Mined hook address:", hookAddress);
        console2.log("Salt:             ", uint256(salt));

        // ── Deploy ───────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);

        hook = new RehypothecationHook{salt: salt}(IPoolManager(poolManagerAddr), IPool(aavePoolAddr), deployer);

        require(address(hook) == hookAddress, "Hook address mismatch  salt mining failed");
        console2.log("\nHook deployed at:", address(hook));

        // Transfer ownership from CREATE2 factory to actual deployer
        // hook.transferOwnership(deployer);
        // console2.log("Ownership transferred to deployer:", deployer);

        // ── Configure pool key ───────────────────────────────────────────
        poolKey = PoolKey({
            currency0: Currency.wrap(token0Addr),
            currency1: Currency.wrap(token1Addr),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        // ── Initialize the Uniswap v4 pool ───────────────────────────────
        // sqrtPriceX96 at tick 0 = price of 1:1 between token0 and token1.
        uint160 initialSqrtPriceX96 = _getInitialSqrtPrice();

        IPoolManager(poolManagerAddr).initialize(poolKey, initialSqrtPriceX96);
        console2.log("Pool initialized. PoolId:", uint256(PoolId.unwrap(poolId)));

        // ── Set Aave aToken config on the hook ───────────────────────────
        address aTokenAddress = vm.envOr("ATOKEN_ADDRESS", address(0));
        if (aTokenAddress != address(0)) {
            hook.setPoolConfig(
                poolId,
                aTokenAddress,
                token0Addr,
                true // isToken0 = true (token0 goes to Aave)
            );
            console2.log("Aave aToken config set:", aTokenAddress);
        } else {
            console2.log("WARNING: ATOKEN_ADDRESS not set. Call setPoolConfig() manually.");
        }

        vm.stopBroadcast();

        // ── Summary ──────────────────────────────────────────────────────
        console2.log("\n=== Deployment Complete ===");
        console2.log("Hook Address:    ", address(hook));
        console2.log("Pool ID:         ", uint256(PoolId.unwrap(poolId)));
        console2.log("Owner:           ", hook.owner());
        console2.log("Paused:          ", hook.paused());
        console2.log("\nNext steps:");
        console2.log("  1. Set NEXT_PUBLIC_HOOK_ADDRESS =", address(hook));
        console2.log("  2. Add liquidity to the pool via PoolManager");
        console2.log("  3. Deploy SwapSingleton.sol (Phase 2)");
        console2.log("  4. Verify contract: forge verify-contract", address(hook));
    }

    /// @dev Returns the initial sqrtPriceX96.
    ///      Reads INITIAL_TICK from env if set, otherwise defaults to tick 0.
    ///      For a USDC/WETH pool you'd set INITIAL_TICK to e.g. 202919
    ///      (roughly $3000 per ETH).
    function _getInitialSqrtPrice() internal view returns (uint160) {
        int24 initialTick = int24(int256(vm.envOr("INITIAL_TICK", uint256(0))));
        return TickMath.getSqrtPriceAtTick(initialTick);
    }
}
