//! RP2040 subsystem-reset controller (RESETS).
//!
//! Source: [RP2040 datasheet §2.14, "Subsystem Resets"](https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf#section_resets).

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
    i2c0 = 3,
    i2c1 = 4,
    io_bank0 = 5,
    io_qspi = 6,
    jtag = 7,
    pads_bank0 = 8,
    pads_qspi = 9,
    pio0 = 10,
    pio1 = 11,
    pll_sys = 12,
    pll_usb = 13,
    pwm = 14,
    rtc = 15,
    spi0 = 16,
    spi1 = 17,
    syscfg = 18,
    sysinfo = 19,
    tbman = 20,
    timer = 21,
    uart0 = 22,
    uart1 = 23,
    usbctrl = 24,
};

/// Register value layout shared by RESET, WDSEL, and RESET_DONE: one bit
/// per subsystem, assigned as in `Block` (RP2040 datasheet §2.14.3).
pub const Reset = packed struct(u32) {
    adc: u1,
    busctrl: u1,
    dma: u1,
    i2c0: u1,
    i2c1: u1,
    io_bank0: u1,
    io_qspi: u1,
    jtag: u1,
    pads_bank0: u1,
    pads_qspi: u1,
    pio0: u1,
    pio1: u1,
    pll_sys: u1,
    pll_usb: u1,
    pwm: u1,
    rtc: u1,
    spi0: u1,
    spi1: u1,
    syscfg: u1,
    sysinfo: u1,
    tbman: u1,
    timer: u1,
    uart0: u1,
    uart1: u1,
    usbctrl: u1,
    _reserved0: u7 = 0,
};

/// RESETS register block; member offsets are pinned by the comptime
/// asserts in `chip.zig`.
pub const Registers = extern struct {
    reset: mmio.ApbReadWrite(Reset),
    wdsel: mmio.ApbReadWrite(Reset),
    reset_done: mmio.ReadOnly(Reset),
};

/// The RESETS peripheral at its RP2040 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.resets_base);

/// Every subsystem this chip's RESETS block controls: 25 bits.
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
/// wants `clk_adc`, the RTC `clk_rtc`, SPI and UART `clk_peri`, USBCTRL
/// `clk_usb` - and their `RESET_DONE` would never assert. ADC, SPI, UART, and
/// USBCTRL are released after M3 brings their clocks up; RTC stays reset until
/// M15. This split is stated explicitly because the old blanket wording
/// incorrectly implied that M3 also released RTC.
pub const early_release_mask: u32 = maskExcluding(&.{
    .adc,
    .rtc,
    .spi0,
    .spi1,
    .uart0,
    .uart1,
    .usbctrl,
});

/// Blocks the chain releases once every M3-configured peripheral clock is
/// running.
///
/// This is the whole inventory except RTC. M3 deliberately leaves `clk_rtc`
/// unconfigured (M15 owns it), and `RESET_DONE` for a block whose functional
/// clock is stopped never asserts, so releasing the RTC here would hang the
/// release poll. Calling this "every peripheral" previously hid that intentional
/// deferral; M15 configures `clk_rtc` and moves RTC into this mask.
pub const post_clock_release_mask: u32 = maskExcluding(&.{.rtc});

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
    std.debug.assert(all_blocks_mask == 0x01ff_ffff);
    std.debug.assert(early_reset_mask == 0x00fb_cdbf);
    std.debug.assert(early_release_mask == 0x003c_7ffe);
    std.debug.assert(post_clock_release_mask == 0x01ff_7fff);

    // Every exclusion is genuinely absent, and nothing else is.
    std.debug.assert(all_blocks_mask & ~early_reset_mask == 0x0104_3240);
    std.debug.assert(all_blocks_mask & ~early_release_mask == 0x01c3_8001);
}
