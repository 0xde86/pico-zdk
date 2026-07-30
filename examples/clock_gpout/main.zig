//! `clock_gpout`: put the system clock on a pin, so the clock tree stops being
//! something you have to take on faith.
//!
//! `clk_sys` divided by 1000 comes out of GPIO 21 - the one clock-output pin
//! free on both boards' headers. Measure it with any logic analyzer,
//! oscilloscope, or multimeter that counts frequency:
//!
//!   - Pico (RP2040):  125.000 kHz
//!   - Pico 2 (RP2350): 150.000 kHz
//!
//! With a 30 ppm crystal the reading should land within about 4 Hz. A reading
//! that is off by a percent or more is a ring-oscillator-derived clock, which
//! means the switch-over did not happen.
//!
//! 1000 is even, so the output is a clean 50% duty cycle without the `DC50` bit.

const zdk = @import("pico_zdk");

/// Routes GPOUT0 to GPIO 21 and leaves it running.
pub fn main() noreturn {
    zdk.gpio.setFunction(21, .gpclk);
    zdk.clocks.gpoutEnable(.gpout0, .{ .source = .clk_sys, .div_int = 1000 });

    while (true) {
        // The generator runs in hardware; nothing left for the core to do.
        asm volatile ("wfi");
    }
}
