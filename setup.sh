#!/usr/bin/env bash
# Run: source setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/.tools"
mkdir -p "$TOOLS_DIR"

ZIG_DIR="$TOOLS_DIR/zig-0.16.0"
if [ ! -f "$ZIG_DIR/zig" ]; then
  echo "[setup] Downloading Zig 0.16.0..."
  curl -L https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz \
    -o "$TOOLS_DIR/zig.tar.xz"
  mkdir -p "$ZIG_DIR"
  tar -xf "$TOOLS_DIR/zig.tar.xz" -C "$ZIG_DIR" --strip-components=1
  rm "$TOOLS_DIR/zig.tar.xz"
  echo "[setup] Zig 0.16.0 installed."
else
  echo "[setup] Zig 0.16.0 already installed."
fi

if ! command -v qemu-system-x86_64 &>/dev/null; then
  echo "[setup] Installing QEMU via apt..."
  apt-get update -qq && apt-get install -y qemu-system-x86 >/dev/null
fi

export PATH="$ZIG_DIR:$PATH"
echo "[setup] Ready."
echo "  Zig:  $(which zig) ($(zig version))"
echo "  QEMU: $(which qemu-system-x86_64) ($(qemu-system-x86_64 --version | head -1))"
echo ""
echo "  Build: zig build run_x64"
echo "  Patch: git format-patch origin/main --stdout > innigkeit.patch"
