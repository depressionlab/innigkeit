const PerThread = @This();

/// FPSIMD (FP+SIMD) state for this user thread (lazily saved/restored).
fpsimd_state: FpsimdState = .{},

/// Thread-local pointer register (TPIDR_EL0) for this user thread.
tpidr_el0: u64 = 0,

pub const FpsimdState = extern struct {
    /// 32 × 128-bit SIMD/FP registers (V0–V31).
    v: [32][16]u8 = .{.{0} ** 16} ** 32,
    fpsr: u32 = 0,
    fpcr: u32 = 0,
};
