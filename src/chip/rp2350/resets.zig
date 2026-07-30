//! RP2350 subsystem-reset controller (RESETS).
//!
//! Source: [RP2350 datasheet §7.5, "Subsystem resets"](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf#section_subsystem_resets).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// Bit position of each resettable subsystem within the RESETS registers.
///
/// Positions are chip-specific; the member names form the portable contract
/// probed in `chip.zig`.
pub const Block = enum(u5) {
    adc = 0,
    busctrl = 1,
    dma = 2,
    hstx = 3,
    i2c0 = 4,
    i2c1 = 5,
    io_bank0 = 6,
    io_qspi = 7,
    jtag = 8,
    pads_bank0 = 9,
    pads_qspi = 10,
    pio0 = 11,
    pio1 = 12,
    pio2 = 13,
    pll_sys = 14,
    pll_usb = 15,
    pwm = 16,
    sha256 = 17,
    spi0 = 18,
    spi1 = 19,
    syscfg = 20,
    sysinfo = 21,
    tbman = 22,
    timer0 = 23,
    timer1 = 24,
    trng = 25,
    uart0 = 26,
    uart1 = 27,
    usbctrl = 28,
};

/// Register value layout shared by RESET, WDSEL, and RESET_DONE: one bit
/// per subsystem, assigned as in `Block` (RP2350 datasheet §7.5).
pub const Reset = packed struct(u32) {
    adc: u1,
    busctrl: u1,
    dma: u1,
    hstx: u1,
    i2c0: u1,
    i2c1: u1,
    io_bank0: u1,
    io_qspi: u1,
    jtag: u1,
    pads_bank0: u1,
    pads_qspi: u1,
    pio0: u1,
    pio1: u1,
    pio2: u1,
    pll_sys: u1,
    pll_usb: u1,
    pwm: u1,
    sha256: u1,
    spi0: u1,
    spi1: u1,
    syscfg: u1,
    sysinfo: u1,
    tbman: u1,
    timer0: u1,
    timer1: u1,
    trng: u1,
    uart0: u1,
    uart1: u1,
    usbctrl: u1,
    _reserved0: u3 = 0,
};

/// RESETS register block; member offsets are pinned by the comptime
/// asserts in `chip.zig`.
pub const Registers = extern struct {
    reset: mmio.ApbReadWrite(Reset),
    wdsel: mmio.ApbReadWrite(Reset),
    reset_done: mmio.ReadOnly(Reset),
};

/// The RESETS peripheral at its RP2350 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.resets_base);

/// Every subsystem this chip's RESETS block controls: 29 bits.
/// The startup chain's masks are carved out of this inventory.
pub const all_blocks_mask: u32 = maskExcluding(&.{});

/// Blocks the startup chain's early reset step must leave running.
///
/// IO_QSPI and PADS_QSPI carry the flash this code executes from, so resetting
/// them is instant death. The PLLs are excluded because clock muxing is not yet
/// in a reset-safe state. USBCTRL and SYSCFG are excluded because resetting them
/// breaks USB-to-SWD debug setups.
pub const early_reset_mask: u32 = maskExcluding(&.{
    .io_qspi,
    .pads_qspi,
    .pll_sys,
    .pll_usb,
    .syscfg,
    .usbctrl,
});

/// Blocks the chain releases before the clock tree is configured: everything
/// clocked only from `clk_sys` and `clk_ref`.
///
/// The excluded blocks need a peripheral clock that does not exist yet - ADC
/// wants `clk_adc`, HSTX `clk_hstx`, SPI and UART `clk_peri`, USBCTRL `clk_usb` -
/// and their `RESET_DONE` would never assert. ADC, SPI, UART, and USBCTRL are
/// released after M3 brings their clocks up; HSTX stays reset until M29. This
/// split is stated explicitly because the old blanket wording incorrectly
/// implied that M3 also released HSTX.
pub const early_release_mask: u32 = maskExcluding(&.{
    .adc,
    .hstx,
    .spi0,
    .spi1,
    .uart0,
    .uart1,
    .usbctrl,
});

/// Blocks the chain releases once every M3-configured peripheral clock is
/// running.
///
/// This is the whole inventory except HSTX. M3 deliberately leaves `clk_hstx`
/// unconfigured (M29 owns it), and `RESET_DONE` for a block whose functional
/// clock is stopped never asserts, so releasing HSTX here would hang the release
/// poll. Calling this "every peripheral" previously hid that intentional
/// deferral; M29 configures `clk_hstx` and moves HSTX into this mask.
pub const post_clock_release_mask: u32 = maskExcluding(&.{.hstx});

/// Returns the mask of every block except those in `exclusions`.
fn maskExcluding(comptime exclusions: []const Block) u32 {
    comptime {
        var mask: u32 = 0;
        for (@typeInfo(Block).@"enum".fields) |field| mask |= @as(u32, 1) << field.value;
        for (exclusions) |block| mask &= ~(@as(u32, 1) << @intFromEnum(block));
        return mask;
    }
}

comptime {
    const std = @import("std");

    // The chain masks, against the words worked through in the manual's
    // startup tables. A drift here means a block silently changed sides.
    std.debug.assert(all_blocks_mask == 0x1fff_ffff);
    std.debug.assert(early_reset_mask == 0x0fef_3b7f);
    std.debug.assert(early_release_mask == 0x03f3_fff6);
    std.debug.assert(post_clock_release_mask == 0x1fff_fff7);

    // Every exclusion is genuinely absent, and nothing else is.
    std.debug.assert(all_blocks_mask & ~early_reset_mask == 0x1010_c480);
    std.debug.assert(all_blocks_mask & ~early_release_mask == 0x1c0c_0009);
}
