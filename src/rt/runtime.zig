//! Bare-metal firmware root selected by `addFirmware`.
//!
//! The application is imported as `app` and supplies `pub fn main()`, returning
//! either `void` or `noreturn`. This module owns `_start`, boot metadata,
//! vectors, and memory initialization.

const config = @import("rt_config");
const is_rp2040 = config.board == .pico;
const is_riscv = config.board == .pico2 and config.arch == .riscv;

const startup = if (is_riscv)
    @import("start_hazard3.zig")
else
    @import("start_cortex_m.zig");

comptime {
    _ = startup._start;

    if (is_rp2040) {
        _ = @import("boot2_image").image;
    } else {
        _ = @import("image_def.zig").image_def;
    }
}
