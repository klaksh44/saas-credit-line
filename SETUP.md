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
npm test            # 30 Foundry tests
npm run e2e:local   # full lifecycle (22 assertions) on a throwaway anvil
npm run server:local  # boots anvil+deploy+server on :8788, curl it
```

Defaults: `WORLD_ID_MODE=dev` (no World App/QR), local risk model (no Chainlink sandbox).
This is the headless/terminal path and needs nothing external.

---

## 2. Going live — what each leg needs

Set these in `.env`. None are paid keys.

### 2a. World ID (cloud verification)
- Create a free app at **https://developer.worldcoin.org** → create an **Action** (e.g. `claim-free-subscription`) → copy the `app_id`.
- `.env`:
  ```
  WORLD_ID_MODE=cloud
  WORLD_APP_ID=app_xxxxxxxx
  WORLD_ACTION=claim-free-subscription
  WORLD_VERIFY_URL=https://developer.worldcoin.org/api/v2/verify/app_xxxxxxxx
  ```
- ⚠️ Cloud mode requires a **real proof from a human** (World App QR scan or the World ID
  simulator). That needs an IDKit UI or the simulator — there is no headless way to mint a
  real proof. For terminal-only testing, stay in `dev` mode (on-chain enforcement is identical).

### 2b. Chainlink Confidential AI (real inference)
- Get the **sandbox endpoint + key** from the Chainlink booth/workshop (event-provisioned).
- `.env`:
  ```
  CONFIDENTIAL_AI_ENDPOINT=https://.../infer
  CONFIDENTIAL_AI_API_KEY=...
  ```
- Unset → the deterministic local model runs (flow still works).

### 2c. Arc testnet deploy
- Fund a wallet: **https://faucet.circle.com** → Arc testnet USDC (gas is paid in USDC).
- `.env` (the deploy reads these):
  ```
  ARC_RPC_URL=https://rpc.testnet.arc.network
  PRIVATE_KEY=0x...                # funded deployer = vendor
  USDC_ADDRESS=0x3600000000000000000000000000000000000000
  ARBITER_ADDRESS=0x...            # dispute arbiter
  KEYSTONE_FORWARDER=0x...         # == address of REPORTER_PRIVATE_KEY (the cap reporter)
  WORLD_ID_SIGNER=0x...            # == address of WORLD_ID_SIGNER_PRIVATE_KEY
  COLLATERAL_BPS=6000              # optional (default 60%)
  DISPUTE_WINDOW_SECONDS=600       # optional
  ```
- Deploy:
  ```bash
  npm run deploy:arc
  ```
  This deploys `StakeAndAdvance` and calls `setWorldIdSigner(WORLD_ID_SIGNER)`.
- Then point the backend at it (for `npm run server`):
  ```
  STAKE_AND_ADVANCE_ADDRESS=0x<deployed>
  RPC_URL=https://rpc.testnet.arc.network
  CHAIN_ID=5042002
  REPORTER_PRIVATE_KEY=0x...       # key whose address == KEYSTONE_FORWARDER
  WORLD_ID_SIGNER_PRIVATE_KEY=0x...# key whose address == WORLD_ID_SIGNER
  ```

## Key invariants (don't break these)
- `KEYSTONE_FORWARDER` **must equal** the address of `REPORTER_PRIVATE_KEY` (only that key can deliver the credit cap via `onReport`).
- `WORLD_ID_SIGNER` **must equal** the address of `WORLD_ID_SIGNER_PRIVATE_KEY` (the contract verifies vouchers against it).
- The voucher EIP-712 domain uses `CHAIN_ID` — it must match the chain the contract is deployed on (`5042002` on Arc, `31337` on local anvil).

## Order of operations
1. Test everything offline (done). 
2. Grab the free World ID `app_id` + the Chainlink sandbox creds at the event.
3. Fund an Arc key from the faucet → `npm run deploy:arc`.
4. Set the server env vars → `npm run server` → integrate from your client.
