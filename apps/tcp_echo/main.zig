//! TCP echo server.
//!
//! Listens on port 7777 and echoes every byte back to the sender.
//! Each accepted connection runs in its own thread; the server runs indefinitely.

const std = @import("std");
const innigkeit = @import("innigkeit");

const PORT: u16 = 7777;
const IDLE_NS: u64 = 30 * std.time.ns_per_s;

pub fn main() void {
    innigkeit.net.setIp(.{ 10, 0, 2, 15 });

    const listener = innigkeit.net.TcpSocket.listen(PORT) catch |err| {
        innigkeit.io.stdout.print("tcp_echo: listen :{}: {s}\n", .{ PORT, @errorName(err) }) catch {};
        return;
    };
    innigkeit.io.stdout.print("tcp_echo: listening on :{}\n", .{PORT}) catch {};

    while (true) {
        const conn = listener.accept() catch |err| switch (err) {
            error.WouldBlock => continue,
            else => {
                innigkeit.io.stdout.print("tcp_echo: accept: {s}\n", .{@errorName(err)}) catch {};
                continue;
            },
        };
        const t = innigkeit.Thread.spawn(echoConn, .{conn}) catch {
            conn.close();
            continue;
        };
        t.detach();
    }
}

fn echoConn(conn: innigkeit.net.TcpSocket) void {
    defer conn.close();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = conn.recvTimeout(&buf, IDLE_NS) catch break;
        if (n == 0) break;
        conn.sendAll(buf[0..n]) catch break;
    }
}
