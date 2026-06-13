# Stake-and-Advance

An AI-underwritten, undercollateralized **USDC credit line** on Circle's **Arc** L1, with
conditional escrow (dispute + automatic release) and a one-free-subscription-per-human gate.

Three integrations, each load-bearing:

| Leg | What it does | Where |
|---|---|---|
| **Arc** (smart contract) | tranche split, per-vendor credit limit, drawdown/repay, conditional cancel/settlement, dispute + time-based `autoRelease` — all in USDC | `contracts/src/StakeAndAdvance.sol` |
| **Chainlink** (Confidential AI) | a CRE workflow underwrites the vendor's credit cap from confidential financials; the cap is delivered on-chain by an authorized reporter (Arc has no KeystoneForwarder) and gates all borrowing | `cre/`, `server/underwrite.ts`, `onReport` |
| **World ID** | one free subscription per human — proof is validated off-chain (cloud verify), the backend signs an EIP-712 voucher, and the `nullifier_hash` is consumed on-chain so a human can't farm multiple free subs | `server/worldid.ts`, `server/voucher.ts`, `depositWithPersonhood` |

No frontend. Everything is exercised from the terminal (Foundry tests, an end-to-end runner,
and curl-able HTTP endpoints).

## Toolchain is project-local

Foundry installs to `./.foundry/bin` and its solc/cache live under `./.localhome`; node deps
live in `./node_modules`. **Delete this folder and everything is gone** — nothing is installed
globally. The npm/shell scripts set `PATH`/`HOME` for you.

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
npm test             # forge test  -> 30 passing
npm run e2e:local    # full lifecycle on a throwaway anvil, driven via the HTTP API
npm run server       # standalone backend (reads .env); curl the endpoints
npm run deploy:arc   # forge script deploy to Arc testnet (reads .env)
```

### End-to-end (the proof)

```bash
npm run e2e:local
```
Boots anvil, deploys MockUSDC + StakeAndAdvance, starts the backend in-process, then runs:
underwrite (Chainlink) → World ID verify → personhood-gated stake → reused-nullifier rejection
→ drawdown → cancel/settle → dispute → time-based autoRelease. Asserts balances/states and
exits non-zero on any failure.

### Curl the endpoints yourself

```bash
npm run server:local   # boots anvil + deploys + runs the server on :8788
```
(or `bash scripts/server.local.sh`). Then:
```bash
curl localhost:8788/health
curl -X POST localhost:8788/cre/underwrite -H 'content-type: application/json' \
  -d '{"vendor":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","currentDepositedPrincipalUsdc":250,"monthlyRecurringRevenueUsd":5000,"grossMarginBps":8000,"cashBalanceUsd":50000,"monthlyBurnUsd":20000,"delinquencyRateBps":100}'
curl -X POST localhost:8788/worldid/verify -H 'content-type: application/json' \
  -d '{"user":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","id":"human-1"}'
```

## API endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | config + mode |
| POST | `/cre/underwrite` | run confidential underwriting; deliver the signed credit cap on-chain (`onReport`). Returns `{cap, creditAllocationBps, inference, txHash}` |
| POST | `/worldid/verify` | validate personhood; return an EIP-712 voucher `{user, nullifierHash, deadline, signature}` for `depositWithPersonhood` |
| POST | `/worldid/sign` | World ID V4 `signRequest` (`rp_context`); dev stub in `WORLD_ID_MODE=dev` |

## Modes

- `WORLD_ID_MODE=dev` (default): no World App / QR needed — terminal-testable. The backend signs a
  voucher for a supplied `nullifier_hash` (or one derived from `id`); on-chain enforcement still applies.
- `WORLD_ID_MODE=cloud`: forwards the IDKit proof to the World Developer Portal verify endpoint
  (`WORLD_APP_ID` + `WORLD_VERIFY_URL`).
- `CONFIDENTIAL_AI_ENDPOINT` set: calls the Chainlink Confidential AI sandbox; unset: a deterministic
  local risk model (so the flow runs offline).

See `docs/decisions.md` for resolved addresses and the Arc/Chainlink/World ID specifics.
