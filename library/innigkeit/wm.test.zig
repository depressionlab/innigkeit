//! Host-test entry for the `wm` package (build.zig `wm_core` target).
//!
//! Rooted at the library directory rather than inside `wm/` so that the package's
//! files may import sibling library modules that live outside `wm/`: notably the
//! IPC `Message`/`Handle` types in `capabilities.zig` that `wm/protocol.zig`
//! encodes onto. A test module's relative-import boundary is its root file's
//! directory; pointing it here widens that boundary to `library/innigkeit/`,
//! matching the real library build (which roots at `root.zig`).

test {
    _ = @import("wm/root.zig");
}
