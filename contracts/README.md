# Steakhouse Contracts — Ecosystem Overview

This document is a concise, auditor-friendly overview of the Steakhouse "Kitchen" smart-contract ecosystem. It focuses on the design values, the contract-to-contract interaction map (CA → CA), and the normal user/creator flow from token creation through trading and graduation.

## Design values
- Simplicity: keep per-contract responsibilities narrow and explicit.
- Auditability: deterministic math (closed-form curve helpers), clear access control, and minimal on-chain state.
- Economic safety: conservative defaults (tax caps, minimum LP lock), explicit fee separation, and defensible upgrade/owner actions.
- Separation of concerns: metadata/storage (`KitchenStorage`) separated from execution (`KitchenBondingCurve`) and orchestration (`KitchenGraduation`).
- Minimal trust: graduation minting and LP handling are centralized to a controller but execute predictable, inspectable steps.

## Core contracts and responsibilities
- `Kitchen` (router): user-facing entrypoint that forwards creation, trading, and graduation requests.
- `KitchenFactory` / `KitchenCreator*`: writes token metadata and creation-time parameters into `KitchenStorage`.
- `KitchenStorage`: canonical store for token metadata and runtime `TokenState` (ethPool, circulatingSupply, graduated flag, timestamps, etc.). Also enforces authorized callers.
- `KitchenBondingCurve`: implements the bonding curve buy/sell logic, separates platform fee and curve tax, updates `TokenState`, records buyer allocations, and accumulates ETH for graduation.
- `KitchenGraduation`: orchestrates the conversion from virtual token to real token: deploys/mints the real token, airdrops buyers, adds liquidity via a router, and handles LP (lock or burn).
- `KitchenDeployer` / `KitchenFactory` (deployment helpers): deploy token contracts (`TaxToken`, `NoTaxToken`, header/headerless variants) and act as the minter for them during graduation.
- `KitchenUtils` / `KitchenCurveMaths`: pure helper libraries for fee/tax/limit calculations and closed-form curve math using the +1 ETH virtual reserve model.
- `SteakLockers`: LP locking service with minimum lock duration and fee collection.
- `TaxToken` / `NoTaxToken`: the real tokens minted at graduation. `TaxToken` includes swap-back-to-ETH logic for collected taxes.

## Contract-to-contract interaction map (CA → CA)
This map lists the primary cross-contract calls and their purpose.

- `Kitchen` → `KitchenFactory`:
  - `create*Token(...)` / `create*TokenStealth(...)` — forwards creator params (and ETH) so the factory persists metadata to `KitchenStorage`.

- `Kitchen` → `KitchenBondingCurve`:
  - `buyTokenFor{value}` / `sellTokenFor` — forwards trading requests; the bonding curve performs accounting and updates `KitchenStorage.TokenState`.

- `Kitchen` → `KitchenGraduation`:
  - `graduateToken(token)` — requests graduation orchestration (manual or forwarded from auto-graduation).

- `KitchenFactory` / `KitchenDeployer` → `KitchenStorage`:
  - Persist static token metadata (`setTokenBasic`, `setTokenAdvanced`, `setTokenSuperSimple`, `setTokenZeroSimple`) and initialize runtime state (`setTokenState`).

- `KitchenBondingCurve` → `KitchenStorage`:
  - Update runtime fields (`ethPool`, `circulatingSupply`, buyer records) and track `accruedEth` used by graduation.
  - Optionally call `KitchenGraduation.graduateToken(token)` (auto-graduation path) when cap and bounds are met.

- `KitchenGraduation` → `KitchenDeployer` / `KitchenFactory`:
  - `deployToken(...)` / `mintRealToken(...)` — deploy the real token contract and mint supply for airdrops/liquidity.

- `KitchenGraduation` → `IUniswapV2Router02` (external DEX router):
  - `addLiquidityETH` / `swap` calls to create token<>WETH pair and seed liquidity during graduation.

- `KitchenGraduation` → `SteakLockers`:
  - `lock(lpToken, amount, duration, creator)` — send LP tokens to the locker or burn them per configuration.

- `TaxToken` → `IUniswapV2Router02`:
  - `_swapBack(...)` uses a swap to convert accumulated tax tokens to ETH and forward to the `taxWallet`.

## Typical user / creator flow (step-by-step)
The following outlines the expected sequence from token creation through trading and graduation.

1. Creation
   - Creator calls `Kitchen.create*Token(...)` (or a stealth variant). `Kitchen` forwards to the `KitchenFactory`/`Creator` which:
     - Validates parameters (caps, tax limits, disallowed combinations).
     - Generates a deterministic virtual token id (off-chain-friendly address derived from creator + entropy).
     - Persists static metadata into `KitchenStorage` and pushes an initial `TokenState` (ethPool = 0, circulatingSupply = 0, start time).

2. Pre-trading setup
   - Off-chain tooling or frontends read `KitchenStorage` metadata to render the bonding curve page (fees, limits, start times).
   - Creators may set `removeHeader` (headerless preference) via `Kitchen.setHeaderlessPreference` if they own the token id.

3. Trading (buy / sell)
   - Buyers call `Kitchen.buyToken{value}(token)` which forwards to `KitchenBondingCurve.buyTokenFor{value}`.
     - Bonding curve applies platform fee (BPS) first, then curve tax (PERCENT) on the remainder.
     - The remaining ETH is converted to virtual tokens via closed-form math and assigned to buyer allocation.
     - `KitchenBondingCurve` updates `TokenState.ethPool` and `circulatingSupply` and records accruedEth for graduation.
     - If configured and bounds are met, the curve may auto-call `KitchenGraduation.graduateToken(token)` (auto-graduation); otherwise graduation is manual.

   - Sellers call `Kitchen.sellToken(token, amount)` which forwards to `KitchenBondingCurve.sellTokenFor`.
     - The curve computes gross ETH for the token amount, deducts platform fee and curve tax, and transfers net ETH to the seller.

4. Graduation (virtual → real token)
   - Trigger: either auto-graduation (from the curve) or manual call to `Kitchen.graduateToken(token)`.
   - `KitchenGraduation` performs an orchestrated sequence:
     1. Pulls required ETH from the curve accounting (`accruedEth` / `ethPool`).
     2. Uses `KitchenDeployer`/`Factory` to deploy the appropriate real token contract (`TaxToken` or `NoTaxToken`) and mints supply for airdrop and liquidity.
     3. Airdrops allocated token balances to buyers recorded by the curve.
     4. Calls the router (`IUniswapV2Router02.addLiquidityETH`) to create the token<>WETH pair and add liquidity.
     5. Either locks LP via `SteakLockers.lock` (preferred) or burns/transfers LP according to token config.
     6. Distributes fees to treasury/tax wallets and refunds any stipend to the caller (if applicable).
     7. Marks token as `graduated` in `KitchenStorage` to prevent further curve trading.

## Key auditor focus areas
- Closed-form math in `KitchenCurveMaths` (edge cases: zero supply, small liquidity).
- Fee ordering and rounding in `KitchenBondingCurve` and `KitchenUtils.quote*` helpers.
- Access control in `KitchenStorage` and who can authorize callers.
- Graduation orchestration in `KitchenGraduation` (token minting, router interactions, LP handling, and stipend behavior).
- `SteakLockers` minimum lock duration and fee enforcement.
- `TaxToken` swap-back logic: approvals, router usage, and reentrancy guard.

## Final notes
- The codebase follows a split-responsibility architecture: metadata and runtime state live in `KitchenStorage`, trading logic in `KitchenBondingCurve`, deployment in `KitchenDeployer/Factory`, and orchestration in `KitchenGraduation`.
- For auditors: follow the life of a token from `KitchenFactory.setToken*` → `KitchenBondingCurve` buy/sell flows → `KitchenGraduation` orchestration to validate invariants end-to-end.
