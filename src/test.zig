//! Test runner root for kernel test builds.
//!
//! In a `zig test` binary, this file acts as the root package,
//! so it must declare everything that `src/main.zig` normally
//! declares for the global kernel build.
//!
//! The kernel boots via Limine; `stage4` runs all tests and exits
//! QEMU via the ISA debug-exit device. This `main()` is never
//! actually called by the kernel.
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const std = @import("std");

pub const panic = innigkeit.debug.panic_interface;

pub const std_options: std.Options = .{
    .log_level = innigkeit.debug.log.log_level.toStd(),
    .logFn = innigkeit.debug.log.stdLogImpl,

    .page_size_min = architecture.paging.standard_page_size.value,
    .page_size_max = architecture.paging.largest_page_size.value,
    .queryPageSize = struct {
        fn queryPageSize() usize {
            return architecture.paging.standard_page_size.value;
        }
    }.queryPageSize,

    .side_channels_mitigations = .full,
};

pub const std_options_debug_io: std.Io = undefined;
pub const debug = innigkeit.debug.interop;

comptime {
    @import("boot").exportEntryPoints();
}

pub fn main() void {}

/// `std.testing.fuzz(...)` resolves against `@import("root").fuzz`; this test
/// binary's root is this file (a "simple"-mode custom test runner), not the
/// standard `compiler/test_runner.zig`, so it needs its own implementation.
/// There's no libFuzzer/coverage-instrumentation support here, as no host
/// process exists inside QEMU to feed a corpus or read coverage back, so
/// this runs `testOne` once per corpus entry plus one empty-input smoke test,
/// matching `std`'s own non-`--fuzz` fallback exactly. Real fuzzing (many
/// random inputs exploring edge cases) only happens for host-testable code
/// exercised via `zig build test_native --fuzz`.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *std.testing.Smith) anyerror!void,
    options: std.testing.FuzzInputOptions,
) anyerror!void {
    for (options.corpus) |input| {
        var smith: std.testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: std.testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}
