//! Host-side helpers for build-graph steps that Zig 0.17's fixed `Step` tag
//! set can no longer express as custom steps. Each subcommand is invoked
//! through a `Step.Run` from `build/`.
//!
//! - `patch-compiler-rt`: copy Zig's compiler_rt with `c_longdouble` replaced by
//!   `f64` (workaround for ziglang/zig#37006, see `build/CompilerRt.zig`).
//! - `require-rust-target`: fail with an actionable message unless the Rust
//!   `rustup` target is installed (instead of cargo's opaque E0463).
//! - `print`: write the arguments to stdout (the `zig build help` menu).
//! - `verdict`: judge a QEMU serial/debugcon log (replaces `VerdictStep`).
//! - `with-swtpm`: run a command with a `swtpm` daemon alive around it
//!   (replaces `TpmHarness`).
//! - `with-fuzz-client`: run a command with the host-side UDP fuzz client
//!   alive around it (replaces `FuzzChannelHarness`).
// zlinter-disable require_errdefer_dealloc - everything here is allocated from the process arena and lives until exit; there is nothing to free on an error path.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) usage("missing subcommand");

    const subcommand = args[1];
    const rest = args[2..];
    if (std.mem.eql(u8, subcommand, "print")) return print(rest);
    if (std.mem.eql(u8, subcommand, "require-rust-target")) return requireRustTarget(init.io, arena, rest);
    if (std.mem.eql(u8, subcommand, "patch-compiler-rt")) return patchCompilerRt(init.io, arena, rest);
    if (std.mem.eql(u8, subcommand, "verdict")) return verdict(init.io, arena, rest);
    if (std.mem.eql(u8, subcommand, "with-swtpm")) return withSwtpm(init.io, arena, rest);
    if (std.mem.eql(u8, subcommand, "with-fuzz-client")) return withFuzzClient(init.io, arena, rest);
    usage("unknown subcommand");
}

fn usage(message: []const u8) noreturn {
    std.debug.print(
        \\{s}
        \\
        \\Usage:
        \\  build_helper print <text>
        \\  build_helper require-rust-target <target-triple>
        \\  build_helper patch-compiler-rt <zig_lib_dir> <out_dir>
        \\  build_helper verdict --log <path> [--expect-no-boot] [--require <substring>]...
        \\  build_helper with-swtpm <state_dir> <socket_path> -- <command> [args...]
        \\  build_helper with-fuzz-client <client_exe> <corpus_dir> <iterations> <seed|-> -- <command> [args...]
        \\
    , .{message});
    std.process.exit(2);
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format ++ "\n", args);
    std.process.exit(1);
}

/// Index of the `--` separator, or a usage error.
fn separator(args: []const [:0]const u8) usize {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) {
            if (i + 1 >= args.len) usage("nothing to run after '--'");
            return i;
        }
    }
    usage("missing '--' before the wrapped command");
}

fn print(args: []const [:0]const u8) void {
    for (args) |arg| std.debug.print("{s}\n", .{arg});
}

fn requireRustTarget(io: std.Io, arena: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len != 1) usage("require-rust-target needs <target-triple>");
    const target = args[0];

    const result = std.process.run(arena, io, .{ .argv = &.{ "rustc", "--print", "sysroot" } }) catch |e|
        fail("unable to run 'rustc --print sysroot' ({t}); is Rust installed? Rust apps need `rustup target add {s}`", .{ e, target });
    const sysroot = std.mem.trim(u8, result.stdout, " \n\r");
    const rustlib_dir = try arena.print("{s}/lib/rustlib/{s}/lib", .{ sysroot, target });
    std.Io.Dir.cwd().access(io, rustlib_dir, .{}) catch
        fail("the '{s}' Rust target is not installed (checked '{s}'). run `rustup target add {s}` before building Rust apps", .{ target, rustlib_dir, target });
}

/// Zig 0.17.0 regression ziglang/zig#37006: on x86-64 targets with the
/// `soft_float` feature, `c_longdouble` (f80) is not extern-compatible, yet
/// `compiler_rt` unconditionally exports the long-double math functions
/// (`cosl`, `expl`, ...) with `c_longdouble` in their C-ABI signatures, so the
/// whole of compiler_rt fails to build. Nothing on such a target can call those
/// functions (no x87), so the copy declares them in terms of `f64` instead.
/// Every other file is copied byte for byte.
fn patchCompilerRt(io: std.Io, arena: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len != 2) usage("patch-compiler-rt needs <zig_lib_dir> <out_dir>");
    const cwd = std.Io.Dir.cwd();

    var lib_dir = cwd.openDir(io, args[0], .{ .iterate = true }) catch |e|
        fail("unable to open zig lib dir '{s}': {t}", .{ args[0], e });
    defer lib_dir.close(io);
    var out_dir = cwd.createDirPathOpen(io, args[1], .{}) catch |e|
        fail("unable to create '{s}': {t}", .{ args[1], e });
    defer out_dir.close(io);

    var replaced: usize = 0;
    try patchFile(io, arena, lib_dir, out_dir, "compiler_rt.zig", &replaced);

    var compiler_rt_dir = lib_dir.openDir(io, "compiler_rt", .{ .iterate = true }) catch |e|
        fail("unable to open '{s}/compiler_rt': {t}", .{ args[0], e });
    defer compiler_rt_dir.close(io);
    out_dir.createDirPath(io, "compiler_rt") catch |e| fail("unable to create compiler_rt dir: {t}", .{e});

    var walker = try compiler_rt_dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const sub_path = try arena.print("compiler_rt/{s}", .{entry.path});
        switch (entry.kind) {
            .directory => out_dir.createDirPath(io, sub_path) catch |e| fail("unable to create '{s}': {t}", .{ sub_path, e }),
            .file => try patchFile(io, arena, lib_dir, out_dir, sub_path, &replaced),
            else => {},
        }
    }

    // A fixed Zig should stop needing this; make that visible instead of
    // silently carrying a stale workaround.
    if (replaced == 0) fail("patch-compiler-rt: found no 'c_longdouble' to replace; ziglang/zig#37006 looks fixed, drop build/CompilerRt.zig", .{});
}

fn patchFile(
    io: std.Io,
    arena: std.mem.Allocator,
    from: std.Io.Dir,
    to: std.Io.Dir,
    sub_path: []const u8,
    replaced: *usize,
) !void {
    const contents = from.readFileAlloc(io, sub_path, arena, .limited(16 * 1024 * 1024)) catch |e|
        fail("unable to read '{s}': {t}", .{ sub_path, e });
    const needle = "c_longdouble";
    const count = std.mem.count(u8, contents, needle);
    const output = if (count == 0) contents else blk: {
        replaced.* += count;
        const patched = try arena.alloc(u8, contents.len - count * (needle.len - "f64".len));
        _ = std.mem.replace(u8, contents, needle, "f64", patched);
        break :blk patched;
    };
    to.writeFile(io, .{ .sub_path = sub_path, .data = output }) catch |e|
        fail("unable to write '{s}': {t}", .{ sub_path, e });
}

/// Fails unless the log contains the kernel test runner's verdict line (and
/// every `--require`d substring). With `--expect-no-boot` it instead fails if
/// the log shows ANY kernel output: used for the Secure Boot suite's
/// unsigned/tampered cases, where firmware rejecting the bootloader before it
/// ever runs is the correct outcome.
///
/// The QEMU exit code alone isn't sufficient ground truth: only x64's
/// isa-debug-exit convention is checked by the QEMU run itself, arm has no
/// exit-code check at all, and a crash before the kernel reaches its verdict
/// can still leave QEMU exiting 0.
fn verdict(io: std.Io, arena: std.mem.Allocator, args: []const [:0]const u8) !void {
    var log_path: ?[]const u8 = null;
    var expect_boot = true;
    var required: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--log")) {
            i += 1;
            if (i >= args.len) usage("--log needs a path");
            log_path = args[i];
        } else if (std.mem.eql(u8, arg, "--expect-no-boot")) {
            expect_boot = false;
        } else if (std.mem.eql(u8, arg, "--require")) {
            i += 1;
            if (i >= args.len) usage("--require needs a substring");
            try required.append(arena, args[i]);
        } else usage("unknown verdict option");
    }
    const path = log_path orelse usage("verdict needs --log");

    const contents: []const u8 = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |e| blk: {
        // QEMU's `-debugcon file:...` chardev is created lazily on first
        // guest write; firmware that rejects a boot before the guest ever
        // touches that I/O port means the file never gets created at all.
        // That is the expected signal for the rejection case, not an error.
        // For the expect-a-pass case a missing log is still a real failure.
        if (!expect_boot and e == error.FileNotFound) break :blk "";
        fail("unable to read QEMU log '{s}': {t}", .{ path, e });
    };

    if (!expect_boot) {
        if (hasPassedLine(contents) or std.mem.find(u8, contents, "test_runner") != null)
            fail(
                "expected firmware to REJECT this boot, but the kernel produced output " ++
                    "(Secure Boot bypass?)\n--- log ---\n{s}",
                .{contents},
            );
        return;
    }

    if (!hasPassedLine(contents))
        fail(
            "QEMU log '{s}' does not contain 'ALL <N> TEST(S) PASSED': boot likely " ++
                "crashed or the kernel hung before the test runner finished\n--- log tail ---\n{s}",
            .{ path, tail(contents, 4096) },
        );

    for (required.items) |needle| {
        if (std.mem.find(u8, contents, needle) == null)
            fail("QEMU log '{s}' is missing required substring '{s}'", .{ path, needle });
    }
}

/// Hand-scans for "ALL <digits> TEST(S) PASSED".
fn hasPassedLine(contents: []const u8) bool {
    const marker = "ALL ";
    var idx: usize = 0;
    while (std.mem.findPos(u8, contents, idx, marker)) |start| {
        var i = start + marker.len;
        var saw_digit = false;
        while (i < contents.len and std.ascii.isDigit(contents[i])) : (i += 1) saw_digit = true;
        if (saw_digit and std.mem.startsWith(u8, contents[i..], " TEST(S) PASSED")) return true;
        idx = start + marker.len;
    }
    return false;
}

fn tail(contents: []const u8, max: usize) []const u8 {
    if (contents.len <= max) return contents;
    return contents[contents.len - max ..];
}

/// Runs `argv` to completion with inherited stdio.
fn runWrapped(io: std.Io, argv: []const []const u8) !std.process.Child.Term {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| fail("unable to spawn '{s}': {t}", .{ argv[0], e });
    return child.wait(io);
}

/// Exits this process with the status the wrapped command had.
fn exitLike(term: std.process.Child.Term) noreturn {
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal, .stopped, .unknown => fail("wrapped command terminated abnormally: {any}", .{term}),
    }
}

fn termFailed(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code != 0,
        .signal, .stopped, .unknown => true,
    };
}

/// `swtpm socket --tpm2 ... --daemon` blocks until the TPM engine is
/// genuinely ready, THEN forks into a detached background daemon and exits, so
/// waiting for that spawn to exit is itself the readiness signal (a plain
/// "does the socket file exist yet" check raced with swtpm's internal init
/// and produced intermittent `TPM_RC` failures on the very first commands).
/// The daemon's real PID comes from its pidfile; it is killed by PID after
/// the wrapped command finishes, whatever its outcome.
fn withSwtpm(io: std.Io, arena: std.mem.Allocator, args: []const [:0]const u8) !void {
    const sep = separator(args);
    if (sep != 2) usage("with-swtpm needs exactly <state_dir> <socket_path> before '--'");
    const state_dir = args[0];
    const socket_path = args[1];
    // `[:0]const u8` and `[]const u8` share one layout (pointer + length), so the
    // slice of sentinel-terminated arguments is also a slice of plain ones.
    const command: []const []const u8 = @ptrCast(args[sep + 1 ..]);

    const cwd = std.Io.Dir.cwd();
    const pid_path = try arena.print("{s}/pid", .{state_dir});
    const log_path = try arena.print("{s}/swtpm.log", .{state_dir});

    killLeftoverDaemon(io, arena, pid_path);
    // zlinter-disable-next-line no_swallow_error - best effort: a missing or already-dead target is the desired end state
    cwd.deleteTree(io, state_dir) catch {};
    cwd.createDirPath(io, state_dir) catch |e|
        fail("unable to create TPM state dir '{s}': {t}", .{ state_dir, e });

    const log_file = cwd.createFile(io, log_path, .{}) catch |e|
        fail("unable to create '{s}': {t}", .{ log_path, e });
    defer log_file.close(io);

    var daemonizer = std.process.spawn(io, .{
        .argv = &.{
            "swtpm",
            "socket",
            "--tpm2",
            "--tpmstate",
            try arena.print("dir={s}", .{state_dir}),
            "--ctrl",
            try arena.print("type=unixio,path={s}", .{socket_path}),
            "--flags",
            "startup-clear,not-need-init",
            "--daemon",
            "--pid",
            try arena.print("file={s}", .{pid_path}),
        },
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
    }) catch |e| fail("unable to spawn swtpm (is it installed?): {t}", .{e});

    const daemonizer_term = daemonizer.wait(io) catch |e|
        fail("failed waiting for swtpm to daemonize: {t}", .{e});
    if (termFailed(daemonizer_term)) {
        const log_contents = cwd.readFileAlloc(io, log_path, arena, .limited(16 * 1024)) catch "(could not read log)";
        fail("swtpm failed to start (term: {any})\n--- {s} ---\n{s}", .{ daemonizer_term, log_path, log_contents });
    }

    var attempt: u32 = 0;
    const daemon_pid: std.posix.pid_t = while (attempt < 20) : (attempt += 1) {
        const contents = cwd.readFileAlloc(io, pid_path, arena, .limited(64)) catch {
            // zlinter-disable-next-line no_swallow_error - an interrupted sleep only shortens a bounded retry loop
            std.Io.sleep(io, .fromMilliseconds(50), .real) catch {};
            continue;
        };
        break std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, contents, " \n\r\t"), 10) catch {
            // zlinter-disable-next-line no_swallow_error - an interrupted sleep only shortens a bounded retry loop
            std.Io.sleep(io, .fromMilliseconds(50), .real) catch {};
            continue;
        };
    } else fail("swtpm pidfile '{s}' never contained a valid pid after 1s", .{pid_path});

    const term = try runWrapped(io, command);
    // zlinter-disable-next-line no_swallow_error - best effort: a missing or already-dead target is the desired end state
    std.posix.kill(daemon_pid, std.posix.SIG.KILL) catch {};
    exitLike(term);
}

fn killLeftoverDaemon(io: std.Io, arena: std.mem.Allocator, pid_path: []const u8) void {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, pid_path, arena, .limited(64)) catch return;
    const pid = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, contents, " \n\r\t"), 10) catch return;
    // zlinter-disable-next-line no_swallow_error - best effort: a missing or already-dead target is the desired end state
    std.posix.kill(pid, std.posix.SIG.KILL) catch {};
}

/// Unlike swtpm, the client (`tools/kernel_fuzz`) is a foreground process that
/// must already be running (retrying against the hostfwd'd port) while the
/// guest boots and its net-poll task comes up. It is started before the
/// wrapped command and waited on after it; the run fails unless the client
/// reported a verified round trip (exit 0).
fn withFuzzClient(io: std.Io, arena: std.mem.Allocator, args: []const [:0]const u8) !void {
    const sep = separator(args);
    if (sep != 4) usage("with-fuzz-client needs <client_exe> <corpus_dir> <iterations> <seed|-> before '--'");
    const client_exe = args[0];
    const corpus_dir = args[1];
    const iterations = args[2];
    const seed = args[3];
    // `[:0]const u8` and `[]const u8` share one layout (pointer + length), so the
    // slice of sentinel-terminated arguments is also a slice of plain ones.
    const command: []const []const u8 = @ptrCast(args[sep + 1 ..]);

    const cwd = std.Io.Dir.cwd();
    inline for (.{ "", "crashes", "interesting" }) |sub| {
        const dir = if (sub.len == 0) corpus_dir else try arena.print("{s}/{s}", .{ corpus_dir, sub });
        cwd.createDirPath(io, dir) catch |e|
            fail("unable to create fuzz corpus directory '{s}': {t}", .{ dir, e });
    }

    var client_argv: std.ArrayList([]const u8) = .empty;
    try client_argv.appendSlice(arena, &.{ client_exe, corpus_dir, "--iterations", iterations });
    if (!std.mem.eql(u8, seed, "-")) try client_argv.appendSlice(arena, &.{ "--seed", seed });

    var client = std.process.spawn(io, .{
        .argv = client_argv.items,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| fail("unable to spawn '{s}': {t}", .{ client_exe, e });

    const term = try runWrapped(io, command);

    const client_term = client.wait(io) catch |e|
        fail("failed waiting for the fuzz-channel client: {t}", .{e});
    if (termFailed(client_term))
        fail("fuzz-channel client failed ({any}); see its stderr above for the reason", .{client_term});

    exitLike(term);
}
