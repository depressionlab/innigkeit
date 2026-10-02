//! Descriptor generation, mutation, and on-disk corpus persistence for
//! `kernel_fuzz`'s mutation loop (docs/test-system-plan.md section 5,
//! staging step 5). Kept separate from `main.zig`'s wire-protocol/socket
//! code since none of this depends on `std.Io.net` at all.
const std = @import("std");

/// Wire shape of one syscall descriptor: `capabilities.Message`'s tag+words
/// shape, matching `fuzz_target.test.zig`/`itest_fuzz_target` exactly.
pub const Descriptor = struct {
    selector: u64,
    words: [4]u64,

    pub fn encode(self: Descriptor, out: *[40]u8) void {
        std.mem.writeInt(u64, out[0..8], self.selector, .little);
        for (self.words, 0..) |w, i| std.mem.writeInt(u64, out[8 + i * 8 ..][0..8], w, .little);
    }
};

/// Boundary/adversarial selector values worth trying regardless of how many
/// real syscalls exist: 0 and 1 (valid-looking), just past a plausible
/// table end, and both ends of the u64 range (the stop sentinel itself,
/// `std.math.maxInt(u64)`, is deliberately excluded, since picking it here would
/// end the loop early instead of fuzzing anything).
const interesting_selectors = [_]u64{ 0, 1, std.math.maxInt(u32), std.math.maxInt(u64) - 1 };

/// Boundary/adversarial word values: zero, small positive, all-ones,
/// a page-aligned-looking user address, and both sides of the canonical/
/// non-canonical address-space boundary x86-64 SYSRET cares about.
const boundary_words = [_]u64{
    0,      1,                0xFFFF_FFFF,           0xFFFF_FFFF_FFFF_FFFF,
    0x1000, 0x7FFF_FFFF_F000, 0xFFFF_8000_0000_0000, 0x8000_0000_0000_0000,
};

const interesting_words = [_]u64{ scratch_sentinel, 2 } ++ boundary_words;

/// See `testing/fixtures/itest_fuzz_target/main.zig`.
pub const scratch_sentinel: u64 = 0x5C5C_5C5C_5C5C_5C5C;

/// Syscalls that take a (buffer pointer, length) pair and carry no
/// entitlement gate (a gated one is rejected before its length is touched,
/// and the fixture holds no entitlements), as word indices (syscall argument
/// number minus one). Only 4 words reach a handler, so a syscall whose
/// pointer or length is its 5th/6th argument (`net_udp_send`) can't be
/// driven this way at all.
const PtrLen = struct { selector: u64, ptr: usize, len: usize };
const ptr_len_syscalls = [_]PtrLen{
    .{ .selector = 2, .ptr = 1, .len = 2 }, // write(fd, buf, len)
    .{ .selector = 3, .ptr = 1, .len = 2 }, // read(fd, buf, len)
    .{ .selector = 31, .ptr = 0, .len = 1 }, // fs_open(name, name_len, flags)
    .{ .selector = 32, .ptr = 1, .len = 2 }, // fs_read(fd, buf, len)
    .{ .selector = 33, .ptr = 1, .len = 2 }, // fs_write(fd, buf, len)
    .{ .selector = 54, .ptr = 0, .len = 1 }, // open(path, path_len, flags)
};

const hostile_lengths = [_]u64{
    0,                        1,                     15,
    16,                       62,                    63,
    64,                       255,                   256,
    1460,                     1472,                  4096,
    0xFFFF,                   0x1_0000,              0xFFFF_FFFF,
    0x1_0000_0000,            0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000,
    std.math.maxInt(u64) - 1, std.math.maxInt(u64),
};

fn randomSelector(random: std.Random, slot_count: usize) u64 {
    return switch (random.intRangeLessThan(u8, 0, 4)) {
        0 => random.intRangeLessThan(u64, 0, @max(slot_count, 1)), // in-range
        1 => random.intRangeLessThan(u64, 0, slot_count * 4 + 16), // near the edge
        2 => interesting_selectors[random.intRangeLessThan(usize, 0, interesting_selectors.len)],
        else => random.int(u64), // fully arbitrary, anywhere in the space
    };
}

fn randomWord(random: std.Random) u64 {
    return switch (random.intRangeLessThan(u8, 0, 3)) {
        0 => interesting_words[random.intRangeLessThan(usize, 0, interesting_words.len)],
        1 => random.int(u64),
        else => random.int(u32), // small values: plausible counts/flags/handles
    };
}

/// A fresh, unbiased-toward-any-corpus-entry descriptor.
pub fn randomDescriptor(random: std.Random, slot_count: usize) Descriptor {
    if (random.intRangeLessThan(u8, 0, 4) == 0) return ptrLenDescriptor(random);
    var d: Descriptor = .{ .selector = randomSelector(random, slot_count), .words = undefined };
    for (&d.words) |*w| w.* = randomWord(random);
    return d;
}

fn ptrLenDescriptor(random: std.Random) Descriptor {
    const row = ptr_len_syscalls[random.intRangeLessThan(usize, 0, ptr_len_syscalls.len)];
    var d: Descriptor = .{ .selector = row.selector, .words = undefined };
    for (&d.words) |*w| w.* = randomWord(random);
    d.words[row.ptr] = scratch_sentinel;
    d.words[row.len] = hostile_lengths[random.intRangeLessThan(usize, 0, hostile_lengths.len)];
    return d;
}

/// AFL-style "havoc" mutation of an existing (presumably already-interesting)
/// descriptor: nudge the selector, or flip/replace/increment one word. Never
/// touches more than one field, so a mutated descriptor stays close to
/// whatever made `base` interesting in the first place.
pub fn mutate(random: std.Random, base: Descriptor, slot_count: usize) Descriptor {
    var d = base;
    if (random.intRangeLessThan(u8, 0, 3) == 0) {
        d.selector = randomSelector(random, slot_count);
    } else {
        const idx = random.intRangeLessThan(usize, 0, d.words.len);
        switch (random.intRangeLessThan(u8, 0, 3)) {
            0 => d.words[idx] = randomWord(random),
            1 => d.words[idx] ^= @as(u64, 1) << random.intRangeAtMost(u6, 0, 63),
            else => d.words[idx] +%= 1,
        }
    }
    return d;
}

/// Bounded set of descriptors that have proven "interesting" (increased
/// coverage). Fixed capacity, no eviction: a single fuzz run's corpus is
/// small enough (`default_iterations` in `main.zig`) that filling this
/// bound at all would already mean most of the run found something new,
/// which is itself worth knowing rather than quietly discarding older
/// finds to make room.
pub const Corpus = struct {
    entries: std.ArrayList(Descriptor) = .empty,
    max_entries: usize,

    pub fn add(self: *Corpus, allocator: std.mem.Allocator, d: Descriptor) !void {
        if (self.entries.items.len >= self.max_entries) return;
        try self.entries.append(allocator, d);
    }

    pub fn pickRandom(self: *const Corpus, random: std.Random) ?Descriptor {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[random.intRangeLessThan(usize, 0, self.entries.items.len)];
    }
};

/// Writes one descriptor's raw 40-byte wire encoding to
/// `<corpus_dir>/<subdir>/seed<seed-hex>_iter<iteration>_sel<selector-hex>.bin` for later
/// human inspection or replay tooling. Best-effort: a corpus write failing
/// (e.g. a read-only filesystem) is logged and does not fail the fuzz run --
/// the run's own pass/fail already comes from the kernel side staying up and
/// responsive, not from whether this bookkeeping succeeded.
pub fn save(
    io: std.Io,
    corpus_dir: []const u8,
    subdir: []const u8,
    seed: u64,
    iteration: usize,
    exit_status: ?u8,
    d: Descriptor,
) void {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = if (exit_status) |status|
        std.fmt.bufPrint(&path_buf, "{s}/{s}/seed{x}_iter{d}_exit{d}_sel{x}.bin", .{ corpus_dir, subdir, seed, iteration, status, d.selector }) catch return
    else
        std.fmt.bufPrint(&path_buf, "{s}/{s}/seed{x}_iter{d}_sel{x}.bin", .{ corpus_dir, subdir, seed, iteration, d.selector }) catch return;

    var encoded: [40]u8 = undefined;
    d.encode(&encoded);

    const cwd = std.Io.Dir.cwd();
    const file = cwd.createFile(io, path, .{}) catch |err| {
        std.debug.print("kernel_fuzz: could not save corpus entry '{s}': {t}\n", .{ path, err });
        return;
    };
    defer file.close(io);
    var buf: [64]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(&encoded) catch |err| {
        std.debug.print("kernel_fuzz: could not write corpus entry '{s}': {t}\n", .{ path, err });
        return;
    };
    writer.interface.flush() catch {};
}
