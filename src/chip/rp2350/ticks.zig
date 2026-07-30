//! RP2350 tick generators (TICKS).
//!
//! Each consumer has its own generator: six identical `{CTRL, CYCLES, COUNT}`
//! triples divide `clk_ref` down to the 1 MHz pulse train that timers count.
//!
//! The `riscv` generator matters most here: when the Pico 2 boots its Hazard3
//! cores, the standard RISC-V `mtime` timebase counts exactly these ticks, so
//! firmware that never starts them has a frozen `mtime` and no fault to explain
//! it.
//!
//! This chip-specific block is reached only from a comptime chip branch.
//!
//! Source: [RP2350 datasheet §8.5, "Ticks"](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// The six independent tick generators, in register-map order.
pub const Generator = enum(u3) {
    /// Core 0's Cortex-M33 SysTick external reference.
    proc0,
    /// Core 1's Cortex-M33 SysTick external reference.
    proc1,
    /// TIMER0's microsecond timebase.
    timer0,
    /// TIMER1's microsecond timebase.
    timer1,
    /// The watchdog countdown.
    watchdog,
    /// The Hazard3 `mtime`/`mtimeh` timebase.
    riscv,
};

/// `TICK_*_CTRL`: enable and running status of one generator.
pub const Ctrl = packed struct(u32) {
    /// `ENABLE`: run the generator.
    enable: bool = false,
    /// `RUNNING`: read-only; the generator is active.
    running: bool = false,
    _reserved0: u30 = 0,
};

/// `TICK_*_CYCLES`: `clk_ref` cycles per tick.
pub const Cycles = packed struct(u32) {
    /// `CYCLES`: nine bits, so at most 511.
    cycles: u9 = 0,
    _reserved0: u23 = 0,
};

/// `TICK_*_COUNT`: read-only countdown state.
pub const Count = packed struct(u32) {
    /// `COUNT`: cycles remaining until the next tick.
    count: u9 = 0,
    _reserved0: u23 = 0,
};

/// One tick generator's register triple.
pub const GeneratorRegisters = extern struct {
    ctrl: mmio.ApbReadWrite(Ctrl),
    cycles: mmio.ApbReadWrite(Cycles),
    count: mmio.ReadOnly(Count),
};

/// TICKS register block.
pub const Registers = extern struct {
    generators: [6]GeneratorRegisters,
};

/// The TICKS peripheral at its RP2350 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.ticks_base);

/// Returns a pointer to `gen`'s register triple inside the TICKS block.
pub inline fn generator(comptime gen: Generator) *volatile GeneratorRegisters {
    return &registers.generators[@intFromEnum(gen)];
}

comptime {
    const std = @import("std");

    // Field bit positions per the datasheet register definitions.
    std.debug.assert(@bitOffsetOf(Ctrl, "enable") == 0);
    std.debug.assert(@bitOffsetOf(Ctrl, "running") == 1);
    std.debug.assert(@bitSizeOf(@FieldType(Cycles, "cycles")) == 9);
    std.debug.assert(@bitSizeOf(@FieldType(Count, "count")) == 9);

    // Block layout: three words per generator, six generators.
    std.debug.assert(@sizeOf(GeneratorRegisters) == 12);
    std.debug.assert(@sizeOf(Registers) == 0x48);
    std.debug.assert(@typeInfo(@FieldType(Registers, "generators")).array.len ==
        @typeInfo(Generator).@"enum".fields.len);

    // Generator bases, per the datasheet's register table.
    std.debug.assert(@intFromPtr(generator(.proc0)) == 0x4010_8000);
    std.debug.assert(@intFromPtr(generator(.timer0)) == 0x4010_8018);
    std.debug.assert(@intFromPtr(generator(.watchdog)) == 0x4010_8030);
    std.debug.assert(@intFromPtr(generator(.riscv)) == 0x4010_803c);
}
