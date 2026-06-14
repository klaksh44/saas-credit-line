# Frontend integration — connect a wallet, ready for demo

The contract is **live on Arc testnet** and the backend is wallet/browser-ready (CORS enabled).
A frontend only needs to wire to the values below — no backend changes required.

## Live deployment

| Thing | Value |
|---|---|
| Chain | **Arc testnet**, chainId **5042002** |
| RPC | `https://rpc.testnet.arc.network` |
| Explorer | `https://testnet.arcscan.app` |
| Pool contract (`StakeAndAdvance`) | `0xC18036FfFfa6D5A861EbA9bd1084b68BC3321c40` |
| USDC (ERC-20, 6 decimals) | `0x3600000000000000000000000000000000000000` |
| Company (borrower) | `0x19E95b026731974B7c1feD9eb3c3113fBDD80464` |

Already wired for you: `app/lib/addresses.ts` (defaults to the address above),
`app/lib/abi.ts` (full pool ABI), `app/lib/arcChain.ts` (viem chain object for wagmi/viem).

## Wallet setup
Add Arc testnet to the wallet (or use `arcTestnet` from `app/lib/arcChain.ts` with wagmi/viem, or a
Dynamic embedded wallet): Network name `Arc Testnet`, RPC `https://rpc.testnet.arc.network`,
chainId `5042002`, currency symbol `USDC`. Fund from `https://faucet.circle.com`.

## Backend API (run `npm run server`, listens on :8788, CORS `*`)
- `GET /health` — `{ok, chainId, contract, confidentialAi}`
- `GET /pool/state` — `{totalAssets, cash, outstandingPrincipal, totalShares, navPerShare1e18, creditCap, interestRateBps, dueAt, defaulted}`
- `POST /cre/underwrite` — body = company financials (`{vendor, monthlyRecurringRevenueUsd, grossMarginBps, cashBalanceUsd, monthlyBurnUsd, delinquencyRateBps, currentDepositedPrincipalUsdc}`); runs Chainlink underwriting and writes the cap + interest rate on-chain. Returns `{cap, interestRateBps, inference, txHash}`.

The frontend can read live state from `/pool/state` (no wallet needed) and trigger underwriting via
`/cre/underwrite`. All on-chain *writes by the user* go straight to the contract via their wallet:

## Contract calls a frontend makes (via the user's wallet)

**Member (the "bank"):**
- Deposit: `USDC.approve(pool, amount)` then `pool.deposit(amount)` → mints shares at NAV. (6-dp USDC; `10 USDC = 10000000`.)
- Redeem: `pool.redeem(shares)` → returns USDC at NAV (bounded by liquid `cash`). Preview with `previewRedeem(shares)`.
- Transfer: `pool.transferShares(to, shares)`.
- Reads: `sharesOf(addr)`, `navPerShare1e18()`, `previewRedeem(shares)`, `poolState()`.

**Company (borrower):**
- `pool.drawdown(amount)` (≤ `availableToBorrow()`), `pool.repay(amount)` (principal + `accruedInterest()`).
- Reads: `availableToBorrow()`, `creditCap()`, `interestRateBps()`, `accruedInterest()`, `trackRecord()`.

**Anyone:** `pool.markDefaulted()` once a loan is past `dueAt + defaultGracePeriod` (NAV drops).

## Recommended stack
- **viem + wagmi** (chain from `app/lib/arcChain.ts`, address + ABI from `app/lib/{addresses,abi}.ts`), or
- **Dynamic** embedded wallet for email/social onboarding — fund a customer and call `depositFor(member, amount)` from a relayer so non-crypto users can join. (`depositFor` is the on-chain seam.)

## Suggested first screen
A single **pool page**: hero = `navPerShare1e18` (NAV) + APR (`interestRateBps`), live from `/pool/state`;
a **Deposit** action (approve → deposit) and a **Your position** panel (`sharesOf × NAV`, Redeem). That one
screen tells the whole story. Company drawdown/repay can be a second screen.
