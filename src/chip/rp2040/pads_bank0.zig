//! RP2040 user IO pads (PADS_BANK0): the electrical behavior of each package pin.
//!
//! This block decides how the pin's transistor-level interface behaves -
//! input buffer, output driver, drive strength, edge speed, and weak pulls.
//!
//! Source: [RP2040 datasheet §2.19.6, "PADS_BANK0 registers"](https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// Nominal output drive strength (datasheet field `DRIVE`).
/// A rating of the pad's current capability.
pub const Drive = enum(u2) {
    ma_2 = 0,
    ma_4 = 1,
    ma_8 = 2,
    ma_12 = 3,
};

/// Bank-wide supply voltage mode (datasheet field `VOLTAGE_SELECT`).
pub const Voltage = enum(u1) {
    /// 3.3 V mode; requires DVDD of at least 2.5 V. Reset value.
    v3_3 = 0,
    /// 1.8 V mode; requires DVDD of at most 1.8 V.
    v1_8 = 1,
};

/// VOLTAGE_SELECT: supply voltage mode for every pad in the bank.
pub const VoltageSelect = packed struct(u32) {
    voltage: Voltage = .v3_3,
    _reserved0: u31 = 0,
};

/// GPIOn: the electrical controls for one pad. Every field defaults to its
/// reset value, so `Pad{}` is the power-on word and a partial initializer
/// changes only what it names.
pub const Pad = packed struct(u32) {
    /// `SLEWFAST`: false selects limited edge rates, true fast edges.
    slew_fast: bool = false,
    /// `SCHMITT`: input hysteresis, so a slow or noisy digital input is less
    /// likely to chatter.
    schmitt: bool = true,
    /// `PDE`: weak pull-down enable.
    pull_down: bool = true,
    /// `PUE`: weak pull-up enable. With both pulls enabled the pad behaves as
    /// a bus keeper.
    pull_up: bool = false,
    /// `DRIVE`: nominal output drive strength.
    drive: Drive = .ma_4,
    /// `IE`: digital input-buffer enable. May stay on while the pin drives an
    /// output, which is what lets software read the pad's actual level back.
    input_enable: bool = true,
    /// `OD`: output disable. Overrides the output enable coming from SIO or
    /// any peripheral, so it is a high-priority gate.
    output_disable: bool = false,
    _reserved0: u24 = 0,
};

/// Pad register slots defined by the PADS_BANK0 block, one per GPIO. The
/// bonded/usable pin count is the chip facade's `gpio_count` (30 here; equal).
pub const num_pads = 30;

/// PADS_BANK0 register block: the bank-wide voltage mode, then one word per
/// pad. Every register is APB read-write so the HAL can masked-update one
/// field while preserving the rest of the pad's configuration.
pub const Registers = extern struct {
    voltage_select: mmio.ApbReadWrite(VoltageSelect),
    gpio: [num_pads]mmio.ApbReadWrite(Pad),
};

/// The PADS_BANK0 peripheral at its RP2040 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.pads_bank0_base);

comptime {
    const std = @import("std");

    // Field bit positions per the datasheet register definition.
    std.debug.assert(@bitOffsetOf(Pad, "slew_fast") == 0);
    std.debug.assert(@bitOffsetOf(Pad, "schmitt") == 1);
    std.debug.assert(@bitOffsetOf(Pad, "pull_down") == 2);
    std.debug.assert(@bitOffsetOf(Pad, "pull_up") == 3);
    std.debug.assert(@bitOffsetOf(Pad, "drive") == 4);
    std.debug.assert(@bitOffsetOf(Pad, "input_enable") == 6);
    std.debug.assert(@bitOffsetOf(Pad, "output_disable") == 7);
    std.debug.assert(@bitOffsetOf(VoltageSelect, "voltage") == 0);

    // The pad powers up with its input buffer enabled and a pull-down holding the line
    std.debug.assert(@as(u32, @bitCast(Pad{})) == 0x0000_0056);
    std.debug.assert(@as(u32, @bitCast(VoltageSelect{})) == 0x0000_0000);

    // Drive encodings.
    std.debug.assert(@intFromEnum(Drive.ma_2) == 0);
    std.debug.assert(@intFromEnum(Drive.ma_4) == 1);
    std.debug.assert(@intFromEnum(Drive.ma_8) == 2);
    std.debug.assert(@intFromEnum(Drive.ma_12) == 3);

    // Block layout: VOLTAGE_SELECT at +0x00, pads from +0x04, 4 bytes each.
    std.debug.assert(@offsetOf(Registers, "voltage_select") == 0x00);
    std.debug.assert(@offsetOf(Registers, "gpio") == 0x04);
    std.debug.assert(@sizeOf(Registers) == 0x7c);
    // The on-board LED pin on both supported boards, as worked through in the
    // manual: 0x04 + 25*4.
    std.debug.assert(@offsetOf(Registers, "gpio") + 25 * 4 == 0x68);
}
