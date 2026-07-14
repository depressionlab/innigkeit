const innigkeit = @import("innigkeit");

physical_range: innigkeit.PhysicalRange,
protection: innigkeit.memory.MapType.Protection,
cache: innigkeit.memory.MapType.Cache,

pub const Error = error{
    ZeroLength,
    OutOfMemory,
};
