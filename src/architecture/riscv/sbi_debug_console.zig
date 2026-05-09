//! A very simple debug console that uses the SBI debug console.
//!
//! Only supports writes.

const architecture = @import("architecture");
const sbi = @import("sbi");

pub fn detect() bool {
    return sbi.debug_console.available();
}

pub const output: architecture.init.InitOutput.Output = .{
    .name = architecture.init.InitOutput.Output.Name.fromSlice("sbi console") catch unreachable,
    .writeFn = struct {
        fn writeFn(_: *anyopaque, str: []const u8) void {
            architecture.init.InitOutput.Output.writeWithCarridgeReturns({}, writeStr, str);
        }
    }.writeFn,
    .splatFn = struct {
        fn splatFn(_: *anyopaque, str: []const u8, splat: usize) void {
            for (0..splat) |_| architecture.init.InitOutput.Output.writeWithCarridgeReturns({}, writeStr, str);
        }
    }.splatFn,
    .state = undefined,
};

fn writeStr(_: void, str: []const u8) void {
    // TODO: figure out how to get `sbi.debug_console.write` to work
    //       as `sbi.debug_console.writeByte` is inefficient
    for (str) |b| sbi.debug_console.writeByte(b) catch return;
}
