//! Innigkeit encrypted-volume recovery tool.
//!
//! Operates on the plaintext multi-keyslot header in sector 0 of a volume image
//! (see `filesystem/VolumeHeader.zig`). The FileVault-style escape hatch: add an
//! Argon2id passphrase keyslot that wraps the AES-XTS volume key, and later
//! recover that key from the passphrase with no TPM.
//!
//! Usage:
//!   volume_recovery info <image>
//!       List the keyslots present in the header.
//!   volume_recovery add-passphrase <image> <key-hex> <passphrase>
//!       Wrap the 64-byte volume key (128 hex chars) under <passphrase> and
//!       write/replace the passphrase slot. Get <key-hex> at provision time or
//!       from a TPM unseal.
//!   volume_recovery recover <image> <passphrase>
//!       Unwrap the passphrase slot and print the recovered volume key as hex.
//!
//! The header sector is read/written in place; the rest of the image is
//! untouched.

const PassphraseKeyslot = @import("PassphraseKeyslot");
const std = @import("std");
const VolumeHeader = @import("VolumeHeader");

const sector_size = 512;

// Strong interactive-login Argon2id parameters for the recovery slot.
const argon_params: PassphraseKeyslot.Params = .{
    .t_cost = 3,
    .m_cost_kib = 64 * 1024,
    .lanes = 1,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) usage();

    const sub = args[1];
    if (std.mem.eql(u8, sub, "info")) {
        if (args.len != 3) usage();
        try cmdInfo(io, args[2]);
    } else if (std.mem.eql(u8, sub, "add-passphrase")) {
        if (args.len != 5) usage();
        try cmdAdd(io, arena, args[2], args[3], args[4]);
    } else if (std.mem.eql(u8, sub, "recover")) {
        if (args.len != 4) usage();
        try cmdRecover(io, arena, args[2], args[3]);
    } else usage();
}

fn cmdInfo(io: std.Io, path: []const u8) !void {
    var sector: [sector_size]u8 = undefined;
    try readSector(io, path, &sector);
    const h = VolumeHeader.parse(&sector) catch fatal("'{s}' has no valid INNIKVOL header", .{path});
    std.debug.print("{s}: {d} keyslot(s)\n", .{ path, h.count });
    for (h.slots[0..h.count], 0..) |s, i| {
        std.debug.print("  slot {d}: {s} ({d} bytes)\n", .{ i, @tagName(s.type), s.bytes.len });
    }
}

fn cmdAdd(io: std.Io, arena: std.mem.Allocator, path: []const u8, key_hex: []const u8, passphrase: []const u8) !void {
    var key: [PassphraseKeyslot.key_length]u8 = undefined;
    if (key_hex.len != key.len * 2) fatal("key must be {d} hex chars ({d} bytes)", .{ key.len * 2, key.len });
    _ = std.fmt.hexToBytes(&key, key_hex) catch fatal("key is not valid hex", .{});
    defer std.crypto.secureZero(u8, &key);

    var sector: [sector_size]u8 = undefined;
    try readSector(io, path, &sector);

    // Fresh entropy for the slot; wrap the key.
    var salt: [PassphraseKeyslot.salt_length]u8 = undefined;
    var nonce: [24]u8 = undefined;
    io.random(&salt);
    io.random(&nonce);
    const slot = PassphraseKeyslot.wrap(arena, io, key, passphrase, salt, nonce, argon_params) catch
        fatal("Argon2id key derivation failed", .{});

    // Rebuild the slot list: keep every non-passphrase slot, then our new one.
    const parsed = VolumeHeader.parse(&sector) catch VolumeHeader.Header{};
    // zlinter-disable-next-line require_errdefer_dealloc - arena-backed, freed with the arena
    var slots: std.ArrayList(VolumeHeader.Slot) = .empty;
    for (parsed.slots[0..parsed.count]) |s| {
        if (s.type != .passphrase) try slots.append(arena, s);
    }
    try slots.append(arena, .{ .type = .passphrase, .bytes = &slot });

    var out: [sector_size]u8 = undefined;
    VolumeHeader.write(&out, slots.items) catch fatal("header does not fit in one sector", .{});
    try writeSector(io, path, &out);
    std.debug.print("{s}: passphrase keyslot written\n", .{path});
}

fn cmdRecover(io: std.Io, arena: std.mem.Allocator, path: []const u8, passphrase: []const u8) !void {
    var sector: [sector_size]u8 = undefined;
    try readSector(io, path, &sector);
    const h = VolumeHeader.parse(&sector) catch fatal("'{s}' has no valid INNIKVOL header", .{path});
    const found = h.find(.passphrase) orelse fatal("no passphrase keyslot in '{s}'", .{path});
    if (found.len != PassphraseKeyslot.slot_length) fatal("passphrase slot is malformed", .{});

    const key = PassphraseKeyslot.unwrap(arena, io, found[0..PassphraseKeyslot.slot_length].*, passphrase) catch
        fatal("wrong passphrase (or corrupt slot)", .{});
    std.debug.print("{s}\n", .{std.fmt.bytesToHex(key, .lower)});
}

fn readSector(io: std.Io, path: []const u8, buf: *[sector_size]u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{ .mode = .read_only }) catch |err|
        fatal("cannot open '{s}': {s}", .{ path, @errorName(err) });
    defer file.close(io);
    var rbuf: [sector_size]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    reader.interface.readSliceAll(buf) catch fatal("cannot read header sector of '{s}'", .{path});
}

fn writeSector(io: std.Io, path: []const u8, buf: *const [sector_size]u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{ .mode = .read_write }) catch |err|
        fatal("cannot open '{s}' for writing: {s}", .{ path, @errorName(err) });
    defer file.close(io);
    var wbuf: [sector_size]u8 = undefined;
    var writer = file.writer(io, &wbuf);
    writer.seekTo(0) catch fatal("cannot seek in '{s}'", .{path});
    writer.interface.writeAll(buf) catch fatal("cannot write header of '{s}'", .{path});
    writer.interface.flush() catch fatal("cannot flush '{s}'", .{path});
}

fn usage() noreturn {
    std.debug.print(
        \\usage:
        \\  volume_recovery info <image>
        \\  volume_recovery add-passphrase <image> <key-hex> <passphrase>
        \\  volume_recovery recover <image> <passphrase>
        \\
    , .{});
    std.process.exit(2);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
