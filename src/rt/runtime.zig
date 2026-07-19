//! Bare-metal firmware root selected by `addFirmware`.
//!
//! The application is imported as `app` and supplies `pub fn main()`, returning
//! either `void` or `noreturn`. This module owns `_start`, boot metadata,
//! vectors, and memory initialization.

const config = @import("config");

const startup = if (config.core == .hazard3)
    @import("start_hazard3.zig")
else
    @import("start_cortex_m.zig");

comptime {
    _ = startup._start;

    // Flash boot metadata is a chip fact: the RP2040 boots through a
    // checksummed second-stage loader, the RP2350 through an IMAGE_DEF block.
    if (config.chip == .rp2040) {
        _ = @import("boot2_image").image;
    } else {
        _ = @import("image_def.zig").image_def;
    }
}
