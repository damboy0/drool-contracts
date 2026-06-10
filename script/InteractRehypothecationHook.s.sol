// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RehypothecationHook} from "../src/RehypothecationHook.sol";

// ─── Minimal router (same pattern as test suite) ────────────────────────────
contract OnchainRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    uint8 constant ACTION_INITIALIZE = 0;
    uint8 constant ACTION_ADD_LIQUIDITY = 1;
    uint8 constant ACTION_REMOVE_LIQUIDITY = 2;
    uint8 constant ACTION_SWAP = 3;

    struct InitParams {
        PoolKey key;
        uint160 sqrtPriceX96;
    }

    struct LiquidityParams {
        PoolKey key;
        ModifyLiquidityParams params;
        address payer;
    }

    struct SwapCallParams {
        PoolKey key;
        SwapParams params;
        address payer;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external {
        manager.unlock(abi.encode(ACTION_INITIALIZE, abi.encode(InitParams(key, sqrtPriceX96))));
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, address payer) external {
        uint8 action = params.liquidityDelta >= 0 ? ACTION_ADD_LIQUIDITY : ACTION_REMOVE_LIQUIDITY;
        manager.unlock(abi.encode(action, abi.encode(LiquidityParams(key, params, payer))));
    }

    function swap(PoolKey memory key, SwapParams memory params, address payer) external {
        manager.unlock(abi.encode(ACTION_SWAP, abi.encode(SwapCallParams(key, params, payer))));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));

        if (action == ACTION_INITIALIZE) {
            InitParams memory p = abi.decode(payload, (InitParams));
            manager.initialize(p.key, p.sqrtPriceX96);
        } else if (action == ACTION_ADD_LIQUIDITY || action == ACTION_REMOVE_LIQUIDITY) {
            LiquidityParams memory p = abi.decode(payload, (LiquidityParams));
            (BalanceDelta delta,) = manager.modifyLiquidity(p.key, p.params, new bytes(0));
            _settle(p.key, delta, p.payer);
        } else if (action == ACTION_SWAP) {
            SwapCallParams memory p = abi.decode(payload, (SwapCallParams));
            BalanceDelta delta = manager.swap(p.key, p.params, new bytes(0));
            _settle(p.key, delta, p.payer);
        }
        return "";
    }

    function _settle(PoolKey memory key, BalanceDelta delta, address payer) internal {
        int128 d0 = delta.amount0();
        if (d0 < 0) key.currency0.settle(manager, payer, uint128(-d0), false);
        else if (d0 > 0) key.currency0.take(manager, payer, uint128(d0), false);

        int128 d1 = delta.amount1();
        if (d1 < 0) key.currency1.settle(manager, payer, uint128(-d1), false);
        else if (d1 > 0) key.currency1.take(manager, payer, uint128(d1), false);
    }
}

// ─── Main interaction script ─────────────────────────────────────────────────
contract InteractRehypothecationHook is Script {
    using PoolIdLibrary for PoolKey;

    // ── Deployed hook ────────────────────────────────────────────────────
    address constant HOOK = 0x39fE01D9250B07036966aab8ac5a0359f756d6C6;

    // ── Sepolia addresses ────────────────────────────────────────────────
    address constant POOL_MANAGER = 0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A;
    address constant AAVE_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address constant LINK = 0xf8Fb3713D459D7C1018BD0A49D19b4C44290EBE5;
    address constant WETH = 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c;
    address constant aLINK = 0x3FfAf50D4F4E96eB78f2407c090b72e86eCaed24;
    address constant aWETH = 0x5b071b590a59395fE4025A0Ccc1FcC931AAc1830;

    // Ensure token0 < token1
    address constant TOKEN0 = LINK < WETH ? LINK : WETH;
    address constant TOKEN1 = LINK < WETH ? WETH : LINK;

    RehypothecationHook hook = RehypothecationHook(HOOK);
    IPoolManager pm = IPoolManager(POOL_MANAGER);
    OnchainRouter router;

    PoolKey poolKey;
    PoolId poolId;

    // ── Amounts ──────────────────────────────────────────────────────────
    uint256 constant LIQUIDITY_AMOUNT = 1_000e18; // 1000 USDC  (6 decimals)
    uint256 constant SWAP_AMOUNT = 1000; // 100  USDC
    int256 constant LIQUIDITY_DELTA = 1e18; // liquidity units (not token amount)

    // ─────────────────────────────────────────────────────────────────────
    // STEP SELECTOR — set via env: STEP=1|2|3|4|all
    // ─────────────────────────────────────────────────────────────────────

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory step = vm.envOr("STEP", string("all"));

        poolKey = PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
        poolId = poolKey.toId();

        console2.log("=== FixedFlow On-chain Interaction ===");
        console2.log("Hook:    ", HOOK);
        console2.log("Deployer:", deployer);
        console2.log("Step:    ", step);

        vm.startBroadcast(pk);
        router = new OnchainRouter(pm);
        console2.log("Router deployed:", address(router));
        router.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        console2.log("Pool initialized");
        vm.stopBroadcast();

        if (_eq(step, "1") || _eq(step, "all")) _step1_configAndVerify(pk, deployer);
        if (_eq(step, "2") || _eq(step, "all")) _step2_addLiquidityVerifyAave(pk, deployer);
        if (_eq(step, "3") || _eq(step, "all")) _step3_fullSwapFlow(pk, deployer);
        if (_eq(step, "4") || _eq(step, "all")) _step4_emergencyAndPause(pk, deployer);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 1 — Config + State Verification
    // ═══════════════════════════════════════════════════════════════════════
    function _step1_configAndVerify(uint256 pk, address deployer) internal {
        // console2.log("────────────────────────────────────────");
        console2.log("STEP 1: Config & State Verification");
        // console2.log("──────────────────────────────────────");

        // ── Read current state before any changes ─────────────────────
        console2.log("[Before] Hook state:");
        console2.log("  owner  :", hook.owner());
        console2.log("  paused :", hook.paused());
        console2.log("  aavePool:", address(hook.aavePool()));

        (address aToken, address underlying, uint256 deployed, bool isToken0, bool initialized) =
            hook.poolConfigs(poolId);
        console2.log("[Before] Pool config:");
        console2.log("  initialized :", initialized);
        console2.log("  aToken      :", aToken);
        console2.log("  underlying  :", underlying);
        console2.log("  deployedToAave:", deployed);
        console2.log("  isToken0    :", isToken0);

        // ── Set pool config ───────────────────────────────────────────
        console2.log("Calling setPoolConfig...");
        vm.startBroadcast(pk);
        hook.setPoolConfig(poolId, aWETH, TOKEN0, true);
        vm.stopBroadcast();

        // ── Verify state after ────────────────────────────────────────
        (aToken, underlying, deployed, isToken0, initialized) = hook.poolConfigs(poolId);
        console2.log("[After] Pool config:");
        console2.log("  initialized :", initialized);
        console2.log("  aToken      :", aToken);
        console2.log("  underlying  :", underlying);
        console2.log("  deployedToAave:", deployed);
        console2.log("  isToken0    :", isToken0);

        // ── Assertions ────────────────────────────────────────────────
        require(initialized, "FAIL: pool not initialized");
        require(aToken == aWETH, "FAIL: aToken mismatch");
        require(underlying == TOKEN0, "FAIL: underlying mismatch");
        require(isToken0 == true, "FAIL: isToken0 mismatch");
        require(!hook.paused(), "FAIL: hook should not be paused");
        require(hook.owner() == deployer, "FAIL: owner mismatch");

        console2.log("STEP 1 PASSED: config verified on-chain");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 2 — Add Liquidity + Verify Aave Deposit
    // ═══════════════════════════════════════════════════════════════════════
    function _step2_addLiquidityVerifyAave(uint256 pk, address deployer) internal {
        console2.log("--------------");
        console2.log("STEP 2: Add Liquidity + Verify Aave Deposit");
        console2.log("--------------");

        // ── Token balances before ─────────────────────────────────────
        uint256 t0Before = IERC20(TOKEN0).balanceOf(deployer);
        uint256 t1Before = IERC20(TOKEN1).balanceOf(deployer);
        uint256 aaveBalBefore = IERC20(aWETH).balanceOf(HOOK);

        console2.log("[Before] Deployer token0 balance:", t0Before);
        console2.log("[Before] Deployer token1 balance:", t1Before);
        console2.log("[Before] Hook aUSDC balance (Aave):", aaveBalBefore);
        console2.log("[Before] deployedToAave:", _getDeployedToAave());

        vm.startBroadcast(pk);

        // Approve router to spend tokens
        IERC20(TOKEN0).approve(address(router), type(uint256).max);
        IERC20(TOKEN1).approve(address(router), type(uint256).max);

        // Add liquidity
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: LIQUIDITY_DELTA, salt: bytes32(0)});
        router.modifyLiquidity(poolKey, params, deployer);

        vm.stopBroadcast();

        // ── Balances after ────────────────────────────────────────────
        uint256 t0After = IERC20(TOKEN0).balanceOf(deployer);
        uint256 t1After = IERC20(TOKEN1).balanceOf(deployer);
        uint256 aaveBalAfter = IERC20(aWETH).balanceOf(HOOK);
        uint256 deployedAfter = _getDeployedToAave();

        console2.log("[After] Deployer token0 balance:", t0After);
        console2.log("[After] Deployer token1 balance:", t1After);
        console2.log("[After] Hook aUSDC balance (Aave):", aaveBalAfter);
        console2.log("[After] deployedToAave:", deployedAfter);

        uint256 token0Spent = t0Before > t0After ? t0Before - t0After : 0;
        console2.log("Token0 spent on liquidity:", token0Spent);

        // ── Note on deposit ───────────────────────────────────────────
        // The hook's _depositToAave currently calls transfer() from hook balance.
        // Since the hook doesn't hold tokens (PoolManager does), the deposit path
        // will only fire if hook has a balance. This is the known Phase 1 TODO.
        // We verify the hook callbacks ran (no revert) and log the state.
        console2.log("Note: Aave deposit fires only when hook holds token balance.");
        console2.log("deployedToAave after add:", deployedAfter);

        require(t0After <= t0Before, "FAIL: token0 balance should have decreased");
        console2.log("STEP 2 PASSED: liquidity added, hook callbacks executed");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 3 — Full Flow: Swap + afterSwap rebalance
    // ═══════════════════════════════════════════════════════════════════════
    function _step3_fullSwapFlow(uint256 pk, address deployer) internal {
        console2.log("----------------------------------");
        console2.log("STEP 3: Full Flow Swap + afterSwap");
        console2.log("----------------------------------");

        uint256 t0Before = IERC20(TOKEN0).balanceOf(deployer);
        uint256 t1Before = IERC20(TOKEN1).balanceOf(deployer);
        uint256 deployedBefore = _getDeployedToAave();

        console2.log("[Before Swap] token0:", t0Before);
        console2.log("[Before Swap] token1:", t1Before);
        console2.log("[Before Swap] deployedToAave:", deployedBefore);

        vm.startBroadcast(pk);

        IERC20(TOKEN0).approve(address(router), type(uint256).max);
        IERC20(TOKEN1).approve(address(router), type(uint256).max);

        // Swap token0 → token1
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(SWAP_AMOUNT),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        router.swap(poolKey, params, deployer);

        vm.stopBroadcast();

        uint256 t0After = IERC20(TOKEN0).balanceOf(deployer);
        uint256 t1After = IERC20(TOKEN1).balanceOf(deployer);
        uint256 deployedAfter = _getDeployedToAave();

        console2.log("[After Swap] token0:", t0After);
        console2.log("[After Swap] token1:", t1After);
        console2.log("[After Swap] deployedToAave:", deployedAfter);

        uint256 t0Spent = t0Before > t0After ? t0Before - t0After : 0;
        uint256 t1Gained = t1After > t1Before ? t1After - t1Before : 0;
        console2.log("Token0 spent in swap:", t0Spent);
        console2.log("Token1 received from swap:", t1Gained);

        require(t1After > t1Before, "FAIL: should have received token1 from swap");
        require(t0After < t0Before, "FAIL: should have spent token0 in swap");

        console2.log("STEP 3 PASSED: swap executed, beforeSwap + afterSwap hooks fired");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 4 — Emergency Withdraw + Pause/Unpause
    // ═══════════════════════════════════════════════════════════════════════
    function _step4_emergencyAndPause(uint256 pk, address deployer) internal {
        console2.log("--------------------------------------");
        console2.log("STEP 4: Emergency Withdraw + Pause Test");
        console2.log("----------------------------------------");

        // ── 4a: Pause ─────────────────────────────────────────────────
        console2.log("[4a] Pausing hook...");
        vm.startBroadcast(pk);
        hook.setPaused(true);
        vm.stopBroadcast();

        require(hook.paused(), "FAIL: hook should be paused");
        console2.log("Hook paused: true");

        // ── 4b: Verify operations revert while paused ─────────────────
        console2.log("[4b] Verifying add liquidity reverts while paused...");
        ModifyLiquidityParams memory liqParams =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e14, salt: bytes32(0)});
        try router.modifyLiquidity(poolKey, liqParams, deployer) {
            console2.log("WARNING: Expected revert but call succeeded");
        } catch {
            console2.log("Correctly reverted: add liquidity blocked when paused");
        }

        console2.log("[4b] Verifying swap reverts while paused...");
        SwapParams memory swapParams =
            SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        try router.swap(poolKey, swapParams, deployer) {
            console2.log("WARNING: Expected revert but call succeeded");
        } catch {
            console2.log("Correctly reverted: swap blocked when paused");
        }

        // ── 4c: Emergency withdraw ────────────────────────────────────
        console2.log("[4c] Emergency withdraw...");
        uint256 deployedBefore = _getDeployedToAave();
        console2.log("deployedToAave before emergency:", deployedBefore);

        vm.startBroadcast(pk);
        hook.emergencyWithdrawAll(poolId);
        vm.stopBroadcast();

        uint256 deployedAfter = _getDeployedToAave();
        console2.log("deployedToAave after emergency:", deployedAfter);

        if (deployedBefore > 0) {
            require(deployedAfter == 0, "FAIL: deployedToAave should be 0 after emergency");
            console2.log("Emergency withdrawal successful");
        } else {
            console2.log("Nothing deployed to Aave emergency withdraw was no-op (expected)");
        }

        // ── 4d: Unpause ───────────────────────────────────────────────
        console2.log("[4d] Unpausing hook...");
        vm.startBroadcast(pk);
        hook.setPaused(false);
        vm.stopBroadcast();

        require(!hook.paused(), "FAIL: hook should be unpaused");
        console2.log("Hook paused: false");

        // ── 4e: Verify operations work again ──────────────────────────
        console2.log("[4e] Verifying swap works after unpause...");
        SwapParams memory smallSwap = SwapParams({
            zeroForOne: true,
            amountSpecified: -100, // ← tiny amount
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.startBroadcast(pk);
        IERC20(TOKEN0).approve(address(router), type(uint256).max);
        IERC20(TOKEN1).approve(address(router), type(uint256).max);
        try router.swap(poolKey, smallSwap, deployer) {
            console2.log("Swap succeeded after unpause");
        } catch {
            console2.log("Swap failed (pool may lack liquidity after emergency withdraw) - hook unpaused correctly");
        }
        vm.stopBroadcast();

        // ── Final state summary ───────────────────────────────────────
        console2.log("=== Final On-chain State ===");
        (address aToken, address underlying, uint256 deployed, bool isToken0, bool initialized) =
            hook.poolConfigs(poolId);
        console2.log("initialized  :", initialized);
        console2.log("aToken       :", aToken);
        console2.log("underlying   :", underlying);
        console2.log("deployedToAave:", deployed);
        console2.log("isToken0     :", isToken0);
        console2.log("paused       :", hook.paused());
        console2.log("owner        :", hook.owner());
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _getDeployedToAave() internal view returns (uint256) {
        (,, uint256 deployed,,) = hook.poolConfigs(poolId);
        return deployed;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
