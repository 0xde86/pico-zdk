//! RP2040 USB controller (USBCTRL_REGS), modeled down to the one register the
//! startup chain touches.
//!
//! The chain powers the USB PHY down so it stops drawing current until M14
//! actually needs it. That is a single bit in `SIE_CTRL`; the rest of the block -
//! endpoint control, buffer status, the DPRAM below this window - arrives with
//! M14. The reserved head keeps `SIE_CTRL` at its true `0x4c` offset.
//!
//! Source: [RP2040 datasheet §4.1.4, "List of Registers"](https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// `SIE_CTRL`: serial interface engine control.
///
/// Only `TRANSCEIVER_PD` is named: the startup chain needs that bit, and it needs
/// to recognize the register's reset word so it can leave an already-configured
/// controller (a debugger or the bootrom) alone. Every other field is M14's.
pub const SieCtrl = packed struct(u32) {
    _reserved0: u18 = 0,
    /// `TRANSCEIVER_PD`: power down the USB PHY.
    transceiver_pd: bool = false,
    _reserved1: u13 = 0,
};

/// USBCTRL_REGS register block, truncated after `SIE_CTRL`.
pub const Registers = extern struct {
    _reserved0: [0x4c / 4]u32,
    sie_ctrl: mmio.ApbReadWrite(SieCtrl),
};

/// The USB controller's registers at their RP2040 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.usbctrl_regs_base);

/// `SIE_CTRL` word selecting only `TRANSCEIVER_PD`, for the atomic SET alias.
pub const transceiver_pd_mask: u32 = mmio.fieldMask(SieCtrl, .transceiver_pd);

comptime {
    const std = @import("std");

    std.debug.assert(@bitOffsetOf(SieCtrl, "transceiver_pd") == 18);
    std.debug.assert(transceiver_pd_mask == 0x0004_0000);

    // The documented reset word used by the "is USB already in use" guard.
    std.debug.assert(@as(u32, @bitCast(SieCtrl{})) == 0x0000_0000);

    std.debug.assert(@offsetOf(Registers, "sie_ctrl") == 0x4c);
    std.debug.assert(@intFromPtr(&registers.sie_ctrl) == 0x5011_004c);
}
