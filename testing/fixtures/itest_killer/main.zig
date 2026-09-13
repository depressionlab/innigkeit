const innigkeit = @import("innigkeit");

const victim_exit_handle: innigkeit.capabilities.Handle = @enumFromInt(0);

pub fn main() void {
    innigkeit.process.killProcess(victim_exit_handle) catch @panic("killProcess failed");
    innigkeit.process.exit(0);
}
