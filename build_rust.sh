#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if command -v cargo >/dev/null 2>&1; then
    echo "==> [AuraSense-Rust] Compiling pure Rust crate with Cargo (Release LTO)..."
    cd "${SCRIPT_DIR}"
    cargo build --release
    # The standalone daemon is not part of AuraSense.app: copying it into the signed bundle
    # would break the app's code signature. Run it from target/release instead.
    echo "==> [AuraSense-Rust] Built ${SCRIPT_DIR}/target/release/aurasense-rs"
else
    echo "==> [AuraSense-Rust] Note: 'cargo' not found in PATH."
    echo "    To compile the standalone Rust crate directly, install rustup (https://rustup.rs) and run:"
    echo "    cargo build --release"
fi
