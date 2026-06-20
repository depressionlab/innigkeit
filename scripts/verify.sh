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

# Run the (already-built) arm test image and judge by the serial verdict.
#
# QEMU selection is environment-dependent and we try both: in the cloud
# container the bundled .tools QEMU 11 crashes the arm boot under TCG (wedges at
# configurePerExecutorSystemFeatures) and the host QEMU 8.2 works; on the
# original dev box the reverse was true (8.2 too old, .tools 11 needed). So we
# try the host QEMU first, then .tools, and accept whichever produces the
# "ALL N TEST(S) PASSED" line. The arm exit code is never trusted (flaky), only
# the serial verdict.
run_arm_suite() {
    # Host distro AAVMF is preferred (the vendored EDK2 aarch64 build wedges in
    # SEC, see build/QEMU.zig). Bail clearly if it is absent.
    if [ ! -f /usr/share/AAVMF/AAVMF_CODE.fd ]; then
        note FAIL "arm suite: host AAVMF firmware missing (/usr/share/AAVMF/AAVMF_CODE.fd)"
        FAILED=1
        return
    fi

    local qemu log verdict
    for qemu in qemu-system-aarch64 "$PWD/.tools/qemu/bin/qemu-system-aarch64"; do
        case "$qemu" in
            /*) [ -x "$qemu" ] || continue ;;
            *)  command -v "$qemu" >/dev/null 2>&1 || continue ;;
        esac
        log=$(mktemp)
        timeout 600 "$qemu" -nodefaults -no-user-config -boot menu=off \
            -m 256 -smp 1 \
            -device virtio-blk-pci,drive=drive0,bootindex=0,disable-modern=on,disable-legacy=off \
            -drive file=zig-out/arm/innigkeit_test_arm.hdd,format=raw,if=none,id=drive0 \
            -netdev user,id=net0 \
            -device virtio-net-pci,netdev=net0,disable-modern=on,disable-legacy=off,romfile= \
            -serial "file:$log" -display none -cpu max -machine virt,acpi=on -accel tcg \
            -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
            -drive if=pflash,format=raw,unit=1,readonly=on,file=/usr/share/AAVMF/AAVMF_VARS.fd \
            -semihosting -semihosting-config enable=on,target=native -no-reboot >/dev/null 2>&1
        verdict=$(grep -aoE 'ALL [0-9]+ TEST\(S\) PASSED( \([0-9]+ skipped\))?' "$log" | tail -1)
        if [ -n "$verdict" ]; then
            note PASS "arm suite (-smp 1, $(basename "$qemu")): $verdict"
            rm -f "$log"
            return
        fi
        rm -f "$log"
    done
    note FAIL "arm suite: no PASSED verdict from any QEMU (tried host + .tools)"
    FAILED=1
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

# 3. Build the x64 test image and run it. Use `image_test_x64` (image only) not
#    `test_x64`: the latter also runs the bundled .tools QEMU, which cannot boot
#    x64 here, so its exit code is always non-zero and would mask a real compile
#    failure. `image_test_x64`'s exit code IS meaningful. Delete any stale image
#    first so a failed rebuild can never be mistaken for a pass.
rm -f zig-out/x64/innigkeit_test_x64.hdd
if timeout 900 "$ZIG" build image_test_x64 >/dev/null 2>&1 && [ -f zig-out/x64/innigkeit_test_x64.hdd ]; then
    run_x64_suite 4
    [ "$SMP1" -eq 1 ] && run_x64_suite 1
else
    note FAIL "x64 test image build"
    FAILED=1
fi

# 4. Optional ARM suite. Build the image with zig, then run it with an explicit
#    QEMU (host-first, .tools fallback) and judge by the serial verdict. We do
#    NOT use `zig build test_arm` here because it hard-wires the .tools QEMU 11,
#    which crashes the arm boot in the cloud container (see run_arm_suite).
if [ "$ARM" -eq 1 ]; then
    rm -f zig-out/arm/innigkeit_test_arm.hdd
    if timeout 900 "$ZIG" build image_test_arm >/dev/null 2>&1 && [ -f zig-out/arm/innigkeit_test_arm.hdd ]; then
        run_arm_suite
    else
        note FAIL "arm test image build"
        FAILED=1
    fi
fi

exit "$FAILED"
