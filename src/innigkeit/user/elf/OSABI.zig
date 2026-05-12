pub const OSABI = enum(u8) {
    /// UNIX System V ABI
    NONE = 0,
    /// HP-UX operating system
    HPUX = 1,
    /// NetBSD
    NETBSD = 2,
    /// GNU (Hurd/Linux)
    GNU = 3,
    /// Solaris
    SOLARIS = 6,
    /// AIX
    AIX = 7,
    /// IRIX
    IRIX = 8,
    /// FreeBSD
    FREEBSD = 9,
    /// TRU64 UNIX
    TRU64 = 10,
    /// Novell Modesto
    MODESTO = 11,
    /// OpenBSD
    OPENBSD = 12,
    /// OpenVMS
    OPENVMS = 13,
    /// Hewlett-Packard Non-Stop Kernel
    NSK = 14,
    /// AROS
    AROS = 15,
    /// FenixOS
    FENIXOS = 16,
    /// Nuxi CloudABI
    CLOUDABI = 17,
    /// Stratus Technologies OpenVOS
    OPENVOS = 18,

    // Above here was taken from https://gabi.xinuos.com/elf/b-osabi.html
    //
    // Below here are additional values present in `std.elf.OSABI`

    /// NVIDIA CUDA architecture (not gABI assigned)
    CUDA = 51,
    /// AMD HSA Runtime (not gABI assigned)
    AMDGPU_HSA = 64,
    /// AMD PAL Runtime (not gABI assigned)
    AMDGPU_PAL = 65,
    /// AMD Mesa3D Runtime (not gABI assigned)
    AMDGPU_MESA3D = 66,
    /// ARM (not gABI assigned)
    ARM = 97,
    /// Standalone (embedded) application (not gABI assigned)
    STANDALONE = 255,

    _,
};
