# Stake-and-Advance — *your customers are the bank*

A per-company **credit pool** on Circle's **Arc** L1. A company's customers deposit USDC and receive
**NAV-based yield-bearing shares**; the pool lends an **AI-underwritten, undercollateralized credit
line** to that one company. Drawdowns accrue **interest**, which lifts the pool's net asset value so
every share is worth more — and a **default** writes down principal so NAV falls. **The depositors,
the lenders, and the company's customers are the same people.** They earn the bank's spread instead of
paying it, and they bear the credit risk like a bank.

This is **debt, not equity** (returns track credit activity, not a cap table), **undercollateralized**
(unlike Aave — the company borrows money it doesn't already have), and **single-company / community**
(unlike Maple's institutional LPs — the lenders are the customers).

## Two load-bearing integrations + two access seams

| Leg | What it does | Where |
|---|---|---|
| **Arc** (smart contract) | the pool: deposit→shares at NAV, redeem at NAV, interest-bearing drawdown/repay, permissionless time-based default write-down — all in USDC | `contracts/src/StakeAndAdvance.sol` |
| **Chainlink** (Confidential AI) | a CRE workflow underwrites the company's **credit cap *and* interest rate** from confidential financials; delivered on-chain by an authorized reporter (Arc has no KeystoneForwarder) via `onReport` and gates all borrowing | `cre/`, `server/underwrite.ts`, `onReport` |
| **Dynamic** *(access seam)* | embedded-wallet / relayer funding: `depositFor(member, amount)` lets a relayer pay in and credit a customer's shares — the on-chain hook is in place | `contracts/src/StakeAndAdvance.sol:depositFor` |
| **Unlink** *(privacy seam)* | confidential balances/positions: "confidential-in (Chainlink) → private on-chain". Documented integration point, not yet wired to the live SDK | (roadmap) |

> World ID was **removed**: the original "one free subscription per human" gate had no job once
> joining costs real USDC (money is the gate). See `docs/decisions.md`.

No frontend. Everything is exercised from the terminal (Foundry tests, an end-to-end runner, and
curl-able HTTP endpoints).

## Toolchain is project-local

Foundry installs to `./.foundry/bin` and its solc/cache live under `./.localhome`; node deps live in
`./node_modules`. **Delete this folder and everything is gone** — nothing is installed globally.

If `./.foundry/bin` is missing, reinstall locally:
```bash
mkdir -p .foundry/bin
curl -fL https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_darwin_arm64.tar.gz \
  | tar -xz -C .foundry/bin
npm install
```

## Commands

```bash
npm run build        # forge build (project-local toolchain)
npm test             # forge test  -> 26 passing
npm run e2e:local    # full lifecycle on a throwaway anvil, driven via the HTTP API
npm run server       # standalone backend (reads .env); curl the endpoints
npm run deploy:arc   # forge script deploy to Arc testnet (reads .env)
```

### End-to-end (the proof)

```bash
npm run e2e:local
```
Boots anvil, deploys MockUSDC + StakeAndAdvance, starts the backend in-process, then runs:
underwrite (Chainlink → cap + interest rate on-chain) → two members deposit (NAV shares) →
company drawdown → time passes + repay-with-interest (**NAV rises**) → member redeems at a **profit**
→ second drawdown → default after grace (**NAV falls**) → remaining member redeems at a **loss**.
Asserts balances/NAV/state (24 assertions) and exits non-zero on any failure.

### Curl the endpoints yourself

```bash
npm run server:local   # boots anvil + deploys + runs the server on :8788
```
Then:
```bash
curl localhost:8788/health
curl localhost:8788/pool/state
curl -X POST localhost:8788/cre/underwrite -H 'content-type: application/json' \
  -d '{"vendor":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","currentDepositedPrincipalUsdc":250,"monthlyRecurringRevenueUsd":5000,"grossMarginBps":8000,"cashBalanceUsd":50000,"monthlyBurnUsd":20000,"delinquencyRateBps":100}'
```

## API endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | config + mode |
| GET | `/pool/state` | live pool snapshot: `{totalAssets, cash, outstandingPrincipal, totalShares, navPerShare1e18, creditCap, interestRateBps, dueAt, defaulted}` |
| POST | `/cre/underwrite` | run confidential underwriting; deliver the signed cap + rate on-chain (`onReport`). Returns `{cap, interestRateBps, inference, txHash}` |

## How the money works

- **NAV (cash basis):** `totalAssets = cash + outstandingPrincipal`. Shares mint/redeem at
  `assets × totalShares / totalAssets`. Accrued-but-unpaid interest is **not** counted as an asset, so
  the pool can never owe more than it holds.
- **Yield:** interest paid by the company raises `totalAssets` → NAV rises → members earn the spread.
- **Risk:** an overdue loan (`now > dueAt + grace`) can be written off permissionlessly via
  `markDefaulted()` → NAV falls → shareholders bear the loss pro-rata.
- **Liquidity:** `minReserveBps` of assets is kept liquid; redemptions are bounded by liquid cash
  (you can't redeem money that's out on loan).
- **Underwriting:** Chainlink Confidential AI prices the **credit cap** (how much the company qualifies
  to borrow) and the **interest rate** (riskier company → higher APR → bigger spread for members).

See `docs/decisions.md` for resolved addresses and the Arc/Chainlink specifics.
