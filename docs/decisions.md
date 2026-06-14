# Stake-and-Advance Decisions

Last updated: 2026-06-13

## Concept

A per-company **credit pool**: customers deposit USDC for NAV-based yield-bearing shares; the pool
lends an AI-underwritten, undercollateralized, **interest-bearing** credit line to the one company.
Interest paid raises NAV (members earn the spread); a default writes down principal and lowers NAV
(members bear the loss). Accounting is **cash basis**: `totalAssets = cash + outstandingPrincipal`,
and accrued-but-unpaid interest is never counted as an asset.

## Arc Testnet

- Chain ID: `5042002`
- RPC: `https://rpc.testnet.arc.network`
- Explorer: `https://testnet.arcscan.app`
- Faucet: `https://faucet.circle.com`
- Native gas token: USDC
- ERC-20 USDC interface: `0x3600000000000000000000000000000000000000`
- ERC-20 USDC decimals: `6`
- Foundry EVM version: `shanghai`

Use the ERC-20 USDC interface for all balances, allowances, and transfers. Arc's native gas token
exposes 18 decimals, while the ERC-20 interface exposes 6 decimals.

## World ID — REMOVED

The original design gated "one free subscription per human" with a World ID nullifier + EIP-712
voucher. The pivot to a paid deposit pool makes that gate pointless: **money is the gate** (there is
no free good to sybil-farm). All World ID surface was deleted — `depositWithPersonhood`, the
EIP-712 personhood voucher, `usedNullifier`, `worldIdSigner`, `server/worldid.ts`, `server/voucher.ts`,
and the `/worldid/*` routes. (If governance or a free tier is ever added, personhood gets a real job
again.)

## Access & privacy seams (Dynamic, Unlink)

- **Dynamic** — embedded-wallet onboarding + relayer funding. On-chain hook in place:
  `depositFor(address member, uint256 amount)` lets a relayer pay in and credit a customer's shares.
- **Unlink** — confidential balances/positions ("confidential-in via Chainlink → private on-chain").
  Documented integration point; not wired to the live SDK in this build.

## Chainlink CRE (Confidential AI underwriting)

- Contract receiver entry point: `onReport(bytes metadata, bytes report)`.
- Trust boundary: `msg.sender` must be the configured `keystoneForwarder` address.
- **Arc has no KeystoneForwarder** (CRE lists Arc Testnet as supported but no forwarder is deployed),
  so `keystoneForwarder` is set to an **authorized reporter** EOA: the CRE workflow / backend runs the
  confidential inference and the reporter key submits `onReport` with the signed terms.
  `REPORTER_PRIVATE_KEY` must be the key for `KEYSTONE_FORWARDER`.
- **Report payload:** `abi.encode(address company, uint256 cap, uint64 expiry, uint16 interestRateBps)`.
  - `cap` — the credit ceiling (margin-adjusted MRR × approved multiple, scaled by burn/delinquency/
    risk penalties). How much the company *qualifies* to borrow; actual draws are additionally bounded
    on-chain by liquid cash (the reserve).
  - `interestRateBps` — the **risk-priced APR** the company pays (riskier → higher → bigger member
    spread). Clamped off-chain to `[600, 2400]` bps; the contract enforces a hard ceiling of
    `10000` bps (100%).
  - `expiry` — a TTL (7 days) anchored to **chain time** (the backend reads the latest block timestamp,
    so the cap stays consistent on a time-warped test chain). After expiry, `activeCreditCap()`
    returns 0 and borrowing is frozen until re-underwritten.
- Underwriting inputs include the on-chain **track record** (`trackRecord()`): drawdowns, repayments,
  on-time vs late counts, total interest paid, defaulted amount, current outstanding, due date.
- Confidential inference path: CRE Confidential HTTP request with sandbox endpoint/API key supplied
  outside the repository; unset → a deterministic local risk model runs so the flow is offline-testable.

## Default / keeper

- A loan is defaultable once `now > dueAt + defaultGracePeriod` with principal outstanding.
  `markDefaulted()` is **permissionless** and writes off the outstanding principal (NAV falls).
- `keeper/markDefault.ts` is the terminal-testable keeper; production moves this into a CRE workflow
  (CRE replaces the deprecated Chainlink Automation/Functions).
