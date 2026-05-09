const PerThread = @This();

const innigkeit = @import("innigkeit");
const x64 = @import("../x64.zig");
const globals = @import("globals.zig");

extended_state: ExtendedState,

/// Create the `PerThread` data of a thread.
///
/// Non-architecture specific creation has already been performed but no initialization.
///
/// This function is called in the `Thread` cache constructor.
pub fn createThread(thread: *innigkeit.user.Thread) innigkeit.mem.cache.ConstructorError!void {
    const per_thread: *x64.user.PerThread = .from(thread);

    per_thread.* = .{
        .extended_state = .{
            .xsave_area = @alignCast(
                globals.xsave_area_cache.allocate() catch return error.ItemConstructionFailed,
            ),
        },
    };
}

/// Destroy the `PerThread` data of a thread.
///
/// Non-architecture specific destruction has not already been performed.
///
/// This function is called in the `Thread` cache destructor.
pub fn destroyThread(thread: *innigkeit.user.Thread) void {
    const per_thread: *x64.user.PerThread = .from(thread);

    globals.xsave_area_cache.deallocate(per_thread.extended_state.xsave_area);
}

/// Initialize the `PerThread` data of a thread.
///
/// All non-architecture specific initialization has already been performed.
///
/// This function is called in `Thread.internal.create`.
pub fn initializeThread(thread: *innigkeit.user.Thread) void {
    const per_thread: *x64.user.PerThread = .from(thread);
    per_thread.extended_state.zero();
}

pub inline fn from(thread: *innigkeit.user.Thread) *PerThread {
    return &thread.arch_specific;
}

pub const ExtendedState = struct {
    fs_base: usize = undefined,
    gs_base: usize = undefined,
    xsave_area: []align(64) u8,

    /// Where is the extended state currently stored
    state: State = .memory,

    pub const State = enum {
        registers,
        memory,
    };

    fn zero(extended_state: *ExtendedState) void {
        extended_state.* = .{
            .fs_base = 0,
            .gs_base = 0,
            .xsave_area = extended_state.xsave_area,
            .state = .memory,
        };

        @memset(extended_state.xsave_area, 0);
    }

    /// Save the extended state into memory if it is currently stored in the registers.
    ///
    /// Caller must ensure SSE is enabled before calling; see `x64.instructions.enableSSEUsage`
    pub fn save(extended_state: *ExtendedState) void {
        switch (extended_state.state) {
            .memory => {},
            .registers => {
                if (x64.info.cpu_id.fsgsbase) {
                    @branchHint(.likely); // modern machines support fsgsbase
                    extended_state.fs_base = x64.instructions.rdfsbase();
                } else {
                    extended_state.fs_base = x64.registers.FS_BASE.read();
                }
                extended_state.gs_base = x64.registers.KERNEL_GS_BASE.read();

                switch (x64.info.xsave.method) {
                    .xsaveopt => {
                        @branchHint(.likely); // modern machines support xsaveopt
                        x64.instructions.xsaveopt(
                            extended_state.xsave_area,
                            x64.info.xsave.xcr0_value,
                        );
                    },
                    .xsave => x64.instructions.xsave(
                        extended_state.xsave_area,
                        x64.info.xsave.xcr0_value,
                    ),
                }

                extended_state.state = .memory;
            },
        }
    }

    /// Load the extended state into registers if it is currently stored in memory.
    ///
    /// Caller must ensure SSE is enabled before calling; see `x64.instructions.enableSSEUsage`
    pub fn load(extended_state: *ExtendedState) void {
        switch (extended_state.state) {
            .memory => {
                if (x64.info.cpu_id.fsgsbase) {
                    @branchHint(.likely); // modern machines support fsgsbase
                    x64.instructions.wrfsbase(extended_state.fs_base);
                } else {
                    x64.registers.FS_BASE.write(extended_state.fs_base);
                }

                x64.registers.KERNEL_GS_BASE.write(extended_state.gs_base);

                x64.instructions.xrstor(
                    extended_state.xsave_area,
                    x64.info.xsave.xcr0_value,
                );

                extended_state.state = .registers;
            },
            .registers => {},
        }
    }
};
