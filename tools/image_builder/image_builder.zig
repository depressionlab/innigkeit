const std = @import("std");
const core = @import("core");
const filesystem = @import("filesystem");

const ImageDescription = @import("image/ImageDescription.zig");
const Gpt = @import("gpt/root.zig");
const FAT = @import("fat/root.zig");

pub const disk_block_size: core.Size = .from(512, .byte);

pub fn main(init: std.process.Init) !void {
    const arguments = try getArguments(init.arena.allocator(), init.io, init.minimal.args);

    var rand = std.Random.DefaultPrng.init(blk: {
        var int: u64 = undefined;
        init.io.random(std.mem.asBytes(&int));
        break :blk int;
    });
    const random = rand.random();

    try createDiskImage(init.arena.allocator(), init.io, arguments, random);
}

const Arguments = struct {
    output_path: []const u8,
    image_description: *ImageDescription.Parsed,

    pub fn deinit(arguments: Arguments, allocator: std.mem.Allocator) void {
        allocator.free(arguments.output_path);
        arguments.image_description.deinit();
        allocator.destroy(arguments.image_description);
    }
};

fn usageError(err_msg: []const u8) noreturn {
    const usage =
        \\Usage: image_builder [image_description_path|-] output_path
        \\
    ;

    std.debug.print(comptime "{s}\n\n" ++ usage, .{err_msg});
    std.process.exit(1);
}

fn getArguments(arena: std.mem.Allocator, io: std.Io, args: std.process.Args) !Arguments {
    const args_slice = try args.toSlice(arena);

    if (args_slice.len != 3) { // first argument is the executable name
        usageError("incorrect number of arguments given");
    }

    const image_description_contents = blk: {
        const file = if (std.mem.eql(u8, args_slice[1], "-"))
            std.Io.File.stdin()
        else
            try std.Io.Dir.cwd().openFile(io, args_slice[1], .{});
        defer file.close(io);

        var buf: [std.heap.page_size_min]u8 = undefined;
        var reader = file.reader(io, &buf);
        break :blk try reader.interface.allocRemaining(arena, .unlimited);
    };

    const image_description = try arena.create(ImageDescription.Parsed);
    image_description.* = try ImageDescription.parse(arena, image_description_contents);

    return .{
        .output_path = args_slice[2],
        .image_description = image_description,
    };
}

fn createDiskImage(allocator: std.mem.Allocator, io: std.Io, arguments: Arguments, random: std.Random) !void {
    const image_description = arguments.image_description.image_description;

    const disk_size = blk: {
        if (!std.mem.isAligned(image_description.size, disk_block_size.value)) {
            @panic("image size is not a multiple of 512 bytes!");
        }
        break :blk core.Size.from(image_description.size, .byte);
    };

    const disk_image = try createAndMapDiskImage(io, arguments.output_path, disk_size);
    defer std.posix.munmap(disk_image);

    const gpt_partitions = try allocator.alloc(Gpt.Partition, image_description.partitions.len);
    defer allocator.free(gpt_partitions);

    try Gpt.create(allocator, image_description, disk_image, random, gpt_partitions);

    for (image_description.partitions, gpt_partitions) |partition, gpt_partition| {
        const partition_slice = disk_image[gpt_partition.start_block * disk_block_size.value ..][0 .. gpt_partition.block_count * disk_block_size.value];

        switch (partition.filesystem) {
            .none => {},
            .fat32 => try FAT.create(
                allocator,
                io,
                partition,
                partition_slice,
            ),
        }
    }
}

fn createAndMapDiskImage(io: std.Io, disk_image_path: []const u8, disk_size: core.Size) ![]align(std.heap.page_size_min) u8 {
    const file = if (std.fs.path.dirname(disk_image_path)) |dir_path| blk: {
        var parent_directory = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
        defer parent_directory.close(io);
        break :blk try parent_directory.createFile(
            io,
            std.fs.path.basename(disk_image_path),
            .{ .truncate = true, .read = true },
        );
    } else try std.Io.Dir.cwd().createFile(io, disk_image_path, .{ .truncate = true, .read = true });
    defer file.close(io);

    try file.setLength(io, disk_size.value);

    return std.posix.mmap(
        null,
        disk_size.value,
        .{
            .READ = true,
            .WRITE = true,
        },
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );
}

pub inline fn asPtr(comptime T: type, file_contents: []u8, index: usize, item_size: core.Size) T {
    return @ptrCast(@alignCast(file_contents.ptr + (index * item_size.value)));
}

comptime {
    std.testing.refAllDecls(@This());
}
