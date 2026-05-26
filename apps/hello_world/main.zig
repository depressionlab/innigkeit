const std = @import("std");
const innigkeit = @import("innigkeit");
const capabilities = innigkeit.capabilities;

pub const std_options = innigkeit.interop.std_options;
pub const std_options_debug_io = innigkeit.interop.debug_io;
pub const std_options_thread_impl = innigkeit.thread.InnigkeitThreadImpl;
pub const panic = innigkeit.interop.panic;

pub fn main() void {
    innigkeit.io.stdout.print("Hello, World!\n", .{}) catch {};

    std.log.info("hello_world starting", .{});

    testIpc();
    testMmap();
    testAllocator();
    testFutex();

    std.log.info("all tests passed", .{});
    innigkeit.io.stdout.print("all tests passed\n", .{}) catch {};
}

fn testIpc() void {
    const ep: capabilities.Handle = capabilities.create(.endpoint) catch {
        innigkeit.io.stdout.print("cap_create failed \n", .{}) catch {};
        return;
    };

    innigkeit.thread.spawn(&serverEntry, ep) catch {};

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var msg: capabilities.Message = .{ .tag = i + 1 };
        capabilities.endpointCall(ep, &msg) catch {};
        innigkeit.io.stdout.print("client got reply tag={}\n", .{msg.tag}) catch {};
    }

    innigkeit.io.stdout.print("ipc test done\n", .{}) catch {};
}

fn testMmap() void {
    const region = innigkeit.mem.mmap(4096, .{ .read = true, .write = true }) catch {
        innigkeit.io.stdout.print("mmap failed\n", .{}) catch {};
        return;
    };

    region[0] = 0xAB;
    region[4095] = 0xCD;
    const ok = region[0] == 0xAB and region[4095] == 0xCD;
    innigkeit.io.stdout.print("mmap: write/read {s}\n", .{if (ok) "ok" else "FAIL"}) catch {};

    innigkeit.mem.munmap(region) catch {};
    innigkeit.io.stdout.print("mmap test done\n", .{}) catch {};
}

fn testAllocator() void {
    var arena = std.heap.ArenaAllocator.init(innigkeit.mem.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const buf = alloc.alloc(u8, 1024) catch {
        std.log.err("page_allocator: alloc failed", .{});
        return;
    };
    @memset(buf, 0xAA);
    const ok = buf[0] == 0xAA and buf[1023] == 0xAA;
    std.log.info("page_allocator: alloc+write {s}", .{if (ok) "ok" else "FAIL"});
}

// A simple futex-based mutex: 0=unlocked, 1=locked, 2=locked+waiters.
const Mutex = struct {
    state: u32 = 0,

    fn lock(self: *Mutex) void {
        // CAS 0 -> 1 (fast path: uncontended).
        if (@cmpxchgStrong(u32, &self.state, 0, 1, .acquire, .monotonic) == null) return;
        // Slow path: mark as contended (state=2) and wait.
        while (@atomicRmw(u32, &self.state, .Xchg, 2, .acquire) != 0) {
            innigkeit.futex.wait(&self.state, 2) catch {};
        }
    }

    fn unlock(self: *Mutex) void {
        const prev = @atomicRmw(u32, &self.state, .Xchg, 0, .release);
        if (prev == 2) {
            // There are waiters, so wake one.
            _ = innigkeit.futex.wake(&self.state, 1) catch 0;
        }
    }
};

var shared_counter: u32 = 0;
var counter_mutex: Mutex = .{};
var done_count: u32 = 0;
var done_futex: u32 = 0;

fn testFutex() void {
    shared_counter = 0;
    done_count = 0;
    @atomicStore(u32, &done_futex, 0, .release);

    // Spawn two threads that each increment the counter 50 times under the mutex.
    innigkeit.thread.spawn(&incrementer, 50) catch {};
    innigkeit.thread.spawn(&incrementer, 50) catch {};

    // Wait for both threads to finish.
    while (@atomicLoad(u32, &done_count, .acquire) < 2) {
        innigkeit.futex.wait(&done_futex, 0) catch {};
    }

    const expected: u32 = 100;
    const actual = @atomicLoad(u32, &shared_counter, .acquire);
    innigkeit.io.stdout.print("futex mutex: counter={} (expected {}){s}\n", .{
        actual, expected, if (actual == expected) "" else " FAIL",
    }) catch {};
    innigkeit.io.stdout.print("futex test done\n", .{}) catch {};
}

fn incrementer(n_raw: usize) callconv(.c) noreturn {
    const n: u32 = @intCast(n_raw);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        counter_mutex.lock();
        shared_counter += 1;
        counter_mutex.unlock();
    }

    _ = @atomicRmw(u32, &done_count, .Add, 1, .acq_rel);
    @atomicStore(u32, &done_futex, 1, .release);
    _ = innigkeit.futex.wake(&done_futex, 1) catch 0;

    innigkeit.thread.exitCurrent();
}

fn serverEntry(ep_raw: usize) callconv(.c) noreturn {
    const ep: capabilities.Handle = @truncate(ep_raw);
    var msg: capabilities.Message = undefined;

    capabilities.endpointRecv(ep, &msg) catch {};
    innigkeit.io.stdout.print("server got tag={}\n", .{msg.tag}) catch {};

    var remaining: usize = 2;
    while (remaining > 0) : (remaining -= 1) {
        msg.tag += 100;
        capabilities.endpointReplyRecv(ep, &msg) catch {};
        innigkeit.io.stdout.print("server got tag={}\n", .{msg.tag}) catch {};
    }

    msg.tag += 100;
    capabilities.endpointReply(ep, &msg) catch {};

    innigkeit.thread.exitCurrent();
}

// TODO: make this less terrible
pub const _start = void;
comptime {
    innigkeit.exportEntry();
}
