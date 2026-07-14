//! Cross-platform UEFI Secure Boot signing/enrollment tool.
//!
//! Usage:
//!   secureboot keygen [dir=keys/secureboot]
//!     Idempotently generate self-signed PK/KEK/db RSA-2048 certs.
//!
//!   secureboot enroll <vars_tmpl> <out_vars> <guid> <pk.crt> <kek.crt> <db.crt>
//!     Enroll PK/KEK/db into a fresh OVMF VARS store via `virt-fw-vars`.
//!
//!   secureboot sign <image.hdd> <db.key> <db.crt> [--esp-lba <n>]
//!     Enroll the limine.conf hash into BOOTX64.EFI, sign it, and write it
//!     back into the ESP. Default --esp-lba is 4096 (GPT partition 2 start,
//!     matching this repo's image layout).

const builtin = @import("builtin");
const std = @import("std");
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        usage();
        std.process.exit(1);
    }
    const sub = args[1];

    if (std.mem.eql(u8, sub, "keygen")) {
        const dir = if (args.len >= 3) args[2] else "keys/secureboot";
        try cmdKeygen(init, dir);
    } else if (std.mem.eql(u8, sub, "enroll")) {
        if (args.len != 8) {
            std.debug.print("usage: secureboot enroll <vars_tmpl> <out_vars> <guid> <pk.crt> <kek.crt> <db.crt>\n", .{});
            std.process.exit(1);
        }
        try cmdEnroll(init, args[2], args[3], args[4], args[5], args[6], args[7]);
    } else if (std.mem.eql(u8, sub, "sign")) {
        if (args.len < 5) {
            std.debug.print("usage: secureboot sign <image.hdd> <db.key> <db.crt> [--esp-lba <n>]\n", .{});
            std.process.exit(1);
        }
        var esp_lba: u64 = 4096;
        if (args.len >= 7 and std.mem.eql(u8, args[5], "--esp-lba")) {
            esp_lba = std.fmt.parseInt(u64, args[6], 10) catch {
                std.debug.print("error: --esp-lba must be a positive integer\n", .{});
                std.process.exit(1);
            };
        }
        try cmdSign(init, args[2], args[3], args[4], esp_lba);
    } else {
        usage();
        std.process.exit(1);
    }
}

fn usage() void {
    std.debug.print(
        \\Innigkeit UEFI Secure Boot signing tool
        \\
        \\  secureboot keygen [dir=keys/secureboot]
        \\      Idempotently generate self-signed PK/KEK/db RSA-2048 certs
        \\
        \\  secureboot enroll <vars_tmpl> <out_vars> <guid> <pk.crt> <kek.crt> <db.crt>
        \\      Enroll PK/KEK/db into a fresh OVMF VARS store
        \\
        \\  secureboot sign <image.hdd> <db.key> <db.crt> [--esp-lba <n>]
        \\      Enroll-config + sign the image's bootloader (default esp-lba 4096)
        \\
    , .{});
}

fn cmdKeygen(init: std.process.Init, dir: []const u8) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();

    cwd.createDirPath(io, dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    inline for (.{ "PK", "KEK", "db" }) |name| {
        const key_path = try std.Io.Dir.path.join(arena, &.{ dir, name ++ ".key" });
        const crt_path = try std.Io.Dir.path.join(arena, &.{ dir, name ++ ".crt" });

        if (fileExists(io, key_path) and fileExists(io, crt_path)) {
            std.debug.print("{s}: already present ({s}, {s}), skipping\n", .{ name, key_path, crt_path });
        } else {
            _ = runChecked(arena, io, &.{
                "openssl", "req",
                "-newkey", "rsa:2048",
                "-nodes",  "-keyout",
                key_path,  "-new",
                "-x509",   "-sha256",
                "-days",   "3650",
                "-subj",   "/CN=Innigkeit Secure Boot " ++ name ++ "/",
                "-out",    crt_path,
            }, null);
            std.debug.print("generated {s} -> {s}, {s}\n", .{ name, key_path, crt_path });
        }
    }
}

fn cmdEnroll(
    init: std.process.Init,
    vars_tmpl: []const u8,
    out_vars: []const u8,
    guid: []const u8,
    pk_crt: []const u8,
    kek_crt: []const u8,
    db_crt: []const u8,
) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    _ = runChecked(arena, io, &.{
        "virt-fw-vars",   "-i", vars_tmpl,
        "--set-pk",       guid, pk_crt,
        "--add-kek",      guid, kek_crt,
        "--add-db",       guid, db_crt,
        "--no-microsoft", "-o", out_vars,
    }, null);
    std.debug.print("enrolled PK/KEK/db from {s} -> {s}\n", .{ vars_tmpl, out_vars });
}

fn cmdSign(init: std.process.Init, image_path: []const u8, db_key: []const u8, db_crt: []const u8, esp_lba: u64) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();

    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const work = try std.fmt.allocPrint(arena, "/tmp/innigkeit-secureboot-sign-{s}", .{
        std.fmt.bytesToHex(rand_bytes, .lower),
    });
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    const conf_path = try std.Io.Dir.path.join(arena, &.{ work, "limine.conf" });
    const efi_path = try std.Io.Dir.path.join(arena, &.{ work, "BOOTX64.EFI" });
    const signed_path = try std.Io.Dir.path.join(arena, &.{ work, "BOOTX64.signed.EFI" });
    const image_spec = try std.fmt.allocPrint(arena, "{s}@@{d}", .{ image_path, esp_lba * 512 });

    // mtools refuses non-standard-looking FAT filesystems without this.
    try init.environ_map.put("MTOOLS_SKIP_CHECK", "1");

    _ = runChecked(arena, io, &.{ "mcopy", "-i", image_spec, "::/limine.conf", conf_path }, init.environ_map);
    _ = runChecked(arena, io, &.{ "mcopy", "-i", image_spec, "::/EFI/BOOT/BOOTX64.EFI", efi_path }, init.environ_map);

    const conf_bytes = try readFile(io, arena, conf_path);
    var digest: [Blake2b512.digest_length]u8 = undefined;
    Blake2b512.hash(conf_bytes, &digest, .{});
    const hash_hex = std.fmt.bytesToHex(digest, .lower);

    const efi_path_z: [:0]u8 = try arena.dupeSentinel(u8, efi_path, 0);
    const hash_hex_z: [:0]u8 = try arena.dupeSentinel(u8, &hash_hex, 0);
    const limine_argv = [_][*:0]const u8{ "limine", "enroll-config", efi_path_z, hash_hex_z };
    const rc = limine_main(@intCast(limine_argv.len), &limine_argv);
    if (rc != 0) {
        std.debug.print("error: limine enroll-config failed (exit {d})\n", .{rc});
        std.process.exit(1);
    }

    switch (builtin.os.tag) {
        .linux => _ = runChecked(arena, io, &.{
            "sbsign",    "--key",
            db_key,      "--cert",
            db_crt,      "--output",
            signed_path, efi_path,
        }, null),
        .macos => _ = runChecked(arena, io, &.{
            "osslsigncode", "sign",
            "-key",         db_key,
            "-certs",       db_crt,
            "-in",          efi_path,
            "-out",         signed_path,
        }, null),
        else => {
            std.debug.print("error: secure boot signing is only supported on linux and macos\n", .{});
            std.process.exit(1);
        },
    }

    _ = runChecked(arena, io, &.{
        "mcopy",
        "-D",
        "o",
        "-i",
        image_spec,
        signed_path,
        "::/EFI/BOOT/BOOTX64.EFI",
    }, init.environ_map);

    std.debug.print("signed {s} (esp_lba={d}, hash={s})\n", .{ image_path, esp_lba, hash_hex });
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn readFile(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: [std.heap.page_size_min]u8 = undefined;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
        std.debug.print("error: cannot open '{s}': {t}\n", .{ path, e });
        std.process.exit(1);
    };
    defer file.close(io);
    var reader = file.reader(io, &buf);
    return reader.interface.allocRemaining(arena, .unlimited) catch |e| {
        std.debug.print("error: cannot read '{s}': {t}\n", .{ path, e });
        std.process.exit(1);
    };
}

/// Runs `argv`, exiting the process with a clear message on spawn failure,
/// non-zero exit, or abnormal termination. Returns the child's stdout.
fn runChecked(
    arena: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
) []u8 {
    const result = std.process.run(arena, io, .{
        .argv = argv,
        .environ_map = environ_map,
    }) catch |e| {
        std.debug.print("error: unable to run '{s}' (is it installed?): {t}\n", .{ argv[0], e });
        std.process.exit(1);
    };
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print(
                "error: '{s}' exited with code {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
                .{ argv[0], code, result.stdout, result.stderr },
            );
            std.process.exit(1);
        },
        else => {
            std.debug.print("error: '{s}' terminated abnormally\n--- stderr ---\n{s}\n", .{ argv[0], result.stderr });
            std.process.exit(1);
        },
    }
    return result.stdout;
}

extern fn limine_main(argc: c_int, argv: [*]const [*:0]const u8) c_int;

comptime {
    std.testing.refAllDecls(@This());
}
