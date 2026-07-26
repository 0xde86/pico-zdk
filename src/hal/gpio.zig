//! Portable physical-pin configuration over IO_BANK0 and PADS_BANK0.
//!
//! Behavior follows RP2040 datasheet §2.19 and RP2350 datasheet §9.11 (the IO
//! bank and pads). Software-controlled direction and value operations live in
//! `sio.zig`; this module owns the function mux and electrical pad controls.
//!
//! Interrupts, callbacks, and the GPIO coprocessor path are later milestones.

const std = @import("std");
const chip = @import("../chip.zig");
const mmio = @import("../chip/mmio.zig");

/// Weak pull-resistor bias for a pin.
pub const Pull = enum {
    /// No pull; a floating input has no defined level.
    none,
    /// Weak pull-up toward the bank supply.
    up,
    /// Weak pull-down toward ground. On RP2350 A2 silicon this is subject to
    /// erratum RP2350-E9: a weak/floating Bank 0 input can be sourced to ~2.2 V
    /// faster than the internal pull-down can hold it low. Affected designs need
    /// the datasheet workaround (external pull-down ≤ 8.2 kΩ, or toggling input
    /// enable around each read); A3 silicon fixes it in hardware.
    down,
};

/// Nominal output drive strength. Identical four-value encoding on both chips.
pub const DriveStrength = chip.pads_bank0.Drive;

/// Peripheral family a pin's function mux can route. Portable across chips.
/// For now only the identity-free families (`sio`, `pio0`, `pio1`, `none`) can be
/// selected.
pub const Function = enum {
    /// SPI signal selected by the chip's per-pin function table.
    spi,
    /// UART signal selected by the chip's per-pin function table.
    uart,
    /// I2C signal selected by the chip's per-pin function table.
    i2c,
    /// PWM channel selected by the chip's per-pin function table.
    pwm,
    /// Software-controlled digital I/O through SIO.
    sio,
    /// Programmable I/O block 0.
    pio0,
    /// Programmable I/O block 1.
    pio1,
    /// General-purpose clock signal selected by the per-pin function table.
    gpclk,
    /// Disconnect the pin from all digital peripheral functions.
    none,
};

/// Routes `function` to the pin through the IO_BANK0 mux, following pico-sdk
/// semantics: enable the pad input buffer, clear the pad output-disable,
/// write the function with normal (peripheral-driven) overrides, then
/// release pad isolation on RP2350.
///
/// The full IO_BANK0 CTRL write intentionally resets all signal overrides to
/// normal. Pulls and drive strength live in PADS_BANK0 and are preserved by
/// the separate masked pad update. IO_BANK0 and PADS_BANK0 must be released
/// from reset before calling this function.
pub inline fn setFunction(comptime pin: anytype, comptime function: Function) void {
    const index = pinIndex(pin);
    const Pad = chip.pads_bank0.Pad;

    // Portable Function → chip FUNCSEL by shared member name.
    const funcsel = @field(chip.io_bank0.FuncSel, @tagName(function));
    comptime std.debug.assert(chip.io_bank0.isAvailable(index, funcsel));

    // Pad: input buffer on, output-disable off. Preserve every other field.
    const pad_fields = comptime mmio.fieldsMask(Pad, &.{ .input_enable, .output_disable });
    const pad_word: u32 = @bitCast(Pad{ .input_enable = true, .output_disable = false });
    chip.pads_bank0.registers.gpio[index].writeMasked(pad_word, pad_fields);

    // Mux: select the function; all overrides stay normal (CTRL defaults).
    chip.io_bank0.registers.io[index].ctrl.write(.{ .funcsel = funcsel });

    // RP2350 pads power up isolated and conduct nothing until this bit is
    // cleared, which must happen after the pad and mux are configured. The
    // field is reserved on RP2040, so the whole branch compiles out there.
    if (@hasField(Pad, "isolate"))
        chip.pads_bank0.registers.gpio[index].clearBits(comptime mmio.fieldMask(Pad, .isolate));
}

/// Sets the pin's weak pull bias, preserving every other pad field. See the
/// E9 note on `Pull.down` before relying on a pull-down on RP2350 A2 silicon.
/// PADS_BANK0 must be released from reset before calling this function.
pub inline fn setPull(comptime pin: anytype, pull: Pull) void {
    const index = pinIndex(pin);
    const Pad = chip.pads_bank0.Pad;
    const mask = comptime mmio.fieldsMask(Pad, &.{ .pull_up, .pull_down });
    const word: u32 = @bitCast(Pad{
        .pull_up = pull == .up,
        .pull_down = pull == .down,
    });
    chip.pads_bank0.registers.gpio[index].writeMasked(word, mask);
}

/// Restores `pin`'s IO_BANK0 mux and PADS_BANK0 electrical configuration to
/// their power-on reset words.
///
/// This does not modify SIO output or output-enable latches; the handle returned
/// by `sio.init` clears those in `deinit` before resetting its pin. IO_BANK0
/// and PADS_BANK0 must be released from reset before calling this function.
pub inline fn reset(comptime pin: anytype) void {
    const index = pinIndex(pin);
    chip.io_bank0.registers.io[index].ctrl.write(.{});
    chip.pads_bank0.registers.gpio[index].write(.{});
}

/// Sets the pin's nominal output drive strength, preserving every other pad
/// field. PADS_BANK0 must be released from reset before calling this function.
pub inline fn setDriveStrength(comptime pin: anytype, strength: DriveStrength) void {
    const index = pinIndex(pin);
    const Pad = chip.pads_bank0.Pad;
    const mask = comptime mmio.fieldMask(Pad, .drive);
    const word: u32 = @bitCast(Pad{ .drive = strength });
    chip.pads_bank0.registers.gpio[index].writeMasked(word, mask);
}

/// Normalizes a comptime pin identifier - a GPIO number or a board `Pin` enum
/// value - to its integer GPIO index, and rejects pins the selected chip does
/// not expose. A comptime-known invalid pin is a compile error.
pub fn pinIndex(comptime pin: anytype) comptime_int {
    const n: comptime_int = switch (@typeInfo(@TypeOf(pin))) {
        .int, .comptime_int => pin,
        .@"enum" => @intFromEnum(pin),
        else => @compileError(
            "gpio pin must be a GPIO number or a board Pin enum value, got " ++ @typeName(@TypeOf(pin)),
        ),
    };
    if (n < 0 or n >= chip.gpio_count) @compileError(std.fmt.comptimePrint(
        "GPIO {d} is out of range; the selected chip exposes GPIO 0..{d}",
        .{ n, chip.gpio_count - 1 },
    ));
    return n;
}

comptime {
    // The portable Function names map to a chip FUNCSEL by shared member name;
    // software GPIO is FUNCSEL 5 on both chips.
    std.debug.assert(@intFromEnum(@field(chip.io_bank0.FuncSel, @tagName(Function.sio))) == 5);

    // `pinIndex` accepts a bare number and a board-style `Pin` enum alike,
    // without the HAL importing any board module.
    const ProbePin = enum(u6) { led = 25 };
    std.debug.assert(pinIndex(25) == 25);
    std.debug.assert(pinIndex(ProbePin.led) == 25);
}
