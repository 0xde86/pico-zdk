//! pico-zdk: a from-scratch RP2040/RP2350 SDK in Zig.
//!
//! This file is the library's only public API surface. As the HAL lands, its
//! curated modules are re-exported here (and only here) - for example:
//!
//!     pub const gpio = @import("hal/gpio.zig");
//!     pub const Uart = @import("hal/Uart.zig");
//!
//! Consumers import this module; internal paths under `src/` stay private.

/// Program-level configuration read by the runtime from the firmware root
/// module. Declaring no `zdk_options` value selects these defaults.
///
///     const zdk = @import("pico_zdk");
///
///     pub const zdk_options: zdk.Options = .{ .startup = .reset_state };
pub const Options = struct {
    /// Startup policy applied before the application enters `main`.
    startup: Startup = .spec,

    /// Selects the runtime's startup initialization policy.
    pub const Startup = enum {
        /// The default init chain: peripheral resets around the clock tree,
        /// crystal and PLLs at datasheet spec speed, 1 microsecond ticks
        /// running, and the chip's pad fixes applied. `main` starts with a
        /// crystal-accurate timebase and every M3-configured block out of reset.
        /// RTC on RP2040 and HSTX on RP2350 remain reset because their clocks
        /// and consumers intentionally arrive in later milestones.
        ///
        /// The chain contains unbounded waits: a board with no working crystal
        /// hangs in startup rather than running at an unknown speed.
        spec,

        /// Performs no clock or peripheral initialization, preserving whatever
        /// state the reset path, bootrom, bootloader, or debugger handed to this
        /// program. A normal cold boot runs from the ring oscillator with most
        /// blocks held in reset, but callers must not assume that state after a
        /// warm or debugger-assisted entry. For boot oracles and bring-up
        /// debugging. Anything that depends on timing - which is everything
        /// from M4 on - needs `.spec`.
        reset_state,
    };
};

/// Raw register definitions and chip-level capabilities for the selected SoC.
pub const chip = @import("./chip.zig");

/// Board-level pin assignments for the configured target board.
pub const board = @import("./board.zig");

/// Interfaces for controlling hardware subsystem resets.
pub const resets = @import("hal/resets.zig");

/// Crystal oscillator startup.
pub const xosc = @import("hal/xosc.zig");

/// Phase-locked loop configuration, searched and validated at compile time.
pub const pll = @import("hal/pll.zig");

/// Clock generator configuration, the spec-speed startup plan, and frequency
/// bookkeeping.
pub const clocks = @import("hal/clocks.zig");

/// Tick generation: the shared 1 microsecond pulse train timers count.
pub const ticks = @import("hal/ticks.zig");

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
