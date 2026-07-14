pub const ObjectType = enum(u16) {
    none = 0,
    relocatable = 1,
    executable = 2,
    shared = 3,
    core = 4,

    _,

    /// Beginning of OS-specific codes
    pub const LOOS = 0xFE00;

    /// End of OS-specific codes
    pub const HIOS = 0xFEFF;

    /// Beginning of processor-specific codes
    pub const LOPROC = 0xFF00;

    /// End of processor-specific codes
    pub const HIPROC = 0xFFFF;
};
