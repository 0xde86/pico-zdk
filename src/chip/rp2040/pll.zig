//! RP2040 phase-locked loops (PLL_SYS and PLL_USB).
//!
//! One register layout, instantiated twice at different base addresses. A PLL
//! multiplies the crystal reference up to a VCO frequency and divides that back
//! down with two series post-dividers:
//!
//!     f_out = (f_ref / REFDIV) * FBDIV / (POSTDIV1 * POSTDIV2)
//!
//! Source: [RP2040 datasheet §2.18, "PLL"](https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// The two PLL instances this chip carries.
pub const Instance = enum {
    /// System PLL: the source `clk_sys` runs from at spec speed.
    sys,
    /// USB PLL: the 48 MHz source for `clk_usb` and `clk_adc`.
    usb,
};

/// `CS`: control and status.
pub const Cs = packed struct(u32) {
    /// `REFDIV`: divides the reference before the phase comparator. The divided
    /// reference must stay at or above 5 MHz.
    refdiv: u6 = 1,
    _reserved0: u2 = 0,
    /// `BYPASS`: route the reference straight to the output, skipping the loop.
    /// Debug use only.
    bypass: bool = false,
    _reserved1: u22 = 0,
    /// `LOCK`: read-only; the feedback loop has converged and the output is
    /// trustworthy.
    lock: bool = false,
};

/// `PWR`: per-section power-down bits. Every bit resets to 1, so a PLL powers
/// up completely off.
pub const Pwr = packed struct(u32) {
    /// `PD`: master power-down for the PLL's analog core.
    pd: bool = true,
    _reserved0: u1 = 0,
    /// `DSMPD`: power-down for the delta-sigma modulator that drives fractional
    /// feedback. These chips run integer-N only, so this stays set.
    dsmpd: bool = true,
    /// `POSTDIVPD`: power-down for the output post-dividers. Held down until the
    /// loop locks so consumers never see the VCO hunting.
    postdivpd: bool = true,
    _reserved1: u1 = 0,
    /// `VCOPD`: power-down for the oscillator itself.
    vcopd: bool = true,
    _reserved2: u26 = 0,
};

/// `FBDIV_INT`: the feedback divider, and therefore the multiplication factor.
pub const FbdivInt = packed struct(u32) {
    /// `FBDIV_INT`: valid range 16 to 320.
    fbdiv_int: u12 = 0,
    _reserved0: u20 = 0,
};

/// `PRIM`: the two output post-dividers, applied in series.
pub const Prim = packed struct(u32) {
    _reserved0: u12 = 0,
    /// `POSTDIV2`: second divider, 1 to 7. Conventionally the smaller of the two.
    postdiv2: u3 = 7,
    _reserved1: u1 = 0,
    /// `POSTDIV1`: first divider, 1 to 7. Conventionally the larger of the two,
    /// because it divides at VCO speed and so saves a little power.
    postdiv1: u3 = 7,
    _reserved2: u13 = 0,
};

/// PLL register block, ending after `PRIM`.
pub const Registers = extern struct {
    cs: mmio.ApbReadWrite(Cs),
    pwr: mmio.ApbReadWrite(Pwr),
    fbdiv_int: mmio.ApbReadWrite(FbdivInt),
    prim: mmio.ApbReadWrite(Prim),
};

/// Returns the register block of PLL instance `which`.
pub inline fn instance(comptime which: Instance) *volatile Registers {
    return @ptrFromInt(switch (which) {
        .sys => address_map.pll_sys_base,
        .usb => address_map.pll_usb_base,
    });
}

comptime {
    const std = @import("std");

    // Field bit positions per the datasheet register definitions.
    std.debug.assert(@bitOffsetOf(Cs, "refdiv") == 0);
    std.debug.assert(@bitOffsetOf(Cs, "bypass") == 8);
    std.debug.assert(@bitOffsetOf(Cs, "lock") == 31);

    std.debug.assert(@bitOffsetOf(Pwr, "pd") == 0);
    std.debug.assert(@bitOffsetOf(Pwr, "dsmpd") == 2);
    std.debug.assert(@bitOffsetOf(Pwr, "postdivpd") == 3);
    std.debug.assert(@bitOffsetOf(Pwr, "vcopd") == 5);

    std.debug.assert(@bitOffsetOf(FbdivInt, "fbdiv_int") == 0);
    std.debug.assert(@bitOffsetOf(Prim, "postdiv2") == 12);
    std.debug.assert(@bitOffsetOf(Prim, "postdiv1") == 16);

    // Reset words: REFDIV 1, everything powered down, post-dividers at 7.
    std.debug.assert(@as(u32, @bitCast(Cs{})) == 0x0000_0001);
    std.debug.assert(@as(u32, @bitCast(Pwr{})) == 0x0000_002d);
    std.debug.assert(@as(u32, @bitCast(FbdivInt{})) == 0x0000_0000);
    std.debug.assert(@as(u32, @bitCast(Prim{})) == 0x0007_7000);

    // The default plan's post-divider words (manual sections 5.2 and 9.1).
    std.debug.assert(@as(u32, @bitCast(Prim{ .postdiv1 = 6, .postdiv2 = 2 })) == 0x0006_2000);
    std.debug.assert(@as(u32, @bitCast(Prim{ .postdiv1 = 5, .postdiv2 = 5 })) == 0x0005_5000);

    // Block layout.
    std.debug.assert(@offsetOf(Registers, "cs") == 0x00);
    std.debug.assert(@offsetOf(Registers, "pwr") == 0x04);
    std.debug.assert(@offsetOf(Registers, "fbdiv_int") == 0x08);
    std.debug.assert(@offsetOf(Registers, "prim") == 0x0c);
    std.debug.assert(@sizeOf(Registers) == 0x10);

    // Instance bases, as worked through in the manual's startup tables.
    std.debug.assert(@intFromPtr(instance(.sys)) == 0x4002_8000);
    std.debug.assert(@intFromPtr(instance(.usb)) == 0x4002_c000);
}
