//! Software-controlled digital I/O through the SIO hardware block.
//!
//! `init` validates the pin at comptime - a GPIO number or a board `Pin` enum
//! value; out of range is a compile error - and returns a zero-sized,
//! pin-specific handle whose methods drive it:
//!
//!     const zdk = @import("pico_zdk");
//!
//!     zdk.resets.releaseAndWait(&.{ .io_bank0, .pads_bank0 });
//!     const led = zdk.sio.init(zdk.board.Pin.led, .{ .direction = .output });
//!     led.toggle();
//!     led.deinit(); // back to the power-on reset state

const std = @import("std");
const chip = @import("../chip.zig");
const mmio = @import("../chip/mmio.zig");
const gpio = @import("gpio.zig");

/// Direction of a pin's output driver.
pub const Direction = enum {
    /// Output driver disabled; the pad reads its external level (high-impedance).
    input,
    /// Output driver enabled; the pad drives the `GPIO_OUT` latch value.
    output,
};

/// Options for `init`.
pub const InitOptions = struct {
    /// Whether the pin drives (`output`) or reads (`input`) after init.
    direction: Direction = .input,
    /// Output latch value preloaded before the driver is enabled, so an output
    /// pin's first driven level is the intended one.
    initial_value: bool = false,
    /// Weak pull-resistor bias.
    pull: gpio.Pull = .none,
};

/// Initializes `pin` as software-controlled GPIO and returns a zero-sized
/// handle for further SIO operations.
///
/// `pin` is a GPIO number or a board `Pin` enum value, validated at comptime.
/// SIO output-enable is cleared, the requested output value is preloaded, and
/// output-enable is set only after the pad and mux are configured. This avoids
/// a wrong-level SIO output when the pin is in reset state or already routed to
/// SIO. A pin currently driven by another peripheral must be quiesced by that
/// peripheral before calling `init`.
///
/// `options.pull` is always applied; its default `.none` actively disables both
/// internal pulls rather than preserving the previous pad configuration.
/// The reset controller must already have released IO_BANK0 and PADS_BANK0.
pub fn init(comptime pin: anytype, comptime options: InitOptions) Pin(pin) {
    const P = Pin(pin);
    const index = P.index;
    const mask = P.mask;

    // Value first, driver last: keep the output driver off during configuration.
    chip.sio.registers.gpio_oe_clr.write(mask);
    if (options.initial_value)
        chip.sio.registers.gpio_out_set.write(mask)
    else
        chip.sio.registers.gpio_out_clr.write(mask);

    gpio.setPull(index, options.pull);
    gpio.setFunction(index, .sio);

    if (options.direction == .output)
        chip.sio.registers.gpio_oe_set.write(mask);

    return .{};
}

/// Generates the private SIO handle type for one comptime-validated pin.
fn Pin(comptime pin: anytype) type {
    const _index = gpio.pinIndex(pin);
    const _mask = std.math.shl(u32, 1, _index);

    return struct {
        const Self = @This();

        /// Compile-time GPIO number used by this handle.
        pub const index = _index;
        /// Compile-time SIO low-bank mask selecting this GPIO.
        pub const mask = _mask;

        /// Returns the pin to its power-on reset state: output driver and latch
        /// cleared, function mux disconnected (FUNCSEL = NULL), and the pad
        /// restored to its reset word.
        pub fn deinit(_: Self) void {
            // Stop driving before disconnecting so the pad cannot glitch.
            chip.sio.registers.gpio_oe_clr.write(_mask);
            chip.sio.registers.gpio_out_clr.write(_mask);
            gpio.reset(_index);
        }

        /// Enables or disables the pin's output driver via SIO's atomic OE registers.
        pub inline fn setDirection(_: Self, direction: Direction) void {
            switch (direction) {
                .output => chip.sio.registers.gpio_oe_set.write(_mask),
                .input => chip.sio.registers.gpio_oe_clr.write(_mask),
            }
        }

        /// Drives the pin's output latch high (`true`) or low (`false`) via SIO's
        /// atomic OUT registers. Only reaches the pad while the pin is an output.
        pub inline fn put(_: Self, value: bool) void {
            if (value)
                chip.sio.registers.gpio_out_set.write(_mask)
            else
                chip.sio.registers.gpio_out_clr.write(_mask);
        }

        /// Reads the pin's live input level from SIO `GPIO_IN`.
        pub inline fn get(_: Self) bool {
            return chip.sio.registers.gpio_in.read() & _mask != 0;
        }

        /// Toggles the pin's output latch via SIO's atomic `GPIO_OUT_XOR`, race-free
        /// against another execution context toggling a different pin.
        pub inline fn toggle(_: Self) void {
            chip.sio.registers.gpio_out_xor.write(_mask);
        }
    };
}

comptime {
    std.debug.assert(@bitSizeOf(Pin(0)) == 0);
}
