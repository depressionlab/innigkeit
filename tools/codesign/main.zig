//! Innigkeit rudimentary code-signing tool.
//!
//! Usage:
//!   codesign keygen
//!     Generate a fresh Ed25519 keypair:
//!       keys/codesign_public.key  (32 bytes, raw, commit this)
//!       keys/codesign_private.key (64 bytes, raw, GITIGNORED)
//!
//!   codesign sign <elf_path> <manifest.toml> <out_sig_path>
//!     Hash the ELF, parse the TOML manifest, sign with the private key,
//!     write a 144-byte .codesig blob.
//!
//!   codesign verify <elf_path> <sig_path>
//!     Verify a .codesig blob against the ELF (uses the public key).

const std = @import("std");
const toml = @import("toml");
const Blake3 = std.crypto.hash.Blake3;
const Ed25519 = std.crypto.sign.Ed25519;

const magic: [8]u8 = "IKSIG\x01\x00\x00".*;
const SigBlobSize = 144;

const SigBlob = extern struct {
    magic: [8]u8,
    key_id: u32,
    flags: u32,
    elf_hash: [32]u8,
    entitlements_raw: u64,
    _pad: [24]u8,
    signature: [64]u8,

    comptime {
        std.debug.assert(@sizeOf(SigBlob) == SigBlobSize);
    }
};

const Manifest = struct {
    name: []const u8,
    version: []const u8 = "0.0.0",
    description: []const u8 = "",
    entitlements: Entitlements = .{},
    trust: Trust = .{},

    const Entitlements = struct {
        framebuffer: bool = false, // bit 0
        storage: bool = false, // bit 1
        network: bool = false, // bit 2
        keyboard: bool = false, // bit 3
        mouse: bool = false, // bit 4
        spawn: bool = true, // bit 5
        gpu: bool = false, // bit 6
        secure_vault: bool = false, // bit 7
    };

    const Trust = struct {
        trusted_spawner_only: bool = false, // bit 8
        internal_service: bool = false, // bit 9
    };

    fn toEntitlementsRaw(m: Manifest) u64 {
        var raw: u64 = 0;
        if (m.entitlements.framebuffer) raw |= (1 << 0);
        if (m.entitlements.storage) raw |= (1 << 1);
        if (m.entitlements.network) raw |= (1 << 2);
        if (m.entitlements.keyboard) raw |= (1 << 3);
        if (m.entitlements.mouse) raw |= (1 << 4);
        if (m.entitlements.spawn) raw |= (1 << 5);
        if (m.entitlements.gpu) raw |= (1 << 6);
        if (m.entitlements.secure_vault) raw |= (1 << 7);
        if (m.trust.trusted_spawner_only) raw |= (1 << 8);
        if (m.trust.internal_service) raw |= (1 << 9);
        return raw;
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        usage();
        std.process.exit(1);
    }

    const sub = args[1];

    if (std.mem.eql(u8, sub, "keygen")) {
        try cmdKeygen(init);
    } else if (std.mem.eql(u8, sub, "sign")) {
        if (args.len != 5) {
            std.debug.print("usage: codesign sign <elf> <manifest.toml> <out.codesig>\n", .{});
            std.process.exit(1);
        }
        try cmdSign(init, args[2], args[3], args[4]);
    } else if (std.mem.eql(u8, sub, "verify")) {
        if (args.len != 4) {
            std.debug.print("usage: codesign verify <elf> <sig.codesig>\n", .{});
            std.process.exit(1);
        }
        try cmdVerify(init, args[2], args[3]);
    } else {
        usage();
        std.process.exit(1);
    }
}

fn usage() void {
    std.debug.print(
        \\Innigkeit codesign tool
        \\
        \\  codesign keygen
        \\      Generate keys/codesign_public.key and keys/codesign_private.key
        \\
        \\  codesign sign <elf> <manifest.toml> <out.codesig>
        \\      Sign an ELF binary with keys/codesign_private.key
        \\
        \\  codesign verify <elf> <sig.codesig>
        \\      Verify a .codesig blob against an ELF (uses keys/codesign_public.key)
        \\
    , .{});
}

fn cmdKeygen(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const kp = Ed25519.KeyPair.generate(io);

    const cwd = std.Io.Dir.cwd();
    cwd.createDir(io, "keys", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const pub_path = try std.fs.path.join(arena, &.{ "keys", "codesign_public.key" });
    const priv_path = try std.fs.path.join(arena, &.{ "keys", "codesign_private.key" });

    try writeFile(io, pub_path, &kp.public_key.bytes);
    try writeFile(io, priv_path, &kp.secret_key.bytes);

    std.debug.print("Generated keypair:\n  public:  {s}\n  private: {s}\n", .{ pub_path, priv_path });
    std.debug.print("Add keys/codesign_private.key to .gitignore!\n", .{});
}

fn cmdSign(init: std.process.Init, elf_path: []const u8, manifest_path: []const u8, out_path: []const u8) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    // Read ELF.
    const elf_data = try readFile(io, arena, elf_path);

    // Parse manifest.toml.
    const manifest = try parseManifest(io, arena, manifest_path);
    const entitlements_raw = manifest.toEntitlementsRaw();

    // Read private key.
    const priv_key_path = try std.fs.path.join(arena, &.{ "keys", "codesign_private.key" });
    const priv_bytes = try readFile(io, arena, priv_key_path);
    if (priv_bytes.len != Ed25519.SecretKey.encoded_length) {
        std.debug.print("error: private key must be {} bytes\n", .{Ed25519.SecretKey.encoded_length});
        std.process.exit(1);
    }
    const secret_key = try Ed25519.SecretKey.fromBytes(priv_bytes[0..Ed25519.SecretKey.encoded_length].*);
    const kp = try Ed25519.KeyPair.fromSecretKey(secret_key);

    // Hash ELF.
    var digest: [Blake3.digest_length]u8 = undefined;
    Blake3.hash(elf_data, &digest, .{});

    // Build blob (without signature).
    var blob: SigBlob = std.mem.zeroes(SigBlob);
    @memcpy(&blob.magic, &magic);
    blob.key_id = 0;
    blob.flags = 0;
    blob.elf_hash = digest;
    blob.entitlements_raw = entitlements_raw;

    // Signed message: elf_hash || entitlements_le64 || key_id_le32
    var msg: [44]u8 = undefined;
    @memcpy(msg[0..32], &blob.elf_hash);
    std.mem.writeInt(u64, msg[32..40], blob.entitlements_raw, .little);
    std.mem.writeInt(u32, msg[40..44], blob.key_id, .little);

    const sig = try kp.sign(&msg, null);
    blob.signature = sig.toBytes();

    try writeFile(io, out_path, std.mem.asBytes(&blob));
    std.debug.print("Signed '{s}' v{s}: {s} -> {s}  (entitlements: 0x{x:0>16})\n", .{
        manifest.name, manifest.version, elf_path, out_path, entitlements_raw,
    });
    std.process.exit(0);
}

fn cmdVerify(init: std.process.Init, elf_path: []const u8, sig_path: []const u8) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const elf_data = try readFile(io, arena, elf_path);
    const sig_data = try readFile(io, arena, sig_path);

    if (sig_data.len != SigBlobSize) {
        std.debug.print("error: sig file must be {} bytes\n", .{SigBlobSize});
        std.process.exit(1);
    }

    var blob: SigBlob = undefined;
    @memcpy(std.mem.asBytes(&blob), sig_data[0..SigBlobSize]);

    if (!std.mem.eql(u8, &blob.magic, &magic)) {
        std.debug.print("error: bad magic\n", .{});
        std.process.exit(1);
    }

    // Verify ELF hash.
    var digest: [Blake3.digest_length]u8 = undefined;
    Blake3.hash(elf_data, &digest, .{});
    if (!std.mem.eql(u8, &digest, &blob.elf_hash)) {
        std.debug.print("FAIL: ELF hash mismatch\n", .{});
        std.process.exit(1);
    }

    // Read public key.
    const pub_key_path = try std.fs.path.join(arena, &.{ "keys", "codesign_public.key" });
    const pub_bytes = try readFile(io, arena, pub_key_path);
    if (pub_bytes.len != Ed25519.PublicKey.encoded_length) {
        std.debug.print("error: public key must be {} bytes\n", .{Ed25519.PublicKey.encoded_length});
        std.process.exit(1);
    }
    const pub_key = try Ed25519.PublicKey.fromBytes(pub_bytes[0..Ed25519.PublicKey.encoded_length].*);

    // Verify Ed25519 signature.
    var msg: [44]u8 = undefined;
    @memcpy(msg[0..32], &blob.elf_hash);
    std.mem.writeInt(u64, msg[32..40], blob.entitlements_raw, .little);
    std.mem.writeInt(u32, msg[40..44], blob.key_id, .little);

    const sig = Ed25519.Signature.fromBytes(blob.signature);
    sig.verify(&msg, pub_key) catch {
        std.debug.print("FAIL: Ed25519 signature mismatch\n", .{});
        std.process.exit(1);
    };

    std.debug.print("OK: signature valid\n", .{});
    printEntitlements(blob.entitlements_raw);
}

fn printEntitlements(raw: u64) void {
    const names = [_]struct { name: []const u8, bit: u6 }{
        .{ .name = "framebuffer", .bit = 0 },
        .{ .name = "storage", .bit = 1 },
        .{ .name = "network", .bit = 2 },
        .{ .name = "keyboard", .bit = 3 },
        .{ .name = "mouse", .bit = 4 },
        .{ .name = "spawn", .bit = 5 },
        .{ .name = "gpu", .bit = 6 },
        .{ .name = "secure_vault", .bit = 7 },
        .{ .name = "trusted_spawner_only", .bit = 8 },
        .{ .name = "internal_service", .bit = 9 },
    };
    std.debug.print("  entitlements: 0x{x:0>16}\n", .{raw});
    for (names) |e| {
        if (raw & (@as(u64, 1) << e.bit) != 0)
            std.debug.print("    + {s}\n", .{e.name});
    }
}

fn parseManifest(io: std.Io, arena: std.mem.Allocator, path: []const u8) !Manifest {
    const data = try readFile(io, arena, path);
    var parser = toml.Parser(Manifest).init(arena);
    defer parser.deinit();
    const result = parser.parseString(data) catch |err| {
        std.debug.print("error: cannot parse manifest '{s}': {s}\n", .{ path, @errorName(err) });
        if (parser.error_info) |einfo| {
            switch (einfo) {
                .parse => |pos| std.debug.print("  parse error at line {}, pos {}\n", .{ pos.line, pos.pos }),
                .struct_mapping => |fp| {
                    std.debug.print("  missing or invalid field: ", .{});
                    for (fp, 0..) |seg, i| {
                        if (i > 0) std.debug.print(".", .{});
                        std.debug.print("{s}", .{seg});
                    }
                    std.debug.print("\n", .{});
                },
            }
        }
        std.process.exit(1);
    };
    // result.deinit() would free string slices; keep result alive for the
    // caller's lifetime by not deferring deinit here, the arena owns it.
    return result.value;
}

fn readFile(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: [std.heap.page_size_min]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch |err| {
        std.debug.print("error: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    defer file.close(io);
    var reader = file.reader(io, &buf);
    return reader.interface.allocRemaining(arena, .unlimited) catch |err| {
        std.debug.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

test "manifest: toEntitlementsRaw defaults" {
    const m: Manifest = .{ .name = "test" };
    const raw = m.toEntitlementsRaw();
    // Only spawn (bit 5) is set by default.
    try std.testing.expectEqual(@as(u64, 1 << 5), raw);
}

test "manifest: toEntitlementsRaw all-set" {
    const m: Manifest = .{
        .name = "test",
        .version = "0.1.0",
        .description = "test description",
        .entitlements = .{
            .framebuffer = true,
            .storage = true,
            .network = true,
            .keyboard = true,
            .mouse = true,
            .spawn = true,
            .gpu = true,
            .secure_vault = true,
        },
        .trust = .{
            .trusted_spawner_only = true,
            .internal_service = true,
        },
    };
    const raw = m.toEntitlementsRaw();
    try std.testing.expectEqual(@as(u64, 0x3FF), raw); // bits 0-9 all set
}
