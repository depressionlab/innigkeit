//! The window-manager/display-server namespace.

pub const client = @import("client.zig");
pub const geometry = @import("geometry.zig");
pub const protocol = @import("protocol.zig");
pub const server = @import("server.zig");

pub const Rect = geometry.Rect;
pub const Surface = geometry.Surface;
pub const SurfaceId = geometry.SurfaceId;
pub const Stack = geometry.Stack;

test {
    // Pull submodules' tests into the `wm_core` host-test target.
    _ = geometry;
    _ = protocol;
    _ = client;
    _ = server;
}
