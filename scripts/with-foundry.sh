#!/usr/bin/env bash
# Run any command with the project-local Foundry toolchain on PATH and Foundry/solc
# caches contained under a project-local HOME (so deleting the project deletes everything).
set -euo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$PROJ/.foundry/bin:$PATH"
export HOME="$PROJ/.localhome"
mkdir -p "$HOME"
exec "$@"
