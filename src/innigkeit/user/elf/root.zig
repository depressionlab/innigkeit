//! A library for reading ELF files.
//!
//! The design of this library is constrained by its usage in the kernel, meaning it does not support file readers nor
//! being given the full ELF file as a slice and instead requires the caller to perfrom all read operations then pass the data
//! in to be parsed.
//!
//! [ELF Object File Format Version 4.3 DRAFT](https://gabi.xinuos.com/)

pub const Header = @import("Header.zig");
pub const ProgramHeader = @import("ProgramHeader.zig");
pub const LoadableRegion = @import("LoadableRegion.zig");
pub const ObjectType = @import("ObjectType.zig").ObjectType;
pub const Machine = @import("Machine.zig").Machine;
pub const Version = @import("Version.zig").Version;
pub const OSABI = @import("OSABI.zig").OSABI;
