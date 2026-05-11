const innigkeit = @import("innigkeit");

physical_range: innigkeit.PhysicalRange,
protection: innigkeit.mem.MapType.Protection,
cache: innigkeit.mem.MapType.Cache,

pub const Error = error{
    ZeroLength,
    OutOfMemory,
};
