const innigkeit = @import("innigkeit");
const capabilities = innigkeit.capabilities;
const std = @import("std");

/// Granted at spawn time: handle 0 is a read+write Endpoint the kernel-side
/// `fuzz_target.test.zig` uses to hand this process one (selector, args)
/// tuple taken directly from the host's fuzz-channel corpus entry.
const endpoint_handle: capabilities.Handle = @enumFromInt(0);

/// Minimally-entitled fuzz target: receives one attacker-controlled syscall
/// descriptor over the granted Endpoint and issues it for real, through the
/// same `Syscall.invoke` any real app uses.
pub fn main() void {
    var msg: capabilities.Message = undefined;
    capabilities.endpointRecv(endpoint_handle, &msg) catch |err|
        std.debug.panic("endpointRecv failed: {t}", .{err});

    // msg.tag is a raw, attacker-controlled u64: it may not name a real
    // syscall at all. Skip invoking anything for an out-of-range selector,
    // exactly like the kernel's own real syscall entry point does
    // (`SyscallFrame.syscall()`'s `std.enums.fromInt`): there is nothing to
    // fuzz in a value the real trap path would refuse to dispatch too.
    if (std.enums.fromInt(innigkeit.Syscall, msg.tag)) |selector| {
        _ = innigkeit.Syscall.invoke(selector, .{
            msg.words[0], msg.words[1], msg.words[2], msg.words[3],
        });
    }

    capabilities.endpointReply(endpoint_handle, &capabilities.Message{}) catch
        @panic("endpointReply failed");
    innigkeit.process.exit(0);
}
