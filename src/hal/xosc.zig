//! Portable crystal-oscillator startup.
//!
//! The crystal takes thousands of cycles to build up a usable amplitude, so the
//! hardware counts a programmable startup delay and then reports `STABLE`:
//!
//!     const zdk = @import("pico_zdk");
//!
//!     zdk.xosc.startBlocking(zdk.board.xosc_hz, .{});
//!
//! Hardware behavior follows RP2040 datasheet §2.16 and RP2350 datasheet §8.2.
//! Chip-specific register layouts and the magic values stay in the selected chip
//! package.

const std = @import("std");
const chip = @import("../chip.zig");
const mmio = @import("../chip/mmio.zig");

/// Options for `startBlocking`.
pub const Options = struct {
    /// Multiplies the computed startup delay. Boards whose crystal circuit
    /// starts slowly raise this; both supported boards use 1. Mirrors pico-sdk's
    /// `PICO_XOSC_STARTUP_DELAY_MULTIPLIER`.
    startup_delay_multiplier: u16 = 1,
};

/// Starts the crystal oscillator and blocks until the hardware reports it
/// usable.
///
/// Writes the frequency band, programs the startup delay computed from
/// `xosc_hz`, enables the oscillator through the `CTRL` SET alias, then spins on
/// `STATUS.STABLE`. Polling `STABLE` rather than `ENABLED` matters: `ENABLED`
/// only reports that the oscillator was asked to run.
///
/// A crystal frequency the selected chip cannot accept, or a startup delay that
/// does not fit the hardware field, is a compile error.
///
/// **The wait is unbounded.** A missing or faulty crystal hangs boot here, by
/// design: the timebase a timeout needs is what this milestone is building, and
/// `error.Timeout` arrives with M4's timer. Failing loudly beats limping.
pub fn startBlocking(comptime xosc_hz: u32, comptime options: Options) void {
    const registers = chip.xosc.registers;

    registers.ctrl.write(.{
        .freq_range = comptime freqRange(xosc_hz),
        // Zero is not one of `ENABLE`'s magic values, so writing it commands
        // nothing and leaves a running oscillator running. Writing the *disable*
        // magic here would stop the crystal on any warm re-entry - while
        // `clk_sys` may still be running from it.
        .enable = @enumFromInt(0),
    });
    registers.startup.write(.{
        .delay = comptime startupDelay(xosc_hz, options.startup_delay_multiplier),
    });
    registers.ctrl.setBits(comptime enableBits());

    while (!registers.status.read().stable) {}
}

/// Returns the startup delay for a `xosc_hz` crystal, in units of 256 crystal
/// cycles, targeting roughly one millisecond.
///
/// The formula is pico-sdk's: at 12 MHz it yields 47, and 47 * 256 = 12032
/// cycles is 1.003 ms. A delay too large for the hardware's 14-bit field is a
/// compile error.
pub fn startupDelay(comptime xosc_hz: u32, comptime multiplier: u16) u14 {
    return comptime blk: {
        const delay = ((xosc_hz / 1000) + 128) / 256 * multiplier;
        const Delay = @FieldType(chip.xosc.Startup, "delay");
        if (delay == 0) @compileError(std.fmt.comptimePrint(
            "xosc: a {d} Hz crystal yields a zero startup delay; the oscillator would be declared stable immediately",
            .{xosc_hz},
        ));
        if (delay > std.math.maxInt(Delay)) @compileError(std.fmt.comptimePrint(
            "xosc: startup delay {d} does not fit STARTUP.DELAY (max {d}); lower the multiplier or use the X4 bit",
            .{ delay, std.math.maxInt(Delay) },
        ));
        break :blk delay;
    };
}

/// Returns the frequency band covering `xosc_hz` on the selected chip.
///
/// RP2040 implements only the 1-15 MHz band; RP2350 adds three more. A crystal
/// outside every implemented band is a compile error.
fn freqRange(comptime xosc_hz: u32) chip.xosc.FreqRange {
    return comptime frequencyBand(xosc_hz) orelse @compileError(std.fmt.comptimePrint(
        "xosc: no frequency band on this chip covers a {d} Hz crystal",
        .{xosc_hz},
    ));
}

/// Returns the exact hardware band containing `xosc_hz`, if one exists.
///
/// This safety check compares in Hz. The earlier integer-MHz comparison rounded
/// frequencies down, incorrectly placing values just above 15, 30, 60, or
/// 100 MHz in a band whose electrical limit they exceeded.
inline fn frequencyBand(comptime xosc_hz: u32) ?chip.xosc.FreqRange {
    const FreqRange = chip.xosc.FreqRange;
    if (xosc_hz >= 1_000_000 and xosc_hz <= 15_000_000) return .mhz_1_15;
    if (@hasField(FreqRange, "mhz_10_30")) {
        if (xosc_hz >= 10_000_000 and xosc_hz <= 30_000_000) return .mhz_10_30;
        if (xosc_hz >= 25_000_000 and xosc_hz <= 60_000_000) return .mhz_25_60;
        if (xosc_hz >= 40_000_000 and xosc_hz <= 100_000_000) return .mhz_40_100;
    }
    return null;
}

/// Returns the `CTRL` word that sets only the enable magic, for the SET alias.
///
/// The frequency range is already programmed at this point, and the SET alias
/// ORs bits in, so writing only the enable field leaves the band untouched.
fn enableBits() u32 {
    return comptime blk: {
        const Ctrl = chip.xosc.Ctrl;
        break :blk @as(u32, @bitCast(Ctrl{
            .freq_range = @enumFromInt(0),
            .enable = .enable,
        })) & mmio.fieldMask(Ctrl, .enable);
    };
}

comptime {
    // The delay both supported boards program, worked through in the manual.
    std.debug.assert(startupDelay(12_000_000, 1) == 47);
    std.debug.assert(startupDelay(12_000_000, 4) == 188);

    // The word the SET alias receives (manual startup tables, step 4).
    std.debug.assert(enableBits() == 0x00fa_b000);

    // Both boards' crystals land in the band every chip implements.
    std.debug.assert(freqRange(12_000_000) == .mhz_1_15);

    // The range write carries no enable magic, so it can never stop a crystal
    // that something is already running from.
    std.debug.assert(@as(u32, @bitCast(chip.xosc.Ctrl{
        .freq_range = freqRange(12_000_000),
        .enable = @enumFromInt(0),
    })) == 0x0000_0aa0);
}

test "startup delay tracks the crystal frequency and the multiplier" {
    // The delay counts units of 256 crystal cycles and targets about 1 ms, so
    // it scales with the crystal frequency.
    try std.testing.expectEqual(@as(u14, 47), startupDelay(12_000_000, 1));
    try std.testing.expectEqual(@as(u14, 4), startupDelay(1_000_000, 1));
    try std.testing.expectEqual(@as(u14, 94), startupDelay(12_000_000, 2));

    // 47 * 256 crystal cycles is a hair over one millisecond at 12 MHz.
    const cycles: u32 = @as(u32, startupDelay(12_000_000, 1)) * 256;
    try std.testing.expectEqual(@as(u32, 12_032), cycles);
    try std.testing.expect(cycles * 1_000 / 12_000_000 >= 1);
}

test "frequency bands use exact Hz boundaries without rounding down" {
    try std.testing.expect(frequencyBand(999_999) == null);
    try std.testing.expect(frequencyBand(1_000_000).? == .mhz_1_15);
    try std.testing.expect(frequencyBand(15_000_000).? == .mhz_1_15);

    if (@hasField(chip.xosc.FreqRange, "mhz_10_30")) {
        // Each value is one hertz above the preceding band's upper limit. The
        // old MHz-flooring implementation put all three in the wrong band.
        try std.testing.expect(frequencyBand(15_000_001).? == .mhz_10_30);
        try std.testing.expect(frequencyBand(30_000_001).? == .mhz_25_60);
        try std.testing.expect(frequencyBand(60_000_001).? == .mhz_40_100);
        try std.testing.expect(frequencyBand(100_000_001) == null);
    } else {
        try std.testing.expect(frequencyBand(15_000_001) == null);
    }
}
