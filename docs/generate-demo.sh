#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Build the tool
nix build

# Add result/bin to PATH so VHS can find agent-monitor-hs
export PATH="$PWD/result/bin:$PATH"

# Run VHS to generate the GIF
nix run nixpkgs#vhs -- docs/demo.tape

echo "Generated docs/demo.gif"
