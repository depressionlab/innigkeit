//! Example Innigkeit app built with the out-of-tree SDK.

const std = @import("std");
const innigkeit = @import("innigkeit");

pub fn main() void {
    innigkeit.io.stdout.print("Hello from an out-of-tree Innigkeit app!\n", .{}) catch {};

    // Report the kernel uptime to show syscall access works.
    const uptime_ms = innigkeit.Syscall.decode(
        innigkeit.Syscall.invoke(.uptime_ms, .{}),
    ) catch 0;
    innigkeit.io.stdout.print("uptime: {}ms\n", .{uptime_ms}) catch {};

    // Spawn a thread to demonstrate the threading API.
    const t = innigkeit.Thread.spawn(worker, .{42}) catch {
        innigkeit.io.stdout.print("thread spawn failed\n", .{}) catch {};
        return;
    };
    t.join();

    innigkeit.io.stdout.print("done.\n", .{}) catch {};
}

fn worker(n: u32) void {
    innigkeit.io.stdout.print("worker thread: n={}\n", .{n}) catch {};
}
