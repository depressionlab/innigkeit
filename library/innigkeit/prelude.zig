// Automatically-injected root module for Innigkeit userspace apps.
// The build system uses this as the actual root_source_file; each app's
// main.zig is imported as "app" so it only needs to define pub fn main.
const app = @import("app");
const innigkeit = @import("innigkeit");

comptime {
    innigkeit.exportEntry();
}

pub const main = app.main;

pub const std_options =
    if (@hasDecl(app, "std_options"))
        app.std_options
    else
        innigkeit.interop.std_options;

pub const std_options_debug_io =
    if (@hasDecl(app, "std_options_debug_io"))
        app.std_options_debug_io
    else
        innigkeit.interop.debug_io;

pub const panic =
    if (@hasDecl(app, "panic"))
        app.panic
    else
        innigkeit.interop.panic;
