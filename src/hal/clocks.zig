//! Portable clock generator configuration, and the startup plan that takes both
//! chips from their power-on ring oscillator to spec speed.
//!
//!     const zdk = @import("pico_zdk");
//!
//!     // What the runtime does before `main` under the default startup policy.
//!     zdk.clocks.applySpecDefaults(zdk.board.xosc_hz);
//!
//!     // What a firmware asks afterwards.
//!     const baud_source = zdk.clocks.hz(.peri);
//!
//! Reconfiguring a live clock is a sequencing problem, not a register write. The
//! order below is expressed as a list of `Step` values that host tests assert
//! directly - the sequence *is* the correctness property - and that `configure`
//! replays as MMIO on target.
//!
//! Hardware behavior follows RP2040 datasheet §2.15 and RP2350 datasheet §8.1.
//! Chip-specific register layouts, source encodings, and the divider
//! fixed-point format stay in the selected chip package.

const std = @import("std");
const config = @import("config");
const chip = @import("../chip.zig");
const mmio = @import("../chip/mmio.zig");
const pll = @import("pll.zig");
const ticks = @import("ticks.zig");
const xosc = @import("xosc.zig");

/// The clock generators the selected chip instantiates.
///
/// Member names are portable; the ordinals are chip-owned register indices.
/// `clk_rtc` exists only on RP2040 and `clk_hstx` only on RP2350, so naming the
/// wrong one is a compile error rather than a wrong register.
pub const Generator = chip.clocks.Generator;

/// The clock a GPOUT generator can observe.
///
/// Encodings are chip-owned - the two chips renumber everything past value 3 -
/// and the member names are the portable contract. Selecting a source the chip
/// does not have is a compile error.
pub const GpoutSource = @FieldType(chip.clocks.GpoutCtrl, "auxsrc");

/// The four clock outputs that can be routed to a package pin.
pub const Gpout = enum { gpout0, gpout1, gpout2, gpout3 };

/// One action of the safe-switching sequence.
///
/// The steps carry encoded register values rather than typed fields, so a plan
/// is plain comparable data that a host test can assert without any hardware.
pub const Step = union(enum) {
    /// Write `DIV`, but only if the new word is larger than the one currently
    /// programmed. A growing divisor must land *before* the source switch or the
    /// domain briefly runs too fast.
    div_if_larger: u32,
    /// Clear `ENABLE` on an aux-gated generator.
    disable,
    /// Wait for the cleared `ENABLE` to propagate through the divider: at least
    /// three cycles of the generator's current output.
    await_disable,
    /// Write the glitchless `SRC` field with this encoded value.
    src: u32,
    /// Spin until `SELECTED` reads this one-hot mask. The glitchless handover
    /// takes several cycles of both clocks; until then the old source still
    /// drives the domain.
    poll_selected: u32,
    /// Update the selected `CTRL` bits - `AUXSRC`, plus `PHASE` where the
    /// generator has one.
    ctrl: Masked,
    /// Set `ENABLE` on an aux-gated generator.
    enable,
    /// Write the requested `DIV` word.
    div: u32,

    /// A register update restricted to the bits `mask` selects.
    pub const Masked = struct { value: u32, mask: u32 };
};

/// What a reconfiguration asks for, in already-encoded register values.
pub const Change = struct {
    /// Encoded glitchless `SRC` value, or null for an aux-only generator.
    src: ?u32 = null,
    /// The `CTRL` bits to update.
    ctrl: Step.Masked,
    /// Encoded `DIV` word, or null for a generator with no divider.
    div: ?u32 = null,
    /// Whether the generator has an `ENABLE` gate.
    gated: bool,
};

/// The `SRC` encoding that selects the auxiliary mux, on both glitchless
/// generators and both chips. A switch bound for this value has to leave the aux
/// path first, so that changing `AUXSRC` cannot glitch a live clock.
pub const glitchless_aux_src: u32 = 1;

/// Returns the ordered steps that carry out `change`.
///
/// The ordering encodes three hazards, in this order:
///
///   1. **Momentary overspeed.** Switching to a faster source and only then
///      raising the divisor would briefly run the domain too fast, so a growing
///      divisor is written first and a shrinking one last.
///   2. **Glitching a live mux.** A glitchless generator moves off the aux path
///      before `AUXSRC` is touched; an aux-only generator is cleanly disabled
///      and given time to stop.
///   3. **Trusting `SELECTED` too early.** Every glitchless write is followed by
///      a poll for the bit that was asked for.
pub fn plan(comptime change: Change) []const Step {
    comptime {
        @setEvalBranchQuota(10_000);
        var steps: []const Step = &.{};

        if (change.div) |word| steps = steps ++ [_]Step{.{ .div_if_larger = word }};

        if (change.src) |value| {
            // Hazard 2, glitchless half: park on source 0 before the aux mux
            // moves under a running clock.
            if (value == glitchless_aux_src) {
                steps = steps ++ [_]Step{ .{ .src = 0 }, .{ .poll_selected = 1 } };
            }
        } else if (change.gated) {
            // Hazard 2, aux-only half: stop the clock and let it settle.
            steps = steps ++ [_]Step{ .disable, .await_disable };
        }

        steps = steps ++ [_]Step{.{ .ctrl = change.ctrl }};

        if (change.src) |value| {
            steps = steps ++ [_]Step{
                .{ .src = value },
                .{ .poll_selected = @as(u32, 1) << @intCast(value) },
            };
        }

        if (change.gated) steps = steps ++ [_]Step{.enable};
        if (change.div) |word| steps = steps ++ [_]Step{.{ .div = word }};

        return steps;
    }
}

/// Frequency bookkeeping: what this HAL last configured each generator to, in
/// Hz. Zero means "never configured here".
///
/// Plain per-generator storage, written only by the configure paths. It is
/// single-core in M3 by construction - the runtime brings clocks up before core
/// 1 exists. M13 guards it across cores; M30 turns updates into transactions
/// with pre- and post-change notifications, which is why no driver may cache a
/// rate indefinitely without registering for reclocking.
var frequencies: [generator_count]u32 = @splat(0);

const generator_count = @typeInfo(Generator).@"enum".fields.len;

/// Returns the frequency in Hz this HAL last configured for `gen`, or 0 if it
/// never has.
///
/// This is bookkeeping, not measurement: it reports what was programmed, not
/// what the pin is doing. M6's frequency counter measures.
pub fn hz(gen: Generator) u32 {
    return frequencies[@intFromEnum(gen)];
}

/// Brings the whole clock tree to datasheet spec speed from a `xosc_hz` crystal,
/// and starts the 1 microsecond tick domains.
///
/// This is the clock half of the runtime's default startup, in the reference
/// implementation's order: disable resus, start the crystal, park both
/// glitchless generators off their auxiliary muxes, lock both PLLs, switch the
/// generators over, and only then start ticks - so the very first tick ever
/// generated is already crystal-accurate.
///
/// Resulting tree: `clk_ref` at the crystal frequency, `clk_sys` at the chip's
/// spec speed, `clk_peri` following `clk_sys`, `clk_usb` and `clk_adc` at
/// 48 MHz. `clk_rtc` (RP2040) and `clk_hstx` (RP2350) are deliberately left at
/// reset; M15 and M29 own them.
///
/// **Contains unbounded waits** - crystal stable, PLL lock, mux handover - so a
/// board with no working crystal hangs here. The runtime calls this before
/// `main`; firmware that opted out of the default startup may call it itself.
pub fn applySpecDefaults(comptime xosc_hz: u32) void {
    // The PLL divider search and the per-generator plans are all resolved here,
    // at compile time; the default quota does not cover that much work.
    @setEvalBranchQuota(500_000);

    const sys_hz = chip.sys_clk_hz;
    const usb_hz = chip.usb_clk_hz;

    // Kill any resus configuration left by earlier software before touching the
    // clock it watches.
    chip.clocks.registers.resus_ctrl.write(.{ .timeout = 0 });

    xosc.startBlocking(xosc_hz, .{});

    // Before the PLLs are touched, both glitchless generators must be off their
    // auxiliary muxes. On RP2350 this is the real handover - the chip boots with
    // `clk_sys` on the aux mux, fed by the ring oscillator - and on RP2040 it is
    // harmless insurance.
    parkOnSourceZero(.sys);
    parkOnSourceZero(.ref);

    pll.init(.sys, xosc_hz, comptime pll.configFor(xosc_hz, sys_hz));
    pll.init(.usb, xosc_hz, comptime pll.usbConfigFor(xosc_hz, usb_hz));

    // Generators, in the reference implementation's order. `clk_ref` first
    // because `clk_sys` can fall back to it, and `clk_peri` last because it
    // follows `clk_sys`.
    configureGlitchless(.ref, .xosc, .pll_usb, xosc_hz, xosc_hz);
    configureGlitchless(.sys, .aux, .pll_sys, sys_hz, sys_hz);
    configureAux(.usb, .pll_usb, usb_hz, usb_hz, 0);
    configureAux(.adc, .pll_usb, usb_hz, usb_hz, 0);
    configureAux(.peri, .clk_sys, sys_hz, sys_hz, 0);

    // `clk_ref` now runs at the crystal frequency, so the tick divisor follows
    // from it directly.
    ticks.startAll(xosc_hz);
}

/// Routes a clock onto GPOUT generator `which` and enables it.
///
/// The generator's pin still has to be muxed separately, because the pin is the
/// application's to own:
///
///     zdk.gpio.setFunction(21, .gpclk);
///     zdk.clocks.gpoutEnable(.gpout0, .{ .source = .clk_sys, .div_int = 1000 });
///
/// A source the chip does not have, a divisor that does not fit the chip's
/// divider fields, or a fractional part on a chip whose GPOUT divider has none,
/// is a compile error. Divide-by-zero is not expressible: the hardware reads a
/// zero integer field as the maximum ratio, and `div_int` of 0 is rejected.
pub fn gpoutEnable(comptime which: Gpout, comptime options: Options) void {
    @setEvalBranchQuota(10_000);

    const gen = comptime @field(Generator, @tagName(which));
    const Ctrl = CtrlOf(gen);
    const div = comptime gpoutDivWord(gen, options);

    const change = comptime Change{
        .ctrl = .{
            .value = @bitCast(Ctrl{ .auxsrc = options.source, .phase = options.phase }),
            .mask = mmio.fieldsMask(Ctrl, &.{ .auxsrc, .phase }),
        },
        .div = div,
        .gated = true,
    };
    applyChange(gen, change);

    // The bookkeeping entry is only meaningful when the source is itself a
    // tracked generator; a PLL or oscillator tap has no entry to divide.
    const int_lsb = comptime @bitOffsetOf(DivOf(gen), "int");
    const source_hz = sourceHz(options.source);
    frequencies[@intFromEnum(gen)] = if (source_hz == 0)
        0
    else
        @intCast((@as(u64, source_hz) << int_lsb) / div);
}

/// Stops GPOUT generator `which` by clearing its enable gate.
///
/// Uses `ENABLE`, never `KILL`: killing a clock stops it asynchronously and can
/// truncate a pulse in flight, for logic that may be mid-operation.
pub fn gpoutDisable(comptime which: Gpout) void {
    const gen = comptime @field(Generator, @tagName(which));
    chip.clocks.generator(gen).ctrl.clearBits(comptime mmio.fieldMask(CtrlOf(gen), .enable));
    frequencies[@intFromEnum(gen)] = 0;
}

/// Options for `gpoutEnable`.
pub const Options = struct {
    /// The clock the generator observes.
    source: GpoutSource,
    /// Integer part of the divisor. 1 passes the source through unchanged.
    div_int: u32 = 1,
    /// Fractional part of the divisor, in units of one over the chip's
    /// fractional width: 1/256 on RP2040's 24.8 dividers, 1/65536 on RP2350's
    /// 16.16 ones. A fractional divisor alternates between neighboring integer
    /// ratios, so its average is right but its edges are not evenly spaced -
    /// fine for a bit-rate source, wrong for anything cycle-exact.
    div_frac: u32 = 0,
    /// `PHASE`: output delay, in cycles of the source clock.
    phase: u2 = 0,
};

/// Encodes a divisor as the register word for a divider whose integer part
/// starts at bit `int_lsb`.
///
/// One function serves both fixed-point formats, because the format is nothing
/// but that bit position: 8 for RP2040's 24.8 dividers, 16 for RP2350's 16.16
/// ones. The shift happens in 64 bits so a fast source cannot overflow it.
pub fn divEncode(src_hz: u64, target_hz: u64, comptime int_lsb: u6) u32 {
    return @intCast((src_hz << int_lsb) / target_hz);
}

/// Returns the `clk_sys` cycles to spin so that at least three cycles of a
/// `gen_hz` clock elapse, matching the reference implementation's margin.
pub fn delayCycles(sys_hz: u32, gen_hz: u32) u32 {
    return (sys_hz / gen_hz + 1) * 3;
}

/// Moves a glitchless generator onto source 0 and waits for the handover.
///
/// Source 0 is the ring oscillator for `clk_ref` and `clk_ref` itself for
/// `clk_sys`; both are always running, which is what makes this the safe place
/// to stand while the PLLs are reprogrammed.
inline fn parkOnSourceZero(comptime gen: Generator) void {
    const registers = chip.clocks.generator(gen);
    registers.ctrl.clearBits(comptime mmio.fieldMask(CtrlOf(gen), .src));
    while (registers.selected.read() != 0x1) {}
}

/// Configures a generator that has a glitchless `SRC` mux (`clk_ref`, `clk_sys`).
inline fn configureGlitchless(
    comptime gen: Generator,
    comptime src: SrcOf(gen),
    comptime auxsrc: AuxSrcOf(gen),
    comptime src_hz: u32,
    comptime target_hz: u32,
) void {
    const Ctrl = CtrlOf(gen);
    const change = comptime Change{
        .src = @intFromEnum(src),
        .ctrl = .{
            .value = @bitCast(Ctrl{ .auxsrc = auxsrc }),
            .mask = mmio.fieldMask(Ctrl, .auxsrc),
        },
        .div = divWord(gen, src_hz, target_hz),
        .gated = false,
    };
    applyChange(gen, change);
    frequencies[@intFromEnum(gen)] = target_hz;
}

/// Configures an aux-only generator, which must be gated off while its `AUXSRC`
/// moves.
inline fn configureAux(
    comptime gen: Generator,
    comptime auxsrc: AuxSrcOf(gen),
    comptime src_hz: u32,
    comptime target_hz: u32,
    comptime phase: u2,
) void {
    const Ctrl = CtrlOf(gen);
    const change = comptime blk: {
        const has_phase = @hasField(Ctrl, "phase");
        if (!has_phase and phase != 0) @compileError(
            "clocks: generator '" ++ @tagName(gen) ++ "' has no PHASE field",
        );
        break :blk Change{
            .ctrl = if (has_phase) .{
                .value = @bitCast(Ctrl{ .auxsrc = auxsrc, .phase = phase }),
                .mask = mmio.fieldsMask(Ctrl, &.{ .auxsrc, .phase }),
            } else .{
                .value = @bitCast(Ctrl{ .auxsrc = auxsrc }),
                .mask = mmio.fieldMask(Ctrl, .auxsrc),
            },
            .div = divWord(gen, src_hz, target_hz),
            .gated = true,
        };
    };
    applyChange(gen, change);
    frequencies[@intFromEnum(gen)] = target_hz;
}

/// Replays a plan as MMIO on the selected chip.
inline fn applyChange(comptime gen: Generator, comptime change: Change) void {
    inline for (comptime plan(change)) |step| execute(gen, step);
}

/// Carries out one planned step against `gen`'s registers.
inline fn execute(comptime gen: Generator, comptime step: Step) void {
    const registers = chip.clocks.generator(gen);
    const Ctrl = CtrlOf(gen);

    switch (step) {
        .div_if_larger => |word| {
            const current: u32 = @bitCast(registers.div.read());
            if (word > current) registers.div.write(@bitCast(word));
        },
        .disable => registers.ctrl.clearBits(comptime mmio.fieldMask(Ctrl, .enable)),
        .await_disable => awaitDisable(gen),
        .src => |value| registers.ctrl.writeMasked(
            comptime std.math.shl(u32, value, @bitOffsetOf(Ctrl, "src")),
            comptime mmio.fieldMask(Ctrl, .src),
        ),
        .poll_selected => |wanted| while (registers.selected.read() & wanted != wanted) {},
        .ctrl => |update| registers.ctrl.writeMasked(update.value, update.mask),
        .enable => registers.ctrl.setBits(comptime mmio.fieldMask(Ctrl, .enable)),
        .div => |word| registers.div.write(@bitCast(word)),
    }
}

/// Spins long enough for a just-cleared `ENABLE` to reach the generator's
/// output.
///
/// The wait is measured in `clk_sys` cycles because there is no timer yet - M3
/// is what makes one possible - so the count comes out of the frequency
/// bookkeeping. A generator this HAL has never configured is not running fast
/// enough to matter, and needs no wait at all.
fn awaitDisable(gen: Generator) void {
    const current = hz(gen);
    const sys_hz = hz(.sys);
    if (current == 0 or sys_hz == 0) return;
    busyWaitCycles(delayCycles(sys_hz, current));
}

/// Spins for at least `cycles` core cycles.
///
/// Deliberately conservative: each iteration costs several cycles, so the wait
/// overshoots rather than undershooting. The empty `volatile` asm is a compiler
/// barrier, without which an optimizer would delete a loop whose result nobody
/// reads. M4's timer replaces this with a real delay.
fn busyWaitCycles(cycles: u32) void {
    var remaining = cycles;
    while (remaining > 0) : (remaining -= 1) {
        asm volatile ("" ::: .{ .memory = true });
    }
}

/// The `CTRL` value layout of `gen`.
fn CtrlOf(comptime gen: Generator) type {
    return chip.clocks.GeneratorType(gen).Ctrl;
}

/// The `DIV` value layout of `gen`.
fn DivOf(comptime gen: Generator) type {
    return chip.clocks.GeneratorType(gen).Div;
}

/// The glitchless `SRC` encoding of `gen`. Only `clk_ref` and `clk_sys` have one.
fn SrcOf(comptime gen: Generator) type {
    return @FieldType(CtrlOf(gen), "src");
}

/// The `AUXSRC` encoding of `gen`.
fn AuxSrcOf(comptime gen: Generator) type {
    return @FieldType(CtrlOf(gen), "auxsrc");
}

/// The encoded `DIV` word taking `gen` from `src_hz` to `target_hz`, or null if
/// the generator has no divider on this chip.
fn divWord(comptime gen: Generator, comptime src_hz: u32, comptime target_hz: u32) ?u32 {
    return comptime blk: {
        const Div = DivOf(gen);
        if (!@hasField(Div, "int")) {
            if (src_hz != target_hz) @compileError(std.fmt.comptimePrint(
                "clocks: generator '{s}' has no divider on this chip, so it cannot turn {d} Hz into {d} Hz",
                .{ @tagName(gen), src_hz, target_hz },
            ));
            break :blk null;
        }

        const int_lsb = @bitOffsetOf(Div, "int");
        const word = divEncode(src_hz, target_hz, int_lsb);
        checkDivWord(gen, word);
        break :blk word;
    };
}

/// The encoded `DIV` word for a GPOUT generator's explicit integer and
/// fractional parts.
fn gpoutDivWord(comptime gen: Generator, comptime options: Options) u32 {
    return comptime blk: {
        const Div = DivOf(gen);
        const int_lsb = @bitOffsetOf(Div, "int");
        const Frac = @FieldType(Div, "frac");

        if (options.div_frac > std.math.maxInt(Frac)) @compileError(std.fmt.comptimePrint(
            "clocks: fractional divisor {d} does not fit this chip's {d}-bit FRAC field (max {d})",
            .{ options.div_frac, @bitSizeOf(Frac), std.math.maxInt(Frac) },
        ));

        const word = (@as(u64, options.div_int) << int_lsb) | options.div_frac;
        if (word > std.math.maxInt(u32)) @compileError(std.fmt.comptimePrint(
            "clocks: integer divisor {d} overflows the DIV register",
            .{options.div_int},
        ));
        checkDivWord(gen, @intCast(word));
        break :blk @intCast(word);
    };
}

/// Rejects an encoded divisor the generator's `DIV` register cannot hold.
fn checkDivWord(comptime gen: Generator, comptime word: u32) void {
    comptime {
        const Div = DivOf(gen);
        const int_lsb = @bitOffsetOf(Div, "int");
        const Int = @FieldType(Div, "int");

        const integer = word >> int_lsb;
        if (integer == 0) @compileError(std.fmt.comptimePrint(
            "clocks: divisor for '{s}' rounds to an integer part of 0, which the hardware reads as the maximum ratio",
            .{@tagName(gen)},
        ));
        if (integer > std.math.maxInt(Int)) @compileError(std.fmt.comptimePrint(
            "clocks: integer divisor {d} does not fit '{s}'s {d}-bit INT field (max {d})",
            .{ integer, @tagName(gen), @bitSizeOf(Int), std.math.maxInt(Int) },
        ));

        const fraction = word & ((@as(u32, 1) << int_lsb) - 1);
        if (!dividerEncodingIsSupported(Div, integer, fraction)) @compileError(std.fmt.comptimePrint(
            "clocks: RP2040 does not support a divisor between 1 and 2 for '{s}'; use exactly 1 or at least 2",
            .{@tagName(gen)},
        ));
        if (fraction != 0 and !@hasField(Div, "frac")) @compileError(std.fmt.comptimePrint(
            "clocks: '{s}' has an integer-only divider on this chip, but the requested ratio is not a whole number",
            .{@tagName(gen)},
        ));
    }
}

/// Whether an encoded divider lies in a ratio range implemented by the chip.
///
/// RP2040's fractional divider has a hardware gap: divide-by-1 works and ratios
/// at or above 2 work, but encodings between them do not. The original generic
/// field-width checks accepted that gap and could silently program an invalid
/// GPOUT ratio. RP2350 removed the restriction.
inline fn dividerEncodingIsSupported(
    comptime Div: type,
    comptime integer: u32,
    comptime fraction: u32,
) bool {
    if (config.chip != .rp2040) return true;
    if (!@hasField(Div, "frac")) return true;
    return integer != 1 or fraction == 0;
}

/// The bookkept frequency of `source`, or 0 when the source is not one of this
/// chip's generators (a PLL output, an oscillator, or a clock input pin).
fn sourceHz(comptime source: GpoutSource) u32 {
    const prefix = "clk_";
    const name = comptime @tagName(source);
    if (comptime !std.mem.startsWith(u8, name, prefix)) return 0;
    const generator_name = comptime name[prefix.len..];
    if (comptime !@hasField(Generator, generator_name)) return 0;
    return hz(@field(Generator, generator_name));
}

comptime {
    // The divider words in the manual's tables, in both fixed-point formats.
    std.debug.assert(divEncode(125_000_000, 125_000, 8) == 0x0003_e800);
    std.debug.assert(divEncode(150_000_000, 150_000, 16) == 0x03e8_0000);
    std.debug.assert(divEncode(12_000_000, 12_000_000, 8) == 0x0000_0100);
    std.debug.assert(divEncode(12_000_000, 12_000_000, 16) == 0x0001_0000);
}

test "a divisor encodes the same ratio in both chips' fixed-point formats" {
    const cases = [_]struct { src_hz: u32, target_hz: u32, rp2040: u32, rp2350: u32 }{
        // Divide by 1: the trap where a word copied across chips silently means
        // a different ratio.
        .{ .src_hz = 12_000_000, .target_hz = 12_000_000, .rp2040 = 0x0000_0100, .rp2350 = 0x0001_0000 },
        .{ .src_hz = 48_000_000, .target_hz = 48_000_000, .rp2040 = 0x0000_0100, .rp2350 = 0x0001_0000 },
        // The gpout example's divide by 1000.
        .{ .src_hz = 125_000_000, .target_hz = 125_000, .rp2040 = 0x0003_e800, .rp2350 = 0x03e8_0000 },
        .{ .src_hz = 150_000_000, .target_hz = 150_000, .rp2040 = 0x0003_e800, .rp2350 = 0x03e8_0000 },
        // A non-integer ratio: 2.5 is 0x280 in 24.8 and 0x2_8000 in 16.16.
        .{ .src_hz = 125_000_000, .target_hz = 50_000_000, .rp2040 = 0x0000_0280, .rp2350 = 0x0002_8000 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.rp2040, divEncode(case.src_hz, case.target_hz, 8));
        try std.testing.expectEqual(case.rp2350, divEncode(case.src_hz, case.target_hz, 16));
        // The integer part is the same ratio in both encodings.
        try std.testing.expectEqual(case.rp2040 >> 8, case.rp2350 >> 16);
    }
}

test "the RP2040 fractional-divider gap is rejected" {
    const Div = DivOf(.gpout0);

    // Divide-by-1 and divide-by-2 are valid on both chips.
    try std.testing.expect(dividerEncodingIsSupported(Div, 1, 0));
    try std.testing.expect(dividerEncodingIsSupported(Div, 2, 0));

    // RP2040 cannot implement 1.5, while RP2350 can. Keeping this as a
    // chip-instantiated test prevents the portable API from erasing that
    // hardware difference again.
    try std.testing.expectEqual(
        config.chip == .rp2350,
        dividerEncodingIsSupported(Div, 1, @as(u32, 1) << (@bitOffsetOf(Div, "int") - 1)),
    );
}

test "a growing divisor is written before the source switch, a shrinking one after" {
    // Both plans write DIV last; the growing case additionally pre-writes it, so
    // the domain never runs fast-source-with-old-small-divisor.
    const steps = comptime plan(.{
        .src = glitchless_aux_src,
        .ctrl = .{ .value = 0, .mask = 0xe0 },
        .div = 0x0000_0400,
        .gated = false,
    });

    try std.testing.expect(steps[0] == .div_if_larger);
    try std.testing.expectEqual(@as(u32, 0x0000_0400), steps[0].div_if_larger);
    try std.testing.expect(steps[steps.len - 1] == .div);
    try std.testing.expectEqual(@as(u32, 0x0000_0400), steps[steps.len - 1].div);

    // A generator with no divider has neither step.
    const no_div = comptime plan(.{
        .ctrl = .{ .value = 0, .mask = 0xe0 },
        .gated = true,
    });
    for (no_div) |step| {
        try std.testing.expect(step != .div);
        try std.testing.expect(step != .div_if_larger);
    }
}

test "a glitchless generator leaves the aux path before AUXSRC moves" {
    // clk_sys switching to PLL_SYS: park on source 0, change AUXSRC, switch
    // back to aux, and confirm each handover before trusting it.
    const steps = comptime plan(.{
        .src = glitchless_aux_src,
        .ctrl = .{ .value = 0, .mask = 0xe0 },
        .div = 0x0000_0100,
        .gated = false,
    });

    try std.testing.expectEqualSlices(Step, &.{
        .{ .div_if_larger = 0x0000_0100 },
        .{ .src = 0 },
        .{ .poll_selected = 0b01 },
        .{ .ctrl = .{ .value = 0, .mask = 0xe0 } },
        .{ .src = 1 },
        .{ .poll_selected = 0b10 },
        .{ .div = 0x0000_0100 },
    }, steps);
}

test "a glitchless generator moving to a direct source skips the park" {
    // clk_ref switching to the crystal (SRC 2) never touches the aux mux, so
    // there is nothing to park away from - but the handover is still confirmed.
    const steps = comptime plan(.{
        .src = 2,
        .ctrl = .{ .value = 0, .mask = 0x60 },
        .div = 0x0000_0100,
        .gated = false,
    });

    try std.testing.expectEqualSlices(Step, &.{
        .{ .div_if_larger = 0x0000_0100 },
        .{ .ctrl = .{ .value = 0, .mask = 0x60 } },
        .{ .src = 2 },
        .{ .poll_selected = 0b100 },
        .{ .div = 0x0000_0100 },
    }, steps);
}

test "an aux-only generator is disabled, settled, and re-enabled" {
    // clk_usb switching to PLL_USB. No SELECTED polling: the register is
    // hard-wired to 0x1 on a generator with no glitchless mux.
    const steps = comptime plan(.{
        .ctrl = .{ .value = 0, .mask = 0xe0 },
        .div = 0x0000_0100,
        .gated = true,
    });

    try std.testing.expectEqualSlices(Step, &.{
        .{ .div_if_larger = 0x0000_0100 },
        .disable,
        .await_disable,
        .{ .ctrl = .{ .value = 0, .mask = 0xe0 } },
        .enable,
        .{ .div = 0x0000_0100 },
    }, steps);

    for (steps) |step| {
        try std.testing.expect(step != .src);
        try std.testing.expect(step != .poll_selected);
    }
}

test "the disable settling wait covers at least three cycles of the target clock" {
    // The wait is counted in clk_sys cycles, so a slower generator needs more of
    // them. The margin is deliberately over rather than under.
    try std.testing.expectEqual(@as(u32, 6), delayCycles(125_000_000, 125_000_000));
    try std.testing.expectEqual(@as(u32, 12), delayCycles(150_000_000, 48_000_000));

    const sys_hz: u32 = 125_000_000;
    for ([_]u32{ 125_000_000, 48_000_000, 12_000_000, 125_000 }) |gen_hz| {
        const cycles = delayCycles(sys_hz, gen_hz);
        // Three generator cycles, expressed in clk_sys cycles, must fit inside
        // what the wait actually spins for.
        try std.testing.expect(cycles >= 3 * (sys_hz / gen_hz));
    }
}

test "frequency bookkeeping starts empty and reports what was recorded" {
    // `.bss` storage, so a fresh program sees zeros until startup fills them in.
    for (std.enums.values(Generator)) |gen| {
        frequencies[@intFromEnum(gen)] = 0;
        try std.testing.expectEqual(@as(u32, 0), hz(gen));
    }

    // What the default plan leaves behind, on whichever chip is under test.
    frequencies[@intFromEnum(Generator.ref)] = 12_000_000;
    frequencies[@intFromEnum(Generator.sys)] = chip.sys_clk_hz;
    frequencies[@intFromEnum(Generator.peri)] = chip.sys_clk_hz;
    frequencies[@intFromEnum(Generator.usb)] = chip.usb_clk_hz;
    frequencies[@intFromEnum(Generator.adc)] = chip.usb_clk_hz;

    try std.testing.expectEqual(@as(u32, 12_000_000), hz(.ref));
    try std.testing.expectEqual(chip.sys_clk_hz, hz(.sys));
    try std.testing.expectEqual(chip.sys_clk_hz, hz(.peri));
    try std.testing.expectEqual(chip.usb_clk_hz, hz(.usb));
    try std.testing.expectEqual(chip.usb_clk_hz, hz(.adc));

    // The generator only one chip has is left at reset by this milestone.
    const deferred = if (@hasField(Generator, "rtc")) Generator.rtc else Generator.hstx;
    try std.testing.expectEqual(@as(u32, 0), hz(deferred));

    for (std.enums.values(Generator)) |gen| frequencies[@intFromEnum(gen)] = 0;
}
