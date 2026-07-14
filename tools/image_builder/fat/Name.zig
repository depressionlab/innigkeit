const Name = @This();

const core = @import("core");
const filesystem = @import("filesystem");
const std = @import("std");

allocator: std.mem.Allocator,
short_name: filesystem.fat.ShortFileName,

/// Is guarenteed to have a trailing zero
long_name: ?[]const u8,

pub fn deinit(self: Name) void {
    if (self.long_name) |long_name| self.allocator.free(long_name);
}

pub fn create(allocator: std.mem.Allocator, name: []const u8) !Name {
    const filename = std.Io.Dir.path.stem(name);
    const extension = std.Io.Dir.path.extension(name);

    var needs_long_name = false;

    var short_name: filesystem.fat.ShortFileName = .{};

    if (extension.len != 0) {
        if (core.is_debug) std.debug.assert(extension[0] == '.');
        const trimmed_extension = extension[1..];

        for (trimmed_extension, 0..) |char, i| {
            if (i >= filesystem.fat.ShortFileName.extension_max_length) {
                needs_long_name = true;
                break;
            }

            if (std.ascii.isLower(char)) {
                needs_long_name = true;
                short_name.extension[i] = std.ascii.toUpper(char);
            } else {
                short_name.extension[i] = char;
            }
        }
    }

    var filename_truncated = false;

    for (filename, 0..) |char, i| {
        if (i >= filesystem.fat.ShortFileName.file_name_max_length) {
            filename_truncated = true;
            needs_long_name = true;
            break;
        }

        if (std.ascii.isLower(char)) {
            needs_long_name = true;
            short_name.name[i] = std.ascii.toUpper(char);
        } else {
            short_name.name[i] = char;
        }
    }

    if (filename_truncated) {
        short_name.name[short_name.name.len - 2] = '~';
        // TODO: Always using 1 is incorrect as duplicates are possible.
        short_name.name[short_name.name.len - 1] = '1';
    }

    return .{
        .allocator = allocator,
        .short_name = short_name,
        .long_name = if (needs_long_name) try std.mem.concat(allocator, u8, &.{ name, "\x00" }) else null,
    };
}
