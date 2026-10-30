//! Configure-time filesystem probes that keep the configuration cache valid.
//!
//! `build.zig` runs in its own process and Zig 0.17 reuses its serialized
//! output while nothing it observed has changed. Anything `build.zig` reads
//! from the host must therefore be declared (or the cache poisoned, which
//! throws the speedup away). The cache manifest can only track paths that
//! exist, so a missing path is tracked through its nearest existing ancestor
//! directory instead: creating the path changes that directory.
const std = @import("std");

pub const Kind = enum {
    /// Only whether the file exists, and its size/mtime.
    file_metadata,
    /// The file's bytes.
    file_contents,
    /// The directory's entry names.
    directory_contents,
};

/// Declares a configure-time dependency on `path` (relative to the build root,
/// or absolute). Returns whether `path` exists.
pub fn track(b: *std.Build, path: []const u8, kind: Kind) bool {
    const io = b.graph.io;

    var probe = path;
    while (true) {
        std.Io.Dir.cwd().access(io, probe, .{}) catch {
            probe = std.Io.Dir.path.dirname(probe) orelse ".";
            continue;
        };
        break;
    }

    const lazy: std.Build.LazyPath = if (std.Io.Dir.path.isAbsolute(probe)) b.graph.cwdRelativePath(probe) else b.path(probe);
    if (probe.len == path.len) {
        switch (kind) {
            .file_metadata => b.dependOnFileMetadata(lazy),
            .file_contents => b.dependOnFileContents(lazy),
            .directory_contents => b.dependOnDirectoryContents(lazy),
        }
        return true;
    }
    b.dependOnDirectoryMetadata(lazy);
    return false;
}
