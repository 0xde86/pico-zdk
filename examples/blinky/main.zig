//! Blinky example (work in progress).
//!
//! Placeholder for the canonical "blink the on-board LED" firmware.

const zdk = @import("pico_zdk");

/// Application entry point called after runtime initialization.
pub fn main() noreturn {
    zdk.hal.resets.releaseAndWait(&.{ .io_bank0, .pads_bank0 });
    var ticks: u32 = 0;
    while (true) {
        // Crude busy-delay placeholder for a real timer-based blink.
        ticks +%= 1;
    }
}
