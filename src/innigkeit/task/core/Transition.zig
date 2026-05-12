//! Represents a scheduler transition between two tasks.
const Transition = @This();

const innigkeit = @import("innigkeit");

old_task: *innigkeit.Task,
new_task: *innigkeit.Task,
type: Type,

pub const Type = enum {
    kernel_to_kernel,
    kernel_to_user,
    user_to_kernel,
    user_to_user,

    pub fn oldType(type_: Type) innigkeit.Context.Type {
        return switch (type_) {
            .kernel_to_kernel, .kernel_to_user => .kernel,
            .user_to_kernel, .user_to_user => .user,
        };
    }

    pub fn newType(type_: Type) innigkeit.Context.Type {
        return switch (type_) {
            .kernel_to_kernel, .user_to_kernel => .kernel,
            .kernel_to_user, .user_to_user => .user,
        };
    }
};

pub fn from(old_task: *innigkeit.Task, new_task: *innigkeit.Task) Transition {
    return .{
        .old_task = old_task,
        .new_task = new_task,
        .type = switch (old_task.type) {
            .kernel => switch (new_task.type) {
                .kernel => .kernel_to_kernel,
                .user => .kernel_to_user,
            },
            .user => switch (new_task.type) {
                .kernel => .user_to_kernel,
                .user => .user_to_user,
            },
        },
    };
}
