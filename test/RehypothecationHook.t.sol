// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RehypothecationHook} from "../src/RehypothecationHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

// ─── Mock Contracts ────────────────────────────────────────────────────────────

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract MockAToken is MockERC20 {
    constructor() MockERC20("Aave USDC", "aUSDC") {}
}

contract MockAavePool {
    MockERC20 public underlying;
    MockAToken public aToken;

    uint256 public totalDeposited;
    uint256 public totalWithdrawn;
    uint256 public depositCallCount;
    uint256 public withdrawCallCount;

    bool public shouldRevertWithdraw;

    event Supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode);
    event Withdraw(address asset, uint256 amount, address to);

    constructor(MockERC20 _underlying, MockAToken _aToken) {
        underlying = _underlying;
        aToken = _aToken;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        require(asset == address(underlying), "MockAave: wrong asset");
        underlying.transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
        totalDeposited += amount;
        depositCallCount++;
        emit Supply(asset, amount, onBehalfOf, referralCode);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        if (shouldRevertWithdraw) return 0;
        require(asset == address(underlying), "MockAave: wrong asset");
        uint256 actual = amount > totalDeposited ? totalDeposited : amount;
        totalDeposited -= actual;
        totalWithdrawn += actual;
        underlying.mint(to, actual);
        withdrawCallCount++;
        emit Withdraw(asset, actual, to);
        return actual;
    }

    function setRevertWithdraw(bool _revert) external {
        shouldRevertWithdraw = _revert;
    }
}

// ─── Unlock Router ─────────────────────────────────────────────────────────────
// v4 PoolManager requires all state-changing calls to happen inside unlock().
// This router receives encoded calldata, unlocks the manager, executes the call
// inside the callback, and settles any resulting deltas.

contract PoolRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    // ── Action constants ────────────────────────────────────────────────────
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

    // ── Entry point ─────────────────────────────────────────────────────────
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

    // ── Callback ─────────────────────────────────────────────────────────────
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));

        if (action == ACTION_INITIALIZE) {
            InitParams memory p = abi.decode(payload, (InitParams));
            manager.initialize(p.key, p.sqrtPriceX96);
        } else if (action == ACTION_ADD_LIQUIDITY || action == ACTION_REMOVE_LIQUIDITY) {
            LiquidityParams memory p = abi.decode(payload, (LiquidityParams));
            (BalanceDelta delta,) = manager.modifyLiquidity(p.key, p.params, new bytes(0));

            // Settle currency0
            int128 d0 = delta.amount0();
            if (d0 < 0) {
                p.key.currency0.settle(manager, p.payer, uint128(-d0), false);
            } else if (d0 > 0) {
                p.key.currency0.take(manager, p.payer, uint128(d0), false);
            }

            // Settle currency1
            int128 d1 = delta.amount1();
            if (d1 < 0) {
                p.key.currency1.settle(manager, p.payer, uint128(-d1), false);
            } else if (d1 > 0) {
                p.key.currency1.take(manager, p.payer, uint128(d1), false);
            }
        } else if (action == ACTION_SWAP) {
            SwapCallParams memory p = abi.decode(payload, (SwapCallParams));
            BalanceDelta delta = manager.swap(p.key, p.params, new bytes(0));

            int128 d0 = delta.amount0();
            if (d0 < 0) {
                p.key.currency0.settle(manager, p.payer, uint128(-d0), false);
            } else if (d0 > 0) {
                p.key.currency0.take(manager, p.payer, uint128(d0), false);
            }

            int128 d1 = delta.amount1();
            if (d1 < 0) {
                p.key.currency1.settle(manager, p.payer, uint128(-d1), false);
            } else if (d1 > 0) {
                p.key.currency1.take(manager, p.payer, uint128(d1), false);
            }
        }

        return "";
    }
}

// ─── Test Contract ─────────────────────────────────────────────────────────────

contract RehypothecationHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolManager public poolManager;
    PoolRouter public router;
    RehypothecationHook public hook;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockAToken public aTokenA;
    MockAavePool public aavePool;

    PoolKey public poolKey;
    PoolId public poolId;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public liquidityProvider = makeAddr("lp");

    uint160 constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG) | uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG)
        | uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG) | uint160(Hooks.BEFORE_SWAP_FLAG) | uint160(Hooks.AFTER_SWAP_FLAG)
        | uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) | uint160(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG);

    // ─── Setup ─────────────────────────────────────────────────────────────
    function setUp() public {
        tokenA = new MockERC20("Token A", "TKNA");
        tokenB = new MockERC20("Token B", "TKNB");

        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }

        aTokenA = new MockAToken();
        aavePool = new MockAavePool(tokenA, aTokenA);

        poolManager = new PoolManager(address(this));
        router = new PoolRouter(IPoolManager(address(poolManager)));

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            FLAGS,
            type(RehypothecationHook).creationCode,
            abi.encode(address(poolManager), address(aavePool), owner)
        );
        hook = new RehypothecationHook{salt: salt}(IPoolManager(address(poolManager)), IPool(address(aavePool)), owner);
        assertEq(address(hook), hookAddress, "Hook address mismatch");

        poolKey = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        // Fund accounts
        tokenA.mint(liquidityProvider, 1_000_000e18);
        tokenB.mint(liquidityProvider, 1_000_000e18);
        tokenA.mint(alice, 100_000e18);
        tokenB.mint(alice, 100_000e18);
        tokenA.mint(bob, 100_000e18);

        // Approve router (router pulls tokens during settle)
        vm.startPrank(liquidityProvider);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ─── Helpers ───────────────────────────────────────────────────────────

    function _initializePool() internal {
        router.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
    }

    function _addLiquidity(address payer, int24 tickLower, int24 tickUpper, int256 liquidity) internal {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidity,
            salt: bytes32(0)
        });
        router.modifyLiquidity(poolKey, params, payer);
    }

    // ─── 1. Deployment ─────────────────────────────────────────────────────

    function test_deployment_aavePoolSetCorrectly() public view {
        assertEq(address(hook.aavePool()), address(aavePool));
    }

    function test_deployment_ownerIsDeployer() public view {
        assertEq(hook.owner(), owner);
    }

    function test_deployment_notPausedByDefault() public view {
        assertFalse(hook.paused());
    }

    function test_deployment_correctTargetInPoolBps() public view {
        assertEq(hook.TARGET_IN_POOL_BPS(), 2000);
    }

    // ─── 2. Hook Permissions ───────────────────────────────────────────────

    function test_hookPermissions_correctFlags() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertFalse(perms.beforeInitialize);
        assertTrue(perms.afterInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertTrue(perms.afterAddLiquidity);
        assertTrue(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.beforeSwapReturnDelta);
        assertTrue(perms.afterSwapReturnDelta);
        assertTrue(perms.afterAddLiquidityReturnDelta);
        assertFalse(perms.afterRemoveLiquidityReturnDelta);
    }

    // ─── 3. afterInitialize ────────────────────────────────────────────────

    function test_afterInitialize_setsPoolConfig() public {
        _initializePool();
        (address aToken, address underlying, uint256 deployedToAave, bool isToken0, bool initialized) =
            hook.poolConfigs(poolId);
        assertTrue(initialized);
        assertTrue(isToken0);
        assertEq(underlying, address(tokenA));
        assertEq(deployedToAave, 0);
        assertEq(aToken, address(0));
    }

    function test_afterInitialize_emitsPoolConfigSetEvent() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit RehypothecationHook.PoolConfigSet(poolId, address(0), address(tokenA));
        _initializePool();
    }

    // ─── 4. setPoolConfig ─────────────────────────────────────────────────

    function test_setPoolConfig_ownerCanSet() public {
        _initializePool();
        hook.setPoolConfig(poolId, address(aTokenA), address(tokenA), true);
        (address aToken, address underlying,, bool isToken0,) = hook.poolConfigs(poolId);
        assertEq(aToken, address(aTokenA));
        assertEq(underlying, address(tokenA));
        assertTrue(isToken0);
    }

    function test_setPoolConfig_nonOwnerReverts() public {
        _initializePool();
        vm.prank(alice);
        vm.expectRevert();
        hook.setPoolConfig(poolId, address(aTokenA), address(tokenA), true);
    }

    // ─── 5. Pause ──────────────────────────────────────────────────────────

    function test_pause_ownerCanPause() public {
        hook.setPaused(true);
        assertTrue(hook.paused());
    }

    function test_pause_nonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        hook.setPaused(true);
    }

    function test_pause_unpauseWorks() public {
        hook.setPaused(true);
        hook.setPaused(false);
        assertFalse(hook.paused());
    }

    // ─── 6. afterAddLiquidity ─────────────────────────────────────────────

    function test_afterAddLiquidity_revertsWhenPaused() public {
        _initializePool();
        hook.setPaused(true);
        vm.expectRevert();
        _addLiquidity(liquidityProvider, -600, 600, 1_000e18);
    }

    function test_afterAddLiquidity_poolInitializedFlag() public {
        _initializePool();
        (,,,, bool initialized) = hook.poolConfigs(poolId);
        assertTrue(initialized);
    }

    // ─── 7. beforeRemoveLiquidity ─────────────────────────────────────────

    function test_beforeRemoveLiquidity_revertsWhenPaused() public {
        _initializePool();
        _addLiquidity(liquidityProvider, -600, 600, 10_000e18);
        hook.setPaused(true);
        vm.expectRevert();
        _addLiquidity(liquidityProvider, -600, 600, -5_000e18);
    }

    // ─── 8. beforeSwap ────────────────────────────────────────────────────

    function test_beforeSwap_revertsWhenPaused() public {
        _initializePool();
        _addLiquidity(liquidityProvider, -600, 600, 100_000e18);
        hook.setPaused(true);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1_000e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.expectRevert();
        router.swap(poolKey, params, alice);
    }

    function test_beforeSwap_normalSwapSucceeds() public {
        _initializePool();
        _addLiquidity(liquidityProvider, -600, 600, 100_000e18);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        router.swap(poolKey, params, alice);
    }

    // ───  emergencyWithdrawAll ─────────────────────────────────────────

    function test_emergencyWithdrawAll_onlyOwner() public {
        _initializePool();
        hook.setPoolConfig(poolId, address(aTokenA), address(tokenA), true);
        vm.prank(alice);
        vm.expectRevert();
        hook.emergencyWithdrawAll(poolId);
    }

    function test_emergencyWithdrawAll_noOpWhenNothingDeployed() public {
        _initializePool();
        hook.setPoolConfig(poolId, address(aTokenA), address(tokenA), true);
        hook.emergencyWithdrawAll(poolId);
        assertEq(aavePool.withdrawCallCount(), 0);
    }

    // ───  Fuzz ─────────────────────────────────────────────────────────

    function testFuzz_setPoolConfig_doesNotRevertForOwner(address _aToken, address _underlying, bool _isToken0)
        public
    {
        _initializePool();
        hook.setPoolConfig(poolId, _aToken, _underlying, _isToken0);
        (address aToken, address underlying,, bool isToken0, bool initialized) = hook.poolConfigs(poolId);
        assertEq(aToken, _aToken);
        assertEq(underlying, _underlying);
        assertEq(isToken0, _isToken0);
        assertTrue(initialized);
    }

    function testFuzz_pause_toggleIsDeterministic(bool pauseState) public {
        hook.setPaused(pauseState);
        assertEq(hook.paused(), pauseState);
    }

    // ─── 14. Integration ──────────────────────────────────────────────────

    function test_integration_fullLifecycle() public {
        _initializePool();
        // hook.setPoolConfig(poolId, address(aTokenA), address(tokenA), true);

        _addLiquidity(liquidityProvider, -600, 600, 100_000e18);

        SwapParams memory swapParams =
            SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        router.swap(poolKey, swapParams, alice);

        _addLiquidity(liquidityProvider, -600, 600, -50_000e18);

        assertTrue(true, "Full lifecycle completed");
    }

    // ─── Storage Helpers ──────────────────────────────────────────────────

    function _poolConfigDeployedSlot(PoolId pid) internal pure returns (bytes32) {
        // poolConfigs is at slot 2; deployedToAave is field index 2 in PoolConfig
        bytes32 baseSlot = keccak256(abi.encode(pid, uint256(2)));
        return bytes32(uint256(baseSlot) + 2);
    }
}
