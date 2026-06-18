#!/usr/bin/env bash
# Runs the full check + test pipeline and prints an unambiguous PASS/FAIL
# verdict per stage. Designed so that any work-in-progress tree state can be
# judged mechanically (e.g. after an interrupted session): exit 0 means every
# requested stage passed.
#
# Usage:
#   scripts/verify.sh                # check + host tests + x64 suite (-smp 4)
#   scripts/verify.sh --smp1         # also run the x64 suite single-core
#   scripts/verify.sh --arm          # also run the arm suite (if it boots)
#   scripts/verify.sh --quick        # compile check only
#
# QEMU exit code 1 means all kernel tests passed (isa-debug-exit encoding).

set -u
cd "$(dirname "$0")/.."

ZIG="$PWD/.tools/zig-0.16.0/zig"
[ -x "$ZIG" ] || { echo "FAIL  zig not found! run: source setup.sh"; exit 1; }
export PATH="$PWD/.tools/zig-0.16.0:$PATH"

QUICK=0 SMP1=0 ARM=0
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
        --smp1)  SMP1=1 ;;
        --arm)   ARM=1 ;;
        *) echo "unknown flag: $arg"; exit 2 ;;
    esac
done

FAILED=0
note() { printf '%-6s %s\n' "$1" "$2"; }

run_x64_suite() { # $1 = smp count
    local log; log=$(mktemp)
    timeout 300 qemu-system-x86_64 -nodefaults -no-user-config -boot menu=off \
        -m 256 -smp "$1" \
        -device virtio-blk-pci,drive=drive0,bootindex=0,disable-modern=on,disable-legacy=off \
        -drive file=zig-out/x64/innigkeit_test_x64.hdd,format=raw,if=none,id=drive0 \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0,disable-modern=on,disable-legacy=off \
        -debugcon "file:$log" -display none -cpu max,migratable=no -machine q35 \
        -accel tcg \
        -drive if=pflash,format=raw,unit=0,readonly=on,file="$(ls zig-pkg/*/x64/code.fd | head -1)" \
        -drive if=pflash,format=raw,unit=1,readonly=on,file="$(ls zig-pkg/*/x64/vars.fd | head -1)" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot >/dev/null 2>&1
    local code=$?
    local verdict
    verdict=$(grep -aoE 'ALL [0-9]+ TEST\(S\) PASSED( \([0-9]+ skipped\))?' "$log" | tail -1)
    if [ "$code" -eq 1 ] && [ -n "$verdict" ]; then
        note PASS "x64 suite (-smp $1): $verdict"
    else
        note FAIL "x64 suite (-smp $1): qemu exit $code; $(grep -acE 'FAIL' "$log") failure line(s); log: $log"
        FAILED=1
        grep -aE 'FAIL|panic' "$log" | head -5
        return
    fi
    rm -f "$log"
}

# 1. Compile check (all architectures, all apps, host tools).
if timeout 600 "$ZIG" build check >/dev/null 2>&1; then
    note PASS "zig build check (x64+arm+riscv, apps, tools)"
else
    note FAIL "zig build check"
    FAILED=1
fi
[ "$QUICK" -eq 1 ] && exit "$FAILED"

# 2. Host-runnable tests.
if timeout 120 "$ZIG" build test_native >/dev/null 2>&1; then
    note PASS "zig build test_native"
else
    note FAIL "zig build test_native"
    FAILED=1
fi

# 3. Build the x64 test image (the build's own QEMU run is ignored here; the
#    explicit runs below produce the verdicts).
timeout 900 "$ZIG" build test_x64 >/dev/null 2>&1
[ -f zig-out/x64/innigkeit_test_x64.hdd ] || { note FAIL "test image build"; exit 1; }

run_x64_suite 4
[ "$SMP1" -eq 1 ] && run_x64_suite 1

# 4. Optional ARM suite. Delegated to scripts/test_arm.sh, which boots QEMU 11
#    itself and greps the serial verdict: `zig build test_arm`'s own exit code
#    is unreliable on arm. The helper prints its own PASS/FAIL line.
if [ "$ARM" -eq 1 ]; then
    if timeout 600 scripts/test_arm.sh; then
        :
    else
        FAILED=1
    fi
fi

exit "$FAILED"
