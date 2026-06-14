# Setup — local now, live later

## 0. Toolchain (already done, project-local)

Foundry → `./.foundry/bin`, caches → `./.localhome`, node deps → `./node_modules`.
Nothing global; delete the folder and it's all gone. If `./.foundry/bin` is missing:

```bash
mkdir -p .foundry/bin
curl -fL https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_darwin_arm64.tar.gz | tar -xz -C .foundry/bin
npm install
```

## 1. Local — NO keys required ✅

```bash
npm test              # 26 Foundry tests
npm run e2e:local     # full lifecycle (24 assertions) on a throwaway anvil
npm run server:local  # boots anvil+deploy+server on :8788, curl it
```

Defaults: deterministic local risk model (no Chainlink sandbox needed). This is the
headless/terminal path and needs nothing external.

---

## 2. Going live — what each leg needs

Set these in `.env`. None are paid keys.

### 2a. Chainlink Confidential AI (real inference)
- Get the **sandbox endpoint + key** from the Chainlink booth/workshop (event-provisioned).
- `.env`:
  ```
  CONFIDENTIAL_AI_ENDPOINT=https://.../infer
  CONFIDENTIAL_AI_API_KEY=...
  ```
- Unset → the deterministic local model runs (flow still works).

### 2b. Arc testnet deploy
- Fund a wallet: **https://faucet.circle.com** → Arc testnet USDC (gas is paid in USDC).
- `.env` (the deploy reads these):
  ```
  ARC_RPC_URL=https://rpc.testnet.arc.network
  PRIVATE_KEY=0x...                 # funded deployer = the company (single borrower)
  USDC_ADDRESS=0x3600000000000000000000000000000000000000
  KEYSTONE_FORWARDER=0x...          # == address of REPORTER_PRIVATE_KEY (the cap reporter)
  MIN_RESERVE_BPS=2000              # optional (default 20% kept liquid)
  REPAYMENT_WINDOW_SECONDS=2592000  # optional (default 30 days)
  DEFAULT_GRACE_SECONDS=604800      # optional (default 7 days)
  ```
- Deploy:
  ```bash
  npm run deploy:arc
  ```
  This deploys `StakeAndAdvance` (the per-company pool; the deployer is the company).
- Then point the backend at it (for `npm run server`):
  ```
  STAKE_AND_ADVANCE_ADDRESS=0x<deployed>
  RPC_URL=https://rpc.testnet.arc.network
  CHAIN_ID=5042002
  REPORTER_PRIVATE_KEY=0x...        # key whose address == KEYSTONE_FORWARDER
  ```

## Key invariants (don't break these)
- `KEYSTONE_FORWARDER` **must equal** the address of `REPORTER_PRIVATE_KEY` (only that key can
  deliver the credit cap + interest rate via `onReport`).
- The deployer of `StakeAndAdvance` is the `company` (the single borrower of that pool).

## Keeper (default crystallization)
- `npm run keeper:mark-default` calls `markDefaulted()` once a loan is past due + grace
  (permissionless). Needs `KEEPER_PRIVATE_KEY` + `STAKE_AND_ADVANCE_ADDRESS`. In production this
  logic moves into a Chainlink **CRE** workflow (CRE replaces the deprecated Automation/Functions).

## Order of operations
1. Test everything offline (`npm test`, `npm run e2e:local`).
2. Grab the Chainlink sandbox creds at the event (optional; local model works without).
3. Fund an Arc key from the faucet → `npm run deploy:arc`.
4. Set the server env vars → `npm run server` → curl `/pool/state`, `/cre/underwrite`.
