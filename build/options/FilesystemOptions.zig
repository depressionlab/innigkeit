const FilesystemOptions = @This();

const std = @import("std");

raw_initfs: bool,
compression_level: u8,
compression_threads: u8,

pub fn get(b: *std.Build) FilesystemOptions {
    const raw_initfs = b.option(bool, "raw_initfs", "skip initfs.tar compression (default: false)") orelse false;
    const compression_level = b.option(u8, "zstd_level", "initfs.tar zstd compression level (default: 8)") orelse 8;
    const compression_threads = b.option(u8, "zstd_threads", "initfs.tar zstd compression parallelism (0 for auto) (default: auto)") orelse 0;

    return .{
        .raw_initfs = raw_initfs,
        .compression_level = compression_level,
        .compression_threads = compression_threads,
    };
}
