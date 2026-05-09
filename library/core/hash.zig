const std = @import("std");
const readInt = std.mem.readInt;
const readIntPartial = @import("core").readIntPartial;

// FAST HASHING ALGORITHM

// folded multiply with a faster 32-bit path
// borrowed from foldhash and modified a bit
pub inline fn mix(x: u64, y: u64) u64 {
    const builtin = @import("builtin");
    const target = builtin.target;
    const cpu = builtin.cpu;

    // sparc64 and wasm64 do not have 128-bit widening multiplication
    // x86-64 and aarch64 should have it regardless of abi, but abi may reduce ptr bit width
    const wide_mul = (target.ptrBitWidth() == 64 and cpu.arch != .sparc64 and cpu.arch != .wasm64) or
        (cpu.arch == .x86_64 or cpu.arch.isAARCH64()) or
        (cpu.arch.isWasm() and cpu.has(.wasm, .wide_arithmetic));

    if (wide_mul) {
        const full = @as(u128, x) * @as(u128, y);
        const lo: u64 = @truncate(full);
        const hi: u64 = @truncate(full >> 64);
        return lo ^ hi;
    }

    // we don't need a super accurate approximation, so we do half the work here that foldhash does
    // this should still do a good job of mixing bits around, but it's a lot faster

    const lx: u32 = @truncate(x);
    const ly: u32 = @truncate(y);
    const hx: u32 = @truncate(x >> 32);
    const hy: u32 = @truncate(y >> 32);

    const ll = @as(u64, lx) * @as(u64, ly);
    const hh = @as(u64, hx) * @as(u64, hy);

    return ll ^ hh;
}

/// Hash function optimized for small strings.
/// Quality degrades significantly with higher input size. Use with caution.
pub fn microhash(seed: u64, input: []const u8) u64 {
    var ptr = input.ptr;
    var len = input.len;
    // mixing in the digits of pi for entropy
    var out = 0x3243F6A8885A308D ^ seed ^ len;

    while (len > 16) : (len -= 16) {
        const x = readInt(u64, @ptrCast(ptr), .little);
        const y = readInt(u64, @ptrCast(ptr + 8), .little);
        out = mix(out ^ x, y);
        out = std.math.rotr(u64, out, 23);
        ptr += 16;
    }

    if (len > 8) {
        const x = readInt(u64, @ptrCast(ptr), .little);
        const y = readIntPartial(u64, (ptr + 8)[0 .. len - 8], .little);
        out = mix(out ^ x, y);
    } else if (len > 0) {
        const x = readIntPartial(u64, ptr[0..len], .little);
        out = mix(out, x);
    }

    return out;
}

// FAST STRING HASHMAPS

pub const FastStringContext = struct {
    pub fn hash(_: @This(), s: []const u8) u64 {
        return microhash(0, s);
    }
    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

pub fn FastStringHashMap(comptime V: type) type {
    return std.HashMap([]const u8, V, FastStringContext, std.hash_map.default_max_load_percentage);
}
pub fn FastStringHashMapUnmanaged(comptime V: type) type {
    return std.HashMapUnmanaged([]const u8, V, FastStringContext, std.hash_map.default_max_load_percentage);
}

pub const FastStringArrayContext = struct {
    pub fn hash(_: @This(), s: []const u8) u32 {
        return @truncate(microhash(0, s));
    }
    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

pub fn FastStringArrayHashMap(comptime V: type) type {
    return std.array_hash_map.Custom([]const u8, V, FastStringArrayContext, true);
}

// pub fn ComptimeStringHashMap(comptime V: type, comptime Context: type, comptime values: anytype) type {
//     const chm = @import("comptime_hash_map");

//     comptime var min_len = std.math.maxInt(usize);
//     comptime var max_len = 0;
//     for (values) |kv| {
//         const key: []const u8 = kv.@"0";
//         min_len = @min(key.len, min_len);
//         max_len = @max(key.len, max_len);
//     }

//     return struct {
//         const map = chm.ComptimeHashMap([]const u8, V, Context, values);

//         pub fn has(key: []const u8) bool {
//             return get(key) != null;
//         }

//         pub fn get(key: []const u8) ?V {
//             if (key.len < min_len or key.len > max_len) return null;
//             // hopefully this will optimize away the reference
//             const value = @call(.always_inline, map.get, .{key});
//             return if (value) |v| v.* else null;
//         }
//     };
// }

// /// Creates a static map of strings to enum values at compile time.
// pub fn EnumStringMap(comptime T: type, comptime Context: type) type {
//     const type_info = @typeInfo(T);
//     if (type_info != .@"enum") @compileError("enumStringMap with non-enum type");

//     const fields = @typeInfo(T).@"enum".fields;
//     comptime var out: [fields.len]struct { []const u8, T } = undefined;
//     inline for (fields, 0..) |field, i|
//         out[i] = .{ field.name, @field(T, field.name) };

//     return ComptimeStringHashMap(T, Context, out);
// }

// test EnumStringMap {
//     const Enum = enum { foo, bar, baz, qux };
//     const map = EnumStringMap(Enum, FastStringContext);
//     try std.testing.expectEqual(map.get("foo").?, Enum.foo);
//     try std.testing.expectEqual(map.get("bar").?, Enum.bar);
//     try std.testing.expectEqual(map.get("baz").?, Enum.baz);
//     try std.testing.expectEqual(map.get("qux").?, Enum.qux);
// }
