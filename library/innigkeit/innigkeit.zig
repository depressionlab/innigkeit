pub const exportEntry = @import("entry.zig").exportEntry;
pub const Syscall = @import("syscall.zig").Syscall;
pub const io = @import("io.zig");

pub const thread = struct {
    pub fn exitCurrent() noreturn {
        _ = Syscall.call0(.exit_current_thread);
        unreachable;
    }
};
