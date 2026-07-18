//! Blinky example (work in progress).
//!
//! Placeholder for the canonical "blink the on-board LED" firmware. Once the
//! GPIO HAL lands this will configure a pin and toggle it on a delay via
//! `pico_zdk.gpio`. For now it just busy-loops a counter so the example
//! compiles for every target and reserves the slot in the build.

/// Application entry point called after runtime initialization.
pub fn main() noreturn {
    var ticks: u32 = 0;
    while (true) {
        // Crude busy-delay placeholder for a real timer-based blink.
        ticks +%= 1;
    }
}
