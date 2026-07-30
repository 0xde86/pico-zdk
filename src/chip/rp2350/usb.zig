//! RP2350 USB controller (USBCTRL_REGS), modeled down to the one register the
//! startup chain touches.
//!
//! The chain powers the USB PHY down so it stops drawing current until M14
//! actually needs it. That is a single bit in `SIE_CTRL`; the rest of the block -
//! endpoint control, buffer status, the DPRAM below this window - arrives with
//! M14. The reserved head keeps `SIE_CTRL` at its true `0x4c` offset.
//!
//! Source: [RP2350 datasheet §12.6.4, "List of Registers"](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// `SIE_CTRL`: serial interface engine control.
///
/// Two fields are named: `TRANSCEIVER_PD`, which the startup chain sets, and
/// `EP0_INT_1BUF`, which is the only bit set in this chip's reset word. The
/// chain compares against that word to leave an already-configured controller (a
/// debugger or the bootrom) alone. Every other field is M14's.
pub const SieCtrl = packed struct(u32) {
    _reserved0: u15 = 0,
    /// `EP0_INT_1BUF`: interrupt on every buffer completion for endpoint 0.
    /// Set in the documented reset state.
    ep0_int_1buf: bool = true,
    _reserved1: u2 = 0,
    /// `TRANSCEIVER_PD`: power down the USB PHY.
    transceiver_pd: bool = false,
    _reserved2: u13 = 0,
};

/// USBCTRL_REGS register block, truncated after `SIE_CTRL`.
pub const Registers = extern struct {
    _reserved0: [0x4c / 4]u32,
    sie_ctrl: mmio.ApbReadWrite(SieCtrl),
};

/// The USB controller's registers at their RP2350 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.usbctrl_regs_base);

/// `SIE_CTRL` word selecting only `TRANSCEIVER_PD`, for the atomic SET alias.
pub const transceiver_pd_mask: u32 = mmio.fieldMask(SieCtrl, .transceiver_pd);

comptime {
    const std = @import("std");

    std.debug.assert(@bitOffsetOf(SieCtrl, "ep0_int_1buf") == 15);
    std.debug.assert(@bitOffsetOf(SieCtrl, "transceiver_pd") == 18);
    std.debug.assert(transceiver_pd_mask == 0x0004_0000);

    // The documented reset word.
    std.debug.assert(@as(u32, @bitCast(SieCtrl{})) == 0x0000_8000);

    std.debug.assert(@offsetOf(Registers, "sie_ctrl") == 0x4c);
    std.debug.assert(@intFromPtr(&registers.sie_ctrl) == 0x5011_004c);
}
