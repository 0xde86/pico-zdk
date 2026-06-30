//! Minimal pico-zdk example.

const pico_zdk = @import("pico_zdk");

/// Reset / entry point. `build.zig` points the linker entry symbol here.
export fn _start() callconv(.c) noreturn {
    while (true) {}
}
