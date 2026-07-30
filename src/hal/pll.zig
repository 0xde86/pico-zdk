//! Portable phase-locked loop configuration.
//!
//! A PLL multiplies the crystal reference up to a VCO frequency and divides that
//! back down with two series post-dividers. `configFor` searches the dividers at
//! compile time, so an unreachable target frequency is a build error rather than
//! a silently wrong clock:
//!
//!     const zdk = @import("pico_zdk");
//!
//!     zdk.pll.init(.sys, zdk.board.xosc_hz,
//!         comptime zdk.pll.configFor(zdk.board.xosc_hz, 150_000_000));
//!
//! Hardware behavior follows RP2040 datasheet §2.18 and RP2350 datasheet §8.6.
//! Chip-specific register layouts stay in the selected chip package.

const std = @import("std");
const chip = @import("../chip.zig");
const mmio = @import("../chip/mmio.zig");
const resets = @import("resets.zig");

/// Which PLL to drive.
pub const Instance = chip.pll.Instance;

/// Lowest VCO frequency the hardware guarantees, in Hz.
pub const vco_min_hz: u32 = 750_000_000;
/// Highest VCO frequency the hardware guarantees, in Hz.
pub const vco_max_hz: u32 = 1_600_000_000;
/// Smallest usable feedback divider.
pub const fbdiv_min: u32 = 16;
/// Largest usable feedback divider.
pub const fbdiv_max: u32 = 320;
/// Lowest frequency the phase comparator accepts after `REFDIV`, in Hz.
pub const ref_min_hz: u32 = 5_000_000;

/// A complete PLL plan. Every field maps directly onto a hardware register
/// field; `validate` checks the combination against the datasheet limits.
pub const Config = struct {
    /// `CS.REFDIV`: divides the reference before the phase comparator.
    refdiv: u6 = 1,
    /// VCO frequency in Hz. Must land within `vco_min_hz`..`vco_max_hz`.
    vco_hz: u32,
    /// `PRIM.POSTDIV1`: first output divider, 1 to 7. By convention the larger
    /// of the two, because it divides at VCO speed and so saves a little power.
    postdiv1: u3,
    /// `PRIM.POSTDIV2`: second output divider, 1 to 7.
    postdiv2: u3,

    /// The feedback divider this plan implies for a `ref_hz` reference.
    pub fn fbdiv(config: Config, ref_hz: u32) u32 {
        return config.vco_hz / (ref_hz / config.refdiv);
    }

    /// The output frequency this plan produces, in Hz.
    pub fn outputHz(config: Config) u32 {
        return config.vco_hz / (@as(u32, config.postdiv1) * config.postdiv2);
    }

    /// Rejects, at compile time, any plan the hardware cannot run or that would
    /// not produce `vco_hz` exactly from `ref_hz`.
    pub fn validate(comptime config: Config, comptime ref_hz: u32) void {
        comptime {
            if (config.refdiv < 1) @compileError("pll: REFDIV must be at least 1");

            const divided_ref = ref_hz / config.refdiv;
            if (divided_ref * config.refdiv != ref_hz) @compileError(std.fmt.comptimePrint(
                "pll: REFDIV {d} does not divide the {d} Hz reference exactly",
                .{ config.refdiv, ref_hz },
            ));
            if (divided_ref < ref_min_hz) @compileError(std.fmt.comptimePrint(
                "pll: reference after REFDIV is {d} Hz, below the {d} Hz minimum",
                .{ divided_ref, ref_min_hz },
            ));

            if (config.vco_hz < vco_min_hz or config.vco_hz > vco_max_hz) @compileError(std.fmt.comptimePrint(
                "pll: VCO {d} Hz is outside the supported {d}..{d} Hz range",
                .{ config.vco_hz, vco_min_hz, vco_max_hz },
            ));

            const fb = config.fbdiv(ref_hz);
            if (fb * divided_ref != config.vco_hz) @compileError(std.fmt.comptimePrint(
                "pll: VCO {d} Hz is not an integer multiple of the {d} Hz divided reference",
                .{ config.vco_hz, divided_ref },
            ));
            if (fb < fbdiv_min or fb > fbdiv_max) @compileError(std.fmt.comptimePrint(
                "pll: FBDIV {d} is outside the supported {d}..{d} range",
                .{ fb, fbdiv_min, fbdiv_max },
            ));

            if (config.postdiv1 < 1 or config.postdiv2 < 1) @compileError(
                "pll: both post-dividers must be at least 1",
            );
            if (config.postdiv1 < config.postdiv2) @compileError(std.fmt.comptimePrint(
                "pll: POSTDIV1 ({d}) must be at least POSTDIV2 ({d}); the larger divider goes first",
                .{ config.postdiv1, config.postdiv2 },
            ));
        }
    }
};

/// Searches for the plan producing exactly `out_hz` from a `ref_hz` reference.
///
/// Walks the feedback divider from high to low, so the highest achievable VCO
/// wins - a taller VCO divided further down carries less jitter, at some power
/// cost. Post-dividers are visited with `postdiv1 >= postdiv2`, so the search
/// never returns the mirror-image pair. `REFDIV` stays at 1, matching pico-sdk's
/// `check_sys_clock_hz`; a plan needing a divided reference is written out by
/// hand and checked with `Config.validate`.
///
/// An unreachable target frequency is a compile error. The result is exact:
/// this function never returns an approximation.
///
/// Note that "highest VCO" is a rule, not a lookup of pico-sdk's tables. It
/// reproduces their system-PLL plans (1500 MHz for both 125 and 150 MHz), but
/// for 48 MHz it finds 1440 MHz / 6 x 5 where pico-sdk hand-picks 1200 MHz /
/// 5 x 5. `usbConfigFor` keeps the hand-picked plan.
pub fn configFor(comptime ref_hz: u32, comptime out_hz: u32) Config {
    return comptime blk: {
        // The search visits up to 305 feedback dividers times 28 post-divider
        // pairs; the default quota does not cover that.
        @setEvalBranchQuota(500_000);

        var fb = fbdiv_max + 1;
        while (fb > fbdiv_min) {
            fb -= 1;
            const vco: u64 = @as(u64, fb) * ref_hz;
            if (vco < vco_min_hz or vco > vco_max_hz) continue;

            var postdiv1: u32 = 8;
            while (postdiv1 > 1) {
                postdiv1 -= 1;
                var postdiv2 = postdiv1 + 1;
                while (postdiv2 > 1) {
                    postdiv2 -= 1;
                    const divisor = postdiv1 * postdiv2;
                    if (vco % divisor != 0) continue;
                    if (vco / divisor != out_hz) continue;
                    break :blk Config{
                        .refdiv = 1,
                        .vco_hz = @intCast(vco),
                        .postdiv1 = @intCast(postdiv1),
                        .postdiv2 = @intCast(postdiv2),
                    };
                }
            }
        }
        @compileError(std.fmt.comptimePrint(
            "pll: no configuration produces {d} Hz from a {d} Hz reference; nearest achievable are {s}",
            .{ out_hz, ref_hz, nearestAchievable(ref_hz, out_hz) },
        ));
    };
}

/// Returns the PLL_USB plan producing `out_hz` from a `ref_hz` reference.
///
/// For the standard 12 MHz crystal this is pico-sdk 2.3.0's hand-picked
/// 1200 MHz VCO with 5 x 5 post-dividers, so the USB clock this SDK programs
/// matches the reference implementation bit for bit. `configFor`'s highest-VCO
/// rule would return the equally valid 1440 MHz / 6 x 5 instead, and the USB
/// clock is not a place to diverge from the vendor for no reason.
///
/// Any other crystal falls through to the general search.
pub fn usbConfigFor(comptime ref_hz: u32, comptime out_hz: u32) Config {
    return comptime blk: {
        if (ref_hz == 12_000_000 and out_hz == 48_000_000) break :blk Config{
            .refdiv = 1,
            .vco_hz = 1_200_000_000,
            .postdiv1 = 5,
            .postdiv2 = 5,
        };
        break :blk configFor(ref_hz, out_hz);
    };
}

/// Programs and locks PLL instance `which`, then opens its output.
///
/// Preserves an exact live configuration; otherwise runs the datasheet's
/// sequence: pulse and release the PLL's RESETS block, write the reference and
/// feedback dividers, power up the loop, wait for lock, and only then program
/// the post-dividers and power up the output. Before reprogramming, startup
/// parks its glitchless consumers on safe sources; it switches them back only
/// after the PLL is stable.
///
/// **The lock wait is unbounded**, like the crystal wait: `error.Timeout` needs
/// M4's timer. Lock normally arrives well inside a millisecond.
///
/// A PLL already running this exact plan is preserved. This check is required
/// for debugger and bootloader hand-offs: resetting an otherwise-correct
/// PLL_USB would interrupt the 48 MHz clock of an active USB controller even
/// though the startup reset masks deliberately left that controller alone.
/// There is no power-down counterpart until M30 wants one.
pub fn init(
    comptime which: Instance,
    comptime ref_hz: u32,
    comptime config: Config,
) void {
    comptime config.validate(ref_hz);

    const registers = chip.pll.instance(which);
    const block = comptime resetBlock(which);

    // pico-sdk performs the same early return. It is a safety property, not
    // merely an optimization: live consumers must not lose a correct PLL.
    if (isConfigured(registers, ref_hz, config)) return;

    // A reset pulse, not just a release: the PLL may carry state from whatever
    // ran before `main` (warm reset, bootloader hand-off). This is safe only
    // after the live-configuration check above has ruled out a PLL we must
    // preserve.
    resets.resetMask(comptime chip.mask(block));
    resets.releaseMaskAndWait(comptime chip.mask(block));

    registers.cs.write(.{ .refdiv = config.refdiv });
    registers.fbdiv_int.write(.{ .fbdiv_int = comptime @intCast(config.fbdiv(ref_hz)) });

    // Power up the loop, leaving the post-dividers down so no consumer can see
    // the VCO hunting during lock acquisition.
    registers.pwr.clearBits(comptime mmio.fieldsMask(chip.pll.Pwr, &.{ .pd, .vcopd }));
    while (!registers.cs.read().lock) {}

    registers.prim.write(.{ .postdiv1 = config.postdiv1, .postdiv2 = config.postdiv2 });
    registers.pwr.clearBits(comptime mmio.fieldMask(chip.pll.Pwr, .postdivpd));
}

/// Whether `registers` already provide the requested live PLL output.
///
/// Kept as a separate inline safety check so every future PLL initialization
/// path must make the preserve-or-reset decision explicitly before pulsing the
/// reset block.
inline fn isConfigured(
    registers: *const volatile chip.pll.Registers,
    comptime ref_hz: u32,
    comptime config: Config,
) bool {
    return configurationIsLive(
        registers.cs.read(),
        registers.pwr.read(),
        registers.fbdiv_int.read(),
        registers.prim.read(),
        ref_hz,
        config,
    );
}

/// Pure register-value half of `isConfigured`, split out so the safety decision
/// is host-testable without dereferencing MMIO.
inline fn configurationIsLive(
    cs: chip.pll.Cs,
    pwr: chip.pll.Pwr,
    fbdiv_int: chip.pll.FbdivInt,
    prim: chip.pll.Prim,
    comptime ref_hz: u32,
    comptime config: Config,
) bool {
    return cs.lock and
        !cs.bypass and
        cs.refdiv == config.refdiv and
        fbdiv_int.fbdiv_int == config.fbdiv(ref_hz) and
        prim.postdiv1 == config.postdiv1 and
        prim.postdiv2 == config.postdiv2 and
        !pwr.pd and
        !pwr.vcopd and
        !pwr.postdivpd and
        pwr.dsmpd;
}

/// The RESETS block gating `which`. Both chips name these bits identically even
/// though the positions differ.
fn resetBlock(comptime which: Instance) chip.resets.Block {
    return switch (which) {
        .sys => .pll_sys,
        .usb => .pll_usb,
    };
}

/// Renders the achievable frequencies nearest `out_hz`, for the `configFor`
/// error message. Comptime-only.
fn nearestAchievable(comptime ref_hz: u32, comptime out_hz: u32) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(500_000);
        var below: u64 = 0;
        var above: u64 = 0;
        var fb = fbdiv_min;
        while (fb <= fbdiv_max) : (fb += 1) {
            const vco: u64 = @as(u64, fb) * ref_hz;
            if (vco < vco_min_hz or vco > vco_max_hz) continue;
            var postdiv1: u32 = 1;
            while (postdiv1 <= 7) : (postdiv1 += 1) {
                var postdiv2: u32 = 1;
                while (postdiv2 <= postdiv1) : (postdiv2 += 1) {
                    const divisor = postdiv1 * postdiv2;
                    if (vco % divisor != 0) continue;
                    const candidate = vco / divisor;
                    if (candidate <= out_hz and candidate > below) below = candidate;
                    if (candidate >= out_hz and (above == 0 or candidate < above)) above = candidate;
                }
            }
        }
        break :blk std.fmt.comptimePrint("{d} Hz and {d} Hz", .{ below, above });
    };
}

comptime {
    // The three plans the milestone actually programs, derived rather than
    // typed: the system PLLs fall out of the search, USB keeps pico-sdk's pick.
    const sys_2040 = configFor(12_000_000, 125_000_000);
    std.debug.assert(sys_2040.vco_hz == 1_500_000_000);
    std.debug.assert(sys_2040.postdiv1 == 6 and sys_2040.postdiv2 == 2);
    std.debug.assert(sys_2040.fbdiv(12_000_000) == 125);

    const sys_2350 = configFor(12_000_000, 150_000_000);
    std.debug.assert(sys_2350.vco_hz == 1_500_000_000);
    std.debug.assert(sys_2350.postdiv1 == 5 and sys_2350.postdiv2 == 2);
    std.debug.assert(sys_2350.fbdiv(12_000_000) == 125);

    const usb = usbConfigFor(12_000_000, 48_000_000);
    std.debug.assert(usb.vco_hz == 1_200_000_000);
    std.debug.assert(usb.postdiv1 == 5 and usb.postdiv2 == 5);
    std.debug.assert(usb.fbdiv(12_000_000) == 100);
}

test "the search reproduces the reference system-PLL plans" {
    const cases = [_]struct { out_hz: u32, vco_hz: u32, postdiv1: u3, postdiv2: u3, fbdiv: u32 }{
        // RP2040 at spec speed.
        .{ .out_hz = 125_000_000, .vco_hz = 1_500_000_000, .postdiv1 = 6, .postdiv2 = 2, .fbdiv = 125 },
        // RP2350 at spec speed.
        .{ .out_hz = 150_000_000, .vco_hz = 1_500_000_000, .postdiv1 = 5, .postdiv2 = 2, .fbdiv = 125 },
    };

    inline for (cases) |case| {
        const config = comptime configFor(12_000_000, case.out_hz);
        try std.testing.expectEqual(case.vco_hz, config.vco_hz);
        try std.testing.expectEqual(case.postdiv1, config.postdiv1);
        try std.testing.expectEqual(case.postdiv2, config.postdiv2);
        try std.testing.expectEqual(case.fbdiv, config.fbdiv(12_000_000));
        try std.testing.expectEqual(case.out_hz, config.outputHz());
    }
}

test "the USB plan keeps pico-sdk's hand-picked dividers" {
    const hand_picked = comptime usbConfigFor(12_000_000, 48_000_000);
    try std.testing.expectEqual(@as(u32, 1_200_000_000), hand_picked.vco_hz);
    try std.testing.expectEqual(@as(u3, 5), hand_picked.postdiv1);
    try std.testing.expectEqual(@as(u3, 5), hand_picked.postdiv2);
    try std.testing.expectEqual(@as(u32, 100), hand_picked.fbdiv(12_000_000));

    // The general search would answer differently here, because a taller VCO
    // also reaches 48 MHz exactly. Both are valid; this pins which one is used
    // where, so a future change to either cannot pass unnoticed.
    const searched = comptime configFor(12_000_000, 48_000_000);
    try std.testing.expectEqual(@as(u32, 1_440_000_000), searched.vco_hz);
    try std.testing.expectEqual(@as(u3, 6), searched.postdiv1);
    try std.testing.expectEqual(@as(u3, 5), searched.postdiv2);
    try std.testing.expectEqual(@as(u32, 48_000_000), searched.outputHz());
}

test "a matching live PLL is preserved but incomplete or different state is not" {
    const config: Config = .{
        .vco_hz = 1_500_000_000,
        .postdiv1 = 6,
        .postdiv2 = 2,
    };
    const live_power = chip.pll.Pwr{
        .pd = false,
        .vcopd = false,
        .postdivpd = false,
    };
    const feedback = chip.pll.FbdivInt{ .fbdiv_int = 125 };
    const postdividers = chip.pll.Prim{ .postdiv1 = 6, .postdiv2 = 2 };

    // This is the debugger/bootloader hand-off case that must not receive a
    // reset pulse: the exact requested clock is already live.
    try std.testing.expect(configurationIsLive(
        .{ .refdiv = 1, .lock = true },
        live_power,
        feedback,
        postdividers,
        12_000_000,
        config,
    ));

    // LOCK alone is insufficient: mismatched dividers would silently report
    // the wrong rate, and a powered-down output cannot serve consumers.
    try std.testing.expect(!configurationIsLive(
        .{ .refdiv = 1, .lock = false },
        live_power,
        feedback,
        postdividers,
        12_000_000,
        config,
    ));
    try std.testing.expect(!configurationIsLive(
        .{ .refdiv = 1, .lock = true },
        live_power,
        .{ .fbdiv_int = 124 },
        postdividers,
        12_000_000,
        config,
    ));
    try std.testing.expect(!configurationIsLive(
        .{ .refdiv = 1, .lock = true },
        .{},
        feedback,
        postdividers,
        12_000_000,
        config,
    ));
    try std.testing.expect(!configurationIsLive(
        .{ .refdiv = 1, .bypass = true, .lock = true },
        live_power,
        feedback,
        postdividers,
        12_000_000,
        config,
    ));
    try std.testing.expect(!configurationIsLive(
        .{ .refdiv = 1, .lock = true },
        .{ .pd = false, .dsmpd = false, .postdivpd = false, .vcopd = false },
        feedback,
        postdividers,
        12_000_000,
        config,
    ));
}

test "every searched plan satisfies the hardware constraints" {
    // A sweep over targets the search can reach from a 12 MHz crystal. Each
    // result must be exact and inside every datasheet limit - the properties
    // `validate` enforces at compile time, checked here as data.
    const targets = [_]u32{
        24_000_000,  25_000_000,  48_000_000,  50_000_000,
        100_000_000, 125_000_000, 133_000_000, 150_000_000,
        200_000_000, 250_000_000, 300_000_000,
    };

    inline for (targets) |target| {
        const config = comptime configFor(12_000_000, target);
        try std.testing.expectEqual(target, config.outputHz());
        try std.testing.expect(config.vco_hz >= vco_min_hz and config.vco_hz <= vco_max_hz);

        const fb = config.fbdiv(12_000_000);
        try std.testing.expect(fb >= fbdiv_min and fb <= fbdiv_max);
        try std.testing.expectEqual(config.vco_hz, fb * 12_000_000 / config.refdiv);

        try std.testing.expect(config.postdiv1 >= 1 and config.postdiv2 >= 1);
        // The power convention: the larger divider runs first, at VCO speed.
        try std.testing.expect(config.postdiv1 >= config.postdiv2);
    }
}

test "hand-written plans reproduce their register-visible dividers" {
    // The exact plans the startup sequence programs, checked against the
    // register words the manual's tables list.
    const sys_2040: Config = .{ .vco_hz = 1_500_000_000, .postdiv1 = 6, .postdiv2 = 2 };
    try std.testing.expectEqual(@as(u32, 125_000_000), sys_2040.outputHz());
    try std.testing.expectEqual(@as(u32, 125), sys_2040.fbdiv(12_000_000));

    const sys_2350: Config = .{ .vco_hz = 1_500_000_000, .postdiv1 = 5, .postdiv2 = 2 };
    try std.testing.expectEqual(@as(u32, 150_000_000), sys_2350.outputHz());

    const usb: Config = .{ .vco_hz = 1_200_000_000, .postdiv1 = 5, .postdiv2 = 5 };
    try std.testing.expectEqual(@as(u32, 48_000_000), usb.outputHz());
    try std.testing.expectEqual(@as(u32, 100), usb.fbdiv(12_000_000));

    // A divided reference still has to land on the same VCO.
    const divided: Config = .{ .refdiv = 2, .vco_hz = 1_500_000_000, .postdiv1 = 6, .postdiv2 = 2 };
    try std.testing.expectEqual(@as(u32, 250), divided.fbdiv(12_000_000));
}
