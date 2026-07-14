# GDB init for `zig build run_x64 -Ddebug=true`: QEMU exposes a GDB stub on
# localhost:1234 and starts frozen (-S) until a debugger attaches.
#
# GDB's auto-load safety feature won't source this automatically unless you
# either run `gdb -x .gdbinit` explicitly, or add
# `add-auto-load-safe-path /path/to/innigkeit` to your own ~/.gdbinit once.
#
# For arm instead of x64, or a test kernel instead of the release one:
#   file zig-out/arm/kernel
#   file zig-out/x64/kernel_test
#   file zig-out/arm/kernel_test

file zig-out/x64/kernel
target remote localhost:1234
