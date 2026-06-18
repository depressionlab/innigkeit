#!/usr/bin/env bash
# zig build test_arm` reports an UNRELIABLE exit code (the
# build wrapper's QEMU run does not cleanly surface the semihosting exit), so it
# cannot be used to mechanically judge an arm run. This script builds the test
# image (via the `image_test_arm` step, no boot) and then boots it itself, with
# QEMU 11 from .tools and host AAVMF firmware, capturing the serial log and
# grepping for the test-runner verdict. Exit 0 = all tests passed.
#
# Usage:
#   scripts/test_arm.sh            # single-core (M1/M2 faithful config)
#   scripts/test_arm.sh --smp 4    # multi-core (M3+)
#   scripts/test_arm.sh --keep-log # leave the serial log on disk on success

set -u
cd "$(dirname "$0")/.."

ZIG="$PWD/.tools/zig-0.16.0/zig"
[ -x "$ZIG" ] || { echo "FAIL  zig not found — run: source setup.sh"; exit 1; }
export PATH="$PWD/.tools/zig-0.16.0:$PATH"

SMP=1
KEEP_LOG=0
while [ $# -gt 0 ]; do
    case "$1" in
        --smp) SMP="${2:?--smp needs a count}"; shift 2 ;;
        --keep-log) KEEP_LOG=1; shift ;;
        *) echo "unknown flag: $1"; exit 2 ;;
    esac
done

# Prefer the QEMU 11 built into .tools (the distro 8.2 hangs booting the arm
# image); fall back to PATH only if it is absent.
QEMU="$PWD/.tools/qemu/bin/qemu-system-aarch64"
[ -x "$QEMU" ] || QEMU="$(command -v qemu-system-aarch64 || true)"
[ -n "$QEMU" ] || { echo "FAIL  qemu-system-aarch64 not found (.tools/qemu or PATH)"; exit 1; }

# Host AAVMF firmware (the bundled zig-pkg EDK2 is a broken build — see docs).
AAVMF_CODE="/usr/share/AAVMF/AAVMF_CODE.fd"
AAVMF_VARS="/usr/share/AAVMF/AAVMF_VARS.fd"
for f in "$AAVMF_CODE" "$AAVMF_VARS"; do
    [ -f "$f" ] || { echo "FAIL  missing firmware: $f"; exit 1; }
done

# 1. Build the test image (no boot).
if ! timeout 600 "$ZIG" build image_test_arm >/dev/null 2>&1; then
    echo "FAIL  zig build image_test_arm"
    exit 1
fi
IMAGE="zig-out/arm/innigkeit_test_arm.hdd"
[ -f "$IMAGE" ] || { echo "FAIL  test image not produced: $IMAGE"; exit 1; }

# 2. Boot it deterministically and capture serial. TCG aarch64 boot is slow
#    (AAVMF alone is ~60-120s), so budget generously.
LOG="$(mktemp)"
timeout 360 "$QEMU" \
    -nodefaults -no-user-config -boot menu=off \
    -m 256 -smp "$SMP" -cpu max -machine virt,acpi=on -accel tcg \
    -device ramfb \
    -device virtio-blk-pci,drive=drive0 \
    -drive file="$IMAGE",format=raw,if=none,id=drive0,readonly=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$AAVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,readonly=on,file="$AAVMF_VARS" \
    -serial file:"$LOG" -display none -semihosting >/dev/null 2>&1
QEMU_RC=$?

# 3. Verdict: the test runner prints exactly one summary line on completion.
VERDICT="$(grep -aoE 'ALL [0-9]+ TEST\(S\) PASSED( \([0-9]+ skipped\))?' "$LOG" | tail -1)"
FAILS="$(grep -acE '\| fail ' "$LOG")"

if [ -n "$VERDICT" ] && [ "$FAILS" -eq 0 ]; then
    echo "PASS   arm suite (-smp $SMP): $VERDICT"
    [ "$KEEP_LOG" -eq 1 ] && echo "       serial log: $LOG" || rm -f "$LOG"
    exit 0
fi

echo "FAIL   arm suite (-smp $SMP): qemu exit $QEMU_RC; ${FAILS} failure line(s)"
echo "       serial log: $LOG"
# Surface the most useful tail: any fail/panic lines, else the last few lines.
if grep -aqE '\| fail |panic|EXCEPTION' "$LOG"; then
    grep -aE '\| fail |panic|EXCEPTION' "$LOG" | head -8
else
    tail -5 "$LOG"
fi
exit 1
