// TODO: split this file without tragic

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const RawCache = innigkeit.mem.cache.RawCache;
const core = @import("core");

const log = innigkeit.debug.log.scoped(.arena);
const globals = @import("globals.zig");

/// A general resource arena providing reasonably low fragmentation with constant time performance.
///
/// Based on [Magazines and Vmem: Extending the Slab Allocator to Many CPUs and Arbitrary Resources](https://www.usenix.org/legacy/publications/library/proceedings/usenix01/full_papers/bonwick/bonwick.pdf) by Jeff Bonwick and Jonathan Adams.
///
/// Written with reference to the following sources, no code was copied:
///  - [bonwick01](https://www.usenix.org/legacy/publications/library/proceedings/usenix01/full_papers/bonwick/bonwick.pdf)
///  - [illumos](https://github.com/illumos/illumos-gate/blob/master/usr/src/uts/common/os/vmem.c)
///  - [lylythechosenone's rust crate](https://github.com/lylythechosenone/vmem/blob/main/src/lib.rs)
///
pub fn Arena(comptime quantum_caching: QuantumCaching) type {
    return struct {
        _name: innigkeit.mem.arena.Name,
        quantum: usize,
        mutex: innigkeit.sync.Mutex,
        source: ?innigkeit.mem.arena.Source,

        /// List of all boundary tags in the arena.
        ///
        /// In order of ascending `base`.
        all_tags: DoublyLinkedList(AllTagNode),

        /// List of all spans in the arena.
        ///
        /// In order of ascending `base`.
        spans: DoublyLinkedList(KindNode),

        /// Hash table of allocated boundary tags.
        allocation_table: [globals.NUMBER_OF_HASH_BUCKETS]DoublyLinkedList(KindNode),

        /// Power-of-two freelists.
        freelists: [globals.NUMBER_OF_FREELISTS]DoublyLinkedList(KindNode),

        /// Bitmap of freelists that are non-empty.
        freelist_bitmap: Bitmap,

        /// List of unused boundary tags.
        unused_tags: SinglyLinkedList,

        /// Number of unused boundary tags.
        unused_tags_count: usize,

        quantum_caches: QuantumCaches,

        pub fn name(self: *const @This()) []const u8 {
            return self._name.constSlice();
        }

        pub fn init(self: *@This(), options: innigkeit.mem.arena.InitOptions) innigkeit.mem.arena.InitError!void {
            if (!std.mem.isValidAlign(options.quantum)) return innigkeit.mem.arena.InitError.InvalidQuantum;

            log.debug("{s}: init with quantum 0x{x}", .{ options.name.constSlice(), options.quantum });

            self.* = .{
                ._name = options.name,
                .quantum = options.quantum,
                .mutex = .{},
                .source = options.source,
                .all_tags = .empty,
                .spans = .empty,
                .allocation_table = @splat(.empty),
                .freelists = @splat(.empty),
                .freelist_bitmap = .empty,
                .unused_tags = .empty,
                .unused_tags_count = 0,
                .quantum_caches = .{
                    .allocation = undefined, // set below
                    .max_cached_size = undefined, // set below
                },
            };

            switch (quantum_caching) {
                .none => {},
                .normal => |count| {
                    if (core.is_debug) std.debug.assert(count > 0);

                    const quantum_caches = innigkeit.mem.heap.allocator.alloc(RawCache, count) catch
                        @panic("quantum cache allocation failed!"); // TODO: return this error

                    for (quantum_caches, 0..) |*quantum_cache, i| {
                        var cache_name: innigkeit.mem.cache.Name = .{};
                        cache_name.writer().print("{s} qcache {}", .{ self.name(), i + 1 }) catch unreachable;

                        quantum_cache.init(.{
                            .name = cache_name,
                            .size = options.quantum * (i + 1),
                            .alignment = .fromByteUnits(options.quantum),
                        });
                        self.quantum_caches.caches.append(quantum_cache) catch unreachable;
                    }

                    self.quantum_caches.allocation = quantum_caches;
                    self.quantum_caches.max_cached_size = count * options.quantum;
                },
                .heap => |count| {
                    if (core.is_debug) std.debug.assert(count > 0);

                    var pages: innigkeit.mem.PhysicalPage.List = .{};

                    var caches_created: usize = 0;

                    const pages_to_allocate = architecture.paging.standard_page_size.amountToCover(
                        core.Size.of(RawCache).multiplyScalar(count),
                    );

                    for (0..pages_to_allocate) |_| {
                        const page = innigkeit.mem.PhysicalPage.allocator.allocate() catch
                            @panic("heap quantum cache allocation failed!");
                        pages.prepend(page);

                        const page_caches = page.baseAddress().toDirectMap()
                            .toPtr(*[globals.QUANTUM_CACHES_PER_PAGE]RawCache);

                        for (page_caches) |*cache| {
                            caches_created += 1;

                            cache.init(.{
                                .name = innigkeit.mem.cache.Name.initPrint(
                                    "heap qcache {}",
                                    .{caches_created},
                                ) catch unreachable,
                                .size = core.Size.from(options.quantum, .byte).multiplyScalar(caches_created),
                                .alignment = .fromByteUnits(options.quantum),
                            });

                            self.quantum_caches.caches.append(cache) catch unreachable;

                            if (caches_created == count) break;
                        }
                    }

                    self.quantum_caches.allocation = pages;
                    self.quantum_caches.max_cached_size = count * options.quantum;
                },
            }
        }

        /// Destroy the resource arena.
        ///
        /// Assumes that no concurrent access to the resource arena is happening, does not lock.
        ///
        /// Panics if there are any allocations in the resource arena.
        pub fn deinit(self: *@This()) void {
            log.debug("{s}: deinit", .{self.name()});

            if (quantum_caching.haveQuantumCache()) {
                for (self.quantum_caches.caches.constSlice()) |quantum_cache| {
                    quantum_cache.deinit();
                }

                switch (quantum_caching) {
                    .no => {},
                    .yes => innigkeit.mem.heap.allocator.free(self.quantum_caches.allocation),
                    .heap => innigkeit.mem.phys.allocator.deallocate(self.quantum_caches.allocation),
                }
            }

            var tags_to_release: SinglyLinkedList = .empty;

            var any_allocations = false;

            // return imported spans and add all used boundary tags to the `tags_to_release` list
            while (self.all_tags.pop()) |node| {
                const tag = node.toTag();

                switch (tag.kind) {
                    .imported_span => self.source.?.callRelease(
                        .{
                            .base = tag.base,
                            .len = tag.len,
                        },
                    ),
                    .allocated => any_allocations = true,
                    .span, .free => {},
                }

                tags_to_release.push(node);
            }

            // add all unused tags to the `tags_to_release` list
            while (self.unused_tags.pop()) |node| {
                tags_to_release.push(node);
            }

            // return all tags to the global tag cache
            var any_tags_to_release = tags_to_release.first != null;
            while (any_tags_to_release) {
                const capacity = globals.MAX_TAGS_PER_ALLOCATION * 4;
                var temp_tag_buffer: core.containers.BoundedArray(
                    *BoundaryTag,
                    capacity,
                ) = .{};

                while (temp_tag_buffer.len < capacity) {
                    const node = tags_to_release.pop() orelse {
                        any_tags_to_release = false;
                        break;
                    };

                    temp_tag_buffer.appendAssumeCapacity(node.toTag());
                }

                globals.tag_cache.deallocateMany(temp_tag_buffer.constSlice());
            }

            if (any_allocations) {
                // TODO: log instead?
                std.debug.panic(
                    "leaks detected when deinitializing arena '{s}'!",
                    .{self.name()},
                );
            }

            self.* = undefined;
        }

        /// Add the span [base, base + len) to the arena.
        ///
        /// Both `base` and `len` must be aligned to the arena's quantum.
        ///
        /// O(N) runtime.
        pub fn addSpan(self: *@This(), base: usize, len: usize) innigkeit.mem.arena.AddSpanError!void {
            log.debug("{s}: adding span [0x{x}, 0x{x})", .{ self.name(), base, base + len });

            try self.ensureBoundaryTags();
            defer self.mutex.unlock();

            const span_tag, const free_tag =
                try self.getTagsForNewSpan(base, len, .span);
            errdefer {
                self.pushUnusedTag(span_tag);
                self.pushUnusedTag(free_tag);
            }

            try self.addSpanInner(span_tag, free_tag, .add);
        }

        fn getTagsForNewSpan(
            self: *@This(),
            base: usize,
            len: usize,
            span_type: enum { imported_span, span },
        ) innigkeit.mem.arena.AddSpanError!struct { *BoundaryTag, *BoundaryTag } {
            if (len == 0) return innigkeit.mem.arena.AddSpanError.ZeroLength;

            if (std.math.maxInt(usize) - base < len) return innigkeit.mem.arena.AddSpanError.WouldWrap;

            if (!std.mem.isAligned(base, self.quantum) or
                !std.mem.isAligned(len, self.quantum))
            {
                return innigkeit.mem.arena.AddSpanError.Unaligned;
            }
            errdefer comptime unreachable;

            const span_tag = self.popUnusedTag();
            span_tag.* = .{
                .base = base,
                .len = len,
                .all_tag_node = .empty,
                .kind_node = .empty,
                .kind = switch (span_type) {
                    .imported_span => .imported_span,
                    .span => .span,
                },
            };

            const free_tag = self.popUnusedTag();
            free_tag.* = .{
                .base = base,
                .len = len,
                .all_tag_node = .empty,
                .kind_node = .empty,
                .kind = .free,
            };

            return .{ span_tag, free_tag };
        }

        fn addSpanInner(
            self: *@This(),
            span_tag: *BoundaryTag,
            free_tag: *BoundaryTag,
            comptime freelist_decision: enum { add, nop },
        ) error{Overlap}!void {
            if (core.is_debug) {
                std.debug.assert(span_tag.kind == .span or span_tag.kind == .imported_span);
                std.debug.assert(free_tag.kind == .free);
            }

            const opt_previous_span = try self.findSpanListPreviousSpan(span_tag.base, span_tag.len);

            errdefer comptime unreachable;

            const previous_all_tag_node = findSpanAllTagInsertionPoint(opt_previous_span);

            // insert the new span into the list of spans
            self.spans.insertAfter(
                &span_tag.kind_node,
                if (opt_previous_span) |previous_span| &previous_span.kind_node else null,
            );

            // insert the new span tag into the list of all tags
            self.all_tags.insertAfter(
                &span_tag.all_tag_node,
                previous_all_tag_node,
            );

            // insert the new free tag into the list of all tags (after the span tag)
            self.all_tags.insertAfter(
                &free_tag.all_tag_node,
                &span_tag.all_tag_node,
            );

            switch (freelist_decision) {
                // insert the new free tag into the appropriate freelist
                .add => self.pushToFreelist(free_tag),
                .nop => {},
            }
        }

        fn findSpanListPreviousSpan(
            self: *const @This(),
            base: usize,
            len: usize,
        ) error{Overlap}!?*BoundaryTag {
            const end = base + len - 1;

            var opt_next_span_kind_node: ?*KindNode = self.spans.first;

            var candidate_previous_span: ?*BoundaryTag = null;

            while (opt_next_span_kind_node) |next_span_kind_node| : ({
                opt_next_span_kind_node = next_span_kind_node.next;
            }) {
                const next_span = next_span_kind_node.toTag();
                if (core.is_debug) std.debug.assert(next_span.kind == .span or next_span.kind == .imported_span);

                if (next_span.base > end) break;

                const next_span_end = next_span.base + next_span.len - 1;

                if (next_span_end >= base) return error.Overlap;

                candidate_previous_span = next_span;
            }

            return candidate_previous_span;
        }

        fn findSpanAllTagInsertionPoint(opt_previous_span: ?*BoundaryTag) ?*AllTagNode {
            if (opt_previous_span) |previous_span| {
                if (core.is_debug) std.debug.assert(previous_span.kind == .span or previous_span.kind == .imported_span);

                if (previous_span.kind_node.next) |next_span_kind_node| {
                    const next_span = next_span_kind_node.toTag();
                    if (core.is_debug) std.debug.assert(next_span.kind == .span or next_span.kind == .imported_span);

                    return next_span.all_tag_node.previous;
                }

                var opt_candidate_node: ?*AllTagNode = &previous_span.all_tag_node;

                while (opt_candidate_node) |candidate_node| {
                    const next = candidate_node.next;
                    if (next == null) break;
                    opt_candidate_node = next;
                }

                return opt_candidate_node;
            }

            return null;
        }

        /// Allocate a block of length `len` from the arena.
        pub fn allocate(
            self: *@This(),
            len: usize,
            policy: innigkeit.mem.arena.Policy,
        ) innigkeit.mem.arena.AllocateError!innigkeit.mem.arena.Allocation {
            if (len == 0) return innigkeit.mem.arena.AllocateError.ZeroLength;

            const quantum_aligned_len = std.mem.alignForward(usize, len, self.quantum);

            log.verbose("{s}: allocating len 0x{x} (quantum_aligned_len: 0x{x}) with policy {t}", .{
                self.name(),
                len,
                quantum_aligned_len,
                policy,
            });

            if (quantum_caching.haveQuantumCache()) {
                if (quantum_aligned_len <= self.quantum_caches.max_cached_size) {
                    const cache_index: usize = (quantum_aligned_len / self.quantum) - 1;
                    const cache = self.quantum_caches.caches.constSlice()[cache_index];
                    if (core.is_debug) std.debug.assert(cache.item_size.value == quantum_aligned_len);

                    const buffer = cache.allocate() catch
                        return innigkeit.mem.arena.AllocateError.RequestedLengthUnavailable; // TODO: is there a better way to handle this?
                    if (core.is_debug) std.debug.assert(buffer.len == quantum_aligned_len);

                    return .{
                        .base = @intFromPtr(buffer.ptr),
                        .len = buffer.len,
                    };
                }
            }

            try self.ensureBoundaryTags();
            errdefer self.mutex.unlock(); // unconditionally unlock mutex on error

            const target_tag: *BoundaryTag = while (true) {
                break switch (policy) {
                    .instant_fit => self.findInstantFit(quantum_aligned_len),
                    .best_fit => self.findBestFit(quantum_aligned_len),
                    .first_fit => self.findFirstFit(quantum_aligned_len),
                } orelse {
                    const source = self.source orelse
                        return innigkeit.mem.arena.AllocateError.RequestedLengthUnavailable;

                    break self.importFromSource(source, quantum_aligned_len) catch
                        return innigkeit.mem.arena.AllocateError.RequestedLengthUnavailable;
                };
            };
            if (core.is_debug) std.debug.assert(target_tag.kind == .free);
            errdefer comptime unreachable;

            self.splitFreeTag(target_tag, quantum_aligned_len);

            target_tag.kind = .allocated;
            if (core.is_debug) std.debug.assert(target_tag.len == quantum_aligned_len);

            self.insertIntoAllocationTable(target_tag);

            self.mutex.unlock();

            const allocation: innigkeit.mem.arena.Allocation = .{
                .base = target_tag.base,
                .len = quantum_aligned_len,
            };

            log.verbose("{s}: allocated {f}", .{ self.name(), allocation });

            return allocation;
        }

        fn findInstantFit(self: *@This(), quantum_aligned_len: usize) ?*BoundaryTag {
            if (self.performStrictInstantFit(quantum_aligned_len)) |tag| {
                @branchHint(.likely);
                return tag;
            }

            return self.performStrictFirstFit(quantum_aligned_len);
        }

        fn findBestFit(self: *@This(), quantum_aligned_len: usize) ?*BoundaryTag {
            // search the freelist that would contain the exact length tag
            {
                var opt_best_tag: ?*BoundaryTag = null;
                var opt_node: ?*KindNode = self.freelists[indexOfFreelistContainingLen(quantum_aligned_len)].first;

                while (opt_node) |node| : (opt_node = node.next) {
                    const tag = node.toTag();
                    if (core.is_debug) std.debug.assert(tag.kind == .free);

                    if (tag.len == quantum_aligned_len) {
                        self.removeFromFreelist(tag);
                        return tag;
                    }

                    if (tag.len < quantum_aligned_len) continue;

                    if (opt_best_tag) |best_tag| {
                        if (tag.len < best_tag.len) opt_best_tag = tag;
                    } else {
                        opt_best_tag = tag;
                    }
                }

                if (opt_best_tag) |best_tag| {
                    self.removeFromFreelist(best_tag);
                    return best_tag;
                }
            }

            // search a freelist that is guaranteed to contain a tag that is large enough for the requested size
            if (self.indexOfNonEmptyFreelistInstantFit(quantum_aligned_len)) |index| {
                const smallest_possible_len = smallestPossibleLenInFreelist(index);

                var opt_best_tag: ?*BoundaryTag = null;
                var opt_node: ?*KindNode = self.freelists[index].first;

                while (opt_node) |node| : (opt_node = node.next) {
                    const tag = node.toTag();
                    if (core.is_debug) std.debug.assert(tag.kind == .free);

                    // if this tag is the smallest possible len in this freelist we can never do better
                    if (tag.len == smallest_possible_len) {
                        self.removeFromFreelist(tag);
                        return tag;
                    }

                    if (opt_best_tag) |best_tag| {
                        if (tag.len < best_tag.len) opt_best_tag = tag;
                    } else {
                        opt_best_tag = tag;
                    }
                }

                if (opt_best_tag) |best_tag| {
                    self.removeFromFreelist(best_tag);
                    return best_tag;
                }
            }

            return null;
        }

        fn findFirstFit(self: *@This(), quantum_aligned_len: usize) ?*BoundaryTag {
            if (self.performStrictFirstFit(quantum_aligned_len)) |tag| return tag;
            return self.performStrictInstantFit(quantum_aligned_len);
        }

        /// Find a free tag in any freelist that is guaranteed to satisfy the requested size.
        fn performStrictInstantFit(self: *@This(), quantum_aligned_len: usize) ?*BoundaryTag {
            const index = self.indexOfNonEmptyFreelistInstantFit(quantum_aligned_len) orelse {
                @branchHint(.unlikely);
                return null;
            };
            const tag = self.popFromFreelist(index) orelse unreachable;
            if (core.is_debug) std.debug.assert(tag.kind == .free);
            return tag;
        }

        /// Search for the first fit tag in the freelist containing the requested size.
        fn performStrictFirstFit(self: *@This(), quantum_aligned_len: usize) ?*BoundaryTag {
            var opt_node: ?*KindNode = self.freelists[indexOfFreelistContainingLen(quantum_aligned_len)].first;

            while (opt_node) |node| : (opt_node = node.next) {
                const tag = node.toTag();
                if (core.is_debug) std.debug.assert(tag.kind == .free);
                if (tag.len >= quantum_aligned_len) {
                    self.removeFromFreelist(tag);
                    return tag;
                }
            }

            return null;
        }

        /// Attempt to import a block of length `len` from the arena's source.
        ///
        /// The mutex must be locked upon entry and will be locked upon exit.
        fn importFromSource(
            self: *@This(),
            source: innigkeit.mem.arena.Source,
            len: usize,
        ) (innigkeit.mem.arena.AllocateError || innigkeit.mem.arena.AddSpanError)!*BoundaryTag {
            self.mutex.unlock();

            log.verbose("{s}: importing len 0x{x} from source {s}", .{ self.name(), len, source.name });

            var need_to_lock_mutex = true;
            defer if (need_to_lock_mutex) self.mutex.lock();

            const allocation = try source.callImport(len, .instant_fit);
            errdefer source.callRelease(allocation);

            try self.ensureBoundaryTags();
            need_to_lock_mutex = false;

            const span_tag, const free_tag =
                try self.getTagsForNewSpan(allocation.base, allocation.len, .imported_span);
            errdefer {
                self.pushUnusedTag(span_tag);
                self.pushUnusedTag(free_tag);
            }

            try self.addSpanInner(span_tag, free_tag, .nop);

            log.verbose("{s}: imported {f} from source {s}", .{ self.name(), allocation, source.name });

            return free_tag;
        }

        fn splitFreeTag(self: *@This(), tag: *BoundaryTag, allocation_len: usize) void {
            if (core.is_debug) {
                std.debug.assert(tag.kind == .free);
                std.debug.assert(tag.len >= allocation_len);
            }

            if (tag.len == allocation_len) return;

            const new_tag = self.popUnusedTag();

            new_tag.* = .{
                .base = tag.base + allocation_len,
                .len = tag.len - allocation_len,
                .all_tag_node = .empty,
                .kind_node = .empty,
                .kind = .free,
            };

            tag.len = allocation_len;

            self.all_tags.insertAfter(
                &new_tag.all_tag_node,
                &tag.all_tag_node,
            );

            self.pushToFreelist(new_tag);
        }

        /// Deallocate the allocation.
        ///
        /// Panics if the allocation does not match a previous call to `allocate`.
        pub fn deallocate(self: *@This(), allocation: innigkeit.mem.arena.Allocation) void {
            log.verbose("{s}: deallocating {f}", .{ self.name(), allocation });

            if (core.is_debug) {
                std.debug.assert(std.mem.isAligned(allocation.base, self.quantum));
                std.debug.assert(std.mem.isAligned(allocation.len, self.quantum));
            }

            if (quantum_caching.haveQuantumCache()) {
                if (allocation.len <= self.quantum_caches.max_cached_size) {
                    const cache_index: usize = (allocation.len / self.quantum) - 1;
                    const cache = self.quantum_caches.caches.constSlice()[cache_index];
                    if (core.is_debug) std.debug.assert(cache.item_size.value == allocation.len);

                    const buffer_ptr: [*]u8 = @ptrFromInt(allocation.base);
                    const buffer = buffer_ptr[0..allocation.len];

                    cache.deallocate(buffer);

                    return;
                }
            }

            self.mutex.lock();

            var need_to_unlock_mutex = true;
            defer if (need_to_unlock_mutex) self.mutex.unlock();

            const tag = self.removeFromAllocationTable(allocation.base) orelse {
                std.debug.panic(
                    "no allocation at '{}' found!",
                    .{allocation.base},
                );
            };
            if (core.is_debug) std.debug.assert(tag.kind == .allocated);

            if (allocation.len != tag.len) {
                std.debug.panic(
                    "provided len '{}' does not match len '{}' of allocation at '{}'!",
                    .{ allocation.len, tag.len, allocation.base },
                );
            }

            tag.kind = .free;

            coalesce_previous_tag: {
                const previous_node = tag.all_tag_node.previous orelse
                    unreachable; // a free tag will always have atleast its containing spans tag before it

                const previous_tag = previous_node.toTag();

                if (previous_tag.kind != .free) break :coalesce_previous_tag;
                if (core.is_debug) std.debug.assert(previous_tag.base + previous_tag.len == tag.base);

                self.removeFromFreelist(previous_tag);
                self.all_tags.remove(&previous_tag.all_tag_node);

                tag.base = previous_tag.base;
                tag.len = previous_tag.len + tag.len;

                self.pushUnusedTag(previous_tag);
            }

            coalesce_next_tag: {
                const next_node = tag.all_tag_node.next orelse break :coalesce_next_tag;
                const next_tag = next_node.toTag();

                if (next_tag.kind != .free) break :coalesce_next_tag;
                if (core.is_debug) std.debug.assert(tag.base + tag.len == next_tag.base);

                self.removeFromFreelist(next_tag);
                self.all_tags.remove(&next_tag.all_tag_node);

                tag.len = tag.len + next_tag.len;

                self.pushUnusedTag(next_tag);
            }

            if (self.source) |source| {
                const previous_node = tag.all_tag_node.previous orelse
                    unreachable; // a free tag will always have atleast its containing spans' tag before it

                const previous_tag = previous_node.toTag();

                if (previous_tag.kind == .imported_span and previous_tag.len == tag.len) {
                    if (core.is_debug) std.debug.assert(previous_tag.base == tag.base);

                    self.spans.remove(&previous_tag.kind_node);
                    self.all_tags.remove(&previous_tag.all_tag_node);
                    self.all_tags.remove(&tag.all_tag_node);

                    const allocation_to_release: innigkeit.mem.arena.Allocation = .{
                        .base = previous_tag.base,
                        .len = previous_tag.len,
                    };

                    previous_tag.* = .empty(.free);

                    self.pushUnusedTag(previous_tag);
                    self.pushUnusedTag(tag);

                    self.mutex.unlock();
                    need_to_unlock_mutex = false;

                    source.callRelease(allocation_to_release);

                    log.verbose(
                        "{s}: released {f} to source {s}",
                        .{ self.name(), allocation_to_release, source.name },
                    );

                    return;
                }
            }

            self.pushToFreelist(tag);
        }

        /// Attempts to ensure that there are at least `min_unused_tags_count` unused tags.
        ///
        /// Upon non-error return, the mutex is locked.
        fn ensureBoundaryTags(self: *@This()) innigkeit.mem.arena.EnsureBoundaryTagsError!void {
            self.mutex.lock();
            errdefer self.mutex.unlock();

            if (self.unused_tags_count >= globals.MAX_TAGS_PER_ALLOCATION) return;

            var tags = core.containers.BoundedArray(
                *BoundaryTag,
                globals.MAX_TAGS_PER_ALLOCATION,
            ).init(globals.MAX_TAGS_PER_ALLOCATION - self.unused_tags_count) catch unreachable;

            globals.tag_cache.allocateMany(tags.slice()) catch
                return innigkeit.mem.arena.EnsureBoundaryTagsError.OutOfBoundaryTags;

            for (tags.slice()) |tag| {
                tag.* = .empty(.free);

                self.pushUnusedTag(tag);
            }
        }

        fn insertIntoAllocationTable(self: *@This(), tag: *BoundaryTag) void {
            if (core.is_debug) std.debug.assert(tag.kind == .allocated);

            const index: globals.HashIndex = @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&tag.base)));
            self.allocation_table[index].push(&tag.kind_node);
        }

        fn removeFromAllocationTable(self: *@This(), base: usize) ?*BoundaryTag {
            const index: globals.HashIndex = @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&base)));
            const bucket = &self.allocation_table[index];

            var opt_node = bucket.first;
            while (opt_node) |node| : (opt_node = node.next) {
                const tag = node.toTag();
                if (core.is_debug) std.debug.assert(tag.kind == .allocated);

                if (tag.base != base) continue;

                bucket.remove(node);
                return tag;
            }

            return null;
        }

        fn pushToFreelist(self: *@This(), tag: *BoundaryTag) void {
            if (core.is_debug) std.debug.assert(tag.kind == .free);

            const index = indexOfFreelistContainingLen(tag.len);

            self.freelists[index].push(&tag.kind_node);
            self.freelist_bitmap.set(index);
        }

        fn popFromFreelist(self: *@This(), index: globals.UsizeShiftInt) ?*BoundaryTag {
            const freelist = &self.freelists[index];

            const node = freelist.pop() orelse return null;

            if (freelist.isEmpty()) self.freelist_bitmap.unset(index);

            const tag = node.toTag();
            if (core.is_debug) std.debug.assert(tag.kind == .free);
            return tag;
        }

        fn removeFromFreelist(self: *@This(), tag: *BoundaryTag) void {
            if (core.is_debug) std.debug.assert(tag.kind == .free);

            const index = indexOfFreelistContainingLen(tag.len);
            const freelist = &self.freelists[index];

            freelist.remove(&tag.kind_node);
            if (freelist.isEmpty()) self.freelist_bitmap.unset(index);
        }

        fn popUnusedTag(self: *@This()) *BoundaryTag {
            if (core.is_debug) std.debug.assert(self.unused_tags_count > 0);
            self.unused_tags_count -= 1;
            const tag = self.unused_tags.pop().?.toTag();
            if (core.is_debug) std.debug.assert(tag.kind == .free);
            return tag;
        }

        fn pushUnusedTag(self: *@This(), tag: *BoundaryTag) void {
            if (core.is_debug) std.debug.assert(tag.kind == .free);
            self.unused_tags.push(&tag.all_tag_node);
            self.unused_tags_count += 1;
        }

        fn indexOfNonEmptyFreelistInstantFit(self: *const @This(), len: usize) ?globals.UsizeShiftInt {
            const pow2_len = std.math.ceilPowerOfTwoAssert(usize, len);
            const index = @ctz(self.freelist_bitmap.value & ~(pow2_len - 1));
            if (index == globals.NUMBER_OF_FREELISTS) {
                @branchHint(.unlikely);
                return null;
            }
            return @intCast(index);
        }

        pub const CreateSourceOptions = struct {
            custom_import: ?fn (
                arena_ptr: *anyopaque,
                len: usize,
                policy: innigkeit.mem.arena.Policy,
            ) innigkeit.mem.arena.AllocateError!innigkeit.mem.arena.Allocation = null,

            custom_release: ?fn (
                arena_ptr: *anyopaque,
                allocation: innigkeit.mem.arena.Allocation,
            ) void = null,
        };

        pub fn createSource(self: *@This(), comptime options: CreateSourceOptions) innigkeit.mem.arena.Source {
            const ArenaT = @This();
            return .{
                .name = self.name(),
                .arena_ptr = self,
                .import = if (options.custom_import) |custom_import|
                    custom_import
                else
                    struct {
                        fn importWrapper(
                            arena_ptr: *anyopaque,
                            len: usize,
                            policy: innigkeit.mem.arena.Policy,
                        ) innigkeit.mem.arena.AllocateError!innigkeit.mem.arena.Allocation {
                            const a: *ArenaT = @ptrCast(@alignCast(arena_ptr));
                            return a.allocate(len, policy);
                        }
                    }.importWrapper,
                .release = if (options.custom_release) |custom_release|
                    custom_release
                else
                    struct {
                        fn releaseWrapper(
                            arena_ptr: *anyopaque,
                            allocation: innigkeit.mem.arena.Allocation,
                        ) void {
                            const a: *ArenaT = @ptrCast(@alignCast(arena_ptr));
                            a.deallocate(allocation);
                        }
                    }.releaseWrapper,
            };
        }

        const QuantumCaches = struct {
            caches: if (quantum_caching != .none)
                core.containers.BoundedArray(
                    *RawCache,
                    globals.MAX_NUMBER_OF_QUANTUM_CACHES,
                )
            else
                void = if (quantum_caching != .none) .{} else {},

            /// The largest size of a cached object.
            max_cached_size: if (quantum_caching != .none) usize else void,

            allocation: QuantumCaches.Allocation,

            const Allocation = switch (quantum_caching) {
                .none => void,
                .normal => []RawCache,
                .heap => innigkeit.mem.PhysicalPage.List,
            };
        };
    };
}

inline fn indexOfFreelistContainingLen(len: usize) globals.UsizeShiftInt {
    return @intCast(globals.NUMBER_OF_FREELISTS - 1 - @clz(len));
}

inline fn smallestPossibleLenInFreelist(index: usize) usize {
    const truncated_len: globals.UsizeShiftInt = @truncate(index);
    const one: usize = 1;
    return one << @truncate(truncated_len);
}

pub const BoundaryTag = struct {
    base: usize,
    len: usize,

    all_tag_node: AllTagNode,
    kind_node: KindNode,

    kind: Kind,

    const Kind = enum(u8) {
        /// the `all_tag_node` list is in order of ascending `base`
        /// the `kind_node` list is in order of ascending `base`
        /// `kind_node` linked into `Arena.spans` along with `imported_span`
        span,

        /// the `all_tag_node` list is in order of ascending `base`
        /// the `kind_node` list is in order of ascending `base`
        /// `kind_node` linked into `Arena.spans` along with `span`
        imported_span,

        /// the `all_tag_node` list is in order of ascending `base`
        /// the `kind_node` list has no guarantee of order
        /// `kind_node` linked into the matching power-of-2 freelist in `Arena.freelists`
        free,

        /// the `all_tag_node` list is in order of ascending `base`
        /// the `kind_node` list has no guarantee of order
        /// `kind_node` linked into matching hash bucket in `Arena.allocation_table`
        allocated,
    };

    fn empty(kind: Kind) BoundaryTag {
        return .{
            .base = 0,
            .len = 0,
            .all_tag_node = .empty,
            .kind_node = .empty,
            .kind = kind,
        };
    }

    pub fn print(self: BoundaryTag, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("BoundaryTag{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("base: 0x{x},\n", .{self.base});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("len: 0x{x},\n", .{self.len});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("kind: {t},\n", .{self.kind});

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("all_tag_node: ");
        try self.all_tag_node.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("kind_node: ");
        try self.kind_node.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: BoundaryTag, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }
};

const AllTagNode = struct {
    previous: ?*AllTagNode,
    next: ?*AllTagNode,

    fn toTag(self: *AllTagNode) *BoundaryTag {
        return @fieldParentPtr("all_tag_node", self);
    }

    const empty: AllTagNode = .{ .previous = null, .next = null };

    pub fn print(self: AllTagNode, writer: *std.Io.Writer, indent: usize) !void {
        _ = indent;

        try writer.writeAll("AllTagNode{ previous: ");
        if (self.previous != null) {
            try writer.writeAll("set");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(", next: ");
        if (self.next != null) {
            try writer.writeAll("set");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(" }");
    }

    pub inline fn format(self: AllTagNode, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }
};

const KindNode = struct {
    previous: ?*KindNode,
    next: ?*KindNode,

    fn toTag(self: *KindNode) *BoundaryTag {
        return @fieldParentPtr("kind_node", self);
    }

    const empty: KindNode = .{ .previous = null, .next = null };

    pub fn print(self: KindNode, writer: *std.Io.Writer, indent: usize) !void {
        _ = indent;

        try writer.writeAll("KindNode{ previous: ");
        if (self.previous != null) {
            try writer.writeAll("set");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(", next: ");
        if (self.next != null) {
            try writer.writeAll("set");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(" }");
    }

    pub inline fn format(self: KindNode, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }
};

const Bitmap = struct {
    value: usize,

    const empty: Bitmap = .{ .value = 0 };

    fn set(self: *Bitmap, index: globals.UsizeShiftInt) void {
        self.value |= maskBit(index);
    }

    fn unset(self: *Bitmap, index: globals.UsizeShiftInt) void {
        self.value &= ~maskBit(index);
    }

    inline fn maskBit(index: globals.UsizeShiftInt) usize {
        const one: usize = 1;
        return one << index;
    }
};

/// A singly linked list, that uses `AllTagNode.next` as the link.
const SinglyLinkedList = struct {
    first: ?*AllTagNode,

    const empty: SinglyLinkedList = .{ .first = null };

    fn push(self: *SinglyLinkedList, node: *AllTagNode) void {
        if (core.is_debug) std.debug.assert(node.previous == null and node.next == null);

        node.* = .{ .next = self.first, .previous = null };

        self.first = node;
    }

    fn pop(self: *SinglyLinkedList) ?*AllTagNode {
        const node = self.first orelse return null;
        if (core.is_debug) std.debug.assert(node.previous == null);

        self.first = node.next;

        node.* = .empty;

        return node;
    }
};

/// A doubly linked list, that uses `Node` as the link.
fn DoublyLinkedList(comptime Node: type) type {
    return struct {
        first: ?*Node,

        const DoublyLinkedListT = @This();

        const empty: DoublyLinkedListT = .{ .first = null };

        /// Push a node to the front of the list.
        fn push(self: *DoublyLinkedListT, node: *Node) void {
            if (core.is_debug) std.debug.assert(node.previous == null and node.next == null);

            const opt_first = self.first;

            node.next = opt_first;

            if (opt_first) |first| {
                if (core.is_debug) std.debug.assert(first.previous == null);
                first.previous = node;
            }

            node.previous = null;
            self.first = node;
        }

        /// Pop a node from the front of the list.
        fn pop(self: *DoublyLinkedListT) ?*Node {
            const first = self.first orelse return null;
            if (core.is_debug) std.debug.assert(first.previous == null);

            const opt_next = first.next;

            if (opt_next) |next| {
                if (core.is_debug) std.debug.assert(next.previous == first);
                next.previous = null;
            }

            self.first = opt_next;

            first.* = .empty;

            return first;
        }

        /// Removes a node from the list.
        fn remove(self: *DoublyLinkedListT, node: *Node) void {
            if (node.previous) |previous| {
                if (core.is_debug) std.debug.assert(previous.next == node);
                previous.next = node.next;
            } else {
                self.first = node.next;
            }

            if (node.next) |next| {
                if (core.is_debug) std.debug.assert(next.previous == node);
                next.previous = node.previous;
            }

            node.* = .empty;
        }

        pub fn insertAfter(self: *DoublyLinkedListT, node: *Node, opt_previous: ?*Node) void {
            if (core.is_debug) std.debug.assert(node.previous == null and node.next == null);

            if (opt_previous) |previous| {
                if (previous.next) |next| {
                    if (core.is_debug) std.debug.assert(next.previous == previous);
                    next.previous = node;
                    node.next = next;
                }

                previous.next = node;
                node.previous = previous;
            } else {
                if (self.first) |first| {
                    if (core.is_debug) std.debug.assert(first.previous == null);
                    first.previous = node;
                    node.next = first;
                }

                self.first = node;
            }
        }

        inline fn isEmpty(self: *const DoublyLinkedListT) bool {
            return self.first == null;
        }
    };
}

pub const QuantumCaching = union(enum) {
    none,

    /// The number of multiples of the quantum to cache.
    ///
    /// Uses the heap resource arena to allocate the caches.
    ///
    /// Must be non-zero.
    normal: u8,

    /// The number of multiples of the quantum to cache.
    ///
    /// This should only be used by the heap resource arena itself.
    ///
    /// Uses the physical memory allocator and the hhdm to allocate the caches.
    ///
    /// Must be non-zero.
    heap: u8,

    inline fn haveQuantumCache(comptime self: QuantumCaching) bool {
        return switch (self) {
            .none => false,
            .normal, .heap => true,
        };
    }
};
