//! Blinky: toggle the on-board LED through the SIO digital-I/O HAL.
//!
//! The blink rate is still a busy-wait, so it is approximate - but it is now a
//! busy-wait on a crystal-derived system clock.

const zdk = @import("pico_zdk");

/// Configures the board LED for SIO output and toggles it forever using an
/// intentionally approximate delay.
///
/// The runtime's default startup already released the GPIO blocks, so this no
/// longer repeats that reset operation.
pub fn main() noreturn {
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
