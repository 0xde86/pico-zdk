//! pico-zdk: a from-scratch RP2040/RP2350 SDK in Zig.
//!
//! This file is the library's only public API surface. As the HAL lands, its
//! curated modules are re-exported here (and only here) - for example:
//!
//!     pub const gpio = @import("hal/gpio.zig");
//!     pub const Uart = @import("hal/Uart.zig");
//!
//! Consumers import this module; internal paths under `src/` stay private.

/// Raw register definitions and chip-level capabilities for the selected SoC.
pub const chip = @import("./chip.zig");

/// Board-level pin assignments for the configured target board.
pub const board = @import("./board.zig");

/// Interfaces for controlling hardware subsystem resets.
pub const resets = @import("hal/resets.zig");

/// Physical GPIO pad and function-mux configuration.
pub const gpio = @import("hal/gpio.zig");

/// Software-controlled digital I/O through the SIO hardware block.
pub const sio = @import("hal/sio.zig");

test {
    // Configuration intake; analyzed under both test configurations (the
    // build instantiates this suite once per chip).
    _ = @import("config");

    // Force-analyze every declaration re-exported from this root as the
    // curated public API lands here.
    @import("std").testing.refAllDecls(@This());
}
