//! Portable tick generation: the shared 1 microsecond pulse train that timers
//! count.
//!
//!     const zdk = @import("pico_zdk");
//!
//!     zdk.ticks.startAll(12_000_000); // clk_ref frequency
//!
//! Rather than each timer dividing the system clock itself, the hardware
//! generates one pulse every N cycles of `clk_ref` and every consumer counts
//! those. Because `clk_ref` runs from the crystal by the time this is called,
//! every tick is crystal-accurate.
//!
//! The behavior is chip-neutral; the mechanism is not. RP2040 has a single
//! generator hidden in the watchdog, feeding the timer and the watchdog
//! countdown. RP2350 has a dedicated TICKS block with six independent
//! generators, one of which is the Hazard3 `mtime` timebase that M4 and M7
//! depend on when the Pico 2 runs RISC-V.
//!
//! Hardware behavior follows RP2040 datasheet §4.7.2 and RP2350 datasheet §8.5.

const std = @import("std");
const config = @import("config");
const chip = @import("../chip.zig");

/// Tick rate every generator is started at, in Hz. One tick per microsecond is
/// what the 64-bit timers and both cores' architectural timebases expect.
pub const tick_hz: u32 = 1_000_000;

/// Starts every tick domain at one tick per microsecond from a `clk_ref_hz`
/// reference.
///
/// `clk_ref` must already run at `clk_ref_hz` - the runtime calls this after the
/// clock tree is switched to the crystal, so the first tick ever generated is
/// already accurate. A reference frequency that is not a whole number of
/// microseconds, or that needs more cycles than the hardware's 9-bit divisor
/// holds, is a compile error.
pub fn startAll(comptime clk_ref_hz: u32) void {
    const cycles = comptime cyclesPerTick(clk_ref_hz);

    // Dependency rule: the chip-unique tick hardware is reachable only from a
    // comptime branch on the selected chip.
    switch (config.chip) {
        .rp2040 => {
            // One generator for the whole chip. It leaves reset already enabled
            // with a zero divisor, so both fields are written together.
            chip.watchdog.registers.tick.write(.{ .cycles = cycles, .enable = true });
        },
        .rp2350 => {
            // Six independent generators. `inline for` unrolls to direct stores
            // at each generator's own offset, with no runtime indexing.
            inline for (comptime std.enums.values(chip.ticks.Generator)) |gen| {
                const registers = chip.ticks.generator(gen);
                registers.cycles.write(.{ .cycles = cycles });
                registers.ctrl.write(.{ .enable = true });
            }
        },
    }
}

/// Returns the `clk_ref` cycles per tick for a `clk_ref_hz` reference.
///
/// Nine bits wide on both chips, so the reference cannot exceed 511 MHz - which
/// is also what rejects an accidentally large value here.
pub fn cyclesPerTick(comptime clk_ref_hz: u32) u9 {
    return comptime blk: {
        if (clk_ref_hz % tick_hz != 0) @compileError(std.fmt.comptimePrint(
            "ticks: a {d} Hz reference does not divide into whole {d} Hz ticks",
            .{ clk_ref_hz, tick_hz },
        ));

        const cycles = clk_ref_hz / tick_hz;
        if (cycles == 0) @compileError(std.fmt.comptimePrint(
            "ticks: a {d} Hz reference is slower than the {d} Hz tick rate",
            .{ clk_ref_hz, tick_hz },
        ));
        if (cycles > std.math.maxInt(u9)) @compileError(std.fmt.comptimePrint(
            "ticks: {d} cycles per tick does not fit the hardware's 9-bit divisor (max {d})",
            .{ cycles, std.math.maxInt(u9) },
        ));
        break :blk cycles;
    };
}

comptime {
    // The divisor both supported boards program: 12 MHz crystal, 1 MHz ticks.
    std.debug.assert(cyclesPerTick(12_000_000) == 12);
}

test "the tick divisor turns a reference frequency into whole microseconds" {
    try std.testing.expectEqual(@as(u9, 12), cyclesPerTick(12_000_000));
    try std.testing.expectEqual(@as(u9, 1), cyclesPerTick(1_000_000));
    try std.testing.expectEqual(@as(u9, 48), cyclesPerTick(48_000_000));
    // The largest reference the 9-bit field can serve.
    try std.testing.expectEqual(@as(u9, 511), cyclesPerTick(511_000_000));

    // Each divisor really does produce one tick per microsecond.
    inline for ([_]u32{ 1_000_000, 12_000_000, 48_000_000 }) |ref_hz| {
        try std.testing.expectEqual(tick_hz, ref_hz / cyclesPerTick(ref_hz));
    }
}
