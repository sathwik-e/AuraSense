#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if command -v cargo >/dev/null 2>&1; then
    echo "==> [AuraSense-Rust] Compiling pure Rust crate with Cargo (Release LTO)..."
    cd "${SCRIPT_DIR}"
    cargo build --release
    cp "${SCRIPT_DIR}/target/release/aurasense-rs" "${RUST_ROOT}/AuraSense.app/Contents/MacOS/aurasense-rs-daemon" 2>/dev/null || true
    echo "==> [AuraSense-Rust] Built target/release/aurasense-rs successfully!"
else
    echo "==> [AuraSense-Rust] Note: 'cargo' not found in PATH."
    echo "    To compile the standalone Rust crate directly, install rustup (https://rustup.rs) and run:"
    echo "    cargo build --release"
fi
