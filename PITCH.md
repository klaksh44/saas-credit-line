# Stake-and-Advance — booth pitch

## One-liner
> **Your most loyal customers become your bank** — and earn the lending spread instead of paying it. A company's customers deposit USDC into its credit pool, the pool lends it back to the company as an AI-underwritten line, and the interest accrues to the depositors. Settled on **Arc**.

## The problem
- Early startups can't raise without **giving up equity** (VCs) or **collateral** (banks won't touch them).
- Meanwhile their users hold **idle stablecoins** doing nothing — and a subscription is a pure sunk cost.

## What we do (30 sec)
- Customers **deposit USDC** into the company's pool and get **yield-bearing shares** (priced at NAV).
- The pool **lends an undercollateralized, interest-bearing credit line** to the company.
- Interest paid in **raises NAV** → members earn yield; a **default lowers NAV** → members bear the loss.
- Members **exit by redeeming at NAV** (bounded by the liquid reserve). A subscription becomes an asset.
- **AI sets the cap and the rate. Arc settles it. The customers are the bank.**

## Why each sponsor (one line each)
- **Arc** — the pool + interest-bearing drawdown/repay + permissionless default write-down + NAV share accounting, all in USDC. (advanced stablecoin logic)
- **Chainlink Confidential AI** — underwrites the **credit cap *and* the interest rate** from the company's **confidential financials** → signed on-chain. Answers **"how much, and at what price."**
- **Dynamic** *(access)* — embedded-wallet onboarding + funding; `depositFor` lets a relayer fund a customer's shares so non-crypto users can join in two clicks.
- **Unlink** *(privacy)* — confidential balances/positions: the financials are private off-chain (Chainlink), so the resulting debt and holdings should be private on-chain too.

## How is this different? (the questions a judge asks)
- **vs. a stock / equity token** → It's **debt**. Returns track the company's *credit activity*, not its valuation. No cap table, no governance, no dilution.
- **vs. Aave** → Aave is **over**collateralized — you borrow money you already have. This is **under**collateralized credit to a real company, underwritten on cash flows. Aave can't serve a business that needs capital.
- **vs. Maple / Goldfinch** → Same plumbing, different pool: there the LPs are institutions and the borrower's customers are nowhere. Here **the lender, the member, and the customer are the same person.**
- **vs. a bank** → You don't own a bank, **you are the bank** for one company: you keep the spread a bank would skim, and you choose the borrower (you're its customer).

## The honest open problem (say it before they do)
- **Default risk** on the undercollateralized loan is **real and borne by shareholders** — that's *why* there's a yield (the interest is the spread paid for taking the risk). NAV can go down.
- How we contain it: **AI underwriting** prices the cap + rate; a **liquidity reserve** keeps redemptions solvent; **on-chain track record** (on-time vs late, defaults) re-prices the next round; cash-basis NAV means the pool never promises more than it holds.

## Opening line
> "A subscription is a sunk cost. We turn it into a **deposit in the company's own bank** — customers fund the company's credit line and earn the interest, instead of a bank skimming it. The product is the hook; the credit pool is the business."

## Proof it's real (if asked)
- Deployed contract + **26 passing Foundry tests** + a full terminal **end-to-end** run: underwrite → deposit → drawdown → repay-with-interest → **redeem at a profit** → default → **redeem at a loss** (24 assertions, NAV verified up and down).
- Public repo: github.com/klaksh44/saas-credit-line
