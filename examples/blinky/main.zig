//! Blinky: toggle the on-board LED through the SIO digital-I/O HAL.
//!
//! The blink rate is an imprecise busy-wait: the chip is still running on its
//! reset-default oscillator because configured clocks and a hardware timer
//! arrive later.

const zdk = @import("pico_zdk");

/// Releases the GPIO blocks, configures the board LED for SIO output, and
/// toggles it forever using an intentionally approximate delay.
pub fn main() noreturn {
    zdk.resets.releaseAndWait(&.{ .io_bank0, .pads_bank0 });
    const led = zdk.sio.init(zdk.board.Pin.led, .{
        .direction = .output,
        .initial_value = false,
    });
    defer led.deinit();

    while (true) {
        led.toggle();
        busyWait(1);
        led.toggle();
        busyWait(1);
        led.toggle();
        busyWait(1);
        led.toggle();
        busyWait(1);
        led.toggle();
        busyWait(4);
        led.toggle();
        busyWait(4);
    }
}

/// Crude, clock-dependent delay. The empty `volatile` asm is a compiler barrier
/// so the loop survives `ReleaseSmall`; an ordinary counter whose result is
/// never observed can be deleted entirely. Replaced by a real timer in M4.
fn busyWait(duration: comptime_int) void {
    var i: u32 = 0;
    while (i < duration * 400_000) : (i += 1) {
        asm volatile ("" ::: .{ .memory = true });
    }
}
