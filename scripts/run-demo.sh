#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export AIGON_STANDALONE=1
export AIGON_EMBEDDINGS=0
export AIGON_ALLOW_RUN=0
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
cargo build --release --locked
printf '%s\n' 'Open http://127.0.0.1:8080/proof. After startup, read .aigon-proof/operator.token locally to unlock approval.'
exec ./target/release/aigon-governance-mcp --http "${PROOF_PORT:-8080}"
