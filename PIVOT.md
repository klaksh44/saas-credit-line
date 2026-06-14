# PIVOT.md — project history (read me first, agents)

**If you're an agent/dev picking this up:** the Solidity symbol is still `StakeAndAdvance`, but it
**no longer** implements the original "stake to subscribe" model. It now implements a per-company
**credit pool** ("the customers are the bank"). World ID has been **removed**. This note explains the
before/after so you don't reintroduce the old design.

## TL;DR
On **2026-06-13** the project pivoted from **"Stake-and-Advance"** (a fixed-value undercollateralized
credit line gated by World ID personhood) to **"your customers are the bank"** (a per-company,
yield-bearing, NAV-based credit pool). Same contract name, fundamentally different mechanism.

## The OLD idea (pre-pivot)
- A user **staked a fixed USDC amount** to use a SaaS product free; the deposit split **60% collateral
  / 40% vendor credit allocation**.
- The vendor drew an **interest-free** undercollateralized credit line; each subscription had its own
  **escrow** with `cancel` / `raiseDispute` / `resolveDispute` / `autoRelease`.
- **World ID** enforced "one free subscription per human" (off-chain verify → EIP-712 voucher →
  on-chain `nullifier` consumed in `depositWithPersonhood`).
- Three load-bearing legs: **Arc + Chainlink + World ID**.

## Why we pivoted (condensed from the design discussion)
1. A judge suggested making the stake **dynamic/resellable**. Taken literally, that collapses into
   **plain tokenization / a security** — un-novel and a regulatory landmine.
2. We reframed the value as **earned yield from real cash flow** (interest the company pays on the
   credit line), **not speculation**. That makes it a **deposit/lending product**, not an equity token.
3. **World ID's job evaporated:** once joining costs real USDC, **money is the gate** — there's no free
   good to sybil-farm. Personhood was neither necessary nor sufficient for anti-whale, and it was not
   the securities shield (the utility/consumption angle is). So it was **dropped entirely**.
4. We **stayed on Arc, not Canton** — Canton is institutional/permissioned and would erase the retail
   "your customers" wedge (you'd become Maple-on-Canton).
5. **Differentiation:** vs **Aave** (overcollateralized — you borrow money you already have) this is
   **undercollateralized** credit to a real company; vs **Maple/Goldfinch** (institutional LPs) here
   the **lender = member = customer**, per company.

## The NEW idea (current)
**"Your customers are the bank."** A per-company pool: members deposit USDC → **NAV-based
yield-bearing shares**; the pool lends an **AI-underwritten, undercollateralized, interest-bearing**
credit line to the one company. Interest paid **raises NAV** (members earn the spread); a **default**
writes down principal → **NAV falls** (shareholders bear the loss). Members exit by **redeeming at
NAV**, bounded by a liquid reserve. Debt, not equity.

## What changed in the code
- **Contract** (`contracts/src/StakeAndAdvance.sol`) rewritten: cash-basis NAV
  (`totalAssets = cash + outstandingPrincipal`); `deposit`/`depositFor`/`redeem`/`transferShares`;
  lazy **interest accrual**; permissionless time-based `markDefaulted`; **reserve ratio**; `onReport`
  now delivers `(company, cap, expiry, interestRateBps)`. **Deleted:** the `Stake` struct, the
  collateral/creditAllocation tranche, all per-stake escrow/dispute, collateral-yield, and **all**
  World ID surface (voucher, nullifier, EIP-712, `depositWithPersonhood`, `_recover`).
- **Backend** (`server/`): deleted `worldid.ts` + `voucher.ts`; routes are now `/health`,
  `/pool/state`, `/cre/underwrite`; **CORS** enabled for a browser frontend.
- **Underwriting** (`cre/src/creditUnderwriting.ts`): prices a **credit cap + risk-based interest rate**
  (was credit-allocation bps).
- **Tests**: new Foundry suite — **26 tests** (`contracts/test/*.t.sol`); `e2e.local.ts` rewritten to
  the new lifecycle (**24 assertions**: deposit → drawdown → interest → **profit redeem**, then
  default → **loss redeem**). Keeper `autoRelease` → `markDefault`.
- **Sponsors**: **Arc** (settlement) + **Chainlink Confidential AI** (cap + rate) are load-bearing;
  **Dynamic** (`depositFor` relayer seam) + **Unlink** (privacy) are documented seams, not yet wired.

## Current state
- ✅ 26 Foundry tests pass, `e2e:local` green, `tsc --noEmit` clean.
- ✅ **Deployed live on Arc testnet**: `0xC18036FfFfa6D5A861EbA9bd1084b68BC3321c40` (chainId 5042002).
  Verified on-chain: underwrite wrote cap 12 000 USDC + rate 996 bps, and a real 10 USDC deposit
  minted shares (NAV + reserve logic confirmed live).
- ⬜ **Frontend not built yet** — integration handoff is in `FRONTEND.md`.

## Where to look
- Concept & money mechanics: `README.md` · pitch: `PITCH.md` · resolved decisions: `docs/decisions.md`
- Setup & commands: `SETUP.md` · frontend wiring: `FRONTEND.md`
