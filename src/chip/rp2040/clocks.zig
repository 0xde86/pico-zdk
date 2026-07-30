//! RP2040 clock generators, muxes, and dividers (CLOCKS).
//!
//! The block instantiates the same small machine ten times - a source mux, an
//! optional divider, and for most generators an enable gate:
//!
//!     sources -> [ AUXSRC mux ] -> (glitchless SRC mux) -> [ / divider ] -> clk_x
//!
//! Only `clk_ref` and `clk_sys` have the glitchless `SRC` mux; every other
//! generator must be disabled before its `AUXSRC` changes.
//!
//! Source: [RP2040 datasheet §2.15, "Clocks"](https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// The clock generators this chip instantiates, in register-map order.
///
/// Member names are the portable contract; the ordinal is the generator's index
/// in the block. Use the names rather than copying numeric indices.
pub const Generator = enum(u4) {
    /// Clock output 0, routable to a package pin.
    gpout0,
    /// Clock output 1, routable to a package pin.
    gpout1,
    /// Clock output 2, routable to a package pin.
    gpout2,
    /// Clock output 3, routable to a package pin.
    gpout3,
    /// The always-sane reference: tick generators and the watchdog run from it.
    ref,
    /// Cores, bus fabric, SRAM, and flash execution.
    sys,
    /// Peripheral bit-rate clock for UART and SPI.
    peri,
    /// USB controller clock; must be 48 MHz.
    usb,
    /// ADC clock; 48 MHz.
    adc,
    /// Real-time clock. M15 owns its configuration.
    rtc,
};

/// `CLK_REF_CTRL.SRC`: the glitchless mux feeding `clk_ref`.
pub const RefSrc = enum(u2) {
    /// Ring oscillator, phase-shifted tap. The power-on selection.
    rosc_ph = 0,
    /// Whatever the auxiliary mux selects.
    aux = 1,
    /// Crystal oscillator.
    xosc = 2,
    _,
};

/// `CLK_REF_CTRL.AUXSRC`: the auxiliary mux behind `clk_ref`'s glitchless mux.
pub const RefAuxSrc = enum(u2) {
    pll_usb = 0,
    gpin0 = 1,
    gpin1 = 2,
    _,
};

/// `CLK_SYS_CTRL.SRC`: the glitchless mux feeding `clk_sys`.
pub const SysSrc = enum(u1) {
    /// Follow `clk_ref`. The power-on selection on this chip.
    clk_ref = 0,
    /// Whatever the auxiliary mux selects.
    aux = 1,
};

/// `CLK_SYS_CTRL.AUXSRC`: the auxiliary mux behind `clk_sys`'s glitchless mux.
pub const SysAuxSrc = enum(u3) {
    pll_sys = 0,
    pll_usb = 1,
    rosc = 2,
    xosc = 3,
    gpin0 = 4,
    gpin1 = 5,
    _,
};

/// `CLK_PERI_CTRL.AUXSRC`.
pub const PeriAuxSrc = enum(u3) {
    clk_sys = 0,
    pll_sys = 1,
    pll_usb = 2,
    rosc_ph = 3,
    xosc = 4,
    gpin0 = 5,
    gpin1 = 6,
    _,
};

/// `AUXSRC` encoding shared by `clk_usb`, `clk_adc`, and `clk_rtc`.
pub const UsbAuxSrc = enum(u3) {
    pll_usb = 0,
    pll_sys = 1,
    rosc_ph = 2,
    xosc = 3,
    gpin0 = 4,
    gpin1 = 5,
    _,
};

/// `AUXSRC` encoding shared by `clk_adc` and `clk_usb`.
pub const AdcAuxSrc = UsbAuxSrc;

/// `AUXSRC` encoding shared by `clk_rtc` and `clk_usb`.
pub const RtcAuxSrc = UsbAuxSrc;

/// `CLK_GPOUTn_CTRL.AUXSRC`: the clock a GPOUT generator observes.
///
/// Use these names rather than raw numbers so call sites follow the portable
/// clock-source contract.
pub const GpoutAuxSrc = enum(u4) {
    pll_sys = 0x0,
    gpin0 = 0x1,
    gpin1 = 0x2,
    pll_usb = 0x3,
    rosc = 0x4,
    xosc = 0x5,
    clk_sys = 0x6,
    clk_usb = 0x7,
    clk_adc = 0x8,
    clk_rtc = 0x9,
    clk_ref = 0xa,
    _,
};

/// `CLK_GPOUTn_CTRL`: source, gating, duty cycle, and output phase.
pub const GpoutCtrl = packed struct(u32) {
    _reserved0: u5 = 0,
    /// `AUXSRC`: the clock this generator observes.
    auxsrc: GpoutAuxSrc = .pll_sys,
    _reserved1: u1 = 0,
    /// `KILL`: stop the clock asynchronously, possibly truncating a pulse in
    /// flight. A last resort; the HAL never sets it.
    kill: bool = false,
    /// `ENABLE`: clean enable/disable of the generator.
    enable: bool = false,
    /// `DC50`: force a 50% duty cycle for odd integer divisors.
    dc50: bool = false,
    _reserved2: u3 = 0,
    /// `PHASE`: output delay, in source clock cycles.
    phase: u2 = 0,
    _reserved3: u2 = 0,
    /// `NUDGE`: shift the output phase by one cycle. Unexposed by the HAL.
    nudge: bool = false,
    _reserved4: u11 = 0,
};

/// `CLK_REF_CTRL`: glitchless source select plus the auxiliary mux behind it.
/// `clk_ref` is never gated, so it has no `ENABLE` bit.
pub const RefCtrl = packed struct(u32) {
    /// `SRC`: glitchless mux select.
    src: RefSrc = .rosc_ph,
    _reserved0: u3 = 0,
    /// `AUXSRC`: auxiliary mux select, reachable through `SRC` value `aux`.
    auxsrc: RefAuxSrc = .pll_usb,
    _reserved1: u25 = 0,
};

/// `CLK_SYS_CTRL`: glitchless source select plus the auxiliary mux behind it.
/// `clk_sys` is never gated, so it has no `ENABLE` bit.
pub const SysCtrl = packed struct(u32) {
    /// `SRC`: glitchless mux select.
    src: SysSrc = .clk_ref,
    _reserved0: u4 = 0,
    /// `AUXSRC`: auxiliary mux select, reachable through `SRC` value `aux`.
    auxsrc: SysAuxSrc = .pll_sys,
    _reserved1: u24 = 0,
};

/// `CLK_PERI_CTRL`: auxiliary source and gating. No divider exists on this chip.
pub const PeriCtrl = packed struct(u32) {
    _reserved0: u5 = 0,
    /// `AUXSRC`: the clock this generator observes.
    auxsrc: PeriAuxSrc = .clk_sys,
    _reserved1: u2 = 0,
    /// `KILL`: stop the clock asynchronously. A last resort; unexposed.
    kill: bool = false,
    /// `ENABLE`: clean enable/disable of the generator.
    enable: bool = false,
    _reserved2: u20 = 0,
};

/// `CLK_USB_CTRL`: auxiliary source, gating, and output phase.
pub const UsbCtrl = packed struct(u32) {
    _reserved0: u5 = 0,
    /// `AUXSRC`: the clock this generator observes.
    auxsrc: UsbAuxSrc = .pll_usb,
    _reserved1: u2 = 0,
    /// `KILL`: stop the clock asynchronously. A last resort; unexposed.
    kill: bool = false,
    /// `ENABLE`: clean enable/disable of the generator.
    enable: bool = false,
    _reserved2: u4 = 0,
    /// `PHASE`: output delay, in source clock cycles.
    phase: u2 = 0,
    _reserved3: u2 = 0,
    /// `NUDGE`: shift the output phase by one cycle. Unexposed by the HAL.
    nudge: bool = false,
    _reserved4: u11 = 0,
};

/// `CLK_ADC_CTRL`: same layout and encoding as `CLK_USB_CTRL`.
pub const AdcCtrl = packed struct(u32) {
    _reserved0: u5 = 0,
    /// `AUXSRC`: the clock this generator observes.
    auxsrc: AdcAuxSrc = .pll_usb,
    _reserved1: u2 = 0,
    /// `KILL`: stop the clock asynchronously. A last resort; unexposed.
    kill: bool = false,
    /// `ENABLE`: clean enable/disable of the generator.
    enable: bool = false,
    _reserved2: u4 = 0,
    /// `PHASE`: output delay, in source clock cycles.
    phase: u2 = 0,
    _reserved3: u2 = 0,
    /// `NUDGE`: shift the output phase by one cycle. Unexposed by the HAL.
    nudge: bool = false,
    _reserved4: u11 = 0,
};

/// `CLK_RTC_CTRL`: same layout and encoding as `CLK_USB_CTRL`.
/// M3 leaves this generator at its reset state.
pub const RtcCtrl = packed struct(u32) {
    _reserved0: u5 = 0,
    /// `AUXSRC`: the clock this generator observes.
    auxsrc: RtcAuxSrc = .pll_usb,
    _reserved1: u2 = 0,
    /// `KILL`: stop the clock asynchronously. A last resort; unexposed.
    kill: bool = false,
    /// `ENABLE`: clean enable/disable of the generator.
    enable: bool = false,
    _reserved2: u4 = 0,
    /// `PHASE`: output delay, in source clock cycles.
    phase: u2 = 0,
    _reserved3: u2 = 0,
    /// `NUDGE`: shift the output phase by one cycle. Unexposed by the HAL.
    nudge: bool = false,
    _reserved4: u11 = 0,
};

/// 24.8 fixed-point divisor, used by the GPOUT generators, `clk_sys`, and
/// `clk_rtc`. The register word for "divide by 1" is `0x0000_0100`.
pub const FracDiv = packed struct(u32) {
    /// Fractional part, in units of 1/256. A fractional divisor alternates
    /// between neighboring integer ratios; the average is right, the edges are
    /// not evenly spaced.
    frac: u8 = 0,
    /// Integer part. Writing 0 selects the maximum division ratio rather than
    /// dividing by zero.
    int: u24 = 1,
};

/// Integer-only divisor occupying the same 24.8 integer position, but only two
/// bits wide. Used by `clk_ref`, `clk_usb`, and `clk_adc`.
pub const IntDiv2 = packed struct(u32) {
    _reserved0: u8 = 0,
    /// Integer part, bits [9:8]. Writing 0 selects the maximum ratio.
    int: u2 = 1,
    _reserved1: u22 = 0,
};

/// `clk_peri` has no divider on this chip; its `DIV` slot is a reserved word.
/// The absence of an `int` field is what tells the HAL there is nothing to
/// divide.
pub const NoDiv = packed struct(u32) {
    _reserved0: u32 = 0,
};

/// `CLK_SYS_RESUS_CTRL`: the resuscitation watchdog that forces `clk_sys` back
/// onto `clk_ref` if it ever stops. M3 writes this register to zero and defers
/// the feature itself.
pub const ResusCtrl = packed struct(u32) {
    /// `TIMEOUT`: `clk_ref` cycles without a `clk_sys` edge before resus fires.
    timeout: u8 = 0xff,
    /// `ENABLE`: arm the resuscitation hardware.
    enable: bool = false,
    _reserved0: u3 = 0,
    /// `FRCE`: force a resus event, for testing.
    force: bool = false,
    _reserved1: u3 = 0,
    /// `CLEAR`: acknowledge and clear a resus event.
    clear: bool = false,
    _reserved2: u15 = 0,
};

/// `CLK_SYS_RESUS_STATUS`.
pub const ResusStatus = packed struct(u32) {
    /// `RESUSSED`: `clk_sys` was resuscitated since this bit was last cleared.
    resussed: bool = false,
    _reserved0: u31 = 0,
};

/// `INTR`/`INTE`/`INTF`/`INTS`: the resus interrupt, modeled as data. M7 owns
/// interrupt behavior.
pub const Interrupt = packed struct(u32) {
    /// `CLK_SYS_RESUS`: the resus hardware fired.
    clk_sys_resus: bool = false,
    _reserved0: u31 = 0,
};

/// One clock generator's register triple.
///
/// `SELECTED` is a live one-hot status rather than storage: bit *n* set means
/// glitchless source *n* currently drives the output, and it can briefly read
/// zero during a handover. Aux-only generators hard-wire it to `0x1`.
pub fn GeneratorRegisters(comptime CtrlType: type, comptime DivType: type) type {
    return extern struct {
        /// `CTRL` value layout of this generator.
        pub const Ctrl = CtrlType;
        /// `DIV` value layout of this generator.
        pub const Div = DivType;

        ctrl: mmio.ApbReadWrite(CtrlType),
        div: mmio.ApbReadWrite(DivType),
        selected: mmio.ReadOnly(u32),
    };
}

/// CLOCKS register block.
///
/// Everything after the ten generators is layout-tested data with no M3
/// behavior: the frequency counter belongs to M6, the wake/sleep enables and
/// the resus feature to M30, the interrupts to M7.
pub const Registers = extern struct {
    gpout0: GeneratorRegisters(GpoutCtrl, FracDiv),
    gpout1: GeneratorRegisters(GpoutCtrl, FracDiv),
    gpout2: GeneratorRegisters(GpoutCtrl, FracDiv),
    gpout3: GeneratorRegisters(GpoutCtrl, FracDiv),
    ref: GeneratorRegisters(RefCtrl, IntDiv2),
    sys: GeneratorRegisters(SysCtrl, FracDiv),
    peri: GeneratorRegisters(PeriCtrl, NoDiv),
    usb: GeneratorRegisters(UsbCtrl, IntDiv2),
    adc: GeneratorRegisters(AdcCtrl, IntDiv2),
    rtc: GeneratorRegisters(RtcCtrl, FracDiv),
    resus_ctrl: mmio.ApbReadWrite(ResusCtrl),
    resus_status: mmio.ReadOnly(ResusStatus),
    /// `FC0_*`: the frequency counter, eight registers of M6 infrastructure.
    /// Modeled as raw words because no bit here has a consumer yet.
    fc0_ref_khz: mmio.ApbReadWrite(u32),
    fc0_min_khz: mmio.ApbReadWrite(u32),
    fc0_max_khz: mmio.ApbReadWrite(u32),
    fc0_delay: mmio.ApbReadWrite(u32),
    fc0_interval: mmio.ApbReadWrite(u32),
    fc0_src: mmio.ApbReadWrite(u32),
    fc0_status: mmio.ReadOnly(u32),
    fc0_result: mmio.ReadOnly(u32),
    /// `WAKE_EN*`/`SLEEP_EN*`: per-consumer clock enables used by the sleep
    /// modes. One bit per clocked block; the inventory arrives with M30.
    wake_en0: mmio.ApbReadWrite(u32),
    wake_en1: mmio.ApbReadWrite(u32),
    sleep_en0: mmio.ApbReadWrite(u32),
    sleep_en1: mmio.ApbReadWrite(u32),
    /// `ENABLED*`: read-back of which clocked blocks are actually running.
    enabled0: mmio.ReadOnly(u32),
    enabled1: mmio.ReadOnly(u32),
    intr: mmio.ReadWrite(Interrupt),
    inte: mmio.ApbReadWrite(Interrupt),
    intf: mmio.ApbReadWrite(Interrupt),
    ints: mmio.ReadOnly(Interrupt),
};

/// The CLOCKS peripheral at its RP2040 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.clocks_base);

/// Returns the register-triple type of generator `gen`, which carries its
/// chip-specific `Ctrl` and `Div` value layouts.
pub fn GeneratorType(comptime gen: Generator) type {
    return @FieldType(Registers, @tagName(gen));
}

/// Returns a pointer to `gen`'s register triple inside the CLOCKS block.
pub inline fn generator(comptime gen: Generator) *volatile GeneratorType(gen) {
    return @ptrFromInt(address_map.clocks_base + @offsetOf(Registers, @tagName(gen)));
}

comptime {
    const std = @import("std");

    // Generator ordinals are register-map indices: three words each, from zero.
    for (@typeInfo(Generator).@"enum".fields) |field| {
        std.debug.assert(@offsetOf(Registers, field.name) == field.value * 12);
    }
    std.debug.assert(@offsetOf(Registers, "ref") == 0x30);
    std.debug.assert(@offsetOf(Registers, "sys") == 0x3c);
    std.debug.assert(@offsetOf(Registers, "peri") == 0x48);
    std.debug.assert(@offsetOf(Registers, "usb") == 0x54);
    std.debug.assert(@offsetOf(Registers, "adc") == 0x60);
    std.debug.assert(@offsetOf(Registers, "rtc") == 0x6c);

    // The block tail begins with the resuscitation registers.
    std.debug.assert(@offsetOf(Registers, "resus_ctrl") == 0x78);
    std.debug.assert(@offsetOf(Registers, "resus_status") == 0x7c);
    std.debug.assert(@offsetOf(Registers, "fc0_ref_khz") == 0x80);
    std.debug.assert(@offsetOf(Registers, "fc0_result") == 0x9c);
    std.debug.assert(@offsetOf(Registers, "wake_en0") == 0xa0);
    std.debug.assert(@offsetOf(Registers, "sleep_en0") == 0xa8);
    std.debug.assert(@offsetOf(Registers, "enabled0") == 0xb0);
    std.debug.assert(@offsetOf(Registers, "intr") == 0xb8);
    std.debug.assert(@offsetOf(Registers, "ints") == 0xc4);
    std.debug.assert(@sizeOf(Registers) == 0xc8);

    // CTRL field bit positions per the datasheet register definitions.
    std.debug.assert(@bitOffsetOf(GpoutCtrl, "auxsrc") == 5);
    std.debug.assert(@bitOffsetOf(GpoutCtrl, "kill") == 10);
    std.debug.assert(@bitOffsetOf(GpoutCtrl, "enable") == 11);
    std.debug.assert(@bitOffsetOf(GpoutCtrl, "dc50") == 12);
    std.debug.assert(@bitOffsetOf(GpoutCtrl, "phase") == 16);
    std.debug.assert(@bitOffsetOf(GpoutCtrl, "nudge") == 20);

    std.debug.assert(@bitOffsetOf(RefCtrl, "src") == 0);
    std.debug.assert(@bitOffsetOf(RefCtrl, "auxsrc") == 5);
    std.debug.assert(@bitSizeOf(RefSrc) == 2);
    std.debug.assert(@bitSizeOf(RefAuxSrc) == 2);

    std.debug.assert(@bitOffsetOf(SysCtrl, "src") == 0);
    std.debug.assert(@bitOffsetOf(SysCtrl, "auxsrc") == 5);
    std.debug.assert(@bitSizeOf(SysSrc) == 1);
    std.debug.assert(@bitSizeOf(SysAuxSrc) == 3);

    std.debug.assert(@bitOffsetOf(PeriCtrl, "auxsrc") == 5);
    std.debug.assert(@bitOffsetOf(PeriCtrl, "enable") == 11);
    std.debug.assert(@bitOffsetOf(UsbCtrl, "auxsrc") == 5);
    std.debug.assert(@bitOffsetOf(UsbCtrl, "enable") == 11);
    std.debug.assert(@bitOffsetOf(UsbCtrl, "phase") == 16);

    // Both glitchless muxes reach their auxiliary stage through source 1; the
    // HAL relies on that shared encoding to detect an aux-bound switch.
    std.debug.assert(@intFromEnum(RefSrc.aux) == 1);
    std.debug.assert(@intFromEnum(SysSrc.aux) == 1);

    // Divider words for "divide by 1".
    std.debug.assert(@as(u32, @bitCast(FracDiv{})) == 0x0000_0100);
    std.debug.assert(@as(u32, @bitCast(IntDiv2{})) == 0x0000_0100);
    std.debug.assert(@bitOffsetOf(FracDiv, "int") == 8);
    std.debug.assert(@bitOffsetOf(IntDiv2, "int") == 8);
    // The gpout example's divide-by-1000 word (manual section 10.2).
    std.debug.assert(@as(u32, @bitCast(FracDiv{ .int = 1000 })) == 0x0003_e800);

    // Resus is written as an all-zero word before anything else is touched.
    std.debug.assert(@as(u32, @bitCast(ResusCtrl{ .timeout = 0 })) == 0x0000_0000);
    std.debug.assert(@as(u32, @bitCast(ResusCtrl{})) == 0x0000_00ff);
    std.debug.assert(@bitOffsetOf(ResusCtrl, "enable") == 8);
    std.debug.assert(@bitOffsetOf(ResusCtrl, "force") == 12);
    std.debug.assert(@bitOffsetOf(ResusCtrl, "clear") == 16);

    // Generator register pointers, as worked through in the manual's tables.
    std.debug.assert(@intFromPtr(generator(.gpout0)) == 0x4000_8000);
    std.debug.assert(@intFromPtr(generator(.sys)) == 0x4000_803c);
    std.debug.assert(@intFromPtr(&generator(.sys).selected) == 0x4000_8044);
}
