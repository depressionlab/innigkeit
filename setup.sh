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
  apt-get install -y qemu-system-x86 qemu-utils 2>/dev/null || \
    { apt-get update -qq && apt-get install -y qemu-system-x86 qemu-utils >/dev/null; }
fi

export PATH="$ZIG_DIR:$PATH"

cat > "$TOOLS_DIR/env.sh" <<EOF
export PATH="$ZIG_DIR:\$PATH"
EOF

echo "[setup] Ready."
echo "  Zig:  $(which zig) ($(zig version))"
echo "  QEMU: $(which qemu-system-x86_64 2>/dev/null || echo not-found) ($(qemu-system-x86_64 --version 2>/dev/null | head -1 || echo -))"
echo ""
echo "  Run x64:  zig build run_x64"
echo "  Test x64:   zig build test_x64"
echo ""
echo "  Re-source env in new shells: source .tools/env.sh"
