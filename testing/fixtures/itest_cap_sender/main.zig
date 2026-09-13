const innigkeit = @import("innigkeit");
const capabilities = innigkeit.capabilities;

/// Granted at spawn time by `testing.integration.test.zig`'s TH-2 test:
/// handle 0 is a write-only Endpoint shared with `itest_cap_receiver`,
/// handle 1 is a Notify this fixture hands to the receiver over that
/// Endpoint instead of using itself. Whether the receiver can actually
/// operate on it afterward is the thing under test, not anything this
/// fixture does with it directly.
const endpoint_handle: capabilities.Handle = @enumFromInt(0);
const notify_handle: capabilities.Handle = @enumFromInt(1);

pub fn main() void {
    var msg: capabilities.Message = .{ .tag = 0xCA97 };
    msg.caps[0] = @intFromEnum(notify_handle);
    capabilities.endpointSend(endpoint_handle, &msg) catch @panic("endpointSend failed");
    innigkeit.process.exit(55);
}
