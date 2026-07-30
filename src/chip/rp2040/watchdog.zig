//! RP2040 watchdog (WATCHDOG), which also hosts the chip's single tick
//! generator.
//!
//! M3 consumes only `TICK`: one pulse every `CYCLES` cycles of `clk_ref`, feeding
//! both the TIMER peripheral and the watchdog countdown. The watchdog proper -
//! `CTRL`, `LOAD`, `REASON`, and the scratch registers that survive a reset - is
//! modeled here as data and driven by M15.
//!
//! This chip-specific block is reached only from a comptime chip branch.
//!
//! Source: [RP2040 datasheet §4.7, "Watchdog"](https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// `CTRL`: watchdog countdown control and debug-pause behavior.
pub const Ctrl = packed struct(u32) {
    /// `TIME`: the countdown's current value, in microseconds times two.
    time: u24 = 0,
    /// `PAUSE_JTAG`: stop the countdown while the JTAG tap is in reset.
    pause_jtag: bool = true,
    /// `PAUSE_DBG0`: stop the countdown while core 0 is halted in the debugger.
    pause_dbg0: bool = true,
    /// `PAUSE_DBG1`: stop the countdown while core 1 is halted in the debugger.
    pause_dbg1: bool = true,
    _reserved0: u3 = 0,
    /// `ENABLE`: run the countdown.
    enable: bool = false,
    /// `TRIGGER`: write 1 to reset the chip immediately.
    trigger: bool = false,
};

/// `LOAD`: write here to restart the countdown ("feed the watchdog").
pub const Load = packed struct(u32) {
    /// `LOAD`: the value the countdown restarts from.
    load: u24 = 0,
    _reserved0: u8 = 0,
};

/// `REASON`: why the chip last reset, latched by the watchdog.
pub const Reason = packed struct(u32) {
    /// `TIMER`: the countdown reached zero.
    timer: bool = false,
    /// `FORCE`: software wrote `CTRL.TRIGGER`.
    force: bool = false,
    _reserved0: u30 = 0,
};

/// `TICK`: the chip's tick generator, dividing `clk_ref` down to the 1 MHz pulse
/// train that timers count.
///
/// The generator comes out of reset already enabled with `CYCLES` at zero, so
/// startup writes both fields in one word rather than only the divisor.
pub const Tick = packed struct(u32) {
    /// `CYCLES`: `clk_ref` cycles per tick. Nine bits, so at most 511.
    cycles: u9 = 0,
    /// `ENABLE`: run the generator.
    enable: bool = true,
    /// `RUNNING`: read-only; the generator is active.
    running: bool = false,
    /// `COUNT`: read-only; the countdown's current state.
    count: u9 = 0,
    _reserved0: u12 = 0,
};

/// WATCHDOG register block.
pub const Registers = extern struct {
    ctrl: mmio.ApbReadWrite(Ctrl),
    load: mmio.WriteOnly(Load),
    reason: mmio.ReadOnly(Reason),
    /// `SCRATCH0`..`SCRATCH7`: general-purpose words that survive a watchdog
    /// reset. The bootrom and M12's reboot paths give them meaning.
    scratch: [8]mmio.ApbReadWrite(u32),
    tick: mmio.ApbReadWrite(Tick),
};

/// The WATCHDOG peripheral at its RP2040 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.watchdog_base);

comptime {
    const std = @import("std");

    // Field bit positions per the datasheet register definitions.
    std.debug.assert(@bitOffsetOf(Ctrl, "pause_jtag") == 24);
    std.debug.assert(@bitOffsetOf(Ctrl, "enable") == 30);
    std.debug.assert(@bitOffsetOf(Ctrl, "trigger") == 31);

    std.debug.assert(@bitOffsetOf(Tick, "cycles") == 0);
    std.debug.assert(@bitOffsetOf(Tick, "enable") == 9);
    std.debug.assert(@bitOffsetOf(Tick, "running") == 10);
    std.debug.assert(@bitOffsetOf(Tick, "count") == 11);

    // The single word M3 writes: 12 cycles of a 12 MHz clk_ref, enabled.
    std.debug.assert(@as(u32, @bitCast(Tick{ .cycles = 12, .enable = true })) == 0x0000_020c);

    // Block layout: the scratch array is what pushes TICK out to 0x2c.
    std.debug.assert(@offsetOf(Registers, "ctrl") == 0x00);
    std.debug.assert(@offsetOf(Registers, "load") == 0x04);
    std.debug.assert(@offsetOf(Registers, "reason") == 0x08);
    std.debug.assert(@offsetOf(Registers, "scratch") == 0x0c);
    std.debug.assert(@offsetOf(Registers, "tick") == 0x2c);
    std.debug.assert(@sizeOf(Registers) == 0x30);
    std.debug.assert(@intFromPtr(&registers.tick) == 0x4005_802c);
}
