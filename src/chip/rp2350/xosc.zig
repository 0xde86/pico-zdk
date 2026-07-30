//! RP2350 crystal oscillator (XOSC).
//!
//! The block turns the board's quartz crystal into a clock. Its control fields
//! accept only magic values, because stopping the crystal while `clk_sys` runs
//! from it kills the chip until the next reset.
//!
//! Source: [RP2350 datasheet §8.2, "Crystal Oscillator (XOSC)"](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// `CTRL.FREQ_RANGE`: the crystal frequency band the oscillator is tuned for.
///
/// RP2350 implements four frequency bands.
///
/// Non-exhaustive because the field is a full 12 bits and reads back whatever
/// was written.
pub const FreqRange = enum(u12) {
    /// 1-15 MHz. The band both supported boards' 12 MHz crystals use.
    mhz_1_15 = 0xaa0,
    /// 10-30 MHz.
    mhz_10_30 = 0xaa1,
    /// 25-60 MHz.
    mhz_25_60 = 0xaa2,
    /// 40-100 MHz.
    mhz_40_100 = 0xaa3,
    _,
};

/// `CTRL.ENABLE`: magic-value oscillator enable.
///
/// Non-exhaustive: the field reads back its written value, and neither magic
/// value is the power-on state.
pub const Enable = enum(u12) {
    /// Stop the oscillator ("die").
    disable = 0xd1e,
    /// Run the oscillator.
    enable = 0xfab,
    _,
};

/// `CTRL`: frequency range and enable, both magic-value fields.
///
/// Neither field has a default: writing this register is always a deliberate
/// statement of both magic values. A write carrying anything else sets
/// `Status.badwrite` instead of taking effect.
pub const Ctrl = packed struct(u32) {
    /// `FREQ_RANGE`: crystal frequency band.
    freq_range: FreqRange,
    /// `ENABLE`: oscillator enable.
    enable: Enable,
    _reserved0: u8 = 0,
};

/// `STATUS`: oscillator state. `badwrite` is write-1-to-clear, which is why the
/// register is modeled read-write rather than read-only; every other field
/// ignores writes.
pub const Status = packed struct(u32) {
    /// `FREQ_RANGE`: the band the oscillator is actually using.
    freq_range: u2 = 0,
    _reserved0: u10 = 0,
    /// `ENABLED`: the oscillator has been asked to run. This reports the
    /// request, not usability - wait on `stable` instead.
    enabled: bool = false,
    _reserved1: u11 = 0,
    /// `BADWRITE`: sticky flag recording a write to `CTRL`, `DORMANT`, or
    /// `STARTUP` that did not carry a valid magic value. Write 1 to clear.
    badwrite: bool = false,
    _reserved2: u6 = 0,
    /// `STABLE`: the startup delay expired and the amplitude check passed, so
    /// the oscillator output is usable.
    stable: bool = false,
};

/// `DORMANT`: magic-value pause control. Modeled as data; the dormant and sleep
/// modes that drive it arrive with M30.
pub const Dormant = packed struct(u32) {
    /// The requested state. Only the two magic values take effect.
    magic: Magic = .wake,

    /// `DORMANT` magic values, spelled in ASCII by the hardware designers.
    pub const Magic = enum(u32) {
        /// "coma": stop the oscillator until an interrupt wakes it.
        dormant = 0x636f6d61,
        /// "wake": run normally.
        wake = 0x77616b65,
        _,
    };
};

/// `STARTUP`: how long to wait before declaring the crystal stable.
pub const Startup = packed struct(u32) {
    /// `DELAY`: startup delay in units of 256 crystal cycles.
    delay: u14 = 0,
    _reserved0: u6 = 0,
    /// `X4`: multiply the delay by four, for crystals that start very slowly.
    x4: bool = false,
    _reserved1: u11 = 0,
};

/// `COUNT`: a sixteen-bit down-counter clocked by the crystal, for software
/// timing loops before any other clock is trustworthy.
pub const Count = packed struct(u32) {
    /// Remaining crystal cycles. Counts down to zero and stops.
    count: u16 = 0,
    _reserved0: u16 = 0,
};

/// XOSC register block.
///
/// `COUNT` follows `STARTUP` directly at `0x10`.
pub const Registers = extern struct {
    ctrl: mmio.ApbReadWrite(Ctrl),
    status: mmio.ReadWrite(Status),
    dormant: mmio.ReadWrite(Dormant),
    startup: mmio.ApbReadWrite(Startup),
    count: mmio.ReadWrite(Count),
};

/// The XOSC peripheral at its RP2350 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.xosc_base);

comptime {
    const std = @import("std");

    // Field bit positions per the datasheet register definitions.
    std.debug.assert(@bitOffsetOf(Ctrl, "freq_range") == 0);
    std.debug.assert(@bitOffsetOf(Ctrl, "enable") == 12);

    std.debug.assert(@bitOffsetOf(Status, "freq_range") == 0);
    std.debug.assert(@bitOffsetOf(Status, "enabled") == 12);
    std.debug.assert(@bitOffsetOf(Status, "badwrite") == 24);
    std.debug.assert(@bitOffsetOf(Status, "stable") == 31);

    std.debug.assert(@bitOffsetOf(Startup, "delay") == 0);
    std.debug.assert(@bitOffsetOf(Startup, "x4") == 20);

    std.debug.assert(@bitSizeOf(@FieldType(Count, "count")) == 16);

    // The magic values, which are the whole point of this block's API.
    std.debug.assert(@intFromEnum(FreqRange.mhz_1_15) == 0xaa0);
    std.debug.assert(@intFromEnum(FreqRange.mhz_10_30) == 0xaa1);
    std.debug.assert(@intFromEnum(FreqRange.mhz_25_60) == 0xaa2);
    std.debug.assert(@intFromEnum(FreqRange.mhz_40_100) == 0xaa3);
    std.debug.assert(@intFromEnum(Enable.enable) == 0xfab);
    std.debug.assert(@intFromEnum(Enable.disable) == 0xd1e);
    std.debug.assert(@intFromEnum(Dormant.Magic.dormant) == 0x636f6d61);
    std.debug.assert(@intFromEnum(Dormant.Magic.wake) == 0x77616b65);

    // The enable word the startup sequence writes through the SET alias.
    std.debug.assert(@as(u32, @bitCast(Ctrl{
        .freq_range = @enumFromInt(0),
        .enable = .enable,
    })) == 0x00fa_b000);

    // Block layout.
    std.debug.assert(@offsetOf(Registers, "ctrl") == 0x00);
    std.debug.assert(@offsetOf(Registers, "status") == 0x04);
    std.debug.assert(@offsetOf(Registers, "dormant") == 0x08);
    std.debug.assert(@offsetOf(Registers, "startup") == 0x0c);
    std.debug.assert(@offsetOf(Registers, "count") == 0x10);
    std.debug.assert(@sizeOf(Registers) == 0x14);
}
