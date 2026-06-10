// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
// import {IPoolManager, SwapParams, ModifyLiquidityParams} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract RehypothecationHook is BaseHook, ReentrancyGuard, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // ─── State ────────────────────────────────────────────────────────────
    IPool public immutable aavePool;

    struct PoolConfig {
        address aToken;          // Aave aToken for the pool asset
        address underlying;      // The actual ERC20 token
        uint256 deployedToAave;  // Amount currently in Aave (in underlying units)
        bool isToken0;           // Which token of the pair goes to Aave
        bool initialized;
    }

    mapping(PoolId => PoolConfig) public poolConfigs;
    uint256 public constant TARGET_IN_POOL_BPS = 2000; // 20% stays in pool, 80% to Aave
    bool public paused;

    // ─── Errors ────────────────────────────────────────────────────────────
    error HookPaused();
    error PoolNotInitialized();
    error AaveWithdrawFailed();

    // ─── Events ────────────────────────────────────────────────────────────
    event AaveDeposited(PoolId indexed poolId, uint256 amount);
    event AaveWithdrawn(PoolId indexed poolId, uint256 amount, string reason);
    event PoolConfigSet(PoolId indexed poolId, address aToken, address underlying);

    constructor(
        IPoolManager _manager,
        IPool _aavePool,
        address _owner
    ) BaseHook(_manager) Ownable(_owner) {
        aavePool = _aavePool;
    }

    // ─── Hook Permissions ──────────────────────────────────────────────────
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Hook Callbacks ────────────────────────────────────────────────────

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal override returns (bytes4) {
        address token0 = Currency.unwrap(key.currency0);
        PoolId poolId = key.toId();

        poolConfigs[poolId].underlying = token0;
        poolConfigs[poolId].isToken0 = true;
        poolConfigs[poolId].initialized = true;

        emit PoolConfigSet(poolId, address(0), token0);
        return BaseHook.afterInitialize.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        if (paused) revert HookPaused();

        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];
        if (!config.initialized) revert PoolNotInitialized();


        // Use delta directly — negative means tokens flowed INTO the pool
        int128 amount = config.isToken0 ? delta.amount0() : delta.amount1();
        uint256 deposited = 0;

        if (amount < 0 && config.aToken != address(0)) {
            uint256 inflow = uint256(int256(-amount));
            // Deposit 80% to Aave, keep 20% in pool
            uint256 toDeposit = (inflow * (10000 - TARGET_IN_POOL_BPS)) / 10000;
            if (toDeposit > 0) {
                deposited = _depositToAave(poolId, config, toDeposit);
            }
        }

        BalanceDelta hookDelta = config.isToken0
            ? toBalanceDelta(int128(int256(deposited)), 0)
            : toBalanceDelta(0, int128(int256(deposited)));

        return (BaseHook.afterAddLiquidity.selector, hookDelta);
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        if (paused) revert HookPaused();

        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];

        uint256 neededAmount = _estimateWithdrawNeeded(key, params, config);
        if (neededAmount > 0 && config.deployedToAave > 0 && config.aToken != address(0)) {
            uint256 toWithdraw = neededAmount > config.deployedToAave
                ? config.deployedToAave
                : neededAmount;
            _withdrawFromAave(poolId, config, toWithdraw, "beforeRemoveLiquidity");
             _returnToPoolManager(config.underlying, toWithdraw); 
        }

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (paused) revert HookPaused();

        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];

            if (config.deployedToAave > 0 && config.aToken != address(0)) {
            Currency currency = config.isToken0 ? key.currency0 : key.currency1;
            uint256 poolReserve = currency.balanceOf(address(poolManager));

            uint256 swapAmount = params.amountSpecified < 0
                ? uint256(-params.amountSpecified)
                : uint256(params.amountSpecified);

            if (poolReserve < (swapAmount * 150) / 100) {
                uint256 deficit = (swapAmount * 150) / 100 - poolReserve;
                uint256 toWithdraw = deficit > config.deployedToAave
                    ? config.deployedToAave
                    : deficit;
                _withdrawFromAave(poolId, config, toWithdraw, "beforeSwap");
                _returnToPoolManager(config.underlying, toWithdraw);
            }
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (paused) revert HookPaused();
        return (BaseHook.afterSwap.selector, 0);
        // if (paused) revert HookPaused();

        // PoolId poolId = key.toId();
        // PoolConfig storage config = poolConfigs[poolId];

        // uint256 deposited = 0;
        // if (config.aToken != address(0)) {
        //     // After zeroForOne swap, token0 flows IN (negative delta = pool received token0)
        //     int128 amount = config.isToken0 ? delta.amount0() : delta.amount1();
        //     if (amount < 0) {
        //         uint256 inflow = uint256(int256(-amount));
        //         uint256 toDeposit = (inflow * (10000 - TARGET_IN_POOL_BPS)) / 10000;
        //         if (toDeposit > 0) {
        //             deposited = _depositToAave(poolId, config, toDeposit);
        //         }
        //     }
        // }

        // int128 hookDelta = config.isToken0
        //     ? int128(int256(deposited))
        //     : int128(0);

        // return (BaseHook.afterSwap.selector, hookDelta);
    }

    // ─── Internal Helpers ──────────────────────────────────────────────────

    function _depositToAave(
        PoolId poolId,
        PoolConfig storage config,
        uint256 amount
    ) internal returns (uint256) {

         poolManager.take(Currency.wrap(config.underlying), address(this), amount);
        // Approve and deposit to Aave
        IERC20(config.underlying).approve(address(aavePool), amount);
        
         // AFTER
        try aavePool.supply(config.underlying, amount, address(this), 0) {
            config.deployedToAave += amount;
            emit AaveDeposited(poolId, amount);
            return amount;  // ← signals to caller how much was consumed
        } catch {
            IERC20(config.underlying).approve(address(aavePool), 0);
            IERC20(config.underlying).transfer(address(poolManager), amount);
            poolManager.sync(Currency.wrap(config.underlying));
            poolManager.settle();
            return 0;  // ← nothing was consumed, PoolManager made whole
        }
    }

    function _withdrawFromAave(
        PoolId poolId,
        PoolConfig storage config,
        uint256 amount,
        string memory reason
    ) internal {
        uint256 withdrawn = aavePool.withdraw(config.underlying, amount, address(this));
        if (withdrawn == 0) revert AaveWithdrawFailed();


        config.deployedToAave = config.deployedToAave > withdrawn
            ? config.deployedToAave - withdrawn
            : 0;
        emit AaveWithdrawn(poolId, withdrawn, reason);
    }

    function _returnToPoolManager(
        address underlying, 
        uint256 amount
        ) internal {
        IERC20(underlying).transfer(address(poolManager), amount);
        poolManager.sync(Currency.wrap(underlying));
        poolManager.settle();
    }

    // 
    // function _computeIdleAmount(
    //     PoolKey calldata key,
    //     PoolConfig storage config
    // ) internal view returns (uint256) {
    //     uint256 poolBalance = _getPoolReserve(key, config);
    //     uint256 targetInPool = (poolBalance * TARGET_IN_POOL_BPS) / 10000;
    //     if (poolBalance > targetInPool + config.deployedToAave) {
    //         return poolBalance - targetInPool - config.deployedToAave;
    //     }
    //     return 0;
    // }

    // function _getPoolReserve(
    //     PoolKey calldata key,
    //     PoolConfig storage config
    // ) internal view returns (uint256) {
    //     if (config.isToken0) {
    //         return key.currency0.balanceOf(address(poolManager));
    //     } else {
    //         return key.currency1.balanceOf(address(poolManager));
    //     }
    // }

    function _estimateWithdrawNeeded(
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        PoolConfig storage config
    ) internal view returns (uint256) {
        return config.deployedToAave / 10;
    }

    // ─── Admin ─────────────────────────────────────────────────────────────

    function setPoolConfig(
        PoolId poolId,
        address aToken,
        address underlying,
        bool isToken0
    ) external onlyOwner {
        poolConfigs[poolId].aToken = aToken;
        poolConfigs[poolId].underlying = underlying;
        poolConfigs[poolId].isToken0 = isToken0;
        poolConfigs[poolId].initialized = true;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function emergencyWithdrawAll(PoolId poolId) external onlyOwner {
        PoolConfig storage config = poolConfigs[poolId];
        if (config.deployedToAave > 0) {
            _withdrawFromAave(poolId, config, config.deployedToAave, "emergency");
        }
    }
}
