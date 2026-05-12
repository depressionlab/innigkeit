const std = @import("std");
const innigkeit = @import("innigkeit");

pub fn ChunkMap(comptime T: type) type {
    return struct {
        chunks: std.AutoHashMapUnmanaged(u32, Chunk) = .{},

        const Chunk = [slots_per_chunk]?*T;

        pub fn get(self: *const @This(), index: u32) ?*T {
            const chunk = self.getChunk(index) orelse return null;
            return chunk[chunkOffset(index)];
        }

        pub fn getChunk(self: *const @This(), index: u32) ?*Chunk {
            return self.chunks.getPtr(chunkIndex(index)) orelse null;
        }

        pub fn ensureChunk(self: *@This(), index: u32) !*Chunk {
            const chunk = try self.chunks.getOrPut(innigkeit.mem.heap.allocator, chunkIndex(index));
            if (!chunk.found_existing) {
                chunk.value_ptr.* = @splat(null);
            }
            return chunk.value_ptr;
        }

        /// Deinitializes the chunk map.
        pub fn deinit(self: *@This()) void {
            self.chunks.deinit(innigkeit.mem.heap.allocator);
        }

        pub inline fn chunkIndex(index: u32) u32 {
            // valid as `slots_per_chunk` is a power of two
            return index >> slots_per_chunk_shift;
        }

        pub inline fn chunkOffset(index: u32) u32 {
            // valid as `slots_per_chunk` is a power of two
            return index & (slots_per_chunk - 1);
        }
    };
}

const slots_per_chunk_shift = std.math.log2(slots_per_chunk);
const slots_per_chunk = 16;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(slots_per_chunk));
}
