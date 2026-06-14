#!/usr/bin/env bash
# Deploy StakeAndAdvance (the per-company credit pool) to Arc testnet (reads .env).
# Uses the project-local Foundry toolchain.
set -euo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$PROJ/.foundry/bin:$PATH"
export HOME="$PROJ/.localhome"
mkdir -p "$HOME"
cd "$PROJ"

set -a
[ -f .env ] && . ./.env
set +a

: "${ARC_RPC_URL:?set ARC_RPC_URL in .env}"
: "${PRIVATE_KEY:?set PRIVATE_KEY in .env}"
: "${USDC_ADDRESS:?set USDC_ADDRESS in .env}"
: "${KEYSTONE_FORWARDER:?set KEYSTONE_FORWARDER in .env}"

echo "[deploy] Arc RPC: $ARC_RPC_URL"
echo "[deploy] reserve=${MIN_RESERVE_BPS:-2000}bps repaymentWindow=${REPAYMENT_WINDOW_SECONDS:-2592000}s"

forge script contracts/script/Deploy.s.sol:Deploy \
  --rpc-url "$ARC_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast -vvv --root contracts
