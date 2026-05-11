const innigkeit = @import("innigkeit");

pub const Address = union(enum) {
    physical: innigkeit.PhysicalAddress,
    virtual: innigkeit.KernelVirtualAddress,

    pub const Raw = extern union {
        physical: innigkeit.PhysicalAddress,
        virtual: innigkeit.KernelVirtualAddress,
    };
};
