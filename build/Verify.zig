//! Composes `zig build verify [-Dtpm=true] [-Dsecboot=true] [-Darm=true]`.

const App = @import("App.zig");
const ImageStep = @import("ImageStep.zig");
const Kernel = @import("Kernel.zig");
const Library = @import("Library.zig");
const Options = @import("Options.zig");
const Platform = @import("Platform.zig");
const QEMU = @import("QEMU.zig");
const std = @import("std");
const Tool = @import("Tool.zig");
const TpmHarness = @import("TpmHarness.zig");
const VerdictStep = @import("VerdictStep.zig");
const Wrapper = @import("Wrapper.zig");

/// Fixed owner GUID used to enroll our own PK/KEK/db.
const secboot_guid = "a5a5a5a5-b6b6-c7c7-d8d8-e9e9e9e9e9e9";
const esp_lba = 4096;
/// Bound on how long a rejected-boot case may run before being killed:
/// firmware refusing to boot may sit at an error screen forever instead of
/// exiting.
const reject_timeout_secs = 60;

pub fn register(
    b: *std.Build,
    wrapper: Wrapper,
    libraries: Library.Collection,
    tools: Tool.Collection,
    apps: App.Collection,
    extra_binaries: []const Kernel.ExtraBinary,
    options: Options,
    native_test_step: *std.Build.Step,
    x64_verdict: *std.Build.Step.Run,
    arm_verdict: *std.Build.Step.Run,
    check: bool,
) !void {
    const verify_step = b.step(
        "verify",
        "Verification gate: check + test_native + x64 suite " ++
            "(-Dtpm/-Dsecboot/-Darm add opt-in suites; -Dcpus=1 for single-core)",
    );
    if (check) verify_step.dependOn(wrapper.check_step);
    verify_step.dependOn(native_test_step);
    verify_step.dependOn(&x64_verdict.step);

    if (b.option(bool, "arm", "Also run the arm suite as part of 'verify' (default: false)") orelse false)
        verify_step.dependOn(&arm_verdict.step);
    if (b.option(bool, "secboot", "Also run the UEFI Secure Boot suite (default: false)") orelse false)
        try registerSecbootSuite(b, verify_step, libraries, tools, apps, extra_binaries, options);
}

fn registerSecbootSuite(
    b: *std.Build,
    verify_step: *std.Build.Step,
    libraries: Library.Collection,
    tools: Tool.Collection,
    apps: App.Collection,
    extra_binaries: []const Kernel.ExtraBinary,
    options: Options,
) !void {
    const secboot_fw = Platform.secbootFirmware(b) orelse {
        std.debug.print("note: -Dsecboot=true requested but no SB-capable OVMF found, skipping the Secure Boot suite", .{});
        return;
    };
    inline for (.{ "swtpm", "sbsign", "virt-fw-vars", "mcopy", "openssl", "timeout" }) |tool_name| {
        if (b.graph.host.result.os.tag == .macos and std.mem.eql(u8, tool_name, "sbsign")) return;
        if (!Platform.hasTool(b, tool_name)) {
            std.debug.print(
                "note: -Dsecboot=true requires '{s}' on PATH; skipping the Secure Boot suite\n",
                .{tool_name},
            );
            return;
        }
    }

    // A dedicated TPM instance, distinct from the base -Dtpm=true one: the
    // secure boot suite always needs a TPM (to seal/unseal the disk key
    // regardless of whether the user separately asked for -Dtpm=true).
    const harness = TpmHarness.create(b, "innigkeit-secboot-tpm");

    const test_opts = options.withTestFlags(b, true);
    const test_kernel = try Kernel.buildTestKernel(b, libraries, test_opts, .x64, apps, tools, extra_binaries);
    const test_image = try ImageStep.buildTestImageStep(b, test_kernel, tools, .x64, test_opts);
    const base_image = test_image.built_file;

    const secureboot_exe = tools.get("secureboot").?.release_safe_exe;

    const keygen = b.addRunArtifact(secureboot_exe);
    keygen.addArg("keygen");

    const enroll = b.addRunArtifact(secureboot_exe);
    enroll.has_side_effects = true;
    enroll.addArg("enroll");
    enroll.addArg(secboot_fw.vars);
    const enrolled_vars = enroll.addPrefixedOutputFileArg("", "vars.fd");
    enroll.addArg(secboot_guid);
    enroll.addFileArg(b.path("keys/secureboot/PK.crt"));
    enroll.addFileArg(b.path("keys/secureboot/KEK.crt"));
    enroll.addFileArg(b.path("keys/secureboot/db.crt"));
    enroll.step.dependOn(&keygen.step);

    // Signed variant: copy the base image, then sign the copy in place.
    const signed_cp = b.addSystemCommand(&.{"cp"});
    signed_cp.addFileArg(base_image);
    const signed_image = signed_cp.addOutputFileArg("secboot-signed.hdd");

    const sign_run = b.addRunArtifact(secureboot_exe);
    sign_run.addArg("sign");
    sign_run.addFileArg(signed_image);
    sign_run.addFileArg(b.path("keys/secureboot/db.key"));
    sign_run.addFileArg(b.path("keys/secureboot/db.crt"));
    sign_run.step.dependOn(&signed_cp.step);
    sign_run.step.dependOn(&keygen.step);

    // Unsigned variant: plain copy, never signed so the firmware must reject it.
    const unsigned_cp = b.addSystemCommand(&.{"cp"});
    unsigned_cp.addFileArg(base_image);
    const unsigned_image = unsigned_cp.addOutputFileArg("secboot-unsigned.hdd");

    // Tampered-config variant: copy the SIGNED image (not the unsigned
    // base as that would just duplicate the unsigned case), then corrupt
    // limine.conf in place. The .EFI's signature still verifies (its bytes
    // are unchanged); the point is proving the enrolled config-hash
    // binding independently catches tampering even when signing itself is
    // otherwise intact.
    const tamper_cp = b.addSystemCommand(&.{"cp"});
    tamper_cp.addFileArg(signed_image);
    const tamper_image = tamper_cp.addOutputFileArg("secboot-tampered.hdd");
    tamper_cp.step.dependOn(&sign_run.step);

    const tamper_run = b.addSystemCommand(&.{ "sh", "-c" });
    tamper_run.setEnvironmentVariable("MTOOLS_SKIP_CHECK", "1");
    tamper_run.addArg(b.fmt(
        \\set -e
        \\mcopy -i "$1@@{d}" ::/limine.conf "$1.conf"
        \\printf '# tampered\n' >> "$1.conf"
        \\mcopy -D o -i "$1@@{d}" "$1.conf" ::/limine.conf
    , .{ esp_lba * 512, esp_lba * 512 }));
    tamper_run.addArg("sh");
    tamper_run.addFileArg(tamper_image);
    tamper_run.step.dependOn(&tamper_cp.step);

    // The three boots share one swtpm state directory and one enrolled VARS file
    // (opened read-write by QEMU); serialize them explicitly rather than
    // trust Zig not to parallelize otherwise-independent steps.
    const signed_verdict = try bootSecboot(b, tools, test_opts, signed_image, enrolled_vars, secboot_fw, harness, true, .{
        .extra_dependencies = &.{&sign_run.step},
        .required_substrings = &.{"pass  testing.tpm.test.test.tpm/eventlog: SecureBoot"},
    });

    const unsigned_verdict = try bootSecboot(b, tools, test_opts, unsigned_image, enrolled_vars, secboot_fw, harness, false, .{
        .timeout_secs = reject_timeout_secs,
        .after = &signed_verdict.step,
    });
    unsigned_verdict.step.dependOn(&unsigned_cp.step);
    unsigned_verdict.step.dependOn(&signed_verdict.step);

    const tampered_verdict = try bootSecboot(b, tools, test_opts, tamper_image, enrolled_vars, secboot_fw, harness, false, .{
        .timeout_secs = reject_timeout_secs,
        .extra_dependencies = &.{&tamper_run.step},
        .after = &unsigned_verdict.step,
    });
    tampered_verdict.step.dependOn(&unsigned_verdict.step);

    verify_step.dependOn(&tampered_verdict.step);
}

const BootSecbootOptions = struct {
    timeout_secs: ?u32 = null,
    /// Steps the QEMU run must wait for beyond what `image`'s LazyPath
    /// implies (needed when a later step mutates `image` in place, e.g.
    /// for signing or tampering after the copy that produced it, since
    /// an in-place mutation isn't tracked by the LazyPath/build-cache
    /// dependency mechanism).
    extra_dependencies: []const *std.Build.Step = &.{},
    /// The previous boot's verdict. The boots share one swtpm state directory
    /// and one writable VARS file, so each QEMU run must wait for the one
    /// before it, not merely its verdict step.
    after: ?*std.Build.Step = null,
    required_substrings: []const []const u8 = &.{},
};

fn bootSecboot(
    b: *std.Build,
    tools: Tool.Collection,
    options: Options,
    image: std.Build.LazyPath,
    vars: std.Build.LazyPath,
    secboot_fw: Platform.FirmwarePaths,
    harness: TpmHarness,
    expect_boot: bool,
    opts: BootSecbootOptions,
) !*std.Build.Step.Run {
    var test_opts = options;
    test_opts.emulator.cpus = options.emulator.cpus orelse 4;
    test_opts.emulator.memory = 256;

    var log: std.Build.LazyPath = undefined;
    const run = try QEMU.buildQemuCommand(b, .x64, image, tools, test_opts, .{
        .log_out = &log,
        .tpm = harness,
        .firmware_override = .{ .secboot_uefi = .{ .code = secboot_fw.code, .vars = vars } },
        .timeout_secs = opts.timeout_secs,
    });
    for (opts.extra_dependencies) |dependency|
        run.step.dependOn(dependency);
    if (opts.after) |after| run.step.dependOn(after);

    run.addArgs(&.{ "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04" });
    run.addArg("-no-reboot");
    if (expect_boot) {
        // buildQemuCommand sets stdio = .inherit; reset so expectExitCode works.
        run.stdio = .infer_from_args;
        run.expectExitCode(1);
    } else {
        // Any exit code is acceptable here (a `timeout`-killed process, or
        // whatever firmware does on reject, both vary) so we explicitly bypass
        // .infer_from_args'/.inherit's implicit "must exit 0" requirement;
        // VerdictStep is the sole judge via log content.
        run.stdio = .{ .check = .empty };
    }

    return VerdictStep.create(b, tools.get("build_helper").?.release_safe_exe, log, opts.required_substrings, expect_boot);
}
