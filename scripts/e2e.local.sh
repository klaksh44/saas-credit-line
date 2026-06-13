#!/usr/bin/env bash
# Full end-to-end demo on a local anvil node, driven entirely from the terminal.
# Starts anvil, builds contracts, runs the e2e (deploy + HTTP API + lifecycle), tears down.
set -euo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$PROJ/.foundry/bin:$PATH"
export HOME="$PROJ/.localhome"
mkdir -p "$HOME"
cd "$PROJ"

PORT="${ANVIL_PORT:-8545}"
export ANVIL_RPC="http://127.0.0.1:${PORT}"

echo "[e2e] forge build..."
forge build --root contracts >/dev/null

echo "[e2e] starting anvil on :${PORT}..."
anvil --port "$PORT" --silent &
ANVIL_PID=$!
cleanup() { kill "$ANVIL_PID" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 40); do
  if cast block-number --rpc-url "$ANVIL_RPC" >/dev/null 2>&1; then break; fi
  sleep 0.25
done

echo "[e2e] running terminal e2e..."
"$PROJ/node_modules/.bin/tsx" scripts/e2e.local.ts
