const std = @import("std");

pub const exportEntry = @import("entry.zig").exportEntry;
pub const Syscall = @import("syscall.zig").Syscall;
pub const SyscallError = @import("syscall.zig").SyscallError;
pub const capabilities = @import("capabilities.zig");
pub const io = @import("io.zig");
pub const interop = @import("interop/root.zig");

pub const mem = struct {
    /// Protection flags for mmap.
    pub const Prot = packed struct(u32) {
        read: bool = false,
        write: bool = false,
        exec: bool = false,
        _pad: u29 = 0,
    };

    /// Map `size` bytes of anonymous zero-fill memory with the given protection.
    ///
    /// Size is rounded up to the next page boundary by the kernel.
    /// Returns a slice pointing to the mapped region.
    pub fn mmap(size: usize, prot: Prot) SyscallError![]u8 {
        const result = Syscall.invoke(.mmap, .{ size, @as(u32, @bitCast(prot)) });
        const addr = try Syscall.decode(result);
        return @as([*]u8, @ptrFromInt(addr))[0..size];
    }

    /// Unmap a region previously returned by `mmap`.
    ///
    /// The slice must match the address and length of an active mapping.
    pub fn munmap(region: []u8) SyscallError!void {
        const result = Syscall.invoke(.munmap, .{ @intFromPtr(region.ptr), region.len });
        _ = try Syscall.decode(result);
    }

    // std.mem.Allocator backed by the mmap/munmap syscalls.
    //
    // Allocations are page-aligned and rounded up to a whole page. This is
    // suitable as a backing allocator for std.heap.ArenaAllocator and
    // std.heap.GeneralPurposeAllocator; it is too wasteful for fine-grained
    // direct use.

    pub const page_allocator: std.mem.Allocator = .{
        .ptr = undefined,
        .vtable = &page_alloc_vtable,
    };

    const page_size = 4096;

    inline fn pageAlignUp(n: usize) usize {
        return (n + page_size - 1) & ~@as(usize, page_size - 1);
    }

    const page_alloc_vtable: std.mem.Allocator.VTable = .{
        .alloc = pageAlloc,
        .resize = pageResize,
        .remap = pageRemap,
        .free = pageFree,
    };

    fn pageAlloc(
        _: *anyopaque,
        len: usize,
        _: std.mem.Alignment, // page-alignment satisfies any alignment ≤ 4096
        _: usize,
    ) ?[*]u8 {
        const aligned = pageAlignUp(len);
        const result = Syscall.invoke(.mmap, .{ aligned, @as(u32, 0b11) }); // PROT_READ|WRITE
        const addr = Syscall.decode(result) catch return null;
        if (addr == 0) return null;
        return @ptrFromInt(addr);
    }

    fn pageResize(
        _: *anyopaque,
        memory: []u8,
        _: std.mem.Alignment,
        new_len: usize,
        _: usize,
    ) bool {
        // True only when new_len fits in the already-mapped pages.
        // We never extend a mapping (no mremap syscall).
        return pageAlignUp(new_len) <= pageAlignUp(memory.len);
    }

    fn pageRemap(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) ?[*]u8 {
        return null; // no mremap; caller must alloc+copy
    }

    fn pageFree(
        _: *anyopaque,
        memory: []u8,
        _: std.mem.Alignment,
        _: usize,
    ) void {
        const aligned = pageAlignUp(memory.len);
        _ = Syscall.invoke(.munmap, .{ @intFromPtr(memory.ptr), aligned });
    }
};

pub const thread = struct {
    /// The required signature for a spawned thread entry point.
    ///
    /// The thread must call `thread.exitCurrent()` before returning; falling
    /// off the end of the function is undefined behaviour.
    pub const EntryFn = *const fn (arg: usize) callconv(.c) noreturn;

    /// Exit the current thread.
    pub fn exitCurrent() noreturn {
        _ = Syscall.invoke(.exit_thread, .{});
        unreachable;
    }

    /// Voluntarily yield the CPU to another runnable thread.
    pub fn yield() void {
        Syscall.invoke(.yield, .{});
    }

    /// Spawn a new thread in the current process.
    ///
    /// The kernel creates a thread that begins executing `entry(arg)`.
    /// The new thread shares the process address space.
    pub fn spawn(entry: EntryFn, arg: usize) SyscallError!void {
        const result = Syscall.invoke(.spawn_thread, .{
            @intFromPtr(entry),
            arg,
        });
        _ = try Syscall.decode(result);
    }
};

pub const futex = struct {
    /// Block until `*addr != expected` or a futex_wake on addr is received.
    ///
    /// Returns immediately if the word already differs from `expected`
    /// (spurious wakeup, caller should re-check the condition).
    pub fn wait(addr: *const u32, expected: u32) SyscallError!void {
        const result = Syscall.invoke(.futex_wait, .{ @intFromPtr(addr), expected });
        _ = try Syscall.decode(result);
    }

    /// Wake up to `max_wake` threads blocked on `addr`.
    ///
    /// Returns the number of threads actually woken.
    pub fn wake(addr: *const u32, max_wake: u32) SyscallError!u32 {
        const result = Syscall.invoke(.futex_wake, .{ @intFromPtr(addr), max_wake });
        return @intCast(try Syscall.decode(result));
    }
};

pub const process = struct {
    /// Exit the process.
    ///
    /// The kernel will terminate all threads in the process and release all
    /// process resources. `status` is reserved for a future wait/waitpid API.
    pub fn exit(status: u8) noreturn {
        _ = Syscall.invoke(.exit_process, .{status});
        unreachable;
    }
};
