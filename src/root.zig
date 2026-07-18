//! pico-zdk: a from-scratch RP2040/RP2350 SDK in Zig.
//!
//! This file is the library's only public API surface. As the HAL lands, its
//! curated modules are re-exported here (and only here) - for example:
//!
//!     pub const gpio = @import("hal/gpio.zig");
//!     pub const Uart = @import("hal/Uart.zig");
//!
//! Consumers import this module; internal paths under `src/` stay private.

test {
    // Force-analyze the host-testable runtime logic under `zig build test`.
    _ = @import("rt/picobin.zig");

    // Force-analyze every declaration re-exported from this root as the
    // curated public API lands here.
    @import("std").testing.refAllDecls(@This());
}
