const std = @import("std");
const Bundle = @import("../../build/Bundle.zig");

pub fn custom(b: *std.Build, bundle: Bundle, module: *std.Build.Module) anyerror!void {
    if (bundle.context != .internal) return;

    if (bundle.architecture != .x64) {
        module.addCSourceFile(.{ .file = b.path("apps/doom/doom_stub.c"), .flags = &.{} });
        return;
    }

    const doomgeneric = b.dependency("doomgeneric", .{}).path("doomgeneric");

    module.addIncludePath(doomgeneric);
    module.addIncludePath(b.path("apps/doom/include"));
    module.addIncludePath(b.path("apps/doom"));

    // Platform-specific C files
    module.addCSourceFile(.{
        .file = b.path("apps/doom/innigkeit_libc.c"),
        .flags = &.{"-Wno-implicit-function-declaration"},
    });
    module.addCSourceFile(.{
        .file = b.path("apps/doom/doomgeneric_innigkeit.c"),
        .flags = &.{"-Wno-implicit-function-declaration"},
    });

    // All doomgeneric engine C sources
    const dg_sources: []const []const u8 = &.{
        "am_map.c",     "d_event.c",     "d_items.c",     "d_iwad.c",
        "d_loop.c",     "d_main.c",      "d_mode.c",      "d_net.c",
        "doomdef.c",    "doomgeneric.c", "doomstat.c",    "dstrings.c",
        "dummy.c",      "f_finale.c",    "f_wipe.c",      "g_game.c",
        "gusconf.c",    "hu_lib.c",      "hu_stuff.c",    "i_cdmus.c",
        "i_endoom.c",   "i_input.c",     "i_joystick.c",  "i_scale.c",
        "i_sound.c",    "i_system.c",    "i_timer.c",     "i_video.c",
        "icon.c",       "info.c",        "m_argv.c",      "m_bbox.c",
        "m_cheat.c",    "m_config.c",    "m_controls.c",  "m_fixed.c",
        "m_menu.c",     "m_misc.c",      "m_random.c",    "memio.c",
        "mus2mid.c",    "p_ceilng.c",    "p_doors.c",     "p_enemy.c",
        "p_floor.c",    "p_inter.c",     "p_lights.c",    "p_map.c",
        "p_maputl.c",   "p_mobj.c",      "p_plats.c",     "p_pspr.c",
        "p_saveg.c",    "p_setup.c",     "p_sight.c",     "p_spec.c",
        "p_switch.c",   "p_telept.c",    "p_tick.c",      "p_user.c",
        "r_bsp.c",      "r_data.c",      "r_draw.c",      "r_main.c",
        "r_plane.c",    "r_segs.c",      "r_sky.c",       "r_things.c",
        "s_sound.c",    "sha1.c",        "sounds.c",      "st_lib.c",
        "st_stuff.c",   "statdump.c",    "tables.c",      "v_video.c",
        "w_checksum.c", "w_file.c",      "w_file_stdc.c", "w_main.c",
        "w_wad.c",      "wi_stuff.c",    "z_zone.c",
    };

    for (dg_sources) |src| {
        module.addCSourceFile(.{
            .file = try doomgeneric.join(b.allocator, src),
            .flags = &.{"-Wno-implicit-function-declaration"},
        });
    }
}
