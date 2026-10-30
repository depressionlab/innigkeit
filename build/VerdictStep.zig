//! Fails the build unless a QEMU debugcon/serial log contains the kernel
//! test runner's verdict line (and any additional required substrings
//! e.g. proof a specific opt-in suite, like TPM, actually ran rather than
//! being silently skipped).
//!
//! The QEMU exit code alone isn't sufficient ground truth: only x64's
//! isa-debug-exit convention is checked by `buildTestQemuStep`, arm has no
//! exit-code check at all (its semihosting exit is not routed through
//! QEMU's own process exit status the same way), and in general a crash
//! before the kernel reaches its verdict can still leave QEMU exiting 0.
//!
//! This is a `Step.Run` wrapper around `tools/build_helper verdict`.
const std = @import("std");

/// `expect_boot` true: fail unless the log shows a passing verdict.
/// false: fail if the log shows ANY kernel output at all. Used for the
/// Secure Boot suite's unsigned/tampered-config cases, where firmware
/// rejecting the bootloader before it ever runs is the expected, correct
/// outcome.
///
/// `log` is produced by the QEMU run step, so this step is ordered after it
/// by the `LazyPath` dependency.
pub fn create(
    owner: *std.Build,
    build_helper: *std.Build.Step.Compile,
    log: std.Build.LazyPath,
    required_substrings: []const []const u8,
    expect_boot: bool,
) *std.Build.Step.Run {
    const run = owner.addRunArtifact(build_helper);
    run.setName("verdict");
    run.addArg("verdict");
    run.addArg("--log");
    run.addFileArg(log);
    if (!expect_boot) run.addArg("--expect-no-boot");
    for (required_substrings) |needle| {
        run.addArg("--require");
        run.addArg(needle);
    }
    return run;
}
