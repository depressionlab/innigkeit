//! Small, self-contained syscalls with no dedicated subsystem file:
//! nanosleep_ms, thread_set_hint, blk_disk_size, gpu_flush, and the efi_var
//! stubs. Each is a plain fn(Context) Error.Syscall!usize.

const innigkeit = @import("innigkeit");
const Error = @import("libinnigkeit").Error;
const Context = @import("../Context.zig");

/// nanosleep_ms(deadline_ms) -> 0 : block until uptime_ms >= deadline_ms
/// (returns immediately if the deadline is already past).
pub fn nanosleepMs(context: Context) Error.Syscall!usize {
    const deadline_ms = context.arg64(.one);
    innigkeit.sync.nanosleep.wait(deadline_ms);
    return 0;
}

/// thread_set_hint(hint) -> 0 : set the P/E-core scheduling hint for the caller.
/// hint: 0=unknown, 1=p_core, 2=e_core.
pub fn threadSetHint(context: Context) Error.Syscall!usize {
    const raw: u8 = @truncate(context.arg(.one));
    context.currentTask().task.core_hint = switch (raw) {
        1 => innigkeit.Executor.CoreType.p_core,
        2 => innigkeit.Executor.CoreType.e_core,
        else => innigkeit.Executor.CoreType.unknown,
    };
    return 0;
}

/// thread_set_qos(qos) -> 0 : set the calling thread's QoS class (scheduler
/// weight + slice). qos: 0=interactive, 1=default, 2=background.
pub fn threadSetQos(context: Context) Error.Syscall!usize {
    const raw: u8 = @truncate(context.arg(.one));
    if (raw >= @typeInfo(innigkeit.Task.Qos).@"enum".fields.len) return error.InvalidArgument;
    const qos: innigkeit.Task.Qos = @enumFromInt(raw);
    // Targets the calling (running) task. Hold the local scheduler lock so the
    // weight/deadline change cannot race the timer tick's updateCurr.
    const sched = innigkeit.Task.Scheduler.Handle.get(); // locks
    defer sched.unlock();
    context.currentTask().task.setQos(qos);
    return 0;
}

/// blk_disk_size(dev_idx) -> sectors : capacity (512-byte sectors) of virtio-blk
/// device dev_idx, or NoDevice if it does not exist.
pub fn blkDiskSize(context: Context) Error.Syscall!usize {
    const dev_idx = context.arg(.one);
    const sectors = innigkeit.drivers.virtio.blk.diskSectorCount(dev_idx) orelse
        return Error.Syscall.NoDevice;
    return @intCast(sectors);
}

/// gpu_flush(w, h) -> 0 : flush the virtio-gpu backing store to the host
/// display. No-op (still 0) when virtio-gpu is not initialized.
pub fn gpuFlush(context: Context) Error.Syscall!usize {
    const w = context.arg32(.one);
    const h = context.arg32(.two);
    innigkeit.drivers.virtio.gpu.flush(w, h) catch {};
    return 0;
}

/// present(x, y, w, h) -> 0 : present just a damage rectangle (the compositor's
/// per-frame repaint path).
///
/// The rect is clamped to the scanout so a bad/oversized rect can't make the
/// device read out of bounds.
///
/// No-op on a plain (direct-mapped) framebuffer (those writes are already
/// visible) and when virtio-gpu is absent.
pub fn present(context: Context) Error.Syscall!usize {
    const x = context.arg32(.one);
    const y = context.arg32(.two);
    const w = context.arg32(.three);
    const h = context.arg32(.four);

    const gpu = innigkeit.drivers.virtio.gpu;
    const state = gpu.state orelse return 0; // plain framebuffer: nothing to do
    if (x >= state.fb_width or y >= state.fb_height) return 0;
    const cw = @min(w, state.fb_width - x);
    const ch = @min(h, state.fb_height - y);
    if (cw == 0 or ch == 0) return 0;
    gpu.flushRect(x, y, cw, ch) catch {};
    return 0;
}

/// efi_var_get / efi_var_set: not yet implemented.
pub fn efiVarStub(_: Context) Error.Syscall!usize {
    return Error.Syscall.Unsupported;
}
