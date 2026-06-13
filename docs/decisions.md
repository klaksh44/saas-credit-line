# Stake-and-Advance Decisions

Last updated: 2026-06-13

## Arc Testnet

- Chain ID: `5042002`
- RPC: `https://rpc.testnet.arc.network`
- Explorer: `https://testnet.arcscan.app`
- Faucet: `https://faucet.circle.com`
- Native gas token: USDC
- ERC-20 USDC interface: `0x3600000000000000000000000000000000000000`
- ERC-20 USDC decimals: `6`
- Foundry EVM version: `shanghai`

Use the ERC-20 USDC interface for all balances, allowances, and transfers. Arc's
native gas token exposes 18 decimals, while the ERC-20 interface exposes 6
decimals.

## World ID (one free subscription per human)

- SDK: `@worldcoin/idkit` (widget) + cloud verify (Developer Portal). Verification happens
  **off-chain**; nothing is deployed on Arc, so it cannot fail on chain support.
- Backend `/worldid/verify` validates personhood, then signs an **EIP-712 voucher** over
  `Personhood(address user, bytes32 nullifierHash, uint64 deadline)` with `worldIdSigner`.
- Contract `depositWithPersonhood(user, amount, nullifierHash, deadline, signature)` verifies
  the voucher and consumes `usedNullifier[nullifierHash]` — a human (unique nullifier per
  app+action) cannot claim a second free subscription / credit allocation.
- Domain: `name="StakeAndAdvance", version="1", chainId, verifyingContract` (must match the
  contract's `DOMAIN_SEPARATOR`).
- `WORLD_ID_MODE=dev` is terminal-testable (no World App/QR); `cloud` uses the IDKit proof.

LI.FI was evaluated and dropped: LI.FI lists Arc in its registry but returns
`No available quotes` for every Arc route (verified live), so it cannot move USDC to/from Arc.

## Chainlink CRE

- Contract receiver entry point: `onReport(bytes metadata, bytes report)`
- Trust boundary: `msg.sender` must be the configured `keystoneForwarder` address.
- **Arc has no KeystoneForwarder** (verified against the CRE forwarder directory; CRE lists
  Arc Testnet as a supported network but no forwarder is deployed). So `keystoneForwarder` is
  set to an **authorized reporter** EOA: the CRE workflow / backend runs the confidential
  inference and the reporter key submits `onReport` with the signed cap. `REPORTER_PRIVATE_KEY`
  must be the key for `KEYSTONE_FORWARDER`. (Optional native path: run a `writeReport` receiver
  on Base Sepolia, which has a forwarder, and relay the cap to Arc.)
- Report payload for this MVP:
  `abi.encode(address vendor, uint256 cap, uint64 expiry, uint16 creditAllocationBps)`
- Confidential inference path: CRE Confidential HTTP request with sandbox
  endpoint/API key supplied outside the repository.
- Credit-limit policy:
  - vendor history comes from this platform's onchain repayment track record
  - the contract exposes drawdowns, repayment count, on-time repayments, late
    repayments, total repaid, current outstanding debt, and current debt due date
  - Chainlink CRE determines `creditAllocationBps`, the percentage of user
    principal that becomes vendor borrowable supply on new deposits
  - if no platform history exists, `creditAllocationBps` defaults to `40%`
  - if platform history exists, CRE raises or lowers `creditAllocationBps` from
    on-time repayment rate, repayment depth, repaid volume, late payments,
    current outstanding debt, confidential AI risk score, delinquency, and burn
  - `creditAllocationBps` has a hard maximum of `70%`; neither CRE nor a bad
    report can increase borrowable supply above that ceiling
  - CRE also reports `cap`, a risk ceiling; the contract enforces the final
    borrow limit as `min(vendorCreditAllocationTotal, vendorCreditCap)`

The Arc testnet KeystoneForwarder address still needs final confirmation from
the current Chainlink forwarder directory or hackathon resources before deploy.
