//! RP2350 user IO bank (IO_BANK0): per-pin GPIO status and function-select mux.
//!
//! Source: [RP2350 datasheet §9.11, "IO_BANK0 registers"](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// GPIOx_STATUS: read-only view of a pin's post-override output, output-enable,
/// input, and interrupt-to-processor signals. RP2350 exposes fewer status bits
/// than RP2040 (no pre-override "from peri"/"from pad" mirrors except INFROMPAD).
pub const GpioStatus = packed struct(u32) {
    _reserved0: u9 = 0,
    /// Output signal to the pad, after the OUTOVER override.
    out_to_pad: u1,
    _reserved1: u3 = 0,
    /// Output enable to the pad, after the OEOVER override.
    oe_to_pad: u1,
    _reserved2: u3 = 0,
    /// Input signal from the pad, before filtering and the INOVER override.
    in_from_pad: u1,
    _reserved3: u8 = 0,
    /// Interrupt to the processors, after the IRQOVER override.
    irq_to_proc: u1,
    _reserved4: u5 = 0,
};

/// Two-bit override applied to a pin's output, input, or interrupt signal.
pub const Override = enum(u2) {
    /// Drive the peripheral's signal unchanged.
    normal = 0,
    /// Drive the peripheral's signal inverted.
    invert = 1,
    /// Force the signal low, ignoring the peripheral.
    low = 2,
    /// Force the signal high, ignoring the peripheral.
    high = 3,
};

/// Two-bit override applied to a pin's output enable. Values 2 and 3
/// force the pad's output driver rather than a signal level.
pub const OeOverride = enum(u2) {
    /// Take the output enable from the selected peripheral.
    normal = 0,
    /// Take the output enable from the selected peripheral, inverted.
    invert = 1,
    /// Force the output driver off, ignoring the peripheral.
    disable = 2,
    /// Force the output driver on, ignoring the peripheral.
    enable = 3,
};

/// FUNCSEL encoding: the peripheral family whose signals the mux routes to a pin.
///
/// Values are RP2350-specific; the member names shared with RP2040 are part of
/// the cross-chip contract probed in `chip.zig`.
///
/// Non-exhaustive because FUNCSEL is a full 5-bit field: encodings with no
/// named family here (funcsel 0 means something different on nearly every pin)
/// must stay representable when CTRL is read back.
pub const FuncSel = enum(u5) {
    /// SPI0 or SPI1 - the pin decides which, and whether it carries SCK, TX,
    /// RX, or CS.
    spi = 1,
    /// UART0 or UART1 - the pin decides which, and whether it carries TX, RX,
    /// CTS, or RTS.
    uart = 2,
    /// I2C0 or I2C1 - the pin decides which, and whether it carries SDA or SCL.
    i2c = 3,
    /// One channel of one PWM slice; the pin decides which.
    pwm = 4,
    /// Software-controlled GPIO through SIO. Same encoding on RP2040.
    sio = 5,
    /// PIO block 0. Any pin in the bank can be claimed by a state machine.
    pio0 = 6,
    /// PIO block 1. Any pin in the bank can be claimed by a state machine.
    pio1 = 7,
    /// Third PIO block; no RP2040 equivalent, which is why RP2040 can encode
    /// `gpclk` at 8 and this chip cannot.
    pio2 = 8,
    /// General-purpose clock in/out.
    gpclk = 9,
    /// Disconnects the pin's digital function. Datasheet name: NULL.
    none = 31,
    _,
};

/// Whether `f` can be routed to `pin`.
///
/// For most families the pin decides *which* instance and signal it gets -
/// GPIO 0 is UART0 TX, GPIO 1 is UART0 RX - so availability is a per-pin table
/// in the datasheet, not a property of the encoding. Those families are
/// rejected here until the milestone that routes them transcribes the table.
///
/// SIO, PIO, and NULL carry no such identity - the pin number *is* the
/// parameter - so they are available on every pin the bank defines. Pins
/// outside the register map are rejected; the HAL additionally rejects pins
/// the selected package does not bond (`chip.gpio_count`).
pub fn isAvailable(comptime pin: u8, comptime f: FuncSel) bool {
    if (pin >= num_gpios) return false;
    return switch (f) {
        .sio, .pio0, .pio1, .pio2, .none => true,
        .spi, .uart, .i2c, .pwm, .gpclk => @compileError(
            "RP2350 pin table for FUNCSEL '" ++ @tagName(f) ++ "' is not transcribed yet",
        ),
        // An encoding with no named family cannot be selected through the HAL.
        _ => false,
    };
}

/// GPIOx_CTRL: pin function select plus per-signal overrides. The override
/// fields sit at different bit positions than on RP2040 (OUTOVER/OEOVER moved
/// up to bits 12..15).
pub const GpioCtrl = packed struct(u32) {
    /// Peripheral routed to the pin.
    funcsel: FuncSel = .none,
    _reserved0: u7 = 0,
    /// Output signal override.
    out_over: Override = .normal,
    /// Output-enable override.
    oe_over: OeOverride = .normal,
    /// Input override.
    in_over: Override = .normal,
    _reserved1: u10 = 0,
    /// Interrupt override.
    irq_over: Override = .normal,
    _reserved2: u2 = 0,
};

/// One GPIO's register pair: STATUS (read-only) then CTRL (8 bytes), as laid
/// out per pin in the IO_BANK0 array. CTRL is APB read-write so the HAL can
/// masked-update FUNCSEL while preserving the overrides.
pub const Gpio = extern struct {
    status: mmio.ReadOnly(GpioStatus),
    ctrl: mmio.ApbReadWrite(GpioCtrl),
};

/// GPIO register slots defined by the IO_BANK0 block (register-map size). The
/// RP2350 die carries 48 slots (B-package superset); the A-package (Pico 2)
/// only bonds the first 30. The usable pin count is the facade's `gpio_count`.
pub const num_gpios = 48;

/// IO_BANK0 register block
pub const Registers = extern struct {
    io: [num_gpios]Gpio,
};

/// The IO_BANK0 peripheral at its RP2350 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.io_bank0_base);

comptime {
    const std = @import("std");

    // Field bit positions per the datasheet register definitions.
    std.debug.assert(@bitOffsetOf(GpioStatus, "out_to_pad") == 9);
    std.debug.assert(@bitOffsetOf(GpioStatus, "oe_to_pad") == 13);
    std.debug.assert(@bitOffsetOf(GpioStatus, "in_from_pad") == 17);
    std.debug.assert(@bitOffsetOf(GpioStatus, "irq_to_proc") == 26);

    std.debug.assert(@bitOffsetOf(GpioCtrl, "funcsel") == 0);
    std.debug.assert(@bitOffsetOf(GpioCtrl, "out_over") == 12);
    std.debug.assert(@bitOffsetOf(GpioCtrl, "oe_over") == 14);
    std.debug.assert(@bitOffsetOf(GpioCtrl, "in_over") == 16);
    std.debug.assert(@bitOffsetOf(GpioCtrl, "irq_over") == 28);

    std.debug.assert(@as(u32, @bitCast(GpioCtrl{})) == 0x0000_001f);
    std.debug.assert(@as(u32, @bitCast(GpioCtrl{ .funcsel = .sio })) == 0x0000_0005);

    // FUNCSEL encodings, in the five-bit field the datasheet gives.
    std.debug.assert(@bitSizeOf(FuncSel) == 5);
    std.debug.assert(@intFromEnum(FuncSel.sio) == 5);
    std.debug.assert(@intFromEnum(FuncSel.pio2) == 8);
    std.debug.assert(@intFromEnum(FuncSel.gpclk) == 9);
    std.debug.assert(@intFromEnum(FuncSel.none) == 31);

    // A pin left in an encoding with no named family here must stay
    // representable when CTRL is read back, and must not be selectable.
    std.debug.assert(!@typeInfo(FuncSel).@"enum".is_exhaustive);
    std.debug.assert(!isAvailable(0, @enumFromInt(0)));

    std.debug.assert(isAvailable(0, .sio));
    std.debug.assert(isAvailable(num_gpios - 1, .sio));
    std.debug.assert(isAvailable(num_gpios - 1, .pio2));
    std.debug.assert(!isAvailable(num_gpios, .sio));

    std.debug.assert(@intFromEnum(Override.normal) == 0);
    std.debug.assert(@intFromEnum(Override.invert) == 1);
    std.debug.assert(@intFromEnum(Override.low) == 2);
    std.debug.assert(@intFromEnum(Override.high) == 3);
    std.debug.assert(@intFromEnum(OeOverride.disable) == 2);
    std.debug.assert(@intFromEnum(OeOverride.enable) == 3);
    std.debug.assert(@as(u32, @bitCast(GpioCtrl{ .out_over = .high })) == 0x0000_301f);
    std.debug.assert(@as(u32, @bitCast(GpioCtrl{ .oe_over = .enable })) == 0x0000_c01f);

    // Block layout: STATUS at +0x00, CTRL at +0x04, 8 bytes per pin.
    std.debug.assert(@offsetOf(Gpio, "status") == 0x00);
    std.debug.assert(@offsetOf(Gpio, "ctrl") == 0x04);
    std.debug.assert(@sizeOf(Gpio) == 8);
    std.debug.assert(@sizeOf(Registers) == num_gpios * 8);
}
