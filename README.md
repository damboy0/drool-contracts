# Drool Protocol

**Synthetic fixed-rate interest rate swaps, powered by Uniswap v4 hooks and Aave rehypothecation.**

Drool lets users lock in a fixed interest rate on any variable-rate DeFi yield — or take the other side and earn leveraged exposure to floating rates. Idle liquidity in the protocol is automatically deployed to Aave to earn yield, making capital more efficient for all participants.

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [Contracts](#contracts)
- [Deployed Addresses](#deployed-addresses)
- [Getting Started](#getting-started)
- [Running Tests](#running-tests)
- [Deployment](#deployment)
- [On-chain Interaction](#on-chain-interaction)
- [Known Limitations](#known-limitations)
- [Frontend Integration](#frontend-integration)
- [License](#license)

---

## Overview

Interest rate volatility is one of the biggest risks in DeFi. A protocol offering 8% APY today might drop to 3% tomorrow, destroying the assumptions of anyone who budgeted around it. Drool solves this with **synthetic interest rate swaps (IRS)**:

- **Fixed receiver** — pays the floating rate, receives a fixed rate. Locks in certainty.
- **Floating receiver** — pays a fixed rate, receives the floating rate. Takes leveraged rate exposure.

Unlike traditional IRS protocols, Drool deploys idle LP liquidity into Aave via a Uniswap v4 hook, generating additional yield for liquidity providers on top of swap fees.

---

## How It Works

### Interest Rate Swap mechanics

1. A user opens a swap as the **fixed receiver** for a given notional amount and term.
   - The contract quotes a fixed rate: `currentFloatingRate + 1% spread`.
   - The user deposits a margin (e.g. `notional × fixedRate × term / leverage`).

2. A counterparty takes the **floating side**, depositing their own margin plus a liquidation bounty.

3. At term end, `settlePosition()` is called:
   - If floating rate outpaced fixed → floating receiver wins, receives payment from fixed margin.
   - If fixed rate outpaced floating → fixed receiver wins, receives payment from floating margin.

### Rehypothecation via Uniswap v4 Hook

The `RehypothecationHook` intercepts Uniswap v4 pool lifecycle events:

```
afterAddLiquidity  → deposits 80% of idle LP tokens to Aave
beforeRemoveLiquidity → withdraws enough from Aave to cover the removal
beforeSwap         → withdraws from Aave if pool reserve is too low to fill the swap
afterSwap          → rebalances: redeposits any new idle to Aave
```

This means LP capital is never idle — it earns Aave yield while sitting between swaps.

### Rate Oracle

The `CumulativeRateOracle` tracks a cumulative rate index (in ray, 1e27) that grows continuously at the current floating rate. Settlement math uses the index ratio between entry and exit to compute exact obligations — the same pattern used by Aave's own interest accrual.

---

## Architecture

```
drool/
├── src/
│   ├── RehypothecationHook.sol     # Uniswap v4 hook — deploys LP liquidity to Aave
│   ├── SwapSingleton.sol           # Core IRS engine — open, match, settle, liquidate
│   ├── CumulativeRateOracle.sol    # Cumulative rate index + TWAR
│   ├── interfaces/
│   │   └── ICumulativeRateOracle.sol
│   └── libraries/
│       └── MarginMath.sol          # Margin requirement and settlement math
├── script/
│   ├── DeployRehypothecationHook.s.sol   # Hook deployment (CREATE2 + ownership fix)
│   ├── DeployProtocol.s.sol              # Oracle + SwapSingleton + first market
│   ├── InteractRehypothecationHook.s.sol # On-chain hook config + test flows
│   └── InteractProtocol.s.sol            # On-chain IRS test flows (Steps 1–6)
├── test/
│   └── RehypothecationHook.t.sol   # Foundry unit + fuzz tests for the hook
├── foundry.toml
└── README.md
```

### Contract interaction diagram

```
User
 │
 ├──► SwapSingleton.openSwap()
 │         │
 │         ├── pulls margin from user (USDC via safeTransferFrom)
 │         ├── queries CumulativeRateOracle.getTWAR() for rate quote
 │         └── stores Position struct
 │
 ├──► SwapSingleton.takeFloatingSide()
 │         │
 │         └── matches counterparty, locks floating margin + bounty
 │
 ├──► SwapSingleton.settlePosition()  (after termEnd)
 │         │
 │         ├── queries CumulativeRateOracle.getIndex() for final value
 │         └── transfers net settlement to winner, returns margins
 │
 └──► Uniswap v4 Pool  ◄──── RehypothecationHook (intercepts callbacks)
           │                        │
           │                        ├── afterAddLiquidity → Aave.supply()
           │                        ├── beforeRemoveLiquidity → Aave.withdraw()
           │                        └── beforeSwap → Aave.withdraw() if pool low
           │
           └──► Aave v3 Pool (idle LP capital earns yield here)
```

---

## Contracts

### `RehypothecationHook.sol`

A Uniswap v4 hook that rehypothecates idle pool liquidity into Aave.

| Function | Description |
|---|---|
| `setPoolConfig(poolId, aToken, underlying, isToken0)` | Owner: configure which token goes to Aave |
| `setPaused(bool)` | Owner: emergency pause all hook callbacks |
| `emergencyWithdrawAll(poolId)` | Owner: pull all capital from Aave immediately |
| `poolConfigs(poolId)` | Read: aToken, underlying, deployedToAave, isToken0, initialized |

**Hook permissions enabled:** `afterInitialize`, `afterAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`, `afterSwap`

**Key constant:** `TARGET_IN_POOL_BPS = 2000` — 20% of liquidity stays in pool, 80% goes to Aave.

---

### `SwapSingleton.sol`

The core interest rate swap engine.

| Function | Caller | Description |
|---|---|---|
| `createMarket(asset, termEnd, leverage, oracle, liqBps)` | Owner | Create a new swap market |
| `openSwap(marketId, notional, isFixed, onBehalfOf)` | Anyone | Open fixed-receiver position, locks margin |
| `takeFloatingSide(positionId, onBehalfOf)` | Anyone | Match an open position, locks floating margin + bounty |
| `settlePosition(positionId)` | Anyone | Settle after termEnd, distribute net payment |
| `liquidate(positionId)` | Anyone | Liquidate undercollateralised position, earn bounty |
| `deactivateMarket(marketId)` | Owner | Disable new positions in a market |

**Position states:**

```
Created (openSwap) → Matched (takeFloatingSide) → Settled (settlePosition or liquidate)
```

---

### `CumulativeRateOracle.sol`

Tracks a compounding cumulative rate index.

| Function | Description |
|---|---|
| `advanceIndex()` | Anyone: advance index based on elapsed time and current rate |
| `getIndex(timestamp)` | View: returns current index (simple implementation returns latest) |
| `getTWAR(lookbackSeconds)` | View: time-weighted average rate (returns `lastRateBps` in MVP) |
| `setManualRate(rateBps)` | Owner: set rate manually (for testing / Chainlink fallback) |

**Index precision:** Ray (1e27). Starting value: `1e27` (= 1.0).

---

### `MarginMath.sol`

Pure library with no state. Used by `SwapSingleton`.

| Function | Description |
|---|---|
| `requiredFixedMargin(notional, fixedRate, term, leverage)` | Margin for fixed side |
| `requiredFloatingMargin(notional, floatRate, term, leverage, bounty)` | Margin for floating side |
| `netSettlement(notional, fixedRate, entryIndex, currentIndex, elapsed)` | Net P&L at settlement |

---

## Deployed Addresses

**Network: Sepolia (chain ID 11155111)**

| Contract | Address |
|---|---|
| `RehypothecationHook` | [`0x8A8E480ECc983282a810fE65B5fD5A15ED0b96c0`](https://sepolia.etherscan.io/address/0x8A8E480ECc983282a810fE65B5fD5A15ED0b96c0) |
| `CumulativeRateOracle` | [`0x239B0AD6c22e8508713df9eF53360B5f970Cd666`](https://sepolia.etherscan.io/address/0x239B0AD6c22e8508713df9eF53360B5f970Cd666) |
| `SwapSingleton` | [`0x7d6a9c2cE05505f54bC8E05781d5b09b5f2bE4eE`](https://sepolia.etherscan.io/address/0x7d6a9c2cE05505f54bC8E05781d5b09b5f2bE4eE) |
| Uniswap v4 PoolManager | `0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A` |
| Aave v3 Pool | `0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951` |
| Underlying (USDC) | `0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8` |
| Market 0 | USDC / 30-day term |

**Verified on-chain state (from test run):**
```
Position #0
  notional         : 10,000 USDC
  fixedRateBps     : 400  (4.00%)
  fixedMargin      : $3.29
  floatingMargin   : $2.47
  liquidationBounty: $10.00
  floatingSideTaken: true
  settled          : false
```

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js 18+ (for frontend)
- An Alchemy or Infura Sepolia RPC URL
- A funded Sepolia wallet

### Install

```bash
git clone https://github.com/your-org/drool
cd drool
forge install
```

### Configure

Copy the example env file and fill in your values:

```bash
cp .env.deploy.example .env
```

```bash
# .env
PRIVATE_KEY=0x...
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
ETHERSCAN_API_KEY=YOUR_KEY

# Sepolia
POOL_MANAGER_ADDRESS=0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A
AAVE_POOL_ADDRESS=0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951
TOKEN0_ADDRESS=0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8
TOKEN1_ADDRESS=0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c
ATOKEN_ADDRESS=0x16dA4541aD1807f4443d92D26044C1147406EB80
```

---

## Running Tests

```bash
# All tests
forge test --mp test/RehypothecationHook.t.sol -vvvv

# Specific test
forge test --match-test test_afterInitialize_setsPoolConfig -vvvv

# With gas report
forge test --mp test/RehypothecationHook.t.sol --gas-report
```

**Test coverage:**

| Group | Tests |
|---|---|
| Deployment | owner, aavePool, paused flag, TARGET_IN_POOL_BPS |
| Hook permissions | all 14 permission flags |
| afterInitialize | pool config state, event emission |
| setPoolConfig | owner access, non-owner revert |
| Pause / Unpause | toggle, non-owner revert |
| afterAddLiquidity | paused guard, Aave deposit |
| beforeRemoveLiquidity | paused guard, Aave withdrawal |
| beforeSwap | paused guard, insufficient liquidity withdrawal |
| afterSwap | redeposit after swap |
| emergencyWithdrawAll | owner-only, full drain, no-op when empty |
| AaveWithdrawFailed | reverts when Aave returns 0 |
| BPS logic | 80/20 split invariant |
| Fuzz | setPoolConfig arbitrary inputs, pause toggle |
| Integration | full lifecycle: init → add → swap → remove |

---

## Deployment

### Deploy the hook

The hook uses CREATE2 for a deterministic address encoding its permission flags. Foundry routes CREATE2 through `0x4e59b44847b379578588920cA78FbF26c0B4956C`, so ownership is transferred to the deployer immediately after deployment.

```bash
forge script script/DeployRehypothecationHook.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=11155111" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

### Deploy the protocol (Oracle + SwapSingleton + Market)

```bash
forge script script/DeployProtocol.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=11155111" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

After deployment, add the printed addresses to your `.env`:
```bash
ORACLE_ADDRESS=0x...
SWAP_SINGLETON_ADDRESS=0x...
MARKET_ID=0
```

> **Note:** The hook constructor takes a third `_owner` argument — this is the EOA deployer. The `transferOwnership` call in the deployment script handles the CREATE2 factory ownership issue automatically.

---

## On-chain Interaction

Both interaction scripts support a `STEP` environment variable to run individual steps.

### Hook interaction

```bash
# Full flow: config → add liquidity → swap → emergency test
STEP=all forge script script/InteractRehypothecationHook.s.sol \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv

# Individual steps
STEP=1 forge script ...   # setPoolConfig + verify state
STEP=2 forge script ...   # add liquidity, verify Aave deposit
STEP=3 forge script ...   # swap, verify beforeSwap + afterSwap fired
STEP=4 forge script ...   # pause, emergency withdraw, unpause
```

### Protocol interaction

```bash
# All steps: verify → oracle → openSwap → takeFloat → health check
STEP=all forge script script/InteractProtocol.s.sol \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv

# Individual steps
STEP=1 forge script ...              # verify deployment state
STEP=2 forge script ...              # advance oracle index
STEP=3 forge script ...              # open swap (fixed side)
POSITION_ID=0 STEP=4 forge script ... # take floating side
POSITION_ID=0 STEP=5 forge script ... # liquidation health check

# After market termEnd (30 days):
POSITION_ID=0 forge script script/InteractProtocol.s.sol \
  --sig "settleAfterExpiry()" \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
```

---

## Known Limitations

These are known gaps relative to the full PRD, deferred for post-hackathon:

| # | Gap | Impact | Phase |
|---|---|---|---|
| 1 | `_depositToAave` calls `poolManager.take()` but token flow needs further testing under edge cases | Deposit may silently fail on certain pool states | Phase 1 |
| 2 | No tick-range awareness — hook deposits based on flat 20% heuristic, not actual out-of-range liquidity (FR-RH-01/02) | Less capital-efficient than spec | Phase 1 |
| 3 | `getTWAR()` returns `lastRateBps` until enough snapshots accumulate | Rate display is static on fresh deployments | Phase 2 |
| 4 | `getIndex(timestamp)` always returns current index regardless of timestamp | Past-timestamp interpolation not implemented | Phase 2 |
| 5 | No Chainlink integration — oracle rate set manually via `setManualRate()` | Rate doesn't auto-track real Aave rate | Phase 2 |
| 6 | No position NFT minting | Portfolio tracking is by address scan only | Phase 2 |
| 7 | `setTargetUtilization()` not implemented — 80/20 split is hardcoded | Admins cannot tune utilization ratio | Phase 3 |

---

## Frontend Integration

The frontend lives at [`damboy0/drool-FE`](https://github.com/damboy0/drool-FE).

Quick setup:

```bash
# In the frontend repo
cp .env.example .env.local

# Add these to .env.local:
NEXT_PUBLIC_CHAIN_ID=11155111
NEXT_PUBLIC_ORACLE_ADDRESS=0x239B0AD6c22e8508713df9eF53360B5f970Cd666
NEXT_PUBLIC_SINGLETON_ADDRESS=0x7d6a9c2cE05505f54bC8E05781d5b09b5f2bE4eE
NEXT_PUBLIC_HOOK_ADDRESS=0x8A8E480ECc983282a810fE65B5fD5A15ED0b96c0
NEXT_PUBLIC_USDC_ADDRESS=0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8
NEXT_PUBLIC_MARKET_ID=0
```


---

## License

MIT