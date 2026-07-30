//! Selected-chip facade: exposes exactly one chip package, chosen by
//! `config.chip`, and comptime-verifies its contract.

const config = @import("config");

/// The concrete chip facade chosen by build configuration.
const selected = switch (config.chip) {
    .rp2040 => @import("./chip/rp2040.zig"),
    .rp2350 => @import("./chip/rp2350.zig"),
};

/// Reset-controller register package of the selected chip.
pub const resets = selected.resets;

/// User IO bank register package of the selected chip.
pub const io_bank0 = selected.io_bank0;

/// User IO pad register package of the selected chip.
pub const pads_bank0 = selected.pads_bank0;

/// Single-cycle I/O register package of the selected chip.
pub const sio = selected.sio;

/// Crystal oscillator register package of the selected chip.
pub const xosc = selected.xosc;

/// PLL register package of the selected chip; one layout, two instances.
pub const pll = selected.pll;

/// Clock generator register package of the selected chip.
pub const clocks = selected.clocks;

/// USB controller register package of the selected chip, modeled down to the
/// one register the startup chain touches.
pub const usb = selected.usb;

/// Watchdog register package, or `void` on a chip whose watchdog does not host
/// the tick generator.
pub const watchdog = if (config.chip == .rp2040) selected.watchdog else void;

/// Tick generator register package, or `void` on a chip that has no dedicated
/// TICKS block.
pub const ticks = if (config.chip == .rp2350) selected.ticks else void;

/// Datasheet-specified system clock frequency of the selected chip, in Hz.
pub const sys_clk_hz = selected.sys_clk_hz;

/// Clock frequency the selected chip's USB controller and ADC require, in Hz.
pub const usb_clk_hz = selected.usb_clk_hz;

/// Usable GPIO count of the selected chip/package.
pub const gpio_count = switch (config.package) {
    .rp2040_qfn56,
    .rp2350a_qfn60,
    => 30,
};

/// Returns the 32-bit RESETS register mask with `block`'s bit set.
pub inline fn mask(block: resets.Block) u32 {
    return @as(u32, 1) << @intFromEnum(block);
}

comptime {
    const std = @import("std");

    // check that selected chip doesn't drift from the shared facade interface
    _ = selected.resets;
    _ = selected.io_bank0;
    _ = selected.pads_bank0;
    _ = selected.sio;
    _ = selected.xosc;
    _ = selected.pll;
    _ = selected.clocks;
    _ = selected.usb;

    std.debug.assert(@bitSizeOf(resets.Reset) == 32);
    std.debug.assert(@offsetOf(resets.Registers, "reset") == 0x00);
    std.debug.assert(@offsetOf(resets.Registers, "wdsel") == 0x04);
    std.debug.assert(@offsetOf(resets.Registers, "reset_done") == 0x08);

    // The HAL builds masks from `Block`, while `Reset` models the same register
    // bits. Verify that both use the same (datasheet-defined) bit positions.
    for (@typeInfo(resets.Block).@"enum".fields) |field| {
        std.debug.assert(@bitOffsetOf(resets.Reset, field.name) == field.value);
    }

    std.debug.assert(@bitSizeOf(io_bank0.GpioStatus) == 32);
    std.debug.assert(@bitSizeOf(io_bank0.GpioCtrl) == 32);
    std.debug.assert(io_bank0.num_gpios >= gpio_count);
    std.debug.assert(@typeInfo(@FieldType(io_bank0.Registers, "io")).array.len == io_bank0.num_gpios);

    for ([_][]const u8{ "spi", "uart", "i2c", "pwm", "sio", "pio0", "pio1", "gpclk", "none" }) |name| {
        std.debug.assert(@hasField(io_bank0.FuncSel, name));
    }

    std.debug.assert(@intFromEnum(io_bank0.FuncSel.sio) == 5);
    std.debug.assert(@intFromEnum(io_bank0.FuncSel.none) == 31);
    std.debug.assert(@as(u32, @bitCast(io_bank0.GpioCtrl{})) == 0x0000_001f);

    std.debug.assert(@bitSizeOf(pads_bank0.Pad) == 32);
    std.debug.assert(pads_bank0.num_pads >= gpio_count);
    std.debug.assert(@typeInfo(@FieldType(pads_bank0.Registers, "gpio")).array.len == pads_bank0.num_pads);

    // Both blocks are indexed by the same pin number, so their slot counts
    // must agree - otherwise a pin valid for the mux could have no pad.
    std.debug.assert(pads_bank0.num_pads == io_bank0.num_gpios);

    // Pad fields the HAL drives on both chips. `isolate` is deliberately
    // absent from this list: it exists only on RP2350, and the HAL branches on
    // the chip rather than writing a reserved bit on RP2040.
    for ([_][]const u8{ "slew_fast", "schmitt", "pull_down", "pull_up", "drive", "input_enable", "output_disable" }) |name| {
        std.debug.assert(@hasField(pads_bank0.Pad, name));
    }

    // Drive strength is a shared four-value encoding, unlike the pad reset
    // word, which differs per chip and is asserted in each register file.
    for ([_][]const u8{ "ma_2", "ma_4", "ma_8", "ma_12" }) |name| {
        std.debug.assert(@hasField(pads_bank0.Drive, name));
    }
    std.debug.assert(@intFromEnum(pads_bank0.Drive.ma_4) == 1);

    // SIO GPIO command registers the HAL drives on both chips.
    for ([_][]const u8{
        "cpuid",        "gpio_in",      "gpio_out", "gpio_out_set",
        "gpio_out_clr", "gpio_out_xor", "gpio_oe",  "gpio_oe_set",
        "gpio_oe_clr",  "gpio_oe_xor",
    }) |name| {
        std.debug.assert(@hasField(sio.Registers, name));
    }

    // The startup chain's three reset masks. Their contents are chip-specific
    // (25 versus 29 subsystems), but all three must exist, must be subsets of
    // the chip's inventory, and must order themselves the same way everywhere.
    std.debug.assert(resets.early_reset_mask & ~resets.all_blocks_mask == 0);
    std.debug.assert(resets.early_release_mask & ~resets.all_blocks_mask == 0);
    std.debug.assert(resets.post_clock_release_mask & ~resets.all_blocks_mask == 0);
    // Everything released early is also released later, and the flash
    // interface is never reset out from under the running program.
    std.debug.assert(resets.early_release_mask & ~resets.post_clock_release_mask == 0);
    for ([_]resets.Block{ .io_qspi, .pads_qspi, .pll_sys, .pll_usb }) |block| {
        std.debug.assert(resets.early_reset_mask & mask(block) == 0);
    }

    // XOSC: the magic-value contract, identical on both chips.
    std.debug.assert(@bitSizeOf(xosc.Ctrl) == 32);
    std.debug.assert(@intFromEnum(xosc.Enable.enable) == 0xfab);
    std.debug.assert(@intFromEnum(xosc.Enable.disable) == 0xd1e);
    std.debug.assert(@intFromEnum(xosc.FreqRange.mhz_1_15) == 0xaa0);
    std.debug.assert(@offsetOf(xosc.Registers, "ctrl") == 0x00);
    std.debug.assert(@offsetOf(xosc.Registers, "status") == 0x04);
    std.debug.assert(@offsetOf(xosc.Registers, "startup") == 0x0c);
    for ([_][]const u8{ "enabled", "stable", "badwrite" }) |name| {
        std.debug.assert(@hasField(xosc.Status, name));
    }

    // PLL: the first four registers and both instances are the shared contract;
    // RP2350's interrupt tail is not.
    std.debug.assert(@offsetOf(pll.Registers, "cs") == 0x00);
    std.debug.assert(@offsetOf(pll.Registers, "pwr") == 0x04);
    std.debug.assert(@offsetOf(pll.Registers, "fbdiv_int") == 0x08);
    std.debug.assert(@offsetOf(pll.Registers, "prim") == 0x0c);
    std.debug.assert(@as(u32, @bitCast(pll.Pwr{})) == 0x0000_002d);
    std.debug.assert(@intFromPtr(pll.instance(.sys)) != @intFromPtr(pll.instance(.usb)));

    // CLOCKS: the generators both chips instantiate, and the two that only one
    // does. A generator's ordinal is its register index, so the names must map
    // to different offsets on the two chips - that divergence is the contract.
    for ([_][]const u8{ "gpout0", "gpout1", "gpout2", "gpout3", "ref", "sys", "peri", "usb", "adc" }) |name| {
        std.debug.assert(@hasField(clocks.Generator, name));
    }
    std.debug.assert(@hasField(clocks.Generator, "rtc") != @hasField(clocks.Generator, "hstx"));
    std.debug.assert(@typeInfo(clocks.Generator).@"enum".fields.len == 10);
    // Only `clk_ref` and `clk_sys` have a glitchless mux; only they lack a gate.
    for ([_]clocks.Generator{ .ref, .sys }) |gen| {
        const Ctrl = clocks.GeneratorType(gen).Ctrl;
        std.debug.assert(@hasField(Ctrl, "src"));
        std.debug.assert(!@hasField(Ctrl, "enable"));
    }
    for ([_]clocks.Generator{ .gpout0, .peri, .usb, .adc }) |gen| {
        const Ctrl = clocks.GeneratorType(gen).Ctrl;
        std.debug.assert(!@hasField(Ctrl, "src"));
        std.debug.assert(@hasField(Ctrl, "enable"));
    }
    // Divider fixed-point is a per-chip fact the HAL reads off the register
    // type rather than restating: 24.8 on RP2040, 16.16 on RP2350. Copying a
    // divider word across chips silently means a different ratio.
    std.debug.assert(@bitOffsetOf(clocks.FracDiv, "int") ==
        if (config.chip == .rp2040) 8 else 16);

    // USB: one register, two different documented reset words.
    std.debug.assert(@offsetOf(usb.Registers, "sie_ctrl") == 0x4c);
    std.debug.assert(usb.transceiver_pd_mask == 0x0004_0000);
}
