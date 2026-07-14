//! Build-graph `swtpm` lifecycle for `-Dtpm=true`. A `start` step spawns
//! `swtpm socket --tpm2 ... --daemon --pid file=...`: with `--daemon`, the
//! spawned process blocks until the TPM engine is genuinely ready, THEN
//! forks into a detached background daemon and exits so waiting for
//! that spawn to exit is itself the readiness signal (a plain "does the socket
//! file exist yet" check raced with swtpm's internal init and produced
//! intermittent `TPM_RC` failures on the very first commands). `start`
//! reads the daemon's real PID from the pidfile; `stop` kills it by PID.
//! Wire `start -> [image build, QEMU run, verdict] -> stop` via `Step.dependOn`
//! at the call site.
const TpmHarness = @This();

const std = @import("std");
const Step = std.Build.Step;

state_dir: []const u8,
socket_path: []const u8,
daemon_pid: ?std.posix.pid_t = null,

start: Step,
stop: Step,

pub fn create(
    owner: *std.Build,
    state_dir: []const u8,
    socket_path: []const u8,
) error{OutOfMemory}!*TpmHarness {
    const self = try owner.allocator.create(TpmHarness);
    self.* = .{
        .state_dir = state_dir,
        .socket_path = socket_path,
        .start = .init(.{
            .id = .custom,
            .name = "tpm-start",
            .owner = owner,
            .makeFn = makeStart,
        }),
        .stop = .init(.{
            .id = .custom,
            .name = "tpm-stop",
            .owner = owner,
            .makeFn = makeStop,
        }),
    };

    return self;
}

fn makeStart(step: *Step, options: Step.MakeOptions) !void {
    const b = step.owner;
    const io = b.graph.io;
    const self: *TpmHarness = @fieldParentPtr("start", step);

    const node = options.progress_node.start("start swtpm", 1);
    defer node.end();

    killLeftoverDaemon(b, io, self.state_dir);

    std.Io.Dir.cwd().deleteTree(io, self.state_dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, self.state_dir) catch |e|
        return step.fail("unable to create TPM state dir '{s}': {t}", .{ self.state_dir, e });

    const pid_path = b.fmt("{s}/pid", .{self.state_dir});
    const log_path = b.fmt("{s}/swtpm.log", .{self.state_dir});
    const log_file = std.Io.Dir.cwd().createFile(io, log_path, .{}) catch |e|
        return step.fail("unable to create '{s}': {t}", .{ log_path, e });
    defer log_file.close(io);

    var child = std.process.spawn(io, .{
        .argv = &.{
            "swtpm",
            "socket",
            "--tpm2",
            "--tpmstate",
            b.fmt("dir={s}", .{self.state_dir}),
            "--ctrl",
            b.fmt("type=unixio,path={s}", .{self.socket_path}),
            "--flags",
            "startup-clear,not-need-init",
            "--daemon",
            "--pid",
            b.fmt("file={s}", .{pid_path}),
        },
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
    }) catch |e| return step.fail(
        "unable to spawn swtpm (is it installed?): {t}",
        .{e},
    );

    const term = child.wait(io) catch |e|
        return step.fail("failed waiting for swtpm to daemonize: {t}", .{e});
    const bad_exit = switch (term) {
        .exited => |code| code != 0,
        .signal, .stopped, .unknown => true,
    };
    if (bad_exit) {
        const log_contents = std.Io.Dir.cwd().readFileAlloc(io, log_path, b.allocator, .limited(16 * 1024)) catch "(could not read log)";
        return step.fail(
            "swtpm failed to start (term: {any})\n--- {s} ---\n{s}",
            .{ term, log_path, log_contents },
        );
    }

    var attempt: u32 = 0;
    self.daemon_pid = while (attempt < 20) : (attempt += 1) {
        const pid_contents = std.Io.Dir.cwd().readFileAlloc(io, pid_path, b.allocator, .limited(64)) catch {
            std.Io.sleep(io, .fromMilliseconds(50), .real) catch {};
            continue;
        };
        const trimmed = std.mem.trim(u8, pid_contents, " \n\r\t");
        const pid = std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch {
            std.Io.sleep(io, .fromMilliseconds(50), .real) catch {};
            continue;
        };
        break pid;
    } else return step.fail("swtpm pidfile '{s}' never contained a valid pid after 1s", .{pid_path});
}

fn killLeftoverDaemon(b: *std.Build, io: std.Io, state_dir: []const u8) void {
    const pid_path = b.fmt("{s}/pid", .{state_dir});
    const contents = std.Io.Dir.cwd().readFileAlloc(io, pid_path, b.allocator, .limited(64)) catch return;
    const trimmed = std.mem.trim(u8, contents, " \n\r\t");
    const pid = std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch return;
    std.posix.kill(pid, std.posix.SIG.KILL) catch {};
}

fn makeStop(step: *Step, options: Step.MakeOptions) anyerror!void {
    const self: *TpmHarness = @fieldParentPtr("stop", step);

    const node = options.progress_node.start("stop swtpm", 1);
    defer node.end();

    if (self.daemon_pid) |pid| {
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        self.daemon_pid = null;
    }
}
